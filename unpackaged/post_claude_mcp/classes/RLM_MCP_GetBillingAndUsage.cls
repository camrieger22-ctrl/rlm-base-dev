/**
 * Hosted MCP: next bill, quote TCV, and usage summaries. TCV is quote
 * GrandTotal (or derived remaining MRR). Salesforce does not store ARR/TCV
 * as a single standard field.
 */
global with sharing class RLM_MCP_GetBillingAndUsage {
    global class BillingInput {
        @InvocableVariable(
            required=true
            label='Account Name'
            description='Account to recap, e.g. Acme.'
        )
        global String accountName;

        @InvocableVariable(
            label='Quote Id'
            description='Optional. When set, TCV is that quote GrandTotal.'
        )
        global String quoteId;
    }

    global class BillingOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(label='Account Url')
        global String accountUrl;
        @InvocableVariable(label='Summary Display')
        global String summaryDisplay;
        @InvocableVariable(label='Needs Disambiguation')
        global Boolean needsDisambiguation;
        @InvocableVariable(label='Candidate Summaries Display')
        global String candidateSummariesDisplay;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(
        label='Get Revenue Cloud Billing And Usage'
        description='Read-only next BillingSchedule date, quote TCV (GrandTotal), and UsageSummary consumption. TCV is not ARR. Never Asset.CurrentMrr.'
    )
    global static List<BillingOutput> getBilling(List<BillingInput> inputs) {
        List<BillingOutput> results = new List<BillingOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (BillingInput input : inputs) {
            results.add(describeOne(input));
        }
        return results;
    }

    private static BillingOutput describeOne(BillingInput input) {
        BillingOutput out = new BillingOutput();
        out.isSuccess = false;
        out.needsDisambiguation = false;
        try {
            if (input == null || String.isBlank(input.accountName)) {
                out.errorMessage = 'Account name is required.';
                return out;
            }
            Account account = resolveAccount(input.accountName.trim(), out);
            if (account == null) {
                return out;
            }
            out.accountUrl = RLM_MCP_RecordLinks.lightningUrl('Account', account.Id);
            Quote quote = resolveQuote(input.quoteId, account.Id);
            List<BillingSchedule> bills = [
                SELECT Id, Status, NextBillingDate, BillingPeriodAmount, PendingAmount,
                       TotalAmount, BilledAmount, ReferenceEntityId
                FROM BillingSchedule
                WHERE BillingAccountId = :account.Id
                ORDER BY NextBillingDate ASC NULLS LAST
                LIMIT 20
            ];
            List<UsageSummary> usage = [
                SELECT Id, Name, Status, ConsumptionUnits, OverageUnits, DebitedUnits,
                       StartDateTime, EndDateTime, AssetId
                FROM UsageSummary
                WHERE AccountId = :account.Id
                ORDER BY StartDateTime DESC NULLS LAST
                LIMIT 20
            ];
            Decimal ownedMrr = currentOwnedMrr(account.Id);
            List<String> rows = new List<String>{
                'Billing and usage for ' + account.Name
            };
            String aLink = RLM_MCP_RecordLinks.markdown('Open Account', 'Account', account.Id);
            if (String.isNotBlank(aLink)) {
                rows.add(aLink);
            }
            rows.add('');
            rows.add('TCV:');
            if (quote != null) {
                rows.add('- Quote ' + quote.Name + ': ' + RLM_MCP_RecordLinks.money(quote.GrandTotal)
                    + ' (quote GrandTotal, not ARR)');
                String qLink = RLM_MCP_RecordLinks.markdown('Open Quote', 'Quote', quote.Id);
                if (String.isNotBlank(qLink)) {
                    rows.add(qLink);
                }
            } else {
                rows.add('- No quote passed. Owned current MRR: '
                    + RLM_MCP_RecordLinks.money(ownedMrr)
                    + '. Derived ARR (MRR×12): '
                    + RLM_MCP_RecordLinks.money(ownedMrr * 12)
                    + '. Salesforce does not store TCV/ARR as a field.');
            }
            rows.add('');
            rows.add('Next bill (BillingSchedule.NextBillingDate):');
            BillingSchedule nextBill = nextUpcoming(bills);
            if (nextBill == null) {
                rows.add('- None scheduled.');
            } else {
                rows.add('- ' + String.valueOf(nextBill.NextBillingDate)
                    + ' — ' + RLM_MCP_RecordLinks.money(nextBill.BillingPeriodAmount)
                    + ' (' + nullToDash(nextBill.Status) + ')');
            }
            if (!bills.isEmpty()) {
                rows.add('Schedules:');
                Integer shown = 0;
                for (BillingSchedule bill : bills) {
                    if (shown >= 5) {
                        break;
                    }
                    rows.add('- ' + (bill.NextBillingDate == null ? 'no next date' : String.valueOf(bill.NextBillingDate))
                        + ', billed ' + RLM_MCP_RecordLinks.money(bill.BilledAmount)
                        + ', pending ' + RLM_MCP_RecordLinks.money(bill.PendingAmount));
                    shown++;
                }
            }
            rows.add('');
            rows.add('Usage (UsageSummary):');
            if (usage.isEmpty()) {
                rows.add('- No usage summaries.');
            } else {
                for (UsageSummary row : usage) {
                    rows.add('- ' + (String.isBlank(row.Name) ? 'Usage' : row.Name)
                        + ' — consumed ' + RLM_MCP_RecordLinks.formatNumber(row.ConsumptionUnits)
                        + ', overage ' + RLM_MCP_RecordLinks.formatNumber(row.OverageUnits)
                        + ' (' + nullToDash(row.Status) + ')');
                }
            }
            out.isSuccess = true;
            out.summaryDisplay = String.join(rows, '\n');
        } catch (Exception e) {
            out.isSuccess = false;
            out.errorMessage = e.getMessage() == null ? 'Billing lookup failed.' : e.getMessage();
        }
        return out;
    }

    private static BillingSchedule nextUpcoming(List<BillingSchedule> bills) {
        Date today = Date.today();
        for (BillingSchedule bill : bills) {
            if (bill.NextBillingDate != null && bill.NextBillingDate >= today) {
                return bill;
            }
        }
        return null;
    }

    private static Decimal currentOwnedMrr(Id accountId) {
        Decimal total = 0;
        List<Asset> assets = [
            SELECT Id FROM Asset
            WHERE AccountId = :accountId AND IsCompetitorProduct = false
            LIMIT 40
        ];
        if (assets.isEmpty()) {
            return total;
        }
        Datetime now = Datetime.now();
        for (AssetStatePeriod period : [
            SELECT Mrr, StartDate, EndDate
            FROM AssetStatePeriod
            WHERE AssetId IN :new Map<Id, Asset>(assets).keySet()
        ]) {
            if (period.StartDate != null && period.StartDate > now) {
                continue;
            }
            if (period.EndDate != null && period.EndDate < now) {
                continue;
            }
            if (period.Mrr != null) {
                total += period.Mrr;
            }
        }
        return total;
    }

    private static Quote resolveQuote(String quoteIdRaw, Id accountId) {
        if (String.isNotBlank(quoteIdRaw)) {
            try {
                Id qid = Id.valueOf(quoteIdRaw.trim());
                List<Quote> byId = [
                    SELECT Id, Name, GrandTotal FROM Quote WHERE Id = :qid LIMIT 1
                ];
                return byId.isEmpty() ? null : byId[0];
            } catch (Exception e) {
                return null;
            }
        }
        List<Quote> latest = [
            SELECT Id, Name, GrandTotal
            FROM Quote
            WHERE AccountId = :accountId
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        return latest.isEmpty() ? null : latest[0];
    }

    private static Account resolveAccount(String term, BillingOutput out) {
        List<Account> exact = [
            SELECT Id, Name FROM Account WHERE Name = :term LIMIT 5
        ];
        if (exact.size() == 1) {
            return exact[0];
        }
        String fuzzy = '%' + term + '%';
        List<Account> matches = [
            SELECT Id, Name FROM Account WHERE Name LIKE :fuzzy ORDER BY Name LIMIT 10
        ];
        if (matches.isEmpty()) {
            out.errorMessage = 'No account matched "' + term + '".';
            return null;
        }
        if (matches.size() == 1) {
            return matches[0];
        }
        out.needsDisambiguation = true;
        List<String> rows = new List<String>{ 'Multiple accounts match "' + term + '". Which one?' };
        Integer n = 1;
        for (Account account : matches) {
            rows.add(String.valueOf(n) + '. ' + account.Name);
            n++;
        }
        out.candidateSummariesDisplay = String.join(rows, '\n');
        out.errorMessage = 'Multiple accounts match. Ask the user which one.';
        return null;
    }

    private static String nullToDash(String value) {
        return String.isBlank(value) ? '—' : value;
    }
}
