@IsTest
private class RLM_RampTransactionActionTest {

    @IsTest
    static void savePlanRejectsBlankQuote() {
        RLM_RampTransactionAction.Result r =
            RLM_RampTransactionAction.savePlan('not-an-id', '{}');
        System.assertEquals(false, r.success);
        System.assert(r.message.contains('Quote Id'), r.message);
    }

    @IsTest
    static void executeRejectsBlankQuote() {
        RLM_RampTransactionAction.Request req = new RLM_RampTransactionAction.Request();
        req.action = 'ApplyPlan';
        req.quoteId = 'not-an-id';
        List<RLM_RampTransactionAction.Result> results =
            RLM_RampTransactionAction.execute(new List<RLM_RampTransactionAction.Request>{ req });
        System.assertEquals(false, results[0].success);
        System.assert(results[0].message.contains('Quote Id'), results[0].message);
    }

    @IsTest
    static void executeRejectsEmptyList() {
        List<RLM_RampTransactionAction.Result> results =
            RLM_RampTransactionAction.execute(new List<RLM_RampTransactionAction.Request>());
        System.assertEquals(false, results[0].success);
    }

    @IsTest
    static void applyPlanRejectsEmptySegments() {
        Account a = new Account(Name = 'Ramp Test');
        insert a;
        Opportunity o = new Opportunity(
            Name = 'Ramp Opp', AccountId = a.Id, StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30));
        insert o;
        Quote q = new Quote(
            Name = 'Ramp Quote', OpportunityId = o.Id, Status = 'Draft');
        insert q;

