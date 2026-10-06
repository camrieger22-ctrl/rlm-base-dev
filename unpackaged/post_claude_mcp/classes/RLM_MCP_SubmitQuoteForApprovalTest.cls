@IsTest
private class RLM_MCP_SubmitQuoteForApprovalTest {

    private class FakeInvoker implements RLM_MCP_SubmitQuoteForApproval.ApprovalFlowInvoker {
        Boolean succeed;
        Integer calls = 0;
        Map<String, Object> lastParams;
        FakeInvoker(Boolean succeed) {
            this.succeed = succeed;
        }
        public RLM_MCP_SubmitQuoteForApproval.InvokeResult start(Map<String, Object> params) {
            calls++;
            lastParams = params;
            return new RLM_MCP_SubmitQuoteForApproval.InvokeResult(succeed, succeed ? null : 'boom');
        }
    }

    @TestSetup
    static void setup() {
        Account a = new Account(Name = 'Zephyr Test Co');
        insert a;
        Opportunity o = new Opportunity(
            Name = 'Zephyr Opp', AccountId = a.Id,
            StageName = 'Prospecting', CloseDate = Date.today().addDays(30)
        );
        insert o;

        Id pbId = Test.getStandardPricebookId();
        Product2 p = new Product2(Name = 'Zephyr Widget', IsActive = true);
        insert p;
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = pbId, Product2Id = p.Id, UnitPrice = 100, IsActive = true
        );
        insert pbe;

        List<Quote> quotes = new List<Quote>{
            new Quote(Name = 'Zephyr Expansion', OpportunityId = o.Id, Pricebook2Id = pbId, Status = 'Draft'),
            new Quote(Name = 'Zephyr Renewal', OpportunityId = o.Id, Pricebook2Id = pbId, Status = 'Draft'),
            new Quote(Name = 'Zephyr Empty', OpportunityId = o.Id, Pricebook2Id = pbId, Status = 'Draft')
        };
        insert quotes;

        insert new List<QuoteLineItem>{
            new QuoteLineItem(QuoteId = quotes[0].Id, PricebookEntryId = pbe.Id, Product2Id = p.Id, Quantity = 1, UnitPrice = 100),
            new QuoteLineItem(QuoteId = quotes[1].Id, PricebookEntryId = pbe.Id, Product2Id = p.Id, Quantity = 2, UnitPrice = 100)
        };
    }

    private static RLM_MCP_SubmitQuoteForApproval.SubmitOutput run(RLM_MCP_SubmitQuoteForApproval.SubmitInput input) {
        return RLM_MCP_SubmitQuoteForApproval.submit(
            new List<RLM_MCP_SubmitQuoteForApproval.SubmitInput>{ input }
        )[0];
    }

    private static RLM_MCP_SubmitQuoteForApproval.SubmitInput byName(String quoteName, String accountName) {
        RLM_MCP_SubmitQuoteForApproval.SubmitInput input = new RLM_MCP_SubmitQuoteForApproval.SubmitInput();
        input.quoteName = quoteName;
        input.accountName = accountName;
        input.comments = 'Test submission';
        return input;
    }

    @IsTest
    static void exactQuoteNameSubmits() {
        FakeInvoker fake = new FakeInvoker(true);
        RLM_MCP_SubmitQuoteForApproval.invoker = fake;
        Quote q = [SELECT Id FROM Quote WHERE Name = 'Zephyr Expansion'];

        RLM_MCP_SubmitQuoteForApproval.SubmitOutput out = run(byName('zephyr expansion', null));

        System.assertEquals(true, out.isSuccess, 'Submit failed: ' + out.errorMessage);
        System.assertEquals(1, fake.calls);
        System.assertEquals(String.valueOf(q.Id), fake.lastParams.get('recordId'));
        System.assertEquals('Test submission', fake.lastParams.get('submissionComments'));
    }

    @IsTest
    static void quoteIdSubmits() {
        FakeInvoker fake = new FakeInvoker(true);
        RLM_MCP_SubmitQuoteForApproval.invoker = fake;
        Quote q = [SELECT Id FROM Quote WHERE Name = 'Zephyr Renewal'];
        RLM_MCP_SubmitQuoteForApproval.SubmitInput input = new RLM_MCP_SubmitQuoteForApproval.SubmitInput();
        input.quoteId = q.Id;

        RLM_MCP_SubmitQuoteForApproval.SubmitOutput out = run(input);

        System.assertEquals(true, out.isSuccess, 'Submit failed: ' + out.errorMessage);
        System.assertEquals(1, fake.calls);
    }

    @IsTest
    static void accountNameWithTwoQuotesAsksUser() {
        FakeInvoker fake = new FakeInvoker(true);
        RLM_MCP_SubmitQuoteForApproval.invoker = fake;

        RLM_MCP_SubmitQuoteForApproval.SubmitOutput out = run(byName(null, 'Zephyr Test'));

        System.assertEquals(false, out.isSuccess);
        System.assertEquals(true, out.needsDisambiguation);
        System.assert(out.candidateSummariesDisplay.contains('Zephyr Expansion'));
        System.assert(!out.candidateSummariesDisplay.contains('Zephyr Empty'));
        System.assertEquals(0, fake.calls);
    }

    @IsTest
    static void exactMatchWithNoLinesIsRejected() {
        RLM_MCP_SubmitQuoteForApproval.invoker = new FakeInvoker(true);
        RLM_MCP_SubmitQuoteForApproval.SubmitOutput out = run(byName('Zephyr Empty', null));
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('no lines'));
    }

    @IsTest
    static void noMatchReturnsError() {
        RLM_MCP_SubmitQuoteForApproval.SubmitOutput out = run(byName('Nonexistent Quote XYZ', null));
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.startsWith('No draft quote found'));
    }

    @IsTest
    static void flowFailureIsReported() {
        RLM_MCP_SubmitQuoteForApproval.invoker = new FakeInvoker(false);
        RLM_MCP_SubmitQuoteForApproval.SubmitOutput out = run(byName('Zephyr Expansion', null));
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('did not start'));
    }

    @IsTest
    static void invalidAndBlankInputs() {
        RLM_MCP_SubmitQuoteForApproval.SubmitInput badId = new RLM_MCP_SubmitQuoteForApproval.SubmitInput();
        badId.quoteId = UserInfo.getUserId();
        System.assertEquals(false, run(badId).isSuccess);

        System.assertEquals(false, run(new RLM_MCP_SubmitQuoteForApproval.SubmitInput()).isSuccess);
        System.assertEquals(0, RLM_MCP_SubmitQuoteForApproval.submit(null).size());
    }
}