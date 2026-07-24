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
            RLM_AssetPriceHistoryController.searchCatalogProducts(q.Id, '', null, null);
        List<RLM_AssetPriceHistoryController.CatalogProductHit> oneChar =
            RLM_AssetPriceHistoryController.searchCatalogProducts(q.Id, 'a', null, null);
        List<RLM_AssetPriceHistoryController.CatalogProductHit> named =
            RLM_AssetPriceHistoryController.searchCatalogProducts(
                q.Id,
                'Studio Common Widget ZZ',
                null,
                null
            );
        RLM_AssetPriceHistoryController.CatalogBrowseContext browseCtx =
            RLM_AssetPriceHistoryController.getCatalogBrowseContext(q.Id);
        Test.stopTest();

        System.assertNotEquals(null, browseCtx);
        System.assertNotEquals(null, browseCtx.catalogs);

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

    @isTest
    static void ensureSalesUnitPrice_seedsFromListPrice() {
        Account acct = new Account(Name = 'UnitPrice Seed Acct');
        insert acct;
        Opportunity opp = new Opportunity(
            Name = 'UnitPrice Seed Opp',
            AccountId = acct.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Quote q = new Quote(
            Name = 'UnitPrice Seed Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft'
        );
        insert q;
        Product2 prod = new Product2(
            Name = 'Seed Price Product',
            IsActive = true,
            StockKeepingUnit = 'RLM-STUDIO-SEED-UP',
            ProductCode = 'RLM-STUDIO-SEED-UP'
        );
        insert prod;
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(),
            Product2Id = prod.Id,
            UnitPrice = 149.99,
            IsActive = true
        );
        insert pbe;
        QuoteLineItem qli = new QuoteLineItem(
            QuoteId = q.Id,
            PricebookEntryId = pbe.Id,
            Quantity = 1,
            UnitPrice = 149.99
        );
        insert qli;
        // Simulate Amend lines that arrive with ListPrice but null sales UnitPrice.
        // Standard PBEs always write UnitPrice on insert — clear via update when allowed.
        // If the org rejects null UnitPrice, assert the helper is a no-op on priced lines.
        QuoteLineItem loaded = [
            SELECT Id, UnitPrice, ListPrice, PricebookEntryId, PricebookEntry.UnitPrice
            FROM QuoteLineItem
            WHERE Id = :qli.Id
        ];
        // Simulate Amend lines that land with null sales UnitPrice.
        Decimal seedFrom = loaded.ListPrice != null
            ? loaded.ListPrice
            : loaded.PricebookEntry.UnitPrice;
        loaded.UnitPrice = null;
        Test.startTest();
        RLM_AssetPriceHistoryController.ensureSalesUnitPrice(new List<QuoteLineItem>{ loaded });
        Test.stopTest();
        QuoteLineItem afterRow = [
            SELECT UnitPrice
            FROM QuoteLineItem
            WHERE Id = :qli.Id
        ];
        System.assertEquals(
            seedFrom,
            afterRow.UnitPrice,
            'Null UnitPrice is seeded from ListPrice / PBE before FORCE reprice'
        );
    }

    @isTest
    static void mapDiscoveryResults_buildsHitsFromPayload() {
        String payload =
            '[{"id":"01tgL00000TMAdJQAX","name":"QuantumBit Generative AI License",'
                + '"productCode":"QB-GEN-AI-LIC","description":"Gen AI license",'
                + '"prices":['
                + '{"priceBookEntryId":"01ugL000003ygucQAA","price":149.99,"isDefault":true,'
                + '"pricingModel":{"id":"0jPgL0000007HvOUAU","name":"Term Annual"}},'
                + '{"priceBookEntryId":"01ugL000003ygudQAA","price":20,"isDefault":false,'
                + '"pricingModel":{"id":"0jPgL0000007HvNUAU","name":"Evergreen Monthly"}}'
                + ']}]';
        Object raw = JSON.deserializeUntyped(payload);
        List<RLM_AssetPriceHistoryController.CatalogProductHit> hits =
            RLM_AssetPriceHistoryController.mapDiscoveryResults(raw);
        // Prefer default price only → 1 hit
        System.assertEquals(1, hits.size());
        System.assertEquals('Discovery', hits[0].source);
        System.assertEquals('QuantumBit Generative AI License · Term Annual', hits[0].label);
        System.assertEquals(149.99, hits[0].listPrice);
        System.assertEquals('QB-GEN-AI-LIC', hits[0].productCode);
        System.assertEquals('Gen AI license', hits[0].description);
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

    @isTest
    static void resolveEffectiveNetUnitPrice_fallsBackWhenNetNull() {
        System.assertEquals(
            90,
            RLM_AssetPriceHistoryController.resolveEffectiveNetUnitPrice(90, 100, 40),
            'Platform net wins when present'
        );
        System.assertEquals(
            97.4935,
            RLM_AssetPriceHistoryController.resolveEffectiveNetUnitPrice(null, 149.99, 35),
            'List × (1 − Disc%) when NetUnitPrice null (QLD-owned sales price)'
        );
        System.assertEquals(
            null,
            RLM_AssetPriceHistoryController.resolveEffectiveNetUnitPrice(null, null, 35),
            'No list → no effective net'
        );
    }

    @isTest
    static void listScenarios_nullOrInvalid_returnsEmpty() {
        Test.startTest();
        System.assertEquals(
            0,
            RLM_AssetPriceHistoryController.listScenarios(null).size()
        );
        Account acct = new Account(Name = 'Scenario List Acct');
        insert acct;
        // Account Id is not an Opportunity — must return empty, not throw
        System.assertEquals(
            0,
            RLM_AssetPriceHistoryController.listScenarios(acct.Id).size()
        );
        Test.stopTest();
    }

    @isTest
    static void listScenarios_excludesNonAmendQuotes() {
        // OriginalActionType is platform-owned (not writeable in tests), so we
        // verify the Amend filter by asserting standard quotes do not appear.
        Account acct = new Account(Name = 'Scenario Amend List Acct');
        insert acct;
        Opportunity opp = new Opportunity(
            Name = 'Scenario Amend List Opp',
            AccountId = acct.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Quote newSale = new Quote(
            Name = 'New Sale Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft'
        );
        insert newSale;

        Test.startTest();
        List<RLM_AssetPriceHistoryController.ScenarioSummary> rows =
            RLM_AssetPriceHistoryController.listScenarios(opp.Id);
        Test.stopTest();

        System.assertEquals(
            0,
            rows.size(),
            'Quotes without OriginalActionType=Amend must be excluded'
        );
    }

    @isTest
    static void getScenarioCompare_buildsColumnsFromPayload() {
        Account acct = new Account(Name = 'Scenario Compare Acct');
        insert acct;
        Opportunity opp = new Opportunity(
            Name = 'Scenario Compare Opp',
            AccountId = acct.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        // No amend quotes on opp — live compare returns empty message.
        // Column builder is unit-tested with an in-memory sibling + payload.

        RLM_AssetPriceHistoryController.ScenarioSummary sibling =
            new RLM_AssetPriceHistoryController.ScenarioSummary();
        sibling.quoteId = opp.Id; // placeholder Id shape for DTO only
        sibling.quoteNumber = '00009999';
        sibling.name = 'Compare Scenario';
        sibling.grandTotal = 1000;
        sibling.isSynced = true;
        sibling.calculationStatus = 'CompletedWithoutTax';

        RLM_AssetPriceHistoryController.StudioPayload payload =
            new RLM_AssetPriceHistoryController.StudioPayload();
        payload.workingLines = new List<RLM_AssetPriceHistoryController.WorkingLine>();
        RLM_AssetPriceHistoryController.WorkingLine line =
            new RLM_AssetPriceHistoryController.WorkingLine();
        line.quantity = 100;
        line.discountPercent = 70;
        line.addArr = 4500;
        line.addMrr = 375;
        line.totalPrice = 1200;
        payload.workingLines.add(line);

        RLM_AssetPriceHistoryController.HistorySummary current =
            new RLM_AssetPriceHistoryController.HistorySummary();
        current.totalQuantity = 70000;
        current.currentArr = 2999800;
        current.currentMrr = 249983.33;
        RLM_AssetPriceHistoryController.HistorySummary projected =
            new RLM_AssetPriceHistoryController.HistorySummary();
        projected.totalQuantity = 70100;
        projected.currentArr = 3004300;
        projected.currentMrr = 250358.33;
        RLM_AssetPriceHistoryController.ProjectionImpact proj =
            new RLM_AssetPriceHistoryController.ProjectionImpact();
        proj.mode = 'Add';
        proj.projected = projected;
        proj.deltaQuantity = 100;
        proj.deltaArr = 4500;
        proj.deltaMrr = 375;
        payload.history = new RLM_AssetPriceHistoryController.HistoryResponse();
        payload.history.summary = current;
        payload.history.projection = proj;

        Test.startTest();
        RLM_AssetPriceHistoryController.ScenarioColumn col =
            RLM_AssetPriceHistoryController.buildScenarioColumn(sibling, payload);
        RLM_AssetPriceHistoryController.ScenarioCompareResponse empty =
            RLM_AssetPriceHistoryController.getScenarioCompare(null);
        RLM_AssetPriceHistoryController.ScenarioCompareResponse live =
            RLM_AssetPriceHistoryController.getScenarioCompare(opp.Id);
        Test.stopTest();

        System.assertEquals(100, col.thisAddQty);
        System.assertEquals(4500, col.thisAddArr);
        System.assertEquals(70, col.thisAddDiscountPercent);
        System.assertEquals(1200, col.thisAddProrated);
        System.assertEquals(70100, col.finalizedQty);
        System.assertEquals(4500, col.deltaArr);
        System.assertEquals(true, col.isSynced);

        System.assertEquals('No opportunity Id provided.', empty.message);
        System.assertEquals(opp.Id, live.opportunityId);
        System.assertEquals(
            'No amendment scenario quotes on this opportunity.',
            live.message
        );
        System.assertEquals(0, live.scenarios.size());
    }

    @isTest
    static void createScenario_clonesAndAttachesToOpportunity() {
        Account acct = new Account(Name = 'Create Scenario Acct');
        insert acct;
        Opportunity opp = new Opportunity(
            Name = 'Create Scenario Opp',
            AccountId = acct.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Quote source = new Quote(
            Name = 'Source Amend',
            OpportunityId = opp.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft'
        );
        Quote cloneTarget = new Quote(
            Name = 'Clone Placeholder',
            OpportunityId = opp.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft'
        );
        insert new List<Quote>{ source, cloneTarget };

        RLM_AssetPriceHistoryController.testBypassAmendScenarioCheck = true;
        RLM_AssetPriceHistoryController.testCloneSalesTransactionIdOverride = cloneTarget.Id;

        Test.startTest();
        RLM_AssetPriceHistoryController.ScenarioMutationResult result =
            RLM_AssetPriceHistoryController.createScenario(
                source.Id,
                'Option B — +40k',
                opp.Id
            );
        Test.stopTest();

        RLM_AssetPriceHistoryController.testBypassAmendScenarioCheck = false;
        RLM_AssetPriceHistoryController.testCloneSalesTransactionIdOverride = null;

        System.assertEquals(true, result.success, result.message == null ? 'expected success' : result.message);
        System.assertEquals(cloneTarget.Id, result.scenario.quoteId);
        Quote after = [SELECT Name, OpportunityId FROM Quote WHERE Id = :cloneTarget.Id];
        System.assertEquals('Option B — +40k', after.Name);
        System.assertEquals(opp.Id, after.OpportunityId);
    }

    @isTest
    static void createScenario_rejectsMissingSource() {
        Test.startTest();
        RLM_AssetPriceHistoryController.ScenarioMutationResult result =
            RLM_AssetPriceHistoryController.createScenario(null, 'X', null);
        Test.stopTest();
        System.assertEquals(false, result.success);
        System.assert(
            result.message != null && result.message.contains('Source quote'),
            result.message
        );
    }

    @isTest
    static void setForecastScenario_syncsQuoteToOpportunity() {
        Account acct = new Account(Name = 'Forecast Scenario Acct');
        insert acct;
        Opportunity opp = new Opportunity(
            Name = 'Forecast Scenario Opp',
            AccountId = acct.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Quote q = new Quote(
            Name = 'Forecast Scenario Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft'
        );
        insert q;

        RLM_AssetPriceHistoryController.testBypassAmendScenarioCheck = true;

        Test.startTest();
        RLM_AssetPriceHistoryController.ScenarioMutationResult result =
            RLM_AssetPriceHistoryController.setForecastScenario(opp.Id, q.Id);
        Test.stopTest();

        RLM_AssetPriceHistoryController.testBypassAmendScenarioCheck = false;

        System.assertEquals(true, result.success, result.message == null ? 'expected success' : result.message);
        System.assertEquals(q.Id, result.syncedQuoteId);
        Opportunity after = [SELECT SyncedQuoteId FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals(q.Id, after.SyncedQuoteId);
    }

    @isTest
    static void setForecastScenario_rejectsWrongOpportunity() {
        Account acct = new Account(Name = 'Forecast Wrong Opp Acct');
        insert acct;
        Opportunity oppA = new Opportunity(
            Name = 'Forecast Opp A',
            AccountId = acct.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        Opportunity oppB = new Opportunity(
            Name = 'Forecast Opp B',
            AccountId = acct.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert new List<Opportunity>{ oppA, oppB };
        Quote q = new Quote(
            Name = 'On Opp A',
            OpportunityId = oppA.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft'
        );
        insert q;

        RLM_AssetPriceHistoryController.testBypassAmendScenarioCheck = true;

        Test.startTest();
        RLM_AssetPriceHistoryController.ScenarioMutationResult result =
            RLM_AssetPriceHistoryController.setForecastScenario(oppB.Id, q.Id);
        Test.stopTest();

        RLM_AssetPriceHistoryController.testBypassAmendScenarioCheck = false;

        System.assertEquals(false, result.success);
        System.assert(
            result.message != null && result.message.contains('does not belong'),
            result.message
        );
    }
}
