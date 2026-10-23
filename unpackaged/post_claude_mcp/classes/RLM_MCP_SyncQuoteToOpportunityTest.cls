@IsTest
private class RLM_MCP_SyncQuoteToOpportunityTest {
    @TestSetup
    static void setup() {
        Account account = new Account(Name = 'Sync MCP Account');
        insert account;
        Opportunity opportunity = new Opportunity(
            Name = 'Sync MCP Opp',
            AccountId = account.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opportunity;
        Id pbId = Test.getStandardPricebookId();
        Product2 product = new Product2(Name = 'Sync Widget', IsActive = true);
        insert product;
        PricebookEntry entry = new PricebookEntry(
            Pricebook2Id = pbId,
            Product2Id = product.Id,
            UnitPrice = 50,
            IsActive = true
        );
        insert entry;
        Quote first = new Quote(
            Name = 'Sync MCP Quote A',
            OpportunityId = opportunity.Id,
            Pricebook2Id = pbId,
            Status = 'Draft'
        );
        Quote second = new Quote(
            Name = 'Sync MCP Quote B',
            OpportunityId = opportunity.Id,
            Pricebook2Id = pbId,
            Status = 'Draft'
        );
        insert new List<Quote>{ first, second };
        insert new List<QuoteLineItem>{
            new QuoteLineItem(
                QuoteId = first.Id,
                PricebookEntryId = entry.Id,
                Product2Id = product.Id,
                Quantity = 1,
                UnitPrice = 50
            ),
            new QuoteLineItem(
                QuoteId = second.Id,
                PricebookEntryId = entry.Id,
                Product2Id = product.Id,
                Quantity = 2,
                UnitPrice = 50
            )
        };
    }

    private static RLM_MCP_SyncQuoteToOpportunity.SyncOutput run(
        RLM_MCP_SyncQuoteToOpportunity.SyncInput input
    ) {
        return RLM_MCP_SyncQuoteToOpportunity.syncQuote(
            new List<RLM_MCP_SyncQuoteToOpportunity.SyncInput>{ input }
        )[0];
    }

    @IsTest
    static void exactNameStartsSync() {
        Quote quote = [SELECT Id, OpportunityId FROM Quote WHERE Name = 'Sync MCP Quote A'];
        RLM_MCP_SyncQuoteToOpportunity.SyncInput input =
            new RLM_MCP_SyncQuoteToOpportunity.SyncInput();
        input.quoteName = 'Sync MCP Quote A';
        Test.startTest();
        RLM_MCP_SyncQuoteToOpportunity.SyncOutput out = run(input);
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, out.errorMessage == null ? 'ok' : out.errorMessage);
        System.assertEquals(true, out.isSyncing);
        System.assertEquals('sync', out.action);
        System.assert(out.resultsDisplay.contains('Started sync'), out.resultsDisplay);
        System.assert(out.resultsDisplay.contains('Open Quote'), out.resultsDisplay);
        System.assert(out.resultsDisplay.contains('do not copy'), out.resultsDisplay);
        Opportunity opportunity = [
            SELECT SyncedQuoteId FROM Opportunity WHERE Id = :quote.OpportunityId
        ];
        System.assertEquals(quote.Id, opportunity.SyncedQuoteId);
    }

