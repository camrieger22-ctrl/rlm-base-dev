@IsTest
private class RLM_BambooSuiteUpdateSeatsTest {
    private static Opportunity makeOpp() {
        Account acct = new Account(Name = 'Suite Update Seats Test');
        insert acct;
        Opportunity opp = new Opportunity(
            Name = 'Suite Update Seats Opp',
            AccountId = acct.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        return opp;
    }

    @IsTest
    static void updateSeats_requiresSeatCount() {
        RLM_BambooSuiteUpdateSeats.Request req = new RLM_BambooSuiteUpdateSeats.Request();
        req.opportunityId = '006000000000000AAA';
        req.optionLabel = 'Good';

        Test.startTest();
        RLM_BambooSuiteUpdateSeats.Result res = RLM_BambooSuiteUpdateSeats.updateOne(req);
        Test.stopTest();

        System.assertEquals(false, res.isSuccess);
        System.assert(res.errorMessage.contains('seatCount'));
    }

    @IsTest
    static void updateSeats_requiresQuoteOrOppLabel() {
        RLM_BambooSuiteUpdateSeats.Request req = new RLM_BambooSuiteUpdateSeats.Request();
        req.seatCount = 100;

        Test.startTest();
        RLM_BambooSuiteUpdateSeats.Result res = RLM_BambooSuiteUpdateSeats.updateOne(req);
        Test.stopTest();

        System.assertEquals(false, res.isSuccess);
        System.assert(res.summary.contains('Could not update seats'));
    }

    @IsTest(SeeAllData=true)
    static void updateSeats_whenCatalogPresent() {
        List<RLM_BambooRevenueSuite.CatalogProductDTO> catalog = RLM_BambooRevenueSuite.getCatalog(
            'USD'
        );
        if (catalog.isEmpty()) {
            return;
        }
        String sku = catalog[0].sku;
        for (RLM_BambooRevenueSuite.CatalogProductDTO p : catalog) {
            if (p.sku == 'BAMBOO-CORE') {
                sku = p.sku;
                break;
            }
        }

        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );
        RLM_BambooRevenueSuite.addProductLine(session.quoteId, sku, 10, 12, null, null);

        RLM_BambooSuiteUpdateSeats.Request req = new RLM_BambooSuiteUpdateSeats.Request();
        req.quoteId = String.valueOf(session.quoteId);
        req.seatCount = 75;

        Test.startTest();
        RLM_BambooSuiteUpdateSeats.Result res = RLM_BambooSuiteUpdateSeats.updateOne(req);
        Test.stopTest();

        System.assertEquals(true, res.isSuccess, res.errorMessage);
        System.assertNotEquals(null, res.quoteId);
        System.assert(res.summary.contains('75 seats'));

        RLM_BambooRevenueSuite.OptionDetailDTO detail = RLM_BambooRevenueSuite.getOptionDetail(
            session.quoteId
        );
        System.assertEquals(1, detail.lines.size());
        System.assertEquals(75, detail.lines[0].quantity);
    }
}
