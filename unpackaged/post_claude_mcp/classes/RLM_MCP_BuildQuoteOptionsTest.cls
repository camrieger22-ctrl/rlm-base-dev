@IsTest
private class RLM_MCP_BuildQuoteOptionsTest {

    @TestSetup
    static void setup() {
        update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
        insert new Account(Name = 'MCP Options Account');
    }

    private static RLM_MCP_BuildQuoteOptions.BuildOutput run(
        String accountName,
        String opportunityName,
        String optionsJson
    ) {
        return run(accountName, opportunityName, optionsJson, null, null);
    }

    private static RLM_MCP_BuildQuoteOptions.BuildOutput run(
        String accountName,
        String opportunityName,
        String optionsJson,
        String sourceQuoteName,
        String sourceQuoteId
    ) {
        RLM_MCP_BuildQuoteOptions.BuildInput input = new RLM_MCP_BuildQuoteOptions.BuildInput();
        input.accountName = accountName;
        input.opportunityName = opportunityName;
        input.optionsJson = optionsJson;
        input.sourceQuoteName = sourceQuoteName;
        input.sourceQuoteId = sourceQuoteId;
        return RLM_MCP_BuildQuoteOptions.build(
            new List<RLM_MCP_BuildQuoteOptions.BuildInput>{ input }
        )[0];
    }

    private class FakeQuoteCloner implements RLM_MCP_BuildQuoteOptions.QuoteCloner {
        Integer calls = 0;
        public RLM_MCP_BuildQuoteOptions.CloneResult cloneQuote(Id sourceQuoteId) {
            calls++;
            Quote source = [
                SELECT OpportunityId, Pricebook2Id, StartDate, EndDate
                FROM Quote
                WHERE Id = :sourceQuoteId
            ];
            Quote copy = new Quote(
                Name = 'Clone ' + String.valueOf(calls),
                OpportunityId = source.OpportunityId,
                Pricebook2Id = source.Pricebook2Id,
                Status = 'Draft',
                StartDate = source.StartDate,
                EndDate = source.EndDate
            );
            insert copy;
            RLM_MCP_BuildQuoteOptions.CloneResult result =
                new RLM_MCP_BuildQuoteOptions.CloneResult();
            result.quoteId = copy.Id;
            return result;
        }
    }

    private class FailingQuoteCloner implements RLM_MCP_BuildQuoteOptions.QuoteCloner {
        Integer calls = 0;
        public RLM_MCP_BuildQuoteOptions.CloneResult cloneQuote(Id sourceQuoteId) {
            calls++;
            RLM_MCP_BuildQuoteOptions.CloneResult result =
                new RLM_MCP_BuildQuoteOptions.CloneResult();
            result.error = 'Deep clone test failure: bundle graph rejected.';
            return result;
        }
    }