        RLM_RampTransactionAction.Request req = new RLM_RampTransactionAction.Request();
        req.action = 'ApplyPlan';
        req.quoteId = q.Id;
        req.planJson = '{"scheduleName":"Empty","segments":[]}';
        RLM_RampTransactionAction.Result r = RLM_RampTransactionAction.run(req);
        System.assertEquals(false, r.success);
        System.assert(r.message.contains('segment'), r.message);
    }

    @IsTest
    static void parsePlanReadsGrid() {
        String json = '{"scheduleName":"3 Year Ramp Schedule","segmentType":"Annual",'
            + '"segments":[{"key":"s0","name":"Year 1","type":"Yearly","startDate":"2026-11-01",'
            + '"endDate":"2027-10-31","discount":0,"uplift":0}],'
            + '"products":[{"pricebookEntryId":"01u000000000001AAA","cells":{"s0":'
            + '{"quantity":5,"adjustment":10,"adjustmentKind":"Discount"}}}]}';
        RLM_RampTransactionAction.Plan plan = RLM_RampTransactionAction.parsePlan(json);
        System.assertEquals('3 Year Ramp Schedule', plan.scheduleName);
        System.assertEquals(1, plan.segments.size());
        System.assertEquals(5, plan.products[0].cells.get('s0').quantity);
        System.assertEquals('Yearly', RLM_RampTransactionAction.segmentTypeValue('Yearly', 'Annual'));
        System.assertEquals('Custom', RLM_RampTransactionAction.segmentTypeValue('Trial', 'Annual'));
        System.assertEquals(null, RLM_RampTransactionAction.toId('abc'));
        System.assertEquals(null, RLM_RampTransactionAction.parsePlan(''));
    }

    @IsTest
    static void startConfigurationRejectsBlankQuote() {
        RLM_RampTransactionAction.ConfigureResult r =
            RLM_RampTransactionAction.startConfiguration('not-an-id', null, null, null);
        System.assertEquals(false, r.success);
        System.assert(r.message.contains('Quote Id'), r.message);
    }

    @IsTest
    static void startConfigurationRejectsBlankPricebookEntry() {
        Account a = new Account(Name = 'Ramp Config Test');
        insert a;
        Opportunity o = new Opportunity(
            Name = 'Ramp Config Opp', AccountId = a.Id, StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30));
        insert o;
        Quote q = new Quote(
            Name = 'Ramp Config Quote', OpportunityId = o.Id, Status = 'Draft');
        insert q;
        RLM_RampTransactionAction.ConfigureResult r =
            RLM_RampTransactionAction.startConfiguration(q.Id, 'not-an-id', null, null);
        System.assertEquals(false, r.success);
        System.assert(r.message.contains('Price book'), r.message);
    }

    @IsTest
    static void browseCatalogRejectsBlankQuote() {
        RLM_RampTransactionAction.CatalogResult r =
            RLM_RampTransactionAction.browseCatalog('not-an-id', null, null);
        System.assertEquals(false, r.success);
        System.assert(r.message.contains('Quote Id'), r.message);
    }

    @IsTest
    static void parseDiscoveryResultsReadsDefaultPrice() {
        Map<String, Object> output = new Map<String, Object>{
            'results' => new List<Object>{
                new Map<String, Object>{
                    'id' => '01t000000000001AAA',
                    'name' => 'Additional API',
                    'productCode' => 'QB-API',
                    'displayUrl' => '/resource/add_api',
                    'nodeType' => 'bundleProduct',
                    'configureDuringSale' => 'Allowed',
                    'qualificationContext' => new Map<String, Object>{ 'isQualified' => true },
                    'prices' => new List<Object>{
                        new Map<String, Object>{
                            'priceBookId' => '01s000000000001AAA',
                            'priceBookEntryId' => '01u000000000001AAA',
                            'price' => 15000,
                            'isDefault' => true,
                            'pricingModel' => new Map<String, Object>{ 'name' => 'Term Annual' }
                        },
                        new Map<String, Object>{
                            'priceBookId' => '01s000000000001AAA',
                            'priceBookEntryId' => '01u000000000002AAA',
                            'price' => 2000,
                            'isDefault' => false
                        }
                    }
                }
            }
        };
        List<RLM_RampTransactionAction.CatalogProduct> products =
            RLM_RampTransactionAction.parseDiscoveryResults(
                output, (Id) '01s000000000001AAA');
        System.assertEquals(1, products.size());
        System.assertEquals('01u000000000001AAA', products[0].pricebookEntryId);
        System.assertEquals(15000, products[0].listPrice);
        System.assertEquals('QB-API', products[0].sku);
        System.assertEquals(true, products[0].qualified);
        System.assertEquals('Term Annual', products[0].sellingModel);
        System.assertEquals('/resource/add_api', products[0].displayUrl);
        System.assertEquals(true, products[0].configurable);
        System.assertEquals('bundleProduct', products[0].nodeType);
        System.assertEquals(2, products[0].sellingModels.size());
        System.assertEquals('01u000000000002AAA', products[0].sellingModels[1].pricebookEntryId);
        System.assertEquals(0, RLM_RampTransactionAction.parseDiscoveryResults(null, null).size());
    }

    @IsTest
    static void browseCatalogReturnsStructuredResult() {
        Account a = new Account(Name = 'Ramp Catalog Test');
        insert a;
        Opportunity o = new Opportunity(
            Name = 'Ramp Catalog Opp', AccountId = a.Id, StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30));
        insert o;
        Quote q = new Quote(
            Name = 'Ramp Catalog Quote', OpportunityId = o.Id, Status = 'Draft');
        insert q;

        Test.startTest();
        RLM_RampTransactionAction.CatalogResult r =
            RLM_RampTransactionAction.browseCatalog(q.Id, null, null);
        Test.stopTest();
        System.assertNotEquals(null, r);
        System.assertNotEquals(null, r.products);
        System.assertNotEquals(null, r.catalogs);
    }

    @IsTest
    static void graphActionRequiresPayload() {
        Account a = new Account(Name = 'Ramp Test 2');
        insert a;
        Opportunity o = new Opportunity(
            Name = 'Ramp Opp 2', AccountId = a.Id, StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30));
        insert o;
        Quote q = new Quote(
            Name = 'Ramp Quote 2', OpportunityId = o.Id, Status = 'Draft');
        insert q;

        RLM_RampTransactionAction.Request req = new RLM_RampTransactionAction.Request();
        req.action = 'EditGroup';
        req.quoteId = q.Id;
        RLM_RampTransactionAction.Result r = RLM_RampTransactionAction.run(req);
        System.assertEquals(false, r.success);
        System.assert(r.message.contains('Graph JSON'), r.message);
    }
}
