@isTest
private class RLM_QuoteLineApprovalFlagsTest {
    @isTest
    static void flagForDiscount_matches_ladder() {
        System.assertEquals(null, RLM_QuoteLineApprovalFlags.flagForDiscount(null));
        System.assertEquals(
            RLM_QuoteLineApprovalFlags.AUTO_APPROVED,
            RLM_QuoteLineApprovalFlags.flagForDiscount(10)
        );
        System.assertEquals(
            RLM_QuoteLineApprovalFlags.AUTO_APPROVED,
            RLM_QuoteLineApprovalFlags.flagForDiscount(14.9)
        );
        System.assertEquals(
            RLM_QuoteLineApprovalFlags.NEEDS_MANAGER,
            RLM_QuoteLineApprovalFlags.flagForDiscount(15)
        );
        System.assertEquals(
            RLM_QuoteLineApprovalFlags.NEEDS_MANAGER,
            RLM_QuoteLineApprovalFlags.flagForDiscount(24)
        );
        System.assertEquals(
            RLM_QuoteLineApprovalFlags.NEEDS_DIRECTOR,
            RLM_QuoteLineApprovalFlags.flagForDiscount(25)
        );
        System.assertEquals(
            RLM_QuoteLineApprovalFlags.NEEDS_DIRECTOR,
            RLM_QuoteLineApprovalFlags.flagForDiscount(34)
        );
        System.assertEquals(
            RLM_QuoteLineApprovalFlags.NEEDS_VP,
            RLM_QuoteLineApprovalFlags.flagForDiscount(35)
        );
        System.assertEquals(
            RLM_QuoteLineApprovalFlags.NEEDS_VP,
            RLM_QuoteLineApprovalFlags.flagForDiscount(70)
        );
        System.assertEquals(null, RLM_QuoteLineApprovalFlags.flagForDiscount(100));
    }

    @isTest
    static void stamp_and_clear_on_approved() {
        Product2 product = new Product2(
            Name = 'Approval Flag Product',
            StockKeepingUnit = 'APPR-FLAG-1',
            IsActive = true
        );
        insert product;

        Account acct = new Account(Name = 'Approval Flag Account');
        insert acct;
        Opportunity opp = new Opportunity(
            Name = 'Approval Flag Opp',
            AccountId = acct.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;

        Id pbId = Test.getStandardPricebookId();
        Quote q = new Quote(
            Name = 'Approval Flag Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = pbId,
            Status = 'Draft'
        );
        insert q;

        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = pbId,
            Product2Id = product.Id,
            UnitPrice = 100,
            IsActive = true
        );
        insert pbe;

        QuoteLineItem line = new QuoteLineItem(
            QuoteId = q.Id,
            PricebookEntryId = pbe.Id,
            Quantity = 1,
            UnitPrice = 100,
            Discount = 40
        );
        insert line;

        line.Discount = 40;
        update as system line;

        line = [
            SELECT RLM_Approval_Flag__c, Discount
            FROM QuoteLineItem
            WHERE Id = :line.Id
        ];
        System.assertEquals(40, line.Discount);
        System.assertEquals(RLM_QuoteLineApprovalFlags.NEEDS_VP, line.RLM_Approval_Flag__c);

        q.RLM_Approval_Status__c = 'Approved';
        update q;

        line = [
            SELECT RLM_Approval_Flag__c
            FROM QuoteLineItem
            WHERE Id = :line.Id
        ];
        System.assertEquals(RLM_QuoteLineApprovalFlags.NEEDS_VP, line.RLM_Approval_Flag__c);

        q.RLM_Approval_Status__c = null;
        update q;

        line = [
            SELECT RLM_Approval_Flag__c
            FROM QuoteLineItem
            WHERE Id = :line.Id
        ];
        System.assertEquals(RLM_QuoteLineApprovalFlags.NEEDS_VP, line.RLM_Approval_Flag__c);
    }
}
