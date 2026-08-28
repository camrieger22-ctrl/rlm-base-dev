@IsTest
private class RLM_BambooSuiteApplyCommercialTermsTest {
    private static Opportunity makeOpp() {
        Account a = new Account(Name = 'Commercial Terms Co');
        insert a;
        Opportunity opp = new Opportunity(
            Name = 'Commercial Terms Opp',
            AccountId = a.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Pricebook2Id = Test.getStandardPricebookId()
        );
        insert opp;
        return opp;
    }

    @IsTest
    static void apply_rejectsMissingInputs() {
        RLM_BambooSuiteApplyCommercialTerms.Request req =
            new RLM_BambooSuiteApplyCommercialTerms.Request();
        req.opportunityId = '';

        List<RLM_BambooSuiteApplyCommercialTerms.Result> results =
            RLM_BambooSuiteApplyCommercialTerms.apply(
                new List<RLM_BambooSuiteApplyCommercialTerms.Request>{ req }
            );

        System.assertEquals(false, results[0].isSuccess);
        System.assert(results[0].errorMessage.contains('opportunityId'));
    }

    @IsTest
    static void apply_rejectsWhenNoTermOrBilling() {
        Opportunity opp = makeOpp();
        RLM_BambooSuiteApplyCommercialTerms.Request req =
            new RLM_BambooSuiteApplyCommercialTerms.Request();
        req.opportunityId = opp.Id;

        List<RLM_BambooSuiteApplyCommercialTerms.Result> results =
            RLM_BambooSuiteApplyCommercialTerms.apply(
                new List<RLM_BambooSuiteApplyCommercialTerms.Request>{ req }
            );

        System.assertEquals(false, results[0].isSuccess);
        System.assert(results[0].errorMessage.contains('termMonths'));
    }

    @IsTest
    static void apply_updatesAllOptionsWhenOnlyBilling() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.openFromOpportunity(opp.Id);
        RLM_BambooRevenueSuite.addOption(opp.Id);

        RLM_BambooSuiteApplyCommercialTerms.Request req =
            new RLM_BambooSuiteApplyCommercialTerms.Request();
        req.opportunityId = opp.Id;
        req.billingFrequency = 'Annual';

        Test.startTest();
        List<RLM_BambooSuiteApplyCommercialTerms.Result> results =
            RLM_BambooSuiteApplyCommercialTerms.apply(
                new List<RLM_BambooSuiteApplyCommercialTerms.Request>{ req }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess, results[0].errorMessage);
        System.assertEquals(2, results[0].optionsUpdated);
        System.assert(results[0].summary.contains('Quantities unchanged'));
    }

    @IsTest(SeeAllData=true)
    static void apply_termAndBillingPreservesQtyWhenPriced() {
        List<RLM_BambooRevenueSuite.CatalogProductDTO> catalog =
            RLM_BambooRevenueSuite.getCatalog('USD');
        if (catalog.isEmpty()) {
            return;
        }
        String sku = catalog[0].sku;
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session =
            RLM_BambooRevenueSuite.openFromOpportunity(opp.Id);
        Decimal seats = 1000;
        RLM_BambooRevenueSuite.addProductLine(
            session.quoteId,
            sku,
            seats,
            12,
            null,
            null
        );
        RLM_BambooRevenueSuite.addOption(opp.Id);

        RLM_BambooSuiteApplyCommercialTerms.Request req =
            new RLM_BambooSuiteApplyCommercialTerms.Request();
        req.opportunityId = opp.Id;
        req.termMonths = 36;
        req.billingFrequency = 'Annual';

        Test.startTest();
        List<RLM_BambooSuiteApplyCommercialTerms.Result> results =
            RLM_BambooSuiteApplyCommercialTerms.apply(
                new List<RLM_BambooSuiteApplyCommercialTerms.Request>{ req }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess, results[0].errorMessage);
        System.assertEquals(2, results[0].optionsUpdated);

        RLM_BambooRevenueSuite.OptionDetailDTO a =
            RLM_BambooRevenueSuite.getOptionDetail(session.quoteId);
        System.assertEquals(36, a.termMonths);
        System.assertEquals('Annual', a.billingFrequency);
        if (!a.lines.isEmpty()) {
            System.assertEquals(seats, a.lines[0].quantity);
        }
    }
}
