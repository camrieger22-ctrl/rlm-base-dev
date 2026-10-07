@IsTest
private class RLM_MCP_AmendAssetTest {
    private class FakeInvoker implements RLM_MCP_AmendAsset.AmendmentInvoker {
        Integer calls = 0;
        Boolean succeed;
        String quoteId;
        String errorMessage;
        Boolean returnNull;
        Id lastAssetId;
        Decimal lastQuantity;

        FakeInvoker(Boolean succeed, String quoteId) {
            this.succeed = succeed;
            this.quoteId = quoteId;
            this.errorMessage = 'boom';
        }

        public RLM_MCP_AmendAsset.InvokeResult start(
            Id assetId,
            Date startDay,
            Decimal quantityChange,
            Id opportunityId
        ) {
            calls++;
            lastAssetId = assetId;
            lastQuantity = quantityChange;
            if (returnNull == true) {
                return null;
            }
            if (succeed != true) {
                return new RLM_MCP_AmendAsset.InvokeResult(false, null, errorMessage);
            }
            return new RLM_MCP_AmendAsset.InvokeResult(true, quoteId, null);
        }
    }

    @TestSetup
    static void setup() {
        update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
        Account acme = new Account(Name = 'Zephyr Amend Co');
        Account other = new Account(Name = 'Other Amend Co');
        insert new List<Account>{ acme, other };
        insert new Opportunity(
            Name = 'Zephyr Amend Opp',
            AccountId = acme.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        Product2 db = new Product2(
            Name = 'Zephyr Amend Database',
            StockKeepingUnit = 'ZAMD-DB',
            IsActive = true
        );
        Product2 complete = new Product2(
            Name = 'Zephyr Amend Complete',
            StockKeepingUnit = 'ZAMD-COMPLETE',
            IsActive = true
        );
        insert new List<Product2>{ db, complete };
        insert new List<Asset>{
            new Asset(
                Name = 'QB Database',
                AccountId = acme.Id,
                Product2Id = db.Id,
                Quantity = 10,
                Status = 'Purchased'
            ),
            new Asset(
                Name = 'QB Complete',
                AccountId = acme.Id,
                Product2Id = complete.Id,
                Quantity = 1,
                Status = 'Purchased'
            ),
            new Asset(
                Name = 'QB Database Other',
                AccountId = other.Id,
                Product2Id = db.Id,
                Quantity = 4,
                Status = 'Purchased'
            )
        };
        insert new Quote(
            Name = 'Zephyr Amend Seed',
            OpportunityId = [SELECT Id FROM Opportunity WHERE Name = 'Zephyr Amend Opp'].Id,
            Status = 'Draft'
        );
    }

    private static RLM_MCP_AmendAsset.AmendOutput run(RLM_MCP_AmendAsset.AmendInput input) {
        return RLM_MCP_AmendAsset.amend(
            new List<RLM_MCP_AmendAsset.AmendInput>{ input }
        )[0];
    }

    private static String todayStamp() {
        return String.valueOf(Date.today());
    }

    private static Asset databaseAsset() {
        return [
            SELECT Id, AccountId
            FROM Asset
            WHERE Name = 'QB Database'
            LIMIT 1
        ];
    }

    @IsTest
    static void emptyInputIsEmpty() {
        System.assertEquals(0, RLM_MCP_AmendAsset.amend(null).size());
        System.assertEquals(
            0,
            RLM_MCP_AmendAsset.amend(new List<RLM_MCP_AmendAsset.AmendInput>()).size()
        );
    }

    @IsTest
    static void quantityChangeRequired() {
        RLM_MCP_AmendAsset.AmendOutput out = run(new RLM_MCP_AmendAsset.AmendInput());
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('Quantity change'), out.errorMessage);
    }

