/**
 * Hosted MCP: describe ramp segments on a Draft, or patch yearly quantities
 * on existing ramped groups. Does not invent a new schedule from scratch.
 */
global with sharing class RLM_MCP_ApplyQuoteRamp {
    private static final Integer MAX_SEGMENTS = 8;

    global class RampInput {
        @InvocableVariable(
            required=true
            label='Quote Id'
            description='18-character Quote Id (starts with 0Q0).'
        )
        global String quoteId;

        @InvocableVariable(
            label='Product Name'
            description='Product to ramp, e.g. QuantumBit Database. Required when applying quantities.'
        )
        global String productName;

        @InvocableVariable(
            label='Segments JSON'
            description='Optional yearly qtys: [{"quantity":10},{"quantity":20},{"quantity":30}]. Omit to describe only.'
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
        description='Describes ramp segments on a Draft, or patches qty on existing ramped groups from segmentsJson. Never SObject-insert QuoteLineGroup. Never rebuild the quote.'
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
                SELECT Id, Name, StartDate, EndDate
                FROM Quote
                WHERE Id = :quoteId
                LIMIT 1
            ];
            out.quoteUrl = RLM_MCP_RecordLinks.lightningUrl('Quote', quote.Id);
            List<QuoteLineGroup> groups = [
                SELECT Id, Name, Type, IsRamped, SortOrder, StartDate, EndDate, SegmentType
                FROM QuoteLineGroup
                WHERE QuoteId = :quoteId
                AND Type != 'RampScheduleGroup'
                ORDER BY SortOrder ASC NULLS LAST
                LIMIT 20
            ];
            List<QuoteLineItem> lines = [
                SELECT Id, Quantity, QuoteLineGroupId, Product2.Name, Product2.StockKeepingUnit
                FROM QuoteLineItem
                WHERE QuoteId = :quoteId
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
                out.errorMessage =
                    'This quote has no ramp segments yet. Open Ramp Builder on the quote to create the schedule, then call this tool again with segmentsJson to set quantities.';
                return out;
            }
            if (String.isBlank(input.productName)) {
                out.errorMessage = 'Product name is required when applying segment quantities.';
                return out;
            }
            if (qtys.size() != ramped.size()) {
                out.errorMessage = 'segmentsJson has ' + String.valueOf(qtys.size())
                    + ' quantities but this quote has ' + String.valueOf(ramped.size())
                    + ' ramp segments. Match the count or describe first.';
                return out;
            }
            Map<Id, Decimal> qtyByLine = new Map<Id, Decimal>();
            List<String> recap = new List<String>{ 'Applied ramp quantities for ' + input.productName + ':' };
            Integer i = 0;
            for (QuoteLineGroup seg : ramped) {
                QuoteLineItem line = matchInGroup(input.productName, seg.Id, lines, out);
                if (line == null) {
                    return out;
                }
                qtyByLine.put(line.Id, qtys[i]);
                recap.add('- ' + nullToName(seg.Name)
                    + ' (' + day(seg.StartDate) + '–' + day(seg.EndDate) + '): qty '
                    + RLM_MCP_RecordLinks.formatNumber(qtys[i]));
                i++;
            }
            String persistError = persistQuantities(quoteId, qtyByLine);
            if (String.isNotBlank(persistError)) {
                out.errorMessage = persistError;
                return out;
            }
            String link = RLM_MCP_RecordLinks.markdown('Open Quote', 'Quote', quoteId);
            if (String.isNotBlank(link)) {
                recap.add(link);
            }
            out.isSuccess = true;
            out.resultsDisplay = String.join(recap, '\n');
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
            rows.add('No ramp segments. Use Ramp Builder to create 10/20/30 (or similar), then call this tool with segmentsJson.');
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

    private static QuoteLineItem matchInGroup(
        String productName,
        Id groupId,
        List<QuoteLineItem> lines,
        RampOutput out
    ) {
        String term = productName.trim().toLowerCase();
        List<QuoteLineItem> hits = new List<QuoteLineItem>();
        for (QuoteLineItem line : lines) {
            if (line.QuoteLineGroupId != groupId) {
                continue;
            }
            String name = line.Product2 == null || line.Product2.Name == null
                ? '' : line.Product2.Name.toLowerCase();
            String sku = line.Product2 == null || line.Product2.StockKeepingUnit == null
                ? '' : line.Product2.StockKeepingUnit.toLowerCase();
            if (name == term || sku == term || name.contains(term) || sku.contains(term)) {
                hits.add(line);
            }
        }
        if (hits.isEmpty()) {
            out.errorMessage = 'No "' + productName + '" line in that ramp segment.';
            return null;
        }
        if (hits.size() > 1) {
            out.needsDisambiguation = true;
            out.errorMessage = 'Multiple "' + productName + '" lines in one segment. Ask which.';
            return null;
        }
        return hits[0];
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
                SELECT Id, Quantity FROM QuoteLineItem WHERE Id IN :qtyByLine.keySet()
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

    private static String day(Date value) {
        return value == null ? '?' : String.valueOf(value);
    }

    private static String nullToName(String value) {
        return String.isBlank(value) ? 'Segment' : value;
    }
}
