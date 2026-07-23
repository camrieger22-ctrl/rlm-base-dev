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

    @isTest
    static void getStudioPayload_nonAmendment_returnsQuoteMeta() {
        Account acct = new Account(Name = 'Studio Payload Acct');
        insert acct;
        Opportunity opp = new Opportunity(
            Name = 'Studio Payload Opp',
            AccountId = acct.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Quote q = new Quote(
            Name = 'Studio Non-Amend Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft'
        );
        insert q;

        Test.startTest();
        RLM_AssetPriceHistoryController.StudioPayload payload =
            RLM_AssetPriceHistoryController.getStudioPayload(q.Id);
        Test.stopTest();

        System.assertNotEquals(null, payload.history);
        System.assertEquals(false, payload.history.isAmendmentQuote);
        System.assertEquals(0, payload.workingLines.size());
        System.assertEquals('Studio Non-Amend Quote', payload.quoteName);
        System.assertNotEquals(null, payload.quoteNumber);
    }

    @isTest
    static void searchCatalogProducts_shortTerm_returnsEmptyOrCommon() {
        Account acct = new Account(Name = 'Search Acct');
        insert acct;
        Opportunity opp = new Opportunity(
            Name = 'Search Opp',
            AccountId = acct.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Quote q = new Quote(
            Name = 'Search Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft'
        );
        insert q;

        Product2 prod = new Product2(
            Name = 'Studio Common Widget ZZ',
            IsActive = true,
            StockKeepingUnit = 'RLM-STUDIO-TEST-COMMON',
            ProductCode = 'RLM-STUDIO-TEST-COMMON'
        );
        insert prod;
        insert new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(),
            Product2Id = prod.Id,
            UnitPrice = 100,
            IsActive = true
        );

        Test.startTest();
        List<RLM_AssetPriceHistoryController.CatalogProductHit> commonHits =
            RLM_AssetPriceHistoryController.searchCatalogProducts(q.Id, '');
        List<RLM_AssetPriceHistoryController.CatalogProductHit> oneChar =
            RLM_AssetPriceHistoryController.searchCatalogProducts(q.Id, 'a');
        List<RLM_AssetPriceHistoryController.CatalogProductHit> named =
            RLM_AssetPriceHistoryController.searchCatalogProducts(q.Id, 'Studio Common Widget ZZ');
        Test.stopTest();

        System.assert(commonHits.size() >= 1, 'Blank term seeds common products');
        Boolean sawCommonFlag = false;
        for (RLM_AssetPriceHistoryController.CatalogProductHit h : commonHits) {
            if (h.isCommon == true) {
                sawCommonFlag = true;
                break;
            }
        }
        System.assertEquals(true, sawCommonFlag, 'Common rail marks hits as isCommon');
        System.assert(oneChar.size() >= 1, 'Short term still shows common rail seed');
        System.assert(named.size() >= 1, 'Name search finds the product');
        System.assertEquals(false, named[0].isCommon);
    }

    private class WaterfallHttpMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setStatusCode(200);
            res.setBody(
                '{"success":true,"executionId":"exec1","lineItemId":"line1","waterfall":['
                    + '{"sequence":1,"hideWaterfall":false,'
                    + '"pricingElement":{"elementType":"ListPrice","name":"Get base prices","adjustments":[]},'
                    + '"outputParameters":{"ListPrice":100}},'
                    + '{"sequence":2,"hideWaterfall":false,'
                    + '"pricingElement":{"elementType":"AssignmentElement","name":"Assign date","adjustments":[]},'
                    + '"outputParameters":{}},'
                    + '{"sequence":3,"hideWaterfall":false,'
                    + '"pricingElement":{"elementType":"ManualDiscount","name":"Percentage discount",'
                    + '"adjustments":[{"AdjustmentType":"Percentage","AdjustmentValue":10}]},'
                    + '"outputParameters":{"NetUnitPrice":90}}'
                    + ']}'
            );
            return res;
        }
    }

    @isTest
    static void getLinePricingWaterfall_parsesPlatformSteps() {
        Account acct = new Account(Name = 'Waterfall Acct');
        insert acct;
        Opportunity opp = new Opportunity(
            Name = 'Waterfall Opp',
            AccountId = acct.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Quote q = new Quote(
            Name = 'Waterfall Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft'
        );
        insert q;
        Product2 prod = new Product2(
            Name = 'Waterfall Product',
            IsActive = true,
            StockKeepingUnit = 'RLM-STUDIO-WF-TEST',
            ProductCode = 'RLM-STUDIO-WF-TEST'
        );
        insert prod;
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(),
            Product2Id = prod.Id,
            UnitPrice = 100,
            IsActive = true
        );
        insert pbe;
        QuoteLineItem qli = new QuoteLineItem(
            QuoteId = q.Id,
            PricebookEntryId = pbe.Id,
            Quantity = 1,
            UnitPrice = 100
        );
        insert qli;

        RLM_AssetPriceHistoryController.testWaterfallIdentifierOverride =
            String.valueOf(qli.Id) + ':exec1';
        Test.setMock(HttpCalloutMock.class, new WaterfallHttpMock());
        Test.startTest();
        RLM_AssetPriceHistoryController.PlatformWaterfallResponse resp =
            RLM_AssetPriceHistoryController.getLinePricingWaterfall(qli.Id);
        Test.stopTest();
        RLM_AssetPriceHistoryController.testWaterfallIdentifierOverride = null;

        System.assertEquals(
            true,
            resp.success,
            'waterfall failed: ' + String.valueOf(resp.message)
        );
        System.assert(resp.steps.size() >= 2, 'Assignment steps filtered; list+discount remain');
        Boolean sawDiscount = false;
        for (RLM_AssetPriceHistoryController.PlatformWaterfallStep s : resp.steps) {
            if (s.isAdjustment == true) {
                sawDiscount = true;
            }
        }
        System.assertEquals(true, sawDiscount, 'Expected a ManualDiscount adjustment step');
    }

    @isTest
    static void removeWorkingLine_rejectsNull() {
        Boolean threw = false;
        try {
            RLM_AssetPriceHistoryController.removeWorkingLine(null, null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Null ids must raise AuraHandledException');
    }

    @isTest
    static void repriceQuote_rejectsNull() {
        Boolean threw = false;
        try {
            RLM_AssetPriceHistoryController.repriceQuote(null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Null quote Id must raise AuraHandledException');
    }

    @isTest
    static void updateWorkingLineQuantity_rejectsInvalidQty() {
        Account acct = new Account(Name = 'Qty Update Acct');
        insert acct;
        Opportunity opp = new Opportunity(
            Name = 'Qty Update Opp',
            AccountId = acct.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Quote q = new Quote(
            Name = 'Qty Update Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft'
        );
        insert q;

        Boolean threw = false;
        try {
            RLM_AssetPriceHistoryController.updateWorkingLineQuantity(q.Id, q.Id, -1, null, null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Negative quantity must raise AuraHandledException');
    }

    @isTest
    static void updateWorkingLineQuantity_rejectsMissingLine() {
        Account acct = new Account(Name = 'Qty Missing Line Acct');
        insert acct;
        Opportunity opp = new Opportunity(
            Name = 'Qty Missing Line Opp',
            AccountId = acct.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Quote q = new Quote(
            Name = 'Qty Missing Line Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft'
        );
        insert q;

        // Valid Quote Id shape but not a QuoteLineItem on this quote
        Boolean threw = false;
        try {
            RLM_AssetPriceHistoryController.updateWorkingLineQuantity(q.Id, q.Id, 10, null, null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Non-line Id must raise AuraHandledException');
    }
}
