@isTest
private class RLM_AI_CatalogSearchServiceTest {

    @isTest
    static void searchRejectsBlankQuoteId() {
        RLM_AI_CatalogSearchService.SearchInput input =
            new RLM_AI_CatalogSearchService.SearchInput();
        input.quoteId = null;
        input.searchTerm = 'AI';

        List<RLM_AI_CatalogSearchService.SearchOutput> results =
            RLM_AI_CatalogSearchService.search(
                new List<RLM_AI_CatalogSearchService.SearchInput>{ input }
            );
        System.assertEquals(false, results[0].isSuccess);
        System.assert(results[0].errorMessage.contains('Quote Id is required'));
    }

    @isTest
    static void searchRejectsShortTerm() {
        Quote q = createQuote('Catalog Search Short');

        RLM_AI_CatalogSearchService.SearchInput input =
            new RLM_AI_CatalogSearchService.SearchInput();
        input.quoteId = String.valueOf(q.Id);
        input.searchTerm = 'A';

        List<RLM_AI_CatalogSearchService.SearchOutput> results =
            RLM_AI_CatalogSearchService.search(
                new List<RLM_AI_CatalogSearchService.SearchInput>{ input }
            );

        System.assertEquals(false, results[0].isSuccess);
        System.assert(results[0].errorMessage.contains('at least 2 characters'));
    }

    @isTest
    static void searchReturnsNamesOnlyHitsOrEmpty() {
        Quote q = createQuote('Catalog Search Hits');
        Product2 product = new Product2(Name = 'QuantumBit Catalog Probe', IsActive = true);
        insert product;
        insert new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(),
            Product2Id = product.Id,
            UnitPrice = 50,
            IsActive = true
        );

        RLM_AI_CatalogSearchService.SearchInput input =
            new RLM_AI_CatalogSearchService.SearchInput();
        input.quoteId = String.valueOf(q.Id);
        input.searchTerm = 'QuantumBit Catalog Probe';

        Test.startTest();
        List<RLM_AI_CatalogSearchService.SearchOutput> results =
            RLM_AI_CatalogSearchService.search(
                new List<RLM_AI_CatalogSearchService.SearchInput>{ input }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess);
        System.assertNotEquals(null, results[0].resultsDisplay);
        System.assert(!results[0].resultsDisplay.contains(String.valueOf(product.Id)));
        System.assert(!results[0].resultsDisplay.contains(String.valueOf(q.Id)));
    }

    private static Quote createQuote(String name) {
        Account acct = new Account(Name = name + ' Account');
        insert acct;
        Opportunity opp = new Opportunity(
            Name = name + ' Opp',
            AccountId = acct.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Quote q = new Quote(
            Name = name,
            Pricebook2Id = Test.getStandardPricebookId(),
            OpportunityId = opp.Id,
            Status = 'Draft'
        );
        insert q;
        return q;
    }
}
