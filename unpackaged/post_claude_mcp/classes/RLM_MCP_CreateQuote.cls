/**
 * Global invocable for Hosted MCP: create a Draft Revenue Cloud Quote
 * from an account name. Reuses an open Opportunity on the account when
 * one exists; otherwise creates a Proposal/Quote opportunity.
 */
global with sharing class RLM_MCP_CreateQuote {
    global class CreateInput {
        @InvocableVariable(
            required=true
            label='Account Name'
            description='Customer account name. Exact match first, then partial. Example: Apex Dynamics.'
        )
        global String accountName;

        @InvocableVariable(
            label='Quote Name'
            description='Optional quote name. Defaults to New Quote For <Account>.'
        )
        global String quoteName;
    }

    global class CreateOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;

        @InvocableVariable(label='Quote Id')
        global String quoteId;

        @InvocableVariable(
            label='Quote Url'
            description='Lightning Quote page. Render as [Open Quote](quoteUrl) in the chat reply.'
        )
        global String quoteUrl;

        @InvocableVariable(label='Quote Name')
        global String quoteName;

        @InvocableVariable(label='Account Name')
        global String accountName;

        @InvocableVariable(label='Opportunity Id')
        global String opportunityId;

        @InvocableVariable(
            label='Opportunity Url'
            description='Lightning Opportunity page. Render as [Open Opportunity](opportunityUrl) in the chat reply.'
        )
        global String opportunityUrl;

        @InvocableVariable(label='Message')
        global String message;

        global CreateOutput() {
            this.isSuccess = false;
        }
    }

    @InvocableMethod(
        label='Create Revenue Cloud Quote'
        description='Creates a Draft Revenue Cloud Quote for an account. Resolves the account by name, uses Standard Price Book, and returns the new Quote Id. Use before adding products.'
    )
    global static List<CreateOutput> createQuote(List<CreateInput> inputs) {
        List<CreateOutput> results = new List<CreateOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (CreateInput input : inputs) {
            results.add(createOne(input));
        }
        return results;
    }

    private static CreateOutput createOne(CreateInput input) {
        CreateOutput out = new CreateOutput();
        if (input == null || String.isBlank(input.accountName)) {
            out.message = 'Account name is required.';
            return out;
        }

        Account account = findAccount(input.accountName.trim());
        if (account == null) {
            out.message = 'No account matched "' + input.accountName + '".';
            return out;
        }
        out.accountName = account.Name;

        List<Pricebook2> books = [
            SELECT Id
            FROM Pricebook2
            WHERE IsStandard = true AND IsActive = true
            WITH USER_MODE
            LIMIT 1
        ];
        if (books.isEmpty()) {
            out.message = 'Standard Price Book is not active.';
            return out;
        }

        Opportunity opportunity = findOpenOpportunity(account.Id);
        if (opportunity == null) {
            opportunity = new Opportunity(
                Name = account.Name + ' Quote Opportunity',
                AccountId = account.Id,
                StageName = 'Proposal/Quote',
                CloseDate = Date.today().addDays(30)
            );
            try {
                insert as user opportunity;
            } catch (Exception e) {
                out.message = 'Could not create Opportunity: ' + e.getMessage();
                return out;
            }
        }
        out.opportunityId = opportunity.Id;
        out.opportunityUrl = RLM_MCP_RecordLinks.lightningUrl('Opportunity', opportunity.Id);

        String name = String.isBlank(input.quoteName)
            ? 'New Quote For ' + account.Name
            : input.quoteName.trim();
        Quote quote = new Quote(
            Name = name,
            OpportunityId = opportunity.Id,
            Pricebook2Id = books[0].Id,
            Status = 'Draft'
        );
        try {
            insert as user quote;
        } catch (Exception e) {
            out.message = 'Could not create Quote: ' + e.getMessage();
            return out;
        }

        out.isSuccess = true;
        out.quoteId = quote.Id;
        out.quoteUrl = RLM_MCP_RecordLinks.lightningUrl('Quote', quote.Id);
        out.quoteName = name;
        List<String> lines = new List<String>{
            'Created draft quote ' + name + ' on ' + account.Name + '.'
        };
        String quoteLink = RLM_MCP_RecordLinks.markdown('Open Quote', 'Quote', quote.Id);
        String oppLink = RLM_MCP_RecordLinks.markdown(
            'Open Opportunity', 'Opportunity', opportunity.Id);
        if (String.isNotBlank(quoteLink)) {
            lines.add(quoteLink);
        }
        if (String.isNotBlank(oppLink)) {
            lines.add(oppLink);
        }
        out.message = String.join(lines, '\n');
        return out;
    }

    private static Account findAccount(String name) {
        List<Account> exact = [
            SELECT Id, Name
            FROM Account
            WHERE Name = :name
            WITH USER_MODE
            LIMIT 2
        ];
        if (exact.size() == 1) {
            return exact[0];
        }
        if (exact.size() > 1) {
            return exact[0];
        }
        String likeName = '%' + name + '%';
        List<Account> fuzzy = [
            SELECT Id, Name
            FROM Account
            WHERE Name LIKE :likeName
            WITH USER_MODE
            LIMIT 2
        ];
        return fuzzy.isEmpty() ? null : fuzzy[0];
    }

    private static Opportunity findOpenOpportunity(Id accountId) {
        List<Opportunity> opps = [
            SELECT Id
            FROM Opportunity
            WHERE AccountId = :accountId AND IsClosed = false
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        return opps.isEmpty() ? null : opps[0];
    }
}