    @IsTest
    static void startDateRequired() {
        RLM_MCP_AmendAsset.AmendInput input = new RLM_MCP_AmendAsset.AmendInput();
        input.quantityChange = 1;
        input.assetId = String.valueOf(databaseAsset().Id);
        RLM_MCP_AmendAsset.AmendOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('start date is required'), out.errorMessage);
    }

    @IsTest
    static void invalidAssetId() {
        RLM_MCP_AmendAsset.AmendInput input = new RLM_MCP_AmendAsset.AmendInput();
        input.quantityChange = 1;
        input.assetId = 'not-an-id';
        RLM_MCP_AmendAsset.AmendOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assertEquals('Invalid Asset Id.', out.errorMessage);
    }

    @IsTest
    static void wrongObjectIdRejected() {
        Account a = [SELECT Id FROM Account WHERE Name = 'Zephyr Amend Co'];
        RLM_MCP_AmendAsset.AmendInput input = new RLM_MCP_AmendAsset.AmendInput();
        input.quantityChange = 1;
        input.assetId = String.valueOf(a.Id);
        RLM_MCP_AmendAsset.AmendOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assertEquals('Invalid Asset Id.', out.errorMessage);
    }

    @IsTest
    static void missingIdentity() {
        RLM_MCP_AmendAsset.AmendInput input = new RLM_MCP_AmendAsset.AmendInput();
        input.quantityChange = 1;
        RLM_MCP_AmendAsset.AmendOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('asset Id'), out.errorMessage);
    }

    @IsTest
    static void noMatch() {
        RLM_MCP_AmendAsset.AmendInput input = new RLM_MCP_AmendAsset.AmendInput();
        input.quantityChange = 1;
        input.accountName = 'No Such Account XYZ';
        input.productName = 'No Such Product';
        RLM_MCP_AmendAsset.AmendOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.startsWith('No asset found'), out.errorMessage);
    }

    @IsTest
    static void missingAssetForId() {
        Asset gone = new Asset(
            Name = 'Gone Asset',
            AccountId = [SELECT Id FROM Account WHERE Name = 'Zephyr Amend Co'].Id,
            Quantity = 1
        );
        insert gone;
        Id goneId = gone.Id;
        delete gone;
        RLM_MCP_AmendAsset.AmendInput input = new RLM_MCP_AmendAsset.AmendInput();
        input.quantityChange = 1;
        input.assetId = String.valueOf(goneId);
        RLM_MCP_AmendAsset.AmendOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assertEquals('No asset found for that Id.', out.errorMessage);
    }

    @IsTest
    static void disambiguatesProductOnly() {
        FakeInvoker fake = new FakeInvoker(true, null);
        RLM_MCP_AmendAsset.invoker = fake;
        RLM_MCP_AmendAsset.AmendInput input = new RLM_MCP_AmendAsset.AmendInput();
        input.quantityChange = 2;
        input.productName = 'Zephyr Amend Database';
        RLM_MCP_AmendAsset.AmendOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assertEquals(true, out.needsDisambiguation);
        System.assert(out.candidateSummariesDisplay.contains('Zephyr Amend Database'));
        System.assertEquals(0, fake.calls);
    }

    @IsTest
    static void exactAccountAndProduct() {
        Quote seed = [SELECT Id FROM Quote WHERE Name = 'Zephyr Amend Seed'];
        FakeInvoker fake = new FakeInvoker(true, String.valueOf(seed.Id));
        RLM_MCP_AmendAsset.invoker = fake;
        RLM_MCP_AmendAsset.AmendInput input = new RLM_MCP_AmendAsset.AmendInput();
        input.quantityChange = 5;
        input.startDate = todayStamp();
        input.accountName = 'Zephyr Amend';
        input.productName = 'zephyr amend database';
        Test.startTest();
        RLM_MCP_AmendAsset.AmendOutput out = run(input);
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, 'err=' + out.errorMessage);
        System.assertEquals(1, fake.calls);
        System.assertEquals(seed.Id, out.quoteId);
        System.assert(
            out.quoteUrl != null && out.quoteUrl.contains('/lightning/r/Quote/'),
            out.quoteUrl
        );
        System.assert(out.message.contains('Open Quote'), out.message);
        System.assert(out.message.contains('+5'), out.message);
        System.assert(out.message.contains('create an order'), out.message);
    }

    @IsTest
    static void resolveBySkuAndAssetId() {
        Quote seed = [SELECT Id FROM Quote WHERE Name = 'Zephyr Amend Seed'];
        Asset asset = databaseAsset();
        FakeInvoker fake = new FakeInvoker(true, String.valueOf(seed.Id));
        RLM_MCP_AmendAsset.invoker = fake;
        RLM_MCP_AmendAsset.AmendInput input = new RLM_MCP_AmendAsset.AmendInput();
        input.quantityChange = -2;
        input.startDate = todayStamp();
        input.accountName = 'Zephyr Amend Co';
        input.productName = 'ZAMD-DB';
        RLM_MCP_AmendAsset.AmendOutput bySku = run(input);
        System.assertEquals(true, bySku.isSuccess, 'err=' + bySku.errorMessage);
        System.assert(bySku.message.contains('-2'), bySku.message);

        RLM_MCP_AmendAsset.AmendInput byId = new RLM_MCP_AmendAsset.AmendInput();
        byId.quantityChange = 1;
        byId.assetId = String.valueOf(asset.Id);
        byId.startDate = String.valueOf(Date.today()) + 'T00:00:00Z';
        RLM_MCP_AmendAsset.AmendOutput out = run(byId);
        System.assertEquals(true, out.isSuccess, 'err=' + out.errorMessage);
        System.assertEquals(asset.Id, out.assetId);
        System.assert(out.assetUrl.contains('/lightning/r/Asset/'), out.assetUrl);
    }

    @IsTest
    static void accountOnlyWithOneAsset() {
        Quote seed = [SELECT Id FROM Quote WHERE Name = 'Zephyr Amend Seed'];
        FakeInvoker fake = new FakeInvoker(true, String.valueOf(seed.Id));
        RLM_MCP_AmendAsset.invoker = fake;
        delete [SELECT Id FROM Asset WHERE Name = 'QB Complete'];
        RLM_MCP_AmendAsset.AmendInput input = new RLM_MCP_AmendAsset.AmendInput();
        input.quantityChange = 1;
        input.startDate = todayStamp();
        input.accountName = 'Zephyr Amend Co';
        RLM_MCP_AmendAsset.AmendOutput out = run(input);
        System.assertEquals(true, out.isSuccess, 'err=' + out.errorMessage);
        System.assertEquals(1, fake.calls);
    }

    @IsTest
    static void invalidStartDate() {
        RLM_MCP_AmendAsset.AmendInput input = new RLM_MCP_AmendAsset.AmendInput();
        input.quantityChange = 1;
        input.assetId = String.valueOf(databaseAsset().Id);
        input.startDate = 'not-a-date';
        RLM_MCP_AmendAsset.AmendOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('yyyy-mm-dd'), out.errorMessage);
    }

    @IsTest
    static void invokerFailureIsReported() {
        FakeInvoker fake = new FakeInvoker(false, null);
        RLM_MCP_AmendAsset.invoker = fake;
        RLM_MCP_AmendAsset.AmendInput input = new RLM_MCP_AmendAsset.AmendInput();
        input.quantityChange = 1;
        input.startDate = todayStamp();
        input.assetId = String.valueOf(databaseAsset().Id);
        RLM_MCP_AmendAsset.AmendOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('boom'), out.errorMessage);
    }

    @IsTest
    static void nullInvokerResult() {
        FakeInvoker fake = new FakeInvoker(true, null);
        fake.returnNull = true;
        RLM_MCP_AmendAsset.invoker = fake;
        RLM_MCP_AmendAsset.AmendInput input = new RLM_MCP_AmendAsset.AmendInput();
        input.quantityChange = 1;
        input.startDate = todayStamp();
        input.assetId = String.valueOf(databaseAsset().Id);
        RLM_MCP_AmendAsset.AmendOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('Could not start'), out.errorMessage);
    }

    @IsTest
    static void missingQuoteIsPartial() {
        FakeInvoker fake = new FakeInvoker(true, null);
        RLM_MCP_AmendAsset.invoker = fake;
        RLM_MCP_AmendAsset.AmendInput input = new RLM_MCP_AmendAsset.AmendInput();
        input.quantityChange = 1;
        input.startDate = todayStamp();
        input.assetId = String.valueOf(databaseAsset().Id);
        RLM_MCP_AmendAsset.AmendOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assertEquals(true, out.isPartial);
        System.assert(out.errorMessage.contains('not visible yet'), out.errorMessage);
    }

    @IsTest
    static void uniqueProductNameWithoutAccount() {
        Quote seed = [SELECT Id FROM Quote WHERE Name = 'Zephyr Amend Seed'];
        FakeInvoker fake = new FakeInvoker(true, String.valueOf(seed.Id));
        RLM_MCP_AmendAsset.invoker = fake;
        RLM_MCP_AmendAsset.AmendInput input = new RLM_MCP_AmendAsset.AmendInput();
        input.quantityChange = 1;
        input.startDate = todayStamp();
        input.productName = 'Zephyr Amend Complete';
        RLM_MCP_AmendAsset.AmendOutput out = run(input);
        System.assertEquals(true, out.isSuccess, 'err=' + out.errorMessage);
        System.assertEquals(1, fake.calls);
    }

    @IsTest
    static void defaultInvokerReportsFailure() {
        RLM_MCP_AmendAsset.invoker = new RLM_MCP_AmendAsset.DefaultAmendmentInvoker();
        RLM_MCP_AmendAsset.AmendInput input = new RLM_MCP_AmendAsset.AmendInput();
        input.quantityChange = 1;
        input.startDate = todayStamp();
        input.assetId = String.valueOf(databaseAsset().Id);
        Test.startTest();
        RLM_MCP_AmendAsset.AmendOutput out = run(input);
        Test.stopTest();
        System.assertEquals(false, out.isSuccess);
        System.assertNotEquals(null, out.errorMessage);
    }

    @IsTest
    static void missingQuoteIdThrowsThenCaught() {
        Account a = [SELECT Id FROM Account WHERE Name = 'Zephyr Amend Co'];
        FakeInvoker fake = new FakeInvoker(true, String.valueOf(a.Id));
        RLM_MCP_AmendAsset.invoker = fake;
        RLM_MCP_AmendAsset.AmendInput input = new RLM_MCP_AmendAsset.AmendInput();
        input.quantityChange = 1;
        input.startDate = todayStamp();
        input.assetId = String.valueOf(databaseAsset().Id);
        RLM_MCP_AmendAsset.AmendOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assertNotEquals(null, out.errorMessage);
    }

    @IsTest
    static void componentWalksToParentThenPatchesLine() {
        Asset parent = [SELECT Id FROM Asset WHERE Name = 'QB Complete'];
        Asset child = [SELECT Id, Product2Id FROM Asset WHERE Name = 'QB Database'];
        child.ParentId = parent.Id;
        update child;
        Quote seed = [SELECT Id FROM Quote WHERE Name = 'Zephyr Amend Seed'];
        Id pbId = Test.getStandardPricebookId();
        seed.Pricebook2Id = pbId;
        update seed;
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = pbId,
            Product2Id = child.Product2Id,
            UnitPrice = 100,
            IsActive = true
        );
        insert pbe;
        insert new QuoteLineItem(
            QuoteId = seed.Id,
            PricebookEntryId = pbe.Id,
            Product2Id = child.Product2Id,
            Quantity = 1,
            UnitPrice = 100
        );
        FakeInvoker fake = new FakeInvoker(true, String.valueOf(seed.Id));
        RLM_MCP_AmendAsset.invoker = fake;
        RLM_MCP_AmendAsset.AmendInput input = new RLM_MCP_AmendAsset.AmendInput();
        input.quantityChange = 5;
        input.startDate = todayStamp();
        input.accountName = 'Zephyr Amend Co';
        input.productName = 'Zephyr Amend Database';
        Test.startTest();
        RLM_MCP_AmendAsset.AmendOutput out = run(input);
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, 'err=' + out.errorMessage);
        System.assertEquals(parent.Id, fake.lastAssetId);
        System.assertEquals(0, fake.lastQuantity);
        System.assert(out.message.contains('parent'), out.message);
        QuoteLineItem patched = [
            SELECT Quantity FROM QuoteLineItem WHERE QuoteId = :seed.Id AND Product2Id = :child.Product2Id
        ];
        System.assertEquals(5, patched.Quantity);
    }
}
