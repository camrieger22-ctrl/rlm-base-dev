@IsTest
private class RLM_MCP_RenewOrCancelAssetTest {
    private class FakeInvoker implements RLM_MCP_RenewOrCancelAsset.LifecycleInvoker {
        public String lastAction;
        public Id lastAssetId;
        public Date lastStart;
        public RLM_MCP_RenewOrCancelAsset.InvokeResult result;
        public RLM_MCP_RenewOrCancelAsset.InvokeResult start(
            String actionName, Id assetId, Date startDay, Id opportunityId
        ) {
            lastAction = actionName;
            lastAssetId = assetId;
            lastStart = startDay;
            return result;
        }
    }

    @TestSetup
    static void setup() {
        Account account = new Account(Name = 'MCP Renew Acme');
        insert account;
        Product2 product = new Product2(
            Name = 'QuantumBit Database',
            StockKeepingUnit = 'ZMCP-REN-DB',
            IsActive = true
        );
        insert product;
        insert new Asset(
            Name = 'QuantumBit Database',
            AccountId = account.Id,
            Product2Id = product.Id,
            Quantity = 1,
            Status = 'Purchased'
        );
    }

    private static RLM_MCP_RenewOrCancelAsset.ChangeOutput run(
        RLM_MCP_RenewOrCancelAsset.ChangeInput input
    ) {
        return RLM_MCP_RenewOrCancelAsset.change(
            new List<RLM_MCP_RenewOrCancelAsset.ChangeInput>{ input }
        )[0];
    }

    @IsTest
    static void requiresAction() {
        RLM_MCP_RenewOrCancelAsset.ChangeOutput out =
            run(new RLM_MCP_RenewOrCancelAsset.ChangeInput());
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('renew or cancel'), '' + out.errorMessage);
    }

    @IsTest
    static void cancelRequiresStartDate() {
        Id assetId = [SELECT Id FROM Asset WHERE Name = 'QuantumBit Database'].Id;
        RLM_MCP_RenewOrCancelAsset.ChangeInput input =
            new RLM_MCP_RenewOrCancelAsset.ChangeInput();
        input.action = 'cancel';
        input.assetId = String.valueOf(assetId);
        RLM_MCP_RenewOrCancelAsset.ChangeOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('start date'), '' + out.errorMessage);
    }

    @IsTest
    static void renewUsesInvoker() {
        Id assetId = [SELECT Id FROM Asset WHERE Name = 'QuantumBit Database'].Id;
        Account account = [SELECT Id FROM Account WHERE Name = 'MCP Renew Acme'];
        Opportunity opp = new Opportunity(
            Name = 'MCP Renew Opp',
            AccountId = account.Id,
            StageName = 'Proposal/Quote',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Quote quote = new Quote(
            Name = 'MCP Renew Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft'
        );
        insert quote;
        FakeInvoker fake = new FakeInvoker();
        fake.result = new RLM_MCP_RenewOrCancelAsset.InvokeResult(
            true, String.valueOf(quote.Id), null
        );
        RLM_MCP_RenewOrCancelAsset.invoker = fake;
        RLM_MCP_RenewOrCancelAsset.ChangeInput input =
            new RLM_MCP_RenewOrCancelAsset.ChangeInput();
        input.action = 'renew';
        input.assetId = String.valueOf(assetId);
        input.startDate = '2026-12-01';
        Test.startTest();
        RLM_MCP_RenewOrCancelAsset.ChangeOutput out = run(input);
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, '' + out.errorMessage);
        System.assertEquals('renew', fake.lastAction);
        System.assertEquals(Date.newInstance(2026, 12, 1), fake.lastStart);
        System.assert(out.message.contains('renew'), '' + out.message);
    }
}
