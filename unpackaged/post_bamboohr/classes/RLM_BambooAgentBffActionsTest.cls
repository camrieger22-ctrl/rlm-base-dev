@IsTest
private class RLM_BambooAgentBffActionsTest {
    private class RouteMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            String ep = req.getEndpoint();
            if (ep != null && ep.contains('/api/get-pricing-estimate')) {
                res.setStatusCode(200);
                res.setBody(
                    '{"ok":true,"currency":"USD","planSku":"BAMBOO-PRO","headcount":100,' +
                    '"netPepm":7.65,"monthlyTotal":765,"annualTotal":9180,"volumePercent":10,' +
                    '"pricingSource":"pricingApi","warnings":[]}'
                );
                return res;
            }
            if (ep != null && ep.contains('/api/get-pricing')) {
                res.setStatusCode(200);
                res.setBody(
                    '{"ok":true,"quoteId":"0Q0TEST000000001","quoteUrl":"/quote/0Q0TEST000000001",' +
                    '"accountId":"001TEST000000001","currency":"USD","netPepm":7.65,"monthlyTotal":765}'
                );
                return res;
            }
            if (ep != null && ep.contains('/api/account-console')) {
                res.setStatusCode(200);
                res.setBody(
                    '{"ok":true,"account":{"id":"001TEST000000001","name":"Raymond Inc",' +
                    '"currency":"USD"},"subscription":{"currentQuantity":200,"recurringMonthly":1500}}'
                );
                return res;
            }
            if (ep != null && ep.contains('/api/account-amend-estimate')) {
                res.setStatusCode(200);
                res.setBody(
                    '{"ok":true,"accountId":"001TEST000000001","accountName":"Raymond Inc",' +
                    '"currency":"USD","newQty":260,"monthly":{"today":1500,"after":1800,"difference":300},' +
                    '"dueToday":null}'
                );
                return res;
            }
            if (ep != null && ep.contains('/api/account-amend-preview')) {
                res.setStatusCode(200);
                res.setBody(
                    '{"ok":true,"accountId":"001TEST000000001","accountName":"Raymond Inc",' +
                    '"currency":"USD","dueToday":420.5,"sticky":true,' +
                    '"monthly":{"today":1500,"after":1800,"difference":300},' +
                    '"amendQuotes":[{"quoteId":"0Q0STICKY0000001","assetIds":["02iTEST"]}],' +
                    '"moduleQuoteId":null,' +
                    '"amendQuoteUrl":"/amend-quote/0Q0STICKY0000001"}'
                );
                return res;
            }
            if (ep != null && ep.contains('/api/account-amend-cache')) {
                res.setStatusCode(200);
                res.setBody(
                    '{"ok":true,"id":"0Q0STICKY0000001","amendQuoteUrl":"/amend-quote/0Q0STICKY0000001"}'
                );
                return res;
            }
            res.setStatusCode(404);
            res.setBody('{"ok":false,"error":"unexpected"}');
            return res;
        }
    }

    private static void assertOk(Boolean isSuccess, String errorMessage, String responseJson) {
        System.assert(
            isSuccess == true,
            'Action failed: ' + errorMessage + ' | body=' + responseJson
        );
    }

    @IsTest
    static void estimateGetPricing_ok() {
        Test.setMock(HttpCalloutMock.class, new RouteMock());
        RLM_BambooAgentBffClient.baseUrlOverride = 'https://phase2-test.example.com';
        RLM_BambooAgentEstimateGetPricing.Request req = new RLM_BambooAgentEstimateGetPricing.Request();
        req.headcount = 100;
        req.country = 'US';
        req.planSku = 'BAMBOO-PRO';
        req.addonSkusCsv = 'BAMBOO-ADD-PAYROLL,BAMBOO-ADD-BENEFITS';
        Test.startTest();
        List<RLM_BambooAgentEstimateGetPricing.Result> results =
            RLM_BambooAgentEstimateGetPricing.run(new List<RLM_BambooAgentEstimateGetPricing.Request>{ req });
        Test.stopTest();
        System.assertEquals(1, results.size());
        assertOk(results[0].isSuccess, results[0].errorMessage, results[0].responseJson);
        System.assertEquals(Decimal.valueOf('7.65'), results[0].netPepm);
        System.assert(results[0].summary != null && results[0].summary.contains('PEPM'));
    }

    @IsTest
    static void createQuote_requiresEmail() {
        RLM_BambooAgentCreateGetPricingQuote.Request req = new RLM_BambooAgentCreateGetPricingQuote.Request();
        req.headcount = 50;
        req.company = 'Acme';
        List<RLM_BambooAgentCreateGetPricingQuote.Result> results =
            RLM_BambooAgentCreateGetPricingQuote.run(
                new List<RLM_BambooAgentCreateGetPricingQuote.Request>{ req }
            );
        System.assertEquals(false, results[0].isSuccess);
        System.assert(results[0].errorMessage != null && results[0].errorMessage.contains('email'));
    }

    @IsTest
    static void createQuote_ok() {
        Test.setMock(HttpCalloutMock.class, new RouteMock());
        RLM_BambooAgentBffClient.baseUrlOverride = 'https://phase2-test.example.com';
        RLM_BambooAgentCreateGetPricingQuote.Request req = new RLM_BambooAgentCreateGetPricingQuote.Request();
        req.headcount = 100;
        req.company = 'Acme Demo';
        req.email = 'buyer@example.com';
        Test.startTest();
        List<RLM_BambooAgentCreateGetPricingQuote.Result> results =
            RLM_BambooAgentCreateGetPricingQuote.run(
                new List<RLM_BambooAgentCreateGetPricingQuote.Request>{ req }
            );
        Test.stopTest();
        assertOk(results[0].isSuccess, results[0].errorMessage, results[0].responseJson);
        System.assertEquals('0Q0TEST000000001', results[0].quoteId);
        System.assertEquals(
            'https://phase2-test.example.com/quote/0Q0TEST000000001',
            results[0].quoteUrl
        );
        // Blended PEPM from monthly ÷ headcount (not plan-only BFF netPepm).
        System.assertEquals(Decimal.valueOf('7.65'), results[0].netPepm);
        System.assert(
            results[0].summary != null &&
            results[0].summary.contains('https://phase2-test.example.com/quote/0Q0TEST000000001')
        );
    }

    @IsTest
    static void licensesSummary_ok() {
        Test.setMock(HttpCalloutMock.class, new RouteMock());
        RLM_BambooAgentBffClient.baseUrlOverride = 'https://phase2-test.example.com';
        RLM_BambooAgentGetLicensesSummary.Request req = new RLM_BambooAgentGetLicensesSummary.Request();
        req.accountId = '001TEST000000001';
        Test.startTest();
        List<RLM_BambooAgentGetLicensesSummary.Result> results =
            RLM_BambooAgentGetLicensesSummary.run(
                new List<RLM_BambooAgentGetLicensesSummary.Request>{ req }
            );
        Test.stopTest();
        assertOk(results[0].isSuccess, results[0].errorMessage, results[0].responseJson);
        System.assertEquals(200, results[0].currentQuantity);
        System.assertEquals(Decimal.valueOf(1500), results[0].recurringMonthly);
    }

    @IsTest
    static void estimateAmend_ok() {
        Test.setMock(HttpCalloutMock.class, new RouteMock());
        RLM_BambooAgentBffClient.baseUrlOverride = 'https://phase2-test.example.com';
        RLM_BambooAgentEstimateAmend.Request req = new RLM_BambooAgentEstimateAmend.Request();
        req.accountId = '001TEST000000001';
        req.newQty = 260;
        Test.startTest();
        List<RLM_BambooAgentEstimateAmend.Result> results =
            RLM_BambooAgentEstimateAmend.run(
                new List<RLM_BambooAgentEstimateAmend.Request>{ req }
            );
        Test.stopTest();
        assertOk(results[0].isSuccess, results[0].errorMessage, results[0].responseJson);
        System.assertEquals(Decimal.valueOf(1800), results[0].monthlyAfter);
        System.assert(results[0].summary != null && results[0].summary.contains('Due today'));
    }

    @IsTest
    static void generateAmendQuote_stickyRoundTrip() {
        Test.setMock(HttpCalloutMock.class, new RouteMock());
        RLM_BambooAgentBffClient.baseUrlOverride = 'https://phase2-test.example.com';
        RLM_BambooAgentGenerateAmendQuote.Request req = new RLM_BambooAgentGenerateAmendQuote.Request();
        req.accountId = '001TEST000000001';
        req.newQty = 260;
        req.amendQuotesJson =
            '[{"quoteId":"0Q0STICKY0000001","assetIds":["02iTEST"]}]';
        Test.startTest();
        List<RLM_BambooAgentGenerateAmendQuote.Result> results =
            RLM_BambooAgentGenerateAmendQuote.run(
                new List<RLM_BambooAgentGenerateAmendQuote.Request>{ req }
            );
        Test.stopTest();
        assertOk(results[0].isSuccess, results[0].errorMessage, results[0].responseJson);
        System.assertEquals(Decimal.valueOf('420.5'), results[0].dueToday);
        System.assertEquals(true, results[0].sticky);
        System.assert(
            results[0].amendQuotesJson != null &&
            results[0].amendQuotesJson.contains('0Q0STICKY0000001')
        );
        System.assert(
            results[0].amendQuoteUrl != null &&
            results[0].amendQuoteUrl.contains('/amend-quote/0Q0STICKY0000001')
        );
    }

    @IsTest
    static void client_helpers() {
        System.assertEquals(2, RLM_BambooAgentBffClient.splitCsv('a, b').size());
        System.assertEquals(null, RLM_BambooAgentBffClient.asDecimal(null));
        System.assertEquals(12, RLM_BambooAgentBffClient.asInteger(12));
        System.assert(
            RLM_BambooAgentBffClient.money('USD', Decimal.valueOf('1.5')).contains('1.5')
        );
        List<Object> parsed = RLM_BambooAgentGenerateAmendQuote.parseAmendQuotes(
            '[{"quoteId":"0Q0x"}]'
        );
        System.assertEquals(1, parsed.size());
    }
}
