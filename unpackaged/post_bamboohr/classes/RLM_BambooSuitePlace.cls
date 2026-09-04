/**
 * Single Place/FORCE edge for Bamboo Revenue Suite commercial mutates.
 * LWC and Commercial call here; do not add new Place graph builders on
 * RLM_BambooRevenueSuite.
 */
public with sharing class RLM_BambooSuitePlace {
    /**
     * Place Sales Transaction + FORCE pricing with Opportunity sync suspended.
     */
    public static void placeForce(
        Id quoteId,
        List<RevSalesTrxn.RecordWithReferenceRequest> nodes
    ) {
        RLM_BambooRevenueSuite.placeForcePublic(quoteId, nodes);
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
            SELECT Id, Quantity
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
        placeForce(quoteId, nodes);
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
