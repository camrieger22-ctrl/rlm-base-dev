/**
 * Hosted MCP: draft an unsent customer reply from quote and/or installed base.
 * Never send mail.
 */
global with sharing class RLM_MCP_DraftCustomerReply {
    global class ReplyInput {
        @InvocableVariable(label='Quote Id')
        global String quoteId;
        @InvocableVariable(label='Quote Name')
        global String quoteName;
        @InvocableVariable(label='Account Name')
        global String accountName;
        @InvocableVariable(
            label='Purpose'
            description='Optional: quote recap, follow-up, or compare to owned. Does not send.'
        )
        global String purpose;
    }

    global class ReplyOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(label='Subject')
        global String subject;
        @InvocableVariable(label='Body Display')
        global String bodyDisplay;
        @InvocableVariable(label='Needs Disambiguation')
        global Boolean needsDisambiguation;
        @InvocableVariable(label='Candidate Summaries Display')
        global String candidateSummariesDisplay;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(
        label='Draft Revenue Cloud Customer Reply'
        description='Drafts an unsent customer email from quote lines and totals. Never send_message or Outlook send. Leave the draft in chat.'
    )
    global static List<ReplyOutput> draft(List<ReplyInput> inputs) {
        List<ReplyOutput> results = new List<ReplyOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (ReplyInput input : inputs) {
            results.add(draftOne(input));
        }
        return results;
    }

    private static ReplyOutput draftOne(ReplyInput input) {
        ReplyOutput out = new ReplyOutput();
        out.isSuccess = false;
        out.needsDisambiguation = false;
        try {
            if (input == null
                || (String.isBlank(input.quoteId)
                    && String.isBlank(input.quoteName)
                    && String.isBlank(input.accountName))
            ) {
                out.errorMessage = 'Provide quoteId, quoteName, or accountName.';
                return out;
            }
            Quote quote = resolveQuote(input, out);
            if (quote == null && String.isNotBlank(out.errorMessage)) {
                return out;
            }
            String accountName = quote == null || quote.Account == null
                ? blankToNull(input.accountName)
                : quote.Account.Name;
            List<QuoteLineItem> lines = new List<QuoteLineItem>();
            if (quote != null) {
                lines = [
                    SELECT Quantity, Discount, Product2.Name, TotalPrice
                    FROM QuoteLineItem
                    WHERE QuoteId = :quote.Id
                    LIMIT 40
                ];
            }
            String purpose = String.isBlank(input.purpose) ? 'quote recap' : input.purpose.trim();
            String subjectName = quote == null ? accountName : quote.Name;
            out.subject = 'Your ' + (subjectName == null ? 'quote' : subjectName);
            List<String> body = new List<String>{
                'Hi' + (accountName == null ? '' : ' ' + accountName) + ',',
                '',
                'Here is a draft recap (' + purpose + '). This email has not been sent.'
            };
            if (quote != null) {
                body.add('');
                body.add('Quote: ' + quote.Name
                    + (String.isBlank(quote.QuoteNumber) ? '' : ' (' + quote.QuoteNumber + ')'));
                if (quote.StartDate != null || quote.EndDate != null) {
                    body.add('Term: '
                        + (quote.StartDate == null ? '' : String.valueOf(quote.StartDate))
                        + (quote.EndDate == null ? '' : ' to ' + String.valueOf(quote.EndDate)));
                }
                if (lines.isEmpty()) {
                    body.add('No lines on this quote yet.');
                } else {
                    body.add('Proposed lines:');
                    for (QuoteLineItem line : lines) {
                        String name = line.Product2 == null ? 'Line' : line.Product2.Name;
                        String row = '- ' + name
                            + ' — qty ' + RLM_MCP_RecordLinks.formatNumber(line.Quantity);
                        if (line.Discount != null && line.Discount > 0) {
                            row += ', ' + RLM_MCP_RecordLinks.formatNumber(line.Discount) + '% off';
                        }
                        Decimal amount = line.TotalPrice;
                        if (amount != null) {
                            row += ' (' + RLM_MCP_RecordLinks.money(amount) + ')';
                        }
                        body.add(row);
                    }
                }
                body.add('');
                body.add('Quote total: ' + RLM_MCP_RecordLinks.money(quote.GrandTotal));
            } else {
                body.add('');
                body.add('I do not have a specific quote yet. Tell me which deal to recap.');
            }
            body.add('');
            body.add('Happy to adjust quantities, term, or discount if anything looks off.');
            body.add('');
            body.add('Thanks,');
            body.add(UserInfo.getName());
            body.add('');
            body.add('Do not send this. Leave it unsent unless they explicitly ask you to send — and even then, do not call Gmail/Outlook send from this skill.');
            out.isSuccess = true;
            out.bodyDisplay = String.join(body, '\n');
        } catch (Exception e) {
            out.isSuccess = false;
            out.errorMessage = e.getMessage() == null ? 'Draft failed.' : e.getMessage();
        }
        return out;
    }

    private static Quote resolveQuote(ReplyInput input, ReplyOutput out) {
        if (String.isNotBlank(input.quoteId)) {
            try {
                Id qid = Id.valueOf(input.quoteId.trim());
                List<Quote> byId = [
                    SELECT Id, Name, QuoteNumber, GrandTotal, StartDate, EndDate,
                           AccountId, Account.Name
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
        String nameTerm = blankToNull(input.quoteName);
        String acctTerm = blankToNull(input.accountName);
        if (nameTerm == null && acctTerm == null) {
            return null;
        }
        String np = nameTerm == null ? null : '%' + nameTerm + '%';
        String ap = acctTerm == null ? null : '%' + acctTerm + '%';
        List<Quote> matches;
        if (np != null && ap != null) {
            matches = [
                SELECT Id, Name, QuoteNumber, GrandTotal, StartDate, EndDate,
                       AccountId, Account.Name
                FROM Quote
                WHERE Name LIKE :np AND Account.Name LIKE :ap
                ORDER BY LastModifiedDate DESC
                LIMIT 8
            ];
        } else if (np != null) {
            matches = [
                SELECT Id, Name, QuoteNumber, GrandTotal, StartDate, EndDate,
                       AccountId, Account.Name
                FROM Quote
                WHERE Name LIKE :np
                ORDER BY LastModifiedDate DESC
                LIMIT 8
            ];
        } else {
            matches = [
                SELECT Id, Name, QuoteNumber, GrandTotal, StartDate, EndDate,
                       AccountId, Account.Name
                FROM Quote
                WHERE Account.Name LIKE :ap
                ORDER BY LastModifiedDate DESC
                LIMIT 8
            ];
        }
        if (matches.isEmpty()) {
            return null;
        }
        if (matches.size() == 1) {
            return matches[0];
        }
        out.needsDisambiguation = true;
        List<String> rows = new List<String>{ 'Multiple quotes match. Which one should the reply use?' };
        Integer n = 1;
        for (Quote q : matches) {
            rows.add(String.valueOf(n) + '. ' + q.Name);
            n++;
        }
        out.candidateSummariesDisplay = String.join(rows, '\n');
        out.errorMessage = 'Multiple quotes match. Ask the user which one.';
        return null;
    }

    private static String blankToNull(String value) {
        return String.isBlank(value) ? null : value.trim();
    }
}
