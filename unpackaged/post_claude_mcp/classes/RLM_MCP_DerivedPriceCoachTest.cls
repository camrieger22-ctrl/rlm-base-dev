@IsTest
private class RLM_MCP_DerivedPriceCoachTest {
    @TestSetup
    static void setup() {
        Id pbId = Test.getStandardPricebookId();
        update new Pricebook2(Id = pbId, IsActive = true);
        Account account = new Account(Name = 'MCP Derived Coach Account');
        insert account;
        Opportunity opportunity = new Opportunity(
            Name = 'MCP Derived Coach Opp',
            AccountId = account.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opportunity;
        Product2 maint = new Product2(
            Name = 'Software Maintenance',
            StockKeepingUnit = 'ZMCP-COACH-MAINT',
            IsActive = true
        );
        Product2 api = new Product2(
            Name = 'Additional API',
            StockKeepingUnit = 'ZMCP-COACH-API',
            IsActive = true
        );
        Product2 mgmt = new Product2(
            Name = 'QB API Management Solution',
            StockKeepingUnit = 'ZMCP-COACH-MGMT',
            IsActive = true
        );
        Product2 database = new Product2(
            Name = 'QuantumBit Database',
            StockKeepingUnit = 'ZMCP-COACH-DB',
            IsActive = true
        );
        Product2 complete = new Product2(
            Name = 'QuantumBit Complete Solution',
            StockKeepingUnit = 'ZMCP-COACH-COMPLETE',
            IsActive = true
        );
        insert new List<Product2>{ maint, api, mgmt, database, complete };
        insert new List<PricebookEntry>{
            new PricebookEntry(
                Pricebook2Id = pbId, Product2Id = maint.Id, UnitPrice = 0, IsActive = true
            ),
            new PricebookEntry(
                Pricebook2Id = pbId, Product2Id = api.Id, UnitPrice = 1000, IsActive = true
            ),
            new PricebookEntry(
                Pricebook2Id = pbId, Product2Id = mgmt.Id, UnitPrice = 2000, IsActive = true
            ),
            new PricebookEntry(
                Pricebook2Id = pbId, Product2Id = database.Id, UnitPrice = 5000, IsActive = true
            ),
            new PricebookEntry(
                Pricebook2Id = pbId, Product2Id = complete.Id, UnitPrice = 10000, IsActive = true
            )
        };
        Quote emptyQuote = new Quote(
            Name = 'MCP Derived Coach Empty',
            OpportunityId = opportunity.Id,
            Pricebook2Id = pbId,
            Status = 'Draft',
            StartDate = Date.today(),
            EndDate = Date.today().addMonths(12)
        );
        Quote missingQuote = new Quote(
            Name = 'MCP Derived Coach Missing',
            OpportunityId = opportunity.Id,
            Pricebook2Id = pbId,
            Status = 'Draft',
            StartDate = Date.today(),
            EndDate = Date.today().addMonths(12)
        );
        Quote presentQuote = new Quote(
            Name = 'MCP Derived Coach Present',
            OpportunityId = opportunity.Id,
            Pricebook2Id = pbId,
            Status = 'Draft',
            StartDate = Date.today(),
            EndDate = Date.today().addMonths(12)
        );
        Quote mixQuote = new Quote(
            Name = 'MCP Derived Coach Mix',
            OpportunityId = opportunity.Id,
            Pricebook2Id = pbId,
            Status = 'Draft',
            StartDate = Date.today(),
            EndDate = Date.today().addMonths(12)
        );
        Quote bundleQuote = new Quote(
            Name = 'MCP Derived Coach Bundle',
            OpportunityId = opportunity.Id,
            Pricebook2Id = pbId,
            Status = 'Draft',
            StartDate = Date.today(),
            EndDate = Date.today().addMonths(12)
        );
        insert new List<Quote>{ emptyQuote, missingQuote, presentQuote, mixQuote, bundleQuote };
        Map<Id, Id> pbeByProduct = new Map<Id, Id>();
        for (PricebookEntry pbe : [
            SELECT Id, Product2Id
            FROM PricebookEntry
            WHERE Product2Id IN :new List<Id>{
                maint.Id, api.Id, mgmt.Id, database.Id, complete.Id
            }
        ]) {
            pbeByProduct.put(pbe.Product2Id, pbe.Id);
        }
        insert new List<QuoteLineItem>{
            new QuoteLineItem(
                QuoteId = missingQuote.Id,
                PricebookEntryId = pbeByProduct.get(maint.Id),
                Product2Id = maint.Id,
                Quantity = 1,
                UnitPrice = 0
            ),
            new QuoteLineItem(
                QuoteId = presentQuote.Id,
                PricebookEntryId = pbeByProduct.get(maint.Id),
                Product2Id = maint.Id,
                Quantity = 1,
                UnitPrice = 0
            ),
            new QuoteLineItem(
                QuoteId = presentQuote.Id,
                PricebookEntryId = pbeByProduct.get(api.Id),
                Product2Id = api.Id,
                Quantity = 1,
                UnitPrice = 1000
            ),
            new QuoteLineItem(
                QuoteId = mixQuote.Id,
                PricebookEntryId = pbeByProduct.get(maint.Id),
                Product2Id = maint.Id,
                Quantity = 1,
                UnitPrice = 0
            ),
            new QuoteLineItem(
                QuoteId = mixQuote.Id,
                PricebookEntryId = pbeByProduct.get(database.Id),
                Product2Id = database.Id,
                Quantity = 1,
                UnitPrice = 5000
            ),
            new QuoteLineItem(
                QuoteId = bundleQuote.Id,
                PricebookEntryId = pbeByProduct.get(maint.Id),
                Product2Id = maint.Id,
                Quantity = 1,
                UnitPrice = 0
            ),
            new QuoteLineItem(
                QuoteId = bundleQuote.Id,
                PricebookEntryId = pbeByProduct.get(complete.Id),
                Product2Id = complete.Id,
                Quantity = 1,
                UnitPrice = 10000
            )
        };
    }

    private static void stubBundles() {
        Product2 maint = [
            SELECT Id FROM Product2 WHERE StockKeepingUnit = 'ZMCP-COACH-MAINT' LIMIT 1
        ];
        RLM_MCP_DerivedPriceCoach.bundleNamesByDerivedOverride = new Map<Id, List<String>>{
            maint.Id => new List<String>{ 'QuantumBit Complete Solution' }
        };
    }

    private static void stubContributors() {
        Product2 maint = [
            SELECT Id FROM Product2 WHERE StockKeepingUnit = 'ZMCP-COACH-MAINT' LIMIT 1
        ];
        Product2 api = [
            SELECT Id FROM Product2 WHERE StockKeepingUnit = 'ZMCP-COACH-API' LIMIT 1
        ];
        Product2 mgmt = [
            SELECT Id FROM Product2 WHERE StockKeepingUnit = 'ZMCP-COACH-MGMT' LIMIT 1
        ];
        RLM_MCP_DerivedPriceCoach.contributorsByProductOverride = new Map<Id, List<Id>>{
            maint.Id => new List<Id>{ api.Id, mgmt.Id }
        };
    }

    @IsTest
    static void nullQuoteReturnsNull() {
        System.assertEquals(null, RLM_MCP_DerivedPriceCoach.forQuote(null));
        System.assertEquals('keep', RLM_MCP_DerivedPriceCoach.append('keep', null));
    }

    @IsTest
    static void emptyQuoteReturnsNull() {
        stubContributors();
        Id quoteId = [SELECT Id FROM Quote WHERE Name = 'MCP Derived Coach Empty'].Id;
        Test.startTest();
        String note = RLM_MCP_DerivedPriceCoach.forQuote(quoteId);
        Test.stopTest();
        System.assertEquals(null, note);
        RLM_MCP_DerivedPriceCoach.contributorsByProductOverride = null;
    }

    @IsTest
    static void missingContributorsCoachesRep() {
        stubContributors();
        Id quoteId = [SELECT Id FROM Quote WHERE Name = 'MCP Derived Coach Missing'].Id;
        Test.startTest();
        String note = RLM_MCP_DerivedPriceCoach.forQuote(quoteId);
        String joined = RLM_MCP_DerivedPriceCoach.append('Cloned quote.', quoteId);
        Test.stopTest();
        RLM_MCP_DerivedPriceCoach.contributorsByProductOverride = null;
        System.assertNotEquals(null, note, 'expected AE note');
        System.assert(note.contains('AE note (chat only, never the customer email)'), note);
        System.assert(note.contains('Software Maintenance'), note);
        System.assert(note.contains('Additional API'), note);
        System.assert(note.contains('QB API Management Solution'), note);
        System.assert(note.contains('$0'), note);
        System.assert(note.contains('Ask the rep (do not add yet)'), note);
        System.assert(note.contains('1. Add Additional API'), note);
        System.assert(note.contains('2. Add QB API Management Solution'), note);
        System.assert(note.contains('3. Add both as individual lines'), note);
        System.assert(note.contains('Leave Software Maintenance at $0'), note);
        System.assert(!note.contains('Add QuantumBit Complete Solution'), note);
        System.assert(joined.startsWith('Cloned quote.'), joined);
        System.assert(joined.contains('AE note'), joined);
    }

    @IsTest
    static void offersAddBundleWhenQuoteIsOnlyDerived() {
        stubContributors();
        stubBundles();
        Id quoteId = [SELECT Id FROM Quote WHERE Name = 'MCP Derived Coach Missing'].Id;
        Test.startTest();
        String note = RLM_MCP_DerivedPriceCoach.forQuote(quoteId);
        Test.stopTest();
        RLM_MCP_DerivedPriceCoach.contributorsByProductOverride = null;
        RLM_MCP_DerivedPriceCoach.bundleNamesByDerivedOverride = null;
        System.assert(note.contains('Add QuantumBit Complete Solution'), note);
        System.assert(!note.contains('Configure QuantumBit Complete Solution'), note);
    }

    @IsTest
    static void skipsAddBundleWhenStandaloneMixExists() {
        stubContributors();
        stubBundles();
        Id quoteId = [SELECT Id FROM Quote WHERE Name = 'MCP Derived Coach Mix'].Id;
        Test.startTest();
        String note = RLM_MCP_DerivedPriceCoach.forQuote(quoteId);
        Test.stopTest();
        RLM_MCP_DerivedPriceCoach.contributorsByProductOverride = null;
        RLM_MCP_DerivedPriceCoach.bundleNamesByDerivedOverride = null;
        System.assertNotEquals(null, note, 'expected AE note');
        System.assert(note.contains('Add Additional API'), note);
        System.assert(!note.contains('Add QuantumBit Complete Solution'), note);
        System.assert(!note.contains('Configure QuantumBit Complete Solution'), note);
    }

    @IsTest
    static void offersConfigureWhenBundleAlreadyOnQuote() {
        stubContributors();
        stubBundles();
        Id quoteId = [SELECT Id FROM Quote WHERE Name = 'MCP Derived Coach Bundle'].Id;
        Test.startTest();
        String note = RLM_MCP_DerivedPriceCoach.forQuote(quoteId);
        Test.stopTest();
        RLM_MCP_DerivedPriceCoach.contributorsByProductOverride = null;
        RLM_MCP_DerivedPriceCoach.bundleNamesByDerivedOverride = null;
        System.assert(note.contains('Configure QuantumBit Complete Solution'), note);
        System.assert(!note.contains('Add QuantumBit Complete Solution'), note);
    }

    @IsTest
    static void liveQueryWithoutDerivedRowsIsQuiet() {
        Id quoteId = [SELECT Id FROM Quote WHERE Name = 'MCP Derived Coach Missing'].Id;
        Test.startTest();
        String note = RLM_MCP_DerivedPriceCoach.forQuote(quoteId);
        Test.stopTest();
        System.assertEquals(null, note);
    }

    @IsTest
    static void presentContributorSkipsNote() {
        stubContributors();
        Id quoteId = [SELECT Id FROM Quote WHERE Name = 'MCP Derived Coach Present'].Id;
        Test.startTest();
        String note = RLM_MCP_DerivedPriceCoach.forQuote(quoteId);
        Test.stopTest();
        RLM_MCP_DerivedPriceCoach.contributorsByProductOverride = null;
        System.assertEquals(null, note);
    }
}
