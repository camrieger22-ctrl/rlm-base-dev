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
    static void createQuote_unknownAccountPointsAtProspect() {
        RLM_MCP_CreateQuote.CreateInput input = new RLM_MCP_CreateQuote.CreateInput();
        input.accountName = 'No Such Prospect MCP XYZ';
        List<RLM_MCP_CreateQuote.CreateOutput> results =
            RLM_MCP_CreateQuote.createQuote(new List<RLM_MCP_CreateQuote.CreateInput>{ input });
        System.assertEquals(false, results[0].isSuccess);
        System.assert(
            results[0].message.contains('createRevenueCloudProspect'),
            '' + results[0].message
        );
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
    static void createQuote_namedOpportunityDoesNotReuseOtherOpenOpp() {
        update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
        Account account = new Account(Name = 'MCP Named Opp Account');
        insert account;
        insert new Opportunity(
            Name = 'Existing Acme Deal',
            AccountId = account.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );

        RLM_MCP_CreateQuote.CreateInput input = new RLM_MCP_CreateQuote.CreateInput();
        input.accountName = 'MCP Named Opp Account';
        input.quoteName = 'Email Quote';
        input.opportunityName = 'Claude Email Test';
        input.termMonths = 12;

        Test.startTest();
        List<RLM_MCP_CreateQuote.CreateOutput> results =
            RLM_MCP_CreateQuote.createQuote(new List<RLM_MCP_CreateQuote.CreateInput>{ input });
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess, results[0].message);
        Opportunity named = [
            SELECT Name FROM Opportunity WHERE Id = :results[0].opportunityId
        ];
        System.assertEquals('Claude Email Test', named.Name);
        System.assertEquals(
            2,
            [SELECT COUNT() FROM Opportunity WHERE AccountId = :account.Id]
        );
        Quote created = [
            SELECT StartDate, EndDate FROM Quote WHERE Id = :results[0].quoteId
        ];
        System.assertEquals(Date.today(), created.StartDate);
        System.assertEquals(Date.today().addMonths(12), created.EndDate);
    }

    @IsTest
    static void createQuote_secondCallReusesSameNamedDraft() {
        update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
        Account account = new Account(Name = 'MCP Reuse Quote Account');
        insert account;

        RLM_MCP_CreateQuote.CreateInput input = new RLM_MCP_CreateQuote.CreateInput();
        input.accountName = 'MCP Reuse Quote Account';
        input.quoteName = 'Claude Email Test';
        input.opportunityName = 'Claude Email Test';
        input.linesJson = '[{"product":"QuantumBit Database","quantity":10}]';
        FakeLineAdder fake = new FakeLineAdder();
        RLM_MCP_CreateQuote.lineAdder = fake;

        List<RLM_MCP_CreateQuote.CreateOutput> first =
            RLM_MCP_CreateQuote.createQuote(new List<RLM_MCP_CreateQuote.CreateInput>{ input });
        System.assertEquals(true, first[0].isSuccess, first[0].message);
        System.assertEquals(false, first[0].alreadyExisted);
        System.assertEquals(1, fake.calls);

        Test.startTest();
        List<RLM_MCP_CreateQuote.CreateOutput> second =
            RLM_MCP_CreateQuote.createQuote(new List<RLM_MCP_CreateQuote.CreateInput>{ input });
        Test.stopTest();

        System.assertEquals(true, second[0].isSuccess, second[0].message);
        System.assertEquals(true, second[0].alreadyExisted);
        System.assertEquals(first[0].quoteId, second[0].quoteId);
        System.assertEquals(1, fake.calls);
        System.assertEquals(1, [SELECT COUNT() FROM Quote WHERE AccountId = :account.Id]);
        System.assert(second[0].message.contains('Reused existing draft'), second[0].message);
    }

    @IsTest
    static void createQuote_blankOppNameWithSeveralOppsAsks() {
        update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
        Account account = new Account(Name = 'MCP Many Opp Account');
        insert account;
        insert new List<Opportunity>{
            new Opportunity(
                Name = 'Deal A',
                AccountId = account.Id,
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(10)
            ),
            new Opportunity(
                Name = 'Deal B',
                AccountId = account.Id,
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(20)
            )
        };

        RLM_MCP_CreateQuote.CreateInput input = new RLM_MCP_CreateQuote.CreateInput();
        input.accountName = 'MCP Many Opp Account';
        input.quoteName = 'Should Not Insert';

        Test.startTest();
        List<RLM_MCP_CreateQuote.CreateOutput> results =
            RLM_MCP_CreateQuote.createQuote(new List<RLM_MCP_CreateQuote.CreateInput>{ input });
        Test.stopTest();

        System.assertEquals(false, results[0].isSuccess);
        System.assert(results[0].message.contains('opportunityName'), results[0].message);
        System.assertEquals(0, [SELECT COUNT() FROM Quote WHERE AccountId = :account.Id]);
    }

    @IsTest
    static void createQuote_newQuoteNameOnSameOppInserts() {
        update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
        Account account = new Account(Name = 'MCP Second Quote Account');
        insert account;
        Opportunity opp = new Opportunity(
            Name = 'Shared Deal',
            AccountId = account.Id,
            StageName = 'Proposal/Quote',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        insert new Quote(
            Name = 'First Option',
            OpportunityId = opp.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft'
        );

        RLM_MCP_CreateQuote.CreateInput input = new RLM_MCP_CreateQuote.CreateInput();
        input.accountName = 'MCP Second Quote Account';
        input.opportunityName = 'Shared Deal';
        input.quoteName = 'Second Option';

        Test.startTest();
        List<RLM_MCP_CreateQuote.CreateOutput> results =
            RLM_MCP_CreateQuote.createQuote(new List<RLM_MCP_CreateQuote.CreateInput>{ input });
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess, results[0].message);
        System.assertEquals(false, results[0].alreadyExisted);
        System.assertEquals(2, [SELECT COUNT() FROM Quote WHERE OpportunityId = :opp.Id]);
    }

    @IsTest
    static void createQuote_warnsWhenLinesMatchOwnedAssets() {
        update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
        Account account = new Account(Name = 'MCP Owned Overlap Account');
        insert account;
        Product2 product = new Product2(
            Name = 'QuantumBit Database',
            StockKeepingUnit = 'ZMCP-OWN-DB',
            IsActive = true
        );
        insert product;
        insert new Asset(
            Name = 'QuantumBit Database',
            AccountId = account.Id,
            Product2Id = product.Id,
            Quantity = 5,
            Status = 'Purchased'
        );
        FakeLineAdder fake = new FakeLineAdder();
        RLM_MCP_CreateQuote.lineAdder = fake;
        RLM_MCP_CreateQuote.CreateInput input = new RLM_MCP_CreateQuote.CreateInput();
        input.accountName = 'MCP Owned Overlap Account';
        input.quoteName = 'New Sale Or Amend';
        input.opportunityName = 'Overlap Deal';
        input.linesJson = '[{"product":"QuantumBit Database","quantity":5}]';
        Test.startTest();
        List<RLM_MCP_CreateQuote.CreateOutput> results =
            RLM_MCP_CreateQuote.createQuote(new List<RLM_MCP_CreateQuote.CreateInput>{ input });
        Test.stopTest();
        System.assertEquals(true, results[0].isSuccess, results[0].message);
        System.assertEquals(false, results[0].alreadyExisted);
        System.assert(results[0].message.contains('already own'), results[0].message);
        System.assert(results[0].message.contains('amend'), results[0].message);
    }

    private class FakeLineAdder implements RLM_MCP_CreateQuote.LineAdder {
        Integer calls = 0;
        public List<RLM_AI_AddProductToQuoteService.AddOutput> add(
            List<RLM_AI_AddProductToQuoteService.AddInput> inputs
        ) {
            calls++;
            List<RLM_AI_AddProductToQuoteService.AddOutput> outs =
                new List<RLM_AI_AddProductToQuoteService.AddOutput>();
            for (RLM_AI_AddProductToQuoteService.AddInput addIn : inputs) {
                RLM_AI_AddProductToQuoteService.AddOutput row =
                    new RLM_AI_AddProductToQuoteService.AddOutput();
                row.isSuccess = true;
                row.productNameAdded = addIn.productName;
                row.quantityAdded = addIn.quantity;
                outs.add(row);
            }
            return outs;
        }
    }

    @IsTest
    static void createQuote_linesJsonAddsAllLinesInOneCall() {
        update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
        Account account = new Account(Name = 'MCP Lines Json Account');
        insert account;
        FakeLineAdder fake = new FakeLineAdder();
        RLM_MCP_CreateQuote.lineAdder = fake;

        RLM_MCP_CreateQuote.CreateInput input = new RLM_MCP_CreateQuote.CreateInput();
        input.accountName = 'MCP Lines Json Account';
        input.quoteName = 'Acme 12-Month Quote';
        input.opportunityName = 'Claude Email Test 4';
        input.termMonths = 12;
        input.linesJson =
            '[{"product":"QuantumBit Database","quantity":10},'
            + '{"product":"Software Maintenance","quantity":5},'
            + '{"product":"Q-Rack 750","quantity":1}]';

        Test.startTest();
        List<RLM_MCP_CreateQuote.CreateOutput> results =
            RLM_MCP_CreateQuote.createQuote(new List<RLM_MCP_CreateQuote.CreateInput>{ input });
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess, results[0].message);
        System.assertEquals(1, fake.calls);
        System.assert(
            results[0].linesDisplay != null
                && results[0].linesDisplay.contains('QuantumBit Database'),
            results[0].linesDisplay
        );
        System.assert(results[0].message.contains('10 × QuantumBit Database'), results[0].message);
        System.assert(results[0].message.contains('Software Maintenance'), results[0].message);
        System.assertEquals(
            'Claude Email Test 4',
            [SELECT Name FROM Opportunity WHERE Id = :results[0].opportunityId].Name
        );
    }

    @IsTest
    static void createQuote_invalidLinesJsonDoesNotInsertQuote() {
        update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
        Account account = new Account(Name = 'MCP Bad Json Account');
        insert account;

        RLM_MCP_CreateQuote.CreateInput input = new RLM_MCP_CreateQuote.CreateInput();
        input.accountName = 'MCP Bad Json Account';
        input.linesJson = '{not-json';

        Test.startTest();
        List<RLM_MCP_CreateQuote.CreateOutput> results =
            RLM_MCP_CreateQuote.createQuote(new List<RLM_MCP_CreateQuote.CreateInput>{ input });
        Test.stopTest();

        System.assertEquals(false, results[0].isSuccess);
        System.assert(results[0].message.contains('linesJson'), results[0].message);
        System.assertEquals(0, [SELECT COUNT() FROM Quote WHERE AccountId = :account.Id]);
    }

    private class FakeAddLineAdder implements RLM_MCP_AddProductToQuote.LineAdder {
        Integer calls = 0;
        Integer lineCount = 0;
        public List<RLM_AI_AddProductToQuoteService.AddOutput> add(
            List<RLM_AI_AddProductToQuoteService.AddInput> inputs
        ) {
            calls++;
            lineCount = inputs == null ? 0 : inputs.size();
            List<RLM_AI_AddProductToQuoteService.AddOutput> outs =
                new List<RLM_AI_AddProductToQuoteService.AddOutput>();
            if (inputs == null) {
                return outs;
            }
            for (RLM_AI_AddProductToQuoteService.AddInput addIn : inputs) {
                RLM_AI_AddProductToQuoteService.AddOutput row =
                    new RLM_AI_AddProductToQuoteService.AddOutput();
                row.isSuccess = true;
                row.productNameAdded = addIn.productName;
                row.quantityAdded = addIn.quantity;
                row.lineSummaryDisplay = String.valueOf(addIn.quantity) + ' × ' + addIn.productName;
                outs.add(row);
            }
            return outs;
        }
    }

    @IsTest
    static void addProduct_linesJsonAddsAllInOneCall() {
        FakeAddLineAdder fake = new FakeAddLineAdder();
        RLM_MCP_AddProductToQuote.lineAdder = fake;
        RLM_MCP_AddProductToQuote.AddInput input = new RLM_MCP_AddProductToQuote.AddInput();
        input.quoteId = '0Q0000000000001AAA';
        input.linesJson =
            '[{"product":"QuantumBit Database","quantity":3},{"product":"Q-Rack 750","quantity":2}]';
        Test.startTest();
        List<RLM_MCP_AddProductToQuote.AddOutput> results =
            RLM_MCP_AddProductToQuote.addProduct(
                new List<RLM_MCP_AddProductToQuote.AddInput>{ input }
            );
        Test.stopTest();
        System.assertEquals(true, results[0].isSuccess, '' + results[0].errorMessage);
        System.assertEquals(1, fake.calls);
        System.assertEquals(2, fake.lineCount);
        System.assert(results[0].lineSummaryDisplay.contains('QuantumBit Database'), results[0].lineSummaryDisplay);
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
