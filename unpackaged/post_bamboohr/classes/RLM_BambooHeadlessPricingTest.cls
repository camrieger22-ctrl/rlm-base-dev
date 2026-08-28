@IsTest
private class RLM_BambooHeadlessPricingTest {
    @IsTest
    static void estimateLines_emptyInput() {
        RLM_BambooHeadlessPricing.EstimateResultDTO result =
            RLM_BambooHeadlessPricing.estimateLines('USD', 12, '2026-06-01', null);
        System.assertEquals(false, result.ok);
        System.assert(result.errorMessage.contains('At least one'));
    }

    @IsTest
    static void estimateLines_workforcePackageRejected() {
        RLM_BambooRevenueSuite.LineInputDTO line = new RLM_BambooRevenueSuite.LineInputDTO();
        line.sku = 'BAMBOO-PKG-WORKFORCE';
        line.quantity = 10;

        RLM_BambooHeadlessPricing.EstimateResultDTO result =
            RLM_BambooHeadlessPricing.estimateLines(
                'USD',
                12,
                '2026-06-01',
                new List<RLM_BambooRevenueSuite.LineInputDTO>{ line }
            );
        System.assertEquals(false, result.ok);
        System.assert(result.errorMessage.contains('Workforce package'));
    }

    @IsTest(SeeAllData=true)
    static void estimateLines_whenCatalogPresent() {
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

        RLM_BambooHeadlessPricing.mockHeadlessOutputs = buildMockOutputs(
            catalog,
            sku,
            8.5
        );

        RLM_BambooRevenueSuite.LineInputDTO line = new RLM_BambooRevenueSuite.LineInputDTO();
        line.sku = sku;
        line.quantity = 25;

        Test.startTest();
        RLM_BambooHeadlessPricing.EstimateResultDTO result =
            RLM_BambooHeadlessPricing.estimateLines(
                'USD',
                12,
                '2026-06-01',
                new List<RLM_BambooRevenueSuite.LineInputDTO>{ line }
            );
        Test.stopTest();

        System.assertEquals(true, result.ok, result.errorMessage);
        System.assertEquals('pricingApi', result.pricingSource);
        System.assertEquals(1, result.lines.size());
        System.assertEquals(25, result.lines[0].quantity);
        System.assertEquals(8.5, result.lines[0].netUnitPrice);
        System.assertEquals(212.5, result.lines[0].netTotal);
        System.assertEquals(212.5, result.mrr);
    }

    @IsTest(SeeAllData=true)
    static void estimateCatalogAdd_delegatesFromSuite() {
        List<RLM_BambooRevenueSuite.CatalogProductDTO> catalog = RLM_BambooRevenueSuite.getCatalog(
            'USD'
        );
        if (catalog.isEmpty()) {
            return;
        }
        RLM_BambooHeadlessPricing.mockHeadlessOutputs = buildMockOutputs(
            catalog,
            catalog[0].sku,
            10
        );

        RLM_BambooRevenueSuite.LineInputDTO line = new RLM_BambooRevenueSuite.LineInputDTO();
        line.sku = catalog[0].sku;
        line.quantity = 5;

        Test.startTest();
        RLM_BambooHeadlessPricing.EstimateResultDTO result =
            RLM_BambooRevenueSuite.estimateCatalogAdd(
                'USD',
                12,
                null,
                new List<RLM_BambooRevenueSuite.LineInputDTO>{ line }
            );
        Test.stopTest();

        System.assertEquals(true, result.ok);
        System.assertEquals(50, result.mrr);
    }

    private static Map<String, Object> buildMockOutputs(
        List<RLM_BambooRevenueSuite.CatalogProductDTO> catalog,
        String sku,
        Decimal netUnit
    ) {
        Decimal listUnit = 10;
        for (RLM_BambooRevenueSuite.CatalogProductDTO p : catalog) {
            if (p.sku == sku && p.listPrice != null) {
                listUnit = p.listPrice;
                break;
            }
        }
        Map<String, Object> output = new Map<String, Object>{
            'ListPrice' => listUnit,
            'NetUnitPrice' => netUnit
        };
        Map<String, Object> wf = new Map<String, Object>{ 'output' => output };
        Map<String, Object> row = new Map<String, Object>{ 'value' => wf };
        Map<String, Object> pricingResult = new Map<String, Object>{
            'PriceWaterFall' => new List<Object>{ row }
        };
        return new Map<String, Object>{
            'pricingProcessStatus' => 'Completed',
            'pricingResult' => JSON.serialize(pricingResult)
        };
    }
}
