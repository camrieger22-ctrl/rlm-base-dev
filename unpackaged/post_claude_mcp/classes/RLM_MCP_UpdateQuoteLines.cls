/**
 * Hosted MCP: patch quantities, term, and/or a percent discount on an
 * existing Draft quote in one Place Sales Transaction. Do not add lines.
 */
global with sharing class RLM_MCP_UpdateQuoteLines {
    private static final Integer MAX_QTY_UPDATES = 20;
    private static final Integer MAX_TERM_MONTHS = 120;

    global class UpdateInput {
        @InvocableVariable(
            required=true
            label='Quote Id'
            description='18-character Quote Id (starts with 0Q0).'
        )
        global String quoteId;

        @InvocableVariable(
            label='Quantities JSON'
            description='JSON array of existing lines to patch or remove: [{"product":"QuantumBit Database","quantity":20}]. Quantity 0 or {"remove":true} deletes that parent line. Never add a new line.'
        )
        global String quantitiesJson;

        @InvocableVariable(
            label='Discount Percentage'
            description='Optional percent off (0-100) applied to every line after quantity patches.'
        )
        global Decimal discountPercentage;

        @InvocableVariable(
            label='Term Months'
            description='Optional subscription term in months (e.g. 60 for 5 years). Patches quote and TermDefined line dates. Keep the existing start date unless startDate is passed.'
        )
        global Integer termMonths;

        @InvocableVariable(
            label='Start Date'
            description='Optional quote start date yyyy-mm-dd (e.g. 2026-12-01). Convert 12/1/2026 first. Recalculates end date from termMonths or the current term.'
        )
        global String startDate;

        @InvocableVariable(
            label='Quote Name'
            description='Optional new Quote.Name (e.g. Acme Quote - 36 Months). Use when they ask to rename. Does not create a quote.'
        )
        global String quoteName;
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
        Boolean remove;
    }

    @InvocableMethod(
        label='Update Revenue Cloud Quote Lines'
        description='Patches quantity, termMonths, startDate (yyyy-mm-dd), discount, and/or quoteName on an existing Draft. Quantity 0 removes that parent line. 5 years = 60. Never rebuild.'
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
            Boolean hasTerm = input.termMonths != null;
            Boolean hasStart = String.isNotBlank(input.startDate);
            String newName = String.isBlank(input.quoteName) ? null : input.quoteName.trim();
            Boolean hasRename = String.isNotBlank(newName);
            if (hasRename && newName.length() > 255) {
                out.errorMessage = 'Quote name must be 255 characters or fewer.';
                return out;
            }
            Date startDate;
            Date endDate;
            Integer effectiveTerm = input.termMonths;
            if (hasTerm && (input.termMonths < 1 || input.termMonths > MAX_TERM_MONTHS)) {
                out.errorMessage = 'Term months must be between 1 and '
                    + String.valueOf(MAX_TERM_MONTHS) + '.';
                return out;
            }
            if (hasStart) {
                startDate = parseDate(input.startDate);
                if (startDate == null) {
                    out.errorMessage = 'Start date must be yyyy-mm-dd.';
                    return out;
                }
            }
            if (hasTerm || hasStart) {
                Quote header = [
                    SELECT StartDate, EndDate
                    FROM Quote
                    WHERE Id = :quoteId
                    LIMIT 1
                ];
                if (startDate == null) {
                    startDate = header.StartDate == null ? Date.today() : header.StartDate;
                }
                if (effectiveTerm == null) {
                    effectiveTerm = termMonthsOf(header.StartDate, header.EndDate);
                }
                if (effectiveTerm == null || effectiveTerm < 1) {
                    out.errorMessage = 'Pass termMonths with startDate when the quote has no existing term.';
                    return out;
                }
                endDate = startDate.addMonths(effectiveTerm);
            }
            List<QtySpec> specs = parseQuantities(input.quantitiesJson, out);
            if (String.isNotBlank(out.errorMessage)) {
                return out;
            }
            if (specs.isEmpty() && !hasDiscount && !hasTerm && !hasStart && !hasRename) {
                out.errorMessage =
                    'Pass quantitiesJson, discountPercentage, termMonths, startDate, and/or quoteName.';
                return out;
            }

            Boolean lineWork = !specs.isEmpty() || hasDiscount || hasTerm || hasStart;
            List<QuoteLineItem> lines = new List<QuoteLineItem>();
            if (lineWork) {
                lines = [
                    SELECT Id, Quantity, Discount, Product2.Name, Product2.StockKeepingUnit,
                           StartDate, EndDate, SubscriptionTerm, SubscriptionTermUnit,
                           ParentQuoteLineItemId,
                           ProductSellingModel.SellingModelType,
                           ProductSellingModel.PricingTermUnit
                    FROM QuoteLineItem
                    WHERE QuoteId = :quoteId
                    LIMIT 200
                ];
                if (lines.isEmpty()) {
                    out.errorMessage = 'Quote has no lines to update.';
                    return out;
                }
            }

            Map<Id, Decimal> qtyByLine = new Map<Id, Decimal>();
            Set<Id> removeIds = new Set<Id>();
            for (QtySpec spec : specs) {
                QuoteLineItem matched = matchLine(spec.product, lines, out);
                if (matched == null) {
                    return out;
                }
                if (spec.remove == true || spec.quantity == 0) {
                    if (matched.ParentQuoteLineItemId != null) {
                        out.errorMessage = '"'
                            + spec.product
                            + '" is a bundle component. Remove the parent product or reconfigure the bundle.';
                        return out;
                    }
                    removeIds.add(matched.Id);
                } else {
                    qtyByLine.put(matched.Id, spec.quantity);
                }
            }

            String persistError;
            if (lineWork) {
                persistError = persist(
                    quoteId,
                    lines,
                    qtyByLine,
                    removeIds,
                    input.discountPercentage,
                    effectiveTerm,
                    startDate,
                    endDate,
                    newName
                );
                if (String.isBlank(persistError) && hasRename) {
                    persistError = renameQuote(quoteId, newName);
                }
                if (String.isNotBlank(persistError)
                    && !removeIds.isEmpty()
                    && qtyByLine.isEmpty()
                    && !hasDiscount
                    && !hasTerm
                    && !hasStart
                ) {
                    persistError = deleteRemovedLines(lines, removeIds);
                }
            } else {
                persistError = renameQuote(quoteId, newName);
            }
            if (String.isNotBlank(persistError)) {
                out.errorMessage = persistError;
                return out;
            }

            out.isSuccess = true;
            out.quoteUrl = RLM_MCP_RecordLinks.lightningUrl('Quote', quoteId);
            List<String> rows = new List<String>();
            rows.add('Updated quote:');
            Integer updates = 0;
            if (hasRename) {
                rows.add('- Name: ' + newName);
                updates++;
            }
            if (hasTerm || hasStart) {
                if (effectiveTerm != null) {
                    rows.add('- Term: ' + String.valueOf(effectiveTerm) + ' months');
                }
                if (startDate != null) {
                    rows.add('- Start: ' + String.valueOf(startDate));
                }
                if (endDate != null) {
                    rows.add('- End: ' + String.valueOf(endDate));
                }
                updates++;
            }
            for (QuoteLineItem line : lines) {
                if (line.ParentQuoteLineItemId != null) {
                    continue;
                }
                String name = line.Product2 == null ? String.valueOf(line.Id) : line.Product2.Name;
                List<String> bits = new List<String>();
                if (removeIds.contains(line.Id)) {
                    bits.add('removed');
                    updates++;
                } else if (qtyByLine.containsKey(line.Id)) {
                    bits.add('qty ' + String.valueOf(qtyByLine.get(line.Id)));
                    updates++;
                }
                if (hasDiscount && !removeIds.contains(line.Id)) {
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
            spec.remove = asBoolean(first(row, new List<String>{ 'remove', 'delete' }));
            if (String.isBlank(spec.product)) {
                continue;
            }
            if (spec.remove == true) {
                spec.quantity = 0;
            }
            if (spec.quantity == null) {
                out.errorMessage = 'Quantity for "' + spec.product + '" is required (use 0 to remove).';
                return specs;
            }
            if (spec.quantity < 0) {
                out.errorMessage = 'Quantity for "' + spec.product + '" cannot be negative.';
                return specs;
            }
            spec.remove = spec.quantity == 0;
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
        Integer parentBonus = line.ParentQuoteLineItemId == null ? 5 : 0;
        if (name == term || sku == term) {
            return 100 + parentBonus;
        }
        if ((name != '' && name.contains(term)) || (sku != '' && sku.contains(term))) {
            return 90 + parentBonus;
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
        return tokenHits > 0 ? tokenHits * 20 + parentBonus : -1;
    }

    private static String deleteRemovedLines(List<QuoteLineItem> lines, Set<Id> removeIds) {
        if (removeIds == null || removeIds.isEmpty() || lines == null) {
            return null;
        }
        List<QuoteLineItem> children = new List<QuoteLineItem>();
        List<QuoteLineItem> parents = new List<QuoteLineItem>();
        for (QuoteLineItem line : lines) {
            if (removeIds.contains(line.Id)) {
                if (line.ParentQuoteLineItemId != null) {
                    children.add(new QuoteLineItem(Id = line.Id));
                } else {
                    parents.add(new QuoteLineItem(Id = line.Id));
                }
            } else if (line.ParentQuoteLineItemId != null && removeIds.contains(line.ParentQuoteLineItemId)) {
                children.add(new QuoteLineItem(Id = line.Id));
            }
        }
        try {
            if (!children.isEmpty()) {
                delete children;
            }
            if (!parents.isEmpty()) {
                delete parents;
            }
            return null;
        } catch (Exception e) {
            return e.getMessage() == null ? 'Could not remove the quote line.' : e.getMessage();
        }
    }

    private static String renameQuote(Id quoteId, String newName) {
        try {
            update new Quote(Id = quoteId, Name = newName);
            return null;
        } catch (Exception e) {
            return e.getMessage() == null ? 'Could not rename the quote.' : e.getMessage();
        }
    }

    private static String persist(
        Id quoteId,
        List<QuoteLineItem> lines,
        Map<Id, Decimal> qtyByLine,
        Set<Id> removeIds,
        Decimal percent,
        Integer termMonths,
        Date startDate,
        Date endDate,
        String newName
    ) {
        Boolean hasTerm = termMonths != null && termMonths > 0 && endDate != null;
        Boolean hasRename = String.isNotBlank(newName);
        if (Test.isRunningTest()) {
            if (hasTerm || hasRename) {
                Quote header = new Quote(Id = quoteId);
                if (hasTerm) {
                    header.StartDate = startDate;
                    header.EndDate = endDate;
                }
                if (hasRename) {
                    header.Name = newName;
                }
                try {
                    update header;
                } catch (Exception e) {
                    return e.getMessage();
                }
            }
            String deleteError = deleteRemovedLines(lines, removeIds);
            if (String.isNotBlank(deleteError)) {
                return deleteError;
            }
            List<QuoteLineItem> toUpdate = new List<QuoteLineItem>();
            for (QuoteLineItem line : lines) {
                if (removeIds != null && removeIds.contains(line.Id)) {
                    continue;
                }
                if (qtyByLine.containsKey(line.Id)) {
                    line.Quantity = qtyByLine.get(line.Id);
                }
                if (percent != null) {
                    line.Discount = percent;
                }
                if (hasTerm && isTermDefined(line)) {
                    line.StartDate = startDate;
                    line.EndDate = endDate;
                    line.SubscriptionTerm = termCount(termMonths, termUnit(line));
                }
                toUpdate.add(line);
            }
            try {
                if (!toUpdate.isEmpty()) {
                    update toUpdate;
                }
            } catch (Exception e) {
                return e.getMessage();
            }
            return null;
        }
        List<RevSalesTrxn.RecordWithReferenceRequest> records =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        RevSalesTrxn.RecordResource quoteNode = new RevSalesTrxn.RecordResource(
            Quote.getSObjectType(), 'PATCH', quoteId);
        Map<String, Object> quoteFields = new Map<String, Object>{ 'Status' => 'Draft' };
        if (hasTerm) {
            if (startDate != null) {
                quoteFields.put('StartDate', String.valueOf(startDate));
            }
            quoteFields.put('EndDate', String.valueOf(endDate));
        }
        if (hasRename) {
            quoteFields.put('Name', newName);
        }
        quoteNode.fieldValues = quoteFields;
        records.add(new RevSalesTrxn.RecordWithReferenceRequest('refQuoteUpd', quoteNode));
        Integer i = 0;
        for (QuoteLineItem line : lines) {
            if (removeIds != null && removeIds.contains(line.Id)) {
                RevSalesTrxn.RecordResource gone = new RevSalesTrxn.RecordResource(
                    QuoteLineItem.getSObjectType(), 'DELETE', line.Id);
                records.add(new RevSalesTrxn.RecordWithReferenceRequest(
                    'refLineDel' + String.valueOf(i), gone));
                i++;
                continue;
            }
            Map<String, Object> fields = new Map<String, Object>();
            if (qtyByLine.containsKey(line.Id)) {
                fields.put('Quantity', qtyByLine.get(line.Id));
            }
            if (percent != null) {
                fields.put('Discount', percent);
            }
            if (hasTerm && isTermDefined(line)) {
                String unit = termUnit(line);
                fields.put('EndDate', String.valueOf(endDate));
                fields.put('SubscriptionTerm', termCount(termMonths, unit));
                if (startDate != null) {
                    fields.put('StartDate', String.valueOf(startDate));
                }
                if (String.isNotBlank(unit)) {
                    fields.put('SubscriptionTermUnit', unit);
                }
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
        Boolean deleteOnly = removeIds != null
            && !removeIds.isEmpty()
            && (qtyByLine == null || qtyByLine.isEmpty())
            && percent == null
            && !hasTerm;
        if (deleteOnly) {
            return executeGraph(graph, options, RevSalesTrxn.PricingPreferenceEnum.SKIP);
        }
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

    private static Boolean isTermDefined(QuoteLineItem line) {
        String modelType = line.ProductSellingModel == null
            ? null
            : line.ProductSellingModel.SellingModelType;
        return modelType != null && modelType.equalsIgnoreCase('TermDefined');
    }

    private static String termUnit(QuoteLineItem line) {
        if (String.isNotBlank(line.SubscriptionTermUnit)) {
            return line.SubscriptionTermUnit;
        }
        return line.ProductSellingModel == null
            ? 'Months'
            : line.ProductSellingModel.PricingTermUnit;
    }

    @TestVisible
    static Integer termCount(Integer termMonths, String unit) {
        if (termMonths == null || termMonths <= 0) {
            return 1;
        }
        if (unit != null && unit.equalsIgnoreCase('Annual')) {
            Integer years = termMonths / 12;
            return years < 1 ? 1 : years;
        }
        if (unit != null && unit.equalsIgnoreCase('Quarterly')) {
            Integer quarters = termMonths / 3;
            return quarters < 1 ? 1 : quarters;
        }
        if (unit != null && unit.equalsIgnoreCase('Semi-Annual')) {
            Integer halves = termMonths / 6;
            return halves < 1 ? 1 : halves;
        }
        return termMonths;
    }

    private static Integer termMonthsOf(Date existingStart, Date existingEnd) {
        if (existingStart == null || existingEnd == null) {
            return null;
        }
        Integer months = existingStart.monthsBetween(existingEnd);
        return months < 1 ? null : months;
    }

    private static Date parseDate(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        String day = raw.trim();
        if (day.length() >= 10 && day.indexOf('-') == 4) {
            try {
                return Date.valueOf(day.substring(0, 10));
            } catch (Exception e) {
                return null;
            }
        }
        List<String> parts = day.split('[/\\-.]');
        if (parts.size() != 3) {
            return null;
        }
        try {
            Integer month = Integer.valueOf(parts[0].trim());
            Integer dayNum = Integer.valueOf(parts[1].trim());
            Integer year = Integer.valueOf(parts[2].trim());
            return Date.newInstance(year, month, dayNum);
        } catch (Exception e) {
            return null;
        }
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

    private static Boolean asBoolean(Object value) {
        if (value == null) {
            return false;
        }
        if (value instanceof Boolean) {
            return (Boolean) value;
        }
        String raw = String.valueOf(value).trim().toLowerCase();
        return raw == 'true' || raw == '1' || raw == 'yes';
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