    @IsTest
    static void alreadySyncingIsNoOp() {
        Quote quote = [SELECT Id, OpportunityId FROM Quote WHERE Name = 'Sync MCP Quote A'];
        update new Opportunity(Id = quote.OpportunityId, SyncedQuoteId = quote.Id);
        RLM_MCP_SyncQuoteToOpportunity.SyncInput input =
            new RLM_MCP_SyncQuoteToOpportunity.SyncInput();
        input.quoteId = quote.Id;
        Test.startTest();
        RLM_MCP_SyncQuoteToOpportunity.SyncOutput out = run(input);
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, out.errorMessage == null ? 'ok' : out.errorMessage);
        System.assertEquals(true, out.isSyncing);
        System.assert(out.resultsDisplay.contains('already syncing'), out.resultsDisplay);
    }

    @IsTest
    static void namedQuoteReplacesOtherSync() {
        Quote first = [SELECT Id, OpportunityId FROM Quote WHERE Name = 'Sync MCP Quote A'];
        Quote second = [SELECT Id FROM Quote WHERE Name = 'Sync MCP Quote B'];
        update new Opportunity(Id = first.OpportunityId, SyncedQuoteId = first.Id);
        RLM_MCP_SyncQuoteToOpportunity.SyncInput input =
            new RLM_MCP_SyncQuoteToOpportunity.SyncInput();
        input.quoteId = second.Id;
        Test.startTest();
        RLM_MCP_SyncQuoteToOpportunity.SyncOutput out = run(input);
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, out.errorMessage == null ? 'ok' : out.errorMessage);
        System.assertEquals('Sync MCP Quote A', out.previousSyncedQuoteName);
        System.assert(out.resultsDisplay.contains('Replaced'), out.resultsDisplay);
        Opportunity opportunity = [
            SELECT SyncedQuoteId FROM Opportunity WHERE Id = :first.OpportunityId
        ];
        System.assertEquals(second.Id, opportunity.SyncedQuoteId);
    }

    @IsTest
    static void unsyncClearsLink() {
        Quote quote = [SELECT Id, OpportunityId FROM Quote WHERE Name = 'Sync MCP Quote A'];
        update new Opportunity(Id = quote.OpportunityId, SyncedQuoteId = quote.Id);
        RLM_MCP_SyncQuoteToOpportunity.SyncInput input =
            new RLM_MCP_SyncQuoteToOpportunity.SyncInput();
        input.quoteId = quote.Id;
        input.action = 'unsync';
        Test.startTest();
        RLM_MCP_SyncQuoteToOpportunity.SyncOutput out = run(input);
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, out.errorMessage == null ? 'ok' : out.errorMessage);
        System.assertEquals(false, out.isSyncing);
        System.assert(out.resultsDisplay.contains('Stopped sync'), out.resultsDisplay);
        Opportunity opportunity = [
            SELECT SyncedQuoteId FROM Opportunity WHERE Id = :quote.OpportunityId
        ];
        System.assertEquals(null, opportunity.SyncedQuoteId);
    }

    @IsTest
    static void unsyncOtherQuoteIsRejected() {
        Quote first = [SELECT Id, OpportunityId FROM Quote WHERE Name = 'Sync MCP Quote A'];
        Quote second = [SELECT Id FROM Quote WHERE Name = 'Sync MCP Quote B'];
        update new Opportunity(Id = first.OpportunityId, SyncedQuoteId = first.Id);
        RLM_MCP_SyncQuoteToOpportunity.SyncInput input =
            new RLM_MCP_SyncQuoteToOpportunity.SyncInput();
        input.quoteId = second.Id;
        input.action = 'stop';
        Test.startTest();
        RLM_MCP_SyncQuoteToOpportunity.SyncOutput out = run(input);
        Test.stopTest();
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('not **Sync MCP Quote B**'), out.errorMessage);
    }

    @IsTest
    static void missingIdentityErrors() {
        RLM_MCP_SyncQuoteToOpportunity.SyncOutput out =
            run(new RLM_MCP_SyncQuoteToOpportunity.SyncInput());
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('Provide a quote'), out.errorMessage);
    }

    @IsTest
    static void invalidActionErrors() {
        RLM_MCP_SyncQuoteToOpportunity.SyncInput input =
            new RLM_MCP_SyncQuoteToOpportunity.SyncInput();
        input.quoteName = 'Sync MCP Quote A';
        input.action = 'merge';
        RLM_MCP_SyncQuoteToOpportunity.SyncOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('sync or unsync'), out.errorMessage);
    }

    @IsTest
    static void accountNameAsksWhichQuote() {
        RLM_MCP_SyncQuoteToOpportunity.SyncInput input =
            new RLM_MCP_SyncQuoteToOpportunity.SyncInput();
        input.accountName = 'Sync MCP Account';
        RLM_MCP_SyncQuoteToOpportunity.SyncOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assertEquals(true, out.needsDisambiguation);
        System.assert(out.candidateSummariesDisplay.contains('Quote A'), out.candidateSummariesDisplay);
        System.assert(out.candidateSummariesDisplay.contains('Quote B'), out.candidateSummariesDisplay);
    }

}
