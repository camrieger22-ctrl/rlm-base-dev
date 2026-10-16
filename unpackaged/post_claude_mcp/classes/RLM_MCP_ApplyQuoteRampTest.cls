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
        System.assertEquals(true, out.isSuccess, 'failed: ' + out.errorMessage);
        System.assert(out.resultsDisplay.contains('Year 1'), '' + out.resultsDisplay);
        System.assert(out.resultsDisplay.contains('2 ramp segments'), '' + out.resultsDisplay);
    }

    @IsTest
    static void refusesCreateWhenNoSchedule() {
        Id pbId = Test.getStandardPricebookId();
        Account account = new Account(Name = 'MCP Empty Ramp Acme');
        insert account;
        Opportunity opp = new Opportunity(
            Name = 'MCP Empty Ramp Opp',
            AccountId = account.Id,
            StageName = 'Proposal/Quote',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Quote quote = new Quote(
            Name = 'MCP Empty Ramp Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = pbId,
            Status = 'Draft',
            StartDate = Date.today()
        );
        insert quote;
        RLM_MCP_ApplyQuoteRamp.RampInput input = new RLM_MCP_ApplyQuoteRamp.RampInput();
        input.quoteId = String.valueOf(quote.Id);
        input.productName = 'QuantumBit Database';
        input.segmentsJson = '[{"quantity":10},{"quantity":20}]';
        Test.startTest();
        RLM_MCP_ApplyQuoteRamp.RampOutput out = run(input);
        Test.stopTest();
        System.assertEquals(false, out.isSuccess);
        System.assert(
            out.errorMessage.contains('createRevenueCloudRampSchedule'),
            '' + out.errorMessage
        );
        System.assertEquals(
            0,
            [SELECT COUNT() FROM QuoteLineGroup WHERE QuoteId = :quote.Id]
        );
    }

    @IsTest
    static void addsProductWhenScheduleExistsWithoutLines() {
        Id pbId = Test.getStandardPricebookId();
        Account account = new Account(Name = 'MCP Add Ramp Acme');
        insert account;
        Opportunity opp = new Opportunity(
            Name = 'MCP Add Ramp Opp',
            AccountId = account.Id,
            StageName = 'Proposal/Quote',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Product2 product = new Product2(
            Name = 'ZMCP Ramp Add Database',
            StockKeepingUnit = 'ZMCP-ADD-DB',
            IsActive = true
        );
        insert product;
        insert new PricebookEntry(
            Pricebook2Id = pbId, Product2Id = product.Id, UnitPrice = 12000, IsActive = true
        );
        Quote quote = new Quote(
            Name = 'MCP Add Ramp Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = pbId,
            Status = 'Draft',
            StartDate = Date.today()
        );
        insert quote;
        insert new List<QuoteLineGroup>{
            new QuoteLineGroup(
                QuoteId = quote.Id,
                Name = 'Year 1',
                SortOrder = 1,
                IsRamped = true,
                SegmentType = 'Yearly',
                StartDate = Date.newInstance(2026, 1, 1),
                EndDate = Date.newInstance(2026, 12, 31)
            ),
            new QuoteLineGroup(
                QuoteId = quote.Id,
                Name = 'Year 2',
                SortOrder = 2,
                IsRamped = true,
                SegmentType = 'Yearly',
                StartDate = Date.newInstance(2027, 1, 1),
                EndDate = Date.newInstance(2027, 12, 31)
            )
        };
        RLM_MCP_ApplyQuoteRamp.RampInput input = new RLM_MCP_ApplyQuoteRamp.RampInput();
        input.quoteId = String.valueOf(quote.Id);
        input.productName = 'ZMCP Ramp Add Database';
        input.segmentsJson = '[{"quantity":10},{"quantity":20}]';
        Test.startTest();
        RLM_MCP_ApplyQuoteRamp.RampOutput out = run(input);
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, 'failed: ' + out.errorMessage);
        System.assert(out.resultsDisplay.contains('qty 20'), '' + out.resultsDisplay);
        List<QuoteLineItem> lines = [
            SELECT Quantity, QuoteLineGroup.SortOrder
            FROM QuoteLineItem
            WHERE QuoteId = :quote.Id
            ORDER BY QuoteLineGroup.SortOrder
        ];
        System.assertEquals(2, lines.size());
        System.assertEquals(10, lines[0].Quantity);
        System.assertEquals(20, lines[1].Quantity);
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
        System.assertEquals(true, out.isSuccess, 'failed: ' + out.errorMessage);
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

    @IsTest
    static void mapsThreeQtysOntoTrialYearsAndProratedStub() {
        List<QuoteLineGroup> ramped = new List<QuoteLineGroup>{
            groupOf('Trial', 'FreeTrial', 1),
            groupOf('Year 1', 'Yearly', 2),
            groupOf('Year 2', 'Yearly', 3),
            groupOf('Year 3', 'Yearly', 4),
            groupOf('Year 4 - Pro-rated', 'Prorated', 5)
        };
        RLM_MCP_ApplyQuoteRamp.RampOutput out = new RLM_MCP_ApplyQuoteRamp.RampOutput();
        RLM_MCP_ApplyQuoteRamp.QtyPlan plan = RLM_MCP_ApplyQuoteRamp.planSegmentQuantities(
            ramped,
            new List<Decimal>{ 10, 20, 30 },
            out
        );
        System.assert(String.isBlank(out.errorMessage), 'segment match failed');
        System.assertEquals(5, plan.targets.size());
        System.assertEquals('Trial', plan.targets[0].Name);
        System.assertEquals('Year 4 - Pro-rated', plan.targets[4].Name);
        System.assertEquals(10, plan.qtys[0]);
        System.assertEquals(10, plan.qtys[1]);
        System.assertEquals(20, plan.qtys[2]);
        System.assertEquals(30, plan.qtys[3]);
        System.assertEquals(30, plan.qtys[4]);
    }

    @IsTest
    static void resolvesTrialYearAndStubAliases() {
        List<QuoteLineGroup> ramped = new List<QuoteLineGroup>{
            groupOf('Trial', 'FreeTrial', 1),
            groupOf('Year 1', 'Yearly', 2),
            groupOf('Year 2', 'Yearly', 3),
            groupOf('Year 3', 'Yearly', 4),
            groupOf('Year 4 - Pro-rated', 'Prorated', 5)
        };
        RLM_MCP_ApplyQuoteRamp.RampOutput out = new RLM_MCP_ApplyQuoteRamp.RampOutput();
        List<QuoteLineGroup> trial = RLM_MCP_ApplyQuoteRamp.resolveTargetGroups(
            new List<String>{ 'the trial' }, ramped, out
        );
        System.assert(String.isBlank(out.errorMessage), 'trial alias failed');
        System.assertEquals(1, trial.size());
        System.assertEquals('Trial', trial[0].Name);
        List<QuoteLineGroup> y2 = RLM_MCP_ApplyQuoteRamp.resolveTargetGroups(
            new List<String>{ 'Y2' }, ramped, out
        );
        System.assertEquals('Year 2', y2[0].Name);
        List<QuoteLineGroup> stub = RLM_MCP_ApplyQuoteRamp.resolveTargetGroups(
            new List<String>{ 'prorated' }, ramped, out
        );
        System.assertEquals('Year 4 - Pro-rated', stub[0].Name);
        List<QuoteLineGroup> paid = RLM_MCP_ApplyQuoteRamp.resolveTargetGroups(
            new List<String>{ 'paid' }, ramped, out
        );
        System.assertEquals(4, paid.size());
        List<QuoteLineGroup> y23 = RLM_MCP_ApplyQuoteRamp.resolveTargetGroups(
            new List<String>{ 'Year 2', 'Year 3' }, ramped, out
        );
        System.assertEquals(2, y23.size());
        System.assertEquals('Year 2', y23[0].Name);
        System.assertEquals('Year 3', y23[1].Name);
    }

    @IsTest
    static void addsSecondSkuToYear2Only() {
        Id quoteId = [SELECT Id FROM Quote WHERE Name = 'MCP Ramp Quote'].Id;
        Id pbId = Test.getStandardPricebookId();
        Product2 rack = new Product2(
            Name = 'ZMCP Edit Rack',
            StockKeepingUnit = 'ZMCP-EDIT-RACK',
            IsActive = true
        );
        insert rack;
        insert new PricebookEntry(
            Pricebook2Id = pbId, Product2Id = rack.Id, UnitPrice = 5000, IsActive = true
        );
        RLM_MCP_ApplyQuoteRamp.RampInput input = new RLM_MCP_ApplyQuoteRamp.RampInput();
        input.quoteId = String.valueOf(quoteId);
        input.editsJson =
            '[{"product":"ZMCP Edit Rack","segments":["Year 2"],"quantity":1}]';
        Test.startTest();
        RLM_MCP_ApplyQuoteRamp.RampOutput out = run(input);
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, 'failed: ' + out.errorMessage);
        List<QuoteLineItem> rackLines = [
            SELECT Quantity, QuoteLineGroup.Name
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            AND Product2.Name = 'ZMCP Edit Rack'
        ];
        System.assertEquals(1, rackLines.size());
        System.assertEquals('Year 2', rackLines[0].QuoteLineGroup.Name);
        System.assertEquals(1, rackLines[0].Quantity);
        System.assertEquals(
            2,
            [SELECT COUNT() FROM QuoteLineItem WHERE QuoteId = :quoteId AND Product2.Name = 'QuantumBit Database']
        );
    }

    @IsTest
    static void removesProductFromYear1Only() {
        Id quoteId = [SELECT Id FROM Quote WHERE Name = 'MCP Ramp Quote'].Id;
        RLM_MCP_ApplyQuoteRamp.RampInput input = new RLM_MCP_ApplyQuoteRamp.RampInput();
        input.quoteId = String.valueOf(quoteId);
        input.editsJson =
            '[{"product":"QuantumBit Database","segments":["Year 1"],"remove":true}]';
        Test.startTest();
        RLM_MCP_ApplyQuoteRamp.RampOutput out = run(input);
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, 'failed: ' + out.errorMessage);
        System.assert(out.resultsDisplay.contains('removed'), '' + out.resultsDisplay);
        List<QuoteLineItem> remaining = [
            SELECT QuoteLineGroup.Name
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            ORDER BY QuoteLineGroup.SortOrder
        ];
        System.assertEquals(1, remaining.size());
        System.assertEquals('Year 2', remaining[0].QuoteLineGroup.Name);
    }

    @IsTest
    static void patchesYear2QtyAndPerYearDiscount() {
        Id quoteId = [SELECT Id FROM Quote WHERE Name = 'MCP Ramp Quote'].Id;
        RLM_MCP_ApplyQuoteRamp.RampInput input = new RLM_MCP_ApplyQuoteRamp.RampInput();
        input.quoteId = String.valueOf(quoteId);
        input.editsJson =
            '[{"product":"QuantumBit Database","segments":["Year 2"],"quantity":25},'
            + '{"product":"QuantumBit Database","segments":["Year 1"],"discount":20},'
            + '{"product":"QuantumBit Database","segments":["Year 2"],"discount":40}]';
        Test.startTest();
        RLM_MCP_ApplyQuoteRamp.RampOutput out = run(input);
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, 'failed: ' + out.errorMessage);
        Map<String, QuoteLineItem> byGroup = new Map<String, QuoteLineItem>();
        for (QuoteLineItem line : [
            SELECT Quantity, Discount, QuoteLineGroup.Name
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
        ]) {
            byGroup.put(line.QuoteLineGroup.Name, line);
        }
        System.assertEquals(10, byGroup.get('Year 1').Quantity);
        System.assertEquals(20, byGroup.get('Year 1').Discount);
        System.assertEquals(25, byGroup.get('Year 2').Quantity);
        System.assertEquals(40, byGroup.get('Year 2').Discount);
    }

    @IsTest
    static void mixedEditsJsonAddRemoveDiscount() {
        Id pbId = Test.getStandardPricebookId();
        Account account = new Account(Name = 'MCP Mix Ramp Acme');
        insert account;
        Opportunity opp = new Opportunity(
            Name = 'MCP Mix Ramp Opp',
            AccountId = account.Id,
            StageName = 'Proposal/Quote',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Product2 db = new Product2(
            Name = 'ZMCP Mix Database',
            StockKeepingUnit = 'ZMCP-MIX-DB',
            IsActive = true
        );
        Product2 rack = new Product2(
            Name = 'ZMCP Mix Rack',
            StockKeepingUnit = 'ZMCP-MIX-RACK',
            IsActive = true
        );
        insert new List<Product2>{ db, rack };
        insert new List<PricebookEntry>{
            new PricebookEntry(
                Pricebook2Id = pbId, Product2Id = db.Id, UnitPrice = 12000, IsActive = true
            ),
            new PricebookEntry(
                Pricebook2Id = pbId, Product2Id = rack.Id, UnitPrice = 5000, IsActive = true
            )
        };
        Quote quote = new Quote(
            Name = 'MCP Mix Ramp Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = pbId,
            Status = 'Draft',
            StartDate = Date.today()
        );
        insert quote;
        QuoteLineGroup trial = new QuoteLineGroup(
            QuoteId = quote.Id,
            Name = 'Trial',
            SortOrder = 1,
            IsRamped = true,
            SegmentType = 'FreeTrial',
            Discount = 100,
            StartDate = Date.newInstance(2026, 10, 15),
            EndDate = Date.newInstance(2026, 11, 13)
        );
        QuoteLineGroup year1 = new QuoteLineGroup(
            QuoteId = quote.Id,
            Name = 'Year 1',
            SortOrder = 2,
            IsRamped = true,
            SegmentType = 'Yearly',
            StartDate = Date.newInstance(2026, 11, 14),
            EndDate = Date.newInstance(2027, 11, 13)
        );
        QuoteLineGroup year2 = new QuoteLineGroup(
            QuoteId = quote.Id,
            Name = 'Year 2',
            SortOrder = 3,
            IsRamped = true,
            SegmentType = 'Yearly',
            StartDate = Date.newInstance(2027, 11, 14),
            EndDate = Date.newInstance(2028, 11, 13)
        );
        insert new List<QuoteLineGroup>{ trial, year1, year2 };
        Id dbPbe = [SELECT Id FROM PricebookEntry WHERE Product2Id = :db.Id].Id;
        insert new List<QuoteLineItem>{
            new QuoteLineItem(
                QuoteId = quote.Id,
                QuoteLineGroupId = trial.Id,
                PricebookEntryId = dbPbe,
                Product2Id = db.Id,
                Quantity = 10,
                UnitPrice = 12000,
                Discount = 100
            ),
            new QuoteLineItem(
                QuoteId = quote.Id,
                QuoteLineGroupId = year1.Id,
                PricebookEntryId = dbPbe,
                Product2Id = db.Id,
                Quantity = 10,
                UnitPrice = 12000
            ),
            new QuoteLineItem(
                QuoteId = quote.Id,
                QuoteLineGroupId = year2.Id,
                PricebookEntryId = dbPbe,
                Product2Id = db.Id,
                Quantity = 20,
                UnitPrice = 12000
            )
        };
        RLM_MCP_ApplyQuoteRamp.RampInput input = new RLM_MCP_ApplyQuoteRamp.RampInput();
        input.quoteId = String.valueOf(quote.Id);
        input.editsJson =
            '[{"product":"ZMCP Mix Rack","segments":["Year 1","Year 2"],"quantity":1},'
            + '{"product":"ZMCP Mix Database","segments":["Trial"],"remove":true},'
            + '{"product":"ZMCP Mix Database","segments":["Year 2"],"discount":20}]';
        Test.startTest();
        RLM_MCP_ApplyQuoteRamp.RampOutput out = run(input);
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, 'failed: ' + out.errorMessage);
        Map<String, Decimal> dbQty = new Map<String, Decimal>();
        Map<String, Decimal> dbDisc = new Map<String, Decimal>();
        Integer rackCount = 0;
        for (QuoteLineItem line : [
            SELECT Quantity, Discount, Product2.Name, QuoteLineGroup.Name
            FROM QuoteLineItem
            WHERE QuoteId = :quote.Id
        ]) {
            if (line.Product2.Name == 'ZMCP Mix Rack') {
                rackCount++;
                System.assert(line.QuoteLineGroup.Name != 'Trial', line.QuoteLineGroup.Name);
            } else {
                dbQty.put(line.QuoteLineGroup.Name, line.Quantity);
                dbDisc.put(line.QuoteLineGroup.Name, line.Discount);
            }
        }
        System.assertEquals(2, rackCount);
        System.assert(!dbQty.containsKey('Trial'));
        System.assertEquals(10, dbQty.get('Year 1'));
        System.assertEquals(20, dbQty.get('Year 2'));
        System.assertEquals(20, dbDisc.get('Year 2'));
    }

    @IsTest
    static void unconfiguredBundleAddKeepsNeedsAction() {
        Quote quote = [SELECT Id FROM Quote WHERE Name = 'MCP Ramp Quote'];
        Id pbId = Test.getStandardPricebookId();
        Product2 rack = new Product2(
            Name = 'QuantumBit Q-Rack 750',
            StockKeepingUnit = 'ZMCP-RAMP-QRACK',
            IsActive = true,
            Type = 'Bundle'
        );
        insert rack;
        insert new PricebookEntry(
            Pricebook2Id = pbId, Product2Id = rack.Id, UnitPrice = 3980, IsActive = true
        );
        Id rackPbe = [SELECT Id FROM PricebookEntry WHERE Product2Id = :rack.Id].Id;
        QuoteLineGroup year2 = [
            SELECT Id FROM QuoteLineGroup WHERE QuoteId = :quote.Id AND Name = 'Year 2'
        ];
        insert new QuoteLineItem(
            QuoteId = quote.Id,
            QuoteLineGroupId = year2.Id,
            PricebookEntryId = rackPbe,
            Product2Id = rack.Id,
            Quantity = 1,
            UnitPrice = 3980
        );
        RLM_MCP_ApplyQuoteRamp.RampInput input = new RLM_MCP_ApplyQuoteRamp.RampInput();
        input.quoteId = String.valueOf(quote.Id);
        input.editsJson =
            '[{"product":"QuantumBit Database","segments":["Year 1"],"quantity":11}]';
        Test.startTest();
        RLM_MCP_ApplyQuoteRamp.RampOutput out = run(input);
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, 'failed: ' + out.errorMessage);
        System.assertEquals(true, out.needsAction);
        System.assert(out.resultsDisplay.contains('describeRevenueCloudBundleConfiguration'));
        System.assert(out.resultsDisplay.contains('Q-Rack'));
    }

    @IsTest
    static void parseEditsAllowsYearBlanket() {
        RLM_MCP_ApplyQuoteRamp.RampOutput parsed =
            new RLM_MCP_ApplyQuoteRamp.RampOutput();
        List<RLM_MCP_ApplyQuoteRamp.RampEdit> edits =
            RLM_MCP_ApplyQuoteRamp.parseEdits(
                '[{"segments":["Year 2"],"discount":25},'
                + '{"product":"QB-PowerSafe 1000D","segments":["Year 3"],"discount":20}]',
                parsed
            );
        System.assert(String.isBlank(parsed.errorMessage), 'failed: ' + parsed.errorMessage);
        System.assertEquals(2, edits.size());
        System.assertEquals(true, String.isBlank(edits[0].product));
        System.assertEquals(25, edits[0].discount);
        System.assertEquals('QB-PowerSafe 1000D', edits[1].product);
        System.assertEquals(20, edits[1].discount);
        RLM_MCP_ApplyQuoteRamp.RampOutput missing =
            new RLM_MCP_ApplyQuoteRamp.RampOutput();
        RLM_MCP_ApplyQuoteRamp.parseEdits(
            '[{"segments":["Year 2"],"quantity":2}]', missing);
        System.assert(missing.errorMessage.contains('product'), missing.errorMessage);
    }

    @IsTest
    static void blanketYear2StampsAllLines() {
        Quote quote = [SELECT Id FROM Quote WHERE Name = 'MCP Ramp Quote'];
        insertPowerSafeOnYears(quote.Id);
        RLM_MCP_ApplyQuoteRamp.RampInput input = new RLM_MCP_ApplyQuoteRamp.RampInput();
        input.quoteId = String.valueOf(quote.Id);
        input.editsJson = '[{"segments":["Year 2"],"discount":25}]';
        Test.startTest();
        RLM_MCP_ApplyQuoteRamp.RampOutput out = run(input);
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, 'failed: ' + out.errorMessage);
        System.assert(out.resultsDisplay.contains('all lines'), out.resultsDisplay);
        Map<String, Decimal> disc = discountsByYearAndSku(quote.Id);
        System.assertEquals(25, disc.get('Year 2|ZMCP-RMP-DB'));
        System.assertEquals(25, disc.get('Year 2|ZMCP-RMP-PS'));
        System.assertEquals(true, disc.get('Year 1|ZMCP-RMP-DB') == null
            || disc.get('Year 1|ZMCP-RMP-DB') == 0);
        System.assertEquals(true, disc.get('Year 1|ZMCP-RMP-PS') == null
            || disc.get('Year 1|ZMCP-RMP-PS') == 0);
    }

    @IsTest
    static void blanketThenNamedException() {
        Quote quote = [SELECT Id FROM Quote WHERE Name = 'MCP Ramp Quote'];
        insertPowerSafeOnYears(quote.Id);
        RLM_MCP_ApplyQuoteRamp.RampInput input = new RLM_MCP_ApplyQuoteRamp.RampInput();
        input.quoteId = String.valueOf(quote.Id);
        input.editsJson =
            '[{"segments":["Year 2"],"discount":35},'
            + '{"product":"QB-PowerSafe 1000D","segments":["Year 2"],"discount":20}]';
        Test.startTest();
        RLM_MCP_ApplyQuoteRamp.RampOutput out = run(input);
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, 'failed: ' + out.errorMessage);
        Map<String, Decimal> disc = discountsByYearAndSku(quote.Id);
        System.assertEquals(35, disc.get('Year 2|ZMCP-RMP-DB'));
        System.assertEquals(20, disc.get('Year 2|ZMCP-RMP-PS'));
        System.assert(out.resultsDisplay.contains('PowerSafe'), out.resultsDisplay);
    }

    @IsTest
    static void childQtyIsBlocked() {
        QuoteLineItem parent = [
            SELECT Id, QuoteLineGroupId, ParentQuoteLineItemId,
                Product2.Name, Product2.StockKeepingUnit
            FROM QuoteLineItem
            WHERE Quote.Name = 'MCP Ramp Quote'
            AND QuoteLineGroup.Name = 'Year 2'
            LIMIT 1
        ];
        QuoteLineItem child = fakeChild(parent.Id, parent.QuoteLineGroupId);
        List<QuoteLineItem> lines = new List<QuoteLineItem>{ parent, child };
        System.assertEquals(
            null,
            RLM_MCP_ApplyQuoteRamp.matchInGroupQuiet(
                'QB-PowerSafe 1000D', parent.QuoteLineGroupId, lines)
        );
        System.assertEquals(
            child,
            RLM_MCP_ApplyQuoteRamp.matchChildInGroupQuiet(
                'QB-PowerSafe 1000D', parent.QuoteLineGroupId, lines)
        );
        RLM_MCP_ApplyQuoteRamp.RampOutput parsed =
            new RLM_MCP_ApplyQuoteRamp.RampOutput();
        QuoteLineItem hit = RLM_MCP_ApplyQuoteRamp.matchInGroupForDiscount(
            'QB-PowerSafe 1000D', parent.QuoteLineGroupId, lines, parsed);
        System.assertEquals(child, hit);
        System.assert(String.isBlank(parsed.errorMessage), 'failed: ' + parsed.errorMessage);
        RLM_MCP_ApplyQuoteRamp.extraChildForTest = fakeChild(
            parent.Id, parent.QuoteLineGroupId);
        RLM_MCP_ApplyQuoteRamp.RampInput input = new RLM_MCP_ApplyQuoteRamp.RampInput();
        input.quoteId = String.valueOf([SELECT Id FROM Quote WHERE Name = 'MCP Ramp Quote'].Id);
        input.editsJson =
            '[{"product":"QB-PowerSafe 1000D","segments":["Year 2"],"quantity":2}]';
        RLM_MCP_ApplyQuoteRamp.RampOutput out = run(input);
        RLM_MCP_ApplyQuoteRamp.extraChildForTest = null;
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('bundle component'), out.errorMessage);
    }

    private static QuoteLineItem fakeChild(Id parentId, Id groupId) {
        QuoteLineItem child = (QuoteLineItem) JSON.deserialize(
            '{"QuoteLineGroupId":"' + groupId
            + '","ParentQuoteLineItemId":"' + parentId + '"}',
            QuoteLineItem.class
        );
        child.Product2 = new Product2(
            Name = 'QB-PowerSafe 1000D',
            StockKeepingUnit = 'ZMCP-RMP-PS'
        );
        return child;
    }

    private static void insertPowerSafeOnYears(Id quoteId) {
        Id pbId = Test.getStandardPricebookId();
        Product2 powerSafe = new Product2(
            Name = 'QB-PowerSafe 1000D',
            StockKeepingUnit = 'ZMCP-RMP-PS',
            IsActive = true
        );
        insert powerSafe;
        insert new PricebookEntry(
            Pricebook2Id = pbId, Product2Id = powerSafe.Id, UnitPrice = 500, IsActive = true
        );
        Id pbeId = [SELECT Id FROM PricebookEntry WHERE Product2Id = :powerSafe.Id].Id;
        List<QuoteLineItem> rows = new List<QuoteLineItem>();
        for (QuoteLineGroup seg : [
            SELECT Id FROM QuoteLineGroup WHERE QuoteId = :quoteId ORDER BY SortOrder
        ]) {
            rows.add(new QuoteLineItem(
                QuoteId = quoteId,
                QuoteLineGroupId = seg.Id,
                PricebookEntryId = pbeId,
                Product2Id = powerSafe.Id,
                Quantity = 1,
                UnitPrice = 500
            ));
        }
        insert rows;
    }

    private static Map<String, Decimal> discountsByYearAndSku(Id quoteId) {
        Map<String, Decimal> byKey = new Map<String, Decimal>();
        for (QuoteLineItem line : [
            SELECT Discount, QuoteLineGroup.Name, Product2.StockKeepingUnit
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
        ]) {
            byKey.put(line.QuoteLineGroup.Name + '|' + line.Product2.StockKeepingUnit, line.Discount);
        }
        return byKey;
    }

    private static QuoteLineGroup groupOf(String name, String segmentType, Integer sortOrder) {
        return new QuoteLineGroup(
            Name = name,
            SegmentType = segmentType,
            SortOrder = sortOrder,
            IsRamped = true
        );
    }
}
