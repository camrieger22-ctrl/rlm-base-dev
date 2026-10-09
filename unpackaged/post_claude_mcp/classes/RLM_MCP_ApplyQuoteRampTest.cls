@IsTest
private class RLM_MCP_ApplyQuoteRampTest {
    @TestSetup
    static void setup() {
        Id pbId = Test.getStandardPricebookId();
        update new Pricebook2(Id = pbId, IsActive = true);
        Account account = new Account(Name = 'MCP Ramp Acme');
        insert account;
        Opportunity opp = new Opportunity(
            Name = 'MCP Ramp Opp',
            AccountId = account.Id,
            StageName = 'Proposal/Quote',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Product2 product = new Product2(
            Name = 'QuantumBit Database',
            StockKeepingUnit = 'ZMCP-RMP-DB',
            IsActive = true
        );
        insert product;
        insert new PricebookEntry(
            Pricebook2Id = pbId, Product2Id = product.Id, UnitPrice = 12000, IsActive = true
        );
        Quote quote = new Quote(
            Name = 'MCP Ramp Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = pbId,
            Status = 'Draft'
        );
        insert quote;
        QuoteLineGroup year1 = new QuoteLineGroup(
            QuoteId = quote.Id,
            Name = 'Year 1',
            SortOrder = 1,
            IsRamped = true,
            SegmentType = 'Yearly',
            StartDate = Date.newInstance(2026, 1, 1),
            EndDate = Date.newInstance(2026, 12, 31)
        );
        QuoteLineGroup year2 = new QuoteLineGroup(
            QuoteId = quote.Id,
            Name = 'Year 2',
            SortOrder = 2,
            IsRamped = true,
            SegmentType = 'Yearly',
            StartDate = Date.newInstance(2027, 1, 1),
            EndDate = Date.newInstance(2027, 12, 31)
        );
        insert new List<QuoteLineGroup>{ year1, year2 };
        Id pbeId = [SELECT Id FROM PricebookEntry WHERE Product2Id = :product.Id].Id;
        insert new List<QuoteLineItem>{
            new QuoteLineItem(
                QuoteId = quote.Id,
                QuoteLineGroupId = year1.Id,
                PricebookEntryId = pbeId,
                Product2Id = product.Id,
                Quantity = 10,
                UnitPrice = 12000
            ),
            new QuoteLineItem(
                QuoteId = quote.Id,
                QuoteLineGroupId = year2.Id,
                PricebookEntryId = pbeId,
                Product2Id = product.Id,
                Quantity = 10,
                UnitPrice = 12000
            )
        };
    }

    private static RLM_MCP_ApplyQuoteRamp.RampOutput run(RLM_MCP_ApplyQuoteRamp.RampInput input) {
        return RLM_MCP_ApplyQuoteRamp.applyRamp(
            new List<RLM_MCP_ApplyQuoteRamp.RampInput>{ input }
        )[0];
    }

    @IsTest
    static void requiresQuoteId() {
        RLM_MCP_ApplyQuoteRamp.RampOutput out = run(new RLM_MCP_ApplyQuoteRamp.RampInput());
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('Quote Id'), '' + out.errorMessage);
    }

    @IsTest
    static void describesExistingSegments() {
        Id quoteId = [SELECT Id FROM Quote WHERE Name = 'MCP Ramp Quote'].Id;
        RLM_MCP_ApplyQuoteRamp.RampInput input = new RLM_MCP_ApplyQuoteRamp.RampInput();
        input.quoteId = String.valueOf(quoteId);
        Test.startTest();
        RLM_MCP_ApplyQuoteRamp.RampOutput out = run(input);
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, '' + out.errorMessage);
        System.assert(out.resultsDisplay.contains('Year 1'), '' + out.resultsDisplay);
        System.assert(out.resultsDisplay.contains('2 ramp segments'), '' + out.resultsDisplay);
    }

    @IsTest
    static void appliesSegmentQuantities() {
        Id quoteId = [SELECT Id FROM Quote WHERE Name = 'MCP Ramp Quote'].Id;
        RLM_MCP_ApplyQuoteRamp.RampInput input = new RLM_MCP_ApplyQuoteRamp.RampInput();
        input.quoteId = String.valueOf(quoteId);
        input.productName = 'QuantumBit Database';
        input.segmentsJson = '[{"quantity":10},{"quantity":20}]';
        Test.startTest();
        RLM_MCP_ApplyQuoteRamp.RampOutput out = run(input);
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, '' + out.errorMessage);
        System.assert(out.resultsDisplay.contains('qty 20'), '' + out.resultsDisplay);
        List<QuoteLineItem> lines = [
            SELECT Quantity, QuoteLineGroup.SortOrder
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            ORDER BY QuoteLineGroup.SortOrder
        ];
        System.assertEquals(10, lines[0].Quantity);
        System.assertEquals(20, lines[1].Quantity);
    }
}
