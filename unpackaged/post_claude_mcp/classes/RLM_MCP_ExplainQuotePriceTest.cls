@IsTest
private class RLM_MCP_ExplainQuotePriceTest {
    private class FakeFetcher implements RLM_MCP_ExplainQuotePrice.WaterfallFetcher {
        Map<String, Object> payload;
        Integer calls = 0;
        String lastLineItemId;
        String lastExecutionId;
        Boolean fail;

        FakeFetcher(Map<String, Object> payload) {
            this.payload = payload;
        }

        public Map<String, Object> fetch(String lineItemId, String executionId) {
            calls++;
            lastLineItemId = lineItemId;
            lastExecutionId = executionId;
            if (fail == true) {
                throw new CalloutException('waterfall unavailable');
            }
            return payload;
        }
    }

    private class OkHttp implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(
                '{"success":true,"output":{"SubscriptionNetUnitPrice":12000,'
                    + '"NetUnitPrice":11040,"ProrationMultiplier":0.9452},"waterfall":[]}'
            );
            return res;
        }
    }

    private class FailHttp implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(
                '{"success":false,"error":{"errorCode":"FETCH_EXPLAINABILITY_LOG_ERROR"},'
                    + '"output":{},"waterfall":[]}'
            );
            return res;
        }
    }

    @TestSetup
    static void setup() {
        Id pbId = Test.getStandardPricebookId();
        update new Pricebook2(Id = pbId, IsActive = true);
        Account acme = new Account(Name = 'Zephyr Explain Co');
        Account other = new Account(Name = 'Other Explain Co');
        insert new List<Account>{ acme, other };
        Opportunity opp = new Opportunity(
            Name = 'Zephyr Explain Opp',
            AccountId = acme.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Product2 db = new Product2(
            Name = 'Zephyr Explain Database',
            StockKeepingUnit = 'ZEXP-DB',
            IsActive = true
        );
        Product2 complete = new Product2(
            Name = 'Zephyr Explain Complete',
            StockKeepingUnit = 'ZEXP-COMPLETE',
            IsActive = true
        );
        insert new List<Product2>{ db, complete };
        insert new List<PricebookEntry>{
            new PricebookEntry(
                Pricebook2Id = pbId,
                Product2Id = db.Id,
                UnitPrice = 12000,
                IsActive = true
            ),
            new PricebookEntry(
                Pricebook2Id = pbId,
                Product2Id = complete.Id,
                UnitPrice = 0,
                IsActive = true
            )
        };
        Quote priced = new Quote(
            Name = 'Zephyr Explain Priced',
            OpportunityId = opp.Id,
            Pricebook2Id = pbId,
            Status = 'Draft',
            StartDate = Date.newInstance(2026, 10, 28),
            EndDate = Date.newInstance(2027, 10, 7)
        );
        Quote sibling = new Quote(
            Name = 'Zephyr Explain Sibling',
            OpportunityId = opp.Id,
            Pricebook2Id = pbId,
            Status = 'Draft'
        );
        Quote emptyQ = new Quote(
            Name = 'Zephyr Explain Empty',
            OpportunityId = opp.Id,
            Pricebook2Id = pbId,
            Status = 'Draft'
        );
        insert new List<Quote>{ priced, sibling, emptyQ };
        PricebookEntry dbEntry = [
            SELECT Id FROM PricebookEntry WHERE Product2.StockKeepingUnit = 'ZEXP-DB'
        ];
        PricebookEntry completeEntry = [
            SELECT Id FROM PricebookEntry WHERE Product2.StockKeepingUnit = 'ZEXP-COMPLETE'
        ];
        insert new List<QuoteLineItem>{
            new QuoteLineItem(
                QuoteId = priced.Id,
                PricebookEntryId = dbEntry.Id,
                Product2Id = db.Id,
                Quantity = 5,
                UnitPrice = 12000,
                Discount = 8,
                StartDate = Date.newInstance(2026, 10, 28),
                EndDate = Date.newInstance(2027, 10, 7)
            ),
            new QuoteLineItem(
                QuoteId = priced.Id,
                PricebookEntryId = completeEntry.Id,
                Product2Id = complete.Id,
                Quantity = 1,
                UnitPrice = 0
            ),
            new QuoteLineItem(
                QuoteId = sibling.Id,
                PricebookEntryId = dbEntry.Id,
                Product2Id = db.Id,
                Quantity = 2,
                UnitPrice = 12000
            )
        };
    }

    private static RLM_MCP_ExplainQuotePrice.ExplainOutput run(
        RLM_MCP_ExplainQuotePrice.ExplainInput input
    ) {
        return RLM_MCP_ExplainQuotePrice.explain(
            new List<RLM_MCP_ExplainQuotePrice.ExplainInput>{ input }
        )[0];
    }

    private static void assertOk(RLM_MCP_ExplainQuotePrice.ExplainOutput out) {
        String dump = 'success=' + out.isSuccess
            + ' err=' + out.errorMessage
            + ' url=' + out.quoteUrl
            + ' display=' + out.explanationDisplay;
        Assert.isTrue(out.isSuccess == true, dump);
        Assert.isTrue(String.isNotBlank(out.explanationDisplay), dump);
        Assert.isTrue(String.isNotBlank(out.quoteUrl), dump);
    }

    @IsTest
    static void emptyInputIsEmpty() {
        System.assertEquals(0, RLM_MCP_ExplainQuotePrice.explain(null).size());
        System.assertEquals(
            0,
            RLM_MCP_ExplainQuotePrice.explain(
                new List<RLM_MCP_ExplainQuotePrice.ExplainInput>()
            ).size()
        );
    }

    @IsTest
    static void missingIdentity() {
        RLM_MCP_ExplainQuotePrice.ExplainOutput out =
            run(new RLM_MCP_ExplainQuotePrice.ExplainInput());
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('quote name'), out.errorMessage);
    }

    @IsTest
    static void invalidQuoteId() {
        RLM_MCP_ExplainQuotePrice.ExplainInput input =
            new RLM_MCP_ExplainQuotePrice.ExplainInput();
        input.quoteId = 'not-an-id';
        RLM_MCP_ExplainQuotePrice.ExplainOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.startsWith('Invalid Quote Id'), out.errorMessage);
    }

    @IsTest
    static void wrongObjectIdRejected() {
        Account a = [SELECT Id FROM Account WHERE Name = 'Zephyr Explain Co'];
        RLM_MCP_ExplainQuotePrice.ExplainInput input =
            new RLM_MCP_ExplainQuotePrice.ExplainInput();
        input.quoteId = String.valueOf(a.Id);
        RLM_MCP_ExplainQuotePrice.ExplainOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.startsWith('Invalid Quote Id'), out.errorMessage);
    }

    @IsTest
    static void noMatch() {
        RLM_MCP_ExplainQuotePrice.ExplainInput input =
            new RLM_MCP_ExplainQuotePrice.ExplainInput();
        input.quoteName = 'No Such Quote XYZ';
        RLM_MCP_ExplainQuotePrice.ExplainOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.startsWith('No quote found'), out.errorMessage);
    }

    @IsTest
    static void emptyQuoteRejected() {
        RLM_MCP_ExplainQuotePrice.ExplainInput input =
            new RLM_MCP_ExplainQuotePrice.ExplainInput();
        input.quoteName = 'Zephyr Explain Empty';
        RLM_MCP_ExplainQuotePrice.ExplainOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('no lines'), out.errorMessage);
    }

    @IsTest
    static void disambiguatesMultiple() {
        RLM_MCP_ExplainQuotePrice.ExplainInput input =
            new RLM_MCP_ExplainQuotePrice.ExplainInput();
        input.quoteName = 'Zephyr Explain';
        RLM_MCP_ExplainQuotePrice.ExplainOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assertEquals(true, out.needsDisambiguation);
        System.assert(out.candidateSummariesDisplay.contains('Zephyr Explain Priced'), out.candidateSummariesDisplay);
        System.assert(out.candidateSummariesDisplay.contains('Open'), out.candidateSummariesDisplay);
    }

    @IsTest
    static void exactNameExplainsListDiscountAndTerm() {
        RLM_MCP_ExplainQuotePrice.ExplainInput input =
            new RLM_MCP_ExplainQuotePrice.ExplainInput();
        input.quoteName = 'Zephyr Explain Priced';
        Test.startTest();
        RLM_MCP_ExplainQuotePrice.ExplainOutput out = run(input);
        Test.stopTest();
        assertOk(out);
        Assert.isTrue(out.quoteUrl.contains('/lightning/r/Quote/'), out.quoteUrl);
        Assert.isTrue(out.explanationDisplay.contains('Open Quote'), out.explanationDisplay);
        Assert.isTrue(out.explanationDisplay.contains('Zephyr Explain Database'), out.explanationDisplay);
        Assert.isTrue(out.explanationDisplay.contains('$12,000.00'), out.explanationDisplay);
        Assert.isTrue(out.explanationDisplay.contains('8%'), out.explanationDisplay);
        Assert.isTrue(out.explanationDisplay.contains('Oct 28, 2026'), out.explanationDisplay);
        Assert.isTrue(out.explanationDisplay.contains('Amount due'), out.explanationDisplay);
    }

    @IsTest
    static void productNameFiltersAndWaterfallEnriches() {
        Quote q = [SELECT Id FROM Quote WHERE Name = 'Zephyr Explain Priced'];
        QuoteLineItem dbLine = [
            SELECT Id FROM QuoteLineItem
            WHERE QuoteId = :q.Id AND Product2.StockKeepingUnit = 'ZEXP-DB'
        ];
        FakeFetcher fake = new FakeFetcher(
            new Map<String, Object>{
                'success' => true,
                'output' => new Map<String, Object>{
                    'SubscriptionNetUnitPrice' => 12000,
                    'NetUnitPrice' => 11040,
                    'ProrationMultiplier' => 0.9452054794520548
                }
            }
        );
        RLM_MCP_ExplainQuotePrice.fetcher = fake;
        RLM_MCP_ExplainQuotePrice.identifierOverrides = new Map<Id, String>{
            dbLine.Id => 'd9a0ca67-8d60-4aa2-a25e-7504596f8d31:297312638583022'
        };

        RLM_MCP_ExplainQuotePrice.ExplainInput input =
            new RLM_MCP_ExplainQuotePrice.ExplainInput();
        input.quoteId = String.valueOf(q.Id);
        input.productName = 'Database';
        Test.startTest();
        RLM_MCP_ExplainQuotePrice.ExplainOutput out = run(input);
        Test.stopTest();

        assertOk(out);
        Assert.areEqual(1, fake.calls, out.explanationDisplay);
        Assert.areEqual('d9a0ca67-8d60-4aa2-a25e-7504596f8d31', fake.lastLineItemId);
        Assert.areEqual('297312638583022', fake.lastExecutionId);
        Assert.isTrue(out.explanationDisplay.contains('Zephyr Explain Database'), out.explanationDisplay);
        Assert.isFalse(out.explanationDisplay.contains('Zephyr Explain Complete'), out.explanationDisplay);
        Assert.isTrue(out.explanationDisplay.contains('$11,040.00'), out.explanationDisplay);
        Assert.isTrue(out.explanationDisplay.contains('Prorated term'), out.explanationDisplay);
        Assert.isTrue(out.explanationDisplay.contains('waterfall'), out.explanationDisplay);
    }

    @IsTest
    static void unknownProduct() {
        RLM_MCP_ExplainQuotePrice.ExplainInput input =
            new RLM_MCP_ExplainQuotePrice.ExplainInput();
        input.quoteName = 'Zephyr Explain Priced';
        input.productName = 'No Such SKU';
        RLM_MCP_ExplainQuotePrice.ExplainOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('No line'), out.errorMessage);
    }

    @IsTest
    static void waterfallFailureStillExplains() {
        Quote q = [SELECT Id FROM Quote WHERE Name = 'Zephyr Explain Priced'];
        QuoteLineItem dbLine = [
            SELECT Id FROM QuoteLineItem
            WHERE QuoteId = :q.Id AND Product2.StockKeepingUnit = 'ZEXP-DB'
        ];
        FakeFetcher fake = new FakeFetcher(null);
        fake.fail = true;
        RLM_MCP_ExplainQuotePrice.fetcher = fake;
        RLM_MCP_ExplainQuotePrice.identifierOverrides = new Map<Id, String>{
            dbLine.Id => 'abc:123'
        };

        RLM_MCP_ExplainQuotePrice.ExplainInput input =
            new RLM_MCP_ExplainQuotePrice.ExplainInput();
        input.quoteId = String.valueOf(q.Id);
        Test.startTest();
        RLM_MCP_ExplainQuotePrice.ExplainOutput out = run(input);
        Test.stopTest();

        assertOk(out);
        Assert.isTrue(out.explanationDisplay.contains('$12,000.00'), out.explanationDisplay);
        Assert.isFalse(
            out.explanationDisplay.contains('persisted price waterfall'),
            out.explanationDisplay
        );
    }

    @IsTest
    static void accountNameResolvesSinglePricedQuote() {
        RLM_MCP_ExplainQuotePrice.ExplainInput input =
            new RLM_MCP_ExplainQuotePrice.ExplainInput();
        input.accountName = 'Other Explain Co';
        RLM_MCP_ExplainQuotePrice.ExplainOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.startsWith('No quote found'), out.errorMessage);
    }

    @IsTest
    static void splitIdentifierParsesUuidAndQliShapes() {
        System.assertEquals(null, RLM_MCP_ExplainQuotePrice.splitIdentifier(null));
        System.assertEquals(null, RLM_MCP_ExplainQuotePrice.splitIdentifier('nocolon'));
        List<String> uuid = RLM_MCP_ExplainQuotePrice.splitIdentifier(
            'd9a0ca67-8d60-4aa2-a25e-7504596f8d31:297312638583022'
        );
        System.assertEquals('d9a0ca67-8d60-4aa2-a25e-7504596f8d31', uuid[0]);
        System.assertEquals('297312638583022', uuid[1]);
        List<String> qli = RLM_MCP_ExplainQuotePrice.splitIdentifier(
            '0QLg8000002dcCMGAY:297308864469025'
        );
        System.assertEquals('0QLg8000002dcCMGAY', qli[0]);
        System.assertEquals('297308864469025', qli[1]);
    }

    @IsTest
    static void moneyFormatsThousandsAndNegatives() {
        System.assertEquals('n/a', RLM_MCP_ExplainQuotePrice.money(null));
        System.assertEquals('$12,000.00', RLM_MCP_ExplainQuotePrice.money(12000));
        System.assertEquals('$52,175.34', RLM_MCP_ExplainQuotePrice.money(52175.34246575343));
        System.assertEquals('-$1,040.50', RLM_MCP_ExplainQuotePrice.money(-1040.5));
    }

    @IsTest
    static void defaultFetcherParsesSuccess() {
        Test.setMock(HttpCalloutMock.class, new OkHttp());
        RLM_MCP_ExplainQuotePrice.DefaultWaterfallFetcher httpFetcher =
            new RLM_MCP_ExplainQuotePrice.DefaultWaterfallFetcher();
        Test.startTest();
        Map<String, Object> ok = httpFetcher.fetch('uuid-1', 'exec-1');
        Test.stopTest();
        System.assertEquals(true, ok.get('success'));
        System.assertEquals(null, httpFetcher.fetch(null, 'exec-1'));
    }

    @IsTest
    static void defaultFetcherTreatsUnsuccessfulBodyAsNull() {
        Test.setMock(HttpCalloutMock.class, new FailHttp());
        RLM_MCP_ExplainQuotePrice.DefaultWaterfallFetcher httpFetcher =
            new RLM_MCP_ExplainQuotePrice.DefaultWaterfallFetcher();
        Test.startTest();
        Map<String, Object> body = httpFetcher.fetch('uuid-1', 'exec-1');
        Test.stopTest();
        System.assertEquals(null, body);
    }
}
