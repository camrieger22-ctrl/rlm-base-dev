@IsTest
private class RLM_MCP_BundleConfigTest {

    private class FakeEngine implements RLM_MCP_BundleConfigService.Engine {
        RLM_RampConfiguratorAction.ConfigResult loadResult;
        RLM_RampConfiguratorAction.ConfigResult saveResult;
        String lastSelectionJson;
        Integer loadCalls = 0;
        Integer saveCalls = 0;
        String loadMessage;

        public RLM_RampConfiguratorAction.ConfigResult load(String quoteId, String quoteLineItemId) {
            loadCalls++;
            if (loadResult != null) {
                return loadResult;
            }
            RLM_RampConfiguratorAction.ConfigResult failed =
                new RLM_RampConfiguratorAction.ConfigResult();
            failed.success = false;
            failed.message = loadMessage == null ? 'no fake load' : loadMessage;
            return failed;
        }

        public RLM_RampConfiguratorAction.ConfigResult save(
            String quoteId,
            String quoteLineItemId,
            String selectionJson
        ) {
            saveCalls++;
            lastSelectionJson = selectionJson;
            return saveResult == null ? loadResult : saveResult;
        }
    }

    @TestSetup
    static void setup() {
        update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
        Account account = new Account(Name = 'Config MCP Account');
        insert account;
        Opportunity opportunity = new Opportunity(
            Name = 'Config MCP Opp',
            AccountId = account.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opportunity;
        Id pricebookId = Test.getStandardPricebookId();
        Product2 bundle = new Product2(
            Name = 'MCP Complete Bundle',
            StockKeepingUnit = 'MCP-CFG-COMPLETE',
            IsActive = true,
            Type = 'Bundle'
        );
        Product2 other = new Product2(
            Name = 'MCP Rack Bundle',
            StockKeepingUnit = 'MCP-CFG-RACK',
            IsActive = true,
            Type = 'Bundle'
        );
        insert new List<Product2>{ bundle, other };
        PricebookEntry bundleEntry = new PricebookEntry(
            Pricebook2Id = pricebookId,
            Product2Id = bundle.Id,
            UnitPrice = 1000,
            IsActive = true
        );
        PricebookEntry otherEntry = new PricebookEntry(
            Pricebook2Id = pricebookId,
            Product2Id = other.Id,
            UnitPrice = 500,
            IsActive = true
        );
        insert new List<PricebookEntry>{ bundleEntry, otherEntry };
        Quote quote = new Quote(
            Name = 'Config MCP Quote',
            OpportunityId = opportunity.Id,
            Pricebook2Id = pricebookId,
            Status = 'Draft'
        );
        Quote otherQuote = new Quote(
            Name = 'Config MCP Other',
            OpportunityId = opportunity.Id,
            Pricebook2Id = pricebookId,
            Status = 'Draft'
        );
        insert new List<Quote>{ quote, otherQuote };
        insert new List<QuoteLineItem>{
            new QuoteLineItem(
                QuoteId = quote.Id,
                PricebookEntryId = bundleEntry.Id,
                Product2Id = bundle.Id,
                Quantity = 1,
                UnitPrice = 1000
            ),
            new QuoteLineItem(
                QuoteId = quote.Id,
                PricebookEntryId = otherEntry.Id,
                Product2Id = other.Id,
                Quantity = 1,
                UnitPrice = 500
            )
        };
    }

    @IsTest
    static void describe_requiresIdentity() {
        List<RLM_MCP_DescribeBundleConfiguration.DescribeOutput> results =
            RLM_MCP_DescribeBundleConfiguration.describe(
                new List<RLM_MCP_DescribeBundleConfiguration.DescribeInput>{
                    new RLM_MCP_DescribeBundleConfiguration.DescribeInput()
                }
            );
        System.assertEquals(1, results.size());
        System.assertEquals(false, results[0].isSuccess);
        System.assert(results[0].errorMessage.contains('quote name'), results[0].errorMessage);
    }

    @IsTest
    static void describe_disambiguatesQuotes() {
        FakeEngine fake = new FakeEngine();
        RLM_MCP_BundleConfigService.engine = fake;
        RLM_MCP_DescribeBundleConfiguration.DescribeInput input =
            new RLM_MCP_DescribeBundleConfiguration.DescribeInput();
        input.accountName = 'Config MCP Account';

        RLM_MCP_DescribeBundleConfiguration.DescribeOutput out =
            RLM_MCP_DescribeBundleConfiguration.describe(
                new List<RLM_MCP_DescribeBundleConfiguration.DescribeInput>{ input }
            )[0];

        System.assertEquals(false, out.isSuccess);
        System.assertEquals(true, out.needsDisambiguation);
        System.assert(out.candidateSummariesDisplay.contains('Config MCP Quote'));
        System.assertEquals(0, fake.loadCalls);
    }

    @IsTest
    static void describe_formatsLoadedGroups() {
        RLM_MCP_DescribeBundleConfiguration.DescribeInput input =
            new RLM_MCP_DescribeBundleConfiguration.DescribeInput();
        input.quoteName = 'Config MCP Quote';
        input.productName = 'MCP-CFG-COMPLETE';

        Test.startTest();
        FakeEngine fake = new FakeEngine();
        fake.loadResult = sampleConfig(true);
        RLM_MCP_BundleConfigService.engine = fake;
        RLM_MCP_DescribeBundleConfiguration.DescribeOutput out =
            RLM_MCP_DescribeBundleConfiguration.describe(
                new List<RLM_MCP_DescribeBundleConfiguration.DescribeInput>{ input }
            )[0];
        Test.stopTest();

        System.assertEquals(true, out.isSuccess, 'describe failed: ' + out.errorMessage);
        System.assertEquals(1, fake.loadCalls);
        System.assertEquals(0, fake.saveCalls);
        System.assert(out.configurationDisplay.contains('MCP Complete Bundle'));
        System.assert(out.configurationDisplay.contains('[x] QuantumBit Database'));
        System.assert(out.configurationDisplay.contains('required; must stay selected'));
        System.assert(out.configurationDisplay.contains('catalog default'));
        System.assert(out.configurationDisplay.contains('[x] QB Memory 32GB'));
        System.assert(out.configurationDisplay.contains('Pick 1 consumption product'));
    }

    @IsTest
    static void configure_selectsSkuAndPersists() {
        RLM_MCP_ConfigureBundle.ConfigureInput input = new RLM_MCP_ConfigureBundle.ConfigureInput();
        input.quoteName = 'Config MCP Quote';
        input.productName = 'MCP Complete Bundle';
        input.selectedProducts = 'QB-MEM 32GB';

        Test.startTest();
        FakeEngine fake = new FakeEngine();
        fake.loadResult = sampleConfig(false);
        fake.saveResult = sampleConfig(true);
        fake.saveResult.messages = new List<RLM_RampConfiguratorAction.ConfigMessage>();
        RLM_MCP_BundleConfigService.engine = fake;
        RLM_MCP_ConfigureBundle.ConfigureOutput out =
            RLM_MCP_ConfigureBundle.configure(
                new List<RLM_MCP_ConfigureBundle.ConfigureInput>{ input }
            )[0];
        Test.stopTest();

        System.assertEquals(true, out.isSuccess, 'configure failed: ' + out.errorMessage);
        System.assertEquals(1, fake.loadCalls);
        System.assertEquals(1, fake.saveCalls);
        System.assert(fake.lastSelectionJson.contains('01t000000000MEMAAA'));
        System.assert(out.configurationDisplay.contains('[x] QB Memory 32GB'));
    }

    @IsTest
    static void configure_rejectsUnknownOption() {
        FakeEngine fake = new FakeEngine();
        fake.loadResult = sampleConfig(false);
        RLM_MCP_BundleConfigService.engine = fake;
        RLM_MCP_ConfigureBundle.ConfigureInput input = new RLM_MCP_ConfigureBundle.ConfigureInput();
        input.quoteName = 'Config MCP Quote';
        input.productName = 'MCP-CFG-COMPLETE';
        input.selectedProducts = 'Not A Real SKU';

        RLM_MCP_ConfigureBundle.ConfigureOutput out =
            RLM_MCP_ConfigureBundle.configure(
                new List<RLM_MCP_ConfigureBundle.ConfigureInput>{ input }
            )[0];

        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('No option matching'), out.errorMessage);
        System.assertEquals(0, fake.saveCalls);
    }

