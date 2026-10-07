@IsTest
private class RLM_MCP_OrderLifecycleTest {
    private class FakeCreateInvoker implements RLM_MCP_OrderLifecycle.CreateOrderInvoker {
        Integer calls = 0;
        Boolean succeed;
        String errorMessage;
        FakeCreateInvoker(Boolean succeed) {
            this.succeed = succeed;
            this.errorMessage = 'boom';
        }
        public RLM_MCP_OrderLifecycle.CreateOrderResult create(Id quoteId) {
            calls++;
            if (succeed != true) {
                return new RLM_MCP_OrderLifecycle.CreateOrderResult(false, null, errorMessage);
            }
            Quote q = [SELECT AccountId FROM Quote WHERE Id = :quoteId];
            Order o = new Order(
                AccountId = q.AccountId,
                QuoteId = quoteId,
                Status = 'Draft',
                EffectiveDate = Date.today(),
                Pricebook2Id = Test.getStandardPricebookId()
            );
            insert o;
            return new RLM_MCP_OrderLifecycle.CreateOrderResult(true, String.valueOf(o.Id), null);
        }
    }

    @TestSetup
    static void setup() {
        update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
        Account a = new Account(
            Name = 'Zephyr Order Co',
            BillingStreet = '1 Market St',
            BillingCity = 'San Francisco',
            BillingState = 'CA',
            BillingPostalCode = '94105',
            BillingCountry = 'US',
            ShippingStreet = '1 Market St',
            ShippingCity = 'San Francisco',
            ShippingState = 'CA',
            ShippingPostalCode = '94105',
            ShippingCountry = 'US'
        );
        insert a;
        insert new Contact(
            LastName = 'Billing',
            AccountId = a.Id,
            Email = 'billing@example.com'
        );
        Opportunity opp = new Opportunity(
            Name = 'Zephyr Order Opp',
            AccountId = a.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Id pbId = Test.getStandardPricebookId();
        Product2 p = new Product2(Name = 'Zephyr Widget', IsActive = true);
        insert p;
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = pbId,
            Product2Id = p.Id,
            UnitPrice = 100,
            IsActive = true
        );
        insert pbe;
        List<Quote> quotes = new List<Quote>{
            new Quote(
                Name = 'Zephyr Expansion',
                OpportunityId = opp.Id,
                Pricebook2Id = pbId,
                Status = 'Draft'
            ),
            new Quote(
                Name = 'Zephyr Renewal',
                OpportunityId = opp.Id,
                Pricebook2Id = pbId,
                Status = 'Draft'
            ),
            new Quote(
                Name = 'Zephyr Empty',
                OpportunityId = opp.Id,
                Pricebook2Id = pbId,
                Status = 'Draft'
            )
        };
        insert quotes;
        insert new List<QuoteLineItem>{
            new QuoteLineItem(
                QuoteId = quotes[0].Id,
                PricebookEntryId = pbe.Id,
                Product2Id = p.Id,
                Quantity = 1,
                UnitPrice = 100
            ),
            new QuoteLineItem(
                QuoteId = quotes[1].Id,
                PricebookEntryId = pbe.Id,
                Product2Id = p.Id,
                Quantity = 2,
                UnitPrice = 100
            )
        };
    }

