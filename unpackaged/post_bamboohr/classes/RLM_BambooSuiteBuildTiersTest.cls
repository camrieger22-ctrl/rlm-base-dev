@IsTest
private class RLM_BambooSuiteBuildTiersTest {
    private static Opportunity makeOpp() {
        Account a = new Account(Name = 'Suite Tiers Co');
        insert a;
        Opportunity opp = new Opportunity(
            Name = 'Tier Build Opp',
            AccountId = a.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Pricebook2Id = Test.getStandardPricebookId()
        );
        insert opp;
        return opp;
    }

    @IsTest
    static void build_ensureOnly_returnsABC() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.openFromOpportunity(opp.Id);

        RLM_BambooSuiteBuildTiers.Request req = new RLM_BambooSuiteBuildTiers.Request();
        req.opportunityId = opp.Id;
        // blank tierKey = ensure only

        Test.startTest();
        List<RLM_BambooSuiteBuildTiers.Result> results = RLM_BambooSuiteBuildTiers.build(
            new List<RLM_BambooSuiteBuildTiers.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(true, results[0].isSuccess);
        System.assertNotEquals(null, results[0].goodQuoteId);
        System.assertNotEquals(null, results[0].betterQuoteId);
        System.assertNotEquals(null, results[0].bestQuoteId);
        System.assert(results[0].summary.contains('Fill each tier'), results[0].summary);
    }

    @IsTest
    static void build_rejectsBlankOpportunity() {
        RLM_BambooSuiteBuildTiers.Request req = new RLM_BambooSuiteBuildTiers.Request();
        req.opportunityId = '';

        List<RLM_BambooSuiteBuildTiers.Result> results = RLM_BambooSuiteBuildTiers.build(
            new List<RLM_BambooSuiteBuildTiers.Request>{ req }
        );

        System.assertEquals(false, results[0].isSuccess);
        System.assert(results[0].errorMessage.contains('opportunityId'));
    }

    @IsTest(SeeAllData=true)
    static void build_fillGood_whenCatalogPresent() {
        List<RLM_BambooRevenueSuite.CatalogProductDTO> catalog = RLM_BambooRevenueSuite.getCatalog(
            'USD'
        );
        Boolean hasCore = false;
        for (RLM_BambooRevenueSuite.CatalogProductDTO p : catalog) {
            if (p.sku == 'BAMBOO-CORE') {
                hasCore = true;
                break;
            }
        }
        if (!hasCore) {
            return;
        }

        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.openFromOpportunity(opp.Id);

        RLM_BambooSuiteBuildTiers.Request req = new RLM_BambooSuiteBuildTiers.Request();
        req.opportunityId = opp.Id;
        req.tierKey = 'Good';
        req.seatCount = 40;
        req.termMonths = 12;
        req.billingFrequency = 'Monthly';

        Test.startTest();
        List<RLM_BambooSuiteBuildTiers.Result> results = RLM_BambooSuiteBuildTiers.build(
            new List<RLM_BambooSuiteBuildTiers.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(
            true,
            results[0].isSuccess,
            'fill Good failed: ' + String.valueOf(results[0].errorMessage)
        );
        System.assertEquals(results[0].goodQuoteId, results[0].filledQuoteId);
        System.assertNotEquals(null, results[0].summary);
    }
}
