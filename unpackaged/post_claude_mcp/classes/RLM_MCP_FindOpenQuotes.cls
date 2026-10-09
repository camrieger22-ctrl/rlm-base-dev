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

        @InvocableVariable(
            label='Opportunity Name'
            description='Optional. When set, list only Drafts on this open Opportunity. Use after reconnect or a follow-up email.'
        )
        global String opportunityName;
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
        description='Lists Draft quotes for an account. Pass opportunityName after reconnect to pin the deal. Do not create a quote.'
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
            RLM_MCP_DealResolver.Result accountHit =
                RLM_MCP_DealResolver.resolveAccount(input.accountName.trim());
            if (accountHit.account == null) {
                out.needsDisambiguation = accountHit.needsDisambiguation;
                out.candidateSummariesDisplay = accountHit.candidateSummariesDisplay;
                out.errorMessage = accountHit.errorMessage;
                return out;
            }
            Account account = accountHit.account;
            Id opportunityId = null;
            if (String.isNotBlank(input.opportunityName)) {
                opportunityId = RLM_MCP_DealResolver.findNamedOpenOpportunity(
                    account.Id,
                    input.opportunityName
                );
                if (opportunityId == null) {
                    out.isSuccess = true;
                    out.summaryDisplay = account.Name + ' has no open Opportunity named "'
                        + input.opportunityName.trim() + '".';
                    return out;
                }
            }
            List<Quote> quotes = RLM_MCP_DealResolver.listDrafts(account.Id, opportunityId);
            if (quotes.size() > MAX_QUOTES) {
                List<Quote> clipped = new List<Quote>();
                for (Integer i = 0; i < MAX_QUOTES; i++) {
                    clipped.add(quotes[i]);
                }
                quotes = clipped;
            }
            out.isSuccess = true;
            out.quoteCount = quotes.size();
            if (quotes.isEmpty()) {
                out.summaryDisplay = String.isBlank(input.opportunityName)
                    ? account.Name + ' has no Draft quotes.'
                    : account.Name + ' has no Draft quotes on "'
                        + input.opportunityName.trim() + '".';
                return out;
            }
            out.latestQuoteId = quotes[0].Id;
            String heading = String.isBlank(input.opportunityName)
                ? 'Draft quotes for ' + account.Name + ' (newest first):'
                : 'Draft quotes for ' + account.Name + ' on '
                    + input.opportunityName.trim() + ' (newest first):';
            List<String> rows = new List<String>{ heading };
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
            if (quotes.size() == 1) {
                rows.add('Use latestQuoteId. Do not create another quote.');
            } else {
                rows.add('Use the quoteId already in this chat when it matches. Otherwise ask which row.');
            }
            out.summaryDisplay = String.join(rows, '\n');
        } catch (Exception e) {
            out.isSuccess = false;
            out.errorMessage = e.getMessage() == null ? 'Could not list quotes.' : e.getMessage();
        }
        return out;
    }
}
