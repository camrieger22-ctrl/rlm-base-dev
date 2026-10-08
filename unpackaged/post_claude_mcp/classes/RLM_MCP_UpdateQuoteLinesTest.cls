@IsTest
private class RLM_MCP_UpdateQuoteLinesTest {
    @TestSetup
    static void setup() {
        Id pbId = Test.getStandardPricebookId();
        update new Pricebook2(Id = pbId, IsActive = true);
        Account account = new Account(Name = 'MCP Update Lines Account');
        insert account;
        Opportunity opportunity = new Opportunity(
            Name = 'MCP Update Lines Opp',
            AccountId = account.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opportunity;
        Product2 database = new Product2(
            Name = 'QuantumBit Database',
            StockKeepingUnit = 'ZMCP-UPD-DB',
            IsActive = true
        );
        Product2 rack = new Product2(
            Name = 'QuantumBit Q-Rack 750',
            StockKeepingUnit = 'ZMCP-UPD-RACK',
            IsActive = true
        );
        Product2 maint = new Product2(
            Name = 'Software Maintenance',
            StockKeepingUnit = 'ZMCP-UPD-MAINT',
            IsActive = true
        );
        insert new List<Product2>{ database, rack, maint };
        insert new List<PricebookEntry>{
            new PricebookEntry(
                Pricebook2Id = pbId, Product2Id = database.Id, UnitPrice = 12000, IsActive = true
            ),
            new PricebookEntry(
                Pricebook2Id = pbId, Product2Id = rack.Id, UnitPrice = 5000, IsActive = true
            ),
            new PricebookEntry(
                Pricebook2Id = pbId, Product2Id = maint.Id, UnitPrice = 1000, IsActive = true
            )
        };
        Quote quote = new Quote(
            Name = 'MCP Update Lines Quote',
            OpportunityId = opportunity.Id,
            Pricebook2Id = pbId,
            Status = 'Draft'
        );
        insert quote;
        Map<Id, Id> pbeByProduct = new Map<Id, Id>();
        for (PricebookEntry pbe : [
            SELECT Id, Product2Id
            FROM PricebookEntry
            WHERE Product2Id IN :new List<Id>{ database.Id, rack.Id, maint.Id }
        ]) {
            pbeByProduct.put(pbe.Product2Id, pbe.Id);
        }
        insert new List<QuoteLineItem>{
            new QuoteLineItem(
                QuoteId = quote.Id,
                PricebookEntryId = pbeByProduct.get(database.Id),
                Product2Id = database.Id,
                Quantity = 10,
                UnitPrice = 12000
            ),
            new QuoteLineItem(
                QuoteId = quote.Id,
                PricebookEntryId = pbeByProduct.get(rack.Id),
                Product2Id = rack.Id,
                Quantity = 1,
                UnitPrice = 5000
            ),
            new QuoteLineItem(
                QuoteId = quote.Id,
                PricebookEntryId = pbeByProduct.get(maint.Id),
                Product2Id = maint.Id,
                Quantity = 5,
                UnitPrice = 1000
            )
        };
    }

    private static RLM_MCP_UpdateQuoteLines.UpdateOutput run(
        RLM_MCP_UpdateQuoteLines.UpdateInput input
    ) {
        return RLM_MCP_UpdateQuoteLines.updateLines(
            new List<RLM_MCP_UpdateQuoteLines.UpdateInput>{ input }
        )[0];
    }

    private static Id quoteId() {
        return [SELECT Id FROM Quote WHERE Name = 'MCP Update Lines Quote'].Id;
    }

    @IsTest
    static void requiresQuoteId() {
        RLM_MCP_UpdateQuoteLines.UpdateOutput out =
            run(new RLM_MCP_UpdateQuoteLines.UpdateInput());
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('Quote Id'), out.errorMessage);
    }

    @IsTest
    static void invalidJson() {
        RLM_MCP_UpdateQuoteLines.UpdateInput input =
            new RLM_MCP_UpdateQuoteLines.UpdateInput();
        input.quoteId = String.valueOf(quoteId());
        input.quantitiesJson = '{not-json';
        RLM_MCP_UpdateQuoteLines.UpdateOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('quantitiesJson'), out.errorMessage);
    }

    @IsTest
    static void patchesQtyAndDiscountInOneCall() {
        RLM_MCP_UpdateQuoteLines.UpdateInput input =
            new RLM_MCP_UpdateQuoteLines.UpdateInput();
        input.quoteId = String.valueOf(quoteId());
        input.quantitiesJson =
            '[{"product":"QB database","quantity":20},{"product":"QB Rack","quantity":3}]';
        input.discountPercentage = 20;

        Test.startTest();
        RLM_MCP_UpdateQuoteLines.UpdateOutput out = run(input);
        Test.stopTest();

        System.assertEquals(true, out.isSuccess, String.valueOf(out.errorMessage) + ' ' + out.resultsDisplay);
        System.assert(out.resultsDisplay.contains('QuantumBit Database'), out.resultsDisplay);
        System.assert(out.resultsDisplay.contains('qty 20'), out.resultsDisplay);
        System.assert(out.resultsDisplay.contains('20% off'), out.resultsDisplay);
        Map<String, QuoteLineItem> byName = new Map<String, QuoteLineItem>();
        for (QuoteLineItem line : [
            SELECT Quantity, Discount, Product2.Name
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId()
        ]) {
            byName.put(line.Product2.Name, line);
        }
        System.assertEquals(20, byName.get('QuantumBit Database').Quantity);
        System.assertEquals(3, byName.get('QuantumBit Q-Rack 750').Quantity);
        System.assertEquals(5, byName.get('Software Maintenance').Quantity);
        System.assertEquals(20, byName.get('QuantumBit Database').Discount);
        System.assertEquals(20, byName.get('Software Maintenance').Discount);
    }

    @IsTest
    static void unknownProduct() {
        RLM_MCP_UpdateQuoteLines.UpdateInput input =
            new RLM_MCP_UpdateQuoteLines.UpdateInput();
        input.quoteId = String.valueOf(quoteId());
        input.quantitiesJson = '[{"product":"No Such Widget","quantity":2}]';
        RLM_MCP_UpdateQuoteLines.UpdateOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('No quote line matched'), out.errorMessage);
    }
}
