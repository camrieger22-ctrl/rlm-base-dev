@isTest
private class RLM_BambooVolumeTiersTest {

    @isTest
    static void resolve_ladder_matches_demo_bands() {
        System.assertEquals(false, RLM_BambooVolumeTiers.isEligibleSku(null));
        System.assertEquals(false, RLM_BambooVolumeTiers.isEligibleSku('BAMBOO-PKG-WORKFORCE'));
        System.assertEquals(true, RLM_BambooVolumeTiers.isEligibleSku('BAMBOO-CORE'));

        RLM_BambooVolumeTiers.TierResult below =
            RLM_BambooVolumeTiers.resolve(10, 'BAMBOO-CORE');
        System.assertEquals(true, below.eligible);
        System.assertEquals('Below volume', below.band);
        System.assertEquals(0, below.discountPercent);
        System.assertEquals(15, below.unitsToNext);
        System.assert(below.nextTierHint.contains('5%'));

        RLM_BambooVolumeTiers.TierResult mid =
            RLM_BambooVolumeTiers.resolve(400, 'BAMBOO-PRO');
        System.assertEquals('301–500', mid.band);
        System.assertEquals(20, mid.discountPercent);
        System.assertEquals(101, mid.unitsToNext);
        System.assert(mid.nextTierHint.contains('25%'));

        RLM_BambooVolumeTiers.TierResult top =
            RLM_BambooVolumeTiers.resolve(900, 'BAMBOO-ADD-PAYROLL');
        System.assertEquals('501+', top.band);
        System.assertEquals(25, top.discountPercent);
        System.assertEquals('Top volume tier', top.nextTierHint);

        System.assertEquals(5, RLM_BambooVolumeTiers.ladder().size());
    }

    @isTest
    static void stampLines_and_coach_payload() {
        Product2 plan = new Product2(
            Name = 'BambooHR Core',
            StockKeepingUnit = 'BAMBOO-CORE',
            IsActive = true
        );
        Product2 pkg = new Product2(
            Name = 'BambooHR Workforce Package',
            StockKeepingUnit = 'BAMBOO-PKG-WORKFORCE',
            IsActive = true
        );
        Product2 other = new Product2(
            Name = 'Other Product',
            StockKeepingUnit = 'OTHER-1',
            IsActive = true
        );
        insert new List<Product2>{ plan, pkg, other };

        Account acct = new Account(Name = 'Bamboo Volume Test');
        insert acct;
        Opportunity opp = new Opportunity(
            Name = 'Bamboo Volume Opp',
            AccountId = acct.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Quote q = new Quote(
            Name = 'Bamboo Volume Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft'
        );
        insert q;

        Id pbId = Test.getStandardPricebookId();
        insert new List<PricebookEntry>{
            new PricebookEntry(
                Pricebook2Id = pbId,
                Product2Id = plan.Id,
                UnitPrice = 10,
                IsActive = true
            ),
            new PricebookEntry(
                Pricebook2Id = pbId,
                Product2Id = pkg.Id,
                UnitPrice = 0,
                IsActive = true
            ),
            new PricebookEntry(
                Pricebook2Id = pbId,
                Product2Id = other.Id,
                UnitPrice = 1,
                IsActive = true
            )
        };

        Map<Id, Id> pbeByProduct = new Map<Id, Id>();
        for (PricebookEntry pbe : [
            SELECT Id, Product2Id
            FROM PricebookEntry
            WHERE Product2Id IN :new Set<Id>{ plan.Id, pkg.Id, other.Id }
              AND Pricebook2Id = :pbId
        ]) {
            pbeByProduct.put(pbe.Product2Id, pbe.Id);
        }

        QuoteLineItem planLine = new QuoteLineItem(
            QuoteId = q.Id,
            PricebookEntryId = pbeByProduct.get(plan.Id),
            Product2Id = plan.Id,
            Quantity = 400,
            UnitPrice = 10
        );
        QuoteLineItem pkgLine = new QuoteLineItem(
            QuoteId = q.Id,
            PricebookEntryId = pbeByProduct.get(pkg.Id),
            Product2Id = pkg.Id,
            Quantity = 400,
            UnitPrice = 0
        );
        QuoteLineItem otherLine = new QuoteLineItem(
            QuoteId = q.Id,
            PricebookEntryId = pbeByProduct.get(other.Id),
            Product2Id = other.Id,
            Quantity = 400,
            UnitPrice = 1
        );

        Test.startTest();
        insert new List<QuoteLineItem>{ planLine, pkgLine, otherLine };
        Test.stopTest();

        QuoteLineItem stamped = [
            SELECT
                RLM_Volume_Tier_Band__c,
                RLM_Volume_Tier_Discount__c,
                RLM_Volume_Tier_Next__c
            FROM QuoteLineItem
            WHERE Id = :planLine.Id
        ];
        System.assertEquals('301–500', stamped.RLM_Volume_Tier_Band__c);
        System.assertEquals(20, stamped.RLM_Volume_Tier_Discount__c);
        System.assert(stamped.RLM_Volume_Tier_Next__c.contains('101'));

        QuoteLineItem clearedPkg = [
            SELECT RLM_Volume_Tier_Band__c, RLM_Volume_Tier_Discount__c
            FROM QuoteLineItem
            WHERE Id = :pkgLine.Id
        ];
        System.assertEquals(null, clearedPkg.RLM_Volume_Tier_Band__c);
        System.assertEquals(null, clearedPkg.RLM_Volume_Tier_Discount__c);

        RLM_BambooVolumeTiers.CoachPayload payload =
            RLM_BambooVolumeTiers.getCoachForQuote(q.Id);
        System.assertEquals(1, payload.lines.size());
        System.assertEquals('301–500', payload.lines[0].band);
        System.assertEquals(20, payload.lines[0].discountPercent);

        RLM_BambooVolumeTiers.CoachPayload empty =
            RLM_BambooVolumeTiers.getCoachForQuote(null);
        System.assertEquals(0, empty.lines.size());
    }
}
