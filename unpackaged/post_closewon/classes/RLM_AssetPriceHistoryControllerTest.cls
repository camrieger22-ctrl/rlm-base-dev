@isTest
private class RLM_AssetPriceHistoryControllerTest {

    @isTest
    static void getHistoryForQuote_null_returnsEmpty() {
        Test.startTest();
        RLM_AssetPriceHistoryController.HistoryResponse resp =
            RLM_AssetPriceHistoryController.getHistoryForQuote(null);
        Test.stopTest();
        System.assertEquals(false, resp.isAmendmentQuote);
        System.assertEquals(0, resp.rows.size());
    }

    @isTest
    static void getHistoryForQuote_nonAmendment_returnsHint() {
        Account acct = new Account(Name = 'Price History Test Acct');
        insert acct;
        Opportunity opp = new Opportunity(
            Name = 'Price History Opp',
            AccountId = acct.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Quote q = new Quote(
            Name = 'Non-Amend Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft'
        );
        insert q;

        Test.startTest();
        RLM_AssetPriceHistoryController.HistoryResponse resp =
            RLM_AssetPriceHistoryController.getHistoryForQuote(q.Id);
        Test.stopTest();
        System.assertEquals(false, resp.isAmendmentQuote);
        System.assert(resp.message != null && resp.message.contains('amendment'));
        System.assertEquals(0, resp.rows.size());
        System.assertEquals(null, resp.summary);
        System.assertEquals(null, resp.projection);
    }
}
