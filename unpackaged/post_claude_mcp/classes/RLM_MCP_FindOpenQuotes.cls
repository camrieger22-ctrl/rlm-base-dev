/**
 * Hosted MCP: list Draft quotes for an account so Claude does not guess
 * among several Acme deals.
 */
global with sharing class RLM_MCP_FindOpenQuotes {
    private static final Integer MAX_QUOTES = 15;

    global class FindInput {
        @InvocableVariable(
            required=true
            label='Account Name'
            description='Account that owns the quotes, e.g. Acme.'
        )
        global String accountName;
    }

    global class FindOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(label='Quote Count')
        global Decimal quoteCount;
        @InvocableVariable(label='Latest Quote Id')
        global String latestQuoteId;
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
        label='Find Revenue Cloud Open Quotes'
        description='Lists Draft quotes for an account (name, Opportunity, line count, last modified). Use when more than one deal might match. Do not create a quote.'
    )
    global static List<FindOutput> findOpenQuotes(List<FindInput> inputs) {
        List<FindOutput> results = new List<FindOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (FindInput input : inputs) {
            results.add(findOne(input));
        }
        return results;
    }

    private static FindOutput findOne(FindInput input) {
        FindOutput out = new FindOutput();
        out.isSuccess = false;
        out.quoteCount = 0;
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
            List<Quote> quotes = [
                SELECT Id, Name, QuoteNumber, Status, LineItemCount, LastModifiedDate,
                       Opportunity.Name, OpportunityId
                FROM Quote
                WHERE AccountId = :account.Id
                AND Status = 'Draft'
                ORDER BY LastModifiedDate DESC
                LIMIT :MAX_QUOTES
            ];
            out.isSuccess = true;
            out.quoteCount = quotes.size();
            if (quotes.isEmpty()) {
                out.summaryDisplay = account.Name + ' has no Draft quotes.';
                return out;
            }
            out.latestQuoteId = quotes[0].Id;
            List<String> rows = new List<String>{
                'Draft quotes for ' + account.Name + ' (newest first):'
            };
            Integer n = 1;
            for (Quote q : quotes) {
                String opp = q.Opportunity == null ? '' : q.Opportunity.Name;
                String lines = q.LineItemCount == null ? '0' : String.valueOf(q.LineItemCount);
                String whenOn = q.LastModifiedDate == null
                    ? ''
                    : String.valueOf(q.LastModifiedDate.date());
                String title = q.Name;
                if (String.isNotBlank(q.QuoteNumber)) {
                    title += ' (' + q.QuoteNumber + ')';
                }
                rows.add(String.valueOf(n) + '. ' + title
                    + ' — ' + opp
                    + ', ' + lines + ' lines'
                    + (String.isBlank(whenOn) ? '' : ', ' + whenOn));
                String link = RLM_MCP_RecordLinks.markdown('Open Quote', 'Quote', q.Id);
                if (String.isNotBlank(link)) {
                    rows.add('   ' + link);
                }
                n++;
            }
            rows.add('Use the quoteId already in this chat when it matches. Otherwise ask which row.');
            out.summaryDisplay = String.join(rows, '\n');
        } catch (Exception e) {
            out.isSuccess = false;
            out.errorMessage = e.getMessage() == null ? 'Could not list quotes.' : e.getMessage();
        }
        return out;
    }

    private static Account resolveAccount(String term, FindOutput out) {
        List<Account> exact = [
            SELECT Id, Name FROM Account WHERE Name = :term LIMIT 10
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
        List<String> names = new List<String>{
            'Multiple accounts match "' + term + '". Which one?'
        };
        Integer n = 1;
        for (Account account : matches) {
            names.add(String.valueOf(n) + '. ' + account.Name);
            n++;
        }
        out.candidateSummariesDisplay = String.join(names, '\n');
        out.errorMessage = 'Multiple accounts match "' + term + '". Ask the user which one.';
        return null;
    }
}