    @IsTest
    static void requiresAccountName() {
        RLM_MCP_BuildQuoteOptions.BuildOutput out = run(null, null, '[]');
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('Account name'), out.errorMessage);
    }

    @IsTest
    static void requiresOptionsJson() {
        RLM_MCP_BuildQuoteOptions.BuildOutput out = run('MCP Options Account', null, null);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('Options JSON'), out.errorMessage);
    }

    @IsTest
    static void rejectsMalformedJson() {
        RLM_MCP_BuildQuoteOptions.BuildOutput out = run('MCP Options Account', null, '{not-json');
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('Options JSON'), out.errorMessage);
    }

    @IsTest
    static void createsTwoQuotesOnOneOpportunity() {
        String optionsJson =
            '[{"quoteName":"12-Month Essentials","termMonths":12,"discountPercent":0,'
            + '"lines":[{"product":"QuantumBit Complete","quantity":10}]},'
            + '{"quoteName":"24-Month Growth","termMonths":24,"discountPercent":5,'
            + '"lines":[{"product":"QuantumBit Complete","quantity":10},'
            + '{"product":"Q-Rack 750","quantity":1}]}]';
        Test.startTest();
        RLM_MCP_BuildQuoteOptions.BuildOutput out = run(
            'MCP Options Account', 'Atlas Robotics Commercial Options', optionsJson);
        Test.stopTest();
        System.assertEquals(
            true,
            out.isSuccess,
            'Build should create quotes: ' + String.valueOf(out.errorMessage)
        );
        System.assertEquals('Atlas Robotics Commercial Options', out.opportunityName);
        System.assert(out.optionsDisplay.contains('12-Month Essentials'), out.optionsDisplay);
        System.assert(out.optionsDisplay.contains('24-Month Growth'), out.optionsDisplay);
        List<Quote> quotes = [
            SELECT Name, OpportunityId, Opportunity.Name, StartDate, EndDate
            FROM Quote
            WHERE Opportunity.Name = 'Atlas Robotics Commercial Options'
            ORDER BY Name
        ];
        System.assertEquals(2, quotes.size());
        System.assertEquals(quotes[0].OpportunityId, quotes[1].OpportunityId);
        System.assertEquals(Date.today().addMonths(12), quotes[0].EndDate);
        System.assertEquals(Date.today().addMonths(24), quotes[1].EndDate);
        System.assert(out.comparisonDisplay.contains('Quote Options'), out.comparisonDisplay);
        System.assert(out.comparisonDisplay.contains('Open Opportunity'), out.comparisonDisplay);
        System.assert(out.comparisonDisplay.contains('Lowest Net'), out.comparisonDisplay);
        System.assertEquals(false, out.isPartial, 'remaining=' + out.remainingOptionsJson);
    }

    @IsTest
    static void pausesAfterOneOptionWhenLimited() {
        RLM_MCP_BuildQuoteOptions.optionsPerCallOverride = 1;
        String optionsJson =
            '[{"quoteName":"12-Month Essentials","termMonths":12,'
            + '"lines":[{"product":"QuantumBit Complete","quantity":10}]},'
            + '{"quoteName":"24-Month Growth","termMonths":24,'
            + '"lines":[{"product":"QuantumBit Complete","quantity":10}]}]';
        Test.startTest();
        RLM_MCP_BuildQuoteOptions.BuildOutput first = run(
            'MCP Options Account', 'CPU Budget Options', optionsJson);
        Test.stopTest();
        System.assertEquals(true, first.isSuccess, 'err=' + first.errorMessage);
        System.assertEquals(true, first.isPartial, 'remaining=' + first.remainingOptionsJson);
        System.assert(
            first.remainingOptionsJson != null && first.remainingOptionsJson.contains('24-Month Growth'),
            'remaining=' + first.remainingOptionsJson
        );
        System.assert(
            first.remainingOptionsJson != null && !first.remainingOptionsJson.contains('12-Month Essentials'),
            'remaining=' + first.remainingOptionsJson
        );
        List<Quote> afterFirst = [
            SELECT Name FROM Quote WHERE Opportunity.Name = 'CPU Budget Options' ORDER BY Name
        ];
        System.assertEquals(1, afterFirst.size());
        System.assertEquals('12-Month Essentials', afterFirst[0].Name);

        RLM_MCP_BuildQuoteOptions.optionsPerCallOverride = 1;
        RLM_MCP_BuildQuoteOptions.BuildOutput second = run(
            'MCP Options Account', 'CPU Budget Options', first.remainingOptionsJson);
        System.assertEquals(true, second.isSuccess, 'err=' + second.errorMessage);
        System.assertEquals(false, second.isPartial, 'remaining=' + second.remainingOptionsJson);
        System.assert(second.comparisonDisplay.contains('12-Month Essentials'), second.comparisonDisplay);
        System.assert(second.comparisonDisplay.contains('24-Month Growth'), second.comparisonDisplay);
        List<Quote> quotes = [
            SELECT Name FROM Quote WHERE Opportunity.Name = 'CPU Budget Options'
        ];
        System.assertEquals(2, quotes.size());
    }

    @IsTest
    static void mixKeyIgnoresTermAndDiscount() {
        String growth =
            '[{"quoteName":"A","termMonths":12,"discountPercent":0,'
            + '"lines":[{"product":"QuantumBit Complete","quantity":10},'
            + '{"product":"Q-Rack 750","quantity":1}]}]';
        String scale =
            '[{"quoteName":"B","termMonths":36,"discountPercent":10,'
            + '"lines":[{"product":"Q-Rack 750","quantity":1},'
            + '{"product":"QuantumBit Complete","quantity":10}]}]';
        String essentials =
            '[{"lines":[{"product":"QuantumBit Complete","quantity":10}]}]';
        System.assertEquals(
            RLM_MCP_BuildQuoteOptions.mixKeyFromJson(growth),
            RLM_MCP_BuildQuoteOptions.mixKeyFromJson(scale)
        );
        System.assertNotEquals(
            RLM_MCP_BuildQuoteOptions.mixKeyFromJson(growth),
            RLM_MCP_BuildQuoteOptions.mixKeyFromJson(essentials)
        );
    }

    @IsTest
    static void termCountFollowsSellingModelUnit() {
        System.assertEquals(1, RLM_MCP_BuildQuoteOptions.termCount(12, 'Annual'));
        System.assertEquals(2, RLM_MCP_BuildQuoteOptions.termCount(24, 'Annual'));
        System.assertEquals(3, RLM_MCP_BuildQuoteOptions.termCount(36, 'Annual'));
        System.assertEquals(24, RLM_MCP_BuildQuoteOptions.termCount(24, 'Months'));
        System.assertEquals(8, RLM_MCP_BuildQuoteOptions.termCount(24, 'Quarterly'));
    }

    @IsTest
    static void pickPricebookEntryUsesCurrencyAndSameProduct() {
        Product2 complete = new Product2(Name = 'QuantumBit Complete Solution', IsActive = true);
        Product2 rack = new Product2(Name = 'QuantumBit Q-Rack 750', IsActive = true);
        insert new List<Product2>{ complete, rack };

        PricebookEntry usd = new PricebookEntry(Product2Id = complete.Id, CurrencyIsoCode = 'USD');
        PricebookEntry eur = new PricebookEntry(Product2Id = complete.Id, CurrencyIsoCode = 'EUR');
        PricebookEntry usdOtherModel = new PricebookEntry(
            Product2Id = complete.Id, CurrencyIsoCode = 'USD');

        PricebookEntry picked = RLM_MCP_BuildQuoteOptions.pickPricebookEntry(
            new List<PricebookEntry>{ usd, eur, usdOtherModel }, 'USD', null);
        System.assertNotEquals(null, picked);
        System.assertEquals(complete.Id, picked.Product2Id);
        System.assertEquals('USD', picked.CurrencyIsoCode);

        PricebookEntry ambiguous = RLM_MCP_BuildQuoteOptions.pickPricebookEntry(
            new List<PricebookEntry>{
                new PricebookEntry(Product2Id = complete.Id, CurrencyIsoCode = 'USD'),
                new PricebookEntry(Product2Id = rack.Id, CurrencyIsoCode = 'USD')
            },
            'USD',
            null
        );
        System.assertEquals(null, ambiguous);
        System.assertEquals(
            null,
            RLM_MCP_BuildQuoteOptions.pickPricebookEntry(new List<PricebookEntry>(), 'USD', null)
        );
    }

    @IsTest
    static void quantityKeyNormalizesDecimals() {
        System.assertEquals('18', RLM_MCP_BuildQuoteOptions.quantityKey(18));
        System.assertEquals('18', RLM_MCP_BuildQuoteOptions.quantityKey(18.0));
        System.assertEquals('1', RLM_MCP_BuildQuoteOptions.quantityKey(null));
        String asInt =
            '[{"lines":[{"product":"QuantumBit Database","quantity":18}]}]';
        String asDecimal =
            '[{"lines":[{"product":"QuantumBit Database","quantity":18.0}]}]';
        System.assertEquals(
            RLM_MCP_BuildQuoteOptions.mixKeyFromJson(asInt),
            RLM_MCP_BuildQuoteOptions.mixKeyFromJson(asDecimal)
        );
    }

    @IsTest
    static void sourceQuoteNameClonesWithoutLines() {
        Account account = [SELECT Id FROM Account WHERE Name = 'MCP Options Account' LIMIT 1];
        Opportunity opportunity = new Opportunity(
            Name = 'Bryce Source Clone Opp',
            AccountId = account.Id,
            StageName = 'Proposal/Quote',
            CloseDate = Date.today().addDays(30)
        );
        insert opportunity;
        Quote source = new Quote(
            Name = 'Bryce Majors 24-Month Quote',
            OpportunityId = opportunity.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft',
            StartDate = Date.today(),
            EndDate = Date.today().addMonths(24)
        );
        insert source;
        FakeQuoteCloner fake = new FakeQuoteCloner();
        RLM_MCP_BuildQuoteOptions.quoteCloner = fake;

        String optionsJson =
            '[{"quoteName":"Bryce Majors 12-Month","termMonths":12,"discountPercent":10},'
            + '{"quoteName":"Bryce Majors 36-Month","termMonths":36,"discountPercent":25}]';
        Test.startTest();
        RLM_MCP_BuildQuoteOptions.BuildOutput out = run(
            'MCP Options Account',
            'Bryce Source Clone Opp',
            optionsJson,
            'Bryce Majors 24-Month Quote',
            null
        );
        Test.stopTest();

        System.assert(
            out != null && out.isSuccess == true,
            'source clone should succeed: ' + (out == null ? 'null' : String.valueOf(out.errorMessage))
        );
        System.assertEquals(2, fake.calls, 'expected two clones from the source quote');
        System.assert(
            out.optionsDisplay != null && out.optionsDisplay.contains('Cloned from'),
            String.valueOf(out.optionsDisplay)
        );
        List<Quote> quotes = [
            SELECT Name, EndDate
            FROM Quote
            WHERE OpportunityId = :opportunity.Id
            ORDER BY Name
        ];
        System.assertEquals(3, quotes.size());
        System.assertEquals('Bryce Majors 12-Month', quotes[0].Name);
        System.assertEquals(Date.today().addMonths(12), quotes[0].EndDate);
        System.assertEquals('Bryce Majors 24-Month Quote', quotes[1].Name);
        System.assertEquals(Date.today().addMonths(24), quotes[1].EndDate);
        System.assertEquals('Bryce Majors 36-Month', quotes[2].Name);
        System.assertEquals(Date.today().addMonths(36), quotes[2].EndDate);
    }

    @IsTest
    static void sourceQuoteLatestAliasUsesOriginalDraft() {
        Account account = [SELECT Id FROM Account WHERE Name = 'MCP Options Account' LIMIT 1];
        Opportunity opportunity = new Opportunity(
            Name = 'Latest Alias Opp',
            AccountId = account.Id,
            StageName = 'Proposal/Quote',
            CloseDate = Date.today().addDays(30)
        );
        insert opportunity;
        insert new Quote(
            Name = 'Older Draft',
            OpportunityId = opportunity.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft'
        );
        Quote latest = new Quote(
            Name = 'Newest Draft',
            OpportunityId = opportunity.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft'
        );
        insert latest;
        FakeQuoteCloner fake = new FakeQuoteCloner();
        RLM_MCP_BuildQuoteOptions.quoteCloner = fake;

        Test.startTest();
        RLM_MCP_BuildQuoteOptions.BuildOutput out = run(
            'MCP Options Account',
            'Latest Alias Opp',
            '[{"quoteName":"12-Month Copy","termMonths":12,"discountPercent":10}]',
            'latest',
            null
        );
        Test.stopTest();

        System.assert(
            out != null && out.isSuccess == true,
            'latest alias should succeed: ' + (out == null ? 'null' : String.valueOf(out.errorMessage))
        );
        System.assertEquals(1, fake.calls, 'expected one clone from the original draft');
        System.assert(
            out.optionsDisplay != null && out.optionsDisplay.contains('Older Draft'),
            String.valueOf(out.optionsDisplay)
        );
        System.assertEquals(
            1,
            [SELECT COUNT() FROM Quote WHERE OpportunityId = :opportunity.Id AND Name = 'Older Draft']
        );
    }

    @IsTest
    static void cloneFailureFallsBackToPlace() {
        Account account = [SELECT Id FROM Account WHERE Name = 'MCP Options Account' LIMIT 1];
        Opportunity opportunity = new Opportunity(
            Name = 'Clone Fallback Opp',
            AccountId = account.Id,
            StageName = 'Proposal/Quote',
            CloseDate = Date.today().addDays(30)
        );
        insert opportunity;
        insert new Quote(
            Name = 'Original 24-Month',
            OpportunityId = opportunity.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft',
            StartDate = Date.today(),
            EndDate = Date.today().addMonths(24)
        );
        FailingQuoteCloner fake = new FailingQuoteCloner();
        RLM_MCP_BuildQuoteOptions.quoteCloner = fake;

        Test.startTest();
        RLM_MCP_BuildQuoteOptions.BuildOutput out = run(
            'MCP Options Account',
            'Clone Fallback Opp',
            '[{"quoteName":"1-Year 10","termMonths":12,"discountPercent":10}]',
            'Original 24-Month',
            null
        );
        Test.stopTest();

        System.assert(
            out != null && out.isSuccess == true,
            'fallback should place: ' + (out == null ? 'null' : String.valueOf(out.errorMessage))
        );
        System.assertEquals(1, fake.calls);
        System.assert(
            out.optionsDisplay != null && out.optionsDisplay.contains('Clone failed'),
            String.valueOf(out.optionsDisplay)
        );
        System.assert(
            out.optionsDisplay.contains('bundle graph rejected'),
            String.valueOf(out.optionsDisplay)
        );
        System.assert(
            out.optionsDisplay.contains('Placed from source lines'),
            String.valueOf(out.optionsDisplay)
        );
        System.assertEquals(
            1,
            [SELECT COUNT() FROM Quote WHERE OpportunityId = :opportunity.Id AND Name = '1-Year 10']
        );
        System.assertEquals(
            1,
            [SELECT COUNT() FROM Quote WHERE OpportunityId = :opportunity.Id AND Name = 'Original 24-Month']
        );
    }

    @IsTest
    static void missingSourceQuoteReturnsError() {
        RLM_MCP_BuildQuoteOptions.BuildOutput out = run(
            'MCP Options Account',
            'Missing Source Opp',
            '[{"quoteName":"12-Month","termMonths":12,"discountPercent":10}]',
            'No Such Draft',
            null
        );
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('sourceQuoteName'), out.errorMessage);
        System.assertEquals(
            0,
            [SELECT COUNT() FROM Quote WHERE Opportunity.Name = 'Missing Source Opp']
        );
    }

    @IsTest
    static void emptyBuildReturnsNoResults() {
        System.assertEquals(0, RLM_MCP_BuildQuoteOptions.build(null).size());
        System.assertEquals(
            0,
            RLM_MCP_BuildQuoteOptions.build(new List<RLM_MCP_BuildQuoteOptions.BuildInput>()).size()
        );
    }

    private class CloneOkHttp implements HttpCalloutMock {
        Id cloneId;
        CloneOkHttp(Id cloneId) {
            this.cloneId = cloneId;
        }
        public HTTPResponse respond(HTTPRequest req) {
            System.assert(
                req.getEndpoint().contains('/connect/rev/sales-transaction/actions/clone'),
                req.getEndpoint()
            );
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"success":true,"salesTransactionId":"' + String.valueOf(cloneId) + '"}');
            return res;
        }
    }

    private static Quote insertDraft(String name, Id opportunityId) {
        Quote quote = new Quote(
            Name = name,
            OpportunityId = opportunityId,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft',
            StartDate = Date.today(),
            EndDate = Date.today().addMonths(24)
        );
        insert quote;
        return quote;
    }

    @IsTest
    static void parseConnectCloneResponseHappyPath() {
        Account account = [SELECT Id FROM Account WHERE Name = 'MCP Options Account' LIMIT 1];
        Opportunity opportunity = new Opportunity(
            Name = 'Connect Parse Opp',
            AccountId = account.Id,
            StageName = 'Proposal/Quote',
            CloseDate = Date.today().addDays(30)
        );
        insert opportunity;
        Quote source = insertDraft('Parse Source', opportunity.Id);
        Quote copy = insertDraft('Parse Copy', opportunity.Id);

        HttpResponse res = new HttpResponse();
        res.setStatusCode(200);
        res.setBody('{"success":true,"salesTransactionId":"' + String.valueOf(copy.Id) + '"}');
        RLM_MCP_BuildQuoteOptions.CloneResult parsed =
            RLM_MCP_BuildQuoteOptions.parseConnectCloneResponse(res, source.Id);
        System.assertEquals(
            copy.Id,
            parsed.quoteId,
            'expected clone id: ' + String.valueOf(parsed.error)
        );
        System.assertEquals(null, parsed.error);
    }

    @IsTest
    static void parseConnectCloneResponseErrors() {
        RLM_MCP_BuildQuoteOptions.CloneResult missing =
            RLM_MCP_BuildQuoteOptions.parseConnectCloneResponse(null, null);
        System.assert(String.isNotBlank(missing.error), 'null response should error');

        HttpResponse bad = new HttpResponse();
        bad.setStatusCode(400);
        bad.setBody('{"message":"Clone is not enabled"}');
        System.assert(
            RLM_MCP_BuildQuoteOptions.parseConnectCloneResponse(bad, null).error.contains('Clone is not enabled')
        );

        HttpResponse junk = new HttpResponse();
        junk.setStatusCode(200);
        junk.setBody('not-json');
        System.assert(
            RLM_MCP_BuildQuoteOptions.parseConnectCloneResponse(junk, null).error.contains('invalid JSON')
        );

        HttpResponse fail = new HttpResponse();
        fail.setStatusCode(200);
        fail.setBody('{"success":false,"errors":[{"message":"bundle graph rejected"}]}');
        System.assert(
            RLM_MCP_BuildQuoteOptions.parseConnectCloneResponse(fail, null).error.contains('bundle graph rejected')
        );

        HttpResponse noId = new HttpResponse();
        noId.setStatusCode(200);
        noId.setBody('{"success":true}');
        System.assert(
            RLM_MCP_BuildQuoteOptions.parseConnectCloneResponse(noId, null).error.contains('salesTransactionId')
        );
    }

    @IsTest
    static void parseConnectCloneRejectsSourceQuote() {
        Account account = [SELECT Id FROM Account WHERE Name = 'MCP Options Account' LIMIT 1];
        Opportunity opportunity = new Opportunity(
            Name = 'Connect Source Echo Opp',
            AccountId = account.Id,
            StageName = 'Proposal/Quote',
            CloseDate = Date.today().addDays(30)
        );
        insert opportunity;
        Quote source = insertDraft('Echo Source', opportunity.Id);
        HttpResponse res = new HttpResponse();
        res.setStatusCode(200);
        res.setBody('{"success":true,"salesTransactionId":"' + String.valueOf(source.Id) + '"}');
        RLM_MCP_BuildQuoteOptions.CloneResult parsed =
            RLM_MCP_BuildQuoteOptions.parseConnectCloneResponse(res, source.Id);
        System.assertEquals(null, parsed.quoteId);
        System.assert(parsed.error.contains('source quote'), parsed.error);
    }

    @IsTest
    static void connectCloneSkipsAfterDml() {
        Account account = [SELECT Id FROM Account WHERE Name = 'MCP Options Account' LIMIT 1];
        Opportunity opportunity = new Opportunity(
            Name = 'Connect Dml Opp',
            AccountId = account.Id,
            StageName = 'Proposal/Quote',
            CloseDate = Date.today().addDays(30)
        );
        insert opportunity;
        Quote source = insertDraft('Dml Source', opportunity.Id);
        RLM_MCP_BuildQuoteOptions.CloneResult result =
            RLM_MCP_BuildQuoteOptions.connectCloneQuote(source.Id);
        System.assertEquals(null, result.quoteId);
        System.assert(result.error.contains('skipped after DML'), result.error);
    }

    @IsTest
    static void connectCloneHttpMockReturnsQuote() {
        Account account = [SELECT Id FROM Account WHERE Name = 'MCP Options Account' LIMIT 1];
        Opportunity opportunity = new Opportunity(
            Name = 'Connect Http Opp',
            AccountId = account.Id,
            StageName = 'Proposal/Quote',
            CloseDate = Date.today().addDays(30)
        );
        insert opportunity;
        Quote source = insertDraft('Http Source', opportunity.Id);
        Quote copy = insertDraft('Http Copy', opportunity.Id);
        Test.setMock(HttpCalloutMock.class, new CloneOkHttp(copy.Id));
        Test.startTest();
        RLM_MCP_BuildQuoteOptions.CloneResult result =
            RLM_MCP_BuildQuoteOptions.connectCloneQuote(source.Id);
        Test.stopTest();
        System.assertEquals(
            copy.Id,
            result.quoteId,
            'expected clone id: ' + String.valueOf(result.error)
        );
    }

    @IsTest
    static void deepCloneSkipsInvocableWhenFlagged() {
        Account account = [SELECT Id FROM Account WHERE Name = 'MCP Options Account' LIMIT 1];
        Opportunity opportunity = new Opportunity(
            Name = 'Skip Invocable Opp',
            AccountId = account.Id,
            StageName = 'Proposal/Quote',
            CloseDate = Date.today().addDays(30)
        );
        insert opportunity;
        Quote source = insertDraft('Skip Invocable Source', opportunity.Id);
        RLM_MCP_BuildQuoteOptions.skipInvocableClone = true;
        RLM_MCP_BuildQuoteOptions.CloneResult result =
            new RLM_MCP_BuildQuoteOptions.DefaultQuoteCloner().cloneQuote(source.Id);
        System.assertEquals(null, result.quoteId);
        System.assert(String.isNotBlank(result.error), result.error);
    }
}
