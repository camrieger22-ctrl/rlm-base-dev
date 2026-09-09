/**
 * Single Place/FORCE edge for Bamboo Revenue Suite commercial mutates.
 * LWC and Commercial call here; do not add new Place graph builders on
 * RLM_BambooRevenueSuite.
 */
public with sharing class RLM_BambooSuitePlace {
    private static final String RAMP_API_VERSION = 'v67.0';

    /** Tests skip the Connect callout; Place still runs unless skipLineRampPlace. */
    @TestVisible
    static Boolean skipLineRampHttp = false;
    @TestVisible
    static Boolean skipLineRampPlace = false;
    @TestVisible
    static Boolean skipGroupRampClone = false;

    /**
     * Place Sales Transaction + FORCE pricing with Opportunity sync suspended.
     */
    public static void placeForce(
        Id quoteId,
        List<RevSalesTrxn.RecordWithReferenceRequest> nodes
    ) {
        RLM_BambooRevenueSuite.placeForcePublic(quoteId, nodes);
    }

    public static void placeForce(
        Id quoteId,
        List<RevSalesTrxn.RecordWithReferenceRequest> nodes,
        String contextId
    ) {
        RLM_BambooRevenueSuite.placeForceWithContextPublic(quoteId, nodes, contextId);
    }

    public static void placeForceWithGroupRamp(
        Id quoteId,
        List<RevSalesTrxn.RecordWithReferenceRequest> nodes,
        RevSalesTrxn.GroupRampActionEnum groupRamp
    ) {
        RLM_BambooRevenueSuite.placeForceWithGroupRampPublic(quoteId, nodes, groupRamp);
    }

    private static RevSalesTrxn.RecordWithReferenceRequest quotePatchNode(Id quoteId) {
        return new RevSalesTrxn.RecordWithReferenceRequest(
            'refQuote',
            new RevSalesTrxn.RecordResource(Quote.getSObjectType(), 'PATCH', quoteId)
        );
    }

    private static Decimal clampPercent(Decimal discountPercent) {
        Decimal pct = discountPercent == null ? 0 : discountPercent;
        if (pct < 0) {
            pct = 0;
        }
        if (pct > 100) {
            pct = 100;
        }
        return pct;
    }

    private static void assertOwnedLine(Id quoteId, Id lineId) {
        List<QuoteLineItem> owned = [
            SELECT Id
            FROM QuoteLineItem
            WHERE Id = :lineId AND QuoteId = :quoteId
            WITH USER_MODE
            LIMIT 1
        ];
        if (owned.isEmpty()) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Line does not belong to this option quote.'
            );
        }
    }

    /** Bulk ownership check — one query for a coalesced batch of line edits. */
    private static void assertOwnedLines(Id quoteId, Set<Id> lineIds) {
        Set<Id> owned = new Set<Id>();
        for (QuoteLineItem qi : [
            SELECT Id
            FROM QuoteLineItem
            WHERE Id IN :lineIds AND QuoteId = :quoteId
            WITH USER_MODE
        ]) {
            owned.add(qi.Id);
        }
        if (owned.size() != lineIds.size()) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'One or more lines do not belong to this option quote.'
            );
        }
    }

    private static void assertSuiteOptionQuote(Id quoteId, String capability) {
        Quote q = [
            SELECT Id, Name
            FROM Quote
            WHERE Id = :quoteId
            WITH USER_MODE
            LIMIT 1
        ];
        if (RLM_BambooRevenueSuite.optionLetterFromNamePublic(q.Name) == null) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Only Bamboo Revenue Suite option quotes (… — Option A/B/C) support ' +
                    capability +
                    '.'
            );
        }
    }

    /** When deleting a bundle root, include all configured child lines. */
    private static Set<Id> expandBundleDeleteIds(Id quoteId, Set<Id> requested) {
        Set<Id> expanded = new Set<Id>(requested);
        for (QuoteLineItem child : [
            SELECT Id
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId AND ParentQuoteLineItemId IN :requested
            WITH USER_MODE
        ]) {
            expanded.add(child.Id);
        }
        return expanded;
    }

    /** Persist quantity via Place + FORCE. Debounce in LWC (300–500ms). */
    @AuraEnabled
    public static RLM_BambooRevenueSuite.OptionDetailDTO updateLineQuantity(
        String quoteId,
        String lineId,
        Decimal quantity
    ) {
        Id qId = RLM_BambooRevenueSuite.parseIdPublic(quoteId, 'Quote');
        Id lId = RLM_BambooRevenueSuite.parseIdPublic(lineId, 'QuoteLineItem');
        Decimal qty = quantity == null || quantity <= 0 ? 1 : quantity;
        assertOwnedLine(qId, lId);

        List<RevSalesTrxn.RecordWithReferenceRequest> nodes =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        nodes.add(quotePatchNode(qId));

        RevSalesTrxn.RecordResource lineNode = new RevSalesTrxn.RecordResource(
            QuoteLineItem.getSObjectType(),
            'PATCH',
            lId
        );
        lineNode.fieldValues = new Map<String, Object>{ 'Quantity' => qty };
        nodes.add(new RevSalesTrxn.RecordWithReferenceRequest('refLine', lineNode));

        placeForce(qId, nodes);
        return RLM_BambooRevenueSuite.buildOptionDetailPublic(qId);
    }

    /**
     * Persist AE line discount % via QuoteLineItem.Discount + FORCE pricing.
     * Null / blank clears the AE discount.
     */
    @AuraEnabled
    public static RLM_BambooRevenueSuite.OptionDetailDTO updateLineDiscount(
        String quoteId,
        String lineId,
        Decimal discountPercent
    ) {
        Id qId = RLM_BambooRevenueSuite.parseIdPublic(quoteId, 'Quote');
        Id lId = RLM_BambooRevenueSuite.parseIdPublic(lineId, 'QuoteLineItem');
        Decimal pct = clampPercent(discountPercent);
        assertOwnedLine(qId, lId);

        List<RevSalesTrxn.RecordWithReferenceRequest> nodes =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        nodes.add(quotePatchNode(qId));

        RevSalesTrxn.RecordResource lineNode = new RevSalesTrxn.RecordResource(
            QuoteLineItem.getSObjectType(),
            'PATCH',
            lId
        );
        lineNode.fieldValues = new Map<String, Object>{
            'Discount' => pct,
            'PartnerDiscountPercent' => null
        };
        nodes.add(new RevSalesTrxn.RecordWithReferenceRequest('refLine', lineNode));

        placeForce(qId, nodes);
        return RLM_BambooRevenueSuite.buildOptionDetailPublic(qId);
    }

    /**
     * One staged line edit. A null quantity or discountPercent leaves that
     * field untouched, so the LWC can stage the two independently.
     */
    public class LineEditInput {
        @AuraEnabled
        public String lineId { get; set; }
        @AuraEnabled
        public Decimal quantity { get; set; }
        @AuraEnabled
        public Decimal discountPercent { get; set; }
    }

    /**
     * Apply several staged quantity / discount edits in ONE Place + FORCE.
     * The LWC coalesces keystrokes into this call so editing a grid of lines
     * costs one reprice instead of one per field.
     */
    @AuraEnabled
    public static RLM_BambooRevenueSuite.OptionDetailDTO updateLines(
        String quoteId,
        List<LineEditInput> edits
    ) {
        Id qId = RLM_BambooRevenueSuite.parseIdPublic(quoteId, 'Quote');

        // Last value wins per line so a batch never PATCHes the same line twice.
        Map<Id, LineEditInput> byLine = new Map<Id, LineEditInput>();
        for (LineEditInput edit : edits == null ? new List<LineEditInput>() : edits) {
            if (edit == null || String.isBlank(edit.lineId)) {
                continue;
            }
            if (edit.quantity == null && edit.discountPercent == null) {
                continue;
            }
            Id lId = RLM_BambooRevenueSuite.parseIdPublic(
                edit.lineId,
                'QuoteLineItem'
            );
            LineEditInput merged = byLine.containsKey(lId)
                ? byLine.get(lId)
                : new LineEditInput();
            merged.lineId = edit.lineId;
            if (edit.quantity != null) {
                merged.quantity = edit.quantity;
            }
            if (edit.discountPercent != null) {
                merged.discountPercent = edit.discountPercent;
            }
            byLine.put(lId, merged);
        }
        if (byLine.isEmpty()) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'No line edits to apply.'
            );
        }
        assertOwnedLines(qId, byLine.keySet());

        List<RevSalesTrxn.RecordWithReferenceRequest> nodes =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        nodes.add(quotePatchNode(qId));
        Integer i = 0;
        for (Id lId : byLine.keySet()) {
            LineEditInput edit = byLine.get(lId);
            Map<String, Object> lineFields = new Map<String, Object>();
            if (edit.quantity != null) {
                lineFields.put('Quantity', edit.quantity <= 0 ? 1 : edit.quantity);
            }
            if (edit.discountPercent != null) {
                lineFields.put('Discount', clampPercent(edit.discountPercent));
                lineFields.put('PartnerDiscountPercent', null);
            }
            RevSalesTrxn.RecordResource lineNode = new RevSalesTrxn.RecordResource(
                QuoteLineItem.getSObjectType(),
                'PATCH',
                lId
            );
            lineNode.fieldValues = lineFields;
            nodes.add(
                new RevSalesTrxn.RecordWithReferenceRequest('refEdit' + i++, lineNode)
            );
        }

        placeForce(qId, nodes);
        return RLM_BambooRevenueSuite.buildOptionDetailPublic(qId);
    }

    /**
     * Broadcast the same AE Discount % to every line on a suite option quote
     * via Place + FORCE.
     */
    @AuraEnabled
    public static RLM_BambooRevenueSuite.OptionDetailDTO updateOptionDiscount(
        String quoteId,
        Decimal discountPercent
    ) {
        Id qId = RLM_BambooRevenueSuite.parseIdPublic(quoteId, 'Quote');
        Decimal pct = clampPercent(discountPercent);
        assertSuiteOptionQuote(qId, 'option discounts');

        List<QuoteLineItem> lines = [
            SELECT Id
            FROM QuoteLineItem
            WHERE QuoteId = :qId
            WITH USER_MODE
        ];
        if (lines.isEmpty()) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Add products before applying an option discount.'
            );
        }

        List<RevSalesTrxn.RecordWithReferenceRequest> nodes =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        nodes.add(quotePatchNode(qId));
        Integer i = 0;
        for (QuoteLineItem qi : lines) {
            RevSalesTrxn.RecordResource lineNode = new RevSalesTrxn.RecordResource(
                QuoteLineItem.getSObjectType(),
                'PATCH',
                qi.Id
            );
            lineNode.fieldValues = new Map<String, Object>{
                'Discount' => pct,
                'PartnerDiscountPercent' => null
            };
            nodes.add(
                new RevSalesTrxn.RecordWithReferenceRequest('refDisc' + i++, lineNode)
            );
        }
        placeForce(qId, nodes);
        return RLM_BambooRevenueSuite.buildOptionDetailPublic(qId);
    }

    /**
     * Set the same seat count on every line of a suite option quote via PST + FORCE.
     */
    @AuraEnabled
    public static RLM_BambooRevenueSuite.OptionDetailDTO updateOptionSeatCount(
        String quoteId,
        Decimal seats
    ) {
        Id qId = RLM_BambooRevenueSuite.parseIdPublic(quoteId, 'Quote');
        Decimal qty = seats == null || seats <= 0 ? null : seats;
        if (qty == null) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Seat count must be greater than zero.'
            );
        }
        assertSuiteOptionQuote(qId, 'bulk seat updates');

        List<QuoteLineItem> lines = [
            SELECT Id
            FROM QuoteLineItem
            WHERE QuoteId = :qId
            WITH USER_MODE
        ];
        if (lines.isEmpty()) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Add products before changing seat count.'
            );
        }

        List<RevSalesTrxn.RecordWithReferenceRequest> nodes =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        nodes.add(quotePatchNode(qId));
        Integer i = 0;
        for (QuoteLineItem qi : lines) {
            RevSalesTrxn.RecordResource lineNode = new RevSalesTrxn.RecordResource(
                QuoteLineItem.getSObjectType(),
                'PATCH',
                qi.Id
            );
            lineNode.fieldValues = new Map<String, Object>{ 'Quantity' => qty };
            nodes.add(
                new RevSalesTrxn.RecordWithReferenceRequest('refSeat' + i++, lineNode)
            );
        }
        placeForce(qId, nodes);
        return RLM_BambooRevenueSuite.buildOptionDetailPublic(qId);
    }

    /** Re-run System pricing on the option quote (FORCE) without structural changes. */
    @AuraEnabled
    public static RLM_BambooRevenueSuite.OptionDetailDTO repriceOption(String quoteId) {
        Id qId = RLM_BambooRevenueSuite.parseIdPublic(quoteId, 'Quote');
        List<QuoteLineItem> lines = [
            SELECT Id, Quantity
            FROM QuoteLineItem
            WHERE QuoteId = :qId
            WITH USER_MODE
        ];
        if (lines.isEmpty()) {
            return RLM_BambooRevenueSuite.buildOptionDetailPublic(qId);
        }

        List<RevSalesTrxn.RecordWithReferenceRequest> nodes =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        nodes.add(quotePatchNode(qId));
        Integer i = 0;
        for (QuoteLineItem qi : lines) {
            RevSalesTrxn.RecordResource lineNode = new RevSalesTrxn.RecordResource(
                QuoteLineItem.getSObjectType(),
                'PATCH',
                qi.Id
            );
            lineNode.fieldValues = new Map<String, Object>{
                'Quantity' => qi.Quantity != null ? qi.Quantity : 1
            };
            nodes.add(
                new RevSalesTrxn.RecordWithReferenceRequest('refLine' + i++, lineNode)
            );
        }
        placeForce(qId, nodes);
        return RLM_BambooRevenueSuite.buildOptionDetailPublic(qId);
    }

    /** Remove a line via Place DELETE + FORCE reprice. */
    @AuraEnabled
    public static RLM_BambooRevenueSuite.OptionDetailDTO removeLine(
        String quoteId,
        String lineId
    ) {
        return removeLines(quoteId, new List<String>{ lineId });
    }

    /** Remove one or more lines in a single Place DELETE + FORCE reprice. */
    @AuraEnabled
    public static RLM_BambooRevenueSuite.OptionDetailDTO removeLines(
        String quoteId,
        List<String> lineIds
    ) {
        Id qId = RLM_BambooRevenueSuite.parseIdPublic(quoteId, 'Quote');
        if (lineIds == null || lineIds.isEmpty()) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Select at least one line to delete.'
            );
        }
        Set<Id> requested = new Set<Id>();
        for (String raw : lineIds) {
            if (String.isBlank(raw)) {
                continue;
            }
            requested.add(RLM_BambooRevenueSuite.parseIdPublic(raw, 'QuoteLineItem'));
        }
        if (requested.isEmpty()) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Select at least one line to delete.'
            );
        }

        List<QuoteLineItem> owned = [
            SELECT Id
            FROM QuoteLineItem
            WHERE Id IN :requested AND QuoteId = :qId
            WITH USER_MODE
        ];
        if (owned.size() != requested.size()) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'One or more lines do not belong to this option quote.'
            );
        }

        requested = expandBundleDeleteIds(qId, requested);

        List<RevSalesTrxn.RecordWithReferenceRequest> nodes =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        nodes.add(quotePatchNode(qId));
        owned = [
            SELECT Id
            FROM QuoteLineItem
            WHERE Id IN :requested AND QuoteId = :qId
            WITH USER_MODE
        ];

        Integer i = 0;
        for (QuoteLineItem qi : owned) {
            nodes.add(
                new RevSalesTrxn.RecordWithReferenceRequest(
                    'refDelete' + i,
                    new RevSalesTrxn.RecordResource(
                        QuoteLineItem.getSObjectType(),
                        'DELETE',
                        qi.Id
                    )
                )
            );
            i++;
        }
        placeForce(qId, nodes);
        RLM_BambooRevenueSuite.OptionDetailDTO detail =
            RLM_BambooRevenueSuite.buildOptionDetailPublic(qId);
        if (detail != null && (detail.lines == null || detail.lines.isEmpty())) {
            RLM_BambooRevenueSuite.zeroOpportunityAmountForOptionIfWinningPublic(qId);
        }
        return detail;
    }

    private static void placeConfigure(
        Id quoteId,
        List<RevSalesTrxn.RecordWithReferenceRequest> nodes
    ) {
        RLM_BambooRevenueSuite.placeConfigurePublic(quoteId, nodes);
    }

    private static String quoteCurrency(Quote q) {
        String ccy = String.isNotBlank(q.CurrencyIsoCode)
            ? q.CurrencyIsoCode
            : (q.Opportunity != null ? q.Opportunity.CurrencyIsoCode : null);
        return String.isBlank(ccy) ? 'USD' : ccy;
    }

    /**
     * Add one or more catalog lines in a single Place + FORCE.
     */
    @AuraEnabled
    public static RLM_BambooRevenueSuite.AddLineResultDTO addProductLines(
        String quoteId,
        List<RLM_BambooRevenueSuite.LineInputDTO> lines,
        Integer termMonths,
        String startDateIso,
        String billingFrequency
    ) {
        Id qId = RLM_BambooRevenueSuite.parseIdPublic(quoteId, 'Quote');
        rejectUngroupedAddOnRampedQuote(qId);
        if (lines == null || lines.isEmpty()) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'At least one product line is required.'
            );
        }

        Integer months = RLM_BambooRevenueSuite.normalizeTermPublic(termMonths);
        Quote q = [
            SELECT Id, Pricebook2Id, CurrencyIsoCode, Opportunity.CurrencyIsoCode
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        String ccy = quoteCurrency(q);
        Date startDate = RLM_BambooRevenueSuite.parseStartDatePublic(startDateIso);
        Date endDate = RLM_BambooRevenueSuite.computeEndDatePublic(startDate, months);
        String billing = RLM_BambooRevenueSuite.normalizeBillingPublic(billingFrequency);
        Id treatmentId = RLM_BambooRevenueSuite.resolveBillingTreatmentIdPublic(ccy);
        Set<Id> beforeIds = RLM_BambooRevenueSuite.existingLineIdsPublic(qId);

        List<RevSalesTrxn.RecordWithReferenceRequest> nodes =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        nodes.add(quotePatchNode(q.Id));

        Integer i = 0;
        for (RLM_BambooRevenueSuite.LineInputDTO raw : lines) {
            if (raw == null || String.isBlank(raw.sku)) {
                throw new RLM_BambooRevenueSuite.SuiteException(
                    'SKU is required for every line.'
                );
            }
            Decimal qty = raw.quantity == null || raw.quantity <= 0 ? 1 : raw.quantity;
            PricebookEntry pbe = RLM_BambooRevenueSuite.resolvePbePublic(
                raw.sku.trim(),
                ccy,
                months
            );
            Map<String, Object> lineFields = new Map<String, Object>{
                'QuoteId' => String.valueOf(q.Id),
                'Product2Id' => pbe.Product2Id,
                'PricebookEntryId' => pbe.Id,
                'Quantity' => qty,
                'UnitPrice' => pbe.UnitPrice != null ? pbe.UnitPrice : 0,
                'StartDate' => String.valueOf(startDate),
                'BillingFrequency' => billing,
                'BillingTreatmentId' => String.valueOf(treatmentId),
                'PeriodBoundary' => 'Anniversary'
            };
            if (endDate != null) {
                lineFields.put('EndDate', String.valueOf(endDate));
            }
            RevSalesTrxn.RecordResource lineNode = new RevSalesTrxn.RecordResource(
                QuoteLineItem.getSObjectType(),
                'POST'
            );
            lineNode.fieldValues = lineFields;
            nodes.add(
                new RevSalesTrxn.RecordWithReferenceRequest('refLine' + i, lineNode)
            );
            i++;
        }

        placeForce(qId, nodes);

        List<Id> created = new List<Id>();
        for (QuoteLineItem qi : [
            SELECT Id
            FROM QuoteLineItem
            WHERE QuoteId = :qId
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ]) {
            if (beforeIds == null || !beforeIds.contains(qi.Id)) {
                created.add(qi.Id);
            }
        }
        if (created.isEmpty()) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Lines were priced but could not be resolved on the quote.'
            );
        }

        RLM_BambooRevenueSuite.AddLineResultDTO result =
            new RLM_BambooRevenueSuite.AddLineResultDTO();
        result.lineIds = created;
        result.lineId = created[created.size() - 1];
        result.option = RLM_BambooRevenueSuite.buildOptionDetailPublic(qId);
        return result;
    }

    @AuraEnabled
    public static RLM_BambooRevenueSuite.AddLineResultDTO addProductLinesBySku(
        String quoteId,
        List<String> skus,
        List<Decimal> quantities,
        Integer termMonths,
        String startDateIso,
        String billingFrequency
    ) {
        if (skus == null || skus.isEmpty()) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'At least one product line is required.'
            );
        }
        List<RLM_BambooRevenueSuite.LineInputDTO> lines =
            new List<RLM_BambooRevenueSuite.LineInputDTO>();
        for (Integer i = 0; i < skus.size(); i++) {
            String sku = skus[i];
            if (String.isBlank(sku)) {
                continue;
            }
            Decimal qty = 1;
            if (quantities != null && i < quantities.size() && quantities[i] != null) {
                qty = quantities[i];
            }
            RLM_BambooRevenueSuite.LineInputDTO line =
                new RLM_BambooRevenueSuite.LineInputDTO();
            line.sku = sku.trim();
            line.quantity = qty;
            lines.add(line);
        }
        return addProductLines(
            quoteId,
            lines,
            termMonths,
            startDateIso,
            billingFrequency
        );
    }

    /**
     * Thin transport: Place AddProducts into the selected ramp segment
     * (and later years when subsequent is true). Dates come from the groups.
     */
    @AuraEnabled
    public static RLM_BambooRevenueSuite.AddLineResultDTO addProductLinesToRampSegments(
        String quoteId,
        List<String> skus,
        List<Decimal> quantities,
        String segmentGroupId,
        Boolean subsequent,
        String billingFrequency
    ) {
        Id qId = RLM_BambooRevenueSuite.parseIdPublic(quoteId, 'Quote');
        Id gId = RLM_BambooRevenueSuite.parseIdPublic(segmentGroupId, 'Ramp segment');
        if (skus == null || skus.isEmpty()) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'At least one product line is required.'
            );
        }

        List<QuoteLineGroup> targets = resolveAddProductTargets(
            qId,
            gId,
            subsequent == true
        );
        Quote q = [
            SELECT Id, Pricebook2Id, CurrencyIsoCode, Opportunity.CurrencyIsoCode
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        String ccy = quoteCurrency(q);
        String billing = RLM_BambooRevenueSuite.normalizeBillingPublic(billingFrequency);
        Id treatmentId = RLM_BambooRevenueSuite.resolveBillingTreatmentIdPublic(ccy);
        Set<Id> beforeIds = RLM_BambooRevenueSuite.existingLineIdsPublic(qId);

        List<RevSalesTrxn.RecordWithReferenceRequest> nodes =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        nodes.add(quotePatchNode(q.Id));

        Integer gi = 0;
        for (QuoteLineGroup grp : targets) {
            nodes.add(
                new RevSalesTrxn.RecordWithReferenceRequest(
                    'refGrp' + gi,
                    new RevSalesTrxn.RecordResource(
                        QuoteLineGroup.getSObjectType(),
                        'PATCH',
                        grp.Id
                    )
                )
            );
            Integer li = 0;
            for (Integer s = 0; s < skus.size(); s++) {
                String sku = skus[s];
                if (String.isBlank(sku)) {
                    continue;
                }
                Decimal qty = 1;
                if (quantities != null && s < quantities.size() && quantities[s] != null) {
                    qty = quantities[s];
                }
                if (qty <= 0) {
                    qty = 1;
                }
                Integer pbeMonths = pbeMonthsForSegment(grp);
                PricebookEntry pbe = RLM_BambooRevenueSuite.resolvePbePublic(
                    sku.trim(),
                    ccy,
                    pbeMonths
                );
                Map<String, Object> lineFields = new Map<String, Object>{
                    'QuoteId' => '@{refQuote.id}',
                    'Product2Id' => pbe.Product2Id,
                    'PricebookEntryId' => pbe.Id,
                    'Quantity' => qty,
                    'UnitPrice' => pbe.UnitPrice != null ? pbe.UnitPrice : 0,
                    'StartDate' => String.valueOf(grp.StartDate),
                    'BillingFrequency' => billing,
                    'BillingTreatmentId' => String.valueOf(treatmentId),
                    'PeriodBoundary' => 'Anniversary',
                    'QuoteLineGroupId' => String.valueOf(grp.Id)
                };
                if (grp.EndDate != null) {
                    lineFields.put('EndDate', String.valueOf(grp.EndDate));
                }
                RevSalesTrxn.RecordResource lineNode = new RevSalesTrxn.RecordResource(
                    QuoteLineItem.getSObjectType(),
                    'POST'
                );
                lineNode.fieldValues = lineFields;
                nodes.add(
                    new RevSalesTrxn.RecordWithReferenceRequest(
                        'refLine' + gi + '_' + li,
                        lineNode
                    )
                );
                li++;
            }
            gi++;
        }

        placeForceWithGroupRamp(
            qId,
            nodes,
            RevSalesTrxn.GroupRampActionEnum.AddProducts
        );

        List<Id> created = new List<Id>();
        for (QuoteLineItem qi : [
            SELECT Id
            FROM QuoteLineItem
            WHERE QuoteId = :qId
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ]) {
            if (beforeIds == null || !beforeIds.contains(qi.Id)) {
                created.add(qi.Id);
            }
        }
        if (created.isEmpty()) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Lines were priced but could not be resolved on the quote.'
            );
        }

        RLM_BambooRevenueSuite.AddLineResultDTO result =
            new RLM_BambooRevenueSuite.AddLineResultDTO();
        result.lineIds = created;
        result.lineId = created[created.size() - 1];
        result.option = RLM_BambooRevenueSuite.buildOptionDetailPublic(qId);
        return result;
    }

    private static List<QuoteLineGroup> resolveAddProductTargets(
        Id quoteId,
        Id segmentGroupId,
        Boolean subsequent
    ) {
        List<QuoteLineGroup> groups = [
            SELECT Id, Name, Type, IsRamped, SegmentType, StartDate, EndDate
            FROM QuoteLineGroup
            WHERE QuoteId = :quoteId
            WITH USER_MODE
            ORDER BY StartDate ASC NULLS LAST, SortOrder ASC NULLS LAST
        ];
        QuoteLineGroup selected = null;
        List<QuoteLineGroup> ramped = new List<QuoteLineGroup>();
        for (QuoteLineGroup grp : groups) {
            if (grp.Type == 'RampScheduleGroup') {
                continue;
            }
            if (grp.IsRamped != true) {
                continue;
            }
            ramped.add(grp);
            if (grp.Id == segmentGroupId) {
                selected = grp;
            }
        }
        if (selected == null) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Select a ramp year on this option, then add the product into that segment.'
            );
        }
        List<QuoteLineGroup> targets = new List<QuoteLineGroup>();
        Boolean seen = false;
        for (QuoteLineGroup grp : ramped) {
            if (grp.Id == selected.Id) {
                seen = true;
            }
            if (!subsequent) {
                if (grp.Id == selected.Id) {
                    targets.add(grp);
                    break;
                }
            } else if (seen) {
                targets.add(grp);
            }
        }
        if (targets.isEmpty()) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'No ramp segments matched that year.'
            );
        }
        return targets;
    }

    private static void rejectUngroupedAddOnRampedQuote(Id quoteId) {
        List<QuoteLineGroup> ramped = [
            SELECT Id
            FROM QuoteLineGroup
            WHERE QuoteId = :quoteId AND IsRamped = TRUE
            WITH USER_MODE
            LIMIT 1
        ];
        if (!ramped.isEmpty()) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'This option has a ramp schedule. Select a year, then add the product into that segment.'
            );
        }
    }

    private static Integer pbeMonthsForSegment(QuoteLineGroup grp) {
        if (grp == null) {
            return 12;
        }
        String t = grp.SegmentType == null ? '' : grp.SegmentType.toUpperCase();
        if (t == 'YEARLY' || t == 'ANNUAL') {
            return 12;
        }
        if (grp.StartDate != null && grp.EndDate != null) {
            Integer months = grp.StartDate.monthsBetween(grp.EndDate.addDays(1));
            if (months >= 1) {
                return months;
            }
        }
        return 12;
    }

    /**
     * Thin transport: Connect ramp-deal-create → Place FORCE with the returned
     * context id. Segment type YEARLY / CUSTOM / FREE_TRIAL; optional trial days.
     */
    public static RLM_BambooRevenueSuite.OptionDetailDTO createLineRamp(
        String quoteId,
        String lineId,
        Integer termMonths
    ) {
        return createLineRamp(quoteId, lineId, termMonths, 'YEARLY', null);
    }

    @AuraEnabled
    public static RLM_BambooRevenueSuite.OptionDetailDTO createLineRamp(
        String quoteId,
        String lineId,
        Integer termMonths,
        String segmentType,
        Integer trialDays
    ) {
        Id qId = RLM_BambooRevenueSuite.parseIdPublic(quoteId, 'Quote');
        Id lId = RLM_BambooRevenueSuite.parseIdPublic(lineId, 'Quote line');

        List<QuoteLineItem> rows = [
            SELECT
                Id,
                QuoteId,
                ParentQuoteLineItemId,
                RampIdentifier,
                UnitPriceUplift,
                Product2.CanRamp,
                Product2.Name
            FROM QuoteLineItem
            WHERE Id = :lId AND QuoteId = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Quote line was not found on this option.'
            );
        }
        QuoteLineItem qi = rows[0];
        if (qi.ParentQuoteLineItemId != null) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Bundle component lines cannot be line-ramped.'
            );
        }
        if (qi.Product2 == null || qi.Product2.CanRamp != true) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'This product is not rampable. Only subscription SKUs with Ramp enabled can use line ramp.'
            );
        }
        if (String.isNotBlank(qi.RampIdentifier)) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'This line already has a ramp schedule.'
            );
        }

        Integer months = termMonths != null
            ? termMonths
            : RLM_BambooRevenueSuite.inferTermMonthsPublic(qId);
        months = months < 1 ? 1 : months;
        String type = String.isBlank(segmentType)
            ? 'YEARLY'
            : segmentType.trim().toUpperCase();
        if (type != 'YEARLY' && type != 'CUSTOM' && type != 'FREE_TRIAL') {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Segment type must be YEARLY, CUSTOM, or FREE_TRIAL.'
            );
        }
        Integer trial = trialDays == null || trialDays < 0 ? 0 : trialDays;
        Integer yearlySegs = months / 12;
        if (Math.mod(months, 12) > 0) {
            yearlySegs++;
        }
        if (trial > 0) {
            yearlySegs++;
        }
        if (type == 'YEARLY' && yearlySegs < 2) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Yearly line ramp needs at least two segments. Use 24+ months, or 12 months plus a trial.'
            );
        }
        if (type == 'CUSTOM' && months < 2) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Custom line ramp needs a duration of at least 2 months.'
            );
        }

        // Aura/Lightning already has uncommitted DML; getContent/Connect
        // must run in a fresh Queueable (API session, callout then Place).
        if (
            !skipLineRampHttp &&
            !Test.isRunningTest() &&
            !System.isQueueable() &&
            !System.isFuture() &&
            !System.isBatch()
        ) {
            System.enqueueJob(new LineRampQueueable(qId, lId, months, type, trial));
            return RLM_BambooRevenueSuite.buildOptionDetailPublic(qId);
        }

        if (!skipLineRampHttp) {
            if (qi.UnitPriceUplift != null) {
                clearUnitPriceUplift(lId);
            }
            String contextId = postRampDealCreate(qId, lId, months, type, trial);
            if (String.isBlank(contextId)) {
                throw new RLM_BambooRevenueSuite.SuiteException(
                    'ramp-deal-create did not return a transaction context.'
                );
            }
            if (!skipLineRampPlace) {
                List<RevSalesTrxn.RecordWithReferenceRequest> nodes =
                    new List<RevSalesTrxn.RecordWithReferenceRequest>();
                nodes.add(quotePatchNode(qId));
                placeForce(qId, nodes, contextId);
            }
        }

        return RLM_BambooRevenueSuite.buildOptionDetailPublic(qId);
    }

    /**
     * Latest LineRampQueueable failure, if any. LWC poll uses this so a
     * Connect rejection is not reported as a generic timeout.
     */
    @AuraEnabled
    public static String getLatestRampJobError(Long sinceMs) {
        DateTime since = DateTime.now().addMinutes(-2);
        if (sinceMs != null) {
            since = DateTime.newInstanceGmt(1970, 1, 1, 0, 0, 0)
                .addSeconds(Integer.valueOf(sinceMs / 1000));
        }
        List<AsyncApexJob> jobs = [
            SELECT ExtendedStatus, Status
            FROM AsyncApexJob
            WHERE
                ApexClass.Name = 'RLM_BambooSuitePlace'
                AND Status IN ('Failed', 'Aborted')
                AND CreatedDate >= :since
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (jobs.isEmpty() || String.isBlank(jobs[0].ExtendedStatus)) {
            return null;
        }
        return jobs[0].ExtendedStatus;
    }

    /**
     * Thin transport (Multiple Ramp Schedules OFF): GroupAll → Place FORCE
     * IsRamped/Yearly PATCH (not EditGroup) → clone last segment for remaining years.
     */
    @AuraEnabled
    public static RLM_BambooRevenueSuite.OptionDetailDTO createGroupRamp(
        String quoteId,
        Integer termMonths,
        String startDateIso
    ) {
        Id qId = RLM_BambooRevenueSuite.parseIdPublic(quoteId, 'Quote');
        Integer months = termMonths != null
            ? termMonths
            : RLM_BambooRevenueSuite.inferTermMonthsPublic(qId);
        months = RLM_BambooRevenueSuite.normalizeTermPublic(months);
        if (months < 12) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Yearly group ramp needs a 1-year or longer term. Change the option term first.'
            );
        }

        List<QuoteLineItem> lines = [
            SELECT Id, RampIdentifier, QuoteLineGroupId, StartDate
            FROM QuoteLineItem
            WHERE QuoteId = :qId
            WITH USER_MODE
            ORDER BY StartDate ASC NULLS LAST, CreatedDate ASC
        ];
        if (lines.isEmpty()) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Add products before creating a group ramp schedule.'
            );
        }
        for (QuoteLineItem qi : lines) {
            if (String.isNotBlank(qi.RampIdentifier) && qi.QuoteLineGroupId == null) {
                throw new RLM_BambooRevenueSuite.SuiteException(
                    'This option already has a line ramp. Remove those segments before creating a group ramp.'
                );
            }
        }

        List<QuoteLineGroup> existing = queryRampGroups(qId);
        for (QuoteLineGroup grp : existing) {
            if (grp.IsRamped == true) {
                throw new RLM_BambooRevenueSuite.SuiteException(
                    'This option already has a group ramp schedule.'
                );
            }
        }

        Date startDate = RLM_BambooRevenueSuite.parseStartDatePublic(startDateIso);
        if (startDate == null && lines[0].StartDate != null) {
            startDate = lines[0].StartDate;
        }
        if (startDate == null) {
            startDate = Date.today();
        }
        Date yearEnd = startDate.addDays(364);

        if (existing.isEmpty()) {
            RevSalesTrxn.RecordResource gPost = new RevSalesTrxn.RecordResource(
                QuoteLineGroup.getSObjectType(),
                'POST',
                'GroupAll',
                null
            );
            gPost.fieldValues = new Map<String, Object>{
                'Name' => 'Year 1',
                'QuoteId' => '@{refQuote.id}'
            };
            placeForce(
                qId,
                new List<RevSalesTrxn.RecordWithReferenceRequest>{
                    quotePatchNode(qId),
                    new RevSalesTrxn.RecordWithReferenceRequest('refG1', gPost)
                }
            );
        }

        QuoteLineGroup first = firstConvertibleGroup(qId);
        if (first == null) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'GroupAll did not create a QuoteLineGroup on this option.'
            );
        }

        RevSalesTrxn.RecordResource gPatch = new RevSalesTrxn.RecordResource(
            QuoteLineGroup.getSObjectType(),
            'PATCH',
            first.Id
        );
        gPatch.fieldValues = new Map<String, Object>{
            'IsRamped' => true,
            'SegmentType' => 'Yearly',
            'SortOrder' => 1,
            'Name' => 'Year 1',
            'StartDate' => String.valueOf(startDate),
            'EndDate' => String.valueOf(yearEnd)
        };
        placeForce(
            qId,
            new List<RevSalesTrxn.RecordWithReferenceRequest>{
                quotePatchNode(qId),
                new RevSalesTrxn.RecordWithReferenceRequest('refRampG1', gPatch)
            }
        );

        Integer years = months / 12;
        if (!skipGroupRampClone && years > 1) {
            System.enqueueJob(new GroupRampCloneQueueable(qId, years - 1));
        }

        return RLM_BambooRevenueSuite.buildOptionDetailPublic(qId);
    }

    public class LineRampQueueable implements Queueable, Database.AllowsCallouts {
        private Id quoteId;
        private Id lineId;
        private Integer termMonths;
        private String segmentType;
        private Integer trialDays;

        public LineRampQueueable(Id quoteId, Id lineId, Integer termMonths) {
            this(quoteId, lineId, termMonths, 'YEARLY', 0);
        }

        public LineRampQueueable(
            Id quoteId,
            Id lineId,
            Integer termMonths,
            String segmentType,
            Integer trialDays
        ) {
            this.quoteId = quoteId;
            this.lineId = lineId;
            this.termMonths = termMonths;
            this.segmentType = segmentType;
            this.trialDays = trialDays;
        }

        public void execute(QueueableContext ctx) {
            createLineRamp(
                String.valueOf(quoteId),
                String.valueOf(lineId),
                termMonths,
                segmentType,
                trialDays
            );
        }
    }

    public class GroupRampCloneQueueable implements Queueable, Database.AllowsCallouts {
        private Id quoteId;
        private Integer remainingClones;

        public GroupRampCloneQueueable(Id quoteId, Integer remainingClones) {
            this.quoteId = quoteId;
            this.remainingClones = remainingClones;
        }

        public void execute(QueueableContext ctx) {
            if (quoteId == null || remainingClones == null || remainingClones <= 0) {
                return;
            }
            Id lastId = lastSegmentGroupId(quoteId);
            if (lastId == null) {
                throw new RLM_BambooRevenueSuite.SuiteException(
                    'Could not resolve the last ramp segment to clone.'
                );
            }
            cloneLastRampSegment(quoteId, lastId);
            if (remainingClones > 1) {
                System.enqueueJob(
                    new GroupRampCloneQueueable(quoteId, remainingClones - 1)
                );
            }
        }
    }

    @AuraEnabled
    public static RLM_BambooRevenueSuite.AddLineResultDTO addWorkforcePackage(
        String quoteId,
        String planSku,
        Decimal quantity,
        Integer termMonths,
        String startDateIso,
        String billingFrequency
    ) {
        Id qId = RLM_BambooRevenueSuite.parseIdPublic(quoteId, 'Quote');
        rejectUngroupedAddOnRampedQuote(qId);
        String plan = String.isBlank(planSku)
            ? RLM_BambooRevenueSuite.workforceDefaultPlan()
            : planSku.trim().toUpperCase();
        if (!RLM_BambooRevenueSuite.isWorkforcePlanSku(plan)) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Workforce plan must be BAMBOO-CORE, BAMBOO-PRO, or BAMBOO-ELITE.'
            );
        }
        if (plan != RLM_BambooRevenueSuite.workforceDefaultPlan()) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Workforce Path A currently expands with Pro (catalog default). ' +
                    'Core/Elite under the package needs configurator plan selection — ' +
                    'add those plans a-la-carte with Payroll + Benefits for Path B, or pick Pro.'
            );
        }
        Decimal qty = quantity == null || quantity <= 0 ? 1 : quantity;
        Integer months = RLM_BambooRevenueSuite.normalizeTermPublic(termMonths);

        Quote q = [
            SELECT Id, Pricebook2Id, CurrencyIsoCode, Opportunity.CurrencyIsoCode
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        String ccy = quoteCurrency(q);
        Date startDate = RLM_BambooRevenueSuite.parseStartDatePublic(startDateIso);
        Date endDate = RLM_BambooRevenueSuite.computeEndDatePublic(startDate, months);
        String billing = RLM_BambooRevenueSuite.normalizeBillingPublic(billingFrequency);
        Id treatmentId = RLM_BambooRevenueSuite.resolveBillingTreatmentIdPublic(ccy);
        String pkgSku = RLM_BambooRevenueSuite.workforcePkgSku();
        PricebookEntry pkgPbe = RLM_BambooRevenueSuite.resolvePbePublic(
            pkgSku,
            ccy,
            months
        );
        Set<Id> beforeIds = RLM_BambooRevenueSuite.existingLineIdsPublic(qId);

        List<RevSalesTrxn.RecordWithReferenceRequest> nodes =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        nodes.add(quotePatchNode(q.Id));

        Map<String, Object> pkgFields = new Map<String, Object>{
            'QuoteId' => String.valueOf(q.Id),
            'Product2Id' => pkgPbe.Product2Id,
            'PricebookEntryId' => pkgPbe.Id,
            'Quantity' => qty,
            'UnitPrice' => pkgPbe.UnitPrice != null ? pkgPbe.UnitPrice : 0,
            'StartDate' => String.valueOf(startDate),
            'BillingFrequency' => billing,
            'BillingTreatmentId' => String.valueOf(treatmentId),
            'PeriodBoundary' => 'Anniversary'
        };
        if (endDate != null) {
            pkgFields.put('EndDate', String.valueOf(endDate));
        }
        RevSalesTrxn.RecordResource pkgNode = new RevSalesTrxn.RecordResource(
            QuoteLineItem.getSObjectType(),
            'POST'
        );
        pkgNode.fieldValues = pkgFields;
        nodes.add(new RevSalesTrxn.RecordWithReferenceRequest('refPkg', pkgNode));

        placeConfigure(qId, nodes);
        stampCommercialTermsOnAllLines(qId, startDate, endDate, billing, treatmentId);

        Id pkgLineId = null;
        for (QuoteLineItem qi : [
            SELECT Id, Product2.StockKeepingUnit, ParentQuoteLineItemId
            FROM QuoteLineItem
            WHERE QuoteId = :qId
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ]) {
            if (beforeIds != null && beforeIds.contains(qi.Id)) {
                continue;
            }
            if (
                qi.Product2 != null &&
                qi.Product2.StockKeepingUnit == pkgSku &&
                qi.ParentQuoteLineItemId == null
            ) {
                pkgLineId = qi.Id;
                break;
            }
        }
        if (pkgLineId == null) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Workforce package line was not created. Check PCM / configurator setup.'
            );
        }

        RLM_BambooRevenueSuite.AddLineResultDTO result =
            new RLM_BambooRevenueSuite.AddLineResultDTO();
        result.lineId = pkgLineId;
        result.lineIds = new List<Id>{ pkgLineId };
        result.option = RLM_BambooRevenueSuite.buildOptionDetailPublic(qId);
        return result;
    }

    @AuraEnabled
    public static RLM_BambooRevenueSuite.OptionDetailDTO applyTermToOption(
        String quoteId,
        Integer termMonths,
        String startDateIso,
        String billingFrequency
    ) {
        Id qId = RLM_BambooRevenueSuite.parseIdPublic(quoteId, 'Quote');
        Integer months = RLM_BambooRevenueSuite.normalizeTermPublic(termMonths);
        String billing = RLM_BambooRevenueSuite.normalizeBillingPublic(billingFrequency);

        Quote q = [
            SELECT Id, CurrencyIsoCode, Opportunity.CurrencyIsoCode
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        String ccy = quoteCurrency(q);

        List<QuoteLineItem> lines = [
            SELECT
                Id,
                Quantity,
                Discount,
                PartnerDiscountPercent,
                ParentQuoteLineItemId,
                RampIdentifier,
                QuoteLineGroupId,
                Product2.StockKeepingUnit
            FROM QuoteLineItem
            WHERE QuoteId = :qId
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ];
        if (lines.isEmpty()) {
            RLM_BambooRevenueSuite.OptionDetailDTO empty =
                RLM_BambooRevenueSuite.buildOptionDetailPublic(qId);
            Date startDate = RLM_BambooRevenueSuite.parseStartDatePublic(startDateIso);
            empty.termMonths = months;
            empty.evergreen = RLM_BambooRevenueSuite.isEvergreenPublic(months);
            empty.startDate = String.valueOf(startDate);
            Date endDate = RLM_BambooRevenueSuite.computeEndDatePublic(startDate, months);
            empty.endDate = endDate == null ? null : String.valueOf(endDate);
            empty.billingFrequency = billing;
            return empty;
        }

        Date startDate = RLM_BambooRevenueSuite.parseStartDatePublic(startDateIso);
        Date endDate = RLM_BambooRevenueSuite.computeEndDatePublic(startDate, months);
        Id treatmentId = RLM_BambooRevenueSuite.resolveBillingTreatmentIdPublic(ccy);

        List<RevSalesTrxn.RecordWithReferenceRequest> nodes =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        nodes.add(quotePatchNode(qId));

        Integer i = 0;
        for (QuoteLineItem qi : lines) {
            if (shouldSkipCommercialStamp(qi.RampIdentifier, qi.QuoteLineGroupId)) {
                continue;
            }
            String sku = qi.Product2 != null ? qi.Product2.StockKeepingUnit : null;
            if (String.isBlank(sku)) {
                throw new RLM_BambooRevenueSuite.SuiteException(
                    'Cannot restamp a line without a product SKU.'
                );
            }
            PricebookEntry pbe = RLM_BambooRevenueSuite.resolvePbePublic(sku, ccy, months);
            Map<String, Object> lineFields = new Map<String, Object>{
                'PricebookEntryId' => pbe.Id,
                'Product2Id' => pbe.Product2Id,
                'UnitPrice' => pbe.UnitPrice != null ? pbe.UnitPrice : 0,
                'StartDate' => String.valueOf(startDate),
                'BillingFrequency' => billing,
                'BillingTreatmentId' => String.valueOf(treatmentId),
                'PeriodBoundary' => 'Anniversary',
                'Quantity' => qi.Quantity == null || qi.Quantity <= 0 ? 1 : qi.Quantity
            };
            if (endDate != null) {
                lineFields.put('EndDate', String.valueOf(endDate));
            }
            if (qi.Discount != null) {
                lineFields.put('Discount', qi.Discount);
            }
            if (qi.PartnerDiscountPercent != null) {
                lineFields.put('PartnerDiscountPercent', qi.PartnerDiscountPercent);
            }
            RevSalesTrxn.RecordResource lineNode = new RevSalesTrxn.RecordResource(
                QuoteLineItem.getSObjectType(),
                'PATCH',
                qi.Id
            );
            lineNode.fieldValues = lineFields;
            nodes.add(
                new RevSalesTrxn.RecordWithReferenceRequest('refTerm' + i++, lineNode)
            );
        }

        if (i == 0) {
            RLM_BambooRevenueSuite.OptionDetailDTO skipped =
                RLM_BambooRevenueSuite.buildOptionDetailPublic(qId);
            skipped.termMonths = months;
            skipped.evergreen = RLM_BambooRevenueSuite.isEvergreenPublic(months);
            skipped.startDate = String.valueOf(startDate);
            skipped.endDate = endDate == null ? null : String.valueOf(endDate);
            skipped.billingFrequency = billing;
            return skipped;
        }

        placeForce(qId, nodes);
        RLM_BambooRevenueSuite.OptionDetailDTO detail =
            RLM_BambooRevenueSuite.buildOptionDetailPublic(qId);
        detail.termMonths = months;
        detail.evergreen = RLM_BambooRevenueSuite.isEvergreenPublic(months);
        detail.startDate = String.valueOf(startDate);
        detail.endDate = endDate == null ? null : String.valueOf(endDate);
        detail.billingFrequency = billing;
        return detail;
    }

    private static void stampCommercialTermsOnAllLines(
        Id quoteId,
        Date startDate,
        Date endDate,
        String billingFrequency,
        Id treatmentId
    ) {
        List<QuoteLineItem> lines = [
            SELECT Id, Quantity, RampIdentifier, QuoteLineGroupId
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            WITH USER_MODE
        ];
        if (lines.isEmpty()) {
            return;
        }
        String billing = RLM_BambooRevenueSuite.normalizeBillingPublic(billingFrequency);
        List<RevSalesTrxn.RecordWithReferenceRequest> nodes =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        nodes.add(quotePatchNode(quoteId));
        Integer i = 0;
        for (QuoteLineItem qi : lines) {
            if (shouldSkipCommercialStamp(qi.RampIdentifier, qi.QuoteLineGroupId)) {
                continue;
            }
            Map<String, Object> lineFields = new Map<String, Object>{
                'StartDate' => String.valueOf(startDate),
                'BillingFrequency' => billing,
                'BillingTreatmentId' => String.valueOf(treatmentId),
                'PeriodBoundary' => 'Anniversary',
                'Quantity' => qi.Quantity == null || qi.Quantity <= 0 ? 1 : qi.Quantity
            };
            if (endDate != null) {
                lineFields.put('EndDate', String.valueOf(endDate));
            }
            RevSalesTrxn.RecordResource lineNode = new RevSalesTrxn.RecordResource(
                QuoteLineItem.getSObjectType(),
                'PATCH',
                qi.Id
            );
            lineNode.fieldValues = lineFields;
            nodes.add(
                new RevSalesTrxn.RecordWithReferenceRequest('refStamp' + i++, lineNode)
            );
        }
        if (i == 0) {
            return;
        }
        placeForce(quoteId, nodes);
    }

    private static List<QuoteLineGroup> queryRampGroups(Id quoteId) {
        return [
            SELECT Id, Name, IsRamped, Type, StartDate, EndDate, SortOrder
            FROM QuoteLineGroup
            WHERE QuoteId = :quoteId
            WITH USER_MODE
            ORDER BY SortOrder ASC NULLS LAST, StartDate ASC NULLS LAST
        ];
    }

    private static QuoteLineGroup firstConvertibleGroup(Id quoteId) {
        for (QuoteLineGroup grp : queryRampGroups(quoteId)) {
            if (grp.Type != 'RampScheduleGroup') {
                return grp;
            }
        }
        return null;
    }

    private static Id lastSegmentGroupId(Id quoteId) {
        List<QuoteLineGroup> groups = queryRampGroups(quoteId);
        QuoteLineGroup last = null;
        for (QuoteLineGroup grp : groups) {
            if (grp.Type == 'RampScheduleGroup') {
                continue;
            }
            last = grp;
        }
        return last == null ? null : last.Id;
    }

    private static void cloneLastRampSegment(Id quoteId, Id groupId) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(
            URL.getOrgDomainUrl().toExternalForm()
            + '/services/data/'
            + RAMP_API_VERSION
            + '/connect/rev/sales-transaction/actions/clone'
        );
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Authorization', 'Bearer ' + apiSessionId());
        req.setBody(
            JSON.serialize(
                new Map<String, Object>{
                    'recordIds' => new List<String>{ String.valueOf(groupId) },
                    'salesTransactionId' => String.valueOf(quoteId),
                    'options' => new Map<String, Object>{ 'lineScope' => 'AllLines' }
                }
            )
        );
        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200 && res.getStatusCode() != 201) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Clone ramp segment failed: ' + httpError(res)
            );
        }
    }

    @TestVisible
    static Boolean shouldSkipCommercialStamp(String rampIdentifier, Id quoteLineGroupId) {
        return String.isNotBlank(rampIdentifier) || quoteLineGroupId != null;
    }

    private static void clearUnitPriceUplift(Id lineId) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(
            URL.getOrgDomainUrl().toExternalForm()
            + '/services/data/'
            + RAMP_API_VERSION
            + '/sobjects/QuoteLineItem/'
            + String.valueOf(lineId)
        );
        req.setMethod('PATCH');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Authorization', 'Bearer ' + apiSessionId());
        req.setBody(JSON.serialize(new Map<String, Object>{ 'UnitPriceUplift' => null }));
        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() >= 300) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Could not clear UnitPriceUplift before line ramp: ' + httpError(res)
            );
        }
    }

    private static String postRampDealCreate(
        Id quoteId,
        Id lineId,
        Integer termMonths,
        String segmentType,
        Integer trialDays
    ) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(
            URL.getOrgDomainUrl().toExternalForm()
            + '/services/data/'
            + RAMP_API_VERSION
            + '/connect/revenue-management/sales-transaction-contexts/'
            + String.valueOf(lineId)
            + '/actions/ramp-deal-create'
        );
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Authorization', 'Bearer ' + apiSessionId());
        Map<String, Object> body = new Map<String, Object>{
            'transactionId' => String.valueOf(quoteId),
            'transactionLineId' => String.valueOf(lineId),
            'subscriptionTerm' => termMonths,
            'subscriptionTermUnit' => 'MONTHS',
            'segmentType' => String.isBlank(segmentType) ? 'YEARLY' : segmentType
        };
        if (trialDays != null && trialDays > 0) {
            body.put('trialTerm', trialDays);
            body.put('trialTermUnit', 'DAYS');
        }
        req.setBody(JSON.serialize(body));
        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200 && res.getStatusCode() != 201) {
            throw new RLM_BambooRevenueSuite.SuiteException(httpError(res));
        }
        return extractTransactionContextId(res.getBody());
    }

    @TestVisible
    static String extractTransactionContextId(String body) {
        if (String.isBlank(body)) {
            return null;
        }
        Object parsed = JSON.deserializeUntyped(body);
        if (!(parsed instanceof Map<String, Object>)) {
            return null;
        }
        Map<String, Object> root = (Map<String, Object>) parsed;
        Object ctx = root.get('transactionContextId');
        if (ctx != null) {
            return String.valueOf(ctx);
        }
        Object nested = root.get('result');
        if (nested instanceof Map<String, Object>) {
            Object nestedCtx = ((Map<String, Object>) nested).get('transactionContextId');
            if (nestedCtx != null) {
                return String.valueOf(nestedCtx);
            }
        }
        return null;
    }

    private static String httpError(HttpResponse res) {
        String body = res == null ? null : res.getBody();
        if (String.isNotBlank(body)) {
            try {
                Object parsed = JSON.deserializeUntyped(body);
                if (parsed instanceof List<Object> && !((List<Object>) parsed).isEmpty()) {
                    Object first = ((List<Object>) parsed)[0];
                    if (first instanceof Map<String, Object>) {
                        Object msg = ((Map<String, Object>) first).get('message');
                        if (msg != null) {
                            return String.valueOf(msg);
                        }
                    }
                }
                if (parsed instanceof Map<String, Object>) {
                    Object msg = ((Map<String, Object>) parsed).get('message');
                    if (msg != null) {
                        return String.valueOf(msg);
                    }
                }
            } catch (Exception e) {
                // Use raw body below.
            }
        }
        String status = res == null ? 'no response' : String.valueOf(res.getStatusCode());
        return String.isBlank(body) ? ('HTTP ' + status) : body;
    }

    private static String cachedApiSessionId;

    private static String apiSessionId() {
        // Lightning Aura: UserInfo.getSessionId() is restricted. The VF page
        // renders $Api.Session_ID. Async Apex (Queueable/future) cannot call
        // Page.getContent() ("Callout not allowed from this future method");
        // those contexts already have an API-enabled session.
        if (Test.isRunningTest()) {
            return 'fake-session-id';
        }
        if (
            System.isQueueable() ||
            System.isFuture() ||
            System.isBatch() ||
            System.isScheduled()
        ) {
            return UserInfo.getSessionId();
        }
        if (cachedApiSessionId == null) {
            cachedApiSessionId = Page.RLM_BambooSuiteSessionId.getContent()
                .toString()
                .trim();
        }
        return cachedApiSessionId;
    }

    private static String billingFrequencyForOption(Id quoteId) {
        List<QuoteLineItem> lines = [
            SELECT BillingFrequency
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            WITH USER_MODE
            ORDER BY CreatedDate ASC
            LIMIT 1
        ];
        if (!lines.isEmpty() && String.isNotBlank(lines[0].BillingFrequency)) {
            return RLM_BambooRevenueSuite.normalizeBillingPublic(
                lines[0].BillingFrequency
            );
        }
        return 'Monthly';
    }

    @AuraEnabled
    public static RLM_BambooRevenueSuite.OptionDetailDTO applyTermToAllOptions(
        String opportunityId,
        String selectedQuoteId,
        Integer termMonths,
        String startDateIso,
        List<String> quoteIds
    ) {
        Id oppId = RLM_BambooRevenueSuite.parseIdPublic(opportunityId, 'Opportunity');
        Id selectedId = String.isBlank(selectedQuoteId)
            ? null
            : RLM_BambooRevenueSuite.parseIdPublic(selectedQuoteId, 'Quote');
        List<RLM_BambooRevenueSuite.OptionSummaryDTO> options =
            RLM_BambooRevenueSuite.buildOptionSummariesPublic(oppId, selectedId);
        if (options.isEmpty()) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'No quote options found on this opportunity.'
            );
        }

        Set<Id> onlyIds = null;
        if (quoteIds != null && !quoteIds.isEmpty()) {
            onlyIds = new Set<Id>();
            for (String raw : quoteIds) {
                if (String.isBlank(raw)) {
                    continue;
                }
                onlyIds.add(RLM_BambooRevenueSuite.parseIdPublic(raw, 'Quote'));
            }
        }

        RLM_BambooRevenueSuite.OptionDetailDTO selectedDetail = null;
        Boolean touchedSelected = false;
        for (RLM_BambooRevenueSuite.OptionSummaryDTO opt : options) {
            if (onlyIds != null && !onlyIds.contains(opt.quoteId)) {
                continue;
            }
            String billing = billingFrequencyForOption(opt.quoteId);
            RLM_BambooRevenueSuite.OptionDetailDTO detail = applyTermToOption(
                opt.quoteId,
                termMonths,
                startDateIso,
                billing
            );
            if (selectedId != null && opt.quoteId == selectedId) {
                selectedDetail = detail;
                touchedSelected = true;
            }
        }
        if (selectedId != null && !touchedSelected) {
            selectedDetail = RLM_BambooRevenueSuite.buildOptionDetailPublic(selectedId);
        } else if (selectedDetail == null && selectedId != null) {
            selectedDetail = RLM_BambooRevenueSuite.buildOptionDetailPublic(selectedId);
        } else if (selectedDetail == null) {
            selectedDetail = RLM_BambooRevenueSuite.buildOptionDetailPublic(
                options[0].quoteId
            );
        }
        return selectedDetail;
    }

    /**
     * Apply the same manual discount percent to every line of every suite option
     * on the opportunity (blanket discount across all options), via PST + FORCE.
     * Fans out to updateOptionDiscount per option so the same Place/pricing path,
     * ownership guards, and waterfall composition apply as the single-option case.
     * The manual discount layers on top of any volume-tier adjustment
     * (multiplicative: List x tier x (1 - discount)). Options with no lines are
     * skipped. Pass quoteIds to scope to a subset; null/empty = all options.
     */
    @AuraEnabled
    public static RLM_BambooRevenueSuite.OptionDetailDTO applyDiscountToAllOptions(
        String opportunityId,
        String selectedQuoteId,
        Decimal discountPercent,
        List<String> quoteIds
    ) {
        Id oppId = RLM_BambooRevenueSuite.parseIdPublic(opportunityId, 'Opportunity');
        Id selectedId = String.isBlank(selectedQuoteId)
            ? null
            : RLM_BambooRevenueSuite.parseIdPublic(selectedQuoteId, 'Quote');
        Decimal pct = clampPercent(discountPercent);
        List<RLM_BambooRevenueSuite.OptionSummaryDTO> options =
            RLM_BambooRevenueSuite.buildOptionSummariesPublic(oppId, selectedId);
        if (options.isEmpty()) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'No quote options found on this opportunity.'
            );
        }

        Set<Id> onlyIds = null;
        if (quoteIds != null && !quoteIds.isEmpty()) {
            onlyIds = new Set<Id>();
            for (String raw : quoteIds) {
                if (String.isBlank(raw)) {
                    continue;
                }
                onlyIds.add(RLM_BambooRevenueSuite.parseIdPublic(raw, 'Quote'));
            }
        }

        // Pre-compute which options actually have lines in one query so empty
        // options are skipped rather than aborting the batch (updateOptionDiscount
        // throws when an option has no products).
        Set<Id> optionIds = new Set<Id>();
        for (RLM_BambooRevenueSuite.OptionSummaryDTO opt : options) {
            optionIds.add(opt.quoteId);
        }
        Set<Id> optionsWithLines = new Set<Id>();
        for (AggregateResult ar : [
            SELECT QuoteId qid
            FROM QuoteLineItem
            WHERE QuoteId IN :optionIds
            WITH USER_MODE
            GROUP BY QuoteId
        ]) {
            optionsWithLines.add((Id) ar.get('qid'));
        }

        // Scale guard: the Opportunity sync suspend/restore is an opportunity-level
        // concern, so do it ONCE around the whole fan-out instead of once per
        // option. With TXN_JOB_IN_PROGRESS set, each per-option Place skips its own
        // suspend/restore (runPlaceWithOpportunitySyncSuspended short-circuits),
        // eliminating N-1 redundant Opp queries + DML + restore jobs. When invoked
        // from the async orchestrator the flag is already set (it owns the
        // lifecycle), so we must not double-suspend — hence the ownSuspend guard.
        Boolean ownSuspend = !RLM_BambooRevenueSuite.isTxnJobInProgressPublic();
        Id stagedSyncQuoteId = null;
        if (ownSuspend) {
            stagedSyncQuoteId =
                RLM_BambooRevenueSuite.syncedQuoteIdForOpportunityPublic(oppId);
            if (stagedSyncQuoteId != null) {
                RLM_BambooRevenueSuite.clearOpportunitySyncedQuotePublic(oppId);
            }
            RLM_BambooRevenueSuite.setTxnJobInProgress(true);
        }

        RLM_BambooRevenueSuite.OptionDetailDTO selectedDetail = null;
        Boolean touchedSelected = false;
        try {
            for (RLM_BambooRevenueSuite.OptionSummaryDTO opt : options) {
                if (onlyIds != null && !onlyIds.contains(opt.quoteId)) {
                    continue;
                }
                if (!optionsWithLines.contains(opt.quoteId)) {
                    continue;
                }
                RLM_BambooRevenueSuite.OptionDetailDTO detail = updateOptionDiscount(
                    opt.quoteId,
                    pct
                );
                if (selectedId != null && opt.quoteId == selectedId) {
                    selectedDetail = detail;
                    touchedSelected = true;
                }
            }
            if (selectedId != null && !touchedSelected) {
                selectedDetail =
                    RLM_BambooRevenueSuite.buildOptionDetailPublic(selectedId);
            } else if (selectedDetail == null && selectedId != null) {
                selectedDetail =
                    RLM_BambooRevenueSuite.buildOptionDetailPublic(selectedId);
            } else if (selectedDetail == null) {
                selectedDetail = RLM_BambooRevenueSuite.buildOptionDetailPublic(
                    options[0].quoteId
                );
            }
        } finally {
            if (ownSuspend) {
                RLM_BambooRevenueSuite.setTxnJobInProgress(false);
                if (stagedSyncQuoteId != null) {
                    RLM_BambooRevenueSuite.enqueueRestoreSyncedQuote(
                        oppId,
                        stagedSyncQuoteId
                    );
                }
            }
        }
        return selectedDetail;
    }

    @AuraEnabled
    public static RLM_BambooRevenueSuite.OptionDetailDTO applyBillingToAllOptions(
        String opportunityId,
        String selectedQuoteId,
        String billingFrequency,
        Map<String, Integer> termMonthsByQuoteId,
        Map<String, String> startDateByQuoteId,
        List<String> quoteIds
    ) {
        Id oppId = RLM_BambooRevenueSuite.parseIdPublic(opportunityId, 'Opportunity');
        Id selectedId = String.isBlank(selectedQuoteId)
            ? null
            : RLM_BambooRevenueSuite.parseIdPublic(selectedQuoteId, 'Quote');
        String billing = RLM_BambooRevenueSuite.normalizeBillingPublic(billingFrequency);
        List<RLM_BambooRevenueSuite.OptionSummaryDTO> options =
            RLM_BambooRevenueSuite.buildOptionSummariesPublic(oppId, selectedId);
        if (options.isEmpty()) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'No quote options found on this opportunity.'
            );
        }

        Set<Id> onlyIds = null;
        if (quoteIds != null && !quoteIds.isEmpty()) {
            onlyIds = new Set<Id>();
            for (String raw : quoteIds) {
                if (String.isBlank(raw)) {
                    continue;
                }
                onlyIds.add(RLM_BambooRevenueSuite.parseIdPublic(raw, 'Quote'));
            }
        }

        RLM_BambooRevenueSuite.OptionDetailDTO selectedDetail = null;
        Boolean touchedSelected = false;
        for (RLM_BambooRevenueSuite.OptionSummaryDTO opt : options) {
            if (onlyIds != null && !onlyIds.contains(opt.quoteId)) {
                continue;
            }
            RLM_BambooRevenueSuite.OptionDetailDTO current =
                RLM_BambooRevenueSuite.buildOptionDetailPublic(opt.quoteId);
            Boolean hasLines = current.lines != null && !current.lines.isEmpty();
            Integer months;
            String startIso;
            String key = String.valueOf(opt.quoteId);
            if (hasLines) {
                months = current.termMonths != null ? current.termMonths : 12;
                startIso = String.isNotBlank(current.startDate)
                    ? current.startDate
                    : String.valueOf(Date.today());
            } else {
                months = (termMonthsByQuoteId != null &&
                    termMonthsByQuoteId.containsKey(key))
                    ? RLM_BambooRevenueSuite.normalizeTermPublic(
                          termMonthsByQuoteId.get(key)
                      )
                    : 12;
                startIso = (startDateByQuoteId != null &&
                    String.isNotBlank(startDateByQuoteId.get(key)))
                    ? startDateByQuoteId.get(key)
                    : String.valueOf(Date.today());
            }
            RLM_BambooRevenueSuite.OptionDetailDTO detail = applyTermToOption(
                opt.quoteId,
                months,
                startIso,
                billing
            );
            if (selectedId != null && opt.quoteId == selectedId) {
                selectedDetail = detail;
                touchedSelected = true;
            }
        }
        if (selectedId != null && !touchedSelected) {
            selectedDetail = RLM_BambooRevenueSuite.buildOptionDetailPublic(selectedId);
        } else if (selectedDetail == null && selectedId != null) {
            selectedDetail = RLM_BambooRevenueSuite.buildOptionDetailPublic(selectedId);
        } else if (selectedDetail == null) {
            selectedDetail = RLM_BambooRevenueSuite.buildOptionDetailPublic(
                options[0].quoteId
            );
        }
        return selectedDetail;
    }

    /**
     * Clear existing lines on a suite option and fill Good / Better / Best catalog.
     * Good = Path B Core+Payroll+Benefits; Better = Workforce Pro package;
     * Best = Path B Elite+Payroll+Benefits+Time.
     */
    @AuraEnabled
    public static RLM_BambooRevenueSuite.OptionDetailDTO fillTierOption(
        String quoteId,
        String tierKey,
        Decimal seats,
        Integer termMonths,
        String startDateIso,
        String billingFrequency
    ) {
        Id qId = RLM_BambooRevenueSuite.parseIdPublic(quoteId, 'Quote');
        String tier = String.isBlank(tierKey) ? '' : tierKey.trim().toLowerCase();
        Decimal qty = seats == null || seats <= 0 ? 50 : seats;
        Integer months = RLM_BambooRevenueSuite.normalizeTermPublic(termMonths);
        String startIso = String.isBlank(startDateIso)
            ? String.valueOf(Date.today())
            : startDateIso.trim();
        String billing = RLM_BambooRevenueSuite.normalizeBillingPublic(billingFrequency);

        clearAllLinesOnQuote(qId);

        if (tier == 'good' || tier == 'a' || tier == 'core') {
            addProductLinesBySku(
                String.valueOf(qId),
                new List<String>{
                    'BAMBOO-CORE',
                    'BAMBOO-ADD-PAYROLL',
                    'BAMBOO-ADD-BENEFITS'
                },
                new List<Decimal>{ qty, qty, qty },
                months,
                startIso,
                billing
            );
        } else if (tier == 'better' || tier == 'b' || tier == 'pro') {
            addWorkforcePackage(
                String.valueOf(qId),
                RLM_BambooRevenueSuite.workforceDefaultPlan(),
                qty,
                months,
                startIso,
                billing
            );
        } else if (tier == 'best' || tier == 'c' || tier == 'elite') {
            addProductLinesBySku(
                String.valueOf(qId),
                new List<String>{
                    'BAMBOO-ELITE',
                    'BAMBOO-ADD-PAYROLL',
                    'BAMBOO-ADD-BENEFITS',
                    'BAMBOO-ADD-TIME'
                },
                new List<Decimal>{ qty, qty, qty, qty },
                months,
                startIso,
                billing
            );
        } else {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Unknown tier "' +
                    tierKey +
                    '". Use Good, Better, or Best.'
            );
        }
        return RLM_BambooRevenueSuite.buildOptionDetailPublic(qId);
    }

    private static void clearAllLinesOnQuote(Id quoteId) {
        List<QuoteLineItem> lines = [
            SELECT Id
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            WITH USER_MODE
        ];
        if (lines.isEmpty()) {
            return;
        }
        List<String> ids = new List<String>();
        for (QuoteLineItem qi : lines) {
            ids.add(String.valueOf(qi.Id));
        }
        removeLines(String.valueOf(quoteId), ids);
    }
}
