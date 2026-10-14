/**
 * Hosted MCP: describe ramp segments on a Draft, add a product across
 * existing Create Ramp Schedule groups, or patch quantities. Does not
 * create the schedule (use RLM_MCP_CreateRampSchedule). Never Ramp
 * Builder. Never RLM_RampTransactionAction. Never SObject-insert
 * QuoteLineGroup.
 */
global with sharing class RLM_MCP_ApplyQuoteRamp {
    private static final Integer MAX_SEGMENTS = 12;

    global class RampInput {
        @InvocableVariable(
            required=true
            label='Quote Id'
            description='18-character Quote Id (starts with 0Q0).'
        )
        global String quoteId;

        @InvocableVariable(
            label='Product Name'
            description='Product to add or patch on existing ramp segments, e.g. QuantumBit Database.'
        )
        global String productName;

        @InvocableVariable(
            label='Segments JSON'
            description='Optional qtys: [{"quantity":10},{"quantity":20},{"quantity":30}]. Omit to describe only. Create the schedule first.'
        )
        global String segmentsJson;
    }

    global class RampOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(label='Quote Url')
        global String quoteUrl;
        @InvocableVariable(label='Results Display')
        global String resultsDisplay;
        @InvocableVariable(label='Needs Disambiguation')
        global Boolean needsDisambiguation;
        @InvocableVariable(label='Candidate Summaries Display')
        global String candidateSummariesDisplay;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(
        label='Apply Revenue Cloud Quote Ramp'
        description='Describes ramp segments, adds a product across an existing Create Ramp Schedule, or patches qty. Never creates the schedule. Never Ramp Builder. Never SObject-insert QuoteLineGroup.'
    )
    global static List<RampOutput> applyRamp(List<RampInput> inputs) {
        List<RampOutput> results = new List<RampOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (RampInput input : inputs) {
            results.add(applyOne(input));
        }
        return results;
    }

    private static RampOutput applyOne(RampInput input) {
        RampOutput out = new RampOutput();
        out.isSuccess = false;
        out.needsDisambiguation = false;
        try {
            if (input == null || String.isBlank(input.quoteId)) {
                out.errorMessage = 'Quote Id is required.';
                return out;
            }
            Id quoteId;
            try {
                quoteId = Id.valueOf(input.quoteId.trim());
            } catch (Exception e) {
                out.errorMessage = 'Invalid quote Id.';
                return out;
            }
            Quote quote = [
                SELECT Id, Name, StartDate, EndDate, Pricebook2Id
                FROM Quote
                WHERE Id = :quoteId
                WITH USER_MODE
                LIMIT 1
            ];
            out.quoteUrl = RLM_MCP_RecordLinks.lightningUrl('Quote', quote.Id);
            List<QuoteLineGroup> groups = [
                SELECT Id, Name, Type, IsRamped, SortOrder, StartDate, EndDate, SegmentType,
                       Discount
                FROM QuoteLineGroup
                WHERE QuoteId = :quoteId
                AND Type != 'RampScheduleGroup'
                WITH USER_MODE
                ORDER BY SortOrder ASC NULLS LAST
                LIMIT 20
            ];
            List<QuoteLineItem> lines = [
                SELECT Id, Quantity, QuoteLineGroupId, PricebookEntryId, Product2Id,
                       Product2.Name, Product2.StockKeepingUnit
                FROM QuoteLineItem
                WHERE QuoteId = :quoteId
                WITH USER_MODE
                LIMIT 200
            ];
            List<QuoteLineGroup> ramped = new List<QuoteLineGroup>();
            for (QuoteLineGroup grp : groups) {
                if (grp.IsRamped == true) {
                    ramped.add(grp);
                }
            }
            List<Decimal> qtys = parseSegments(input.segmentsJson, out);
            if (String.isNotBlank(out.errorMessage)) {
                return out;
            }
            if (qtys.isEmpty()) {
                out.isSuccess = true;
                out.resultsDisplay = describeRamp(quote, ramped, lines);
                return out;
            }
            if (ramped.isEmpty()) {
                out.errorMessage = 'No ramp schedule on this quote. Call createRevenueCloudRampSchedule first (preview, then confirm=true). Then call this tool with productName and segmentsJson. Never Ramp Builder.';
                return out;
            }
            if (String.isBlank(input.productName)) {
                out.errorMessage = 'Product name is required when applying segment quantities.';
                return out;
            }
            QtyPlan plan = planSegmentQuantities(ramped, qtys, out);
            if (plan == null) {
                return out;
            }
            return applyProductToSegments(
                out, quote, plan.targets, lines, input.productName, plan.qtys);
        } catch (Exception e) {
            out.isSuccess = false;
            out.errorMessage = e.getMessage() == null ? 'Ramp failed.' : e.getMessage();
        }
        return out;
    }

    private static String describeRamp(
        Quote quote,
        List<QuoteLineGroup> ramped,
        List<QuoteLineItem> lines
    ) {
        List<String> rows = new List<String>{ 'Ramp on ' + quote.Name };
        String link = RLM_MCP_RecordLinks.markdown('Open Quote', 'Quote', quote.Id);
        if (String.isNotBlank(link)) {
            rows.add(link);
        }
        if (ramped.isEmpty()) {
            rows.add('No ramp segments yet. Call createRevenueCloudRampSchedule to preview and create the empty schedule (Annual/Custom, trial, prorated). Then call this tool with productName and segmentsJson.');
            return String.join(rows, '\n');
        }
        rows.add(String.valueOf(ramped.size()) + ' ramp segments:');
        for (QuoteLineGroup seg : ramped) {
            rows.add('- ' + nullToName(seg.Name)
                + ' — ' + day(seg.StartDate) + ' to ' + day(seg.EndDate)
                + (String.isBlank(seg.SegmentType) ? '' : ' (' + seg.SegmentType + ')'));
            for (QuoteLineItem line : lines) {
                if (line.QuoteLineGroupId != seg.Id) {
                    continue;
                }
                String name = line.Product2 == null ? 'Line' : line.Product2.Name;
                rows.add('  · ' + name + ' qty ' + RLM_MCP_RecordLinks.formatNumber(line.Quantity));
            }
        }
        return String.join(rows, '\n');
    }

    @TestVisible
    class QtyPlan {
        public List<QuoteLineGroup> targets;
        public List<Decimal> qtys;
    }

    /**
     * Yearly qtys (10/20/30) also cover Trial (first year qty) and a
     * prorated stub (last year qty). A trial without the SKU is empty.
     */
    @TestVisible
    static QtyPlan planSegmentQuantities(
        List<QuoteLineGroup> ramped,
        List<Decimal> qtys,
        RampOutput out
    ) {
        QtyPlan plan = new QtyPlan();
        if (qtys.size() == ramped.size()) {
            plan.targets = ramped;
            plan.qtys = qtys;
            return plan;
        }
        List<QuoteLineGroup> paid = new List<QuoteLineGroup>();
        List<QuoteLineGroup> yearly = new List<QuoteLineGroup>();
        for (QuoteLineGroup seg : ramped) {
            if (seg.SegmentType != 'FreeTrial') {
                paid.add(seg);
            }
            if (seg.SegmentType == 'Yearly') {
                yearly.add(seg);
            }
        }
        if (qtys.size() == yearly.size()) {
            plan.targets = ramped;
            plan.qtys = expandFromYearly(ramped, qtys);
            return plan;
        }
        if (qtys.size() == paid.size()) {
            plan.targets = ramped;
            plan.qtys = expandFromPaid(ramped, qtys);
            return plan;
        }
        out.errorMessage = 'segmentsJson has ' + String.valueOf(qtys.size())
            + ' quantities but this quote has ' + String.valueOf(ramped.size())
            + ' ramp segments (' + String.valueOf(paid.size())
            + ' excluding trial, ' + String.valueOf(yearly.size())
            + ' yearly). Match one of those counts.';
        return null;
    }

    @TestVisible
    static List<Decimal> expandFromYearly(
        List<QuoteLineGroup> ramped,
        List<Decimal> yearlyQtys
    ) {
        List<Decimal> expanded = new List<Decimal>();
        Integer yearIndex = 0;
        Decimal first = yearlyQtys[0];
        Decimal last = yearlyQtys[yearlyQtys.size() - 1];
        for (QuoteLineGroup seg : ramped) {
            if (seg.SegmentType == 'Yearly') {
                expanded.add(yearlyQtys[yearIndex]);
                yearIndex++;
            } else if (seg.SegmentType == 'FreeTrial') {
                expanded.add(first);
            } else {
                expanded.add(last);
            }
        }
        return expanded;
    }

    private static List<Decimal> expandFromPaid(
        List<QuoteLineGroup> ramped,
        List<Decimal> paidQtys
    ) {
        List<Decimal> expanded = new List<Decimal>();
        Integer paidIndex = 0;
        Decimal first = paidQtys[0];
        for (QuoteLineGroup seg : ramped) {
            if (seg.SegmentType == 'FreeTrial') {
                expanded.add(first);
            } else {
                expanded.add(paidQtys[paidIndex]);
                paidIndex++;
            }
        }
        return expanded;
    }

    private static RampOutput applyProductToSegments(
        RampOutput out,
        Quote quote,
        List<QuoteLineGroup> targets,
        List<QuoteLineItem> lines,
        String productName,
        List<Decimal> qtys
    ) {
        Map<Id, QuoteLineItem> existingByGroup = new Map<Id, QuoteLineItem>();
        for (QuoteLineGroup seg : targets) {
            QuoteLineItem hit = matchInGroupQuiet(productName, seg.Id, lines);
            if (hit != null) {
                existingByGroup.put(seg.Id, hit);
            }
        }
        List<QuoteLineGroup> missing = new List<QuoteLineGroup>();
        List<Decimal> missingQtys = new List<Decimal>();
        Map<Id, Decimal> qtyByLine = new Map<Id, Decimal>();
        List<String> recap = new List<String>{
            'Applied ramp quantities for ' + productName + ':'
        };
        Integer i = 0;
        for (QuoteLineGroup seg : targets) {
            QuoteLineItem line = existingByGroup.get(seg.Id);
            if (line == null) {
                missing.add(seg);
                missingQtys.add(qtys[i]);
            } else {
                qtyByLine.put(line.Id, qtys[i]);
            }
            recap.add('- ' + nullToName(seg.Name)
                + ' (' + day(seg.StartDate) + '–' + day(seg.EndDate) + '): qty '
                + RLM_MCP_RecordLinks.formatNumber(qtys[i]));
            i++;
        }
        if (!missing.isEmpty()) {
            PricebookEntry pbe = resolvePricebookEntry(quote, productName, lines, out);
            if (pbe == null) {
                return out;
            }
            String addError = addProducts(quote.Id, pbe, missing, missingQtys);
            if (String.isNotBlank(addError)) {
                out.errorMessage = addError;
                return out;
            }
        }
        if (!qtyByLine.isEmpty()) {
            String persistError = persistQuantities(quote.Id, qtyByLine);
            if (String.isNotBlank(persistError)) {
                out.errorMessage = persistError;
                return out;
            }
        }
        String link = RLM_MCP_RecordLinks.markdown('Open Quote', 'Quote', quote.Id);
        if (String.isNotBlank(link)) {
            recap.add(link);
        }
        out.isSuccess = true;
        out.resultsDisplay = String.join(recap, '\n');
        return out;
    }

    private static QuoteLineItem matchInGroupQuiet(
        String productName,
        Id groupId,
        List<QuoteLineItem> lines
    ) {
        String term = productName.trim().toLowerCase();
        for (QuoteLineItem line : lines) {
            if (line.QuoteLineGroupId != groupId) {
                continue;
            }
            if (nameOrSkuMatches(line, term)) {
                return line;
            }
        }
        return null;
    }

    private static Boolean nameOrSkuMatches(QuoteLineItem line, String term) {
        String name = line.Product2 == null || line.Product2.Name == null
            ? '' : line.Product2.Name.toLowerCase();
        String sku = line.Product2 == null || line.Product2.StockKeepingUnit == null
            ? '' : line.Product2.StockKeepingUnit.toLowerCase();
        return name == term || sku == term || name.contains(term) || sku.contains(term);
    }

    private static PricebookEntry resolvePricebookEntry(
        Quote quote,
        String productName,
        List<QuoteLineItem> lines,
        RampOutput out
    ) {
        String term = productName.trim().toLowerCase();
        for (QuoteLineItem line : lines) {
            if (line.PricebookEntryId != null && nameOrSkuMatches(line, term)) {
                List<PricebookEntry> fromLine = [
                    SELECT Id, Product2Id, UnitPrice,
                           ProductSellingModel.SellingModelType,
                           ProductSellingModel.PricingTermUnit
                    FROM PricebookEntry
                    WHERE Id = :line.PricebookEntryId
                    WITH USER_MODE
                    LIMIT 1
                ];
                if (!fromLine.isEmpty()) {
                    return fromLine[0];
                }
            }
        }
        List<PricebookEntry> candidates = [
            SELECT Id, Product2Id, UnitPrice, Product2.Name, Product2.StockKeepingUnit,
                   ProductSellingModel.SellingModelType,
                   ProductSellingModel.PricingTermUnit
            FROM PricebookEntry
            WHERE Pricebook2Id = :quote.Pricebook2Id
            AND IsActive = true
            WITH USER_MODE
            LIMIT 200
        ];
        List<PricebookEntry> exact = new List<PricebookEntry>();
        List<PricebookEntry> partial = new List<PricebookEntry>();
        for (PricebookEntry pbe : candidates) {
            String name = pbe.Product2 == null || pbe.Product2.Name == null
                ? '' : pbe.Product2.Name.toLowerCase();
            String sku = pbe.Product2 == null || pbe.Product2.StockKeepingUnit == null
                ? '' : pbe.Product2.StockKeepingUnit.toLowerCase();
            if (name == term || sku == term) {
                exact.add(pbe);
            } else if (name.contains(term) || sku.contains(term)) {
                partial.add(pbe);
            }
        }
        List<PricebookEntry> hits = exact.isEmpty() ? partial : exact;
        if (hits.isEmpty()) {
            out.errorMessage = 'No "' + productName + '" selling model in this quote price book.';
            return null;
        }
        PricebookEntry chosen = preferSellingModel(hits);
        if (chosen != null) {
            return chosen;
        }
        Set<Id> productIds = new Set<Id>();
        for (PricebookEntry pbe : hits) {
            productIds.add(pbe.Product2Id);
        }
        if (productIds.size() > 1) {
            out.needsDisambiguation = true;
            out.errorMessage = 'Multiple "' + productName + '" products. Ask which.';
            return null;
        }
        return hits[0];
    }

    private static PricebookEntry preferSellingModel(List<PricebookEntry> hits) {
        if (hits.size() == 1) {
            return hits[0];
        }
        Set<Id> productIds = new Set<Id>();
        for (PricebookEntry pbe : hits) {
            productIds.add(pbe.Product2Id);
        }
        if (productIds.size() != 1) {
            return null;
        }
        for (PricebookEntry pbe : hits) {
            String model = pbe.ProductSellingModel == null
                ? '' : String.valueOf(pbe.ProductSellingModel.SellingModelType);
            String term = pbe.ProductSellingModel == null
                ? '' : String.valueOf(pbe.ProductSellingModel.PricingTermUnit);
            if (model == 'TermDefined' && term == 'Annual') {
                return pbe;
            }
        }
        for (PricebookEntry pbe : hits) {
            String model = pbe.ProductSellingModel == null
                ? '' : String.valueOf(pbe.ProductSellingModel.SellingModelType);
            if (model == 'TermDefined') {
                return pbe;
            }
        }
        return hits[0];
    }

    private static String addProducts(
        Id quoteId,
        PricebookEntry pbe,
        List<QuoteLineGroup> segments,
        List<Decimal> qtys
    ) {
        if (Test.isRunningTest()) {
            List<QuoteLineItem> rows = new List<QuoteLineItem>();
            String rampId = newRampId();
            Integer i = 0;
            for (QuoteLineGroup seg : segments) {
                QuoteLineItem row = new QuoteLineItem(
                    QuoteId = quoteId,
                    QuoteLineGroupId = seg.Id,
                    PricebookEntryId = pbe.Id,
                    Product2Id = pbe.Product2Id,
                    Quantity = qtys[i],
                    UnitPrice = pbe.UnitPrice == null ? 0 : pbe.UnitPrice,
                    RampIdentifier = rampId,
                    SegmentIdentifier = newSegId()
                );
                if (seg.Discount != null) {
                    row.Discount = seg.Discount;
                }
                rows.add(row);
                i++;
            }
            try {
                insert rows;
            } catch (Exception e) {
                return e.getMessage();
            }
            return null;
        }
        List<RevSalesTrxn.RecordWithReferenceRequest> records =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        RevSalesTrxn.RecordResource header = new RevSalesTrxn.RecordResource(
            Quote.getSObjectType(), 'PATCH', quoteId
        );
        header.fieldValues = new Map<String, Object>{ 'Status' => 'Draft' };
        records.add(new RevSalesTrxn.RecordWithReferenceRequest('refRampQuote', header));
        String rampId = newRampId();
        String sellingModelType = pbe.ProductSellingModel == null
            ? null : String.valueOf(pbe.ProductSellingModel.SellingModelType);
        String term = pbe.ProductSellingModel == null
            ? null : String.valueOf(pbe.ProductSellingModel.PricingTermUnit);
        String frequency = term == 'Months' ? 'Monthly'
            : (term == 'Annual' ? 'Annual' : null);
        Integer i = 0;
        for (QuoteLineGroup seg : segments) {
            RevSalesTrxn.RecordResource groupRec = new RevSalesTrxn.RecordResource(
                QuoteLineGroup.getSObjectType(), 'PATCH', seg.Id
            );
            groupRec.fieldValues = new Map<String, Object>();
            records.add(new RevSalesTrxn.RecordWithReferenceRequest(
                'refGrp' + String.valueOf(i), groupRec));
            RevSalesTrxn.RecordResource line = new RevSalesTrxn.RecordResource(
                QuoteLineItem.getSObjectType(), 'POST'
            );
            Map<String, Object> fields = new Map<String, Object>{
                'QuoteId' => quoteId,
                'QuoteLineGroupId' => seg.Id,
                'Product2Id' => pbe.Product2Id,
                'PricebookEntryId' => pbe.Id,
                'Quantity' => qtys[i],
                'UnitPrice' => pbe.UnitPrice == null ? 0 : pbe.UnitPrice,
                'RampIdentifier' => rampId,
                'SegmentIdentifier' => newSegId()
            };
            if (seg.Discount != null) {
                fields.put('Discount', seg.Discount);
            }
            if (sellingModelType == 'TermDefined' && String.isNotBlank(frequency)) {
                fields.put('StartDate', iso(seg.StartDate));
                fields.put('EndDate', iso(seg.EndDate));
                fields.put('PeriodBoundary', 'Anniversary');
                fields.put('BillingFrequency', frequency);
            }
            line.fieldValues = fields;
            records.add(new RevSalesTrxn.RecordWithReferenceRequest(
                'refLine' + String.valueOf(i), line));
            i++;
        }
        RevSalesTrxn.ConfigurationOptionsInput options =
            new RevSalesTrxn.ConfigurationOptionsInput();
        options.executeConfigurationRules = false;
        options.validateProductCatalog = false;
        options.validateAmendRenewCancel = false;
        options.addDefaultConfiguration = false;
        RevSalesTrxn.GraphRequest graph = new RevSalesTrxn.GraphRequest(
            'McpRampAddProducts', records);
        RevSalesTrxn.PlaceSalesTransactionResponse resp =
            RevSalesTrxn.PlaceSalesTransactionExecutor.execute(
                graph,
                RevSalesTrxn.PricingPreferenceEnum.SYSTEM,
                RevSalesTrxn.ConfigurationExecutionEnum.SKIP,
                options,
                null,
                RevSalesTrxn.TaxPreferenceEnum.Skip,
                null,
                RevSalesTrxn.GroupRampActionEnum.AddProducts
            );
        if (resp != null && resp.isSuccess) {
            return null;
        }
        return resp == null || resp.errorResponse == null
            ? 'Could not add the product to ramp segments.'
            : String.valueOf(resp.errorResponse);
    }

    private static List<Decimal> parseSegments(String raw, RampOutput out) {
        List<Decimal> qtys = new List<Decimal>();
        if (String.isBlank(raw)) {
            return qtys;
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(raw);
        } catch (Exception e) {
            out.errorMessage = 'segmentsJson is not valid JSON. Pass [{"quantity":10},{"quantity":20}].';
            return qtys;
        }
        if (!(parsed instanceof List<Object>)) {
            out.errorMessage = 'segmentsJson must be a JSON array.';
            return qtys;
        }
        for (Object item : (List<Object>) parsed) {
            if (qtys.size() >= MAX_SEGMENTS) {
                break;
            }
            if (item instanceof Decimal || item instanceof Integer || item instanceof Long) {
                qtys.add(Decimal.valueOf(String.valueOf(item)));
                continue;
            }
            if (!(item instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> row = (Map<String, Object>) item;
            Object qty = row.containsKey('quantity') ? row.get('quantity') : row.get('qty');
            if (qty == null) {
                continue;
            }
            try {
                Decimal value = Decimal.valueOf(String.valueOf(qty).trim());
                if (value <= 0) {
                    out.errorMessage = 'Each segment quantity must be greater than 0.';
                    return new List<Decimal>();
                }
                qtys.add(value);
            } catch (Exception e) {
                out.errorMessage = 'segmentsJson quantities must be numbers.';
                return new List<Decimal>();
            }
        }
        if (qtys.isEmpty()) {
            out.errorMessage = 'segmentsJson had no quantities.';
        }
        return qtys;
    }

    private static String persistQuantities(Id quoteId, Map<Id, Decimal> qtyByLine) {
        if (Test.isRunningTest()) {
            List<QuoteLineItem> lines = [
                SELECT Id, Quantity
                FROM QuoteLineItem
                WHERE Id IN :qtyByLine.keySet()
                WITH USER_MODE
            ];
            for (QuoteLineItem line : lines) {
                line.Quantity = qtyByLine.get(line.Id);
            }
            try {
                update lines;
            } catch (Exception e) {
                return e.getMessage();
            }
            return null;
        }
        List<RevSalesTrxn.RecordWithReferenceRequest> records =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        RevSalesTrxn.RecordResource header = new RevSalesTrxn.RecordResource(
            Quote.getSObjectType(), 'PATCH', quoteId
        );
        header.fieldValues = new Map<String, Object>{ 'Status' => 'Draft' };
        records.add(new RevSalesTrxn.RecordWithReferenceRequest('refRampQuote', header));
        Integer n = 0;
        for (Id lineId : qtyByLine.keySet()) {
            n++;
            RevSalesTrxn.RecordResource line = new RevSalesTrxn.RecordResource(
                QuoteLineItem.getSObjectType(), 'PATCH', lineId
            );
            line.fieldValues = new Map<String, Object>{ 'Quantity' => qtyByLine.get(lineId) };
            records.add(new RevSalesTrxn.RecordWithReferenceRequest('refRampLine' + n, line));
        }
        RevSalesTrxn.ConfigurationOptionsInput options =
            new RevSalesTrxn.ConfigurationOptionsInput();
        options.executeConfigurationRules = false;
        options.validateProductCatalog = false;
        options.validateAmendRenewCancel = false;
        options.addDefaultConfiguration = false;
        RevSalesTrxn.GraphRequest graph = new RevSalesTrxn.GraphRequest('McpRampQty', records);
        RevSalesTrxn.PlaceSalesTransactionResponse resp =
            RevSalesTrxn.PlaceSalesTransactionExecutor.execute(
                graph,
                RevSalesTrxn.PricingPreferenceEnum.SYSTEM,
                RevSalesTrxn.ConfigurationExecutionEnum.SKIP,
                options,
                null
            );
        if (resp != null && resp.isSuccess) {
            return null;
        }
        return resp == null || resp.errorResponse == null
            ? 'Could not apply ramp quantities.'
            : String.valueOf(resp.errorResponse);
    }

    private static String newRampId() {
        return 'RDI' + String.valueOf(Crypto.getRandomInteger()).replace('-', '').left(12);
    }

    private static String newSegId() {
        return 'SEG' + String.valueOf(Crypto.getRandomInteger()).replace('-', '').left(12);
    }

    private static String iso(Date value) {
        return value == null ? null : String.valueOf(value) + 'T00:00:00.000Z';
    }

    private static String day(Date value) {
        return value == null ? '?' : String.valueOf(value);
    }

    private static String nullToName(String value) {
        return String.isBlank(value) ? 'Segment' : value;
    }
}
