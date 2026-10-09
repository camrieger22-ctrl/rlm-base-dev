@IsTest
private class RLM_MCP_DecideQuoteApprovalTest {
    private class FakeInvoker implements RLM_MCP_DecideQuoteApproval.DecisionInvoker {
        public Id lastWorkItemId;
        public String lastDecision;
        public Boolean succeed = true;
        public String errorMessage = 'boom';
        public RLM_MCP_DecideQuoteApproval.InvokeResult decide(
            Id workItemId,
            String decision,
            String comments
        ) {
            lastWorkItemId = workItemId;
            lastDecision = decision;
            if (succeed != true) {
                return new RLM_MCP_DecideQuoteApproval.InvokeResult(false, errorMessage);
            }
            return new RLM_MCP_DecideQuoteApproval.InvokeResult(true, null);
        }
    }

    @TestSetup
    static void setup() {
        update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
        Account account = new Account(Name = 'MCP Decide Acme');
        insert account;
        Opportunity opp = new Opportunity(
            Name = 'MCP Decide Opp',
            AccountId = account.Id,
            StageName = 'Proposal/Quote',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        insert new Quote(
            Name = 'MCP Decide Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft'
        );
    }

    private static RLM_MCP_DecideQuoteApproval.DecideOutput run(
        RLM_MCP_DecideQuoteApproval.DecideInput input
    ) {
        return RLM_MCP_DecideQuoteApproval.decide(
            new List<RLM_MCP_DecideQuoteApproval.DecideInput>{ input }
        )[0];
    }

    @IsTest
    static void requiresDecision() {
        RLM_MCP_DecideQuoteApproval.DecideOutput out =
            run(new RLM_MCP_DecideQuoteApproval.DecideInput());
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('approve or reject'), '' + out.errorMessage);
    }

    @IsTest
    static void approvesInjectedWorkItem() {
        Id quoteId = [SELECT Id FROM Quote WHERE Name = 'MCP Decide Quote'].Id;
        FakeInvoker fake = new FakeInvoker();
        RLM_MCP_DecideQuoteApproval.invoker = fake;
        RLM_MCP_DecideQuoteApproval.injectedWorkItemId = quoteId;
        RLM_MCP_DecideQuoteApproval.DecideInput input =
            new RLM_MCP_DecideQuoteApproval.DecideInput();
        input.decision = 'approve';
        input.quoteId = String.valueOf(quoteId);
        input.comments = 'Looks good.';
        Test.startTest();
        RLM_MCP_DecideQuoteApproval.DecideOutput out = run(input);
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, '' + out.errorMessage);
        System.assertEquals('Approve', fake.lastDecision);
        System.assertEquals(quoteId, fake.lastWorkItemId);
        System.assert(out.message.contains('Approved'), '' + out.message);
    }

    @IsTest
    static void noWorkItemWithoutInjection() {
        Id quoteId = [SELECT Id FROM Quote WHERE Name = 'MCP Decide Quote'].Id;
        RLM_MCP_DecideQuoteApproval.DecideInput input =
            new RLM_MCP_DecideQuoteApproval.DecideInput();
        input.decision = 'reject';
        input.quoteId = String.valueOf(quoteId);
        RLM_MCP_DecideQuoteApproval.DecideOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assert(
            out.errorMessage.contains('approval'),
            '' + out.errorMessage
        );
    }
}