    @IsTest
    static void createRequiresIdentity() {
        System.assertEquals(0, RLM_MCP_CreateOrderFromQuote.createOrder(null).size());
        RLM_MCP_CreateOrderFromQuote.CreateOutput out =
            RLM_MCP_CreateOrderFromQuote.createOrder(
                new List<RLM_MCP_CreateOrderFromQuote.CreateInput>{
                    new RLM_MCP_CreateOrderFromQuote.CreateInput()
                }
            )[0];
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('quote name'), out.errorMessage);
    }

    @IsTest
    static void createNoMatch() {
        RLM_MCP_CreateOrderFromQuote.CreateInput input =
            new RLM_MCP_CreateOrderFromQuote.CreateInput();
        input.quoteName = 'No Such Quote XYZ';
        RLM_MCP_CreateOrderFromQuote.CreateOutput out =
            RLM_MCP_CreateOrderFromQuote.createOrder(
                new List<RLM_MCP_CreateOrderFromQuote.CreateInput>{ input }
            )[0];
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.startsWith('No quote found'), out.errorMessage);
    }

    @IsTest
    static void createEmptyQuoteRejected() {
        FakeCreateInvoker fake = new FakeCreateInvoker(true);
        RLM_MCP_OrderLifecycle.invoker = fake;
        RLM_MCP_CreateOrderFromQuote.CreateInput input =
            new RLM_MCP_CreateOrderFromQuote.CreateInput();
        input.quoteName = 'Zephyr Empty';
        RLM_MCP_CreateOrderFromQuote.CreateOutput out =
            RLM_MCP_CreateOrderFromQuote.createOrder(
                new List<RLM_MCP_CreateOrderFromQuote.CreateInput>{ input }
            )[0];
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('no lines'), out.errorMessage);
        System.assertEquals(0, fake.calls);
    }

    @IsTest
    static void createDisambiguates() {
        FakeCreateInvoker fake = new FakeCreateInvoker(true);
        RLM_MCP_OrderLifecycle.invoker = fake;
        RLM_MCP_CreateOrderFromQuote.CreateInput input =
            new RLM_MCP_CreateOrderFromQuote.CreateInput();
        input.accountName = 'Zephyr Order';
        RLM_MCP_CreateOrderFromQuote.CreateOutput out =
            RLM_MCP_CreateOrderFromQuote.createOrder(
                new List<RLM_MCP_CreateOrderFromQuote.CreateInput>{ input }
            )[0];
        System.assertEquals(false, out.isSuccess);
        System.assertEquals(true, out.needsDisambiguation);
        System.assert(out.candidateSummariesDisplay.contains('Zephyr Expansion'));
        System.assertEquals(0, fake.calls);
    }

    @IsTest
    static void createFromExactName() {
        FakeCreateInvoker fake = new FakeCreateInvoker(true);
        RLM_MCP_OrderLifecycle.invoker = fake;
        RLM_MCP_CreateOrderFromQuote.CreateInput input =
            new RLM_MCP_CreateOrderFromQuote.CreateInput();
        input.quoteName = 'zephyr expansion';
        Test.startTest();
        RLM_MCP_CreateOrderFromQuote.CreateOutput out =
            RLM_MCP_CreateOrderFromQuote.createOrder(
                new List<RLM_MCP_CreateOrderFromQuote.CreateInput>{ input }
            )[0];
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, 'err=' + out.errorMessage);
        System.assertEquals(1, fake.calls);
        System.assertNotEquals(null, out.orderId);
        System.assert(
            out.orderUrl != null && out.orderUrl.contains('/lightning/r/Order/'),
            out.orderUrl
        );
        System.assert(out.message.contains('Open Order'), out.message);
        Order created = [SELECT QuoteId, BillToContactId, ShippingStreet FROM Order WHERE Id = :out.orderId];
        Quote q = [SELECT Id FROM Quote WHERE Name = 'Zephyr Expansion'];
        System.assertEquals(q.Id, created.QuoteId);
        System.assertNotEquals(null, created.BillToContactId);
        System.assertEquals('1 Market St', created.ShippingStreet);
    }

    @IsTest
    static void createReusesExistingOrder() {
        FakeCreateInvoker fake = new FakeCreateInvoker(true);
        RLM_MCP_OrderLifecycle.invoker = fake;
        Quote q = [SELECT Id, AccountId FROM Quote WHERE Name = 'Zephyr Expansion'];
        insert new Order(
            AccountId = q.AccountId,
            QuoteId = q.Id,
            Status = 'Draft',
            EffectiveDate = Date.today(),
            Pricebook2Id = Test.getStandardPricebookId()
        );
        RLM_MCP_CreateOrderFromQuote.CreateInput input =
            new RLM_MCP_CreateOrderFromQuote.CreateInput();
        input.quoteId = String.valueOf(q.Id);
        RLM_MCP_CreateOrderFromQuote.CreateOutput out =
            RLM_MCP_CreateOrderFromQuote.createOrder(
                new List<RLM_MCP_CreateOrderFromQuote.CreateInput>{ input }
            )[0];
        System.assertEquals(true, out.isSuccess, 'err=' + out.errorMessage);
        System.assertEquals(0, fake.calls);
        System.assert(out.message.contains('existing'), out.message);
    }

    @IsTest
    static void createInvokerFailureIsReported() {
        FakeCreateInvoker fake = new FakeCreateInvoker(false);
        RLM_MCP_OrderLifecycle.invoker = fake;
        RLM_MCP_CreateOrderFromQuote.CreateInput input =
            new RLM_MCP_CreateOrderFromQuote.CreateInput();
        input.quoteName = 'Zephyr Expansion';
        RLM_MCP_CreateOrderFromQuote.CreateOutput out =
            RLM_MCP_CreateOrderFromQuote.createOrder(
                new List<RLM_MCP_CreateOrderFromQuote.CreateInput>{ input }
            )[0];
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('boom'), out.errorMessage);
    }

    @IsTest
    static void activateRequiresIdentity() {
        System.assertEquals(0, RLM_MCP_ActivateOrder.activate(null).size());
        RLM_MCP_ActivateOrder.ActivateOutput out =
            RLM_MCP_ActivateOrder.activate(
                new List<RLM_MCP_ActivateOrder.ActivateInput>{
                    new RLM_MCP_ActivateOrder.ActivateInput()
                }
            )[0];
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('order'), out.errorMessage);
    }

    @IsTest
    static void activateMissingContactIsBlocked() {
        Account bare = new Account(Name = 'No Contact Account');
        insert bare;
        Order o = new Order(
            AccountId = bare.Id,
            Status = 'Draft',
            EffectiveDate = Date.today(),
            Pricebook2Id = Test.getStandardPricebookId()
        );
        insert o;
        RLM_MCP_ActivateOrder.ActivateInput input = new RLM_MCP_ActivateOrder.ActivateInput();
        input.orderId = String.valueOf(o.Id);
        RLM_MCP_ActivateOrder.ActivateOutput out =
            RLM_MCP_ActivateOrder.activate(
                new List<RLM_MCP_ActivateOrder.ActivateInput>{ input }
            )[0];
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('Bill to Contact'), out.errorMessage);
        System.assertEquals('Draft', [SELECT Status FROM Order WHERE Id = :o.Id].Status);
    }

    @IsTest
    static void activateSetsStatusAndLinks() {
        Quote q = [SELECT Id, AccountId FROM Quote WHERE Name = 'Zephyr Expansion'];
        Product2 p = [SELECT Id FROM Product2 WHERE Name = 'Zephyr Widget'];
        PricebookEntry pbe = [
            SELECT Id FROM PricebookEntry WHERE Product2Id = :p.Id LIMIT 1
        ];
        Order o = new Order(
            AccountId = q.AccountId,
            QuoteId = q.Id,
            Status = 'Draft',
            EffectiveDate = Date.today(),
            Pricebook2Id = Test.getStandardPricebookId()
        );
        insert o;
        insert new OrderItem(
            OrderId = o.Id,
            PricebookEntryId = pbe.Id,
            Product2Id = p.Id,
            Quantity = 1,
            UnitPrice = 100
        );
        RLM_MCP_ActivateOrder.ActivateInput input = new RLM_MCP_ActivateOrder.ActivateInput();
        input.quoteName = 'Zephyr Expansion';
        Test.startTest();
        RLM_MCP_ActivateOrder.ActivateOutput out =
            RLM_MCP_ActivateOrder.activate(
                new List<RLM_MCP_ActivateOrder.ActivateInput>{ input }
            )[0];
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, 'err=' + out.errorMessage);
        Order stamped = [
            SELECT BillToContactId, ShippingStreet FROM Order WHERE Id = :o.Id
        ];
        System.assertNotEquals(null, stamped.BillToContactId);
        System.assertEquals('1 Market St', stamped.ShippingStreet);
        System.assert(
            out.orderUrl != null && out.orderUrl.contains('/lightning/r/Order/'),
            out.orderUrl
        );
        System.assert(out.message.contains('Open Order'), out.message);
    }
}
