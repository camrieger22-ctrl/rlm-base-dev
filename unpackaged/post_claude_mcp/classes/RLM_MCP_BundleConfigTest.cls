@IsTest
private class RLM_MCP_BundleConfigTest {

    private class FakeEngine implements RLM_MCP_BundleConfigService.Engine {
        RLM_RampConfiguratorAction.ConfigResult loadResult;
        RLM_RampConfiguratorAction.ConfigResult applyResult;
        RLM_RampConfiguratorAction.ConfigResult saveResult;
        String lastSelectionJson;
        Map<String, String> lastAttributeValues;
        Integer loadCalls = 0;
        Integer applyCalls = 0;
        Integer saveCalls = 0;
        List<String> savedLineIds = new List<String>();
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

        public RLM_RampConfiguratorAction.ConfigResult applyAttributes(
            String quoteId,
            String quoteLineItemId,
            Map<String, String> attributeValues
        ) {
            applyCalls++;
            lastAttributeValues = attributeValues;
            if (applyResult != null) {
                return applyResult;
            }
            RLM_RampConfiguratorAction.ConfigResult working = loadResult;
            if (working != null && working.attributes != null && attributeValues != null) {
                for (RLM_RampConfiguratorAction.ConfigAttribute attr : working.attributes) {
                    if (attr == null) {
                        continue;
                    }
                    for (String key : attributeValues.keySet()) {
                        if (key == null) {
                            continue;
                        }
                        if ((attr.label != null && attr.label.equalsIgnoreCase(key))
                            || (attr.attributeName != null && attr.attributeName.equalsIgnoreCase(key))) {
                            attr.value = attributeValues.get(key);
                        }
                    }
                }
            }
            return working;
        }

