@IsTest
private class RLM_BambooRevenueSuiteTest {
    private class CatalogFixture {
        Opportunity opp;
        Quote quote;
        String sku = 'BAMBOO-SUITE-TEST-CORE';
        Id pbeId;
    }

    private static CatalogFixture makeCatalogFixture() {
        Account a = new Account(Name = 'Suite Phase1 Co');
        insert a;
        Opportunity opp = new Opportunity(
            Name = 'Phase1 Opp',
            AccountId = a.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Pricebook2Id = Test.getStandardPricebookId()
        );
        insert opp;

        Product2 prod = new Product2(
            Name = 'BambooHR Suite Test Core',
            StockKeepingUnit = 'BAMBOO-SUITE-TEST-CORE',
            IsActive = true
        );
        insert prod;

        ProductSellingModel psm = new ProductSellingModel(
            Name = 'Term Monthly Suite Test',
            SellingModelType = 'TermDefined',
            PricingTermUnit = 'Months',
            PricingTerm = 1,
            Status = 'Active'
        );
        insert psm;
        insert new ProductSellingModelOption(
            Product2Id = prod.Id,
            ProductSellingModelId = psm.Id,
            IsDefault = true
        );

        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(),
            Product2Id = prod.Id,
            ProductSellingModelId = psm.Id,
            UnitPrice = 15,
            IsActive = true,
            CurrencyIsoCode = 'USD'
        );
        insert pbe;

