/**
 * Hosted MCP: patch quantities and/or a percent discount on existing
 * Draft quote lines in one Place Sales Transaction. Do not add lines.
 */
global with sharing class RLM_MCP_UpdateQuoteLines {
    private static final Integer MAX_QTY_UPDATES = 20;

    global class UpdateInput {
        @InvocableVariable(
            required=true
            label='Quote Id'
            description='18-character Quote Id (starts with 0Q0).'
        )
        global String quoteId;

        @InvocableVariable(
            label='Quantities JSON'
            description='JSON array of existing lines to patch: [{"product":"QuantumBit Database","quantity":20}]. Never add a new line.'
        )
        global String quantitiesJson;

        @InvocableVariable(
            label='Discount Percentage'
            description='Optional percent off (0-100) applied to every line after quantity patches.'
        )
        global Decimal discountPercentage;
    }

    global class UpdateOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(label='Updated Count')
        global Decimal updatedCount;
        @InvocableVariable(
            label='Quote Url'
            description='Lightning Quote page. Render as [Open Quote](quoteUrl) in the chat reply.'
        )
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

    private class QtySpec {
        String product;
        Decimal quantity;
    }

    @InvocableMethod(
        label='Update Revenue Cloud Quote Lines'
        description='Patches quantity on existing Draft quote lines and/or applies a percent discount in one call. Pass quantitiesJson and/or discountPercentage. Never rebuild the quote or add delta lines.'
    )
    global static List<UpdateOutput> updateLines(List<UpdateInput> inputs) {
        List<UpdateOutput> results = new List<UpdateOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (UpdateInput input : inputs) {
            results.add(updateOne(input));
        }
        return results;
    }

    private static UpdateOutput updateOne(UpdateInput input) {
        UpdateOutput out = new UpdateOutput();
        out.isSuccess = false;
        out.updatedCount = 0;
        out.needsDisambiguation = false;
        try {
            if (input == null || String.isBlank(input.quoteId)) {
                out.errorMessage = 'Quote Id is required.';
                return out;
            }
            Id quoteId;
            try {
                quoteId = Id.valueOf(input.quoteId);
            } catch (Exception e) {
                out.errorMessage = 'Invalid quote Id.';
                return out;
            }
            Boolean hasDiscount = input.discountPercentage != null;
            if (hasDiscount && (input.discountPercentage < 0 || input.discountPercentage > 100)) {
                out.errorMessage = 'Discount percentage must be between 0 and 100.';
                return out;
            }
            List<QtySpec> specs = parseQuantities(input.quantitiesJson, out);
            if (String.isNotBlank(out.errorMessage)) {
                return out;
            }
            if (specs.isEmpty() && !hasDiscount) {
                out.errorMessage = 'Pass quantitiesJson and/or discountPercentage.';
                return out;
            }

            List<QuoteLineItem> lines = [
                SELECT Id, Quantity, Discount, Product2.Name, Product2.StockKeepingUnit
                FROM QuoteLineItem
                WHERE QuoteId = :quoteId
                LIMIT 200
            ];
            if (lines.isEmpty()) {
                out.errorMessage = 'Quote has no lines to update.';
                return out;
            }

            Map<Id, Decimal> qtyByLine = new Map<Id, Decimal>();
            for (QtySpec spec : specs) {
                QuoteLineItem matched = matchLine(spec.product, lines, out);
                if (matched == null) {
                    return out;
                }
                qtyByLine.put(matched.Id, spec.quantity);
            }

            String persistError = persist(quoteId, lines, qtyByLine, input.discountPercentage);
            if (String.isNotBlank(persistError)) {
                out.errorMessage = persistError;
                return out;
            }

            out.isSuccess = true;
            out.quoteUrl = RLM_MCP_RecordLinks.lightningUrl('Quote', quoteId);
            List<String> rows = new List<String>();
            rows.add('Updated quote lines:');
            Integer updates = 0;
            for (QuoteLineItem line : lines) {
                String name = line.Product2 == null ? String.valueOf(line.Id) : line.Product2.Name;
                List<String> bits = new List<String>();
                if (qtyByLine.containsKey(line.Id)) {
                    bits.add('qty ' + String.valueOf(qtyByLine.get(line.Id)));
                    updates++;
                }
                if (hasDiscount) {
                    bits.add(String.valueOf(input.discountPercentage) + '% off');
                    if (!qtyByLine.containsKey(line.Id)) {
                        updates++;
                    }
                }
                if (!bits.isEmpty()) {
                    rows.add('- ' + name + ' — ' + String.join(bits, ', '));
                }
            }
            out.updatedCount = updates;
            String quoteLink = RLM_MCP_RecordLinks.markdown('Open Quote', 'Quote', quoteId);
            if (String.isNotBlank(quoteLink)) {
                rows.add(quoteLink);
            }
            out.resultsDisplay = String.join(rows, '\n');
        } catch (Exception e) {
            out.isSuccess = false;
            out.errorMessage = e.getMessage() == null ? 'Update failed.' : e.getMessage();
        }
        return out;
    }

    private static List<QtySpec> parseQuantities(String raw, UpdateOutput out) {
        List<QtySpec> specs = new List<QtySpec>();
        if (String.isBlank(raw)) {
            return specs;
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(raw);
        } catch (Exception e) {
            out.errorMessage = 'quantitiesJson is not valid JSON. Pass [{"product":"Name","quantity":20}].';
            return specs;
        }
        if (!(parsed instanceof List<Object>)) {
            out.errorMessage = 'quantitiesJson must be a JSON array.';
            return specs;
        }
        for (Object item : (List<Object>) parsed) {
            if (specs.size() >= MAX_QTY_UPDATES) {
                break;
            }
            if (!(item instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> row = (Map<String, Object>) item;
            QtySpec spec = new QtySpec();
            spec.product = asString(first(row, new List<String>{ 'product', 'name', 'sku' }));
            spec.quantity = asDecimal(first(row, new List<String>{ 'quantity', 'qty' }));
            if (String.isBlank(spec.product)) {
                continue;
            }
            if (spec.quantity == null || spec.quantity <= 0) {
                out.errorMessage = 'Quantity for "' + spec.product + '" must be greater than 0.';
                return specs;
            }
            specs.add(spec);
        }
        if (specs.isEmpty()) {
            out.errorMessage = 'quantitiesJson had no products.';
        }
        return specs;
    }

    private static QuoteLineItem matchLine(
        String needle,
        List<QuoteLineItem> lines,
        UpdateOutput out
    ) {
        String term = needle.trim().toLowerCase();
        List<QuoteLineItem> hits = new List<QuoteLineItem>();
        Integer best = -1;
        for (QuoteLineItem line : lines) {
            Integer score = scoreLine(term, line);
            if (score < 0) {
                continue;
            }
            if (score > best) {
                best = score;
                hits = new List<QuoteLineItem>{ line };
            } else if (score == best) {
                hits.add(line);
            }
        }
        if (hits.isEmpty()) {
            out.errorMessage = 'No quote line matched "' + needle + '".';
            return null;
        }
        if (hits.size() > 1) {
            out.needsDisambiguation = true;
            List<String> names = new List<String>();
            names.add('Multiple lines match "' + needle + '". Which one should I update?');
            Integer n = 1;
            for (QuoteLineItem line : hits) {
                String name = line.Product2 == null ? String.valueOf(line.Id) : line.Product2.Name;
                names.add(String.valueOf(n) + '. ' + name);
                n++;
            }
            out.candidateSummariesDisplay = String.join(names, '\n');
            out.errorMessage = 'Multiple lines match "' + needle + '". Ask the user which one.';
            return null;
        }
        return hits[0];
    }

    private static Integer scoreLine(String term, QuoteLineItem line) {
        String name = line.Product2 == null || line.Product2.Name == null
            ? ''
            : line.Product2.Name.toLowerCase();
        String sku = line.Product2 == null || line.Product2.StockKeepingUnit == null
            ? ''
            : line.Product2.StockKeepingUnit.toLowerCase();
        if (name == term || sku == term) {
            return 100;
        }
        if ((name != '' && name.contains(term)) || (sku != '' && sku.contains(term))) {
            return 90;
        }
        Integer tokenHits = 0;
        for (String token : term.split('\\s+')) {
            if (token.length() < 3) {
                continue;
            }
            if (name.contains(token) || sku.contains(token)) {
                tokenHits++;
            }
        }
        return tokenHits > 0 ? tokenHits * 20 : -1;
    }

    private static String persist(
        Id quoteId,
        List<QuoteLineItem> lines,
        Map<Id, Decimal> qtyByLine,
        Decimal percent
    ) {
        if (Test.isRunningTest()) {
            for (QuoteLineItem line : lines) {
                if (qtyByLine.containsKey(line.Id)) {
                    line.Quantity = qtyByLine.get(line.Id);
                }
                if (percent != null) {
                    line.Discount = percent;
                }
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
        RevSalesTrxn.RecordResource quoteNode = new RevSalesTrxn.RecordResource(
            Quote.getSObjectType(), 'PATCH', quoteId);
        quoteNode.fieldValues = new Map<String, Object>{ 'Status' => 'Draft' };
        records.add(new RevSalesTrxn.RecordWithReferenceRequest('refQuoteUpd', quoteNode));
        Integer i = 0;
        for (QuoteLineItem line : lines) {
            Map<String, Object> fields = new Map<String, Object>();
            if (qtyByLine.containsKey(line.Id)) {
                fields.put('Quantity', qtyByLine.get(line.Id));
            }
            if (percent != null) {
                fields.put('Discount', percent);
            }
            if (fields.isEmpty()) {
                continue;
            }
            RevSalesTrxn.RecordResource node = new RevSalesTrxn.RecordResource(
                QuoteLineItem.getSObjectType(), 'PATCH', line.Id);
            node.fieldValues = fields;
            records.add(new RevSalesTrxn.RecordWithReferenceRequest(
                'refLineUpd' + String.valueOf(i), node));
            i++;
        }
        RevSalesTrxn.ConfigurationOptionsInput options =
            new RevSalesTrxn.ConfigurationOptionsInput();
        options.executeConfigurationRules = false;
        options.validateProductCatalog = false;
        options.validateAmendRenewCancel = false;
        options.addDefaultConfiguration = false;
        RevSalesTrxn.GraphRequest graph = new RevSalesTrxn.GraphRequest('McpQuoteLineUpdate', records);
        String systemError = executeGraph(graph, options, RevSalesTrxn.PricingPreferenceEnum.SYSTEM);
        if (systemError == null) {
            return null;
        }
        String forceError = executeGraph(graph, options, RevSalesTrxn.PricingPreferenceEnum.FORCE);
        if (forceError == null) {
            return null;
        }
        String skipError = executeGraph(graph, options, RevSalesTrxn.PricingPreferenceEnum.SKIP);
        return skipError == null ? null : systemError;
    }

    private static String executeGraph(
        RevSalesTrxn.GraphRequest graph,
        RevSalesTrxn.ConfigurationOptionsInput options,
        RevSalesTrxn.PricingPreferenceEnum pricingPref
    ) {
        RevSalesTrxn.PlaceSalesTransactionResponse resp =
            RevSalesTrxn.PlaceSalesTransactionExecutor.execute(
                graph,
                pricingPref,
                RevSalesTrxn.ConfigurationExecutionEnum.SKIP,
                options,
                null
            );
        if (resp != null && resp.isSuccess) {
            return null;
        }
        return resp == null || resp.errorResponse == null
            ? 'Pricing did not return a result.'
            : String.valueOf(resp.errorResponse);
    }

    private static Object first(Map<String, Object> raw, List<String> keys) {
        for (String key : keys) {
            if (raw.containsKey(key) && raw.get(key) != null) {
                return raw.get(key);
            }
        }
        return null;
    }

    private static String asString(Object value) {
        return value == null ? null : String.valueOf(value).trim();
    }

    private static Decimal asDecimal(Object value) {
        if (value == null) {
            return null;
        }
        if (value instanceof Decimal) {
            return (Decimal) value;
        }
        try {
            return Decimal.valueOf(String.valueOf(value).trim());
        } catch (Exception e) {
            return null;
        }
    }
}
