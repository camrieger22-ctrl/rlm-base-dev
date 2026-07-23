/**
 * Loads paid-price history for assets being amended on a Quote,
 * plus an add/upsell projection of how current amend lines would
 * change blended qty / discount / MRR / ARR. Decrease/cancel is parked.
 */
public with sharing class RLM_AssetPriceHistoryController {

    public class HistoryRow {
        @AuraEnabled public Id assetId;
        @AuraEnabled public String assetName;
        @AuraEnabled public Id actionId;
        @AuraEnabled public String actionType;
        @AuraEnabled public String category;
        @AuraEnabled public Datetime actionDate;
        @AuraEnabled public Decimal quantityChange;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public Decimal listPrice;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public Decimal netUnitPrice;
        @AuraEnabled public Decimal discountPercent;
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public Datetime periodStart;
        @AuraEnabled public Datetime periodEnd;
    }

    public class HistorySummary {
        @AuraEnabled public String assetName;
        /** Qty-weighted average net unit price across contributing rows. */
        @AuraEnabled public Decimal averagePaid;
        @AuraEnabled public Decimal averageDiscountPercent;
        /** Sum of quantities across contributing rows. */
        @AuraEnabled public Decimal totalQuantity;
        /** ARR = Σ(net unit × qty); MRR = ARR / 12. */
        @AuraEnabled public Decimal currentMrr;
        @AuraEnabled public Decimal currentArr;
    }

    /**
     * Add/upsell impact of the current amendment line(s) on top of history.
     * mode: Add | DecreaseParked | None
     */
    public class ProjectionImpact {
        @AuraEnabled public String mode;
        @AuraEnabled public String message;
        @AuraEnabled public HistorySummary projected;
        @AuraEnabled public Decimal deltaQuantity;
        @AuraEnabled public Decimal deltaAveragePaid;
        @AuraEnabled public Decimal deltaAverageDiscountPercent;
        @AuraEnabled public Decimal deltaMrr;
        @AuraEnabled public Decimal deltaArr;
        @AuraEnabled public Decimal amendmentQuantity;
        @AuraEnabled public Decimal amendmentPaid;
        @AuraEnabled public Decimal amendmentDiscountPercent;
    }

    public class HistoryResponse {
        @AuraEnabled public Boolean isAmendmentQuote;
        @AuraEnabled public List<HistoryRow> rows;
        @AuraEnabled public HistorySummary summary;
        @AuraEnabled public ProjectionImpact projection;
        @AuraEnabled public String message;
    }

    /**
     * Not cacheable: amendment QuoteActions / AssetActions often land just after
     * the page first paints; a cached empty response would stick until hard reload.
     */
    @AuraEnabled
    public static HistoryResponse getHistoryForQuote(Id quoteId) {
        HistoryResponse resp = new HistoryResponse();
        resp.rows = new List<HistoryRow>();
        resp.isAmendmentQuote = false;
        if (quoteId == null) {
            resp.message = 'No quote Id provided.';
            return resp;
        }

        Id qId = Id.valueOf(String.valueOf(quoteId));
        if (qId.getSObjectType() != Quote.SObjectType) {
            resp.message = 'Record is not a Quote.';
            return resp;
        }

        Quote q = [
            SELECT Id, OriginalActionType
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        if (q.OriginalActionType == 'Amend') {
            resp.isAmendmentQuote = true;
        }

        Set<Id> assetIds = new Set<Id>();
        Map<Id, String> assetNames = new Map<Id, String>();

        for (QuoteAction qa : [
            SELECT SourceAssetId, SourceAsset.Name, Type
            FROM QuoteAction
            WHERE QuoteId = :qId AND SourceAssetId != null
            WITH USER_MODE
        ]) {
            if (qa.Type == 'Amend') {
                resp.isAmendmentQuote = true;
            }
            if (resp.isAmendmentQuote || qa.Type == 'Amend') {
                assetIds.add(qa.SourceAssetId);
                if (qa.SourceAsset != null) {
                    assetNames.put(qa.SourceAssetId, qa.SourceAsset.Name);
                }
            }
        }

        if (assetIds.isEmpty() && resp.isAmendmentQuote) {
            Set<Id> actionIds = new Set<Id>();
            for (QuoteLineItem qli : [
                SELECT QuoteActionId
                FROM QuoteLineItem
                WHERE QuoteId = :qId AND QuoteActionId != null
                WITH USER_MODE
            ]) {
                actionIds.add(qli.QuoteActionId);
            }
            if (!actionIds.isEmpty()) {
                for (QuoteAction qa : [
                    SELECT SourceAssetId, SourceAsset.Name
                    FROM QuoteAction
                    WHERE Id IN :actionIds AND SourceAssetId != null
                    WITH USER_MODE
                ]) {
                    assetIds.add(qa.SourceAssetId);
                    if (qa.SourceAsset != null) {
                        assetNames.put(qa.SourceAssetId, qa.SourceAsset.Name);
                    }
                }
            }
        }

        if (assetIds.isEmpty()) {
            resp.message = resp.isAmendmentQuote
                ? 'Amendment quote has no linked source assets yet. Refresh after the line finishes loading.'
                : 'Price history appears on amendment quotes.';
            return resp;
        }

        for (AssetAction aa : [
            SELECT Id, AssetId, Type, CategoryEnum, ActionDate, QuantityChange, Amount,
                (SELECT ListPrice, UnitPrice, NetUnitPrice, Quantity, Discount,
                        StartDate, EndDate
                 FROM AssetActionSources
                 ORDER BY StartDate ASC NULLS LAST)
            FROM AssetAction
            WHERE AssetId IN :assetIds
            WITH USER_MODE
            ORDER BY ActionDate ASC, CreatedDate ASC
        ]) {
            List<AssetActionSource> sources = aa.AssetActionSources;
            if (sources == null || sources.isEmpty()) {
                resp.rows.add(baseRow(aa, assetNames));
                continue;
            }
            for (AssetActionSource src : sources) {
                HistoryRow row = baseRow(aa, assetNames);
                row.listPrice = src.ListPrice;
                row.unitPrice = src.UnitPrice;
                row.netUnitPrice = src.NetUnitPrice;
                row.quantity = src.Quantity;
                row.periodStart = src.StartDate;
                row.periodEnd = src.EndDate;
                row.discountPercent = resolveDiscountPercent(src.Discount, src.ListPrice, src.NetUnitPrice);
                resp.rows.add(row);
            }
        }

        resp.summary = buildSummaryFromRows(resp.rows, assetNames);
        resp.projection = buildAddProjection(qId, resp.rows, resp.summary, assetNames);
        stampQuoteDifferenceFields(qId, resp);

        if (resp.rows.isEmpty()) {
            resp.message = 'No Asset Actions found for the amended asset(s) yet.';
        }
        return resp;
    }

    /**
     * Persist Current / Proposed / Net Increase KPIs on the Quote so layouts,
     * reports, and Document Generation can use them without the LWC.
     * Best-effort: stamp failures must not break the history panel.
     */
    @TestVisible
    private static void stampQuoteDifferenceFields(Id quoteId, HistoryResponse resp) {
        if (quoteId == null || resp == null || resp.summary == null) {
            return;
        }
        try {
            Quote q = new Quote(Id = quoteId);
            q.RLM_Amend_Current_ARR__c = resp.summary.currentArr;
            q.RLM_Amend_Current_MRR__c = resp.summary.currentMrr;
            q.RLM_Amend_Current_Qty__c = resp.summary.totalQuantity;

            if (resp.projection != null && resp.projection.mode == 'Add' && resp.projection.projected != null) {
                q.RLM_Amend_Proposed_ARR__c = resp.projection.projected.currentArr;
                q.RLM_Amend_Proposed_MRR__c = resp.projection.projected.currentMrr;
                q.RLM_Amend_Proposed_Qty__c = resp.projection.projected.totalQuantity;
                q.RLM_Amend_Net_Increase_ARR__c = resp.projection.deltaArr;
                q.RLM_Amend_Net_Increase_MRR__c = resp.projection.deltaMrr;
                q.RLM_Amend_Net_Increase_Qty__c = resp.projection.deltaQuantity;
            } else {
                // No add projection — proposed matches current; net increase is zero.
                q.RLM_Amend_Proposed_ARR__c = resp.summary.currentArr;
                q.RLM_Amend_Proposed_MRR__c = resp.summary.currentMrr;
                q.RLM_Amend_Proposed_Qty__c = resp.summary.totalQuantity;
                q.RLM_Amend_Net_Increase_ARR__c = 0;
                q.RLM_Amend_Net_Increase_MRR__c = 0;
                q.RLM_Amend_Net_Increase_Qty__c = 0;
            }
            update as user q;
        } catch (Exception e) {
            // Panel read path must stay resilient if FLS/validation blocks the stamp.
            System.debug(
                LoggingLevel.WARN,
                'RLM_AssetPriceHistoryController: could not stamp difference fields on '
                    + quoteId + ': ' + e.getMessage()
            );
        }
    }

    /**
     * v1: only models positive-qty amend lines (add / upsell).
     * Negative qty (decrease / cancel) returns DecreaseParked.
     */
    private static ProjectionImpact buildAddProjection(
        Id quoteId,
        List<HistoryRow> historyRows,
        HistorySummary baseline,
        Map<Id, String> assetNames
    ) {
        ProjectionImpact impact = new ProjectionImpact();
        impact.mode = 'None';

        List<QuoteLineItem> lines = [
            SELECT Id, Quantity, ListPrice, NetUnitPrice, Discount, Product2.Name,
                StartDate, EndDate
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            WITH USER_MODE
        ];
        if (lines.isEmpty()) {
            impact.message = 'Add amendment quantity and reprice to model impact.';
            return impact;
        }

        Boolean hasDecrease = false;
        Boolean hasAdd = false;
        List<HistoryRow> amendTranches = new List<HistoryRow>();
        Decimal amendQty = 0;
        Decimal amendPaidWeight = 0;
        Decimal amendDiscWeight = 0;

        for (QuoteLineItem qli : lines) {
            Decimal qty = qli.Quantity != null ? qli.Quantity : 0;
            if (qty < 0) {
                hasDecrease = true;
                continue;
            }
            if (qty == 0) {
                continue;
            }
            hasAdd = true;
            HistoryRow tranche = new HistoryRow();
            tranche.category = 'This amendment';
            tranche.assetName = qli.Product2 != null ? qli.Product2.Name : null;
            tranche.quantity = qty;
            tranche.listPrice = qli.ListPrice;
            tranche.netUnitPrice = qli.NetUnitPrice;
            tranche.discountPercent = resolveDiscountPercent(qli.Discount, qli.ListPrice, qli.NetUnitPrice);
            if (qli.StartDate != null) {
                tranche.periodStart = Datetime.newInstance(qli.StartDate, Time.newInstance(0, 0, 0, 0));
            }
            if (qli.EndDate != null) {
                tranche.periodEnd = Datetime.newInstance(qli.EndDate, Time.newInstance(23, 59, 59, 0));
            }
            amendTranches.add(tranche);
            amendQty += qty;
            if (qli.NetUnitPrice != null) {
                amendPaidWeight += qli.NetUnitPrice * qty;
            }
            if (tranche.discountPercent != null) {
                amendDiscWeight += tranche.discountPercent * qty;
            }
        }

        if (hasDecrease && !hasAdd) {
            impact.mode = 'DecreaseParked';
            impact.message =
                'License decrease detected. Impact modeling for reductions is not enabled yet — history still applies.';
            return impact;
        }
        if (hasDecrease && hasAdd) {
            impact.mode = 'DecreaseParked';
            impact.message =
                'This quote mixes adds and decreases. Impact modeling supports add/upsell only for now.';
            return impact;
        }
        if (!hasAdd) {
            impact.message = 'Set a positive amendment quantity and reprice to model add/upsell impact.';
            return impact;
        }

        List<HistoryRow> combined = new List<HistoryRow>();
        if (historyRows != null) {
            combined.addAll(historyRows);
        }
        combined.addAll(amendTranches);

        impact.mode = 'Add';
        impact.projected = buildSummaryFromRows(combined, assetNames);
        impact.amendmentQuantity = amendQty;
        if (amendQty > 0) {
            impact.amendmentPaid = (amendPaidWeight / amendQty).setScale(2, RoundingMode.HALF_UP);
            impact.amendmentDiscountPercent =
                (amendDiscWeight / amendQty).setScale(2, RoundingMode.HALF_UP);
        }
        impact.deltaQuantity = deltaDec(
            impact.projected != null ? impact.projected.totalQuantity : null,
            baseline != null ? baseline.totalQuantity : null
        );
        impact.deltaAveragePaid = deltaDec(
            impact.projected != null ? impact.projected.averagePaid : null,
            baseline != null ? baseline.averagePaid : null
        );
        impact.deltaAverageDiscountPercent = deltaDec(
            impact.projected != null ? impact.projected.averageDiscountPercent : null,
            baseline != null ? baseline.averageDiscountPercent : null
        );
        impact.deltaMrr = deltaDec(
            impact.projected != null ? impact.projected.currentMrr : null,
            baseline != null ? baseline.currentMrr : null
        );
        impact.deltaArr = deltaDec(
            impact.projected != null ? impact.projected.currentArr : null,
            baseline != null ? baseline.currentArr : null
        );
        impact.message =
            'Proposed if this add/upsell closes at the current line price. Reprice or refresh after changing Discount %. Values are stamped on the Quote for proposals.';
        return impact;
    }

    private static Decimal deltaDec(Decimal projected, Decimal baseline) {
        if (projected == null) {
            return null;
        }
        Decimal base = baseline != null ? baseline : 0;
        return (projected - base).setScale(2, RoundingMode.HALF_UP);
    }

    /**
     * Roll up contributing rows: qty-weighted averages, total quantity,
     * ARR/MRR from Σ(net × qty). Skips non-positive quantities.
     */
    private static HistorySummary buildSummaryFromRows(
        List<HistoryRow> rows,
        Map<Id, String> assetNames
    ) {
        HistorySummary summary = new HistorySummary();
        if (rows == null || rows.isEmpty()) {
            return summary;
        }

        Decimal qtyTotal = 0;
        Decimal paidWeight = 0;
        Decimal discountWeight = 0;
        Decimal arrTotal = 0;
        Set<String> names = new Set<String>();

        for (HistoryRow row : rows) {
            if (String.isNotBlank(row.assetName)) {
                names.add(row.assetName);
            }
            Decimal qty = row.quantity != null ? row.quantity : 0;
            if (qty <= 0) {
                continue;
            }
            qtyTotal += qty;
            if (row.netUnitPrice != null) {
                paidWeight += row.netUnitPrice * qty;
                arrTotal += row.netUnitPrice * qty;
            }
            if (row.discountPercent != null) {
                discountWeight += row.discountPercent * qty;
            }
        }

        summary.assetName = names.isEmpty() ? null : String.join(new List<String>(names), ', ');
        summary.totalQuantity = qtyTotal;
        if (qtyTotal > 0) {
            summary.averagePaid = (paidWeight / qtyTotal).setScale(2, RoundingMode.HALF_UP);
            summary.averageDiscountPercent =
                (discountWeight / qtyTotal).setScale(2, RoundingMode.HALF_UP);
        }
        summary.currentArr = arrTotal.setScale(2, RoundingMode.HALF_UP);
        summary.currentMrr = (arrTotal / 12).setScale(2, RoundingMode.HALF_UP);
        return summary;
    }

    private static Decimal resolveDiscountPercent(
        Decimal discountField,
        Decimal listPrice,
        Decimal netUnitPrice
    ) {
        if (discountField != null) {
            return discountField;
        }
        if (listPrice != null && listPrice != 0 && netUnitPrice != null) {
            Decimal pct = ((listPrice - netUnitPrice) / listPrice) * 100;
            return pct.setScale(2, RoundingMode.HALF_UP);
        }
        return null;
    }

    private static HistoryRow baseRow(AssetAction aa, Map<Id, String> assetNames) {
        HistoryRow row = new HistoryRow();
        row.assetId = aa.AssetId;
        row.assetName = assetNames.get(aa.AssetId);
        row.actionId = aa.Id;
        row.actionType = aa.Type;
        row.category = aa.CategoryEnum;
        row.actionDate = aa.ActionDate;
        row.quantityChange = aa.QuantityChange;
        row.amount = aa.Amount;
        return row;
    }
}
