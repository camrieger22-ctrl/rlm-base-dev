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
        System.assert(
            results[0].quoteUrl != null && results[0].quoteUrl.contains('/lightning/r/Quote/'),
            results[0].quoteUrl
        );
        System.assert(
            results[0].opportunityUrl != null
                && results[0].opportunityUrl.contains('/lightning/r/Opportunity/'),
            results[0].opportunityUrl
        );
        System.assert(results[0].message.contains('Open Quote'), results[0].message);
        System.assert(results[0].message.contains('Open Opportunity'), results[0].message);
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
    static void applyDiscount_updatesAllLines() {
        Id pricebookId = Test.getStandardPricebookId();
        update new Pricebook2(Id = pricebookId, IsActive = true);
        Account account = new Account(Name = 'MCP Discount Account');
        insert account;
        Opportunity opportunity = new Opportunity(
            Name = 'MCP Discount Opportunity',
            AccountId = account.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opportunity;
        Product2 product = new Product2(Name = 'QuantumBit Complete Solution', IsActive = true);
        insert product;
        PricebookEntry entry = new PricebookEntry(
            Pricebook2Id = pricebookId,
            Product2Id = product.Id,
            UnitPrice = 1000,
            IsActive = true
        );
        insert entry;
        Quote quote = new Quote(
            Name = 'MCP Discount Quote',
            OpportunityId = opportunity.Id,
            Pricebook2Id = pricebookId,
            Status = 'Draft'
        );
        insert quote;
        QuoteLineItem line = new QuoteLineItem(
            QuoteId = quote.Id,
            PricebookEntryId = entry.Id,
            Product2Id = product.Id,
            Quantity = 10,
            UnitPrice = 1000
        );
        insert line;

        RLM_MCP_ApplyQuoteDiscount.DiscountInput input =
            new RLM_MCP_ApplyQuoteDiscount.DiscountInput();
        input.quoteId = String.valueOf(quote.Id);
        input.discountPercentage = 8;
        input.applyToAll = true;
        Test.startTest();
        List<RLM_MCP_ApplyQuoteDiscount.DiscountOutput> results =
            RLM_MCP_ApplyQuoteDiscount.applyDiscount(
                new List<RLM_MCP_ApplyQuoteDiscount.DiscountInput>{ input }
            );
        Test.stopTest();
        System.assertEquals(true, results[0].isSuccess, 'err=' + results[0].errorMessage);
        System.assertEquals(1, results[0].appliedCount);
        System.assert(
            results[0].quoteUrl != null && results[0].quoteUrl.contains('/lightning/r/Quote/'),
            results[0].quoteUrl
        );
        System.assert(results[0].resultsDisplay.contains('Open Quote'), results[0].resultsDisplay);
        QuoteLineItem updated = [
            SELECT Discount FROM QuoteLineItem WHERE Id = :line.Id
        ];
        System.assertEquals(8, updated.Discount);
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

    @IsTest
    static void recordLinks_buildsLightningMarkdown() {
        Account account = new Account(Name = 'MCP Link Account');
        insert account;
        String url = RLM_MCP_RecordLinks.lightningUrl('Account', account.Id);
        System.assert(url != null && url.contains('/lightning/r/Account/'), url);
        System.assert(url.contains(String.valueOf(account.Id)), url);
        String md = RLM_MCP_RecordLinks.markdown('Open Account', 'Account', account.Id);
        System.assert(md != null && md.startsWith('[Open Account]('), md);
        System.assertEquals(null, RLM_MCP_RecordLinks.lightningUrl('Account', null));
        System.assertEquals(null, RLM_MCP_RecordLinks.toId('not-an-id'));
    }
}
