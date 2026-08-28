/**
 * Ephemeral Salesforce headless pricing for BambooHR AE Revenue Suite catalog
 * estimates (Slice 6). Prices a cart without creating Quote lines — mirrors Get
 * Pricing pricing_api.headless_price_cart via runSalesforceHeadlessPricing.
 */
public with sharing class RLM_BambooHeadlessPricing {
    public class EstimateLineDTO {
        @AuraEnabled
        public String sku;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public Decimal quantity;
        @AuraEnabled
        public Decimal listUnitPrice;
        @AuraEnabled
        public Decimal netUnitPrice;
        @AuraEnabled
        public Decimal netTotal;
    }

    public class EstimateResultDTO {
        @AuraEnabled
        public Boolean ok;
        @AuraEnabled
        public String errorMessage;
        @AuraEnabled
        public String pricingSource;
        @AuraEnabled
        public Decimal mrr;
        @AuraEnabled
        public Decimal estimatedMonthlyTotal;
        @AuraEnabled
        public List<EstimateLineDTO> lines;
    }

    private static final String CONTEXT_DEF_NAME = 'RLM_SalesTransactionContext';
    private static final String MAPPING_TITLE = 'QuoteEntitiesMapping';
    private static final String PRICING_PROCEDURE = 'RLM_DefaultPricingProcedure';
    private static final Set<String> PATH_B_TARGETS = new Set<String>{
        'BAMBOO-ADD-PAYROLL',
        'BAMBOO-ADD-BENEFITS'
    };
    private static final Set<String> PLAN_SKUS = new Set<String>{
        'BAMBOO-CORE',
        'BAMBOO-PRO',
        'BAMBOO-ELITE'
    };

    @TestVisible
    private static Map<String, Object> mockHeadlessOutputs = null;

    /**
     * Headless estimate for catalog queue lines before Place add.
     * Falls back to list pricing when the platform action is unavailable.
     */
    public static EstimateResultDTO estimateLines(
        String currencyIsoCode,
        Integer termMonths,
        String startDateIso,
        List<RLM_BambooRevenueSuite.LineInputDTO> lines
    ) {
        EstimateResultDTO result = new EstimateResultDTO();
        result.ok = false;
        result.lines = new List<EstimateLineDTO>();
        result.pricingSource = 'localFallback';

        if (lines == null || lines.isEmpty()) {
            result.errorMessage = 'At least one catalog line is required.';
            return result;
        }

        String ccy = String.isBlank(currencyIsoCode) ? 'USD' : currencyIsoCode.trim();
        Integer months = termMonths == null || termMonths <= 0 ? 12 : termMonths;
        Date startDate = parseStartDate(startDateIso);
        Date endDate = computeEndDate(startDate, months);

        List<LineSpec> specs = buildSpecs(lines, ccy, months);
        if (specs.isEmpty()) {
            result.errorMessage = 'No valid catalog SKUs to estimate.';
            return result;
        }
        for (LineSpec spec : specs) {
            if (spec.sku == 'BAMBOO-PKG-WORKFORCE') {
                result.errorMessage =
                    'Workforce package pricing requires Add to option (configurator expand).';
                return result;
            }
        }

        Map<String, Decimal> netsBySku = new Map<String, Decimal>();
        try {
            netsBySku = invokeHeadlessPricing(ccy, startDate, endDate, specs);
            result.pricingSource = 'pricingApi';
            result.ok = true;
        } catch (Exception e) {
            result.pricingSource = 'localFallback';
            result.ok = true;
            for (LineSpec spec : specs) {
                netsBySku.put(spec.sku, spec.listUnit);
            }
        }

        Decimal mrr = 0;
        for (LineSpec spec : specs) {
            EstimateLineDTO row = new EstimateLineDTO();
            row.sku = spec.sku;
            row.name = spec.name;
            row.quantity = spec.quantity;
            row.listUnitPrice = spec.listUnit;
            Decimal netUnit = netsBySku.containsKey(spec.sku)
                ? netsBySku.get(spec.sku)
                : spec.listUnit;
            row.netUnitPrice = netUnit;
            row.netTotal = netUnit * spec.quantity;
            mrr += row.netTotal;
            result.lines.add(row);
        }
        result.mrr = mrr;
        result.estimatedMonthlyTotal = mrr;
        return result;
    }

    private class LineSpec {
        public String sku;
        public String name;
        public Decimal quantity;
        public Decimal listUnit;
        public Id product2Id;
        public Id productSellingModelId;
    }

    private static List<LineSpec> buildSpecs(
        List<RLM_BambooRevenueSuite.LineInputDTO> lines,
        String ccy,
        Integer months
    ) {
        List<LineSpec> specs = new List<LineSpec>();
        for (RLM_BambooRevenueSuite.LineInputDTO raw : lines) {
            if (raw == null || String.isBlank(raw.sku)) {
                continue;
            }
            Decimal qty = raw.quantity == null || raw.quantity <= 0 ? 1 : raw.quantity;
            PricebookEntry pbe = resolvePbe(raw.sku.trim(), ccy, months);
            LineSpec spec = new LineSpec();
            spec.sku = raw.sku.trim().toUpperCase();
            spec.name = pbe.Product2 != null ? pbe.Product2.Name : spec.sku;
            spec.quantity = qty;
            spec.listUnit = pbe.UnitPrice != null ? pbe.UnitPrice : 0;
            spec.product2Id = pbe.Product2Id;
            spec.productSellingModelId = pbe.ProductSellingModelId;
            specs.add(spec);
        }
        return specs;
    }

    private static Map<String, Decimal> invokeHeadlessPricing(
        String ccy,
        Date startDate,
        Date endDate,
        List<LineSpec> specs
    ) {
        ContextIds ctx = resolveContextIds();
        Id pricebookId = resolveStandardPricebookId();
        Boolean pathB = detectPathB(specs);

        String synthQuote = '0Q0EST' + EncodingUtil.convertToHex(Crypto.generateAesKey(128)).substring(0, 12);
        List<Object> items = new List<Object>();
        Integer i = 0;
        for (LineSpec spec : specs) {
            Map<String, Object> item = new Map<String, Object>{
                'businessObjectType' => 'QuoteLineItem',
                'id' => 'synth_' + spec.sku + '_' + String.valueOf(i),
                'Product' => String.valueOf(spec.product2Id),
                'ProductSellingModel' => String.valueOf(spec.productSellingModelId),
                'Quantity' => spec.quantity,
                'SalesTransactionItemSource' => 'LINE_ITEM' + String.valueOf(i + 1),
                'EffectiveFrom' => isoMidnight(startDate),
                'EffectiveTo' => isoMidnight(endDate)
            };
            if (PATH_B_TARGETS.contains(spec.sku)) {
                item.put('RLM_Bamboo_BundleSave_Target__c', true);
            }
            items.add(item);
            i++;
        }

        Map<String, Object> txn = new Map<String, Object>{
            'businessObjectType' => 'Quote',
            'id' => synthQuote,
            'Pricebook' => String.valueOf(pricebookId),
            'CurrencyIsoCode' => ccy,
            'RLM_Bamboo_PathB_BundleSave__c' => pathB,
            'SalesTransactionItem' => items
        };
        String pricingData = JSON.serialize(new Map<String, Object>{ 'SalesTransaction' => txn });

        Map<String, Object> outputs = invokeHeadlessAction(
            ctx.contextDefinitionId,
            ctx.contextMappingId,
            pricingData
        );
        return parseNetsFromOutputs(outputs, specs);
    }

    private static Map<String, Decimal> parseNetsFromOutputs(
        Map<String, Object> outputs,
        List<LineSpec> specs
    ) {
        if (outputs == null) {
            throw new PricingException('Headless pricing returned no output.');
        }
        Object statusObj = outputs.get('pricingProcessStatus');
        if (statusObj != null && String.valueOf(statusObj) != 'Completed') {
            throw new PricingException(
                'Headless pricing not completed: ' + String.valueOf(statusObj)
            );
        }
        Object resultObj = outputs.get('pricingResult');
        if (resultObj == null) {
            throw new PricingException('Headless pricing missing pricingResult.');
        }
        Map<String, Object> resultMap = (Map<String, Object>) JSON.deserializeUntyped(
            String.valueOf(resultObj)
        );
        List<Object> waterfall = (List<Object>) resultMap.get('PriceWaterFall');
        if (waterfall == null || waterfall.isEmpty()) {
            throw new PricingException('Headless pricing returned no waterfall rows.');
        }

        Map<Decimal, String> skuByList = new Map<Decimal, String>();
        for (LineSpec spec : specs) {
            skuByList.put(spec.listUnit.setScale(4), spec.sku);
        }

        Map<String, Decimal> nets = new Map<String, Decimal>();
        for (Object rowObj : waterfall) {
            Map<String, Object> row = (Map<String, Object>) rowObj;
            Object valueObj = row.get('value');
            Map<String, Object> wf = valueObj instanceof String
                ? (Map<String, Object>) JSON.deserializeUntyped((String) valueObj)
                : (Map<String, Object>) valueObj;
            Map<String, Object> output = (Map<String, Object>) wf.get('output');
            if (output == null) {
                continue;
            }
            Decimal listPrice = toDecimal(output.get('ListPrice'));
            Decimal netUnit = toDecimal(output.get('NetUnitPrice'));
            String sku = skuByList.get(listPrice.setScale(4));
            if (sku != null) {
                nets.put(sku, netUnit);
            }
        }
        if (nets.isEmpty()) {
            throw new PricingException('Could not match headless nets to catalog SKUs.');
        }
        return nets;
    }

    private static Map<String, Object> invokeHeadlessAction(
        Id contextDefinitionId,
        Id contextMappingId,
        String pricingData
    ) {
        if (Test.isRunningTest() && mockHeadlessOutputs != null) {
            return mockHeadlessOutputs;
        }
        Invocable.Action action = Invocable.Action.createStandardAction(
            'runSalesforceHeadlessPricing'
        );
        action.setInvocationParameter(
            'contextDefinitionId',
            String.valueOf(contextDefinitionId)
        );
        action.setInvocationParameter('contextMappingId', String.valueOf(contextMappingId));
        action.setInvocationParameter('pricingProcedureId', PRICING_PROCEDURE);
        action.setInvocationParameter('skipDiscovery', true);
        action.setInvocationParameter('displayContext', false);
        action.setInvocationParameter('isSkipWaterfall', false);
        action.setInvocationParameter('persistContext', false);
        action.setInvocationParameter('useSessionScopedContext', false);
        action.setInvocationParameter('taggedData', false);
        action.setInvocationParameter('pricingData', pricingData);

        List<Invocable.Action.Result> results = action.invoke();
        if (results.isEmpty()) {
            throw new PricingException('runSalesforceHeadlessPricing returned no result.');
        }
        Invocable.Action.Result res = results[0];
        if (!res.isSuccess()) {
            List<String> messages = new List<String>();
            for (Invocable.Action.Error err : res.getErrors()) {
                messages.add(err.getMessage());
            }
            throw new PricingException(String.join(messages, '; '));
        }
        return res.getOutputParameters();
    }

    private class ContextIds {
        public Id contextDefinitionId;
        public Id contextMappingId;
    }

    private static ContextIds resolveContextIds() {
        ContextIds ctx = new ContextIds();
        List<ContextDefinition> defs = [
            SELECT Id
            FROM ContextDefinition
            WHERE DeveloperName = :CONTEXT_DEF_NAME
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (defs.isEmpty()) {
            throw new PricingException('Context definition ' + CONTEXT_DEF_NAME + ' not found.');
        }
        ctx.contextDefinitionId = defs[0].Id;

        List<ContextMapping> mappings = [
            SELECT Id
            FROM ContextMapping
            WHERE Title = :MAPPING_TITLE AND IsDefault = TRUE
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (mappings.isEmpty()) {
            throw new PricingException('Context mapping ' + MAPPING_TITLE + ' not found.');
        }
        ctx.contextMappingId = mappings[0].Id;
        return ctx;
    }

    private static Id resolveStandardPricebookId() {
        List<Pricebook2> pbs = [
            SELECT Id
            FROM Pricebook2
            WHERE IsStandard = TRUE
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (pbs.isEmpty()) {
            throw new PricingException('Standard Price Book not found.');
        }
        return pbs[0].Id;
    }

    private static Boolean detectPathB(List<LineSpec> specs) {
        Boolean hasPlan = false;
        Boolean hasPayroll = false;
        Boolean hasBenefits = false;
        for (LineSpec spec : specs) {
            if (PLAN_SKUS.contains(spec.sku)) {
                hasPlan = true;
            }
            if (spec.sku == 'BAMBOO-ADD-PAYROLL') {
                hasPayroll = true;
            }
            if (spec.sku == 'BAMBOO-ADD-BENEFITS') {
                hasBenefits = true;
            }
        }
        return hasPlan && hasPayroll && hasBenefits;
    }

    private static PricebookEntry resolvePbe(String sku, String ccy, Integer termMonths) {
        String smt = termMonths != null && termMonths == 1 ? 'Evergreen' : 'TermDefined';
        List<PricebookEntry> rows = [
            SELECT
                Id,
                UnitPrice,
                ProductSellingModelId,
                Product2Id,
                Product2.Name,
                Product2.StockKeepingUnit
            FROM PricebookEntry
            WHERE
                Pricebook2.IsStandard = TRUE
                AND IsActive = TRUE
                AND Product2.IsActive = TRUE
                AND Product2.StockKeepingUnit = :sku
                AND CurrencyIsoCode = :ccy
                AND ProductSellingModel.PricingTermUnit = 'Months'
                AND ProductSellingModel.SellingModelType = :smt
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (rows.isEmpty() && smt == 'Evergreen') {
            rows = [
                SELECT
                    Id,
                    UnitPrice,
                    ProductSellingModelId,
                    Product2Id,
                    Product2.Name,
                    Product2.StockKeepingUnit
                FROM PricebookEntry
                WHERE
                    Pricebook2.IsStandard = TRUE
                    AND IsActive = TRUE
                    AND Product2.IsActive = TRUE
                    AND Product2.StockKeepingUnit = :sku
                    AND CurrencyIsoCode = :ccy
                    AND ProductSellingModel.PricingTermUnit = 'Months'
                    AND ProductSellingModel.SellingModelType = 'TermDefined'
                WITH SYSTEM_MODE
                LIMIT 1
            ];
        }
        if (rows.isEmpty()) {
            throw new PricingException(
                'No active Standard Price Book entry for ' + sku + ' (' + smt + ', ' + ccy + ').'
            );
        }
        return rows[0];
    }

    private static Date parseStartDate(String startDateIso) {
        if (String.isBlank(startDateIso)) {
            return Date.today();
        }
        return Date.valueOf(startDateIso.trim());
    }

    private static Date computeEndDate(Date startDate, Integer termMonths) {
        if (startDate == null) {
            return Date.today();
        }
        if (termMonths == null || termMonths == 1) {
            return startDate.addMonths(1).addDays(-1);
        }
        return startDate.addMonths(termMonths).addDays(-1);
    }

    private static String isoMidnight(Date d) {
        if (d == null) {
            d = Date.today();
        }
        return String.valueOf(d) + 'T00:00:00.000Z';
    }

    private static Decimal toDecimal(Object raw) {
        if (raw == null) {
            return 0;
        }
        if (raw instanceof Decimal) {
            return (Decimal) raw;
        }
        return Decimal.valueOf(String.valueOf(raw));
    }

    public class PricingException extends Exception {
    }
}
