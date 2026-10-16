@IsTest
private class RLM_MCP_BundleCoachTest {
    @TestSetup
    static void setup() {
        Id pbId = Test.getStandardPricebookId();
        activateStandardPricebook(pbId);
        Account account = new Account(Name = 'MCP Bundle Coach Account');
        insert account;
        Opportunity opportunity = new Opportunity(
            Name = 'MCP Bundle Coach Opp',
            AccountId = account.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opportunity;
        Product2 database = new Product2(
            Name = 'QuantumBit Database',
            StockKeepingUnit = 'MCP-COACH-DB',
            IsActive = true
        );
        Product2 rack = new Product2(
            Name = 'QuantumBit Q-Rack 750',
            StockKeepingUnit = 'MCP-COACH-QRACK',
            IsActive = true,
            Type = 'Bundle'
        );
        Product2 cpu = new Product2(
            Name = 'Q-Rack CPU',
            StockKeepingUnit = 'MCP-COACH-CPU',
            IsActive = true
        );
        insert new List<Product2>{ database, rack, cpu };
        insert new List<PricebookEntry>{
            new PricebookEntry(
                Pricebook2Id = pbId, Product2Id = database.Id, UnitPrice = 12000, IsActive = true
            ),
            new PricebookEntry(
                Pricebook2Id = pbId, Product2Id = rack.Id, UnitPrice = 3980, IsActive = true
            ),
            new PricebookEntry(
                Pricebook2Id = pbId, Product2Id = cpu.Id, UnitPrice = 500, IsActive = true
            )
        };
        Quote quote = new Quote(
            Name = 'MCP Bundle Coach Quote',
            OpportunityId = opportunity.Id,
            Pricebook2Id = pbId,
            Status = 'Draft'
        );
        insert quote;
        Map<String, Id> pbeBySku = new Map<String, Id>();
        for (PricebookEntry entry : [
            SELECT Id, Product2.StockKeepingUnit
            FROM PricebookEntry
            WHERE Product2.StockKeepingUnit IN ('MCP-COACH-DB', 'MCP-COACH-QRACK', 'MCP-COACH-CPU')
        ]) {
            pbeBySku.put(entry.Product2.StockKeepingUnit, entry.Id);
        }
        insert new QuoteLineItem(
            QuoteId = quote.Id,
            PricebookEntryId = pbeBySku.get('MCP-COACH-DB'),
            Product2Id = database.Id,
            Quantity = 10,
            UnitPrice = 12000
        );
        insert new QuoteLineItem(
            QuoteId = quote.Id,
            PricebookEntryId = pbeBySku.get('MCP-COACH-QRACK'),
            Product2Id = rack.Id,
            Quantity = 1,
            UnitPrice = 3980
        );
    }

    @IsTest
    static void databaseAddDoesNotGate() {
        Quote quote = [SELECT Id FROM Quote WHERE Name = 'MCP Bundle Coach Quote'];
        QuoteLineItem rack = [
            SELECT Id FROM QuoteLineItem
            WHERE QuoteId = :quote.Id AND Product2.Type = 'Bundle'
        ];
        delete rack;
        RLM_MCP_BundleCoach.Result gate = RLM_MCP_BundleCoach.forQuote(quote.Id);
        System.assertEquals(false, gate.needsAction);
        System.assertEquals(true, String.isBlank(gate.promptDisplay));
        System.assertEquals(
            'Added Database.',
            RLM_MCP_BundleCoach.append('Added Database.', gate)
        );
    }

    @IsTest
    static void unconfiguredQRackNeedsDescribe() {
        Quote quote = [SELECT Id FROM Quote WHERE Name = 'MCP Bundle Coach Quote'];
        QuoteLineItem rack = [
            SELECT Id FROM QuoteLineItem
            WHERE QuoteId = :quote.Id AND Product2.StockKeepingUnit = 'MCP-COACH-QRACK'
        ];
        Test.startTest();
        RLM_MCP_BundleCoach.Result gate = RLM_MCP_BundleCoach.forQuote(quote.Id);
        Test.stopTest();
        System.assertEquals(true, gate.needsAction);
        System.assert(gate.promptDisplay.contains('describeRevenueCloudBundleConfiguration'));
        System.assert(gate.promptDisplay.contains('quoteLineItemId ' + String.valueOf(rack.Id)));
        System.assert(gate.promptDisplay.contains('Q-Rack'));
        System.assert(gate.promptDisplay.contains('Never insert child'));
        String joined = RLM_MCP_BundleCoach.append('Added Q-Rack.', quote.Id);
        System.assert(joined.contains('Added Q-Rack.'));
        System.assert(joined.contains('Wait'));
    }

    @IsTest
    static void configuredBundleDoesNotReopen() {
        Quote quote = [SELECT Id FROM Quote WHERE Name = 'MCP Bundle Coach Quote'];
        QuoteLineItem rack = [
            SELECT Id FROM QuoteLineItem
            WHERE QuoteId = :quote.Id AND Product2.StockKeepingUnit = 'MCP-COACH-QRACK'
        ];
        RLM_MCP_BundleCoach.configuredParentIdsOverride = new Set<Id>{ rack.Id };
        RLM_MCP_BundleCoach.Result gate = RLM_MCP_BundleCoach.forQuote(quote.Id);
        System.assertEquals(false, gate.needsAction);
        System.assertEquals(true, String.isBlank(gate.promptDisplay));
    }

    private static void activateStandardPricebook(Id pbId) {
        for (Integer attempt = 0; attempt < 5; attempt++) {
            try {
                update new Pricebook2(Id = pbId, IsActive = true);
                return;
            } catch (DmlException e) {
                if (!e.getMessage().contains('UNABLE_TO_LOCK_ROW') || attempt == 4) {
                    throw e;
                }
            }
        }
    }
}
