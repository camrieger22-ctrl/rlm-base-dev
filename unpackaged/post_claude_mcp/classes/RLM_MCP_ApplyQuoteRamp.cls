/**
 * Hosted MCP: describe ramp segments on a Draft, add a product across
 * existing Create Ramp Schedule groups, patch qty, or apply editsJson
 * (add / remove / qty / discount by Trial, Year N, or stub). Does not
 * create the schedule (use RLM_MCP_CreateRampSchedule). Never Ramp
 * Builder. Never RLM_RampTransactionAction. Never SObject-insert
 * QuoteLineGroup.
 */
global with sharing class RLM_MCP_ApplyQuoteRamp {
    private static final Integer MAX_SEGMENTS = 12;
    private static final Integer MAX_EDITS = 20;
    @TestVisible
    static QuoteLineItem extraChildForTest;

    global class RampInput {
        @InvocableVariable(
            required=true
            label='Quote Id'
            description='18-character Quote Id (starts with 0Q0).'
        )
        global String quoteId;

        @InvocableVariable(
            label='Product Name'
            description='Product to add or patch on existing ramp segments, e.g. QuantumBit Database. Skip when editsJson is set.'
        )
        global String productName;

        @InvocableVariable(
            label='Segments JSON'
            description='Optional qtys: [{"quantity":10},{"quantity":20},{"quantity":30}]. Omit to describe only. Ignored when editsJson is set.'
        )
        global String segmentsJson;

        @InvocableVariable(
            label='Edits JSON'
            description='Per-year add/remove/qty/discount. Omit product for a year blanket: [{"segments":["Year 2"],"discount":25}]. Named product overlays that SKU (parent or child). Later named rows win. Omit segments for all ramp groups.'
        )
        global String editsJson;
    }

    global class RampOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(label='Quote Url')
        global String quoteUrl;
        @InvocableVariable(label='Results Display')
        global String resultsDisplay;
        @InvocableVariable(
            label='Needs Action'
            description='True when a bundle was added unconfigured. Describe now, wait, then configure. That picker is the Next line. Never Gmail this note.'
        )
        global Boolean needsAction;
        @InvocableVariable(label='Needs Disambiguation')
        global Boolean needsDisambiguation;
        @InvocableVariable(label='Candidate Summaries Display')
        global String candidateSummariesDisplay;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @TestVisible
    class RampEdit {
        public String product;
        public List<String> segmentTokens;
        public Decimal quantity;
        public Decimal discount;
        public Boolean remove;
        public Boolean hasQuantity;
        public Boolean hasDiscount;
    }

    @InvocableMethod(
        label='Apply Revenue Cloud Quote Ramp'
        description='Describes ramp segments, first-add 10/20/30, or editsJson add/remove/qty/discount by Trial/Year N/stub. Year blanket: omit product. Named SKU overlays, including bundle children. Never Ramp Builder. Never SObject-insert QuoteLineGroup.'
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
        out.needsAction = false;
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
                SELECT Id, Quantity, Discount, QuoteLineGroupId, PricebookEntryId, Product2Id,
                       Product2.Name, Product2.StockKeepingUnit, ParentQuoteLineItemId,
                       RampIdentifier
                FROM QuoteLineItem
                WHERE QuoteId = :quoteId
                WITH USER_MODE
                LIMIT 200
            ];
            if (extraChildForTest != null) {
                lines.add(extraChildForTest);
                extraChildForTest = null;
            }
            List<QuoteLineGroup> ramped = new List<QuoteLineGroup>();
            for (QuoteLineGroup grp : groups) {
                if (grp.IsRamped == true) {
                    ramped.add(grp);
                }
            }
            if (String.isNotBlank(input.editsJson)) {
                List<RampEdit> edits = parseEdits(input.editsJson, out);
                if (String.isNotBlank(out.errorMessage)) {
                    return out;
                }
                if (ramped.isEmpty()) {
                    out.errorMessage = 'No ramp schedule on this quote. Call createRevenueCloudRampSchedule first (preview, then confirm=true). Then call this tool with editsJson or productName and segmentsJson. Never Ramp Builder.';
                    return out;
                }
                return applyEdits(out, quote, ramped, lines, edits);
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
            rows.add('No ramp segments yet. Call createRevenueCloudRampSchedule to preview and create the empty schedule (Annual/Custom, trial, prorated). Then call this tool with productName and segmentsJson, or editsJson for per-year add/remove/qty/discount.');
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
                if (line.ParentQuoteLineItemId != null) {
                    continue;
                }
                String name = line.Product2 == null ? 'Line' : line.Product2.Name;
                String bits = '  · ' + name + ' qty '
                    + RLM_MCP_RecordLinks.formatNumber(line.Quantity);
                if (line.Discount != null && line.Discount != 0) {
                    bits += ', ' + RLM_MCP_RecordLinks.formatNumber(line.Discount) + '% off';
                }
                rows.add(bits);
            }
        }
        return String.join(rows, '\n');
    }

    private static RampOutput finishSuccess(
        RampOutput out,
        Id quoteId,
        List<String> recap
    ) {
        out.isSuccess = true;
        out.resultsDisplay = String.join(recap, '\n');
        RLM_MCP_BundleCoach.Result gate = RLM_MCP_BundleCoach.forQuote(quoteId);
        out.resultsDisplay = RLM_MCP_BundleCoach.append(out.resultsDisplay, gate);
        if (gate != null && gate.needsAction == true) {
            out.needsAction = true;
        }
        return out;
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
            String addError = addProducts(
                quote.Id,
                pbe,
                missing,
                missingQtys,
                null,
                rampIdFromLines(productName, lines)
            );
            if (String.isNotBlank(addError)) {
                out.errorMessage = addError;
                return out;
            }
        }
        if (!qtyByLine.isEmpty()) {
            String persistError = persistPatches(
                quote.Id, qtyByLine, new Map<Id, Decimal>());
            if (String.isNotBlank(persistError)) {
                out.errorMessage = persistError;
                return out;
            }
        }
        String link = RLM_MCP_RecordLinks.markdown('Open Quote', 'Quote', quote.Id);
        if (String.isNotBlank(link)) {
            recap.add(link);
        }
        return finishSuccess(out, quote.Id, recap);
    }

    private static RampOutput applyEdits(
        RampOutput out,
        Quote quote,
        List<QuoteLineGroup> ramped,
        List<QuoteLineItem> lines,
        List<RampEdit> edits
    ) {
        Map<Id, Decimal> blanketDiscountByLine = new Map<Id, Decimal>();
        List<String> recap = new List<String>{ 'Updated ramp:' };
        List<RampEdit> named = new List<RampEdit>();
        for (RampEdit edit : edits) {
            if (String.isBlank(edit.product) && edit.hasDiscount == true) {
                if (edit.discount < 0 || edit.discount > 100) {
                    out.errorMessage = 'Discount percentage must be between 0 and 100.';
                    return out;
                }
                List<QuoteLineGroup> targets = resolveTargetGroups(
                    edit.segmentTokens, ramped, out);
                if (targets == null) {
                    return out;
                }
                for (QuoteLineGroup seg : targets) {
                    Integer stamped = 0;
                    for (QuoteLineItem line : lines) {
                        if (line.QuoteLineGroupId != seg.Id) {
                            continue;
                        }
                        blanketDiscountByLine.put(line.Id, edit.discount);
                        stamped++;
                    }
                    recap.add(recapLine(
                        seg,
                        'all lines',
                        bitsFor(null, edit.discount, false)
                            + (stamped == 0 ? ' (no lines)' : '')
                    ));
                }
            } else {
                named.add(edit);
            }
        }
        Map<String, CellIntent> intents = new Map<String, CellIntent>();
        for (RampEdit edit : named) {
            List<QuoteLineGroup> targets = resolveTargetGroups(
                edit.segmentTokens, ramped, out);
            if (targets == null) {
                return out;
            }
            Boolean discountOnly = edit.hasDiscount == true
                && edit.remove != true
                && edit.hasQuantity != true;
            for (QuoteLineGroup seg : targets) {
                QuoteLineItem line;
                if (discountOnly) {
                    line = matchInGroupForDiscount(edit.product, seg.Id, lines, out);
                    if (String.isNotBlank(out.errorMessage)) {
                        return out;
                    }
                } else {
                    line = matchInGroupQuiet(edit.product, seg.Id, lines);
                    if (line == null && matchChildInGroupQuiet(edit.product, seg.Id, lines) != null) {
                        out.errorMessage = '"' + edit.product
                            + '" is a bundle component. Remove the parent product or reconfigure the bundle.';
                        return out;
                    }
                }
                String key = edit.product.trim().toLowerCase() + '\n' + String.valueOf(seg.Id);
                CellIntent intent = intents.get(key);
                if (intent == null) {
                    intent = new CellIntent();
                    intent.product = edit.product;
                    intent.segment = seg;
                    intent.line = line;
                    intent.remove = false;
                    intent.hasQty = false;
                    intent.hasDiscount = false;
                    intents.put(key, intent);
                }
                intent.line = line;
                if (edit.remove == true || (edit.hasQuantity && edit.quantity == 0)) {
                    intent.remove = true;
                    intent.hasQty = false;
                    intent.hasDiscount = false;
                    intent.quantity = null;
                    intent.discount = null;
                    continue;
                }
                intent.remove = false;
                if (edit.hasQuantity) {
                    if (edit.quantity < 0) {
                        out.errorMessage = 'Quantity for "' + edit.product + '" must be 0 or greater.';
                        return out;
                    }
                    intent.hasQty = true;
                    intent.quantity = edit.quantity;
                }
                if (edit.hasDiscount) {
                    if (edit.discount < 0 || edit.discount > 100) {
                        out.errorMessage = 'Discount percentage must be between 0 and 100.';
                        return out;
                    }
                    intent.hasDiscount = true;
                    intent.discount = edit.discount;
                }
            }
        }
        Set<Id> removeIds = new Set<Id>();
        Map<String, List<QuoteLineGroup>> addGroups = new Map<String, List<QuoteLineGroup>>();
        Map<String, List<Decimal>> addQtys = new Map<String, List<Decimal>>();
        Map<String, List<Decimal>> addDiscounts = new Map<String, List<Decimal>>();
        Map<Id, Decimal> qtyByLine = new Map<Id, Decimal>();
        Map<Id, Decimal> discountByLine = new Map<Id, Decimal>(blanketDiscountByLine);
        for (CellIntent intent : intents.values()) {
            if (intent.remove == true) {
                if (intent.line == null) {
                    out.errorMessage = '"' + intent.product + '" is not on '
                        + nullToName(intent.segment.Name) + '.';
                    return out;
                }
                removeIds.add(intent.line.Id);
                recap.add(recapLine(intent.segment, intent.product, 'removed'));
                continue;
            }
            if (intent.line == null) {
                if (intent.hasQty != true && intent.hasDiscount != true) {
                    intent.hasQty = true;
                    intent.quantity = 1;
                }
                if (intent.hasQty != true) {
                    out.errorMessage = '"' + intent.product + '" is not on '
                        + nullToName(intent.segment.Name)
                        + '. Pass quantity to add it, or add the product first.';
                    return out;
                }
                String pkey = intent.product;
                if (!addGroups.containsKey(pkey)) {
                    addGroups.put(pkey, new List<QuoteLineGroup>());
                    addQtys.put(pkey, new List<Decimal>());
                    addDiscounts.put(pkey, new List<Decimal>());
                }
                addGroups.get(pkey).add(intent.segment);
                addQtys.get(pkey).add(intent.quantity);
                addDiscounts.get(pkey).add(
                    intent.hasDiscount == true ? intent.discount : null);
                recap.add(recapLine(
                    intent.segment,
                    intent.product,
                    bitsFor(
                        intent.quantity,
                        intent.hasDiscount == true ? intent.discount : null,
                        true
                    )
                ));
                continue;
            }
            if (intent.hasQty == true) {
                qtyByLine.put(intent.line.Id, intent.quantity);
            }
            if (intent.hasDiscount == true) {
                discountByLine.put(intent.line.Id, intent.discount);
            }
            if (intent.hasQty == true || intent.hasDiscount == true) {
                recap.add(recapLine(
                    intent.segment,
                    intent.product,
                    bitsFor(
                        intent.hasQty == true ? intent.quantity : null,
                        intent.hasDiscount == true ? intent.discount : null,
                        false
                    )
                ));
            }
        }
        if (!removeIds.isEmpty()) {
            String deleteError = deleteProducts(quote.Id, removeIds);
            if (String.isNotBlank(deleteError)) {
                out.errorMessage = deleteError;
                return out;
            }
        }
        for (String productName : addGroups.keySet()) {
            PricebookEntry pbe = resolvePricebookEntry(quote, productName, lines, out);
            if (pbe == null) {
                return out;
            }
            String addError = addProducts(
                quote.Id,
                pbe,
                addGroups.get(productName),
                addQtys.get(productName),
                addDiscounts.get(productName),
                rampIdFromLines(productName, lines)
            );
            if (String.isNotBlank(addError)) {
                out.errorMessage = addError;
                return out;
            }
        }
        if (!qtyByLine.isEmpty() || !discountByLine.isEmpty()) {
            String persistError = persistPatches(quote.Id, qtyByLine, discountByLine);
            if (String.isNotBlank(persistError)) {
                out.errorMessage = persistError;
                return out;
            }
        }
        String link = RLM_MCP_RecordLinks.markdown('Open Quote', 'Quote', quote.Id);
        if (String.isNotBlank(link)) {
            recap.add(link);
        }
        return finishSuccess(out, quote.Id, recap);
    }

    private class CellIntent {
        public String product;
        public QuoteLineGroup segment;
        public QuoteLineItem line;
        public Boolean remove;
        public Decimal quantity;
        public Decimal discount;
        public Boolean hasQty;
        public Boolean hasDiscount;
    }

    @TestVisible
    static List<RampEdit> parseEdits(String raw, RampOutput out) {
        List<RampEdit> edits = new List<RampEdit>();
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(raw);
        } catch (Exception e) {
            out.errorMessage = 'editsJson is not valid JSON. Pass [{"product":"Name","segments":["Year 2"],"quantity":1}].';
            return edits;
        }
        if (!(parsed instanceof List<Object>)) {
            out.errorMessage = 'editsJson must be a JSON array.';
            return edits;
        }
        for (Object item : (List<Object>) parsed) {
            if (edits.size() >= MAX_EDITS) {
                break;
            }
            if (!(item instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> row = (Map<String, Object>) item;
            RampEdit edit = new RampEdit();
            edit.hasQuantity = false;
            edit.hasDiscount = false;
            edit.remove = false;
            edit.product = asString(first(row, new List<String>{ 'product', 'productName', 'sku' }));
            edit.segmentTokens = parseSegmentTokens(row);
            edit.remove = asBoolean(first(row, new List<String>{ 'remove', 'delete' }));
            Object qty = first(row, new List<String>{ 'quantity', 'qty' });
            if (qty != null) {
                try {
                    edit.quantity = Decimal.valueOf(String.valueOf(qty).trim());
                    edit.hasQuantity = true;
                } catch (Exception e) {
                    out.errorMessage = 'Quantity'
                        + (String.isBlank(edit.product) ? '' : ' for "' + edit.product + '"')
                        + ' must be a number.';
                    return new List<RampEdit>();
                }
            }
            Object discount = first(row, new List<String>{ 'discount', 'discountPercentage' });
            if (discount != null) {
                try {
                    edit.discount = Decimal.valueOf(String.valueOf(discount).trim());
                    edit.hasDiscount = true;
                } catch (Exception e) {
                    out.errorMessage = 'Discount'
                        + (String.isBlank(edit.product) ? '' : ' for "' + edit.product + '"')
                        + ' must be a number.';
                    return new List<RampEdit>();
                }
            }
            if (String.isBlank(edit.product)) {
                if (edit.hasDiscount != true || edit.remove == true || edit.hasQuantity == true) {
                    out.errorMessage = 'Each editsJson row needs a product, unless it is a year discount (segments + discount).';
                    return new List<RampEdit>();
                }
            } else if (edit.remove != true && edit.hasQuantity != true && edit.hasDiscount != true) {
                edit.hasQuantity = true;
                edit.quantity = 1;
            }
            edits.add(edit);
        }
        if (edits.isEmpty()) {
            out.errorMessage = 'editsJson had no edits.';
        }
        return edits;
    }

    private static List<String> parseSegmentTokens(Map<String, Object> row) {
        List<String> tokens = new List<String>();
        Object segs = first(row, new List<String>{ 'segments', 'segment', 'years', 'year' });
        if (segs == null) {
            return tokens;
        }
        if (segs instanceof List<Object>) {
            for (Object item : (List<Object>) segs) {
                if (item == null) {
                    continue;
                }
                if (item instanceof Decimal || item instanceof Integer || item instanceof Long) {
                    tokens.add('Year ' + String.valueOf(item));
                } else {
                    String value = String.valueOf(item).trim();
                    if (String.isNotBlank(value)) {
                        tokens.add(value);
                    }
                }
            }
            return tokens;
        }
        if (segs instanceof Decimal || segs instanceof Integer || segs instanceof Long) {
            tokens.add('Year ' + String.valueOf(segs));
            return tokens;
        }
        String value = String.valueOf(segs).trim();
        if (String.isNotBlank(value)) {
            tokens.add(value);
        }
        return tokens;
    }

    @TestVisible
    static List<QuoteLineGroup> resolveTargetGroups(
        List<String> tokens,
        List<QuoteLineGroup> ramped,
        RampOutput out
    ) {
        if (tokens == null || tokens.isEmpty()) {
            return ramped;
        }
        List<Boolean> pick = new List<Boolean>();
        for (Integer i = 0; i < ramped.size(); i++) {
            pick.add(false);
        }
        for (String token : tokens) {
            List<QuoteLineGroup> hits = matchSegmentToken(token, ramped);
            if (hits.isEmpty()) {
                out.errorMessage = 'No ramp segment matched "' + token + '". Use Trial, Year 1, Y2, prorated, stub, paid, or all.';
                return null;
            }
            if (hits.size() > 1 && !isAllOrPaid(token)) {
                out.errorMessage = 'Multiple ramp segments matched "' + token + '". Use a more specific name.';
                return null;
            }
            for (QuoteLineGroup hit : hits) {
                for (Integer i = 0; i < ramped.size(); i++) {
                    QuoteLineGroup seg = ramped[i];
                    if (seg === hit || (seg.Id != null && hit.Id != null && seg.Id == hit.Id)) {
                        pick[i] = true;
                    }
                }
            }
        }
        List<QuoteLineGroup> ordered = new List<QuoteLineGroup>();
        for (Integer i = 0; i < ramped.size(); i++) {
            if (pick[i] == true) {
                ordered.add(ramped[i]);
            }
        }
        return ordered;
    }

    private static Boolean isAllOrPaid(String token) {
        String compact = compactToken(token);
        return compact == 'all' || compact == 'every' || compact == 'everyyear'
            || compact == 'allyears' || compact == 'entireramp'
            || compact == 'paid' || compact == 'yearly' || compact == 'paidyears';
    }

    @TestVisible
    static List<QuoteLineGroup> matchSegmentToken(
        String token,
        List<QuoteLineGroup> ramped
    ) {
        List<QuoteLineGroup> hits = new List<QuoteLineGroup>();
        String compact = compactToken(token);
        if (String.isBlank(compact)) {
            return hits;
        }
        if (compact == 'all' || compact == 'every' || compact == 'everyyear'
            || compact == 'allyears' || compact == 'entireramp'
        ) {
            return new List<QuoteLineGroup>(ramped);
        }
        if (compact == 'paid' || compact == 'yearly' || compact == 'paidyears') {
            for (QuoteLineGroup seg : ramped) {
                if (seg.SegmentType != 'FreeTrial') {
                    hits.add(seg);
                }
            }
            return hits;
        }
        if (compact == 'trial' || compact == 'freetrial') {
            for (QuoteLineGroup seg : ramped) {
                if (seg.SegmentType == 'FreeTrial') {
                    hits.add(seg);
                }
            }
            if (!hits.isEmpty()) {
                return hits;
            }
        }
        if (compact == 'prorated' || compact == 'proratedstub' || compact == 'stub'
            || compact == 'proration' || compact == 'prorate'
        ) {
            for (QuoteLineGroup seg : ramped) {
                if (seg.SegmentType == 'Prorated') {
                    hits.add(seg);
                }
            }
            if (!hits.isEmpty()) {
                return hits;
            }
        }
        Integer yearNum = yearNumber(compact);
        if (yearNum != null) {
            for (QuoteLineGroup seg : ramped) {
                if (nameHasYear(compactToken(nullToName(seg.Name)), yearNum)) {
                    hits.add(seg);
                }
            }
            if (!hits.isEmpty()) {
                return hits;
            }
            Integer yearlyIndex = 0;
            for (QuoteLineGroup seg : ramped) {
                if (seg.SegmentType == 'Yearly') {
                    yearlyIndex++;
                    if (yearlyIndex == yearNum) {
                        hits.add(seg);
                    }
                }
            }
            return hits;
        }
        String needle = compact;
        for (QuoteLineGroup seg : ramped) {
            String name = compactToken(nullToName(seg.Name));
            if (name == needle || name.contains(needle)) {
                hits.add(seg);
            }
        }
        return hits;
    }

    private static String compactToken(String token) {
        if (String.isBlank(token)) {
            return '';
        }
        String n = token.trim().toLowerCase();
        if (n.startsWith('the ')) {
            n = n.substring(4);
        }
        return n.replaceAll('[^a-z0-9]', '');
    }

    private static Integer yearNumber(String compact) {
        if (String.isBlank(compact)) {
            return null;
        }
        String digits;
        if (compact.startsWith('year') && compact.length() > 4) {
            digits = compact.substring(4);
        } else if (compact.startsWith('y') && compact.length() > 1 && compact.length() <= 4) {
            digits = compact.substring(1);
        } else if (compact.isNumeric()) {
            digits = compact;
        } else {
            return null;
        }
        Integer cut = 0;
        while (cut < digits.length() && digits.substring(cut, cut + 1).isNumeric()) {
            cut++;
        }
        if (cut == 0) {
            return null;
        }
        try {
            return Integer.valueOf(digits.substring(0, cut));
        } catch (Exception e) {
            return null;
        }
    }

    private static Boolean nameHasYear(String compactName, Integer yearNum) {
        String needle = 'year' + String.valueOf(yearNum);
        Integer idx = compactName.indexOf(needle);
        if (idx < 0) {
            return false;
        }
        Integer after = idx + needle.length();
        if (after < compactName.length()
            && compactName.substring(after, after + 1).isNumeric()
        ) {
            return false;
        }
        return true;
    }

    @TestVisible
    static QuoteLineItem matchInGroupQuiet(
        String productName,
        Id groupId,
        List<QuoteLineItem> lines
    ) {
        String term = productName.trim().toLowerCase();
        for (QuoteLineItem line : lines) {
            if (line.QuoteLineGroupId != groupId) {
                continue;
            }
            if (line.ParentQuoteLineItemId != null) {
                continue;
            }
            if (nameOrSkuMatches(line, term)) {
                return line;
            }
        }
        return null;
    }

    @TestVisible
    static QuoteLineItem matchChildInGroupQuiet(
        String productName,
        Id groupId,
        List<QuoteLineItem> lines
    ) {
        if (String.isBlank(productName) || lines == null) {
            return null;
        }
        String term = productName.trim().toLowerCase();
        for (QuoteLineItem line : lines) {
            if (line.QuoteLineGroupId != groupId || line.ParentQuoteLineItemId == null) {
                continue;
            }
            if (nameOrSkuMatches(line, term)) {
                return line;
            }
        }
        return null;
    }

    @TestVisible
    static QuoteLineItem matchInGroupForDiscount(
        String productName,
        Id groupId,
        List<QuoteLineItem> lines,
        RampOutput out
    ) {
        if (String.isBlank(productName) || lines == null) {
            return null;
        }
        String term = productName.trim().toLowerCase();
        List<QuoteLineItem> hits = new List<QuoteLineItem>();
        for (QuoteLineItem line : lines) {
            if (line.QuoteLineGroupId != groupId) {
                continue;
            }
            if (nameOrSkuMatches(line, term)) {
                hits.add(line);
            }
        }
        if (hits.isEmpty()) {
            return null;
        }
        if (hits.size() > 1) {
            out.errorMessage = 'Multiple "' + productName
                + '" lines in that year. Name the SKU more specifically.';
            return null;
        }
        return hits[0];
    }

    private static Boolean nameOrSkuMatches(QuoteLineItem line, String term) {
        String name = line.Product2 == null || line.Product2.Name == null
            ? '' : line.Product2.Name.toLowerCase();
        String sku = line.Product2 == null || line.Product2.StockKeepingUnit == null
            ? '' : line.Product2.StockKeepingUnit.toLowerCase();
        return name == term || sku == term || name.contains(term) || sku.contains(term);
    }

    private static String rampIdFromLines(String productName, List<QuoteLineItem> lines) {
        if (String.isBlank(productName) || lines == null) {
            return null;
        }
        String term = productName.trim().toLowerCase();
        for (QuoteLineItem line : lines) {
            if (line.ParentQuoteLineItemId != null) {
                continue;
            }
            if (nameOrSkuMatches(line, term) && String.isNotBlank(line.RampIdentifier)) {
                return line.RampIdentifier;
            }
        }
        return null;
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
        String raw = productName.trim();
        List<PricebookEntry> exact = [
            SELECT Id, Product2Id, UnitPrice, Product2.Name, Product2.StockKeepingUnit,
                   ProductSellingModel.SellingModelType,
                   ProductSellingModel.PricingTermUnit
            FROM PricebookEntry
            WHERE Pricebook2Id = :quote.Pricebook2Id
            AND IsActive = true
            AND (Product2.Name = :raw OR Product2.StockKeepingUnit = :raw)
            WITH USER_MODE
            LIMIT 20
        ];
        List<PricebookEntry> hits = new List<PricebookEntry>(exact);
        if (hits.isEmpty()) {
            String likeTerm = '%' + raw.replace('%', '\\%').replace('_', '\\_') + '%';
            hits = [
                SELECT Id, Product2Id, UnitPrice, Product2.Name, Product2.StockKeepingUnit,
                       ProductSellingModel.SellingModelType,
                       ProductSellingModel.PricingTermUnit
                FROM PricebookEntry
                WHERE Pricebook2Id = :quote.Pricebook2Id
                AND IsActive = true
                AND (Product2.Name LIKE :likeTerm OR Product2.StockKeepingUnit LIKE :likeTerm)
                WITH USER_MODE
                LIMIT 50
            ];
        }
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
        List<Decimal> qtys,
        List<Decimal> discounts,
        String rampId
    ) {
        if (segments == null || segments.isEmpty()) {
            return null;
        }
        if (String.isBlank(rampId)) {
            rampId = newRampId();
        }
        if (Test.isRunningTest()) {
            List<QuoteLineItem> rows = new List<QuoteLineItem>();
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
                Decimal lineDiscount = discountAt(discounts, i);
                if (lineDiscount != null) {
                    row.Discount = lineDiscount;
                } else if (seg.Discount != null) {
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
            Decimal lineDiscount = discountAt(discounts, i);
            if (lineDiscount != null) {
                fields.put('Discount', lineDiscount);
            } else if (seg.Discount != null) {
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

    private static String deleteProducts(Id quoteId, Set<Id> lineIds) {
        if (lineIds == null || lineIds.isEmpty()) {
            return null;
        }
        if (Test.isRunningTest()) {
            try {
                delete [
                    SELECT Id
                    FROM QuoteLineItem
                    WHERE Id IN :lineIds
                    AND QuoteId = :quoteId
                    WITH USER_MODE
                ];
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
        for (Id lineId : lineIds) {
            n++;
            RevSalesTrxn.RecordResource line = new RevSalesTrxn.RecordResource(
                QuoteLineItem.getSObjectType(), 'DELETE', lineId
            );
            line.fieldValues = new Map<String, Object>();
            records.add(new RevSalesTrxn.RecordWithReferenceRequest('refDel' + n, line));
        }
        RevSalesTrxn.ConfigurationOptionsInput options =
            new RevSalesTrxn.ConfigurationOptionsInput();
        options.executeConfigurationRules = false;
        options.validateProductCatalog = false;
        options.validateAmendRenewCancel = false;
        options.addDefaultConfiguration = false;
        RevSalesTrxn.GraphRequest graph = new RevSalesTrxn.GraphRequest(
            'McpRampDeleteProducts', records);
        RevSalesTrxn.PlaceSalesTransactionResponse resp =
            RevSalesTrxn.PlaceSalesTransactionExecutor.execute(
                graph,
                RevSalesTrxn.PricingPreferenceEnum.SYSTEM,
                RevSalesTrxn.ConfigurationExecutionEnum.SKIP,
                options,
                null,
                RevSalesTrxn.TaxPreferenceEnum.Skip,
                null,
                RevSalesTrxn.GroupRampActionEnum.DeleteProducts
            );
        if (resp != null && resp.isSuccess) {
            return null;
        }
        return resp == null || resp.errorResponse == null
            ? 'Could not remove the product from ramp segments.'
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

    private static String persistPatches(
        Id quoteId,
        Map<Id, Decimal> qtyByLine,
        Map<Id, Decimal> discountByLine
    ) {
        if (qtyByLine == null) {
            qtyByLine = new Map<Id, Decimal>();
        }
        if (discountByLine == null) {
            discountByLine = new Map<Id, Decimal>();
        }
        Set<Id> lineIds = new Set<Id>();
        lineIds.addAll(qtyByLine.keySet());
        lineIds.addAll(discountByLine.keySet());
        if (lineIds.isEmpty()) {
            return null;
        }
        if (Test.isRunningTest()) {
            List<QuoteLineItem> lines = [
                SELECT Id, Quantity, Discount
                FROM QuoteLineItem
                WHERE Id IN :lineIds
                AND QuoteId = :quoteId
                WITH USER_MODE
            ];
            for (QuoteLineItem line : lines) {
                if (qtyByLine.containsKey(line.Id)) {
                    line.Quantity = qtyByLine.get(line.Id);
                }
                if (discountByLine.containsKey(line.Id)) {
                    line.Discount = discountByLine.get(line.Id);
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
        RevSalesTrxn.RecordResource header = new RevSalesTrxn.RecordResource(
            Quote.getSObjectType(), 'PATCH', quoteId
        );
        header.fieldValues = new Map<String, Object>{ 'Status' => 'Draft' };
        records.add(new RevSalesTrxn.RecordWithReferenceRequest('refRampQuote', header));
        Integer n = 0;
        for (Id lineId : lineIds) {
            n++;
            Map<String, Object> fields = new Map<String, Object>();
            if (qtyByLine.containsKey(lineId)) {
                fields.put('Quantity', qtyByLine.get(lineId));
            }
            if (discountByLine.containsKey(lineId)) {
                fields.put('Discount', discountByLine.get(lineId));
            }
            RevSalesTrxn.RecordResource line = new RevSalesTrxn.RecordResource(
                QuoteLineItem.getSObjectType(), 'PATCH', lineId
            );
            line.fieldValues = fields;
            records.add(new RevSalesTrxn.RecordWithReferenceRequest('refRampLine' + n, line));
        }
        RevSalesTrxn.ConfigurationOptionsInput options =
            new RevSalesTrxn.ConfigurationOptionsInput();
        options.executeConfigurationRules = false;
        options.validateProductCatalog = false;
        options.validateAmendRenewCancel = false;
        options.addDefaultConfiguration = false;
            RevSalesTrxn.GraphRequest graph = new RevSalesTrxn.GraphRequest('McpRampPatch', records);
        String systemError = executePatchGraph(
            graph, options, RevSalesTrxn.PricingPreferenceEnum.SYSTEM);
        if (systemError == null) {
            return null;
        }
        String forceError = executePatchGraph(
            graph, options, RevSalesTrxn.PricingPreferenceEnum.FORCE);
        if (forceError == null) {
            return null;
        }
        String skipError = executePatchGraph(
            graph, options, RevSalesTrxn.PricingPreferenceEnum.SKIP);
        if (skipError == null) {
            return null;
        }
        return systemError;
    }

    private static String executePatchGraph(
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
            ? 'Could not apply ramp line updates.'
            : String.valueOf(resp.errorResponse);
    }

    private static Decimal discountAt(List<Decimal> discounts, Integer i) {
        if (discounts == null || i == null || i < 0 || i >= discounts.size()) {
            return null;
        }
        return discounts[i];
    }

    private static Object first(Map<String, Object> row, List<String> keys) {
        for (String key : keys) {
            if (row.containsKey(key) && row.get(key) != null) {
                return row.get(key);
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
        return String.valueOf(value).trim().equalsIgnoreCase('true');
    }

    private static String recapLine(QuoteLineGroup seg, String product, String bits) {
        return '- ' + nullToName(seg.Name)
            + ' (' + day(seg.StartDate) + '–' + day(seg.EndDate) + '): '
            + product + ' ' + bits;
    }

    private static String bitsFor(Decimal qty, Decimal discount, Boolean added) {
        List<String> bits = new List<String>();
        if (added) {
            bits.add('added');
        }
        if (qty != null) {
            bits.add('qty ' + RLM_MCP_RecordLinks.formatNumber(qty));
        }
        if (discount != null) {
            bits.add(RLM_MCP_RecordLinks.formatNumber(discount) + '% off');
        }
        return String.join(bits, ', ');
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
