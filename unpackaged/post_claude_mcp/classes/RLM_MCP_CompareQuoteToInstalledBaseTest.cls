@IsTest
private class RLM_MCP_CompareQuoteToInstalledBaseTest {
    @TestSetup
    static void setup() {
        Id pbId = Test.getStandardPricebookId();
        update new Pricebook2(Id = pbId, IsActive = true);
        Account account = new Account(Name = 'MCP Compare Acme');
        insert account;
        Opportunity opp = new Opportunity(
            Name = 'MCP Compare Opp',
            AccountId = account.Id,
            StageName = 'Proposal/Quote',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Product2 database = new Product2(
            Name = 'QuantumBit Database',
            StockKeepingUnit = 'ZMCP-CMP-DB',
            IsActive = true
        );
        Product2 rack = new Product2(
            Name = 'QuantumBit Q-Rack 750',
            StockKeepingUnit = 'ZMCP-CMP-RACK',
            IsActive = true
        );
        insert new List<Product2>{ database, rack };
        insert new List<PricebookEntry>{
            new PricebookEntry(
                Pricebook2Id = pbId, Product2Id = database.Id, UnitPrice = 12000, IsActive = true
            ),
            new PricebookEntry(
                Pricebook2Id = pbId, Product2Id = rack.Id, UnitPrice = 3980, IsActive = true
            )
        };
        Quote quote = new Quote(
            Name = 'MCP Compare Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = pbId,
            Status = 'Draft'
        );
        insert quote;
        Map<Id, Id> pbeByProduct = new Map<Id, Id>();
        for (PricebookEntry pbe : [
            SELECT Id, Product2Id FROM PricebookEntry
            WHERE Product2Id IN :new List<Id>{ database.Id, rack.Id }
        ]) {
            pbeByProduct.put(pbe.Product2Id, pbe.Id);
        }
        insert new List<QuoteLineItem>{
            new QuoteLineItem(
                QuoteId = quote.Id,
                PricebookEntryId = pbeByProduct.get(database.Id),
                Product2Id = database.Id,
                Quantity = 50,
                UnitPrice = 12000,
                Discount = 30
            ),
            new QuoteLineItem(
                QuoteId = quote.Id,
                PricebookEntryId = pbeByProduct.get(rack.Id),
                Product2Id = rack.Id,
                Quantity = 8,
                UnitPrice = 3980,
                Discount = 30
            )
        };
        insert new Asset(
            Name = 'QuantumBit Database',
            AccountId = account.Id,
            Product2Id = database.Id,
            Quantity = 1,
            Status = 'Purchased'
        );
    }

    private static RLM_MCP_CompareQuoteToInstalledBase.CompareOutput run(
        RLM_MCP_CompareQuoteToInstalledBase.CompareInput input
    ) {
        return RLM_MCP_CompareQuoteToInstalledBase.compare(
            new List<RLM_MCP_CompareQuoteToInstalledBase.CompareInput>{ input }
        )[0];
    }

    @IsTest
    static void requiresIdentity() {
        RLM_MCP_CompareQuoteToInstalledBase.CompareOutput out =
            run(new RLM_MCP_CompareQuoteToInstalledBase.CompareInput());
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('quoteId'), '' + out.errorMessage);
    }

    @IsTest
    static void comparesQuoteLines() {
        Id quoteId = [SELECT Id FROM Quote WHERE Name = 'MCP Compare Quote'].Id;
        RLM_MCP_CompareQuoteToInstalledBase.CompareInput input =
            new RLM_MCP_CompareQuoteToInstalledBase.CompareInput();
        input.quoteId = String.valueOf(quoteId);

        Test.startTest();
        RLM_MCP_CompareQuoteToInstalledBase.CompareOutput out = run(input);
        Test.stopTest();

        System.assertEquals(true, out.isSuccess, '' + out.errorMessage);
        System.assert(out.summaryDisplay.contains('QuantumBit Q-Rack 750'), '' + out.summaryDisplay);
        System.assert(out.summaryDisplay.contains('30% off'), '' + out.summaryDisplay);
        System.assert(out.summaryDisplay.contains('new on quote'), '' + out.summaryDisplay);
    }
}