        public RLM_RampConfiguratorAction.ConfigResult save(
            String quoteId,
            String quoteLineItemId,
            String selectionJson
        ) {
            saveCalls++;
            lastSelectionJson = selectionJson;
            savedLineIds.add(quoteLineItemId);
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
    static void describe_retriesWhenCreLoading() {
        FakeEngine fake = new FakeEngine();
        fake.loadMessage = RLM_RampConfiguratorAction.CRE_LOADING;
        RLM_MCP_BundleConfigService.engine = fake;
        RLM_MCP_DescribeBundleConfiguration.DescribeInput input =
            new RLM_MCP_DescribeBundleConfiguration.DescribeInput();
        input.quoteName = 'Config MCP Quote';
        input.productName = 'MCP-CFG-COMPLETE';

        RLM_MCP_DescribeBundleConfiguration.DescribeOutput out =
            RLM_MCP_DescribeBundleConfiguration.describe(
                new List<RLM_MCP_DescribeBundleConfiguration.DescribeInput>{ input }
            )[0];

        System.assertEquals(false, out.isSuccess);
        System.assertEquals(true, out.needsAction);
        System.assertNotEquals(null, out.quoteLineItemId);
        System.assert(out.errorMessage.contains('Call this tool again immediately'), out.errorMessage);
        System.assert(out.errorMessage.contains('at most 3 times'), out.errorMessage);
        System.assert(out.errorMessage.contains('Do not query QuoteLineItem children'), out.errorMessage);
        System.assert(out.errorMessage.contains('Do not invent Dual'), out.errorMessage);
        System.assertEquals(1, fake.loadCalls);
        System.assert(out.errorMessage.contains('### Fix this'), out.errorMessage);
    }

    @IsTest
    static void formatDisplayPutsFixThisFirst() {
        Quote quote = [
            SELECT Id, Name, Account.Name
            FROM Quote
            WHERE Name = 'Config MCP Quote'
            LIMIT 1
        ];
        QuoteLineItem line = [
            SELECT Id, Product2.Name, Product2.StockKeepingUnit
            FROM QuoteLineItem
            WHERE QuoteId = :quote.Id
            LIMIT 1
        ];
        RLM_RampConfiguratorAction.ConfigResult config = sampleConfig(true);
        RLM_RampConfiguratorAction.ConfigAttribute socket =
            new RLM_RampConfiguratorAction.ConfigAttribute();
        socket.attributeName = 'SocketConfiguration';
        socket.label = 'Socket';
        socket.value = 'Dual';
        RLM_RampConfiguratorAction.ConfigAttribute workload =
            new RLM_RampConfiguratorAction.ConfigAttribute();
        workload.attributeName = 'Workload';
        workload.label = 'Workload';
        workload.value = 'General';
        config.attributes.add(socket);
        config.attributes.add(workload);
        RLM_RampConfiguratorAction.ConfigMessage gold =
            new RLM_RampConfiguratorAction.ConfigMessage();
        gold.messageType = 'constraint';
        gold.text = 'Dual cannot use a Gold CPU. Pick a Platinum, or switch Socket to Single.';
        config.messages.add(gold);

        String display = RLM_MCP_BundleConfigService.formatDisplay(quote, line, config);
        System.assert(display.startsWith('Constraint'), display);
        System.assert(display.contains('Rule:'), display);
        System.assert(display.contains('### Fix this'), display);
        System.assert(display.contains('What to change'), display);
        System.assert(display.contains('Dual sockets need Workload'), display);
        System.assert(display.contains('Dual cannot use a Gold CPU'), display);
        System.assertEquals(false, display.contains('- constraint:'), display);
    }

    @IsTest
    static void formatDisplayFlagsLeftoverGoldWithoutCreMessage() {
        Quote quote = [
            SELECT Id, Name, Account.Name
            FROM Quote
            WHERE Name = 'Config MCP Quote'
            LIMIT 1
        ];
        QuoteLineItem line = [
            SELECT Id, Product2.Name, Product2.StockKeepingUnit
            FROM QuoteLineItem
            WHERE QuoteId = :quote.Id
            LIMIT 1
        ];
        RLM_RampConfiguratorAction.ConfigResult config = sampleQRackConfig(true);
        config.groups[0].components[0].selected = true;
        config.messages = new List<RLM_RampConfiguratorAction.ConfigMessage>();

        String display = RLM_MCP_BundleConfigService.formatDisplay(quote, line, config);
        System.assert(display.startsWith('Constraint'), display);
        System.assert(display.contains(
            'Rule: Dual cannot use a Gold CPU. Pick a Platinum, or switch Socket to Single.'),
            display);
        System.assertEquals(
            false,
            display.contains('Dual sockets cannot use a Gold CPU.'),
            display
        );
        System.assert(display.contains('Now:'), display);
        System.assert(display.contains('Change one of:'), display);
        System.assert(display.contains('Processor →'), display);
        System.assert(display.contains('Socket Configuration → Single'), display);
        System.assertEquals(false, display.contains('Processor → Intel Xeon Gold'), display);
        System.assert(display.contains('I will not configure until you pick.'), display);
        System.assert(display.contains('### Fix this'), display);
        System.assert(display.contains('Dual cannot use a Gold CPU'), display);
        System.assertEquals(
            true,
            RLM_MCP_BundleConfigService.hasBlockingIssues(config)
        );
    }

    @IsTest
    static void configure_flagsLeftoverGoldAfterPersist() {
        FakeEngine fake = new FakeEngine();
        fake.loadResult = sampleQRackConfig(true);
        fake.saveResult = sampleQRackConfig(true);
        fake.saveResult.groups[0].components[0].selected = true;
        fake.saveResult.messages = new List<RLM_RampConfiguratorAction.ConfigMessage>();
        RLM_MCP_BundleConfigService.engine = fake;
        RLM_MCP_ConfigureBundle.ConfigureInput input = new RLM_MCP_ConfigureBundle.ConfigureInput();
        input.quoteName = 'Config MCP Quote';
        input.productName = 'MCP Complete Bundle';
        input.attributePicksJson =
            '{"Socket Configuration":"Dual","Workload":"High Performance Computing"}';

        RLM_MCP_ConfigureBundle.ConfigureOutput out =
            RLM_MCP_ConfigureBundle.configure(
                new List<RLM_MCP_ConfigureBundle.ConfigureInput>{ input }
            )[0];

        System.assertEquals(true, out.isSuccess, 'configure failed: ' + out.errorMessage);
        System.assertEquals(true, out.needsAction);
        System.assert(String.isNotBlank(out.constraintCoachDisplay), out.constraintCoachDisplay);
        System.assert(out.constraintCoachDisplay.startsWith('Constraint'), out.constraintCoachDisplay);
        System.assert(out.constraintCoachDisplay.contains('Rule:'), out.constraintCoachDisplay);
        System.assert(out.constraintCoachDisplay.contains('Now:'), out.constraintCoachDisplay);
        System.assert(out.constraintCoachDisplay.contains('Change one of:'),
            out.constraintCoachDisplay);
        System.assert(out.constraintCoachDisplay.contains('I will not configure until you pick.'),
            out.constraintCoachDisplay);
        System.assert(out.configurationDisplay.startsWith('Constraint'), out.configurationDisplay);
        System.assert(out.configurationDisplay.contains('### Fix this'), out.configurationDisplay);
        System.assert(out.configurationDisplay.contains('Dual cannot use a Gold CPU'),
            out.configurationDisplay);
        System.assertEquals(
            false,
            out.configurationDisplay.contains('Fix the picks and call configure'),
            out.configurationDisplay
        );
        System.assertEquals(
            false,
            out.configurationDisplay.contains('constraints still fail'),
            out.configurationDisplay
        );
    }

    @IsTest
    static void formatDisplayFlagsSingleLeftoverDualHardware() {
        Quote quote = [
            SELECT Id, Name, Account.Name
            FROM Quote
            WHERE Name = 'Config MCP Quote'
            LIMIT 1
        ];
        QuoteLineItem line = [
            SELECT Id, Product2.Name, Product2.StockKeepingUnit
            FROM QuoteLineItem
            WHERE QuoteId = :quote.Id
            LIMIT 1
        ];
        RLM_RampConfiguratorAction.ConfigResult config = sampleQRackConfig(true);
        config.attributes[0].value = 'Single';
        RLM_RampConfiguratorAction.ConfigMessage staleGold =
            new RLM_RampConfiguratorAction.ConfigMessage();
        staleGold.messageType = 'constraint';
        staleGold.text = 'Dual cannot use a Gold CPU. Pick a Platinum, or switch Socket to Single.';
        config.messages = new List<RLM_RampConfiguratorAction.ConfigMessage>{ staleGold };

        String display = RLM_MCP_BundleConfigService.formatDisplay(quote, line, config);
        System.assert(display.startsWith('Constraint'), display);
        System.assert(display.contains('### Fix this'), display);
        System.assert(display.contains(
            'Rule: Dual sockets need Workload AI or High Performance Computing.'),
            display);
        System.assert(display.contains('Workload → General'), display);
        System.assertEquals(false, display.contains('two CPUs or two liquid coolers'), display);
        System.assertEquals(false, display.contains('Gold CPU'), display);
        System.assertEquals(
            true,
            RLM_MCP_BundleConfigService.hasBlockingIssues(config)
        );
    }

    @IsTest
    static void configure_flagsSingleLeftoverAfterDualPersist() {
        FakeEngine fake = new FakeEngine();
        fake.loadResult = sampleQRackConfig(true);
        fake.saveResult = sampleQRackConfig(true);
        fake.saveResult.attributes[0].value = 'Single';
        RLM_RampConfiguratorAction.ConfigMessage staleGold =
            new RLM_RampConfiguratorAction.ConfigMessage();
        staleGold.messageType = 'constraint';
        staleGold.text = 'Dual cannot use a Gold CPU. Pick a Platinum, or switch Socket to Single.';
        fake.saveResult.messages = new List<RLM_RampConfiguratorAction.ConfigMessage>{ staleGold };
        RLM_MCP_BundleConfigService.engine = fake;
        RLM_MCP_ConfigureBundle.ConfigureInput input = new RLM_MCP_ConfigureBundle.ConfigureInput();
        input.quoteName = 'Config MCP Quote';
        input.productName = 'MCP Complete Bundle';
        input.attributePicksJson = '{"Socket Configuration":"Single"}';

        RLM_MCP_ConfigureBundle.ConfigureOutput out =
            RLM_MCP_ConfigureBundle.configure(
                new List<RLM_MCP_ConfigureBundle.ConfigureInput>{ input }
            )[0];

        System.assertEquals(true, out.isSuccess, 'configure failed: ' + out.errorMessage);
        System.assertEquals(true, out.needsAction);
        System.assert(out.configurationDisplay.contains('### Fix this'), out.configurationDisplay);
        System.assert(out.configurationDisplay.contains(
            'Rule: Dual sockets need Workload AI or High Performance Computing.'),
            out.configurationDisplay);
        System.assertEquals(false, out.configurationDisplay.contains('two CPUs or two liquid coolers'),
            out.configurationDisplay);
        System.assertEquals(false, out.configurationDisplay.contains('Gold CPU'),
            out.configurationDisplay);
    }

    @IsTest
    static void formatDisplayMapsDomainLeftoverToPlatform() {
        Quote quote = [
            SELECT Id, Name, Account.Name
            FROM Quote
            WHERE Name = 'Config MCP Quote'
            LIMIT 1
        ];
        QuoteLineItem line = [
            SELECT Id, Product2.Name, Product2.StockKeepingUnit
            FROM QuoteLineItem
            WHERE QuoteId = :quote.Id
            LIMIT 1
        ];
        RLM_RampConfiguratorAction.ConfigResult config = sampleConfig(true);
        config.success = false;
        config.message = 'Calculated value int 1 is not in domain of x16Lanes in Server_0';

        String display = RLM_MCP_BundleConfigService.formatDisplay(quote, line, config);
        System.assert(display.startsWith('Constraint'), display);
        System.assert(display.contains('### Fix this'), display);
        System.assert(display.contains('Performance Tier'), display);
        System.assert(display.contains('Socket'), display);
        System.assertEquals(false, display.contains('Server_0'), display);
        System.assertEquals('change_picks', config.fixKind);
    }

    @IsTest
    static void formatDisplayMapsGenericCreToCoachCard() {
        Quote quote = [
            SELECT Id, Name, Account.Name
            FROM Quote
            WHERE Name = 'Config MCP Quote'
            LIMIT 1
        ];
        QuoteLineItem line = [
            SELECT Id, Product2.Name, Product2.StockKeepingUnit
            FROM QuoteLineItem
            WHERE QuoteId = :quote.Id
            LIMIT 1
        ];
        RLM_RampConfiguratorAction.ConfigResult config = sampleConfig(true);
        RLM_RampConfiguratorAction.ConfigAttribute raid =
            new RLM_RampConfiguratorAction.ConfigAttribute();
        raid.label = 'RAID';
        raid.attributeName = 'RAID';
        raid.value = 'RAID 1';
        RLM_RampConfiguratorAction.ConfigPicklistOption raidNa =
            new RLM_RampConfiguratorAction.ConfigPicklistOption();
        raidNa.label = 'N/A';
        raidNa.value = 'N/A';
        RLM_RampConfiguratorAction.ConfigPicklistOption raid1 =
            new RLM_RampConfiguratorAction.ConfigPicklistOption();
        raid1.label = 'RAID 1';
        raid1.value = 'RAID 1';
        raid.options = new List<RLM_RampConfiguratorAction.ConfigPicklistOption>{
            raidNa, raid1
        };
        config.attributes.add(raid);
        RLM_RampConfiguratorAction.ConfigComponent raidCard =
            new RLM_RampConfiguratorAction.ConfigComponent();
        raidCard.name = 'RAID 500 card';
        raidCard.sku = 'QB-RAID-500';
        raidCard.selected = false;
        RLM_RampConfiguratorAction.ConfigGroup controller =
            new RLM_RampConfiguratorAction.ConfigGroup();
        controller.name = 'Controller';
        controller.components = new List<RLM_RampConfiguratorAction.ConfigComponent>{
            raidCard
        };
        config.groups.add(controller);
        RLM_RampConfiguratorAction.ConfigMessage raidMsg =
            new RLM_RampConfiguratorAction.ConfigMessage();
        raidMsg.messageType = 'constraint';
        raidMsg.text = 'RAID 1 requires a RAID 500 card.';
        config.messages.add(raidMsg);

        String display = RLM_MCP_BundleConfigService.formatDisplay(quote, line, config);
        System.assert(display.startsWith('Constraint'), display);
        System.assert(display.contains(
            'Rule: RAID needs a RAID 500 card. Add it, or set RAID to N/A.'), display);
        System.assert(display.contains('Now: RAID = RAID 1'), display);
        System.assert(display.contains('RAID → N/A'), display);
        System.assert(display.contains('Controller → RAID 500 card'), display);
        System.assertEquals(false, display.contains('Server_0'), display);
    }

    @IsTest
    static void formatDisplayHidesSolverLeftoverFromCoachCard() {
        Quote quote = [
            SELECT Id, Name, Account.Name
            FROM Quote
            WHERE Name = 'Config MCP Quote'
            LIMIT 1
        ];
        QuoteLineItem line = [
            SELECT Id, Product2.Name, Product2.StockKeepingUnit
            FROM QuoteLineItem
            WHERE QuoteId = :quote.Id
            LIMIT 1
        ];
        RLM_RampConfiguratorAction.ConfigResult config = sampleConfig(true);
        config.success = false;
        config.message = 'Calculated value int 1 is not in domain of FooBar in Server_0';

        String display = RLM_MCP_BundleConfigService.formatDisplay(quote, line, config);
        System.assertEquals(null, config.constraintCoachDisplay);
        System.assertEquals('platform', config.fixKind);
        System.assertEquals(false, display.startsWith('Constraint'), display);
        System.assert(display.contains('### Fix this'), display);
        System.assertEquals(false, display.contains('Server_0'), display);
        System.assertEquals(false, display.contains('not in domain'), display);
    }

    @IsTest
    static void describe_leftoverGoldLeadsWithCoachCard() {
        FakeEngine fake = new FakeEngine();
        fake.loadResult = sampleQRackConfig(true);
        fake.loadResult.groups[0].components[0].selected = true;
        fake.loadResult.messages = new List<RLM_RampConfiguratorAction.ConfigMessage>();
        RLM_MCP_BundleConfigService.engine = fake;
        RLM_MCP_DescribeBundleConfiguration.DescribeInput input =
            new RLM_MCP_DescribeBundleConfiguration.DescribeInput();
        input.quoteName = 'Config MCP Quote';
        input.productName = 'MCP Complete Bundle';

        RLM_MCP_DescribeBundleConfiguration.DescribeOutput out =
            RLM_MCP_DescribeBundleConfiguration.describe(
                new List<RLM_MCP_DescribeBundleConfiguration.DescribeInput>{ input }
            )[0];

        System.assertEquals(true, out.isSuccess, 'describe failed: ' + out.errorMessage);
        System.assertEquals(true, out.needsAction);
        System.assert(String.isNotBlank(out.constraintCoachDisplay), out.constraintCoachDisplay);
        System.assert(out.constraintCoachDisplay.startsWith('Constraint'),
            out.constraintCoachDisplay);
        System.assert(out.configurationDisplay.startsWith('Constraint'), out.configurationDisplay);
        System.assert(out.configurationDisplay.contains('I will not configure until you pick.'),
            out.configurationDisplay);
        System.assertEquals(
            false,
            out.configurationDisplay.contains('Keep-or-drill'),
            out.configurationDisplay
        );
        System.assertEquals(
            false,
            out.configurationDisplay.contains('Step 1 of 2'),
            out.configurationDisplay
        );
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
        System.assertEquals(true, out.needsAction);
        System.assertEquals(1, fake.loadCalls);
        System.assertEquals(0, fake.saveCalls);
        System.assert(out.configurationDisplay.contains('Wait'));
        System.assert(out.configurationDisplay.contains('MCP Complete Bundle'));
        System.assert(out.configurationDisplay.contains('[x] QuantumBit Database'));
        System.assert(out.configurationDisplay.contains('required; must stay selected'));
        System.assert(out.configurationDisplay.contains('catalog default'));
        System.assert(out.configurationDisplay.contains('[x] QB Memory 32GB'));
        System.assert(out.configurationDisplay.contains('Pick 1 consumption product'));
        System.assert(out.configurationDisplay.contains('keep the current mix'), out.configurationDisplay);
        System.assert(out.configurationDisplay.contains('configure once'), out.configurationDisplay);
        System.assert(out.configurationDisplay.contains('quoteLineItemId'), out.configurationDisplay);
        System.assert(out.configurationDisplay.contains('Attributes'), out.configurationDisplay);
        System.assertEquals(
            false,
            out.configurationDisplay.contains('Step 1 of 2'),
            out.configurationDisplay);
        System.assertEquals(
            false,
            out.configurationDisplay.contains('Keep all current attributes'),
            out.configurationDisplay);
        System.assertEquals(
            false,
            out.configurationDisplay.contains('. Options:'),
            out.configurationDisplay);
        System.assert(
            !out.configurationDisplay.contains('Keep General'),
            out.configurationDisplay);
        System.assertEquals(
            false,
            out.configurationDisplay.contains('Step 2 of 2'),
            out.configurationDisplay);
        System.assertEquals(
            false,
            out.configurationDisplay.contains('Keep all catalog add-ons'),
            out.configurationDisplay);
        System.assertEquals(
            false,
            out.configurationDisplay.contains('clean engine save'),
            out.configurationDisplay);
    }

    @IsTest
    static void describe_priceImpactingShowsAffectsPrice() {
        FakeEngine fake = new FakeEngine();
        fake.loadResult = sampleConfig(true);
        addPriceTier(fake.loadResult, false);
        RLM_MCP_BundleConfigService.engine = fake;
        RLM_MCP_DescribeBundleConfiguration.DescribeInput input =
            new RLM_MCP_DescribeBundleConfiguration.DescribeInput();
        input.quoteName = 'Config MCP Quote';
        input.productName = 'MCP-CFG-COMPLETE';

        RLM_MCP_DescribeBundleConfiguration.DescribeOutput out =
            RLM_MCP_DescribeBundleConfiguration.describe(
                new List<RLM_MCP_DescribeBundleConfiguration.DescribeInput>{ input }
            )[0];

        System.assertEquals(true, out.isSuccess, 'describe failed: ' + out.errorMessage);
        System.assertEquals(true, out.needsAction);
        System.assert(out.configurationDisplay.startsWith('Constraint'), out.configurationDisplay);
        System.assert(out.configurationDisplay.contains('Performance Tier'), out.configurationDisplay);
        System.assert(out.configurationDisplay.contains('(not set)'), out.configurationDisplay);
        System.assertEquals(
            false,
            out.configurationDisplay.contains('affects price'),
            out.configurationDisplay
        );
        System.assertEquals(
            false,
            out.configurationDisplay.contains('keep the current mix'),
            out.configurationDisplay
        );
        System.assert(out.constraintCoachDisplay.contains('Performance Tier still needs a value.'),
            out.constraintCoachDisplay);
        System.assert(out.constraintCoachDisplay.contains('I will not configure until you pick.'),
            out.constraintCoachDisplay);
    }

    @IsTest
    static void configure_priceImpactingWithoutPicksKeepsNeedsAction() {
        FakeEngine fake = new FakeEngine();
        fake.loadResult = sampleConfig(true);
        addPriceTier(fake.loadResult, true);
        fake.saveResult = sampleConfig(true);
        addPriceTier(fake.saveResult, true);
        fake.saveResult.messages = new List<RLM_RampConfiguratorAction.ConfigMessage>();
        RLM_MCP_BundleConfigService.engine = fake;
        RLM_MCP_ConfigureBundle.ConfigureInput input = new RLM_MCP_ConfigureBundle.ConfigureInput();
        input.quoteName = 'Config MCP Quote';
        input.productName = 'MCP Complete Bundle';
        input.selectedProducts = 'QB-MEM 32GB';

        RLM_MCP_ConfigureBundle.ConfigureOutput out =
            RLM_MCP_ConfigureBundle.configure(
                new List<RLM_MCP_ConfigureBundle.ConfigureInput>{ input }
            )[0];

        System.assertEquals(true, out.isSuccess, 'configure failed: ' + out.errorMessage);
        System.assertEquals(true, out.needsAction);
        System.assert(out.errorMessage.contains('attributePicksJson'), out.errorMessage);
        System.assertEquals(
            false,
            out.configurationDisplay.contains('Fix the picks and call configure'),
            out.configurationDisplay
        );
        System.assertEquals(1, fake.saveCalls);
    }

    @IsTest
    static void configure_attributePicksJsonClearsNeedsAction() {
        FakeEngine fake = new FakeEngine();
        fake.loadResult = sampleConfig(true);
        addPriceTier(fake.loadResult, false);
        fake.saveResult = sampleConfig(true);
        addPriceTier(fake.saveResult, true);
        fake.saveResult.messages = new List<RLM_RampConfiguratorAction.ConfigMessage>();
        RLM_MCP_BundleConfigService.engine = fake;
        RLM_MCP_ConfigureBundle.ConfigureInput input = new RLM_MCP_ConfigureBundle.ConfigureInput();
        input.quoteName = 'Config MCP Quote';
        input.productName = 'MCP Complete Bundle';
        input.selectedProducts = 'QB-MEM 32GB';
        input.attributePicksJson = '{"Performance Tier":"Performance"}';

        RLM_MCP_ConfigureBundle.ConfigureOutput out =
            RLM_MCP_ConfigureBundle.configure(
                new List<RLM_MCP_ConfigureBundle.ConfigureInput>{ input }
            )[0];

        System.assertEquals(true, out.isSuccess, 'configure failed: ' + out.errorMessage);
        System.assertEquals(false, out.needsAction);
        System.assert(fake.lastSelectionJson.contains('Performance'), fake.lastSelectionJson);
        System.assertEquals(1, fake.applyCalls);
        System.assertEquals(1, fake.saveCalls);
    }

    @IsTest
    static void configure_requiredAttributeBlankKeepsNeedsAction() {
        FakeEngine fake = new FakeEngine();
        fake.loadResult = sampleConfig(true);
        fake.loadResult.attributes[0].value = null;
        fake.loadResult.attributes[0].picklistValueId = null;
        fake.saveResult = sampleConfig(true);
        fake.saveResult.attributes[0].value = null;
        fake.saveResult.attributes[0].picklistValueId = null;
        fake.saveResult.messages = new List<RLM_RampConfiguratorAction.ConfigMessage>();
        RLM_MCP_BundleConfigService.engine = fake;
        RLM_MCP_ConfigureBundle.ConfigureInput input = new RLM_MCP_ConfigureBundle.ConfigureInput();
        input.quoteName = 'Config MCP Quote';
        input.productName = 'MCP Complete Bundle';
        input.selectedProducts = 'QB-MEM 32GB';

        RLM_MCP_ConfigureBundle.ConfigureOutput out =
            RLM_MCP_ConfigureBundle.configure(
                new List<RLM_MCP_ConfigureBundle.ConfigureInput>{ input }
            )[0];

        System.assertEquals(true, out.isSuccess, 'configure failed: ' + out.errorMessage);
        System.assertEquals(true, out.needsAction);
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
        System.assertEquals(false, out.needsAction);
        System.assertEquals(1, fake.loadCalls);
        System.assertEquals(1, fake.saveCalls);
        System.assert(fake.lastSelectionJson.contains('01t000000000MEMAAA'));
        System.assert(out.configurationDisplay.contains('[x] QB Memory 32GB'));
    }

    @IsTest
    static void describe_pinsQuoteLineItemId() {
        QuoteLineItem rack = [
            SELECT Id, QuoteId FROM QuoteLineItem
            WHERE Product2.StockKeepingUnit = 'MCP-CFG-RACK'
        ];
        FakeEngine fake = new FakeEngine();
        fake.loadResult = sampleConfig(true);
        RLM_MCP_BundleConfigService.engine = fake;
        RLM_MCP_DescribeBundleConfiguration.DescribeInput input =
            new RLM_MCP_DescribeBundleConfiguration.DescribeInput();
        input.quoteId = rack.QuoteId;
        input.productName = 'MCP Complete Bundle';
        input.quoteLineItemId = String.valueOf(rack.Id);

        RLM_MCP_DescribeBundleConfiguration.DescribeOutput out =
            RLM_MCP_DescribeBundleConfiguration.describe(
                new List<RLM_MCP_DescribeBundleConfiguration.DescribeInput>{ input }
            )[0];

        System.assertEquals(true, out.isSuccess, 'describe failed: ' + out.errorMessage);
        System.assertEquals(String.valueOf(rack.Id), out.quoteLineItemId);
        System.assertEquals(true, out.needsAction);
    }

    @IsTest
    static void configure_cannotUnselectRequired() {
        FakeEngine fake = new FakeEngine();
        fake.loadResult = sampleConfig(true);
        RLM_MCP_BundleConfigService.engine = fake;
        RLM_MCP_ConfigureBundle.ConfigureInput input = new RLM_MCP_ConfigureBundle.ConfigureInput();
        input.quoteName = 'Config MCP Quote';
        input.productName = 'MCP-CFG-COMPLETE';
        input.unselectedProducts = 'QuantumBit Database';

        RLM_MCP_ConfigureBundle.ConfigureOutput out =
            RLM_MCP_ConfigureBundle.configure(
                new List<RLM_MCP_ConfigureBundle.ConfigureInput>{ input }
            )[0];

        System.assertEquals(false, out.isSuccess);
        System.assertEquals(true, out.needsAction);
        System.assert(out.errorMessage.contains('required'), out.errorMessage);
        System.assertEquals(0, fake.saveCalls);
    }

    @IsTest
    static void configure_cmlErrorKeepsNeedsAction() {
        FakeEngine fake = new FakeEngine();
        fake.loadResult = sampleConfig(true);
        fake.saveResult = sampleConfig(true);
        RLM_RampConfiguratorAction.ConfigMessage errorMsg =
            new RLM_RampConfiguratorAction.ConfigMessage();
        errorMsg.messageType = 'error';
        errorMsg.text = 'CPU and GPU cannot be combined.';
        fake.saveResult.messages = new List<RLM_RampConfiguratorAction.ConfigMessage>{ errorMsg };
        RLM_MCP_BundleConfigService.engine = fake;
        RLM_MCP_ConfigureBundle.ConfigureInput input = new RLM_MCP_ConfigureBundle.ConfigureInput();
        input.quoteName = 'Config MCP Quote';
        input.productName = 'MCP-CFG-COMPLETE';
        input.selectedProducts = 'QB-MEM 32GB';

        RLM_MCP_ConfigureBundle.ConfigureOutput out =
            RLM_MCP_ConfigureBundle.configure(
                new List<RLM_MCP_ConfigureBundle.ConfigureInput>{ input }
            )[0];

        System.assertEquals(true, out.isSuccess, 'configure failed: ' + out.errorMessage);
        System.assertEquals(true, out.needsAction);
        System.assert(out.configurationDisplay.contains('CPU and GPU cannot be combined'));
        System.assertEquals(
            false,
            out.configurationDisplay.contains('constraints still fail'),
            out.configurationDisplay
        );
        System.assertEquals(
            false,
            out.configurationDisplay.contains('Fix the picks and call configure'),
            out.configurationDisplay
        );
        System.assertEquals(1, fake.saveCalls);
    }

    @IsTest
    static void configure_copiesMixToRampSiblings() {
        Quote quote = [SELECT Id, OpportunityId, Pricebook2Id FROM Quote WHERE Name = 'Config MCP Other'];
        Product2 rack = [SELECT Id FROM Product2 WHERE StockKeepingUnit = 'MCP-CFG-RACK'];
        Id rackPbe = [SELECT Id FROM PricebookEntry WHERE Product2Id = :rack.Id].Id;
        QuoteLineGroup year2 = new QuoteLineGroup(
            QuoteId = quote.Id,
            Name = 'Year 2',
            SortOrder = 2,
            IsRamped = true,
            SegmentType = 'Yearly',
            StartDate = Date.newInstance(2027, 1, 1),
            EndDate = Date.newInstance(2027, 12, 31)
        );
        QuoteLineGroup year3 = new QuoteLineGroup(
            QuoteId = quote.Id,
            Name = 'Year 3',
            SortOrder = 3,
            IsRamped = true,
            SegmentType = 'Yearly',
            StartDate = Date.newInstance(2028, 1, 1),
            EndDate = Date.newInstance(2028, 12, 31)
        );
        insert new List<QuoteLineGroup>{ year2, year3 };
        QuoteLineItem parent2 = new QuoteLineItem(
            QuoteId = quote.Id,
            QuoteLineGroupId = year2.Id,
            PricebookEntryId = rackPbe,
            Product2Id = rack.Id,
            Quantity = 1,
            UnitPrice = 500
        );
        QuoteLineItem parent3 = new QuoteLineItem(
            QuoteId = quote.Id,
            QuoteLineGroupId = year3.Id,
            PricebookEntryId = rackPbe,
            Product2Id = rack.Id,
            Quantity = 1,
            UnitPrice = 500
        );
        insert new List<QuoteLineItem>{ parent2, parent3 };

        FakeEngine fake = new FakeEngine();
        fake.loadResult = sampleConfig(true);
        fake.saveResult = sampleConfig(true);
        fake.saveResult.messages = new List<RLM_RampConfiguratorAction.ConfigMessage>();
        RLM_MCP_BundleConfigService.engine = fake;
        RLM_MCP_ConfigureBundle.ConfigureInput input = new RLM_MCP_ConfigureBundle.ConfigureInput();
        input.quoteId = quote.Id;
        input.quoteLineItemId = String.valueOf(parent2.Id);
        input.selectedProducts = 'QB-MEM 32GB';

        Test.startTest();
        RLM_MCP_ConfigureBundle.ConfigureOutput out =
            RLM_MCP_ConfigureBundle.configure(
                new List<RLM_MCP_ConfigureBundle.ConfigureInput>{ input }
            )[0];
        Test.stopTest();

        System.assertEquals(true, out.isSuccess, 'configure failed: ' + out.errorMessage);
        System.assertEquals(false, out.needsAction);
        System.assertEquals(2, fake.saveCalls);
        System.assert(fake.savedLineIds.contains(String.valueOf(parent2.Id)));
        System.assert(fake.savedLineIds.contains(String.valueOf(parent3.Id)));
        System.assert(out.configurationDisplay.contains('Year 3'), out.configurationDisplay);
    }

    @IsTest
    static void siblingCopy_backfillsWhenChildrenExistWithoutAttributes() {
        Id siblingId = '0QL000000000001AAA';
        System.assertEquals(
            false,
            RLM_MCP_BundleConfigService.siblingAlreadyHasCopiedGraph(
                siblingId, new Set<Id>{ siblingId }, new Set<Id>()),
            'Children without QLIAs must still receive the attribute payload');
        System.assertEquals(
            true,
            RLM_MCP_BundleConfigService.siblingAlreadyHasCopiedGraph(
                siblingId, new Set<Id>{ siblingId }, new Set<Id>{ siblingId }));
        System.assertEquals(
            false,
            RLM_MCP_BundleConfigService.siblingAlreadyHasCopiedGraph(
                siblingId, new Set<Id>(), new Set<Id>{ siblingId }));
    }

    @IsTest
    static void configure_engineChangesRecapAndSiblingUsesSavedGraph() {
        Quote quote = [SELECT Id, OpportunityId, Pricebook2Id FROM Quote WHERE Name = 'Config MCP Other'];
        Product2 rack = [SELECT Id FROM Product2 WHERE StockKeepingUnit = 'MCP-CFG-RACK'];
        Id rackPbe = [SELECT Id FROM PricebookEntry WHERE Product2Id = :rack.Id].Id;
        QuoteLineGroup year2 = new QuoteLineGroup(
            QuoteId = quote.Id,
            Name = 'Year 2 Engine',
            SortOrder = 12,
            IsRamped = true,
            SegmentType = 'Yearly',
            StartDate = Date.newInstance(2027, 1, 1),
            EndDate = Date.newInstance(2027, 12, 31)
        );
        QuoteLineGroup year3 = new QuoteLineGroup(
            QuoteId = quote.Id,
            Name = 'Year 3 Engine',
            SortOrder = 13,
            IsRamped = true,
            SegmentType = 'Yearly',
            StartDate = Date.newInstance(2028, 1, 1),
            EndDate = Date.newInstance(2028, 12, 31)
        );
        insert new List<QuoteLineGroup>{ year2, year3 };
        QuoteLineItem parent2 = new QuoteLineItem(
            QuoteId = quote.Id,
            QuoteLineGroupId = year2.Id,
            PricebookEntryId = rackPbe,
            Product2Id = rack.Id,
            Quantity = 1,
            UnitPrice = 500
        );
        QuoteLineItem parent3 = new QuoteLineItem(
            QuoteId = quote.Id,
            QuoteLineGroupId = year3.Id,
            PricebookEntryId = rackPbe,
            Product2Id = rack.Id,
            Quantity = 1,
            UnitPrice = 500
        );
        insert new List<QuoteLineItem>{ parent2, parent3 };

        FakeEngine fake = new FakeEngine();
        fake.loadResult = sampleConfig(true);
        fake.saveResult = sampleConfig(true);
        fake.saveResult.groups[1].components[0].quantity = 2;
        fake.saveResult.messages = new List<RLM_RampConfiguratorAction.ConfigMessage>();
        RLM_MCP_BundleConfigService.engine = fake;
        RLM_MCP_ConfigureBundle.ConfigureInput input = new RLM_MCP_ConfigureBundle.ConfigureInput();
        input.quoteId = quote.Id;
        input.quoteLineItemId = String.valueOf(parent2.Id);
        input.selectedProducts = 'QB-MEM 32GB';

        RLM_MCP_ConfigureBundle.ConfigureOutput out =
            RLM_MCP_ConfigureBundle.configure(
                new List<RLM_MCP_ConfigureBundle.ConfigureInput>{ input }
            )[0];

        System.assertEquals(true, out.isSuccess, 'configure failed: ' + out.errorMessage);
        System.assertEquals(false, out.needsAction);
        System.assert(out.configurationDisplay.contains('Configurator updated the mix'), out.configurationDisplay);
        System.assert(out.configurationDisplay.contains('qty 1 → 2'), out.configurationDisplay);
        System.assertEquals(2, fake.saveCalls);
        System.assert(
            fake.lastSelectionJson.contains('"quantity":2'),
            fake.lastSelectionJson);
    }

    @IsTest
    static void configure_constraintMessagesSkipSiblingCopy() {
        Quote quote = [SELECT Id, OpportunityId, Pricebook2Id FROM Quote WHERE Name = 'Config MCP Other'];
        Product2 rack = [SELECT Id FROM Product2 WHERE StockKeepingUnit = 'MCP-CFG-RACK'];
        Id rackPbe = [SELECT Id FROM PricebookEntry WHERE Product2Id = :rack.Id].Id;
        QuoteLineGroup year2 = new QuoteLineGroup(
            QuoteId = quote.Id,
            Name = 'Year 2 Blocked',
            SortOrder = 22,
            IsRamped = true,
            SegmentType = 'Yearly',
            StartDate = Date.newInstance(2027, 1, 1),
            EndDate = Date.newInstance(2027, 12, 31)
        );
        QuoteLineGroup year3 = new QuoteLineGroup(
            QuoteId = quote.Id,
            Name = 'Year 3 Blocked',
            SortOrder = 23,
            IsRamped = true,
            SegmentType = 'Yearly',
            StartDate = Date.newInstance(2028, 1, 1),
            EndDate = Date.newInstance(2028, 12, 31)
        );
        insert new List<QuoteLineGroup>{ year2, year3 };
        QuoteLineItem parent2 = new QuoteLineItem(
            QuoteId = quote.Id,
            QuoteLineGroupId = year2.Id,
            PricebookEntryId = rackPbe,
            Product2Id = rack.Id,
            Quantity = 1,
            UnitPrice = 500
        );
        QuoteLineItem parent3 = new QuoteLineItem(
            QuoteId = quote.Id,
            QuoteLineGroupId = year3.Id,
            PricebookEntryId = rackPbe,
            Product2Id = rack.Id,
            Quantity = 1,
            UnitPrice = 500
        );
        insert new List<QuoteLineItem>{ parent2, parent3 };

        FakeEngine fake = new FakeEngine();
        fake.loadResult = sampleConfig(true);
        fake.saveResult = sampleConfig(true);
        RLM_RampConfiguratorAction.ConfigMessage errorMsg =
            new RLM_RampConfiguratorAction.ConfigMessage();
        errorMsg.messageType = 'constraint';
        errorMsg.text = 'Dual CPUs are only available for Platinum CPUs.';
        fake.saveResult.messages = new List<RLM_RampConfiguratorAction.ConfigMessage>{ errorMsg };
        RLM_MCP_BundleConfigService.engine = fake;
        RLM_MCP_ConfigureBundle.ConfigureInput input = new RLM_MCP_ConfigureBundle.ConfigureInput();
        input.quoteId = quote.Id;
        input.quoteLineItemId = String.valueOf(parent2.Id);
        input.selectedProducts = 'QB-MEM 32GB';

        RLM_MCP_ConfigureBundle.ConfigureOutput out =
            RLM_MCP_ConfigureBundle.configure(
                new List<RLM_MCP_ConfigureBundle.ConfigureInput>{ input }
            )[0];

        System.assertEquals(true, out.isSuccess, 'configure failed: ' + out.errorMessage);
        System.assertEquals(true, out.needsAction);
        System.assertEquals(1, fake.saveCalls);
        System.assert(out.configurationDisplay.contains('Dual cannot use a Gold CPU'));
        System.assert(
            !out.configurationDisplay.contains('Same mix copied'),
            out.configurationDisplay);
    }

    @IsTest
    static void fallback_detectsConfiguratorRulesCrash() {
        RLM_RampConfiguratorAction.ConfigResult ok =
            new RLM_RampConfiguratorAction.ConfigResult();
        ok.success = true;
        ok.message = 'Add-ons saved.';
        System.assertEquals(false, RLM_MCP_BundleConfigService.shouldFallbackToCatalog(ok));

        RLM_RampConfiguratorAction.ConfigResult crashed =
            new RLM_RampConfiguratorAction.ConfigResult();
        crashed.success = false;
        crashed.message = 'Something went wrong while running configuration rules. : com.salesforce.configurator.api.exception.ConfiguratorException';
        System.assertEquals(true, RLM_MCP_BundleConfigService.shouldFallbackToCatalog(crashed));
        System.assertEquals(true, RLM_MCP_BundleConfigService.shouldFallbackToCatalog(null));

        RLM_RampConfiguratorAction.ConfigResult catalog =
            new RLM_RampConfiguratorAction.ConfigResult();
        catalog.success = true;
        catalog.messages = new List<RLM_RampConfiguratorAction.ConfigMessage>();
        RLM_MCP_BundleConfigService.overlayRulesCrash(catalog, crashed);
        System.assertEquals('constraint', catalog.messages[0].messageType);
        System.assert(catalog.messages[0].text.contains('configuration rules'));
    }

    @IsTest
    static void overlayConfigRules_hidesPicklistAndDisabledComponent() {
        RLM_RampConfiguratorAction.ConfigResult catalog = sampleConfig(false);
        RLM_RampConfiguratorAction.ConfigPicklistOption extra =
            new RLM_RampConfiguratorAction.ConfigPicklistOption();
        extra.label = 'Windows Server';
        extra.value = 'Windows Server';
        extra.picklistValueId = '0tv000000000WINAA';
        catalog.attributes[0].options.add(extra);

        String rulesJson = JSON.serialize(new Map<String, Object>{
            'messageRules' => new List<Object>{
                new Map<String, Object>{
                    'severity' => 'ERROR',
                    'messages' => new List<String>{ 'RAM mix is invalid.' }
                }
            },
            'errors' => new List<Object>(),
            'visibilityRules' => new List<Object>{
                new Map<String, Object>{
                    'type' => 'Hide',
                    'target' => 'Attribute_Picklist_Value',
                    'attributePicklistValueId' => '0tv000000000WINAA'
                },
                new Map<String, Object>{
                    'type' => 'Disable',
                    'target' => 'Component',
                    'prcId' => '0go000000000MEMAAA'
                }
            }
        });
        RLM_MCP_BundleConfigService.overlayConfigRules(catalog, rulesJson);

        System.assertEquals(1, catalog.attributes[0].options.size(),
            JSON.serialize(catalog.attributes[0].options));
        System.assertEquals('Redhat Enterprise Linux', catalog.attributes[0].options[0].label);
        Boolean memoryStillListed = false;
        for (RLM_RampConfiguratorAction.ConfigComponent component : catalog.groups[1].components) {
            if (component.productRelatedComponentId == '0go000000000MEMAAA') {
                memoryStillListed = true;
            }
        }
        System.assertEquals(false, memoryStillListed);
        System.assertEquals('constraint', catalog.messages[1].messageType);
        System.assert(catalog.messages[1].text.contains('RAM mix is invalid.'));
    }

    @IsTest
    static void overlayConfigRules_selectedDisabledComponentIsBlocking() {
        RLM_RampConfiguratorAction.ConfigResult catalog = sampleConfig(true);
        String rulesJson = JSON.serialize(new Map<String, Object>{
            'messageRules' => new List<Object>(),
            'errors' => new List<Object>(),
            'visibilityRules' => new List<Object>{
                new Map<String, Object>{
                    'type' => 'Disable',
                    'target' => 'Component',
                    'prcId' => '0go000000000MEMAAA'
                }
            }
        });
        RLM_MCP_BundleConfigService.overlayConfigRules(catalog, rulesJson);
        System.assertEquals(true, catalog.groups[1].components[0].selected);
        System.assert(catalog.messages[1].text.contains('disabled by configuration rules'));
        System.assertEquals(
            true,
            RLM_MCP_BundleConfigService.hasBlockingIssues(catalog));
    }

    @IsTest
    static void configure_recapsCreDualGraph() {
        FakeEngine fake = new FakeEngine();
        fake.loadResult = sampleQRackConfig(false);
        fake.applyResult = sampleQRackConfig(true);
        fake.saveResult = sampleQRackConfig(true);
        fake.saveResult.messages = new List<RLM_RampConfiguratorAction.ConfigMessage>();
        RLM_MCP_BundleConfigService.engine = fake;
        RLM_MCP_ConfigureBundle.ConfigureInput input = new RLM_MCP_ConfigureBundle.ConfigureInput();
        input.quoteName = 'Config MCP Quote';
        input.productName = 'MCP Complete Bundle';
        input.attributePicksJson =
            '{"Socket Configuration":"Dual","Workload":"High Performance Computing"}';

        RLM_MCP_ConfigureBundle.ConfigureOutput out =
            RLM_MCP_ConfigureBundle.configure(
                new List<RLM_MCP_ConfigureBundle.ConfigureInput>{ input }
            )[0];

        System.assertEquals(true, out.isSuccess, 'configure failed: ' + out.errorMessage);
        System.assertEquals(1, fake.applyCalls);
        System.assertEquals(1, fake.saveCalls);
        System.assert(out.configurationDisplay.contains('Configurator updated the mix'),
            out.configurationDisplay);
        System.assert(out.configurationDisplay.contains('Removed Intel Xeon Gold'),
            out.configurationDisplay);
        System.assert(out.configurationDisplay.contains('Added Intel Xeon Platinum'),
            out.configurationDisplay);
        System.assert(out.configurationDisplay.contains('qty 2'), out.configurationDisplay);
        System.assert(out.configurationDisplay.contains('liquid cooler'),
            out.configurationDisplay.toLowerCase());
        System.assertEquals(
            'Dual',
            fake.lastAttributeValues.get('Socket Configuration'));
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

    private static void addPriceTier(
        RLM_RampConfiguratorAction.ConfigResult config,
        Boolean withValue
    ) {
        RLM_RampConfiguratorAction.ConfigAttribute tier =
            new RLM_RampConfiguratorAction.ConfigAttribute();
        tier.label = 'Performance Tier';
        tier.attributeName = 'PerformanceTier';
        tier.attributeKey = '0tj000000000PTAAA';
        tier.priceImpacting = true;
        tier.required = false;
        RLM_RampConfiguratorAction.ConfigPicklistOption entry =
            new RLM_RampConfiguratorAction.ConfigPicklistOption();
        entry.label = 'Entry';
        entry.value = 'Entry';
        entry.picklistValueId = '0tv000000000ENAAA';
        RLM_RampConfiguratorAction.ConfigPicklistOption performance =
            new RLM_RampConfiguratorAction.ConfigPicklistOption();
        performance.label = 'Performance';
        performance.value = 'Performance';
        performance.picklistValueId = '0tv000000000PAAAA';
        tier.options = new List<RLM_RampConfiguratorAction.ConfigPicklistOption>{
            entry, performance
        };
        if (withValue) {
            tier.value = 'Performance';
            tier.picklistValueId = performance.picklistValueId;
        }
        if (config.attributes == null) {
            config.attributes = new List<RLM_RampConfiguratorAction.ConfigAttribute>();
        }
        config.attributes.add(tier);
    }

    private static RLM_RampConfiguratorAction.ConfigResult sampleQRackConfig(Boolean dual) {
        RLM_RampConfiguratorAction.ConfigResult config =
            new RLM_RampConfiguratorAction.ConfigResult();
        config.success = true;
        config.transactionContextId = dual ? 'ctx-dual' : 'ctx-single';

        RLM_RampConfiguratorAction.ConfigComponent gold =
            new RLM_RampConfiguratorAction.ConfigComponent();
        gold.product2Id = '01t000000000GLDAAA';
        gold.name = 'Intel Xeon Gold 6330N 2.2GHz, 28C/56T';
        gold.sku = 'QB-CPU-G6330N';
        gold.selected = dual != true;
        gold.quantity = 1;

        RLM_RampConfiguratorAction.ConfigComponent platinum =
            new RLM_RampConfiguratorAction.ConfigComponent();
        platinum.product2Id = '01t000000000PLTAAA';
        platinum.name = 'Intel Xeon Platinum 8352M 2.3GHz, 32C/64T';
        platinum.sku = 'QB-CPU-P8352M';
        platinum.selected = dual == true;
        platinum.quantity = dual == true ? 2 : 1;

        RLM_RampConfiguratorAction.ConfigComponent air =
            new RLM_RampConfiguratorAction.ConfigComponent();
        air.product2Id = '01t000000000AIRAAA';
        air.name = 'CPU Heat Sink';
        air.selected = dual != true;
        air.quantity = 1;

        RLM_RampConfiguratorAction.ConfigComponent liquid =
            new RLM_RampConfiguratorAction.ConfigComponent();
        liquid.product2Id = '01t000000000LIQAAA';
        liquid.name = 'CPU liquid cooler';
        liquid.selected = dual == true;
        liquid.quantity = dual == true ? 2 : 1;

        RLM_RampConfiguratorAction.ConfigGroup cpu = new RLM_RampConfiguratorAction.ConfigGroup();
        cpu.name = 'CPU';
        cpu.components = new List<RLM_RampConfiguratorAction.ConfigComponent>{ gold, platinum };
        RLM_RampConfiguratorAction.ConfigGroup cooling = new RLM_RampConfiguratorAction.ConfigGroup();
        cooling.name = 'Cooling';
        cooling.components = new List<RLM_RampConfiguratorAction.ConfigComponent>{ air, liquid };
        config.groups = new List<RLM_RampConfiguratorAction.ConfigGroup>{ cpu, cooling };

        RLM_RampConfiguratorAction.ConfigAttribute socket =
            new RLM_RampConfiguratorAction.ConfigAttribute();
        socket.label = 'Socket Configuration';
        socket.attributeName = 'SocketConfiguration';
        socket.value = dual == true ? 'Dual' : 'Single';
        RLM_RampConfiguratorAction.ConfigAttribute workload =
            new RLM_RampConfiguratorAction.ConfigAttribute();
        workload.label = 'Workload';
        workload.attributeName = 'Workload';
        workload.value = dual == true ? 'High Performance Computing' : 'General';
        config.attributes = new List<RLM_RampConfiguratorAction.ConfigAttribute>{
            socket, workload
        };
        config.messages = new List<RLM_RampConfiguratorAction.ConfigMessage>();
        return config;
    }
}
