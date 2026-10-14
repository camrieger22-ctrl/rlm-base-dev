@IsTest
private class RLM_MCP_CloneQuoteTest {

    @TestSetup
    static void setup() {
        update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
        insert new Account(Name = 'MCP Clone Account');
    }

    private static RLM_MCP_CloneQuote.CloneOutput run(RLM_MCP_CloneQuote.CloneInput input) {
        return RLM_MCP_CloneQuote.cloneQuote(
            new List<RLM_MCP_CloneQuote.CloneInput>{ input }
        )[0];
    }

    private static Quote insertDraft(String name, Id opportunityId) {
        Quote quote = new Quote(
            Name = name,
            OpportunityId = opportunityId,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft',
            StartDate = Date.today(),
            EndDate = Date.today().addMonths(24)
        );
        insert quote;
        return quote;
    }

    private static Opportunity insertOpp(String name, Id accountId) {
        Opportunity opportunity = new Opportunity(
            Name = name,
            AccountId = accountId,
            StageName = 'Proposal/Quote',
            CloseDate = Date.today().addDays(30)
        );
        insert opportunity;
        return opportunity;
    }

    @IsTest
    static void emptyInputsReturnNothing() {
        System.assertEquals(0, RLM_MCP_CloneQuote.cloneQuote(null).size());
        System.assertEquals(
            0,
            RLM_MCP_CloneQuote.cloneQuote(new List<RLM_MCP_CloneQuote.CloneInput>()).size()
        );
    }

    @IsTest
    static void requiresAccountOrQuoteId() {
        RLM_MCP_CloneQuote.CloneOutput out = run(new RLM_MCP_CloneQuote.CloneInput());
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('Account name'), out.errorMessage);
    }

    @IsTest
    static void rejectsNonQuoteId() {
        Account account = [SELECT Id FROM Account WHERE Name = 'MCP Clone Account' LIMIT 1];
        RLM_MCP_CloneQuote.CloneInput input = new RLM_MCP_CloneQuote.CloneInput();
        input.quoteId = String.valueOf(account.Id);
        RLM_MCP_CloneQuote.CloneOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('Quote Id'), out.errorMessage);
    }

    @IsTest
    static void missingNamedDraftErrors() {
        Account account = [SELECT Id FROM Account WHERE Name = 'MCP Clone Account' LIMIT 1];
        insertOpp('Clone Missing Opp', account.Id);
        RLM_MCP_CloneQuote.CloneInput input = new RLM_MCP_CloneQuote.CloneInput();
        input.accountName = 'MCP Clone Account';
        input.opportunityName = 'Clone Missing Opp';
        input.quoteName = 'No Such Draft';
        RLM_MCP_CloneQuote.CloneOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('No Draft quote named'), out.errorMessage);
        System.assert(
            !out.errorMessage.contains('Build Quote Options')
            || out.errorMessage.contains('Do not Build Quote Options'),
            out.errorMessage
        );
    }

    @IsTest
    static void latestAliasUsesOldestDraft() {
        Account account = [SELECT Id FROM Account WHERE Name = 'MCP Clone Account' LIMIT 1];
        Opportunity opportunity = insertOpp('Clone Latest Opp', account.Id);
        Quote older = insertDraft('Older Original', opportunity.Id);
        insertDraft('Newer Sibling', opportunity.Id);
        RLM_MCP_CloneQuote.CloneInput input = new RLM_MCP_CloneQuote.CloneInput();
        input.accountName = 'MCP Clone Account';
        input.opportunityName = 'Clone Latest Opp';
        input.quoteName = 'latest';
        input.clonedQuoteName = 'Latest Copy';
        Test.startTest();
        RLM_MCP_CloneQuote.CloneOutput out = run(input);
        Test.stopTest();
        System.assertEquals(
            true,
            out.isSuccess,
            'latest clone: ' + String.valueOf(out.errorMessage)
        );
        System.assertEquals(older.Id, out.sourceQuoteId);
        System.assertEquals('Latest Copy', out.quoteName);
        System.assertNotEquals(older.Id, out.quoteId);
        System.assert(out.resultsDisplay.contains('Do not Build Quote Options'), out.resultsDisplay);
        System.assertEquals(
            3,
            [SELECT COUNT() FROM Quote WHERE OpportunityId = :opportunity.Id]
        );
    }

    @IsTest
    static void clonesByQuoteId() {
        Account account = [SELECT Id FROM Account WHERE Name = 'MCP Clone Account' LIMIT 1];
        Opportunity opportunity = insertOpp('Clone Id Opp', account.Id);
        Quote source = insertDraft('Id Source', opportunity.Id);
        RLM_MCP_CloneQuote.CloneInput input = new RLM_MCP_CloneQuote.CloneInput();
        input.quoteId = String.valueOf(source.Id);
        Test.startTest();
        RLM_MCP_CloneQuote.CloneOutput out = run(input);
        Test.stopTest();
        System.assertEquals(
            true,
            out.isSuccess,
            'id clone: ' + String.valueOf(out.errorMessage)
        );
        System.assertEquals(source.Id, out.sourceQuoteId);
        System.assertEquals('Id Source Copy', out.quoteName);
        System.assertEquals(
            1,
            [SELECT COUNT() FROM Quote WHERE Id = :source.Id AND Name = 'Id Source']
        );
        System.assertEquals(
            2,
            [SELECT COUNT() FROM Quote WHERE OpportunityId = :opportunity.Id]
        );
    }
}