        RLM_BambooRevenueSuite.SessionDTO session = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );

        CatalogFixture f = new CatalogFixture();
        f.opp = opp;
        f.quote = new Quote(Id = session.quoteId);
        f.pbeId = pbe.Id;
        f.sku = 'BAMBOO-SUITE-TEST-CORE';
        return f;
    }

    private static Opportunity makeOpp() {
        Account a = new Account(Name = 'Suite Phase0 Co');
        insert a;
        Opportunity opp = new Opportunity(
            Name = 'Canvera Expansion',
            AccountId = a.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Pricebook2Id = Test.getStandardPricebookId()
        );
        insert opp;
        return opp;
    }

    @IsTest
    static void openFromOpportunity_createsOptionA() {
        Opportunity opp = makeOpp();

        Test.startTest();
        RLM_BambooRevenueSuite.SessionDTO session = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );
        Test.stopTest();

        System.assertEquals(opp.Id, session.opportunityId);
        System.assertNotEquals(null, session.quoteId);
        System.assert(session.quoteName.contains('Option A'), session.quoteName);
        System.assertEquals('Option A', session.optionLabel);
    }

    @IsTest
    static void openFromOpportunity_reusesDraftOptionA() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO first = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );

        Test.startTest();
        RLM_BambooRevenueSuite.SessionDTO second = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );
        Test.stopTest();

        System.assertEquals(first.quoteId, second.quoteId);
        System.assertEquals(
            1,
            [SELECT COUNT() FROM Quote WHERE OpportunityId = :opp.Id]
        );
    }

    @IsTest
    static void getSession_returnsContext() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO created = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );

        Test.startTest();
        RLM_BambooRevenueSuite.SessionDTO session = RLM_BambooRevenueSuite.getSession(
            created.quoteId
        );
        Test.stopTest();

        System.assertEquals(created.quoteId, session.quoteId);
        System.assertEquals(opp.Id, session.opportunityId);
        System.assertEquals('Suite Phase0 Co', session.accountName);
    }

    @IsTest
    static void openFromOpportunity_rejectsBlank() {
        Boolean threw = false;
        try {
            RLM_BambooRevenueSuite.openFromOpportunity('');
        } catch (RLM_BambooRevenueSuite.SuiteException e) {
            threw = true;
            System.assert(e.getMessage().contains('required'), e.getMessage());
        }
        System.assert(threw, 'Expected SuiteException');
    }

    @IsTest(SeeAllData=true)
    static void getCatalog_returnsBambooProductsWhenPresent() {
        List<RLM_BambooRevenueSuite.CatalogProductDTO> catalog = RLM_BambooRevenueSuite.getCatalog(
            'USD'
        );
        if (catalog.isEmpty()) {
            // Scratch without bh-pcm/bh-pricing loaded — skip.
            return;
        }
        Boolean foundPlan = false;
        for (RLM_BambooRevenueSuite.CatalogProductDTO p : catalog) {
            if (p.sku == 'BAMBOO-CORE' || p.sku == 'BAMBOO-PRO') {
                foundPlan = true;
                System.assertNotEquals(null, p.listPrice);
                System.assertNotEquals(null, p.badge);
            }
        }
        System.assert(foundPlan, 'Expected a Bamboo plan SKU in catalog when data is present');
    }

    @IsTest(SeeAllData=true)
    static void addProductLine_createsQliWhenCatalogPresent() {
        List<RLM_BambooRevenueSuite.CatalogProductDTO> catalog = RLM_BambooRevenueSuite.getCatalog(
            'USD'
        );
        if (catalog.isEmpty()) {
            return;
        }
        String sku = null;
        for (RLM_BambooRevenueSuite.CatalogProductDTO p : catalog) {
            if (p.sku == 'BAMBOO-CORE') {
                sku = p.sku;
                break;
            }
        }
        if (sku == null) {
            sku = catalog[0].sku;
        }

        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );

        Test.startTest();
        RLM_BambooRevenueSuite.AddLineResultDTO result = RLM_BambooRevenueSuite.addProductLine(
            session.quoteId,
            sku,
            10,
            12,
            null,
            null
        );
        Test.stopTest();

        System.assertNotEquals(null, result.lineId);
        System.assert(result.option.lines.size() >= 1);
        System.assert(result.option.mrr > 0);
    }

    @IsTest(SeeAllData=true)
    static void addProductLines_createsMultipleWhenCatalogPresent() {
        List<RLM_BambooRevenueSuite.CatalogProductDTO> catalog = RLM_BambooRevenueSuite.getCatalog(
            'USD'
        );
        if (catalog.size() < 2) {
            return;
        }
        String skuA = null;
        String skuB = null;
        for (RLM_BambooRevenueSuite.CatalogProductDTO p : catalog) {
            if (p.sku == 'BAMBOO-ADD-PAYROLL') {
                skuA = p.sku;
            }
            if (p.sku == 'BAMBOO-ADD-BENEFITS') {
                skuB = p.sku;
            }
        }
        if (skuA == null || skuB == null) {
            skuA = catalog[0].sku;
            skuB = catalog[1].sku;
        }

        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );

        Test.startTest();
        RLM_BambooRevenueSuite.AddLineResultDTO result = RLM_BambooRevenueSuite.addProductLinesBySku(
            session.quoteId,
            new List<String>{ skuA, skuB },
            new List<Decimal>{ 10, 25 },
            12,
            '2026-06-01',
            'Monthly'
        );
        Test.stopTest();

        System.assertEquals(2, result.lineIds.size());
        System.assert(result.option.lines.size() >= 2);
        Map<String, Decimal> qtyBySku = new Map<String, Decimal>();
        for (RLM_BambooRevenueSuite.OptionLineDTO line : result.option.lines) {
            if (line.sku != null) {
                qtyBySku.put(line.sku, line.quantity);
            }
        }
        System.assertEquals(10, qtyBySku.get(skuA), 'First SKU should keep qty 10');
        System.assertEquals(25, qtyBySku.get(skuB), 'Second SKU should keep qty 25');
    }

    @IsTest
    static void addProductLines_rejectsEmpty() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );
        Boolean threw = false;
        try {
            RLM_BambooRevenueSuite.addProductLines(
                session.quoteId,
                new List<RLM_BambooRevenueSuite.LineInputDTO>(),
                12,
                null,
                null
            );
        } catch (RLM_BambooRevenueSuite.SuiteException e) {
            threw = true;
        }
        System.assert(threw, 'Empty lines should throw SuiteException');
    }

    @IsTest(SeeAllData=true)
    static void addWorkforcePackage_expandsWhenCatalogPresent() {
        List<RLM_BambooRevenueSuite.CatalogProductDTO> catalog = RLM_BambooRevenueSuite.getCatalog(
            'USD'
        );
        Boolean hasPkg = false;
        for (RLM_BambooRevenueSuite.CatalogProductDTO p : catalog) {
            if (p.sku == 'BAMBOO-PKG-WORKFORCE') {
                hasPkg = true;
                break;
            }
        }
        if (!hasPkg) {
            return;
        }

        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );

        Test.startTest();
        RLM_BambooRevenueSuite.AddLineResultDTO result = RLM_BambooRevenueSuite.addWorkforcePackage(
            session.quoteId,
            'BAMBOO-PRO',
            10,
            12,
            '2026-06-01',
            'Monthly'
        );
        Test.stopTest();

        System.assertNotEquals(null, result.lineId);
        System.assert(result.option.lines.size() >= 3, 'Expected package + children');
        Boolean sawPro = false;
        Boolean sawPkg = false;
        Boolean sawPayroll = false;
        Boolean sawBenefits = false;
        for (RLM_BambooRevenueSuite.OptionLineDTO line : result.option.lines) {
            if (line.sku == 'BAMBOO-PKG-WORKFORCE') {
                sawPkg = true;
            }
            if (line.sku == 'BAMBOO-PRO') {
                sawPro = true;
            }
            if (line.sku == 'BAMBOO-ADD-PAYROLL') {
                sawPayroll = true;
            }
            if (line.sku == 'BAMBOO-ADD-BENEFITS') {
                sawBenefits = true;
            }
        }
        System.assert(sawPkg, 'Missing package root');
        System.assert(sawPro, 'Missing Pro plan child (catalog default)');
        System.assert(sawPayroll, 'Missing Payroll child');
        System.assert(sawBenefits, 'Missing Benefits child');

        // Post-expand stamp must copy term dates onto children (not only the
        // package root). Without this, configurator defaults leave ~1-month
        // EndDate on components while the parent shows the deal term.
        for (RLM_BambooRevenueSuite.OptionLineDTO line : result.option.lines) {
            System.assertEquals(
                '2026-06-01',
                line.startDate,
                'Expected shared start on ' + line.sku
            );
            System.assertEquals(
                '2027-05-31',
                line.endDate,
                'Expected 12-month end on ' + line.sku
            );
        }

        Boolean threwCore = false;
        try {
            RLM_BambooRevenueSuite.addWorkforcePackage(
                session.quoteId,
                'BAMBOO-CORE',
                10,
                12,
                '2026-06-01',
                'Monthly'
            );
        } catch (RLM_BambooRevenueSuite.SuiteException e) {
            threwCore = true;
            System.assert(
                e.getMessage().contains('Pro'),
                'Core rejection should mention Pro default: ' + e.getMessage()
            );
        }
        System.assert(threwCore, 'Core under package should reject until configurator swap');
    }

    @IsTest(SeeAllData=true)
    static void previewProposal_startsWhenTemplatePresent() {
        List<DocumentTemplate> templates = [
            SELECT Id
            FROM DocumentTemplate
            WHERE Name = 'RLM_Bamboo_QuoteProposal' AND IsActive = TRUE
            LIMIT 1
        ];
        if (templates.isEmpty()) {
            return;
        }

        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );

        Test.startTest();
        RLM_BambooRevenueSuite.PreviewResultDTO started = RLM_BambooRevenueSuite.previewProposal(
            session.quoteId
        );
        Test.stopTest();

        System.assertNotEquals(null, started.processId);
        RLM_BambooRevenueSuite.PreviewResultDTO polled = RLM_BambooRevenueSuite.getProposalStatus(
            started.processId
        );
        System.assertNotEquals(null, polled.status);
    }

    @IsTest(SeeAllData=true)
    static void updateLineQuantity_repricesWhenCatalogPresent() {
        List<RLM_BambooRevenueSuite.CatalogProductDTO> catalog = RLM_BambooRevenueSuite.getCatalog(
            'USD'
        );
        if (catalog.isEmpty()) {
            return;
        }
        String sku = catalog[0].sku;
        for (RLM_BambooRevenueSuite.CatalogProductDTO p : catalog) {
            if (p.sku == 'BAMBOO-CORE') {
                sku = p.sku;
                break;
            }
        }

        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );
        RLM_BambooRevenueSuite.AddLineResultDTO added = RLM_BambooRevenueSuite.addProductLine(
            session.quoteId,
            sku,
            10,
            12,
            null,
            null
        );

        Test.startTest();
        RLM_BambooRevenueSuite.OptionDetailDTO updated = RLM_BambooRevenueSuite.updateLineQuantity(
            session.quoteId,
            added.lineId,
            25
        );
        Test.stopTest();

        System.assertEquals(1, updated.lines.size());
        System.assertEquals(25, updated.lines[0].quantity);
        System.assert(updated.mrr > 0);
    }

    @IsTest(SeeAllData=true)
    static void repriceOption_runsWhenLinesPresent() {
        List<RLM_BambooRevenueSuite.CatalogProductDTO> catalog = RLM_BambooRevenueSuite.getCatalog(
            'USD'
        );
        if (catalog.isEmpty()) {
            return;
        }

        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );
        RLM_BambooRevenueSuite.addProductLine(session.quoteId, catalog[0].sku, 10, 12, null, null);

        Test.startTest();
        RLM_BambooRevenueSuite.OptionDetailDTO priced = RLM_BambooRevenueSuite.repriceOption(
            session.quoteId
        );
        Test.stopTest();

        System.assert(priced.lines.size() >= 1);
        System.assert(priced.mrr > 0);
    }

    @IsTest(SeeAllData=true)
    static void removeLine_deletesWhenCatalogPresent() {
        List<RLM_BambooRevenueSuite.CatalogProductDTO> catalog = RLM_BambooRevenueSuite.getCatalog(
            'USD'
        );
        if (catalog.isEmpty()) {
            return;
        }
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );
        RLM_BambooRevenueSuite.AddLineResultDTO added = RLM_BambooRevenueSuite.addProductLine(
            session.quoteId,
            catalog[0].sku,
            5,
            12,
            null,
            null
        );

        Test.startTest();
        RLM_BambooRevenueSuite.OptionDetailDTO after = RLM_BambooRevenueSuite.removeLine(
            session.quoteId,
            added.lineId
        );
        Test.stopTest();

        System.assertEquals(0, after.lines.size());
    }

    @IsTest(SeeAllData=true)
    static void removeLines_bulkDeletesWhenCatalogPresent() {
        List<RLM_BambooRevenueSuite.CatalogProductDTO> catalog = RLM_BambooRevenueSuite.getCatalog(
            'USD'
        );
        if (catalog.size() < 2) {
            return;
        }
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );
        RLM_BambooRevenueSuite.AddLineResultDTO a = RLM_BambooRevenueSuite.addProductLine(
            session.quoteId,
            catalog[0].sku,
            5,
            12,
            null,
            null
        );
        RLM_BambooRevenueSuite.AddLineResultDTO b = RLM_BambooRevenueSuite.addProductLine(
            session.quoteId,
            catalog[1].sku,
            5,
            12,
            null,
            null
        );

        Test.startTest();
        RLM_BambooRevenueSuite.OptionDetailDTO after = RLM_BambooRevenueSuite.removeLines(
            session.quoteId,
            new List<String>{ a.lineId, b.lineId }
        );
        Test.stopTest();

        System.assertEquals(0, after.lines.size());
    }

    @IsTest(SeeAllData=true)
    static void updateLineDiscount_appliesWhenCatalogPresent() {
        List<RLM_BambooRevenueSuite.CatalogProductDTO> catalog = RLM_BambooRevenueSuite.getCatalog(
            'USD'
        );
        if (catalog.isEmpty()) {
            return;
        }
        String sku = catalog[0].sku;
        for (RLM_BambooRevenueSuite.CatalogProductDTO p : catalog) {
            if (p.sku == 'BAMBOO-CORE') {
                sku = p.sku;
                break;
            }
        }
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );
        RLM_BambooRevenueSuite.AddLineResultDTO added = RLM_BambooRevenueSuite.addProductLine(
            session.quoteId,
            sku,
            10,
            12,
            null,
            null
        );

        Test.startTest();
        RLM_BambooRevenueSuite.OptionDetailDTO updated = RLM_BambooRevenueSuite.updateLineDiscount(
            session.quoteId,
            added.lineId,
            10
        );
        Test.stopTest();

        System.assertEquals(1, updated.lines.size());
        System.assertEquals(10, updated.lines[0].discountPercent);
        System.assertNotEquals(null, updated.lines[0].startDate);
    }

    @IsTest(SeeAllData=true)
    static void applyTermToOption_restampsWhenCatalogPresent() {
        List<RLM_BambooRevenueSuite.CatalogProductDTO> catalog = RLM_BambooRevenueSuite.getCatalog(
            'USD'
        );
        if (catalog.isEmpty()) {
            return;
        }
        String sku = catalog[0].sku;
        for (RLM_BambooRevenueSuite.CatalogProductDTO p : catalog) {
            if (p.sku == 'BAMBOO-CORE') {
                sku = p.sku;
                break;
            }
        }
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );
        RLM_BambooRevenueSuite.addProductLine(session.quoteId, sku, 10, 12, null, null);

        Test.startTest();
        RLM_BambooRevenueSuite.OptionDetailDTO at24 = RLM_BambooRevenueSuite.applyTermToOption(
            session.quoteId,
            24,
            null,
            null
        );
        Test.stopTest();

        System.assertEquals(24, at24.termMonths);
        System.assertEquals(false, at24.evergreen);
        System.assert(at24.lines.size() >= 1);
        System.assertEquals(10, at24.lines[0].quantity);
    }

    @IsTest
    static void applyTermToOption_emptyQuoteNoops() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );

        Test.startTest();
        RLM_BambooRevenueSuite.OptionDetailDTO detail = RLM_BambooRevenueSuite.applyTermToOption(
            session.quoteId,
            36,
            null,
            null
        );
        Test.stopTest();

        System.assertEquals(0, detail.lines.size());
    }

    @IsTest
    static void applyTermToAllOptions_updatesEveryOption() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO a = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );
        RLM_BambooRevenueSuite.AddOptionResultDTO b = RLM_BambooRevenueSuite.addOption(opp.Id);

        Test.startTest();
        RLM_BambooRevenueSuite.OptionDetailDTO selectedA =
            RLM_BambooRevenueSuite.applyTermToAllOptions(
                opp.Id,
                a.quoteId,
                24,
                '2026-06-01',
                null
            );
        RLM_BambooRevenueSuite.OptionDetailDTO selectedB =
            RLM_BambooRevenueSuite.applyTermToAllOptions(
                opp.Id,
                b.created.quoteId,
                24,
                '2026-06-01',
                new List<String>{ b.created.quoteId }
            );
        Test.stopTest();

        System.assertEquals(24, selectedA.termMonths);
        System.assertEquals('2026-06-01', selectedA.startDate);
        System.assertEquals(24, selectedB.termMonths);
        System.assertEquals('2026-06-01', selectedB.startDate);
    }

    @IsTest
    static void applyBillingToAllOptions_preservesTerm() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO a = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );
        RLM_BambooRevenueSuite.AddOptionResultDTO b = RLM_BambooRevenueSuite.addOption(
            opp.Id
        );
        RLM_BambooRevenueSuite.applyTermToAllOptions(
            opp.Id,
            a.quoteId,
            24,
            '2026-06-01',
            null
        );

        Map<String, Integer> termByQuote = new Map<String, Integer>{
            a.quoteId => 24,
            b.created.quoteId => 24
        };
        Map<String, String> startByQuote = new Map<String, String>{
            a.quoteId => '2026-06-01',
            b.created.quoteId => '2026-06-01'
        };

        Test.startTest();
        RLM_BambooRevenueSuite.OptionDetailDTO detail =
            RLM_BambooRevenueSuite.applyBillingToAllOptions(
                opp.Id,
                a.quoteId,
                'Annual',
                termByQuote,
                startByQuote,
                null
            );
        Test.stopTest();

        System.assertEquals(24, detail.termMonths);
        System.assertEquals('2026-06-01', detail.startDate);
    }

    @IsTest
    static void applyBillingToAllOptions_respectsQuoteIdFilter() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO a = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );
        RLM_BambooRevenueSuite.AddOptionResultDTO b = RLM_BambooRevenueSuite.addOption(
            opp.Id
        );
        Map<String, Integer> termByQuote = new Map<String, Integer>{
            a.quoteId => 12,
            b.created.quoteId => 12
        };
        Map<String, String> startByQuote = new Map<String, String>{
            a.quoteId => '2026-06-01',
            b.created.quoteId => '2026-06-01'
        };

        Test.startTest();
        RLM_BambooRevenueSuite.OptionDetailDTO detail =
            RLM_BambooRevenueSuite.applyBillingToAllOptions(
                opp.Id,
                a.quoteId,
                'Quarterly',
                termByQuote,
                startByQuote,
                new List<String>{ a.quoteId }
            );
        Test.stopTest();

        System.assertEquals(a.quoteId, detail.quoteId);
        System.assertEquals(12, detail.termMonths);
    }

    @IsTest
    static void addOption_createsOptionB() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO a = RLM_BambooRevenueSuite.openFromOpportunity(opp.Id);

        Test.startTest();
        RLM_BambooRevenueSuite.AddOptionResultDTO result = RLM_BambooRevenueSuite.addOption(
            opp.Id
        );
        Test.stopTest();

        System.assertEquals('Option B', result.created.optionLabel);
        System.assertEquals(2, result.options.size());
        System.assertEquals(result.created.quoteId, result.session.quoteId);
        System.assertNotEquals(a.quoteId, result.created.quoteId);
        System.assert(
            result.created.quoteName.contains('Option B'),
            result.created.quoteName
        );
    }

    @IsTest
    static void deleteOption_removesWhenMultiple() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO a = RLM_BambooRevenueSuite.openFromOpportunity(opp.Id);
        RLM_BambooRevenueSuite.AddOptionResultDTO b = RLM_BambooRevenueSuite.addOption(opp.Id);

        Test.startTest();
        RLM_BambooRevenueSuite.AddOptionResultDTO after = RLM_BambooRevenueSuite.deleteOption(
            b.created.quoteId
        );
        Test.stopTest();

        System.assertEquals(1, after.options.size());
        System.assertEquals(a.quoteId, after.session.quoteId);
        System.assertEquals('Option A', after.options[0].optionLabel);
    }

    @IsTest
    static void deleteOption_rejectsLastOption() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO a = RLM_BambooRevenueSuite.openFromOpportunity(opp.Id);
        Boolean threw = false;
        try {
            RLM_BambooRevenueSuite.deleteOption(a.quoteId);
        } catch (RLM_BambooRevenueSuite.SuiteException e) {
            threw = true;
            System.assert(e.getMessage().contains('at least one'), e.getMessage());
        }
        System.assertEquals(true, threw);
    }

    @IsTest
    static void listOptions_marksSelected() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO a = RLM_BambooRevenueSuite.openFromOpportunity(opp.Id);
        RLM_BambooRevenueSuite.AddOptionResultDTO b = RLM_BambooRevenueSuite.addOption(opp.Id);

        Test.startTest();
        List<RLM_BambooRevenueSuite.OptionSummaryDTO> rows = RLM_BambooRevenueSuite.listOptions(
            opp.Id,
            a.quoteId
        );
        Test.stopTest();

        System.assertEquals(2, rows.size());
        System.assertEquals('Option A', rows[0].optionLabel);
        System.assertEquals(true, rows[0].selected);
        System.assertEquals('Option B', rows[1].optionLabel);
        System.assertEquals(false, rows[1].selected);
        System.assertEquals(b.created.quoteId, rows[1].quoteId);
    }

    @IsTest
    static void getOptionDetail_grandTotalDefaultsZeroOnEmptyQuote() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );

        Test.startTest();
        RLM_BambooRevenueSuite.OptionDetailDTO detail = RLM_BambooRevenueSuite.getOptionDetail(
            session.quoteId
        );
        List<RLM_BambooRevenueSuite.OptionSummaryDTO> rows = RLM_BambooRevenueSuite.listOptions(
            opp.Id,
            session.quoteId
        );
        Test.stopTest();

        System.assertEquals(0, detail.grandTotal);
        System.assertEquals(1, rows.size());
        System.assertEquals(detail.grandTotal, rows[0].grandTotal);
    }

    @IsTest(SeeAllData=true)
    static void getOptionDetail_grandTotalMatchesQuoteHeaderWhenPriced() {
        List<RLM_BambooRevenueSuite.CatalogProductDTO> catalog = RLM_BambooRevenueSuite.getCatalog(
            'USD'
        );
        if (catalog.isEmpty()) {
            return;
        }
        String sku = catalog[0].sku;

        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );

        Test.startTest();
        RLM_BambooRevenueSuite.AddLineResultDTO result = RLM_BambooRevenueSuite.addProductLine(
            session.quoteId,
            sku,
            10,
            12,
            null,
            null
        );
        List<RLM_BambooRevenueSuite.OptionSummaryDTO> rows = RLM_BambooRevenueSuite.listOptions(
            opp.Id,
            session.quoteId
        );
        Test.stopTest();

        Quote q = [
            SELECT GrandTotal, TotalPrice
            FROM Quote
            WHERE Id = :session.quoteId
            LIMIT 1
        ];
        Decimal expected = q.GrandTotal != null ? q.GrandTotal : q.TotalPrice;
        System.assertNotEquals(null, result.option.grandTotal);
        System.assertEquals(expected, result.option.grandTotal);
        System.assertEquals(result.option.grandTotal, rows[0].grandTotal);
    }

    @IsTest
    static void getQuotingAssistantBotId_runsWithoutError() {
        // May be null in orgs without the published agent; must not throw.
        String botId = RLM_BambooRevenueSuite.getQuotingAssistantBotId();
        System.assert(botId == null || botId.startsWith('0Xx'), botId);
    }

    @IsTest
    static void ensureGoodBetterBestOptions_createsABC() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.openFromOpportunity(opp.Id);

        Test.startTest();
        RLM_BambooRevenueSuite.TierOptionsResultDTO tiers = RLM_BambooRevenueSuite.ensureGoodBetterBestOptions(
            opp.Id
        );
        Test.stopTest();

        System.assertNotEquals(null, tiers.goodQuoteId);
        System.assertNotEquals(null, tiers.betterQuoteId);
        System.assertNotEquals(null, tiers.bestQuoteId);
        System.assertNotEquals(tiers.goodQuoteId, tiers.betterQuoteId);
        System.assertNotEquals(tiers.betterQuoteId, tiers.bestQuoteId);
        System.assertEquals(3, tiers.options.size());
    }

    @IsTest
    static void fillTierOption_rejectsUnknownTier() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );
        Boolean threw = false;
        try {
            RLM_BambooRevenueSuite.fillTierOption(
                session.quoteId,
                'Platinum',
                50,
                12,
                null,
                null
            );
        } catch (Exception e) {
            threw = true;
            System.assert(e.getMessage().contains('Unknown tier'), e.getMessage());
        }
        System.assert(threw, 'Unknown tier should throw');
    }

    @IsTest(SeeAllData=true)
    static void fillTierOption_goodWhenCatalogPresent() {
        List<RLM_BambooRevenueSuite.CatalogProductDTO> catalog = RLM_BambooRevenueSuite.getCatalog(
            'USD'
        );
        Boolean hasCore = false;
        for (RLM_BambooRevenueSuite.CatalogProductDTO p : catalog) {
            if (p.sku == 'BAMBOO-CORE') {
                hasCore = true;
                break;
            }
        }
        if (!hasCore) {
            return;
        }

        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.TierOptionsResultDTO tiers = RLM_BambooRevenueSuite.ensureGoodBetterBestOptions(
            opp.Id
        );

        Test.startTest();
        RLM_BambooRevenueSuite.OptionDetailDTO good = RLM_BambooRevenueSuite.fillTierOption(
            String.valueOf(tiers.goodQuoteId),
            'Good',
            50,
            12,
            String.valueOf(Date.today()),
            'Monthly'
        );
        Test.stopTest();

        System.assert(good.lines.size() >= 1, 'Good should have lines');
        System.assert(good.mrr >= 0);
    }

    @IsTest
    static void syncOptionToOpportunity_rejectsUnpriced() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );

        Boolean threw = false;
        try {
            Test.startTest();
            RLM_BambooRevenueSuite.syncOptionToOpportunity(session.quoteId);
            Test.stopTest();
        } catch (RLM_BambooRevenueSuite.SuiteException e) {
            threw = true;
            System.assert(
                e.getMessage().contains('Price the option'),
                e.getMessage()
            );
        }
        System.assert(threw, 'Expected SuiteException for unpriced option');
    }

    @IsTest
    static void listOptions_marksSyncedQuote() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );

        Database.SaveResult sr = Database.update(
            new Opportunity(Id = opp.Id, SyncedQuoteId = session.quoteId),
            false
        );
        if (!sr.isSuccess()) {
            // Some orgs reject SyncedQuoteId without priced lines — skip stamp assert.
            return;
        }

        Test.startTest();
        List<RLM_BambooRevenueSuite.OptionSummaryDTO> options = RLM_BambooRevenueSuite.listOptions(
            opp.Id,
            session.quoteId
        );
        Test.stopTest();

        System.assertEquals(1, options.size());
        System.assertEquals(true, options[0].syncedToOpportunity);
        System.assertEquals(
            session.quoteId,
            RLM_BambooRevenueSuite.getSession(session.quoteId).syncedQuoteId
        );
    }

    @IsTest
    static void unsyncOpportunity_clearsSyncedQuoteId() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );

        Database.SaveResult sr = Database.update(
            new Opportunity(Id = opp.Id, SyncedQuoteId = session.quoteId),
            false
        );
        if (!sr.isSuccess()) {
            return;
        }

        Test.startTest();
        RLM_BambooRevenueSuite.SyncOpportunityResultDTO result = RLM_BambooRevenueSuite.unsyncOpportunity(
            opp.Id
        );
        Test.stopTest();

        System.assertEquals(null, result.syncedQuoteId);
        Opportunity refreshed = [
            SELECT SyncedQuoteId
            FROM Opportunity
            WHERE Id = :opp.Id
        ];
        System.assertEquals(null, refreshed.SyncedQuoteId);
        System.assertEquals(false, result.options[0].syncedToOpportunity);
    }

    @IsTest(SeeAllData=true)
    static void syncOptionToOpportunity_setsSyncedQuoteIdWhenPriced() {
        List<RLM_BambooRevenueSuite.CatalogProductDTO> catalog = RLM_BambooRevenueSuite.getCatalog(
            'USD'
        );
        if (catalog.isEmpty()) {
            return;
        }
        String sku = null;
        for (RLM_BambooRevenueSuite.CatalogProductDTO p : catalog) {
            if (p.sku == 'BAMBOO-CORE') {
                sku = p.sku;
                break;
            }
        }
        if (sku == null) {
            sku = catalog[0].sku;
        }

        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );
        RLM_BambooRevenueSuite.AddLineResultDTO added = RLM_BambooRevenueSuite.addProductLine(
            session.quoteId,
            sku,
            10,
            12,
            null,
            null
        );
        if (added == null || added.option == null || added.option.priced != true) {
            return;
        }

        Test.startTest();
        RLM_BambooRevenueSuite.SyncOpportunityResultDTO result = RLM_BambooRevenueSuite.syncOptionToOpportunity(
            session.quoteId
        );
        Test.stopTest();

        System.assertEquals(session.quoteId, result.syncedQuoteId);
        System.assertEquals(true, result.options[0].syncedToOpportunity);
        Opportunity refreshed = [
            SELECT SyncedQuoteId
            FROM Opportunity
            WHERE Id = :opp.Id
        ];
        System.assertEquals(session.quoteId, refreshed.SyncedQuoteId);
    }

    @IsTest
    static void opportunitySyncRoundTrip_forPlaceGuard() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );

        Database.SaveResult sr = Database.update(
            new Opportunity(Id = opp.Id, SyncedQuoteId = session.quoteId),
            false
        );
        if (!sr.isSuccess()) {
            return;
        }

        Test.startTest();
        RLM_BambooRevenueSuite.unsyncOpportunity(opp.Id);
        RLM_BambooRevenueSuite.SyncOpportunityResultDTO restored =
            RLM_BambooRevenueSuite.syncOptionToOpportunity(session.quoteId);
        Test.stopTest();

        System.assertEquals(session.quoteId, restored.syncedQuoteId);
        Opportunity refreshed = [
            SELECT SyncedQuoteId
            FROM Opportunity
            WHERE Id = :opp.Id
        ];
        System.assertEquals(session.quoteId, refreshed.SyncedQuoteId);
    }

    @IsTest
    static void normalizeApprovalStatus_defaultsDraft() {
        System.assertEquals('Draft', RLM_BambooRevenueSuite.normalizeApprovalStatus(null));
        System.assertEquals('Pending', RLM_BambooRevenueSuite.normalizeApprovalStatus('pending'));
        System.assertEquals('Approved', RLM_BambooRevenueSuite.normalizeApprovalStatus('Approved'));
    }

    @IsTest
    static void submitOptionForApproval_requiresPricedLines() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );
        Boolean threw = false;
        try {
            RLM_BambooRevenueSuite.submitOptionForApproval(session.quoteId, 'test');
        } catch (RLM_BambooRevenueSuite.SuiteException e) {
            threw = true;
            System.assert(
                e.getMessage().contains('Price the option'),
                e.getMessage()
            );
        }
        System.assert(threw, 'Expected SuiteException for unpriced option');
    }

    @IsTest
    static void listOpportunityContacts_returnsAccountContacts() {
        Opportunity opp = makeOpp();
        Contact c = new Contact(
            LastName = 'SuiteSend',
            Email = 'suite.send@example.com',
            AccountId = opp.AccountId
        );
        insert c;

        Test.startTest();
        List<RLM_BambooRevenueSuite.ContactOptionDTO> rows =
            RLM_BambooRevenueSuite.listOpportunityContacts(opp.Id);
        Test.stopTest();

        System.assert(!rows.isEmpty(), 'Expected at least one contact');
        Boolean found = false;
        for (RLM_BambooRevenueSuite.ContactOptionDTO row : rows) {
            if (row.contactId == c.Id) {
                found = true;
                System.assertEquals('suite.send@example.com', row.email);
            }
        }
        System.assert(found, 'Inserted contact should be listed');
    }

    // Kept for local fixture experiments; not run against orgs that already have BAMBOO SKUs.
    @IsTest
    static void catalogFixture_helpersCompile() {
        System.assertNotEquals(null, makeOpp().Id);
    }
}
