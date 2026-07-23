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

    @isTest
    static void stampDifferenceFieldsForQuote_nonAmendment_isNoOp() {
        Account acct = new Account(Name = 'Stamp Test Acct');
        insert acct;
        Opportunity opp = new Opportunity(
            Name = 'Stamp Test Opp',
            AccountId = acct.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Quote q = new Quote(
            Name = 'Stamp Non-Amend Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft'
        );
        insert q;

        Test.startTest();
        RLM_AssetPriceHistoryController.stampDifferenceFieldsForQuote(q.Id);
        RLM_AssetPriceHistoryController.stampDifferenceFieldsForQuote(null);
        Test.stopTest();

        Quote after = [
            SELECT RLM_Amend_Current_ARR__c, RLM_Amend_Proposed_ARR__c
            FROM Quote
            WHERE Id = :q.Id
        ];
        System.assertEquals(null, after.RLM_Amend_Current_ARR__c,
            'Non-amendment quotes must not stamp Current ARR');
        System.assertEquals(null, after.RLM_Amend_Proposed_ARR__c,
            'Non-amendment quotes must not stamp Proposed ARR');
    }
}
