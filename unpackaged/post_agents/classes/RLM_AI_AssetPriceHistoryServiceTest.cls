@isTest
private class RLM_AI_AssetPriceHistoryServiceTest {

    @isTest
    static void historyRejectsBlankQuoteId() {
        RLM_AI_AssetPriceHistoryService.HistoryInput input =
            new RLM_AI_AssetPriceHistoryService.HistoryInput();
        input.quoteId = '';

        List<RLM_AI_AssetPriceHistoryService.HistoryOutput> results =
            RLM_AI_AssetPriceHistoryService.getHistory(
                new List<RLM_AI_AssetPriceHistoryService.HistoryInput>{ input }
            );

        System.assertEquals(false, results[0].isSuccess);
        System.assert(results[0].errorMessage.contains('Quote Id is required'));
    }

    @isTest
    static void historyRejectsNonQuoteId() {
        Account acct = new Account(Name = 'Not A Quote');
        insert acct;

        RLM_AI_AssetPriceHistoryService.HistoryInput input =
            new RLM_AI_AssetPriceHistoryService.HistoryInput();
        input.quoteId = String.valueOf(acct.Id); // Account prefix, not Quote

        List<RLM_AI_AssetPriceHistoryService.HistoryOutput> results =
            RLM_AI_AssetPriceHistoryService.getHistory(
                new List<RLM_AI_AssetPriceHistoryService.HistoryInput>{ input }
            );

        System.assertEquals(false, results[0].isSuccess);
        System.assert(results[0].errorMessage.contains('Invalid quote Id'));
    }

    @isTest
    static void historyReturnsEmptyFriendlyMessage() {
        Account acct = new Account(Name = 'History Empty Account');
        insert acct;
        Opportunity opp = new Opportunity(
            Name = 'History Empty Opp',
            AccountId = acct.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Quote q = new Quote(
            Name = 'History Empty Quote',
            Pricebook2Id = Test.getStandardPricebookId(),
            OpportunityId = opp.Id,
            Status = 'Draft'
        );
        insert q;

        RLM_AI_AssetPriceHistoryService.HistoryInput input =
            new RLM_AI_AssetPriceHistoryService.HistoryInput();
        input.quoteId = String.valueOf(q.Id);
        input.productName = 'Generative AI';

        Test.startTest();
        List<RLM_AI_AssetPriceHistoryService.HistoryOutput> results =
            RLM_AI_AssetPriceHistoryService.getHistory(
                new List<RLM_AI_AssetPriceHistoryService.HistoryInput>{ input }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess);
        System.assert(String.isNotBlank(results[0].historyDisplay));
        System.assert(!results[0].historyDisplay.contains(String.valueOf(q.Id)));
    }
}
