@isTest
private class RLM_BambooPathBBundleSaveTest {

    @isTest
    static void isEligible_requires_plan_payroll_benefits_without_package() {
        System.assertEquals(
            false,
            RLM_BambooPathBBundleSave.isEligible(
                new Set<String>{ 'BAMBOO-CORE', 'BAMBOO-ADD-PAYROLL' }
            )
        );
        System.assertEquals(
            true,
            RLM_BambooPathBBundleSave.isEligible(
                new Set<String>{
                    'BAMBOO-PRO',
                    'BAMBOO-ADD-PAYROLL',
                    'BAMBOO-ADD-BENEFITS'
                }
            )
        );
        System.assertEquals(
            false,
            RLM_BambooPathBBundleSave.isEligible(
                new Set<String>{
                    'BAMBOO-PKG-WORKFORCE',
                    'BAMBOO-PRO',
                    'BAMBOO-ADD-PAYROLL',
                    'BAMBOO-ADD-BENEFITS'
                }
            )
        );
    }

    @isTest
    static void trigger_sets_and_clears_quote_flag() {
        // Unique SKUs — org may already own production BAMBOO-* products, and
        // SeeAllData=false tests cannot query them but SKU uniqueness still applies.
        String planSku = 'BAMBOO-CORE-A7T';
        String payrollSku = 'BAMBOO-ADD-PAYROLL-A7T';
        String benefitsSku = 'BAMBOO-ADD-BENEFITS-A7T';
        String pkgSku = 'BAMBOO-PKG-A7T';
        RLM_BambooPathBBundleSave.planSkuOverrides = new Set<String>{ planSku };
        RLM_BambooPathBBundleSave.payrollSkuOverride = payrollSku;
        RLM_BambooPathBBundleSave.benefitsSkuOverride = benefitsSku;

        Product2 plan = new Product2(
            Name = 'BH PathB Test Plan',
            StockKeepingUnit = planSku,
            IsActive = true
        );
        Product2 payroll = new Product2(
            Name = 'BH PathB Test Payroll',
            StockKeepingUnit = payrollSku,
            IsActive = true
        );
        Product2 benefits = new Product2(
            Name = 'BH PathB Test Benefits',
            StockKeepingUnit = benefitsSku,
            IsActive = true
        );
        Product2 pkg = new Product2(
            Name = 'BH PathB Test Package',
            StockKeepingUnit = pkgSku,
            IsActive = true
        );
        insert new List<Product2>{ plan, payroll, benefits, pkg };

        Account acct = new Account(Name = 'Bamboo Path B Test');
        insert acct;
        Opportunity opp = new Opportunity(
            Name = 'Bamboo Path B Opp',
            AccountId = acct.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Quote q = new Quote(
            Name = 'Bamboo Path B Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft'
        );
        insert q;

        Id pbId = Test.getStandardPricebookId();
        List<PricebookEntry> pbes = new List<PricebookEntry>();
        for (Product2 p : new List<Product2>{ plan, payroll, benefits, pkg }) {
            pbes.add(
                new PricebookEntry(
                    Pricebook2Id = pbId,
                    Product2Id = p.Id,
                    UnitPrice = 10,
                    IsActive = true
                )
            );
        }
        insert pbes;
        Map<Id, Id> pbeByProduct = new Map<Id, Id>();
        for (PricebookEntry pbe : pbes) {
            pbeByProduct.put(pbe.Product2Id, pbe.Id);
        }

        Test.startTest();
        insert new List<QuoteLineItem>{
            new QuoteLineItem(
                QuoteId = q.Id,
                PricebookEntryId = pbeByProduct.get(plan.Id),
                Quantity = 10,
                UnitPrice = 10
            ),
            new QuoteLineItem(
                QuoteId = q.Id,
                PricebookEntryId = pbeByProduct.get(payroll.Id),
                Quantity = 10,
                UnitPrice = 8
            ),
            new QuoteLineItem(
                QuoteId = q.Id,
                PricebookEntryId = pbeByProduct.get(benefits.Id),
                Quantity = 10,
                UnitPrice = 6
            )
        };
        Test.stopTest();

        q = [
            SELECT RLM_Bamboo_PathB_BundleSave__c
            FROM Quote
            WHERE Id = :q.Id
        ];
        System.assertEquals(
            true,
            q.RLM_Bamboo_PathB_BundleSave__c,
            'A la carte plan+Payroll+Benefits should set Path B flag'
        );

        insert new QuoteLineItem(
            QuoteId = q.Id,
            PricebookEntryId = pbeByProduct.get(pkg.Id),
            Quantity = 1,
            UnitPrice = 0
        );
        q = [
            SELECT RLM_Bamboo_PathB_BundleSave__c
            FROM Quote
            WHERE Id = :q.Id
        ];
        System.assertEquals(
            false,
            q.RLM_Bamboo_PathB_BundleSave__c,
            'Workforce package present should clear Path B flag'
        );
    }
}
