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
            results[0].message.contains('contactEmail'),
            '' + results[0].message
        );
        System.assert(
            results[0].message.contains('Do not call createRevenueCloudProspect first'),
            '' + results[0].message
        );
    }

    @IsTest
    static void createQuote_unknownAccountCreatesProspectInline() {
        update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
        RLM_MCP_CreateQuote.CreateInput input = new RLM_MCP_CreateQuote.CreateInput();
        input.accountName = 'MCP Inline Prospect Analytics';
        input.quoteName = 'MCP Inline 36-Month Quote';
        input.opportunityName = 'MCP Inline Prospect New Business';
        input.contactFirstName = 'Priya';
        input.contactLastName = 'Shah';
        input.contactEmail = 'priya.shah.mcp.inline@example.test';
        input.billingStreet = '1200 Market Street';
        input.billingCity = 'San Francisco';
        input.billingState = 'CA';
        input.billingPostalCode = '94102';
        input.billingCountry = 'United States';
        input.termMonths = 36;

        Test.startTest();
        List<RLM_MCP_CreateQuote.CreateOutput> results =
            RLM_MCP_CreateQuote.createQuote(new List<RLM_MCP_CreateQuote.CreateInput>{ input });
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess, results[0].message);
        System.assertNotEquals(null, results[0].quoteId);
        System.assertNotEquals(null, results[0].opportunityId);
        System.assertNotEquals(null, results[0].contactId);
        System.assertEquals('MCP Inline Prospect Analytics', results[0].accountName);
        System.assert(
            results[0].accountUrl != null
                && results[0].accountUrl.contains('/lightning/r/Account/'),
            results[0].accountUrl
        );
        System.assert(
            results[0].contactUrl != null
                && results[0].contactUrl.contains('/lightning/r/Contact/'),
            results[0].contactUrl
        );
        System.assert(results[0].message.contains('Open Account'), results[0].message);
        System.assert(results[0].message.contains('Open Contact'), results[0].message);
        System.assertEquals(
            1,
            [SELECT COUNT() FROM Account WHERE Name = 'MCP Inline Prospect Analytics']
        );
        System.assertEquals(
            1,
            [
                SELECT COUNT()
                FROM Contact
                WHERE Email = 'priya.shah.mcp.inline@example.test'
            ]
        );
        Quote quote = [
            SELECT ContactId, Opportunity.Name
            FROM Quote
            WHERE Id = :results[0].quoteId
        ];
        System.assertEquals(Id.valueOf(results[0].contactId), quote.ContactId);
        System.assertEquals('MCP Inline Prospect New Business', quote.Opportunity.Name);
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
        List<String> productOrder = new List<String>();
        public List<RLM_AI_AddProductToQuoteService.AddOutput> add(
            List<RLM_AI_AddProductToQuoteService.AddInput> inputs
        ) {
            calls++;
            productOrder = new List<String>();
            List<RLM_AI_AddProductToQuoteService.AddOutput> outs =
                new List<RLM_AI_AddProductToQuoteService.AddOutput>();
            for (RLM_AI_AddProductToQuoteService.AddInput addIn : inputs) {
                productOrder.add(addIn.productName);
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
            '[{"product":"Q-Rack 750","quantity":1},'
            + '{"product":"QuantumBit Database","quantity":10},'
            + '{"product":"Software Maintenance","quantity":5}]';

        Test.startTest();
        List<RLM_MCP_CreateQuote.CreateOutput> results =
            RLM_MCP_CreateQuote.createQuote(new List<RLM_MCP_CreateQuote.CreateInput>{ input });
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess, results[0].message);
        System.assertEquals(1, fake.calls);
        System.assertEquals(3, fake.productOrder.size());
        System.assertEquals('QuantumBit Database', fake.productOrder[0]);
        System.assertEquals('Software Maintenance', fake.productOrder[1]);
        System.assertEquals('Q-Rack 750', fake.productOrder[2]);
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
    static void createQuote_retriesFractionalBundleAtQuantityOne() {
        update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
        Account account = new Account(Name = 'MCP Fractional Rack Account');
        insert account;
        FractionalRackLineAdder fake = new FractionalRackLineAdder();
        RLM_MCP_CreateQuote.lineAdder = fake;

        RLM_MCP_CreateQuote.CreateInput input = new RLM_MCP_CreateQuote.CreateInput();
        input.accountName = 'MCP Fractional Rack Account';
        input.quoteName = 'Acme 24-Month Quote';
        input.opportunityName = 'Claude Fractional Rack';
        input.termMonths = 24;
        input.linesJson =
            '[{"product":"QuantumBit Database","quantity":50},'
            + '{"product":"Q-Rack 750","quantity":8}]';

        Test.startTest();
        List<RLM_MCP_CreateQuote.CreateOutput> results =
            RLM_MCP_CreateQuote.createQuote(new List<RLM_MCP_CreateQuote.CreateInput>{ input });
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess, results[0].message);
        System.assertEquals(2, fake.calls);
        System.assert(results[0].message.contains('quantity 1'), results[0].message);
        System.assert(results[0].message.contains('Q-Rack 750'), results[0].message);
        System.assert(results[0].linesDisplay.contains('1 × Q-Rack 750'), results[0].linesDisplay);
    }

    private class FractionalRackLineAdder implements RLM_MCP_CreateQuote.LineAdder {
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
                Boolean tooMany = addIn.quantity != null && addIn.quantity > 1
                    && addIn.productName != null && addIn.productName.contains('Q-Rack');
                if (tooMany) {
                    row.isSuccess = false;
                    row.errorMessage = 'Cannot have a fractional quantity.';
                } else {
                    row.isSuccess = true;
                    row.productNameAdded = addIn.productName;
                    row.quantityAdded = addIn.quantity == null ? 1 : addIn.quantity;
                }
                outs.add(row);
            }
            return outs;
        }
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
        Date lastStartDate;
        Date lastEndDate;
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
                lastStartDate = addIn.startDate;
                lastEndDate = addIn.endDate;
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
    static void addProduct_retriesFractionalBundleAtQuantityOne() {
        FractionalAddLineAdder fake = new FractionalAddLineAdder();
        RLM_MCP_AddProductToQuote.lineAdder = fake;
        RLM_MCP_AddProductToQuote.AddInput input = new RLM_MCP_AddProductToQuote.AddInput();
        input.quoteId = '0Q0000000000001AAA';
        input.linesJson = '[{"product":"Q-Rack 750","quantity":8}]';
        Test.startTest();
        List<RLM_MCP_AddProductToQuote.AddOutput> results =
            RLM_MCP_AddProductToQuote.addProduct(
                new List<RLM_MCP_AddProductToQuote.AddInput>{ input }
            );
        Test.stopTest();
        System.assertEquals(true, results[0].isSuccess, '' + results[0].errorMessage);
        System.assertEquals(2, fake.calls);
        System.assertEquals(1, results[0].quantityAdded);
        System.assert(results[0].lineSummaryDisplay.contains('quantity 1'), results[0].lineSummaryDisplay);
    }

    private class FractionalAddLineAdder implements RLM_MCP_AddProductToQuote.LineAdder {
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
                if (addIn.quantity != null && addIn.quantity > 1) {
                    row.isSuccess = false;
                    row.errorMessage = 'Cannot have a fractional quantity.';
                } else {
                    row.isSuccess = true;
                    row.productNameAdded = addIn.productName;
                    row.quantityAdded = 1;
                    row.lineSummaryDisplay = '1 × ' + addIn.productName;
                }
                outs.add(row);
            }
            return outs;
        }
    }

    @IsTest
    static void addProduct_inheritsQuoteStartAndEndDates() {
        update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
        Account account = new Account(Name = 'MCP Add Term Account');
        insert account;
        Opportunity opp = new Opportunity(
            Name = 'MCP Add Term Deal',
            AccountId = account.Id,
            StageName = 'Proposal/Quote',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Date startDate = Date.today();
        Date endDate = startDate.addMonths(36);
        Quote quote = new Quote(
            Name = 'MCP 36 Month Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft',
            StartDate = startDate,
            EndDate = endDate
        );
        insert quote;

        FakeAddLineAdder fake = new FakeAddLineAdder();
        RLM_MCP_AddProductToQuote.lineAdder = fake;
        RLM_MCP_AddProductToQuote.AddInput input = new RLM_MCP_AddProductToQuote.AddInput();
        input.quoteId = quote.Id;
        input.linesJson = '[{"product":"Software Maintenance","quantity":5}]';
        Test.startTest();
        List<RLM_MCP_AddProductToQuote.AddOutput> results =
            RLM_MCP_AddProductToQuote.addProduct(
                new List<RLM_MCP_AddProductToQuote.AddInput>{ input }
            );
        Test.stopTest();
        System.assertEquals(true, results[0].isSuccess, '' + results[0].errorMessage);
        System.assertEquals(startDate, fake.lastStartDate);
        System.assertEquals(endDate, fake.lastEndDate);
        System.assert(
            results[0].lineSummaryDisplay.contains('36 months'),
            results[0].lineSummaryDisplay
        );
    }

    @IsTest
    static void addProduct_termMonthsOverridesQuoteTerm() {
        update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
        Account account = new Account(Name = 'MCP Add Override Account');
        insert account;
        Opportunity opp = new Opportunity(
            Name = 'MCP Add Override Deal',
            AccountId = account.Id,
            StageName = 'Proposal/Quote',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Date startDate = Date.today();
        Quote quote = new Quote(
            Name = 'MCP 36 Month Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft',
            StartDate = startDate,
            EndDate = startDate.addMonths(36)
        );
        insert quote;

        FakeAddLineAdder fake = new FakeAddLineAdder();
        RLM_MCP_AddProductToQuote.lineAdder = fake;
        RLM_MCP_AddProductToQuote.AddInput input = new RLM_MCP_AddProductToQuote.AddInput();
        input.quoteId = quote.Id;
        input.linesJson =
            '[{"product":"Software Maintenance","quantity":5,"termMonths":12}]';
        Test.startTest();
        List<RLM_MCP_AddProductToQuote.AddOutput> results =
            RLM_MCP_AddProductToQuote.addProduct(
                new List<RLM_MCP_AddProductToQuote.AddInput>{ input }
            );
        Test.stopTest();
        System.assertEquals(true, results[0].isSuccess, '' + results[0].errorMessage);
        System.assertEquals(startDate, fake.lastStartDate);
        System.assertEquals(startDate.addMonths(12), fake.lastEndDate);
        System.assert(
            results[0].lineSummaryDisplay.contains('12 months'),
            results[0].lineSummaryDisplay
        );
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
    static void lineAddRetry_detectsFractionalAndSkipsQtyOne() {
        System.assertEquals(
            true,
            RLM_MCP_LineAddRetry.isFractionalQuantityError('Cannot have a fractional quantity.')
        );
        System.assertEquals(false, RLM_MCP_LineAddRetry.isFractionalQuantityError('required field'));
        RLM_AI_AddProductToQuoteService.AddInput qtyOne =
            new RLM_AI_AddProductToQuoteService.AddInput();
        qtyOne.quantity = 1;
        RLM_AI_AddProductToQuoteService.AddOutput fail =
            new RLM_AI_AddProductToQuoteService.AddOutput();
        fail.isSuccess = false;
        fail.errorMessage = 'Cannot have a fractional quantity.';
        System.assertEquals(false, RLM_MCP_LineAddRetry.shouldRetryAtOne(qtyOne, fail));
        qtyOne.quantity = 8;
        System.assertEquals(true, RLM_MCP_LineAddRetry.shouldRetryAtOne(qtyOne, fail));
        System.assert(RLM_MCP_LineAddRetry.retryNote('Q-Rack 750', 8).contains('quantity 1'));
        System.assertEquals(
            0,
            RLM_MCP_LineAddRetry.addWithRetry(null, null, null).size()
        );
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
