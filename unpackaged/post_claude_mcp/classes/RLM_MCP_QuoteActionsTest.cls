@IsTest
private class RLM_MCP_QuoteActionsTest {
    @IsTest
    static void createQuote_requiresAccountName() {
        RLM_MCP_CreateQuote.CreateInput input = new RLM_MCP_CreateQuote.CreateInput();
        List<RLM_MCP_CreateQuote.CreateOutput> results =
            RLM_MCP_CreateQuote.createQuote(new List<RLM_MCP_CreateQuote.CreateInput>{ input });
        System.assertEquals(1, results.size());
        System.assertEquals(false, results[0].isSuccess);
        System.assert(results[0].message.contains('Account name'));
    }

    @IsTest
    static void createQuote_insertsDraftForAccount() {
        update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
        Account account = new Account(Name = 'MCP Quote Test Account');
        insert account;

        RLM_MCP_CreateQuote.CreateInput input = new RLM_MCP_CreateQuote.CreateInput();
        input.accountName = 'MCP Quote Test Account';
        input.quoteName = 'MCP Demo Quote';

        Test.startTest();
        List<RLM_MCP_CreateQuote.CreateOutput> results =
            RLM_MCP_CreateQuote.createQuote(new List<RLM_MCP_CreateQuote.CreateInput>{ input });
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess, results[0].message);
        System.assertNotEquals(null, results[0].quoteId);
        Quote created = [SELECT Name, Status, AccountId FROM Quote WHERE Id = :results[0].quoteId];
        System.assertEquals('MCP Demo Quote', created.Name);
        System.assertEquals('Draft', created.Status);
        System.assertEquals(account.Id, created.AccountId);
    }

    @IsTest
    static void addProduct_requiresQuoteId() {
        RLM_MCP_AddProductToQuote.AddInput input = new RLM_MCP_AddProductToQuote.AddInput();
        List<RLM_MCP_AddProductToQuote.AddOutput> results =
            RLM_MCP_AddProductToQuote.addProduct(
                new List<RLM_MCP_AddProductToQuote.AddInput>{ input }
            );
        System.assertEquals(1, results.size());
        System.assertEquals(false, results[0].isSuccess);
        System.assert(results[0].errorMessage.contains('Quote Id'));
    }

    @IsTest
    static void applyDiscount_requiresQuoteId() {
        RLM_MCP_ApplyQuoteDiscount.DiscountInput input =
            new RLM_MCP_ApplyQuoteDiscount.DiscountInput();
        List<RLM_MCP_ApplyQuoteDiscount.DiscountOutput> results =
            RLM_MCP_ApplyQuoteDiscount.applyDiscount(
                new List<RLM_MCP_ApplyQuoteDiscount.DiscountInput>{ input }
            );
        System.assertEquals(1, results.size());
        System.assertEquals(false, results[0].isSuccess);
        System.assert(results[0].errorMessage.contains('Quote Id'));
    }

    @IsTest
    static void getSummary_requiresQuoteId() {
        RLM_MCP_GetQuoteSummary.SummaryInput input = new RLM_MCP_GetQuoteSummary.SummaryInput();
        List<RLM_MCP_GetQuoteSummary.SummaryOutput> results =
            RLM_MCP_GetQuoteSummary.getSummary(
                new List<RLM_MCP_GetQuoteSummary.SummaryInput>{ input }
            );
        System.assertEquals(1, results.size());
        System.assertEquals(false, results[0].isSuccess);
        System.assert(results[0].errorMessage.contains('Quote Id'));
    }
}
