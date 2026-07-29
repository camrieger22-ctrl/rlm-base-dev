/**
 * Difference quoting for Amendment Studio: installed-asset price history,
 * add/upsell projection, Quote KPI stamps, and Working-line ARR/MRR economics.
 * Commercial writes stay on RLM_RepriceQuoteInvocable (PST).
 */
public with sharing class RLM_AmendDifferenceService {

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
        /** Line ARR = net unit × qty (installed tranche or amend delta). */
        @AuraEnabled public Decimal arr;
        /** Line MRR = ARR / 12. */
        @AuraEnabled public Decimal mrr;
        /**
         * Commercial change kind for UI grouping:
         * Initial | Add | Decrease | Renew | Other
         */
        @AuraEnabled public String changeKind;
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

    /** Counts of commercial events on one asset (from AssetAction timeline). */
    public class AssetHistoryCounts {
        @AuraEnabled public Integer initialSale;
        @AuraEnabled public Integer addOn;
        @AuraEnabled public Integer decrease;
        @AuraEnabled public Integer renew;
        @AuraEnabled public Integer other;
    }

    /**
     * Per-asset commercial history for the Account installed footprint.
     * Timeline = AssetAction (+ AssetActionSource) rows; summary prefers latest ASP.
     * Includes sibling installed assets not on this Quote's Amend actions.
     */
    public class AssetHistoryCard {
        @AuraEnabled public Id assetId;
        @AuraEnabled public String assetName;
        /** True when this Quote has an Amend QuoteAction / line for the asset. */
        @AuraEnabled public Boolean isAmending;
        @AuraEnabled public List<HistoryRow> timeline;
        @AuraEnabled public AssetHistoryCounts counts;
        /** Current installed snapshot (latest Asset State Period + avg paid from timeline). */
        @AuraEnabled public HistorySummary summary;
        @AuraEnabled public Decimal installedQuantity;
        @AuraEnabled public Decimal installedMrr;
        /** This Quote's amend delta for this Source Asset (qty × effective net). */
        @AuraEnabled public Decimal thisAddQty;
        @AuraEnabled public Decimal thisAddArr;
        @AuraEnabled public Decimal thisAddMrr;
        @AuraEnabled public Decimal thisAddProrated;
        @AuraEnabled public Date thisAddStartDate;
        @AuraEnabled public Date thisAddEndDate;
        @AuraEnabled public Decimal thisAddDiscountPercent;
        @AuraEnabled public Decimal thisAddListPrice;
        @AuraEnabled public Decimal thisAddNetUnitPrice;
        @AuraEnabled public Decimal thisAddTermMonths;
        /** Current + This add (add/upsell). Null when decrease-only / parked. */
        @AuraEnabled public Decimal finalizedQty;
        @AuraEnabled public Decimal finalizedArr;
        @AuraEnabled public Decimal finalizedMrr;
        @AuraEnabled public Decimal deltaQty;
        @AuraEnabled public Decimal deltaArr;
        @AuraEnabled public Decimal deltaMrr;
        /** Add | DecreaseParked | None */
        @AuraEnabled public String impactMode;
        @AuraEnabled public String impactMessage;
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
        /** Flat timeline (all assets) — used by quote-level stamp / legacy Installed UI. */
        @AuraEnabled public List<HistoryRow> rows;
        @AuraEnabled public HistorySummary summary;
        @AuraEnabled public ProjectionImpact projection;
        /**
         * One card per installed Asset in the Account footprint (Source Assets
         * being amended plus sibling Assets that have Asset State Periods).
         */
        @AuraEnabled public List<AssetHistoryCard> assets;
        @AuraEnabled public String message;
    }

    /** Latest ASP qty/MRR/amount per asset (end-state installed, not "as of now"). */
    public class AssetStateSnapshot {
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public Decimal mrr;
        @AuraEnabled public Decimal amount;
    }

    /**
     * End-state installed quantity per asset (latest Asset State Period).
     * Do not use "as of now" — future-dated prior amends still count as what
     * the customer owns for Current → This add → Finalized (e.g. 30k installed
     * even when today's period is still the pre-amend 10k tranche).
     */
    @TestVisible
    public static Map<Id, Decimal> installedQuantityByAsset(Set<Id> assetIds) {
        Map<Id, Decimal> qtyOnly = new Map<Id, Decimal>();
        Map<Id, AssetStateSnapshot> snaps = installedStateByAsset(assetIds);
        for (Id assetId : snaps.keySet()) {
            if (snaps.get(assetId).quantity != null) {
                qtyOnly.put(assetId, snaps.get(assetId).quantity);
            }
        }
        return qtyOnly;
    }

    @TestVisible
    public static Map<Id, AssetStateSnapshot> installedStateByAsset(Set<Id> assetIds) {
        Map<Id, AssetStateSnapshot> result = new Map<Id, AssetStateSnapshot>();
        if (assetIds == null || assetIds.isEmpty()) {
            return result;
        }
        for (AssetStatePeriod asp : [
            SELECT AssetId, Quantity, Mrr, Amount, StartDate
            FROM AssetStatePeriod
            WHERE AssetId IN :assetIds
            WITH USER_MODE
            ORDER BY AssetId, StartDate DESC
        ]) {
            if (asp.AssetId == null || result.containsKey(asp.AssetId)) {
                continue;
            }
            AssetStateSnapshot snap = new AssetStateSnapshot();
            snap.quantity = asp.Quantity;
            snap.mrr = asp.Mrr;
            snap.amount = asp.Amount;
            result.put(asp.AssetId, snap);
        }
        return result;
    }


    /**
     * Working Quote lines with This-add ARR/MRR economics (qty × effective net).
     * Installed qty from latest Asset State Period per source asset.
     */
    public static List<RLM_AssetPriceHistoryController.WorkingLine> loadWorkingLines(Id quoteId) {
        List<RLM_AssetPriceHistoryController.WorkingLine> out =
            new List<RLM_AssetPriceHistoryController.WorkingLine>();
        if (quoteId == null || quoteId.getSObjectType() != Quote.SObjectType) {
            return out;
        }
        Id qId = Id.valueOf(String.valueOf(quoteId));
        Set<Id> sourceAssetIds = new Set<Id>();
        List<QuoteLineItem> qlis = [
            SELECT
                Id,
                Quantity,
                ListPrice,
                NetUnitPrice,
                Discount,
                TotalPrice,
                StartDate,
                EndDate,
                PriceWaterfallIdentifier,
                Product2.Name,
                QuoteActionId,
                QuoteAction.Type,
                QuoteAction.SourceAssetId
            FROM QuoteLineItem
            WHERE QuoteId = :qId
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ];
        for (QuoteLineItem qli : qlis) {
            if (qli.QuoteAction != null && qli.QuoteAction.SourceAssetId != null) {
                sourceAssetIds.add(qli.QuoteAction.SourceAssetId);
            }
        }
        Map<Id, Decimal> installedByAsset = installedQuantityByAsset(sourceAssetIds);
        Set<Id> detailLineIds = new Set<Id>();
        if (!qlis.isEmpty()) {
            Set<Id> qliIds = new Set<Id>();
            for (QuoteLineItem qli : qlis) {
                qliIds.add(qli.Id);
            }
            for (AggregateResult ar : [
                SELECT QuoteLineItemId lineId
                FROM QuoteLineDetail
                WHERE QuoteLineItemId IN :qliIds
                WITH USER_MODE
                GROUP BY QuoteLineItemId
            ]) {
                detailLineIds.add((Id) ar.get('lineId'));
            }
        }
        for (QuoteLineItem qli : qlis) {
            RLM_AssetPriceHistoryController.WorkingLine line =
                new RLM_AssetPriceHistoryController.WorkingLine();
            line.id = qli.Id;
            line.productName = qli.Product2 != null ? qli.Product2.Name : 'Quote line';
            line.quantity = qli.Quantity;
            line.listPrice = qli.ListPrice;
            line.netUnitPrice = qli.NetUnitPrice;
            line.discountPercent = resolveDiscountPercent(
                qli.Discount,
                qli.ListPrice,
                qli.NetUnitPrice
            );
            line.totalPrice = qli.TotalPrice;
            line.startDate = qli.StartDate;
            line.endDate = qli.EndDate;
            line.priceWaterfallIdentifier = qli.PriceWaterfallIdentifier;
            line.quoteActionId = qli.QuoteActionId;
            line.hasQuoteLineDetails = detailLineIds.contains(qli.Id);
            if (qli.QuoteAction != null) {
                line.quoteActionType = qli.QuoteAction.Type;
                line.sourceAssetId = qli.QuoteAction.SourceAssetId;
                line.isCatalogAdd =
                    qli.QuoteAction == null || qli.QuoteAction.Type == 'Add';
                if (line.sourceAssetId != null) {
                    line.installedQuantity = installedByAsset.get(line.sourceAssetId);
                }
            } else {
                line.isCatalogAdd = false;
            }
            if (qli.Quantity != null && qli.Quantity > 0) {
                Decimal effectiveNet = resolveEffectiveNetUnitPrice(
                    qli.NetUnitPrice,
                    qli.ListPrice,
                    qli.Discount
                );
                if (effectiveNet != null) {
                    line.addArr = effectiveNet * qli.Quantity;
                    line.addMrr = line.addArr / 12;
                } else {
                    line.addArr = 0;
                    line.addMrr = 0;
                }
            } else {
                line.addArr = 0;
                line.addMrr = 0;
            }
            out.add(line);
        }
        return out;
    }

    /**
     * Not cacheable: amendment QuoteActions / AssetActions often land just after
     * the page first paints; a cached empty response would stick until hard reload.
     */
    public static HistoryResponse getHistoryForQuote(Id quoteId) {
        HistoryResponse resp = new HistoryResponse();
        resp.rows = new List<HistoryRow>();
        resp.assets = new List<AssetHistoryCard>();
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
            SELECT Id, OriginalActionType, AccountId, Contract.AccountId
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        if (q.OriginalActionType == 'Amend') {
            resp.isAmendmentQuote = true;
        }

        Set<Id> amendingAssetIds = new Set<Id>();
        Set<Id> assetIds = new Set<Id>();
        Map<Id, String> assetNames = new Map<Id, String>();

        for (QuoteAction qa : [
            SELECT SourceAssetId, SourceAsset.Name, SourceAsset.AccountId, Type
            FROM QuoteAction
            WHERE QuoteId = :qId AND SourceAssetId != null
            WITH USER_MODE
        ]) {
            if (qa.Type == 'Amend') {
                resp.isAmendmentQuote = true;
            }
            if (resp.isAmendmentQuote || qa.Type == 'Amend') {
                amendingAssetIds.add(qa.SourceAssetId);
                assetIds.add(qa.SourceAssetId);
                if (qa.SourceAsset != null) {
                    assetNames.put(qa.SourceAssetId, qa.SourceAsset.Name);
                }
            }
        }

        if (amendingAssetIds.isEmpty() && resp.isAmendmentQuote) {
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
                    amendingAssetIds.add(qa.SourceAssetId);
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

        // Current = full Account installed footprint, not only assets on this Amend.
        expandInstalledFootprint(q, amendingAssetIds, assetIds, assetNames);

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
                HistoryRow orphan = baseRow(aa, assetNames);
                orphan.changeKind = classifyChangeKind(orphan);
                enrichLineEconomics(orphan);
                resp.rows.add(orphan);
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
                row.changeKind = classifyChangeKind(row);
                enrichLineEconomics(row);
                resp.rows.add(row);
            }
        }

        resp.assets = buildAssetHistoryCards(assetIds, assetNames, resp.rows, amendingAssetIds);
        applyQuoteLineImpactToAssetCards(qId, resp.assets);
        // Prefer latest ASP rollups so sibling installed assets count in Current.
        resp.summary = buildSummaryFromAssetCards(resp.assets);
        resp.projection = buildAddProjection(qId, resp.summary);
        // Do NOT stamp Quote KPIs on this read path. Studio/history load runs as
        // soon as the Quote page opens; a Quote update races the OOTB Quote Line
        // Editor (stale LastModifiedDate → "refresh and re-enter changes").
        // Stamp only via stampDifferenceFieldsForQuote (post-reprice / DocGen).

        if (resp.rows.isEmpty()) {
            resp.message = 'No Asset Actions found for the installed asset(s) yet.';
        }
        return resp;
    }

    /**
     * Add sibling Account Assets that have Asset State Periods so Current reflects
     * the full installed contract, even when this Quote amends only one asset.
     */
    @TestVisible
    private static void expandInstalledFootprint(
        Quote quote,
        Set<Id> amendingAssetIds,
        Set<Id> assetIds,
        Map<Id, String> assetNames
    ) {
        if (assetIds == null || assetNames == null) {
            return;
        }
        Id accountId = resolveFootprintAccountId(quote, amendingAssetIds);
        if (accountId == null) {
            return;
        }
        for (Asset asset : [
            SELECT Id, Name
            FROM Asset
            WHERE AccountId = :accountId
                AND Id IN (SELECT AssetId FROM AssetStatePeriod)
            WITH USER_MODE
        ]) {
            assetIds.add(asset.Id);
            if (!assetNames.containsKey(asset.Id) && String.isNotBlank(asset.Name)) {
                assetNames.put(asset.Id, asset.Name);
            }
        }
    }

    @TestVisible
    private static Id resolveFootprintAccountId(Quote quote, Set<Id> seedAssetIds) {
        if (quote != null) {
            if (quote.AccountId != null) {
                return quote.AccountId;
            }
            if (quote.Contract != null && quote.Contract.AccountId != null) {
                return quote.Contract.AccountId;
            }
        }
        if (seedAssetIds == null || seedAssetIds.isEmpty()) {
            return null;
        }
        for (Asset asset : [
            SELECT AccountId
            FROM Asset
            WHERE Id IN :seedAssetIds AND AccountId != null
            WITH USER_MODE
            LIMIT 1
        ]) {
            return asset.AccountId;
        }
        return null;
    }

    /**
     * Sum installed ASP snapshots across footprint cards for quote-level Current.
     */
    @TestVisible
    private static HistorySummary buildSummaryFromAssetCards(List<AssetHistoryCard> cards) {
        HistorySummary summary = new HistorySummary();
        if (cards == null || cards.isEmpty()) {
            return summary;
        }
        Decimal qtyTotal = 0;
        Decimal arrTotal = 0;
        Decimal paidWeight = 0;
        Decimal paidQty = 0;
        Decimal discWeight = 0;
        Set<String> names = new Set<String>();
        for (AssetHistoryCard card : cards) {
            if (card == null) {
                continue;
            }
            if (String.isNotBlank(card.assetName)) {
                names.add(card.assetName);
            }
            Decimal qty = card.summary != null && card.summary.totalQuantity != null
                ? card.summary.totalQuantity
                : card.installedQuantity;
            Decimal arr = card.summary != null ? card.summary.currentArr : null;
            Decimal avgPaid = card.summary != null ? card.summary.averagePaid : null;
            Decimal avgDisc = card.summary != null ? card.summary.averageDiscountPercent : null;
            if (qty != null) {
                qtyTotal += qty;
            }
            if (arr != null) {
                arrTotal += arr;
            }
            if (avgPaid != null && qty != null && qty > 0) {
                paidWeight += avgPaid * qty;
                paidQty += qty;
                if (avgDisc != null) {
                    discWeight += avgDisc * qty;
                }
            }
        }
        summary.assetName = names.isEmpty() ? null : String.join(new List<String>(names), ', ');
        summary.totalQuantity = qtyTotal;
        if (paidQty > 0) {
            summary.averagePaid = (paidWeight / paidQty).setScale(2, RoundingMode.HALF_UP);
            summary.averageDiscountPercent =
                (discWeight / paidQty).setScale(2, RoundingMode.HALF_UP);
        }
        summary.currentArr = arrTotal.setScale(2, RoundingMode.HALF_UP);
        summary.currentMrr = (arrTotal / 12).setScale(2, RoundingMode.HALF_UP);
        return summary;
    }

    /**
     * Recompute and stamp Current / Proposed / Net Increase on the Quote.
     * Called after a successful force-reprice so DocGen / layouts stay current
     * without requiring the seller to open the history panel.
     * Best-effort: never throws.
     *
     * Intentionally separate from getHistoryForQuote (read-only) so opening
     * Amendment Studio does not DML the Quote underneath the Quote Line Editor.
     */
    public static void stampDifferenceFieldsForQuote(Id quoteId) {
        if (quoteId == null || quoteId.getSObjectType() != Quote.SObjectType) {
            return;
        }
        try {
            HistoryResponse resp = getHistoryForQuote(quoteId);
            stampQuoteDifferenceFields(quoteId, resp);
        } catch (Exception e) {
            System.debug(
                LoggingLevel.WARN,
                'RLM_AmendDifferenceService.stampDifferenceFieldsForQuote: '
                    + quoteId + ': ' + e.getMessage()
            );
        }
    }

    /**
     * Persist Current / Proposed / Net Increase KPIs on the Quote so layouts,
     * reports, and Document Generation can use them without the LWC.
     * Best-effort: stamp failures must not break the history panel.
     * Skips Quote DML when values are unchanged so callers that stamp after
     * reprice do not bump LastModifiedDate unnecessarily.
     */
    @TestVisible
    private static void stampQuoteDifferenceFields(Id quoteId, HistoryResponse resp) {
        if (quoteId == null || resp == null || resp.summary == null) {
            return;
        }
        try {
            Decimal proposedArr = resp.summary.currentArr;
            Decimal proposedMrr = resp.summary.currentMrr;
            Decimal proposedQty = resp.summary.totalQuantity;
            Decimal netArr = 0;
            Decimal netMrr = 0;
            Decimal netQty = 0;
            if (resp.projection != null && resp.projection.mode == 'Add' && resp.projection.projected != null) {
                proposedArr = resp.projection.projected.currentArr;
                proposedMrr = resp.projection.projected.currentMrr;
                proposedQty = resp.projection.projected.totalQuantity;
                netArr = resp.projection.deltaArr;
                netMrr = resp.projection.deltaMrr;
                netQty = resp.projection.deltaQuantity;
            }
            // Build breakdown rows up front so the Quote-level prorated total
            // covers catalog adds as well as amended assets.
            List<RLM_Amend_Breakdown__c> breakdownRows = buildBreakdownRows(quoteId, resp);
            Decimal proratedTotal = 0;
            for (RLM_Amend_Breakdown__c row : breakdownRows) {
                if (row.This_Add_Prorated__c != null) {
                    proratedTotal += row.This_Add_Prorated__c;
                }
            }
            proratedTotal = proratedTotal.setScale(2, RoundingMode.HALF_UP);

            Boolean needsQuoteUpdate = true;
            for (Quote existing : [
                SELECT
                    RLM_Amend_Current_ARR__c,
                    RLM_Amend_Current_MRR__c,
                    RLM_Amend_Current_Qty__c,
                    RLM_Amend_Proposed_ARR__c,
                    RLM_Amend_Proposed_MRR__c,
                    RLM_Amend_Proposed_Qty__c,
                    RLM_Amend_Net_Increase_ARR__c,
                    RLM_Amend_Net_Increase_MRR__c,
                    RLM_Amend_Net_Increase_Qty__c,
                    RLM_Amend_This_Add_Prorated__c
                FROM Quote
                WHERE Id = :quoteId
                WITH USER_MODE
                LIMIT 1
            ]) {
                needsQuoteUpdate = !(
                    decimalsEqual(existing.RLM_Amend_Current_ARR__c, resp.summary.currentArr)
                    && decimalsEqual(existing.RLM_Amend_Current_MRR__c, resp.summary.currentMrr)
                    && decimalsEqual(existing.RLM_Amend_Current_Qty__c, resp.summary.totalQuantity)
                    && decimalsEqual(existing.RLM_Amend_Proposed_ARR__c, proposedArr)
                    && decimalsEqual(existing.RLM_Amend_Proposed_MRR__c, proposedMrr)
                    && decimalsEqual(existing.RLM_Amend_Proposed_Qty__c, proposedQty)
                    && decimalsEqual(existing.RLM_Amend_Net_Increase_ARR__c, netArr)
                    && decimalsEqual(existing.RLM_Amend_Net_Increase_MRR__c, netMrr)
                    && decimalsEqual(existing.RLM_Amend_Net_Increase_Qty__c, netQty)
                    && decimalsEqual(existing.RLM_Amend_This_Add_Prorated__c, proratedTotal)
                );
            }

            if (needsQuoteUpdate) {
                Quote q = new Quote(Id = quoteId);
                q.RLM_Amend_Current_ARR__c = resp.summary.currentArr;
                q.RLM_Amend_Current_MRR__c = resp.summary.currentMrr;
                q.RLM_Amend_Current_Qty__c = resp.summary.totalQuantity;
                q.RLM_Amend_Proposed_ARR__c = proposedArr;
                q.RLM_Amend_Proposed_MRR__c = proposedMrr;
                q.RLM_Amend_Proposed_Qty__c = proposedQty;
                q.RLM_Amend_Net_Increase_ARR__c = netArr;
                q.RLM_Amend_Net_Increase_MRR__c = netMrr;
                q.RLM_Amend_Net_Increase_Qty__c = netQty;
                q.RLM_Amend_This_Add_Prorated__c = proratedTotal;
                update as user q;
            }
            stampBreakdownRows(quoteId, breakdownRows);
        } catch (Exception e) {
            // Panel read path must stay resilient if FLS/validation blocks the stamp.
            System.debug(
                LoggingLevel.WARN,
                'RLM_AmendDifferenceService: could not stamp difference fields on '
                    + quoteId + ': ' + e.getMessage()
            );
        }
    }

    @TestVisible
    private static Boolean decimalsEqual(Decimal a, Decimal b) {
        if (a == null && b == null) {
            return true;
        }
        if (a == null || b == null) {
            return false;
        }
        return a == b;
    }

    /**
     * Replace this Quote's Amend Breakdown rows so DocGen can render By product
     * (Current / This add / Finalized) without the LWC.
     * Best-effort; never throws to the caller.
     */
    @TestVisible
    private static void stampBreakdownRows(
        Id quoteId,
        List<RLM_Amend_Breakdown__c> rows
    ) {
        if (quoteId == null) {
            return;
        }
        try {
            delete as user [
                SELECT Id
                FROM RLM_Amend_Breakdown__c
                WHERE Quote__c = :quoteId
                WITH USER_MODE
            ];
            if (rows != null && !rows.isEmpty()) {
                insert as user rows;
            }
        } catch (Exception e) {
            System.debug(
                LoggingLevel.WARN,
                'RLM_AmendDifferenceService: could not stamp breakdown rows on '
                    + quoteId + ': ' + e.getMessage()
            );
        }
    }

    /**
     * One row per installed footprint Asset, then one per catalog-added product.
     * Pure builder — no DML — so the caller can total This add prorated across
     * every row before it stamps the Quote.
     */
    @TestVisible
    private static List<RLM_Amend_Breakdown__c> buildBreakdownRows(
        Id quoteId,
        HistoryResponse resp
    ) {
        List<RLM_Amend_Breakdown__c> rows = new List<RLM_Amend_Breakdown__c>();
        if (quoteId == null || resp == null) {
            return rows;
        }
        Set<Id> assetIds = new Set<Id>();
        for (AssetHistoryCard card : resp.assets == null
            ? new List<AssetHistoryCard>()
            : resp.assets) {
            if (card != null && card.assetId != null) {
                assetIds.add(card.assetId);
            }
        }
        Map<Id, Asset> assetsById = new Map<Id, Asset>();
        if (!assetIds.isEmpty()) {
            for (Asset a : [
                SELECT Id, LifecycleStartDate, LifecycleEndDate
                FROM Asset
                WHERE Id IN :assetIds
                WITH USER_MODE
            ]) {
                assetsById.put(a.Id, a);
            }
        }
        Integer sortOrder = 0;
        for (AssetHistoryCard card : resp.assets == null
            ? new List<AssetHistoryCard>()
            : resp.assets) {
            if (card == null || card.assetId == null) {
                continue;
            }
            String assetKey = String.valueOf(card.assetId);
            if (assetKey == 'flat') {
                continue;
            }
            Decimal currentQty = card.summary != null && card.summary.totalQuantity != null
                ? card.summary.totalQuantity
                : card.installedQuantity;
            Decimal currentArr = card.summary != null ? card.summary.currentArr : null;
            Decimal currentMrr = card.summary != null
                ? card.summary.currentMrr
                : card.installedMrr;
            Decimal addQty = card.thisAddQty != null ? card.thisAddQty : 0;
            Decimal addArr = card.thisAddArr != null ? card.thisAddArr : 0;
            Decimal addMrr = card.thisAddMrr != null ? card.thisAddMrr : 0;
            Decimal addProrated = card.thisAddProrated != null ? card.thisAddProrated : 0;
            Decimal finalizedQty = card.finalizedQty != null
                ? card.finalizedQty
                : ((currentQty != null ? currentQty : 0) + addQty);
            Decimal finalizedArr = card.finalizedArr != null
                ? card.finalizedArr
                : ((currentArr != null ? currentArr : 0) + addArr);
            Decimal finalizedMrr = card.finalizedMrr != null
                ? card.finalizedMrr
                : ((currentMrr != null ? currentMrr : 0) + addMrr);

            // Skip empty sibling rows with no commercial footprint.
            if ((currentQty == null || currentQty == 0)
                && (currentArr == null || currentArr == 0)
                && addQty == 0
                && addArr == 0) {
                continue;
            }

            String productName = String.isNotBlank(card.assetName)
                ? card.assetName
                : 'Asset';
            if (productName.length() > 80) {
                productName = productName.substring(0, 80);
            }

            RLM_Amend_Breakdown__c row = new RLM_Amend_Breakdown__c();
            row.Quote__c = quoteId;
            row.Name = productName;
            row.Asset_Key__c = assetKey.length() > 18 ? assetKey.substring(0, 18) : assetKey;
            row.Is_Amending__c = card.isAmending == true;
            row.Amending_Badge__c = card.isAmending == true ? 'AMENDING' : '';
            row.Sort_Order__c = sortOrder;
            row.Current_Qty__c = currentQty;
            row.Current_ARR__c = currentArr;
            row.Current_MRR__c = currentMrr;
            populateCurrentCommercialFields(row, card, assetsById.get(card.assetId));
            row.This_Add_Qty__c = addQty;
            row.This_Add_ARR__c = addArr;
            row.This_Add_MRR__c = addMrr;
            row.This_Add_Prorated__c = addProrated;
            row.This_Add_Start_Date__c = card.thisAddStartDate;
            row.This_Add_End_Date__c = card.thisAddEndDate;
            row.This_Add_Discount__c = card.thisAddDiscountPercent;
            row.This_Add_List_Price__c = card.thisAddListPrice;
            row.This_Add_Net_Unit_Price__c = card.thisAddNetUnitPrice;
            row.This_Add_Term_Months__c = card.thisAddTermMonths;
            if (card.thisAddDiscountPercent != null) {
                Decimal d = card.thisAddDiscountPercent.setScale(0, RoundingMode.HALF_UP);
                row.This_Add_Discount_Label__c = String.valueOf(d) + '%';
            } else {
                row.This_Add_Discount_Label__c = null;
            }
            row.Finalized_Qty__c = finalizedQty;
            row.Finalized_ARR__c = finalizedArr;
            row.Finalized_MRR__c = finalizedMrr;
            row.Finalized_Prorated__c = resolveFinalizedProrated(
                currentArr,
                finalizedArr,
                addProrated,
                card.thisAddTermMonths
            );
            rows.add(row);
            sortOrder++;
        }
        rows.addAll(buildCatalogAddRows(quoteId, sortOrder));
        return rows;
    }

    /**
     * Finalized Amount for DocGen: Current Amount (annual current ARR) plus
     * This add Amount (day-exact prorated charge).
     */
    @TestVisible
    private static Decimal resolveFinalizedProrated(
        Decimal currentArr,
        Decimal finalizedArr,
        Decimal thisAddProrated,
        Decimal termMonths
    ) {
        Decimal currentAmount = currentArr != null ? currentArr : 0;
        Decimal addAmount = thisAddProrated != null ? thisAddProrated : 0;
        return (currentAmount + addAmount).setScale(2, RoundingMode.HALF_UP);
    }

    /**
     * Stamp Current-contract commercial columns (dates, term, list/net) from the
     * installed Asset lifecycle and the card's ASP / timeline summary.
     */
    @TestVisible
    private static void populateCurrentCommercialFields(
        RLM_Amend_Breakdown__c row,
        AssetHistoryCard card,
        Asset asset
    ) {
        if (row == null) {
            return;
        }
        Date startDate = null;
        Date endDate = null;
        if (asset != null) {
            if (asset.LifecycleStartDate != null) {
                startDate = asset.LifecycleStartDate.date();
            }
            if (asset.LifecycleEndDate != null) {
                endDate = asset.LifecycleEndDate.date();
            }
        }
        row.Current_Start_Date__c = startDate;
        row.Current_End_Date__c = endDate;
        row.Current_Term_Months__c = termMonthsBetween(startDate, endDate);

        Decimal netUnit = card != null && card.summary != null
            ? card.summary.averagePaid
            : null;
        Decimal listUnit = weightedAverageListPrice(card);
        Decimal qty = row.Current_Qty__c;
        Decimal arr = row.Current_ARR__c;
        if (netUnit == null && qty != null && qty != 0 && arr != null) {
            netUnit = (arr / qty).setScale(4, RoundingMode.HALF_UP);
        }
        if (listUnit == null) {
            listUnit = netUnit;
        }
        row.Current_List_Price__c = listUnit;
        row.Current_Net_Unit_Price__c = netUnit;
    }

    @TestVisible
    private static Decimal weightedAverageListPrice(AssetHistoryCard card) {
        if (card == null || card.timeline == null || card.timeline.isEmpty()) {
            return null;
        }
        Decimal weight = 0;
        Decimal qty = 0;
        for (HistoryRow r : card.timeline) {
            if (r == null || r.listPrice == null) {
                continue;
            }
            Decimal q = r.quantity != null ? r.quantity : 0;
            if (q <= 0) {
                continue;
            }
            weight += r.listPrice * q;
            qty += q;
        }
        if (qty <= 0) {
            return null;
        }
        return (weight / qty).setScale(4, RoundingMode.HALF_UP);
    }

    @TestVisible
    private static Decimal termMonthsBetween(Date startDate, Date endDate) {
        if (startDate == null || endDate == null) {
            return null;
        }
        Integer days = startDate.daysBetween(endDate);
        if (days < 0) {
            return 0;
        }
        // Align with PricingTermCount * 12 (four decimals) used on quote lines.
        return (Decimal.valueOf(days) / 30.44).setScale(4, RoundingMode.HALF_UP);
    }

    @TestVisible
    private static Decimal termMonthsFromPricingTermCount(Decimal pricingTermCount) {
        if (pricingTermCount == null) {
            return null;
        }
        // Four decimals so ARR × (term/12) closely matches day-exact prorated Amount.
        return (pricingTermCount * 12).setScale(4, RoundingMode.HALF_UP);
    }

    /**
     * Breakdown rows for products added from the catalog on this amendment.
     * These lines have no Source Asset (nothing installed to amend), so they
     * produce no AssetHistoryCard and would otherwise be missing entirely from
     * the proposal's This add / Finalized tables. Current is zero by definition;
     * Finalized equals This add. Lines are grouped by product so multiple
     * catalog lines for the same SKU render as one row.
     */
    @TestVisible
    private static List<RLM_Amend_Breakdown__c> buildCatalogAddRows(
        Id quoteId,
        Integer startSortOrder
    ) {
        List<RLM_Amend_Breakdown__c> rows = new List<RLM_Amend_Breakdown__c>();
        if (quoteId == null) {
            return rows;
        }
        Map<Id, RLM_Amend_Breakdown__c> byProduct = new Map<Id, RLM_Amend_Breakdown__c>();
        List<Id> productOrder = new List<Id>();
        Map<Id, Decimal> discWeight = new Map<Id, Decimal>();
        Map<Id, Decimal> discQty = new Map<Id, Decimal>();
        Map<Id, Decimal> listWeight = new Map<Id, Decimal>();
        Map<Id, Decimal> listQty = new Map<Id, Decimal>();
        Map<Id, Decimal> termWeight = new Map<Id, Decimal>();
        Map<Id, Decimal> termQty = new Map<Id, Decimal>();

        for (QuoteLineItem qli : [
            SELECT
                Product2Id,
                Product2.Name,
                Quantity,
                ListPrice,
                NetUnitPrice,
                Discount,
                TotalPrice,
                StartDate,
                EndDate,
                PricingTermCount,
                QuoteAction.SourceAssetId
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
                AND Product2Id != null
                AND (QuoteActionId = null OR QuoteAction.SourceAssetId = null)
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ]) {
            Decimal qty = qli.Quantity != null ? qli.Quantity : 0;
            if (qty <= 0) {
                continue;
            }
            Decimal effectiveNet = resolveEffectiveNetUnitPrice(
                qli.NetUnitPrice,
                qli.ListPrice,
                qli.Discount
            );
            Decimal lineArr = effectiveNet != null ? effectiveNet * qty : 0;

            RLM_Amend_Breakdown__c row = byProduct.get(qli.Product2Id);
            if (row == null) {
                row = new RLM_Amend_Breakdown__c();
                row.Quote__c = quoteId;
                String productName = qli.Product2 != null && String.isNotBlank(qli.Product2.Name)
                    ? qli.Product2.Name
                    : 'New product';
                row.Name = productName.length() > 80 ? productName.substring(0, 80) : productName;
                // No Source Asset — key on the product so the row stays stable.
                row.Asset_Key__c = String.valueOf(qli.Product2Id);
                // New products are part of this amendment, not the prior footprint.
                row.Is_Amending__c = true;
                row.Amending_Badge__c = 'NEW';
                row.Current_Qty__c = 0;
                row.Current_ARR__c = 0;
                row.Current_MRR__c = 0;
                row.This_Add_Qty__c = 0;
                row.This_Add_ARR__c = 0;
                row.This_Add_MRR__c = 0;
                row.This_Add_Prorated__c = 0;
                byProduct.put(qli.Product2Id, row);
                productOrder.add(qli.Product2Id);
            }

            row.This_Add_Qty__c += qty;
            row.This_Add_ARR__c += lineArr;
            row.This_Add_Prorated__c += qli.TotalPrice != null ? qli.TotalPrice : 0;
            if (qli.StartDate != null
                && (row.This_Add_Start_Date__c == null
                    || qli.StartDate < row.This_Add_Start_Date__c)) {
                row.This_Add_Start_Date__c = qli.StartDate;
            }
            if (qli.EndDate != null
                && (row.This_Add_End_Date__c == null
                    || qli.EndDate > row.This_Add_End_Date__c)) {
                row.This_Add_End_Date__c = qli.EndDate;
            }
            if (qli.ListPrice != null) {
                Decimal prevLw = listWeight.containsKey(qli.Product2Id)
                    ? listWeight.get(qli.Product2Id)
                    : 0;
                Decimal prevLq = listQty.containsKey(qli.Product2Id)
                    ? listQty.get(qli.Product2Id)
                    : 0;
                listWeight.put(qli.Product2Id, prevLw + (qli.ListPrice * qty));
                listQty.put(qli.Product2Id, prevLq + qty);
            }
            Decimal termMo = termMonthsFromPricingTermCount(qli.PricingTermCount);
            if (termMo == null) {
                termMo = termMonthsBetween(qli.StartDate, qli.EndDate);
            }
            if (termMo != null) {
                Decimal prevTw = termWeight.containsKey(qli.Product2Id)
                    ? termWeight.get(qli.Product2Id)
                    : 0;
                Decimal prevTq = termQty.containsKey(qli.Product2Id)
                    ? termQty.get(qli.Product2Id)
                    : 0;
                termWeight.put(qli.Product2Id, prevTw + (termMo * qty));
                termQty.put(qli.Product2Id, prevTq + qty);
            }
            Decimal lineDisc = resolveDiscountPercent(
                qli.Discount,
                qli.ListPrice,
                qli.NetUnitPrice
            );
            if (lineDisc != null) {
                Decimal prevDw = discWeight.containsKey(qli.Product2Id)
                    ? discWeight.get(qli.Product2Id)
                    : 0;
                Decimal prevDq = discQty.containsKey(qli.Product2Id)
                    ? discQty.get(qli.Product2Id)
                    : 0;
                discWeight.put(qli.Product2Id, prevDw + (lineDisc * qty));
                discQty.put(qli.Product2Id, prevDq + qty);
            }
        }

        Integer sortOrder = startSortOrder != null ? startSortOrder : 0;
        for (Id productId : productOrder) {
            RLM_Amend_Breakdown__c row = byProduct.get(productId);
            row.Sort_Order__c = sortOrder;
            row.This_Add_ARR__c = row.This_Add_ARR__c.setScale(2, RoundingMode.HALF_UP);
            row.This_Add_MRR__c = (row.This_Add_ARR__c / 12).setScale(2, RoundingMode.HALF_UP);
            row.This_Add_Prorated__c =
                row.This_Add_Prorated__c.setScale(2, RoundingMode.HALF_UP);
            if (row.This_Add_Qty__c != null && row.This_Add_Qty__c != 0) {
                row.This_Add_Net_Unit_Price__c =
                    (row.This_Add_ARR__c / row.This_Add_Qty__c).setScale(4, RoundingMode.HALF_UP);
            }
            if (listQty.containsKey(productId) && listQty.get(productId) > 0) {
                row.This_Add_List_Price__c =
                    (listWeight.get(productId) / listQty.get(productId))
                        .setScale(4, RoundingMode.HALF_UP);
            }
            if (termQty.containsKey(productId) && termQty.get(productId) > 0) {
                row.This_Add_Term_Months__c =
                    (termWeight.get(productId) / termQty.get(productId))
                        .setScale(4, RoundingMode.HALF_UP);
            } else {
                row.This_Add_Term_Months__c = termMonthsBetween(
                    row.This_Add_Start_Date__c,
                    row.This_Add_End_Date__c
                );
            }
            if (discQty.containsKey(productId) && discQty.get(productId) > 0) {
                Decimal pct = (discWeight.get(productId) / discQty.get(productId))
                    .setScale(2, RoundingMode.HALF_UP);
                row.This_Add_Discount__c = pct;
                row.This_Add_Discount_Label__c =
                    String.valueOf(pct.setScale(0, RoundingMode.HALF_UP)) + '%';
            }
            // Nothing installed, so the finalized contract position is the add.
            row.Finalized_Qty__c = row.This_Add_Qty__c;
            row.Finalized_ARR__c = row.This_Add_ARR__c;
            row.Finalized_MRR__c = row.This_Add_MRR__c;
            row.Finalized_Prorated__c = resolveFinalizedProrated(
                row.Current_ARR__c,
                row.Finalized_ARR__c,
                row.This_Add_Prorated__c,
                row.This_Add_Term_Months__c
            );
            rows.add(row);
            sortOrder++;
        }
        return rows;
    }

    /**
     * v1: only models positive-qty amend lines (add / upsell).
     * Negative qty (decrease / cancel) returns DecreaseParked.
     * Proposed = ASP Current footprint + this Quote's add economics (not timeline re-sum).
     */
    private static ProjectionImpact buildAddProjection(
        Id quoteId,
        HistorySummary baseline
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
        Decimal amendQty = 0;
        Decimal amendArr = 0;
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
            Decimal effectiveNet = resolveEffectiveNetUnitPrice(
                qli.NetUnitPrice,
                qli.ListPrice,
                qli.Discount
            );
            HistoryRow tranche = new HistoryRow();
            tranche.quantity = qty;
            tranche.listPrice = qli.ListPrice;
            tranche.netUnitPrice = effectiveNet;
            tranche.discountPercent = resolveDiscountPercent(
                qli.Discount,
                qli.ListPrice,
                effectiveNet
            );
            enrichLineEconomics(tranche);
            amendQty += qty;
            if (tranche.arr != null) {
                amendArr += tranche.arr;
            } else if (effectiveNet != null) {
                amendArr += effectiveNet * qty;
            }
            if (effectiveNet != null) {
                amendPaidWeight += effectiveNet * qty;
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

        Decimal baseQty = baseline != null && baseline.totalQuantity != null ? baseline.totalQuantity : 0;
        Decimal baseArr = baseline != null && baseline.currentArr != null ? baseline.currentArr : 0;

        HistorySummary projected = new HistorySummary();
        projected.assetName = baseline != null ? baseline.assetName : null;
        projected.totalQuantity = baseQty + amendQty;
        projected.currentArr = (baseArr + amendArr).setScale(2, RoundingMode.HALF_UP);
        projected.currentMrr = (projected.currentArr / 12).setScale(2, RoundingMode.HALF_UP);
        if (amendQty > 0) {
            projected.averagePaid = (amendPaidWeight / amendQty).setScale(2, RoundingMode.HALF_UP);
            projected.averageDiscountPercent =
                (amendDiscWeight / amendQty).setScale(2, RoundingMode.HALF_UP);
        } else if (baseline != null) {
            projected.averagePaid = baseline.averagePaid;
            projected.averageDiscountPercent = baseline.averageDiscountPercent;
        }

        impact.mode = 'Add';
        impact.projected = projected;
        impact.amendmentQuantity = amendQty;
        if (amendQty > 0) {
            impact.amendmentPaid = (amendPaidWeight / amendQty).setScale(2, RoundingMode.HALF_UP);
            impact.amendmentDiscountPercent =
                (amendDiscWeight / amendQty).setScale(2, RoundingMode.HALF_UP);
        }
        impact.deltaQuantity = amendQty;
        impact.deltaAveragePaid = deltaDec(projected.averagePaid, baseline != null ? baseline.averagePaid : null);
        impact.deltaAverageDiscountPercent = deltaDec(
            projected.averageDiscountPercent,
            baseline != null ? baseline.averageDiscountPercent : null
        );
        impact.deltaArr = amendArr.setScale(2, RoundingMode.HALF_UP);
        impact.deltaMrr = (amendArr / 12).setScale(2, RoundingMode.HALF_UP);
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

    /**
     * Group flat history rows into one card per installed Asset in the footprint.
     * Summary qty/MRR prefer latest Asset State Period; avg paid from timeline.
     * amendingAssetIds marks which cards this Quote is actively amending.
     */
    @TestVisible
    private static List<AssetHistoryCard> buildAssetHistoryCards(
        Set<Id> assetIds,
        Map<Id, String> assetNames,
        List<HistoryRow> allRows,
        Set<Id> amendingAssetIds
    ) {
        List<AssetHistoryCard> cards = new List<AssetHistoryCard>();
        if (assetIds == null || assetIds.isEmpty()) {
            return cards;
        }
        Map<Id, List<HistoryRow>> rowsByAsset = new Map<Id, List<HistoryRow>>();
        for (Id assetId : assetIds) {
            rowsByAsset.put(assetId, new List<HistoryRow>());
        }
        if (allRows != null) {
            for (HistoryRow row : allRows) {
                if (row.assetId == null || !rowsByAsset.containsKey(row.assetId)) {
                    continue;
                }
                rowsByAsset.get(row.assetId).add(row);
            }
        }
        Map<Id, AssetStateSnapshot> snaps = installedStateByAsset(assetIds);
        List<AssetHistoryCard> amending = new List<AssetHistoryCard>();
        List<AssetHistoryCard> siblings = new List<AssetHistoryCard>();
        for (Id assetId : assetIds) {
            List<HistoryRow> timeline = rowsByAsset.get(assetId);
            AssetHistoryCard card = new AssetHistoryCard();
            card.assetId = assetId;
            card.assetName = assetNames != null ? assetNames.get(assetId) : null;
            card.isAmending = amendingAssetIds != null && amendingAssetIds.contains(assetId);
            card.timeline = timeline;
            card.counts = countChangeKinds(timeline);
            HistorySummary fromTimeline = buildSummaryFromRows(timeline, assetNames);
            AssetStateSnapshot snap = snaps.get(assetId);
            card.summary = new HistorySummary();
            card.summary.assetName = card.assetName;
            card.summary.averagePaid = fromTimeline.averagePaid;
            card.summary.averageDiscountPercent = fromTimeline.averageDiscountPercent;
            if (snap != null && snap.quantity != null) {
                card.installedQuantity = snap.quantity;
                card.summary.totalQuantity = snap.quantity;
            } else {
                card.installedQuantity = fromTimeline.totalQuantity;
                card.summary.totalQuantity = fromTimeline.totalQuantity;
            }
            if (snap != null && snap.mrr != null) {
                card.installedMrr = snap.mrr;
                card.summary.currentMrr = snap.mrr.setScale(2, RoundingMode.HALF_UP);
                card.summary.currentArr = (snap.mrr * 12).setScale(2, RoundingMode.HALF_UP);
            } else {
                card.installedMrr = fromTimeline.currentMrr;
                card.summary.currentMrr = fromTimeline.currentMrr;
                card.summary.currentArr = fromTimeline.currentArr;
            }
            if (card.isAmending == true) {
                amending.add(card);
            } else {
                siblings.add(card);
            }
        }
        // Amending assets first so sellers can single out the change against the footprint.
        cards.addAll(amending);
        cards.addAll(siblings);
        return cards;
    }

    /** Overload for unit tests that predate the amending-asset flag. */
    @TestVisible
    private static List<AssetHistoryCard> buildAssetHistoryCards(
        Set<Id> assetIds,
        Map<Id, String> assetNames,
        List<HistoryRow> allRows
    ) {
        return buildAssetHistoryCards(assetIds, assetNames, allRows, assetIds);
    }

    /**
     * Attach this Quote's QLI deltas to each Source Asset card (This add → Finalized).
     * Catalog lines with no SourceAssetId are skipped (no installed history to amend).
     */
    @TestVisible
    private static void applyQuoteLineImpactToAssetCards(
        Id quoteId,
        List<AssetHistoryCard> cards
    ) {
        if (quoteId == null || cards == null || cards.isEmpty()) {
            return;
        }
        Map<Id, AssetHistoryCard> byAsset = new Map<Id, AssetHistoryCard>();
        for (AssetHistoryCard card : cards) {
            if (card.assetId != null) {
                card.impactMode = 'None';
                card.thisAddQty = 0;
                card.thisAddArr = 0;
                card.thisAddMrr = 0;
                card.thisAddProrated = 0;
                card.thisAddStartDate = null;
                card.thisAddEndDate = null;
                card.thisAddDiscountPercent = null;
                card.thisAddListPrice = null;
                card.thisAddNetUnitPrice = null;
                card.thisAddTermMonths = null;
                byAsset.put(card.assetId, card);
            }
        }
        if (byAsset.isEmpty()) {
            return;
        }

        Map<Id, Decimal> addQty = new Map<Id, Decimal>();
        Map<Id, Decimal> addArr = new Map<Id, Decimal>();
        Map<Id, Decimal> addProrated = new Map<Id, Decimal>();
        Map<Id, Date> addStart = new Map<Id, Date>();
        Map<Id, Date> addEnd = new Map<Id, Date>();
        Map<Id, Decimal> addDiscWeight = new Map<Id, Decimal>();
        Map<Id, Decimal> addDiscQty = new Map<Id, Decimal>();
        Map<Id, Decimal> addListWeight = new Map<Id, Decimal>();
        Map<Id, Decimal> addListQty = new Map<Id, Decimal>();
        Map<Id, Decimal> addTermWeight = new Map<Id, Decimal>();
        Map<Id, Decimal> addTermQty = new Map<Id, Decimal>();
        Map<Id, Boolean> hasDecrease = new Map<Id, Boolean>();
        Map<Id, Boolean> hasAdd = new Map<Id, Boolean>();

        for (QuoteLineItem qli : [
            SELECT
                Quantity,
                ListPrice,
                NetUnitPrice,
                Discount,
                TotalPrice,
                StartDate,
                EndDate,
                PricingTermCount,
                QuoteAction.SourceAssetId
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            WITH USER_MODE
        ]) {
            if (qli.QuoteAction == null || qli.QuoteAction.SourceAssetId == null) {
                continue;
            }
            Id assetId = qli.QuoteAction.SourceAssetId;
            if (!byAsset.containsKey(assetId)) {
                continue;
            }
            Decimal qty = qli.Quantity != null ? qli.Quantity : 0;
            if (qty < 0) {
                hasDecrease.put(assetId, true);
                continue;
            }
            if (qty == 0) {
                continue;
            }
            hasAdd.put(assetId, true);
            Decimal effectiveNet = resolveEffectiveNetUnitPrice(
                qli.NetUnitPrice,
                qli.ListPrice,
                qli.Discount
            );
            Decimal prevQty = addQty.containsKey(assetId) ? addQty.get(assetId) : 0;
            addQty.put(assetId, prevQty + qty);
            if (effectiveNet != null) {
                Decimal prevArr = addArr.containsKey(assetId) ? addArr.get(assetId) : 0;
                addArr.put(assetId, prevArr + (effectiveNet * qty));
            }
            if (qli.TotalPrice != null) {
                Decimal prevPr = addProrated.containsKey(assetId) ? addProrated.get(assetId) : 0;
                addProrated.put(assetId, prevPr + qli.TotalPrice);
            }
            if (qli.StartDate != null) {
                Date prevStart = addStart.get(assetId);
                if (prevStart == null || qli.StartDate < prevStart) {
                    addStart.put(assetId, qli.StartDate);
                }
            }
            if (qli.EndDate != null) {
                Date prevEnd = addEnd.get(assetId);
                if (prevEnd == null || qli.EndDate > prevEnd) {
                    addEnd.put(assetId, qli.EndDate);
                }
            }
            if (qli.ListPrice != null && qty > 0) {
                Decimal prevLw = addListWeight.containsKey(assetId) ? addListWeight.get(assetId) : 0;
                Decimal prevLq = addListQty.containsKey(assetId) ? addListQty.get(assetId) : 0;
                addListWeight.put(assetId, prevLw + (qli.ListPrice * qty));
                addListQty.put(assetId, prevLq + qty);
            }
            Decimal termMo = termMonthsFromPricingTermCount(qli.PricingTermCount);
            if (termMo == null) {
                termMo = termMonthsBetween(qli.StartDate, qli.EndDate);
            }
            if (termMo != null && qty > 0) {
                Decimal prevTw = addTermWeight.containsKey(assetId) ? addTermWeight.get(assetId) : 0;
                Decimal prevTq = addTermQty.containsKey(assetId) ? addTermQty.get(assetId) : 0;
                addTermWeight.put(assetId, prevTw + (termMo * qty));
                addTermQty.put(assetId, prevTq + qty);
            }
            Decimal lineDisc = resolveDiscountPercent(
                qli.Discount,
                qli.ListPrice,
                qli.NetUnitPrice
            );
            if (lineDisc != null && qty > 0) {
                Decimal prevDw = addDiscWeight.containsKey(assetId) ? addDiscWeight.get(assetId) : 0;
                Decimal prevDq = addDiscQty.containsKey(assetId) ? addDiscQty.get(assetId) : 0;
                addDiscWeight.put(assetId, prevDw + (lineDisc * qty));
                addDiscQty.put(assetId, prevDq + qty);
            }
        }

        for (Id assetId : byAsset.keySet()) {
            AssetHistoryCard card = byAsset.get(assetId);
            Boolean dec = hasDecrease.containsKey(assetId) && hasDecrease.get(assetId);
            Boolean add = hasAdd.containsKey(assetId) && hasAdd.get(assetId);
            if (dec && !add) {
                card.impactMode = 'DecreaseParked';
                card.impactMessage =
                    'License decrease on this asset — impact modeling for reductions is not enabled yet.';
                continue;
            }
            if (dec && add) {
                card.impactMode = 'DecreaseParked';
                card.impactMessage =
                    'This asset mixes adds and decreases — impact modeling supports add/upsell only for now.';
                continue;
            }
            if (!add) {
                card.impactMode = 'None';
                card.impactMessage = 'No positive amendment quantity on this asset yet.';
                // Finalized matches current when no add.
                card.finalizedQty = card.summary != null ? card.summary.totalQuantity : card.installedQuantity;
                card.finalizedArr = card.summary != null ? card.summary.currentArr : null;
                card.finalizedMrr = card.summary != null ? card.summary.currentMrr : card.installedMrr;
                card.deltaQty = 0;
                card.deltaArr = 0;
                card.deltaMrr = 0;
                continue;
            }

            Decimal tQty = addQty.containsKey(assetId) ? addQty.get(assetId) : 0;
            Decimal tArr = addArr.containsKey(assetId) ? addArr.get(assetId) : 0;
            Decimal tPr = addProrated.containsKey(assetId) ? addProrated.get(assetId) : 0;
            card.impactMode = 'Add';
            card.thisAddQty = tQty;
            card.thisAddArr = tArr.setScale(2, RoundingMode.HALF_UP);
            card.thisAddMrr = (tArr / 12).setScale(2, RoundingMode.HALF_UP);
            card.thisAddProrated = tPr.setScale(2, RoundingMode.HALF_UP);
            card.thisAddStartDate = addStart.get(assetId);
            card.thisAddEndDate = addEnd.get(assetId);
            if (addDiscQty.containsKey(assetId) && addDiscQty.get(assetId) > 0) {
                card.thisAddDiscountPercent =
                    (addDiscWeight.get(assetId) / addDiscQty.get(assetId))
                        .setScale(2, RoundingMode.HALF_UP);
            }
            if (addListQty.containsKey(assetId) && addListQty.get(assetId) > 0) {
                card.thisAddListPrice =
                    (addListWeight.get(assetId) / addListQty.get(assetId))
                        .setScale(4, RoundingMode.HALF_UP);
            }
            if (tQty != null && tQty != 0) {
                card.thisAddNetUnitPrice = (tArr / tQty).setScale(4, RoundingMode.HALF_UP);
            }
            if (addTermQty.containsKey(assetId) && addTermQty.get(assetId) > 0) {
                card.thisAddTermMonths =
                    (addTermWeight.get(assetId) / addTermQty.get(assetId))
                        .setScale(4, RoundingMode.HALF_UP);
            } else {
                card.thisAddTermMonths =
                    termMonthsBetween(card.thisAddStartDate, card.thisAddEndDate);
            }

            Decimal baseQty = card.summary != null && card.summary.totalQuantity != null
                ? card.summary.totalQuantity
                : (card.installedQuantity != null ? card.installedQuantity : 0);
            Decimal baseArr = card.summary != null && card.summary.currentArr != null
                ? card.summary.currentArr
                : 0;
            Decimal baseMrr = card.summary != null && card.summary.currentMrr != null
                ? card.summary.currentMrr
                : (card.installedMrr != null ? card.installedMrr : 0);

            card.finalizedQty = baseQty + tQty;
            card.finalizedArr = (baseArr + tArr).setScale(2, RoundingMode.HALF_UP);
            card.finalizedMrr = (baseMrr + (tArr / 12)).setScale(2, RoundingMode.HALF_UP);
            card.deltaQty = tQty;
            card.deltaArr = card.thisAddArr;
            card.deltaMrr = card.thisAddMrr;
            card.impactMessage = null;
        }
    }

    @TestVisible
    private static AssetHistoryCounts countChangeKinds(List<HistoryRow> timeline) {
        AssetHistoryCounts counts = new AssetHistoryCounts();
        counts.initialSale = 0;
        counts.addOn = 0;
        counts.decrease = 0;
        counts.renew = 0;
        counts.other = 0;
        if (timeline == null) {
            return counts;
        }
        // Count distinct AssetActions, not every source tranche.
        Set<Id> seenActions = new Set<Id>();
        for (HistoryRow row : timeline) {
            if (row.actionId != null) {
                if (seenActions.contains(row.actionId)) {
                    continue;
                }
                seenActions.add(row.actionId);
            }
            String kind = String.isNotBlank(row.changeKind)
                ? row.changeKind
                : classifyChangeKind(row);
            if (kind == 'Initial') {
                counts.initialSale++;
            } else if (kind == 'Add') {
                counts.addOn++;
            } else if (kind == 'Decrease') {
                counts.decrease++;
            } else if (kind == 'Renew') {
                counts.renew++;
            } else {
                counts.other++;
            }
        }
        return counts;
    }

    /**
     * Map platform Type / CategoryEnum / qty Δ into a stable UI kind.
     */
    @TestVisible
    private static String classifyChangeKind(HistoryRow row) {
        if (row == null) {
            return 'Other';
        }
        String cat = row.category != null ? row.category.toLowerCase() : '';
        String typ = row.actionType != null ? row.actionType.toLowerCase() : '';
        Decimal qtyDelta = row.quantityChange;
        if (qtyDelta == null && row.quantity != null) {
            // Source quantity is often the period qty, not Δ — only use when action Δ missing.
            qtyDelta = null;
        }
        if (
            cat.contains('initial') ||
            cat.contains('newsale') ||
            cat.contains('new sale') ||
            typ.contains('generate') ||
            typ == 'new'
        ) {
            return 'Initial';
        }
        if (cat.contains('renew') || typ.contains('renew')) {
            return 'Renew';
        }
        if (
            cat.contains('cancel') ||
            cat.contains('downsell') ||
            cat.contains('downgrade') ||
            cat.contains('decrease') ||
            (qtyDelta != null && qtyDelta < 0)
        ) {
            return 'Decrease';
        }
        if (
            cat.contains('upsell') ||
            cat.contains('cross') ||
            cat.contains('upgrade') ||
            (qtyDelta != null && qtyDelta > 0)
        ) {
            return 'Add';
        }
        if (typ.contains('amend') && qtyDelta != null && qtyDelta > 0) {
            return 'Add';
        }
        if (typ.contains('amend') && qtyDelta != null && qtyDelta < 0) {
            return 'Decrease';
        }
        return 'Other';
    }

    private static void enrichLineEconomics(HistoryRow row) {
        if (row == null) {
            return;
        }
        Decimal qty = row.quantity != null ? row.quantity : row.quantityChange;
        if (qty == null || qty <= 0 || row.netUnitPrice == null) {
            row.arr = 0;
            row.mrr = 0;
            return;
        }
        row.arr = (row.netUnitPrice * qty).setScale(2, RoundingMode.HALF_UP);
        row.mrr = (row.arr / 12).setScale(2, RoundingMode.HALF_UP);
    }

    /**
     * Net unit for ARR/MRR KPIs. Prefer platform NetUnitPrice; when Quote Line
     * Details own sales price the QLI NetUnitPrice is often null — fall back to
     * List × (1 − Discount%) so Finalized / This Add stay consistent with Studio preview.
     */
    @TestVisible
    public static Decimal resolveEffectiveNetUnitPrice(
        Decimal netUnitPrice,
        Decimal listPrice,
        Decimal discountPercent
    ) {
        if (netUnitPrice != null) {
            return netUnitPrice;
        }
        if (listPrice == null) {
            return null;
        }
        Decimal disc = discountPercent != null ? discountPercent : 0;
        return (listPrice * (1 - (disc / 100))).setScale(6, RoundingMode.HALF_UP);
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