    @IsTest
    static void configure_emptyInputList() {
        List<RLM_MCP_ConfigureBundle.ConfigureOutput> results =
            RLM_MCP_ConfigureBundle.configure(
                new List<RLM_MCP_ConfigureBundle.ConfigureInput>()
            );
        System.assertEquals(0, results.size());
    }

    @IsTest
    static void describe_missingBundleLine() {
        FakeEngine fake = new FakeEngine();
        RLM_MCP_BundleConfigService.engine = fake;
        Quote empty = [SELECT Id FROM Quote WHERE Name = 'Config MCP Other'];
        RLM_MCP_DescribeBundleConfiguration.DescribeInput input =
            new RLM_MCP_DescribeBundleConfiguration.DescribeInput();
        input.quoteId = empty.Id;
        input.productName = 'MCP-CFG-COMPLETE';

        RLM_MCP_DescribeBundleConfiguration.DescribeOutput out =
            RLM_MCP_DescribeBundleConfiguration.describe(
                new List<RLM_MCP_DescribeBundleConfiguration.DescribeInput>{ input }
            )[0];

        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('Add that product first'), out.errorMessage);
        System.assertEquals(0, fake.loadCalls);
    }

    private static RLM_RampConfiguratorAction.ConfigResult sampleConfig(Boolean memorySelected) {
        RLM_RampConfiguratorAction.ConfigResult config =
            new RLM_RampConfiguratorAction.ConfigResult();
        config.success = true;
        config.transactionContextId = 'ctx-1';

        RLM_RampConfiguratorAction.ConfigComponent database =
            new RLM_RampConfiguratorAction.ConfigComponent();
        database.product2Id = '01t000000000DBAAA';
        database.name = 'QuantumBit Database';
        database.sku = 'QB-DB';
        database.required = true;
        database.selected = true;
        database.quantity = 1;
        database.pricebookEntryId = '01u000000000DBAAA';

        RLM_RampConfiguratorAction.ConfigComponent memory =
            new RLM_RampConfiguratorAction.ConfigComponent();
        memory.product2Id = '01t000000000MEMAAA';
        memory.name = 'QB Memory 32GB';
        memory.sku = 'QB-MEM 32GB';
        memory.required = false;
        memory.defaulted = true;
        memory.selected = memorySelected;
        memory.quantity = 1;
        memory.pricebookEntryId = '01u000000000MEMAAA';
        memory.productRelatedComponentId = '0go000000000MEMAAA';

        RLM_RampConfiguratorAction.ConfigGroup software = new RLM_RampConfiguratorAction.ConfigGroup();
        software.name = 'Software';
        software.selectionMode = 'multiple';
        software.rangeLabel = 'Pick at least 1';
        software.components = new List<RLM_RampConfiguratorAction.ConfigComponent>{ database };

        RLM_RampConfiguratorAction.ConfigGroup memoryGroup = new RLM_RampConfiguratorAction.ConfigGroup();
        memoryGroup.name = 'Memory';
        memoryGroup.selectionMode = 'single';
        memoryGroup.rangeLabel = 'Pick 1';
        memoryGroup.components = new List<RLM_RampConfiguratorAction.ConfigComponent>{ memory };

        config.groups = new List<RLM_RampConfiguratorAction.ConfigGroup>{ software, memoryGroup };

        RLM_RampConfiguratorAction.ConfigMessage warning =
            new RLM_RampConfiguratorAction.ConfigMessage();
        warning.messageType = 'warning';
        warning.text = 'Pick 1 consumption product.';
        config.messages = new List<RLM_RampConfiguratorAction.ConfigMessage>{ warning };

        RLM_RampConfiguratorAction.ConfigAttribute os =
            new RLM_RampConfiguratorAction.ConfigAttribute();
        os.label = 'Operating System';
        os.attributeName = 'Operating_System';
        os.attributeKey = '0tj000000000OSAAA';
        os.required = true;
        os.value = 'Redhat Enterprise Linux';
        RLM_RampConfiguratorAction.ConfigPicklistOption opt =
            new RLM_RampConfiguratorAction.ConfigPicklistOption();
        opt.label = 'Redhat Enterprise Linux';
        opt.value = 'Redhat Enterprise Linux';
        opt.picklistValueId = '0tv000000000RHAAA';
        os.options = new List<RLM_RampConfiguratorAction.ConfigPicklistOption>{ opt };
        config.attributes = new List<RLM_RampConfiguratorAction.ConfigAttribute>{ os };
        return config;
    }
}
