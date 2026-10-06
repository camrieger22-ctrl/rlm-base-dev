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
        RLM_MCP_BuildQuoteOptions.BuildInput input = new RLM_MCP_BuildQuoteOptions.BuildInput();
        input.accountName = accountName;
        input.opportunityName = opportunityName;
        input.optionsJson = optionsJson;
        return RLM_MCP_BuildQuoteOptions.build(
            new List<RLM_MCP_BuildQuoteOptions.BuildInput>{ input }
        )[0];
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
    static void emptyBuildReturnsNoResults() {
        System.assertEquals(0, RLM_MCP_BuildQuoteOptions.build(null).size());
        System.assertEquals(
            0,
            RLM_MCP_BuildQuoteOptions.build(new List<RLM_MCP_BuildQuoteOptions.BuildInput>()).size()
        );
    }
}
