/**
 * Hosted MCP: compare a Draft quote to current AssetStatePeriod rows so
 * Claude does not mix quote discount/qty with what the account owns.
 */
global with sharing class RLM_MCP_CompareQuoteToInstalledBase {
    private static final Integer MAX_LINES = 80;

    global class CompareInput {
        @InvocableVariable(
            label='Quote Id'
            description='18-character Quote Id (starts with 0Q0). Preferred when already in the chat.'
        )
        global String quoteId;

        @InvocableVariable(label='Quote Name')
        global String quoteName;

        @InvocableVariable(label='Account Name')
        global String accountName;
    }

    global class CompareOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(label='Quote Url')
        global String quoteUrl;
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
        label='Compare Quote To Installed Base'
        description='Compares a Draft quote to current AssetStatePeriod qty and Discount. Quote 30% off is not what they own. Never use Asset.CurrentMrr.'
    )
    global static List<CompareOutput> compare(List<CompareInput> inputs) {
        List<CompareOutput> results = new List<CompareOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (CompareInput input : inputs) {
            results.add(compareOne(input));
        }
        return results;
    }

    private static CompareOutput compareOne(CompareInput input) {
        CompareOutput out = new CompareOutput();
        out.isSuccess = false;
        out.needsDisambiguation = false;
        try {
            Quote quote = resolveQuote(input, out);
            if (quote == null) {
                return out;
            }
            out.quoteUrl = RLM_MCP_RecordLinks.lightningUrl('Quote', quote.Id);
            List<QuoteLineItem> lines = [
                SELECT Id, Quantity, Discount, Product2.Name
                FROM QuoteLineItem
                WHERE QuoteId = :quote.Id
                LIMIT :MAX_LINES
            ];
            Map<String, String> ownedNames = new Map<String, String>();
            Map<String, AssetStatePeriod> owned = currentOwned(quote.AccountId, ownedNames);
            Set<String> seen = new Set<String>();
            List<String> both = new List<String>();
            List<String> quoteOnly = new List<String>();
            List<String> ownedOnly = new List<String>();

            for (QuoteLineItem line : lines) {
                String key = productKey(line.Product2 == null ? null : line.Product2.Name);
                if (String.isBlank(key)) {
                    continue;
                }
                seen.add(key);
                String name = line.Product2.Name;
                AssetStatePeriod period = owned.get(key);
                if (period == null) {
                    quoteOnly.add('- ' + name + ' — qty ' + qtyLabel(line.Quantity)
                        + discountBit(line.Discount) + ' (new on quote)');
                } else {
                    both.add('- ' + name
                        + ' — owned qty ' + qtyLabel(period.Quantity)
                        + discountBit(period.Discount)
                        + ' → quote qty ' + qtyLabel(line.Quantity)
                        + discountBit(line.Discount));
                }
            }
            for (String key : owned.keySet()) {
                if (seen.contains(key)) {
                    continue;
                }
                AssetStatePeriod period = owned.get(key);
                String ownedName = ownedNames.containsKey(key) ? ownedNames.get(key) : key;
                ownedOnly.add('- ' + ownedName
                    + ' — qty ' + qtyLabel(period.Quantity)
                    + discountBit(period.Discount)
                    + ' (not on this quote)');
            }

            List<String> rows = new List<String>{
                'Quote vs installed base: ' + quote.Name
                    + (quote.Account == null ? '' : ' / ' + quote.Account.Name)
            };
            String qLink = RLM_MCP_RecordLinks.markdown('Open Quote', 'Quote', quote.Id);
            if (String.isNotBlank(qLink)) {
                rows.add(qLink);
            }
            rows.add('Quote Discount is the Draft. Owned Discount is AssetStatePeriod.');
            rows.add('');
            rows.add('On both:');
            rows.addAll(both.isEmpty() ? new List<String>{ '- None.' } : both);
            rows.add('');
            rows.add('New on quote (not owned):');
            rows.addAll(quoteOnly.isEmpty() ? new List<String>{ '- None.' } : quoteOnly);
            rows.add('');
            rows.add('Owned, not on this quote:');
            rows.addAll(ownedOnly.isEmpty() ? new List<String>{ '- None.' } : ownedOnly);
            out.isSuccess = true;
            out.summaryDisplay = String.join(rows, '\n');
        } catch (Exception e) {
            out.isSuccess = false;
            out.errorMessage = e.getMessage() == null ? 'Compare failed.' : e.getMessage();
        }
        return out;
    }

    private static Quote resolveQuote(CompareInput input, CompareOutput out) {
        if (input != null && String.isNotBlank(input.quoteId)) {
            try {
                Id qid = Id.valueOf(input.quoteId.trim());
                List<Quote> byId = [
                    SELECT Id, Name, AccountId, Account.Name
                    FROM Quote
                    WHERE Id = :qid
                    LIMIT 1
                ];
                if (byId.isEmpty()) {
                    out.errorMessage = 'No quote found for that Id.';
                    return null;
                }
                return byId[0];
            } catch (Exception e) {
                out.errorMessage = 'Invalid quote Id.';
                return null;
            }
        }
        String nameTerm = input == null ? null : blankToNull(input.quoteName);
        String acctTerm = input == null ? null : blankToNull(input.accountName);
        if (nameTerm == null && acctTerm == null) {
            out.errorMessage = 'Provide quoteId, or quoteName and/or accountName.';
            return null;
        }
        String np = nameTerm == null ? null : '%' + nameTerm + '%';
        String ap = acctTerm == null ? null : '%' + acctTerm + '%';
        List<Quote> matches;
        if (np != null && ap != null) {
            matches = [
                SELECT Id, Name, AccountId, Account.Name, LastModifiedDate
                FROM Quote
                WHERE Name LIKE :np AND Account.Name LIKE :ap
                ORDER BY LastModifiedDate DESC
                LIMIT 10
            ];
        } else if (np != null) {
            matches = [
                SELECT Id, Name, AccountId, Account.Name, LastModifiedDate
                FROM Quote
                WHERE Name LIKE :np
                ORDER BY LastModifiedDate DESC
                LIMIT 10
            ];
        } else {
            matches = [
                SELECT Id, Name, AccountId, Account.Name, LastModifiedDate
                FROM Quote
                WHERE Account.Name LIKE :ap AND Status = 'Draft'
                ORDER BY LastModifiedDate DESC
                LIMIT 10
            ];
        }
        if (matches.isEmpty()) {
            out.errorMessage = 'No quote matched.';
            return null;
        }
        if (matches.size() == 1) {
            return matches[0];
        }
        out.needsDisambiguation = true;
        List<String> rows = new List<String>{ 'Multiple quotes match. Which one?' };
        Integer n = 1;
        for (Quote q : matches) {
            String acct = q.Account == null ? '' : q.Account.Name;
            rows.add(String.valueOf(n) + '. ' + q.Name + ' — ' + acct);
            n++;
        }
        out.candidateSummariesDisplay = String.join(rows, '\n');
        out.errorMessage = 'Multiple quotes match. Ask the user which one.';
        return null;
    }

    private static Map<String, AssetStatePeriod> currentOwned(
        Id accountId,
        Map<String, String> ownedNames
    ) {
        Map<String, AssetStatePeriod> byName = new Map<String, AssetStatePeriod>();
        if (accountId == null) {
            return byName;
        }
        List<Asset> assets = [
            SELECT Id, Product2.Name
            FROM Asset
            WHERE AccountId = :accountId
            AND IsCompetitorProduct = false
            LIMIT 40
        ];
        if (assets.isEmpty()) {
            return byName;
        }
        Map<Id, String> nameByAsset = new Map<Id, String>();
        for (Asset asset : assets) {
            String name = asset.Product2 == null ? null : asset.Product2.Name;
            if (String.isNotBlank(name)) {
                nameByAsset.put(asset.Id, name);
            }
        }
        Datetime now = Datetime.now();
        for (AssetStatePeriod period : [
            SELECT AssetId, Quantity, Discount, StartDate, EndDate
            FROM AssetStatePeriod
            WHERE AssetId IN :nameByAsset.keySet()
            ORDER BY StartDate ASC
        ]) {
            if (period.StartDate != null && period.StartDate > now) {
                continue;
            }
            if (period.EndDate != null && period.EndDate < now) {
                continue;
            }
            String label = nameByAsset.get(period.AssetId);
            String key = productKey(label);
            if (String.isNotBlank(key)) {
                byName.put(key, period);
                ownedNames.put(key, label);
            }
        }
        return byName;
    }

    private static String productKey(String name) {
        return String.isBlank(name) ? null : name.trim().toLowerCase();
    }

    private static String qtyLabel(Decimal qty) {
        return formatNumber(qty);
    }

    private static String discountBit(Decimal percent) {
        if (percent == null || percent == 0) {
            return ', no % off';
        }
        return ', ' + formatNumber(percent) + '% off';
    }

    private static String formatNumber(Decimal value) {
        if (value == null) {
            return '0';
        }
        Decimal rounded = value.setScale(2, RoundingMode.HALF_UP);
        if (rounded == rounded.round(RoundingMode.DOWN)) {
            return String.valueOf(rounded.longValue());
        }
        return String.valueOf(rounded);
    }

    private static String blankToNull(String value) {
        return String.isBlank(value) ? null : value.trim();
    }
}
