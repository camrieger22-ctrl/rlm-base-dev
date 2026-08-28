@IsTest
private class RLM_BambooAgentBffActionsTest {
    private class RouteMock implements HttpCalloutMock {
        public String lastGetPricingBody;

        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            String ep = req.getEndpoint();
            if (ep != null && ep.contains('/api/qualify-session')) {
                res.setStatusCode(200);
                res.setBody(
                    '{"ok":true,"session":{"sessionId":"sess-1","step":3,' +
                    '"headcount":12,"country":"US","needs":["hiring","timetracking"]}}'
                );
                return res;
            }
            if (ep != null && ep.contains('/api/qualify-lookup')) {
                String body = req.getBody();
                if (body != null && body.contains('existing@')) {
                    res.setStatusCode(200);
                    res.setBody(
                        '{"ok":true,"status":"existingCustomer","reason":"sign in",' +
                        '"matched":true,"accountId":"001EXIST","signInUrl":"/account?accountId=001EXIST"}'
                    );
                    return res;
                }
                if (body != null && body.contains('sales@')) {
                    res.setStatusCode(200);
                    res.setBody(
                        '{"ok":true,"status":"salesWorking","reason":"Open Quote",' +
                        '"matched":true,"accountId":"001SALES"}'
                    );
                    return res;
                }
                res.setStatusCode(200);
                res.setBody(
                    '{"ok":true,"status":"selfServe","reason":"clear","matched":false,' +
                    '"accountId":null,"contactId":null,"signInUrl":null}'
                );
                return res;
            }
            if (ep != null && ep.contains('/api/qualify-commit')) {
                String body = req.getBody();
                if (body != null && body.contains('dual@example.com')) {
                    res.setStatusCode(409);
                    res.setBody(
                        '{"ok":false,"error":"Sales is already working this.",' +
                        '"status":"salesWorking","reason":"Open Quote","accountId":"001DUAL"}'
                    );
                    return res;
                }
                res.setStatusCode(200);
                res.setBody(
                    '{"ok":true,"status":"selfServe","reason":"stamped",' +
                    '"accountId":"001SELF","contactId":"003SELF"}'
                );
                return res;
            }
            if (ep != null && ep.contains('/api/qualify-handoff')) {
                String body = req.getBody();
                if (body != null && body.contains('existing@')) {
                    res.setStatusCode(409);
                    res.setBody(
                        '{"ok":true,"handoff":false,"status":"existingCustomer",' +
                        '"accountId":"001EXIST","signInUrl":"/account?accountId=001EXIST"}'
                    );
                    return res;
                }
                res.setStatusCode(200);
                res.setBody(
                    '{"ok":true,"handoff":true,"status":"salesWorking","alreadyWorking":false,' +
                    '"accountId":"001HAND","contactId":"003HAND","taskId":"00THAND",' +
                    '"reason":"Payroll needs a person."}'
                );
                return res;
            }
            if (ep != null && ep.contains('/api/collect-payment')) {
                res.setStatusCode(200);
                res.setBody(
                    '{"ok":true,"ready":true,"orderId":"801TEST000000001",' +
                    '"invoiceId":"3i0TEST000000001","paymentUrl":"https://pay.example.com/now"}'
                );
                return res;
            }
            if (ep != null && ep.contains('/api/activate') && !ep.contains('cadence')) {
                res.setStatusCode(200);
                res.setBody(
                    '{"ok":true,"accountId":"001TEST000000001","paid":true,"loginReady":false,' +
                    '"licensesUrl":"/account","message":"Activate checklist updated."}'
                );
                return res;
            }
            if (ep != null && ep.contains('/api/checkout')) {
                res.setStatusCode(200);
                res.setBody(
                    '{"ok":true,"quoteId":"0Q0TEST000000001","orderId":"801TEST000000001",' +
                    '"orderNumber":"00000100","quoteTotal":765,"startDate":"2026-08-19",' +
                    '"paymentUrl":"https://pay.example.com/now"}'
                );
                return res;
            }
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
                lastGetPricingBody = req.getBody();
                String body = req.getBody();
                if (body != null && body.contains('nocommit@')) {
                    res.setStatusCode(409);
                    res.setBody(
                        '{"ok":false,"error":"Create your self-serve account before requesting a Quote.",' +
                        '"status":"commitRequired"}'
                    );
                    return res;
                }
                res.setStatusCode(200);
                res.setBody(
                    '{"ok":true,"quoteId":"0Q0TEST000000001","quoteUrl":"/quote/0Q0TEST000000001",' +
                    '"accountId":"001TEST000000001","currency":"USD","netPepm":7.65,"monthlyTotal":765,' +
                    '"termMonths":12,"termTotal":9180,"startDate":"2026-09-01","planSku":"BAMBOO-PRO",' +
                    '"headcount":100}'
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
            if (ep != null && ep.contains('/api/account-amend')) {
                res.setStatusCode(200);
                res.setBody(
                    '{"ok":true,"accountId":"001TEST000000001","amendOrderId":"801TEST000000002",' +
                    '"amendOrderNumber":"00000200",' +
                    '"payment":{"paymentUrl":"https://pay.example.com/amend"}}'
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
        System.assertEquals(12, results[0].termMonths);
        System.assertEquals('12', results[0].termMonthsText);
        System.assertEquals('765', results[0].monthlyTotalText);
        System.assertEquals('100', results[0].headcountText);
        System.assertEquals('2026-09-01', results[0].startDate);
        System.assertEquals('BAMBOO-PRO', results[0].planSku);
        System.assertEquals(100, results[0].headcount);
        System.assert(
            results[0].summary != null &&
            results[0].summary.contains('https://phase2-test.example.com/quote/0Q0TEST000000001')
        );
    }

    @IsTest
    static void createQuote_passesPreviewQuoteId() {
        RouteMock mock = new RouteMock();
        Test.setMock(HttpCalloutMock.class, mock);
        RLM_BambooAgentBffClient.baseUrlOverride = 'https://phase2-test.example.com';
        RLM_BambooAgentCreateGetPricingQuote.Request req = new RLM_BambooAgentCreateGetPricingQuote.Request();
        req.headcount = 12;
        req.company = 'Sticky Co';
        req.email = 'buyer@example.com';
        req.previewQuoteId = '0Q0STICKY000000001';
        req.accountId = '001STICKY000000001';
        Test.startTest();
        List<RLM_BambooAgentCreateGetPricingQuote.Result> results =
            RLM_BambooAgentCreateGetPricingQuote.run(
                new List<RLM_BambooAgentCreateGetPricingQuote.Request>{ req }
            );
        Test.stopTest();
        assertOk(results[0].isSuccess, results[0].errorMessage, results[0].responseJson);
        System.assert(mock.lastGetPricingBody != null);
        System.assert(mock.lastGetPricingBody.contains('0Q0STICKY000000001'));
        System.assert(mock.lastGetPricingBody.contains('001STICKY000000001'));
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
        System.assertEquals(null, RLM_BambooAgentBffClient.asMap('x'));
        System.assert(
            RLM_BambooAgentBffClient.isAcquisitionDraftName('SelfServe — Acme')
        );
        System.assert(
            RLM_BambooAgentBffClient.isAcquisitionDraftName('14-day trial Core')
        );
        System.assertEquals(
            false,
            RLM_BambooAgentBffClient.isAcquisitionDraftName('AE deal Q-100')
        );
    }

    @IsTest
    static void saveQualifySession_ok() {
        Test.setMock(HttpCalloutMock.class, new RouteMock());
        RLM_BambooAgentBffClient.baseUrlOverride = 'https://phase2-test.example.com';
        RLM_BambooAgentSaveQualifySession.Request req = new RLM_BambooAgentSaveQualifySession.Request();
        req.step = 3;
        req.headcount = 12;
        req.country = 'US';
        req.needsCsv = 'hiring,timetracking';
        Test.startTest();
        List<RLM_BambooAgentSaveQualifySession.Result> results =
            RLM_BambooAgentSaveQualifySession.run(
                new List<RLM_BambooAgentSaveQualifySession.Request>{ req }
            );
        Test.stopTest();
        assertOk(results[0].isSuccess, results[0].errorMessage, results[0].responseJson);
        System.assertEquals('sess-1', results[0].sessionId);
        System.assertEquals(3, results[0].step);
    }

    @IsTest
    static void lookupQualifyEmail_requiresEmail() {
        RLM_BambooAgentLookupQualifyEmail.Request req = new RLM_BambooAgentLookupQualifyEmail.Request();
        List<RLM_BambooAgentLookupQualifyEmail.Result> results =
            RLM_BambooAgentLookupQualifyEmail.run(
                new List<RLM_BambooAgentLookupQualifyEmail.Request>{ req }
            );
        System.assertEquals(false, results[0].isSuccess);
        System.assert(results[0].errorMessage.contains('email'));
    }

    @IsTest
    static void lookupQualifyEmail_ok() {
        Test.setMock(HttpCalloutMock.class, new RouteMock());
        RLM_BambooAgentBffClient.baseUrlOverride = 'https://phase2-test.example.com';
        RLM_BambooAgentLookupQualifyEmail.Request req = new RLM_BambooAgentLookupQualifyEmail.Request();
        req.email = 'new@example.com';
        Test.startTest();
        List<RLM_BambooAgentLookupQualifyEmail.Result> results =
            RLM_BambooAgentLookupQualifyEmail.run(
                new List<RLM_BambooAgentLookupQualifyEmail.Request>{ req }
            );
        Test.stopTest();
        assertOk(results[0].isSuccess, results[0].errorMessage, results[0].responseJson);
        System.assertEquals('selfServe', results[0].status);
    }

    @IsTest
    static void commitQualify_ok() {
        Test.setMock(HttpCalloutMock.class, new RouteMock());
        RLM_BambooAgentBffClient.baseUrlOverride = 'https://phase2-test.example.com';
        RLM_BambooAgentCommitQualifyIdentity.Request req = new RLM_BambooAgentCommitQualifyIdentity.Request();
        req.company = 'Hale Labs';
        req.email = 'jordan@halelabs.example';
        req.headcount = 12;
        Test.startTest();
        List<RLM_BambooAgentCommitQualifyIdentity.Result> results =
            RLM_BambooAgentCommitQualifyIdentity.run(
                new List<RLM_BambooAgentCommitQualifyIdentity.Request>{ req }
            );
        Test.stopTest();
        assertOk(results[0].isSuccess, results[0].errorMessage, results[0].responseJson);
        System.assertEquals('001SELF', results[0].accountId);
        System.assertEquals('selfServe', results[0].status);
        System.assertEquals('true', results[0].committed);
    }

    @IsTest
    static void commitQualify_dualMotion409() {
        Test.setMock(HttpCalloutMock.class, new RouteMock());
        RLM_BambooAgentBffClient.baseUrlOverride = 'https://phase2-test.example.com';
        RLM_BambooAgentCommitQualifyIdentity.Request req = new RLM_BambooAgentCommitQualifyIdentity.Request();
        req.company = 'Dual Co';
        req.email = 'dual@example.com';
        req.headcount = 10;
        Test.startTest();
        List<RLM_BambooAgentCommitQualifyIdentity.Result> results =
            RLM_BambooAgentCommitQualifyIdentity.run(
                new List<RLM_BambooAgentCommitQualifyIdentity.Request>{ req }
            );
        Test.stopTest();
        System.assertEquals(false, results[0].isSuccess);
        System.assertEquals('salesWorking', results[0].status);
        System.assert(results[0].summary != null && results[0].summary.contains('Sales'));
    }

    @IsTest
    static void handoffQualify_ok() {
        Test.setMock(HttpCalloutMock.class, new RouteMock());
        RLM_BambooAgentBffClient.baseUrlOverride = 'https://phase2-test.example.com';
        RLM_BambooAgentHandoffQualifyToSales.Request req = new RLM_BambooAgentHandoffQualifyToSales.Request();
        req.company = 'Payroll Co';
        req.email = 'ae@payroll.example';
        req.bounceType = 'payroll';
        req.bounceReason = 'Needs Payroll';
        Test.startTest();
        List<RLM_BambooAgentHandoffQualifyToSales.Result> results =
            RLM_BambooAgentHandoffQualifyToSales.run(
                new List<RLM_BambooAgentHandoffQualifyToSales.Request>{ req }
            );
        Test.stopTest();
        assertOk(results[0].isSuccess, results[0].errorMessage, results[0].responseJson);
        System.assertEquals('001HAND', results[0].accountId);
        System.assertEquals('00THAND', results[0].taskId);
    }

    @IsTest
    static void lookupQualifyEmail_existingCustomer() {
        Test.setMock(HttpCalloutMock.class, new RouteMock());
        RLM_BambooAgentBffClient.baseUrlOverride = 'https://phase2-test.example.com';
        RLM_BambooAgentLookupQualifyEmail.Request req = new RLM_BambooAgentLookupQualifyEmail.Request();
        req.email = 'existing@example.com';
        Test.startTest();
        List<RLM_BambooAgentLookupQualifyEmail.Result> results =
            RLM_BambooAgentLookupQualifyEmail.run(
                new List<RLM_BambooAgentLookupQualifyEmail.Request>{ req }
            );
        Test.stopTest();
        assertOk(results[0].isSuccess, results[0].errorMessage, results[0].responseJson);
        System.assertEquals('existingCustomer', results[0].status);
        System.assert(results[0].summary.contains('Licenses'));
    }

    @IsTest
    static void lookupQualifyEmail_salesWorking() {
        Test.setMock(HttpCalloutMock.class, new RouteMock());
        RLM_BambooAgentBffClient.baseUrlOverride = 'https://phase2-test.example.com';
        RLM_BambooAgentLookupQualifyEmail.Request req = new RLM_BambooAgentLookupQualifyEmail.Request();
        req.email = 'sales@example.com';
        Test.startTest();
        List<RLM_BambooAgentLookupQualifyEmail.Result> results =
            RLM_BambooAgentLookupQualifyEmail.run(
                new List<RLM_BambooAgentLookupQualifyEmail.Request>{ req }
            );
        Test.stopTest();
        assertOk(results[0].isSuccess, results[0].errorMessage, results[0].responseJson);
        System.assertEquals('salesWorking', results[0].status);
    }

    @IsTest
    static void handoffQualify_existingCustomer409() {
        Test.setMock(HttpCalloutMock.class, new RouteMock());
        RLM_BambooAgentBffClient.baseUrlOverride = 'https://phase2-test.example.com';
        RLM_BambooAgentHandoffQualifyToSales.Request req = new RLM_BambooAgentHandoffQualifyToSales.Request();
        req.company = 'Existing Co';
        req.email = 'existing@example.com';
        req.bounceType = 'payroll';
        Test.startTest();
        List<RLM_BambooAgentHandoffQualifyToSales.Result> results =
            RLM_BambooAgentHandoffQualifyToSales.run(
                new List<RLM_BambooAgentHandoffQualifyToSales.Request>{ req }
            );
        Test.stopTest();
        System.assertEquals(false, results[0].isSuccess);
        System.assertEquals('existingCustomer', results[0].status);
        System.assert(results[0].summary.contains('sign in'));
    }

    @IsTest
    static void createQuote_rejectsPayrollAddon() {
        RLM_BambooAgentCreateGetPricingQuote.Request req = new RLM_BambooAgentCreateGetPricingQuote.Request();
        req.headcount = 12;
        req.company = 'Acme';
        req.email = 'buyer@example.com';
        req.addonSkusCsv = 'BAMBOO-ADD-PAYROLL';
        List<RLM_BambooAgentCreateGetPricingQuote.Result> results =
            RLM_BambooAgentCreateGetPricingQuote.run(
                new List<RLM_BambooAgentCreateGetPricingQuote.Request>{ req }
            );
        System.assertEquals(false, results[0].isSuccess);
        System.assert(results[0].errorMessage.contains('Payroll'));
    }

    @IsTest
    static void createQuote_commitRequired409() {
        Test.setMock(HttpCalloutMock.class, new RouteMock());
        RLM_BambooAgentBffClient.baseUrlOverride = 'https://phase2-test.example.com';
        RLM_BambooAgentCreateGetPricingQuote.Request req = new RLM_BambooAgentCreateGetPricingQuote.Request();
        req.headcount = 12;
        req.company = 'Skip Commit';
        req.email = 'nocommit@example.com';
        Test.startTest();
        List<RLM_BambooAgentCreateGetPricingQuote.Result> results =
            RLM_BambooAgentCreateGetPricingQuote.run(
                new List<RLM_BambooAgentCreateGetPricingQuote.Request>{ req }
            );
        Test.stopTest();
        System.assertEquals(false, results[0].isSuccess);
        System.assert(results[0].errorMessage.contains('self-serve account'));
    }

    @IsTest
    static void createQuote_usesPageQuoteIdWhenPreviewBlank() {
        RouteMock mock = new RouteMock();
        Test.setMock(HttpCalloutMock.class, mock);
        RLM_BambooAgentBffClient.baseUrlOverride = 'https://phase2-test.example.com';
        RLM_BambooAgentCreateGetPricingQuote.Request req = new RLM_BambooAgentCreateGetPricingQuote.Request();
        req.headcount = 12;
        req.company = 'Page Co';
        req.email = 'buyer@example.com';
        req.pageQuoteId = '0Q0PAGE000000000001';
        Test.startTest();
        List<RLM_BambooAgentCreateGetPricingQuote.Result> results =
            RLM_BambooAgentCreateGetPricingQuote.run(
                new List<RLM_BambooAgentCreateGetPricingQuote.Request>{ req }
            );
        Test.stopTest();
        assertOk(results[0].isSuccess, results[0].errorMessage, results[0].responseJson);
        System.assert(mock.lastGetPricingBody.contains('0Q0PAGE000000000001'));
    }

    @IsTest
    static void placeOrder_ok() {
        Test.setMock(HttpCalloutMock.class, new RouteMock());
        RLM_BambooAgentBffClient.baseUrlOverride = 'https://phase2-test.example.com';
        RLM_BambooAgentPlaceGetPricingOrder.Request req = new RLM_BambooAgentPlaceGetPricingOrder.Request();
        req.quoteId = Quote.SObjectType.getDescribe().getKeyPrefix() + '000000000001';
        Test.startTest();
        List<RLM_BambooAgentPlaceGetPricingOrder.Result> results =
            RLM_BambooAgentPlaceGetPricingOrder.run(
                new List<RLM_BambooAgentPlaceGetPricingOrder.Request>{ req }
            );
        Test.stopTest();
        assertOk(results[0].isSuccess, results[0].errorMessage, results[0].responseJson);
        System.assertEquals('801TEST000000001', results[0].orderId);
        System.assertEquals('https://pay.example.com/now', results[0].paymentUrl);
        System.assert(results[0].summary.contains('https://pay.example.com/now'));
    }

    @IsTest
    static void placeOrder_blankQuoteFails() {
        RLM_BambooAgentPlaceGetPricingOrder.Result res = RLM_BambooAgentPlaceGetPricingOrder.runOne(
            new RLM_BambooAgentPlaceGetPricingOrder.Request()
        );
        System.assertEquals(false, res.isSuccess);
        System.assert(res.errorMessage.contains('Quote Id'));
    }

    @IsTest
    static void placeOrder_pageQuoteSkipsStaleAccountPin() {
        Id quoteId = (Id) (Quote.SObjectType.getDescribe().getKeyPrefix() + '000000000001');
        Id quoteAcct = (Id) (Account.SObjectType.getDescribe().getKeyPrefix() + '000000000001');
        Id pinAcct = (Id) (Account.SObjectType.getDescribe().getKeyPrefix() + '000000000002');
        System.assertEquals(
            false,
            RLM_BambooAgentPlaceGetPricingOrder.sessionAccountBlocksPlace(
                quoteAcct,
                String.valueOf(pinAcct),
                String.valueOf(quoteId),
                quoteId
            ),
            'On-quote Place must ignore a Licenses pin'
        );
        System.assertEquals(
            true,
            RLM_BambooAgentPlaceGetPricingOrder.sessionAccountBlocksPlace(
                quoteAcct,
                String.valueOf(pinAcct),
                null,
                quoteId
            ),
            'Off-quote Place still blocks a mismatched session Account'
        );
    }

    @IsTest
    static void collectPayment_ok() {
        Test.setMock(HttpCalloutMock.class, new RouteMock());
        RLM_BambooAgentBffClient.baseUrlOverride = 'https://phase2-test.example.com';
        RLM_BambooAgentCollectPayment.Request req = new RLM_BambooAgentCollectPayment.Request();
        req.orderId = Order.SObjectType.getDescribe().getKeyPrefix() + '000000000001';
        Test.startTest();
        List<RLM_BambooAgentCollectPayment.Result> results =
            RLM_BambooAgentCollectPayment.run(
                new List<RLM_BambooAgentCollectPayment.Request>{ req }
            );
        Test.stopTest();
        assertOk(results[0].isSuccess, results[0].errorMessage, results[0].responseJson);
        System.assertEquals('https://pay.example.com/now', results[0].paymentUrl);
    }

    @IsTest
    static void completeActivate_ok() {
        Test.setMock(HttpCalloutMock.class, new RouteMock());
        RLM_BambooAgentBffClient.baseUrlOverride = 'https://phase2-test.example.com';
        RLM_BambooAgentCompleteActivate.Request req = new RLM_BambooAgentCompleteActivate.Request();
        req.accountId = Account.SObjectType.getDescribe().getKeyPrefix() + '000000000001';
        req.adminEmail = 'admin@example.com';
        Test.startTest();
        List<RLM_BambooAgentCompleteActivate.Result> results =
            RLM_BambooAgentCompleteActivate.run(
                new List<RLM_BambooAgentCompleteActivate.Request>{ req }
            );
        Test.stopTest();
        assertOk(results[0].isSuccess, results[0].errorMessage, results[0].responseJson);
        System.assertEquals(true, results[0].paid);
    }

    @IsTest
    static void placeAmend_ok() {
        Test.setMock(HttpCalloutMock.class, new RouteMock());
        RLM_BambooAgentBffClient.baseUrlOverride = 'https://phase2-test.example.com';
        RLM_BambooAgentPlaceAmend.Request req = new RLM_BambooAgentPlaceAmend.Request();
        req.accountId = Account.SObjectType.getDescribe().getKeyPrefix() + '000000000001';
        req.newQty = 20;
        Test.startTest();
        List<RLM_BambooAgentPlaceAmend.Result> results =
            RLM_BambooAgentPlaceAmend.run(
                new List<RLM_BambooAgentPlaceAmend.Request>{ req }
            );
        Test.stopTest();
        assertOk(results[0].isSuccess, results[0].errorMessage, results[0].responseJson);
        System.assertEquals('00000200', results[0].amendOrderNumber);
        System.assertEquals('https://pay.example.com/amend', results[0].paymentUrl);
    }
}
