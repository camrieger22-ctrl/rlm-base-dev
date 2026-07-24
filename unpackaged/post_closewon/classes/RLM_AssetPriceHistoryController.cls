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
        /** Line ARR = net unit × qty (installed tranche or amend delta). */
        @AuraEnabled public Decimal arr;
        /** Line MRR = ARR / 12. */
        @AuraEnabled public Decimal mrr;
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
     * Amendment Quote line for Studio Working Changes.
     * quantity is the RLM delta on the QLI (0 when QuoteAction is No Change).
     */
    public class WorkingLine {
        @AuraEnabled public Id id;
        @AuraEnabled public String productName;
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public Decimal listPrice;
        @AuraEnabled public Decimal netUnitPrice;
        @AuraEnabled public Decimal discountPercent;
        @AuraEnabled public Decimal totalPrice;
        @AuraEnabled public String quoteActionType;
        @AuraEnabled public Id quoteActionId;
        @AuraEnabled public Id sourceAssetId;
        /** Current installed qty from the source asset (when known). */
        @AuraEnabled public Decimal installedQuantity;
        /** Amendment service start (drives proration). */
        @AuraEnabled public Date startDate;
        /** Term end — platform-populated for amendments; read-only in Studio. */
        @AuraEnabled public Date endDate;
        /** This add's ARR contribution (qty × net), when qty > 0. */
        @AuraEnabled public Decimal addArr;
        @AuraEnabled public Decimal addMrr;
        /**
         * True when Quote Line Details exist (future-dated multi-ASP / ARC
         * breakdown). Sales price lives on details; Studio Update uses Place
         * Sales Transaction FORCE (requires Near Core Map Line Item + Advanced
         * Detail Line Pricing).
         */
        @AuraEnabled public Boolean hasQuoteLineDetails;
        /** True when line is a catalog Add (hard-deletable). */
        @AuraEnabled public Boolean isCatalogAdd;
        /**
         * QLI.PriceWaterfallIdentifier — "{lineItemId}:{executionId}" after
         * platform pricing. Used to fetch the OOTB pricing-procedure waterfall.
         */
        @AuraEnabled public String priceWaterfallIdentifier;
    }

    public class StudioPayload {
        @AuraEnabled public HistoryResponse history;
        @AuraEnabled public List<WorkingLine> workingLines;
        @AuraEnabled public String quoteNumber;
        @AuraEnabled public String quoteName;
        /** Parent Opportunity for scenario compare (may be null on unlinked amends). */
        @AuraEnabled public Id opportunityId;
        /** Quote.CalculationStatus after last pricing run (informational). */
        @AuraEnabled public String calculationStatus;
        /** Quote.ValidationResult — non-null means prices/transaction need attention. */
        @AuraEnabled public String validationResult;
    }

    /**
     * Sibling amend Quote on an Opportunity (scenario compare Phase 1).
     * Forecast commitment = Opportunity.SyncedQuoteId / Quote.IsSyncing.
     */
    public class ScenarioSummary {
        @AuraEnabled public Id quoteId;
        @AuraEnabled public String quoteNumber;
        @AuraEnabled public String name;
        @AuraEnabled public Decimal grandTotal;
        @AuraEnabled public Boolean isSynced;
        @AuraEnabled public String calculationStatus;
        @AuraEnabled public String validationResult;
    }

    /**
     * One column in the scenario compare matrix: This add + Finalized if selected.
     */
    public class ScenarioColumn {
        @AuraEnabled public Id quoteId;
        @AuraEnabled public String quoteNumber;
        @AuraEnabled public String name;
        @AuraEnabled public Boolean isSynced;
        @AuraEnabled public Decimal grandTotal;
        @AuraEnabled public String calculationStatus;
        /** Working-line rollup: add qty / ARR / MRR / prorated (term bill). */
        @AuraEnabled public Decimal thisAddQty;
        @AuraEnabled public Decimal thisAddArr;
        @AuraEnabled public Decimal thisAddMrr;
        @AuraEnabled public Decimal thisAddProrated;
        /** Qty-weighted average discount % across positive-qty working lines. */
        @AuraEnabled public Decimal thisAddDiscountPercent;
        /** Finalized contract if this quote were the forecast (proposed). */
        @AuraEnabled public Decimal finalizedQty;
        @AuraEnabled public Decimal finalizedArr;
        @AuraEnabled public Decimal finalizedMrr;
        @AuraEnabled public Decimal deltaQty;
        @AuraEnabled public Decimal deltaArr;
        @AuraEnabled public Decimal deltaMrr;
        /**
         * Primary working line for inline qty/disc Update from the compare matrix
         * (first positive-qty line, else first line).
         */
        @AuraEnabled public Id primaryLineItemId;
    }

    public class ScenarioCompareResponse {
        @AuraEnabled public Id opportunityId;
        @AuraEnabled public Id syncedQuoteId;
        /** Shared installed baseline (same Source Asset history across siblings). */
        @AuraEnabled public HistorySummary current;
        @AuraEnabled public List<ScenarioColumn> scenarios;
        @AuraEnabled public String message;
    }

    /** Result for createScenario / setForecastScenario mutations. */
    public class ScenarioMutationResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;
        @AuraEnabled public ScenarioSummary scenario;
        @AuraEnabled public Id opportunityId;
        @AuraEnabled public Id syncedQuoteId;
    }

    /**
     * Amendment Quotes on an Opportunity for scenario compare.
     * Not cacheable: sync / clone / reprice change the list frequently.
     */
    @AuraEnabled
    public static List<ScenarioSummary> listScenarios(Id opportunityId) {
        List<ScenarioSummary> out = new List<ScenarioSummary>();
        if (opportunityId == null || opportunityId.getSObjectType() != Opportunity.SObjectType) {
            return out;
        }
        Id oppId = Id.valueOf(String.valueOf(opportunityId));
        for (Quote q : [
            SELECT
                Id,
                QuoteNumber,
                Name,
                GrandTotal,
                IsSyncing,
                CalculationStatus,
                ValidationResult
            FROM Quote
            WHERE OpportunityId = :oppId AND OriginalActionType = 'Amend'
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ]) {
            ScenarioSummary row = new ScenarioSummary();
            row.quoteId = q.Id;
            row.quoteNumber = q.QuoteNumber;
            row.name = q.Name;
            row.grandTotal = q.GrandTotal;
            row.isSynced = q.IsSyncing == true;
            row.calculationStatus = q.CalculationStatus;
            row.validationResult = q.ValidationResult;
            out.add(row);
        }
        return out;
    }

    /**
     * Side-by-side impact of sibling amend Quotes on one Opportunity.
     * Reuses getStudioPayload KPI math per quote (Current shared from first
     * sibling with history). Intended for N ≤ ~5 scenarios.
     */
    @AuraEnabled
    public static ScenarioCompareResponse getScenarioCompare(Id opportunityId) {
        ScenarioCompareResponse resp = new ScenarioCompareResponse();
        resp.scenarios = new List<ScenarioColumn>();
        if (opportunityId == null || opportunityId.getSObjectType() != Opportunity.SObjectType) {
            resp.message = 'No opportunity Id provided.';
            return resp;
        }
        Id oppId = Id.valueOf(String.valueOf(opportunityId));
        resp.opportunityId = oppId;

        for (Opportunity opp : [
            SELECT Id, SyncedQuoteId
            FROM Opportunity
            WHERE Id = :oppId
            WITH USER_MODE
            LIMIT 1
        ]) {
            resp.syncedQuoteId = opp.SyncedQuoteId;
        }

        List<ScenarioSummary> siblings = listScenarios(oppId);
        if (siblings.isEmpty()) {
            resp.message = 'No amendment scenario quotes on this opportunity.';
            return resp;
        }

        for (ScenarioSummary sibling : siblings) {
            StudioPayload payload = getStudioPayload(sibling.quoteId);
            if (resp.current == null && payload.history != null && payload.history.summary != null) {
                resp.current = payload.history.summary;
            }
            resp.scenarios.add(buildScenarioColumn(sibling, payload));
        }
        if (resp.current == null) {
            resp.current = new HistorySummary();
        }
        return resp;
    }

    /**
     * Duplicate an amend Quote as a sibling scenario via OOTB Connect
     * quote-scoped clone (`/connect/rev/sales-transaction/actions/clone`).
     * Sets OpportunityId + Name on the clone. Discount may reset to 0 on clone
     * (platform behavior) — callers should re-apply qty/disc via
     * updateWorkingLineQuantity when modeling a distinct option.
     *
     * @param sourceQuoteId Amend Quote to clone
     * @param label Optional Name for the clone (defaults to "{source} — option")
     * @param opportunityId Opp to attach; falls back to source.OpportunityId
     */
    @AuraEnabled
    public static ScenarioMutationResult createScenario(
        Id sourceQuoteId,
        String label,
        Id opportunityId
    ) {
        ScenarioMutationResult result = new ScenarioMutationResult();
        result.success = false;
        if (sourceQuoteId == null || sourceQuoteId.getSObjectType() != Quote.SObjectType) {
            result.message = 'Source quote Id is required.';
            return result;
        }
        Id sourceId = Id.valueOf(String.valueOf(sourceQuoteId));

        List<Quote> sources = [
            SELECT Id, Name, QuoteNumber, OpportunityId, OriginalActionType, GrandTotal
            FROM Quote
            WHERE Id = :sourceId
            WITH USER_MODE
            LIMIT 1
        ];
        if (sources.isEmpty()) {
            result.message = 'Source quote was not found.';
            return result;
        }
        Quote source = sources[0];
        if (!isAmendScenarioQuote(source)) {
            result.message = 'Only amendment quotes can be duplicated as scenarios.';
            return result;
        }

        Id oppId = null;
        if (opportunityId != null && opportunityId.getSObjectType() == Opportunity.SObjectType) {
            oppId = Id.valueOf(String.valueOf(opportunityId));
        } else if (source.OpportunityId != null) {
            oppId = source.OpportunityId;
        }
        if (oppId == null) {
            result.message =
                'Opportunity Id is required (source quote has none). Pass opportunityId.';
            return result;
        }
        result.opportunityId = oppId;

        Id clonedQuoteId;
        try {
            clonedQuoteId = cloneSalesTransactionQuote(sourceId);
        } catch (AuraHandledException ahe) {
            result.message = ahe.getMessage();
            return result;
        } catch (Exception e) {
            result.message = 'Clone failed: ' + e.getMessage();
            return result;
        }
        if (clonedQuoteId == null) {
            result.message = 'Clone returned no quote Id.';
            return result;
        }

        String newName = String.isNotBlank(label)
            ? label.trim()
            : (String.isNotBlank(source.Name) ? source.Name + ' — option' : 'Amend scenario');
        if (newName.length() > 255) {
            newName = newName.substring(0, 255);
        }

        try {
            Quote cloned = new Quote(Id = clonedQuoteId, Name = newName, OpportunityId = oppId);
            update as user cloned;
        } catch (Exception e) {
            result.message =
                'Clone succeeded (' +
                clonedQuoteId +
                ') but could not set Name/Opportunity: ' +
                e.getMessage();
            return result;
        }

        List<ScenarioSummary> rows = listScenarios(oppId);
        for (ScenarioSummary row : rows) {
            if (row.quoteId == clonedQuoteId) {
                result.scenario = row;
                break;
            }
        }
        if (result.scenario == null) {
            result.scenario = new ScenarioSummary();
            result.scenario.quoteId = clonedQuoteId;
            result.scenario.name = newName;
            result.scenario.isSynced = false;
        }
        result.success = true;
        result.message = null;
        return result;
    }

    /**
     * Commit a scenario Quote as the Opportunity forecast (OOTB sync).
     * Sets Opportunity.SyncedQuoteId; IsSyncing flips on the Quotes.
     */
    @AuraEnabled
    public static ScenarioMutationResult setForecastScenario(Id opportunityId, Id quoteId) {
        ScenarioMutationResult result = new ScenarioMutationResult();
        result.success = false;
        if (opportunityId == null || opportunityId.getSObjectType() != Opportunity.SObjectType) {
            result.message = 'Opportunity Id is required.';
            return result;
        }
        if (quoteId == null || quoteId.getSObjectType() != Quote.SObjectType) {
            result.message = 'Quote Id is required.';
            return result;
        }
        Id oppId = Id.valueOf(String.valueOf(opportunityId));
        Id qId = Id.valueOf(String.valueOf(quoteId));
        result.opportunityId = oppId;

        List<Quote> quotes = [
            SELECT Id, Name, QuoteNumber, OpportunityId, OriginalActionType, GrandTotal, IsSyncing,
                CalculationStatus, ValidationResult
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        if (quotes.isEmpty()) {
            result.message = 'Quote was not found.';
            return result;
        }
        Quote q = quotes[0];
        if (q.OpportunityId != oppId) {
            result.message = 'Quote does not belong to that opportunity.';
            return result;
        }
        if (!isAmendScenarioQuote(q)) {
            result.message = 'Only amendment scenario quotes can be set as forecast.';
            return result;
        }

        try {
            Opportunity opp = new Opportunity(Id = oppId, SyncedQuoteId = qId);
            update as user opp;
        } catch (Exception e) {
            result.message = 'Could not sync quote to opportunity: ' + e.getMessage();
            return result;
        }

        result.syncedQuoteId = qId;
        result.scenario = new ScenarioSummary();
        result.scenario.quoteId = q.Id;
        result.scenario.quoteNumber = q.QuoteNumber;
        result.scenario.name = q.Name;
        result.scenario.grandTotal = q.GrandTotal;
        result.scenario.isSynced = true;
        result.scenario.calculationStatus = q.CalculationStatus;
        result.scenario.validationResult = q.ValidationResult;
        result.success = true;
        result.message = null;
        return result;
    }

    /**
     * Connect quote-scoped clone. Do not pass a QLI Id — that clones into the
     * same transaction (Phase 0 spike).
     */
    @TestVisible
    private static Id cloneSalesTransactionQuote(Id quoteId) {
        if (Test.isRunningTest() && testCloneSalesTransactionIdOverride != null) {
            return testCloneSalesTransactionIdOverride;
        }
        HttpRequest req = new HttpRequest();
        req.setMethod('POST');
        req.setEndpoint(
            URL.getOrgDomainUrl().toExternalForm()
                + '/services/data/v67.0/connect/rev/sales-transaction/actions/clone'
        );
        req.setHeader('Authorization', 'Bearer ' + getApiSessionId());
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(60000);
        Map<String, Object> body = new Map<String, Object>{
            'recordIds' => new List<String>{ String.valueOf(quoteId) },
            'salesTransactionId' => String.valueOf(quoteId)
        };
        req.setBody(JSON.serialize(body));
        HttpResponse httpRes = new Http().send(req);
        if (httpRes.getStatusCode() < 200 || httpRes.getStatusCode() >= 300) {
            throw new AuraHandledException(
                'Clone API ' +
                    httpRes.getStatusCode() +
                    ': ' +
                    truncateMessage(httpRes.getBody(), 240)
            );
        }
        Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(
            httpRes.getBody()
        );
        if (root.get('success') == false) {
            throw new AuraHandledException(
                'Clone failed: ' + truncateMessage(String.valueOf(root.get('errors')), 240)
            );
        }
        Object stxId = root.get('salesTransactionId');
        if (stxId == null || String.isBlank(String.valueOf(stxId))) {
            throw new AuraHandledException('Clone response missing salesTransactionId.');
        }
        return Id.valueOf(String.valueOf(stxId));
    }

    private static Boolean isAmendScenarioQuote(Quote q) {
        if (q == null) {
            return false;
        }
        if (Test.isRunningTest() && testBypassAmendScenarioCheck) {
            return true;
        }
        return q.OriginalActionType == 'Amend';
    }

    /** Test-only: skip Connect clone and return this Quote Id as the clone. */
    @TestVisible
    private static Id testCloneSalesTransactionIdOverride;

    /** Test-only: OriginalActionType is not DML-writeable in unit tests. */
    @TestVisible
    private static Boolean testBypassAmendScenarioCheck = false;

    @TestVisible
    private static ScenarioColumn buildScenarioColumn(
        ScenarioSummary sibling,
        StudioPayload payload
    ) {
        ScenarioColumn col = new ScenarioColumn();
        col.quoteId = sibling.quoteId;
        col.quoteNumber = sibling.quoteNumber;
        col.name = sibling.name;
        col.isSynced = sibling.isSynced;
        col.grandTotal = sibling.grandTotal;
        col.calculationStatus = sibling.calculationStatus;

        Decimal addQty = 0;
        Decimal addArr = 0;
        Decimal addMrr = 0;
        Decimal prorated = 0;
        Decimal discWeight = 0;
        Decimal discQty = 0;
        Id primaryLineId = null;
        Id fallbackLineId = null;
        if (payload != null && payload.workingLines != null) {
            for (WorkingLine line : payload.workingLines) {
                if (fallbackLineId == null && line.id != null) {
                    fallbackLineId = line.id;
                }
                Decimal q = line.quantity != null ? line.quantity : 0;
                if (q <= 0) {
                    continue;
                }
                if (primaryLineId == null && line.id != null) {
                    primaryLineId = line.id;
                }
                addQty += q;
                if (line.addArr != null) {
                    addArr += line.addArr;
                }
                if (line.addMrr != null) {
                    addMrr += line.addMrr;
                }
                if (line.totalPrice != null) {
                    prorated += line.totalPrice;
                }
                if (line.discountPercent != null) {
                    discWeight += line.discountPercent * q;
                    discQty += q;
                }
            }
        }
        col.primaryLineItemId = primaryLineId != null ? primaryLineId : fallbackLineId;
        col.thisAddQty = addQty;
        col.thisAddArr = addArr.setScale(2, RoundingMode.HALF_UP);
        col.thisAddMrr = addMrr.setScale(2, RoundingMode.HALF_UP);
        col.thisAddProrated = prorated.setScale(2, RoundingMode.HALF_UP);
        col.thisAddDiscountPercent = discQty > 0
            ? (discWeight / discQty).setScale(2, RoundingMode.HALF_UP)
            : null;

        HistorySummary baseline =
            payload != null && payload.history != null ? payload.history.summary : null;
        HistorySummary proposed = null;
        ProjectionImpact projection =
            payload != null && payload.history != null ? payload.history.projection : null;
        if (projection != null && projection.mode == 'Add' && projection.projected != null) {
            proposed = projection.projected;
            col.deltaQty = projection.deltaQuantity;
            col.deltaArr = projection.deltaArr;
            col.deltaMrr = projection.deltaMrr;
        } else if (baseline != null) {
            proposed = baseline;
            col.deltaQty = 0;
            col.deltaArr = 0;
            col.deltaMrr = 0;
        }
        if (proposed != null) {
            col.finalizedQty = proposed.totalQuantity;
            col.finalizedArr = proposed.currentArr;
            col.finalizedMrr = proposed.currentMrr;
        }
        return col;
    }

    /**
     * Amendment Studio payload: history/projection KPIs + working Quote lines.
     * Not cacheable (same timing reasons as getHistoryForQuote).
     */
    @AuraEnabled
    public static StudioPayload getStudioPayload(Id quoteId) {
        StudioPayload payload = new StudioPayload();
        payload.workingLines = new List<WorkingLine>();
        payload.history = getHistoryForQuote(quoteId);
        if (quoteId == null || quoteId.getSObjectType() != Quote.SObjectType) {
            return payload;
        }
        Id qId = Id.valueOf(String.valueOf(quoteId));
        for (Quote q : [
            SELECT Id, QuoteNumber, Name, OpportunityId, CalculationStatus, ValidationResult
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ]) {
            payload.quoteNumber = q.QuoteNumber;
            payload.quoteName = q.Name;
            payload.opportunityId = q.OpportunityId;
            payload.calculationStatus = q.CalculationStatus;
            payload.validationResult = q.ValidationResult;
        }
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
            WorkingLine line = new WorkingLine();
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
                line.isCatalogAdd = qli.QuoteAction.Type == 'Add';
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
            payload.workingLines.add(line);
        }
        return payload;
    }

    /**
     * Amendment Studio: set amendment delta qty and/or list discount % and/or
     * service start date on a working line. Flips QuoteAction No Change → Amend
     * when needed, force-reprices via Place Sales Transaction, returns payload.
     *
     * EndDate is never written here — amendment term end stays platform-owned.
     */
    @AuraEnabled
    public static StudioPayload updateWorkingLineQuantity(
        Id quoteId,
        Id lineItemId,
        Decimal newQuantity,
        Decimal discountPercent,
        Date startDate
    ) {
        if (quoteId == null || quoteId.getSObjectType() != Quote.SObjectType) {
            throw new AuraHandledException('Quote Id is required.');
        }
        if (lineItemId == null || lineItemId.getSObjectType() != QuoteLineItem.SObjectType) {
            throw new AuraHandledException('Quote line Id is required.');
        }
        if (newQuantity == null && discountPercent == null && startDate == null) {
            throw new AuraHandledException('Provide a quantity, discount, and/or start date to update.');
        }
        if (newQuantity != null && newQuantity < 0) {
            throw new AuraHandledException('Quantity cannot be negative.');
        }
        if (discountPercent != null && (discountPercent < 0 || discountPercent > 100)) {
            throw new AuraHandledException('Discount percent must be between 0 and 100.');
        }

        Id qId = Id.valueOf(String.valueOf(quoteId));
        Id liId = Id.valueOf(String.valueOf(lineItemId));

        List<QuoteLineItem> lines = [
            SELECT
                Id,
                QuoteId,
                Quantity,
                Discount,
                StartDate,
                UnitPrice,
                ListPrice,
                PricebookEntryId,
                PricebookEntry.UnitPrice,
                QuoteActionId,
                QuoteAction.Type
            FROM QuoteLineItem
            WHERE Id = :liId AND QuoteId = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        if (lines.isEmpty()) {
            throw new AuraHandledException('Quote line was not found on this quote.');
        }

        QuoteLineItem existing = lines[0];
        String actionType = existing.QuoteAction != null ? existing.QuoteAction.Type : null;

        try {
            // QuoteAction Type flips still require DML. Commercial fields go through
            // Place Sales Transaction so Quote Line Detail / multi-period lines can reprice.
            if (newQuantity != null && newQuantity == 0) {
                applyAmendmentQuantity(existing, actionType, 0);
                ensureSalesUnitPriceForQuote(qId);
                RLM_RepriceQuoteInvocable.repriceQuoteNow(qId);
                return getStudioPayload(qId);
            }
            ensureAmendActionType(existing, actionType, newQuantity, discountPercent, startDate);

            Map<String, Object> lineFields = new Map<String, Object>();
            if (newQuantity != null) {
                lineFields.put('Quantity', newQuantity);
            }
            if (discountPercent != null) {
                lineFields.put('Discount', discountPercent);
            }
            if (startDate != null) {
                lineFields.put('StartDate', startDate);
            }
            if (existing.UnitPrice == null) {
                Decimal seed = existing.ListPrice;
                if (seed == null && existing.PricebookEntry != null) {
                    seed = existing.PricebookEntry.UnitPrice;
                }
                if (seed != null) {
                    lineFields.put('UnitPrice', seed);
                }
            }
            if (lineFields.isEmpty()) {
                ensureSalesUnitPriceForQuote(qId);
                RLM_RepriceQuoteInvocable.repriceQuoteNow(qId);
            } else {
                RLM_RepriceQuoteInvocable.patchLineAndReprice(qId, liId, lineFields);
            }
        } catch (RLM_RepriceQuoteInvocable.RepriceException e) {
            throw new AuraHandledException(e.getMessage());
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        } catch (Exception e) {
            throw new AuraHandledException('Reprice failed: ' + e.getMessage());
        }

        return getStudioPayload(qId);
    }

    /**
     * Flip No Change → Amend when the AE starts changing qty / discount / start.
     * Does not write commercial QLI fields (those go through PST).
     */
    private static void ensureAmendActionType(
        QuoteLineItem existing,
        String actionType,
        Decimal newQuantity,
        Decimal discountPercent,
        Date startDate
    ) {
        Boolean touchesCommercial =
            newQuantity != null || discountPercent != null || startDate != null;
        if (!touchesCommercial) {
            return;
        }
        Boolean isNoChange = actionType == null || actionType == 'No Change';
        if (!isNoChange) {
            if (actionType != 'Amend' && actionType != 'Add') {
                throw new AuraHandledException(
                    'Edits are only supported for No Change / Amend / Add lines (found: '
                        + actionType
                        + ').'
                );
            }
            return;
        }
        if (existing.QuoteActionId == null) {
            throw new AuraHandledException(
                'This line has no Quote Action; open Advanced line editor to amend it.'
            );
        }
        update as user new QuoteAction(Id = existing.QuoteActionId, Type = 'Amend');
    }

    /**
     * Remove a Working line from the amendment Quote.
     * - QuoteAction Type = Add (catalog add-on): delete QLI + QuoteAction.
     * - Amend / No Change (asset-backed): reset to No Change + qty 0 (do not delete).
     */
    @AuraEnabled
    public static StudioPayload removeWorkingLine(Id quoteId, Id lineItemId) {
        if (quoteId == null || quoteId.getSObjectType() != Quote.SObjectType) {
            throw new AuraHandledException('Quote Id is required.');
        }
        if (lineItemId == null || lineItemId.getSObjectType() != QuoteLineItem.SObjectType) {
            throw new AuraHandledException('Quote line Id is required.');
        }
        Id qId = Id.valueOf(String.valueOf(quoteId));
        Id liId = Id.valueOf(String.valueOf(lineItemId));

        List<QuoteLineItem> lines = [
            SELECT Id, QuoteId, Quantity, QuoteActionId, QuoteAction.Type, QuoteAction.SourceAssetId
            FROM QuoteLineItem
            WHERE Id = :liId AND QuoteId = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        if (lines.isEmpty()) {
            throw new AuraHandledException('Quote line was not found on this quote.');
        }

        QuoteLineItem existing = lines[0];
        String actionType = existing.QuoteAction != null ? existing.QuoteAction.Type : null;

        try {
            if (actionType == 'Add') {
                Id actionId = existing.QuoteActionId;
                delete as user existing;
                if (actionId != null) {
                    List<QuoteAction> actions = [
                        SELECT Id
                        FROM QuoteAction
                        WHERE Id = :actionId
                        WITH USER_MODE
                        LIMIT 1
                    ];
                    if (!actions.isEmpty()) {
                        delete as user actions;
                    }
                }
            } else {
                applyAmendmentQuantity(existing, actionType, 0);
            }
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }

        try {
            RLM_RepriceQuoteInvocable.repriceQuoteNow(qId);
        } catch (RLM_RepriceQuoteInvocable.RepriceException e) {
            throw new AuraHandledException(e.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Line removed but reprice failed: ' + e.getMessage());
        }
        return getStudioPayload(qId);
    }

    /**
     * Force-reprice the Quote (Place Sales Transaction) and refresh Studio payload.
     * Used by Working Changes "Reprice" without changing line fields.
     */
    @AuraEnabled
    public static StudioPayload repriceQuote(Id quoteId) {
        if (quoteId == null || quoteId.getSObjectType() != Quote.SObjectType) {
            throw new AuraHandledException('Quote Id is required.');
        }
        Id qId = Id.valueOf(String.valueOf(quoteId));
        try {
            ensureSalesUnitPriceForQuote(qId);
            RLM_RepriceQuoteInvocable.repriceQuoteNow(qId);
        } catch (RLM_RepriceQuoteInvocable.RepriceException e) {
            throw new AuraHandledException(e.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Reprice failed: ' + e.getMessage());
        }
        return getStudioPayload(qId);
    }

    public class CatalogProductHit {
        @AuraEnabled public Id pricebookEntryId;
        @AuraEnabled public Id productId;
        @AuraEnabled public String productName;
        @AuraEnabled public String productCode;
        @AuraEnabled public String description;
        @AuraEnabled public Decimal listPrice;
        @AuraEnabled public Id sellingModelId;
        @AuraEnabled public String sellingModelName;
        @AuraEnabled public String label;
        /** True when returned as the default common-products rail (not a typed search). */
        @AuraEnabled public Boolean isCommon;
        /** Discovery | PriceBook — where the hit came from. */
        @AuraEnabled public String source;
    }

    /** Catalog or category chip for the Studio Discovery rail. */
    public class CatalogTaxonomyNode {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String code;
        @AuraEnabled public Integer childCount;
    }

    /**
     * Initial Discovery browse context: catalogs + categories for the default
     * catalog (prefers QuantumBit Software).
     */
    public class CatalogBrowseContext {
        @AuraEnabled public List<CatalogTaxonomyNode> catalogs;
        @AuraEnabled public List<CatalogTaxonomyNode> categories;
        @AuraEnabled public Id defaultCatalogId;
        @AuraEnabled public String message;
    }

    /** Max rows for common-products rail (price-book seed). */
    @TestVisible
    private static final Integer CATALOG_LIST_LIMIT = 40;

    /** Page size for Discovery search / browse (OOTB-like density). */
    @TestVisible
    private static final Integer CATALOG_SEARCH_LIMIT = 12;

    /**
     * Hero / commonly sold QuantumBit SKUs — preferred when seeding the catalog rail.
     * Missing SKUs in an org are skipped; popularity + alphabetical fill the rest.
     */
    @TestVisible
    private static final List<String> COMMON_PRODUCT_SKUS = new List<String>{
        'QB-GEN-AI-LIC',
        'QB-DB',
        'QB-CS',
        'QB-COMPLETE',
        'QB-BDL-ENTR',
        'QB-BDL-STND',
        'QB-BDL-CRTL',
        'QB-SRV-AS',
        'QB-TRN-FUND',
        'QB-TRN-ESSNTLS',
        'QB-TOKENS-PACK',
        'QB-DB-TOKEN',
        'QB-MTY-CMT',
        'QB-QTY-CMT',
        'QB-BDL-RAXS',
        'QB-BDL-SRVC'
    };

    /**
     * Load Discovery taxonomy for the Studio rail (catalogs + default categories).
     */
    @AuraEnabled
    public static CatalogBrowseContext getCatalogBrowseContext(Id quoteId) {
        CatalogBrowseContext ctx = new CatalogBrowseContext();
        ctx.catalogs = new List<CatalogTaxonomyNode>();
        ctx.categories = new List<CatalogTaxonomyNode>();
        if (quoteId == null || quoteId.getSObjectType() != Quote.SObjectType) {
            ctx.message = 'Quote required.';
            return ctx;
        }
        Id qId = Id.valueOf(String.valueOf(quoteId));
        ctx.catalogs = listDiscoveryCatalogs(qId);
        ctx.defaultCatalogId = pickDefaultCatalogId(ctx.catalogs);
        if (ctx.defaultCatalogId != null) {
            ctx.categories = listDiscoveryCategories(qId, ctx.defaultCatalogId);
        }
        return ctx;
    }

    /**
     * Categories for a selected Discovery catalog.
     */
    @AuraEnabled
    public static List<CatalogTaxonomyNode> getCatalogCategories(Id quoteId, Id catalogId) {
        if (
            quoteId == null ||
            quoteId.getSObjectType() != Quote.SObjectType ||
            catalogId == null
        ) {
            return new List<CatalogTaxonomyNode>();
        }
        return listDiscoveryCategories(
            Id.valueOf(String.valueOf(quoteId)),
            Id.valueOf(String.valueOf(catalogId))
        );
    }

    /**
     * Catalog browse / search for Studio (OOTB Discovery composition).
     * - No catalog + blank → curated common products (price book).
     * - Catalog/category + blank → getProducts browse.
     * - 2+ chars → findProducts (scoped when catalog/category set),
     *   falling back to price-book name search if Discovery returns nothing.
     */
    @AuraEnabled
    public static List<CatalogProductHit> searchCatalogProducts(
        Id quoteId,
        String searchTerm,
        Id catalogId,
        Id categoryId
    ) {
        if (quoteId == null || quoteId.getSObjectType() != Quote.SObjectType) {
            return new List<CatalogProductHit>();
        }
        Id qId = Id.valueOf(String.valueOf(quoteId));
        List<Quote> quotes = [
            SELECT Id, Pricebook2Id
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        if (quotes.isEmpty() || quotes[0].Pricebook2Id == null) {
            return new List<CatalogProductHit>();
        }
        Id pricebookId = quotes[0].Pricebook2Id;
        Id scopedCatalogId = catalogId;
        Id scopedCategoryId = categoryId;
        String trimmed = searchTerm == null ? '' : searchTerm.trim();
        if (trimmed.length() < 2) {
            if (scopedCatalogId != null || scopedCategoryId != null) {
                List<CatalogProductHit> browseHits = browseViaProductDiscovery(
                    qId,
                    pricebookId,
                    scopedCatalogId,
                    scopedCategoryId
                );
                if (!browseHits.isEmpty()) {
                    return browseHits;
                }
            }
            return listCommonCatalogProducts(pricebookId);
        }
        List<CatalogProductHit> discoveryHits = searchViaProductDiscovery(
            qId,
            pricebookId,
            trimmed,
            scopedCatalogId,
            scopedCategoryId
        );
        if (!discoveryHits.isEmpty()) {
            return discoveryHits;
        }
        return searchCatalogProductsByName(pricebookId, trimmed);
    }

    /**
     * OOTB Product Discovery search (standard invocable findProducts).
     */
    private static List<CatalogProductHit> searchViaProductDiscovery(
        Id quoteId,
        Id pricebookId,
        String searchTerm,
        Id catalogId,
        Id categoryId
    ) {
        try {
            Invocable.Action action = Invocable.Action.createStandardAction('findProducts');
            action.setInvocationParameter('searchTerm', searchTerm);
            action.setInvocationParameter('transactionId', String.valueOf(quoteId));
            action.setInvocationParameter('priceBookId', String.valueOf(pricebookId));
            action.setInvocationParameter('limit', CATALOG_SEARCH_LIMIT);
            action.setInvocationParameter('enablePricing', true);
            action.setInvocationParameter('enableQualification', false);
            if (catalogId != null) {
                action.setInvocationParameter('catalogId', String.valueOf(catalogId));
            }
            if (categoryId != null) {
                action.setInvocationParameter('categoryId', String.valueOf(categoryId));
            }
            return invokeDiscoveryProductList(action);
        } catch (Exception e) {
            return new List<CatalogProductHit>();
        }
    }

    /**
     * OOTB Product Discovery browse (standard invocable getProducts).
     */
    private static List<CatalogProductHit> browseViaProductDiscovery(
        Id quoteId,
        Id pricebookId,
        Id catalogId,
        Id categoryId
    ) {
        try {
            Invocable.Action action = Invocable.Action.createStandardAction('getProducts');
            action.setInvocationParameter('transactionId', String.valueOf(quoteId));
            action.setInvocationParameter('priceBookId', String.valueOf(pricebookId));
            action.setInvocationParameter('limit', CATALOG_SEARCH_LIMIT);
            action.setInvocationParameter('enablePricing', true);
            action.setInvocationParameter('enableQualification', false);
            if (catalogId != null) {
                action.setInvocationParameter('catalogId', String.valueOf(catalogId));
            }
            if (categoryId != null) {
                action.setInvocationParameter('categoryId', String.valueOf(categoryId));
            }
            List<CatalogProductHit> hits = invokeDiscoveryProductList(action);
            for (CatalogProductHit hit : hits) {
                hit.isCommon = true;
            }
            return hits;
        } catch (Exception e) {
            return new List<CatalogProductHit>();
        }
    }

    private static List<CatalogProductHit> invokeDiscoveryProductList(Invocable.Action action) {
        List<Invocable.Action.Result> actionResults = action.invoke();
        if (actionResults == null || actionResults.isEmpty()) {
            return new List<CatalogProductHit>();
        }
        Invocable.Action.Result res = actionResults[0];
        if (!res.isSuccess()) {
            return new List<CatalogProductHit>();
        }
        Map<String, Object> outMap = res.getOutputParameters();
        if (outMap == null) {
            return new List<CatalogProductHit>();
        }
        return mapDiscoveryResults(outMap.get('results'));
    }

    private static List<CatalogTaxonomyNode> listDiscoveryCatalogs(Id quoteId) {
        List<CatalogTaxonomyNode> nodes = new List<CatalogTaxonomyNode>();
        try {
            Invocable.Action action = Invocable.Action.createStandardAction('getCatalogs');
            action.setInvocationParameter('transactionId', String.valueOf(quoteId));
            action.setInvocationParameter('limit', 20);
            List<Invocable.Action.Result> actionResults = action.invoke();
            if (actionResults == null || actionResults.isEmpty() || !actionResults[0].isSuccess()) {
                return nodes;
            }
            Map<String, Object> outMap = actionResults[0].getOutputParameters();
            Object raw = outMap != null ? outMap.get('resultCatalogList') : null;
            for (Map<String, Object> row : asObjectMaps(raw)) {
                CatalogTaxonomyNode node = new CatalogTaxonomyNode();
                if (row.get('id') == null) {
                    continue;
                }
                try {
                    node.id = Id.valueOf(String.valueOf(row.get('id')));
                } catch (Exception e) {
                    continue;
                }
                node.name = row.get('name') != null ? String.valueOf(row.get('name')) : 'Catalog';
                node.code = row.get('catalogCode') != null
                    ? String.valueOf(row.get('catalogCode'))
                    : null;
                if (row.get('numberOfCategories') != null) {
                    try {
                        node.childCount = Integer.valueOf(String.valueOf(row.get('numberOfCategories')));
                    } catch (Exception e) {
                        node.childCount = null;
                    }
                }
                nodes.add(node);
            }
        } catch (Exception e) {
            return nodes;
        }
        return nodes;
    }

    private static List<CatalogTaxonomyNode> listDiscoveryCategories(Id quoteId, Id catalogId) {
        List<CatalogTaxonomyNode> nodes = new List<CatalogTaxonomyNode>();
        try {
            Invocable.Action action = Invocable.Action.createStandardAction('getCategories');
            action.setInvocationParameter('transactionId', String.valueOf(quoteId));
            action.setInvocationParameter('catalogId', String.valueOf(catalogId));
            action.setInvocationParameter('limit', 50);
            List<Invocable.Action.Result> actionResults = action.invoke();
            if (actionResults == null || actionResults.isEmpty() || !actionResults[0].isSuccess()) {
                return nodes;
            }
            Map<String, Object> outMap = actionResults[0].getOutputParameters();
            Object raw = outMap != null ? outMap.get('resultCategoryList') : null;
            for (Map<String, Object> row : asObjectMaps(raw)) {
                CatalogTaxonomyNode node = new CatalogTaxonomyNode();
                if (row.get('id') == null) {
                    continue;
                }
                try {
                    node.id = Id.valueOf(String.valueOf(row.get('id')));
                } catch (Exception e) {
                    continue;
                }
                node.name = row.get('name') != null ? String.valueOf(row.get('name')) : 'Category';
                nodes.add(node);
            }
        } catch (Exception e) {
            return nodes;
        }
        return nodes;
    }

    private static Id pickDefaultCatalogId(List<CatalogTaxonomyNode> catalogs) {
        if (catalogs == null || catalogs.isEmpty()) {
            return null;
        }
        for (CatalogTaxonomyNode n : catalogs) {
            if (n.code != null && n.code.equalsIgnoreCase('CAT-QB-SFT')) {
                return n.id;
            }
        }
        for (CatalogTaxonomyNode n : catalogs) {
            if (n.name != null && n.name.toLowerCase().contains('software')) {
                return n.id;
            }
        }
        return catalogs[0].id;
    }

    private static List<Map<String, Object>> asObjectMaps(Object raw) {
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        if (raw == null) {
            return rows;
        }
        try {
            Object parsed = JSON.deserializeUntyped(JSON.serialize(raw));
            if (!(parsed instanceof List<Object>)) {
                return rows;
            }
            for (Object item : (List<Object>) parsed) {
                if (item instanceof Map<String, Object>) {
                    rows.add((Map<String, Object>) item);
                }
            }
        } catch (Exception e) {
            return rows;
        }
        return rows;
    }

    /**
     * Map findProducts / Discovery result payload into Studio catalog hits.
     * Emits one hit per priced selling model (prefers isDefault when present).
     *
     * Always normalize via JSON: invocable output is typed
     * SearchProductsRepresentation (not Map&lt;String,Object&gt;), so a direct
     * List&lt;Object&gt; cast would skip every row.
     */
    @TestVisible
    private static List<CatalogProductHit> mapDiscoveryResults(Object rawResults) {
        List<CatalogProductHit> hits = new List<CatalogProductHit>();
        if (rawResults == null) {
            return hits;
        }
        List<Object> items;
        try {
            Object parsed = JSON.deserializeUntyped(JSON.serialize(rawResults));
            if (!(parsed instanceof List<Object>)) {
                return hits;
            }
            items = (List<Object>) parsed;
        } catch (Exception e) {
            return hits;
        }
        Set<Id> seenPbe = new Set<Id>();
        for (Object rawItem : items) {
            if (!(rawItem instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> product = (Map<String, Object>) rawItem;
            String productName = product.get('name') != null
                ? String.valueOf(product.get('name'))
                : 'Product';
            String productCode = product.get('productCode') != null
                ? String.valueOf(product.get('productCode'))
                : null;
            String description = product.get('description') != null
                ? String.valueOf(product.get('description'))
                : null;
            Id productId = null;
            if (product.get('id') != null) {
                try {
                    productId = Id.valueOf(String.valueOf(product.get('id')));
                } catch (Exception e) {
                    productId = null;
                }
            }
            List<Object> prices = new List<Object>();
            if (product.get('prices') instanceof List<Object>) {
                prices = (List<Object>) product.get('prices');
            }
            if (prices.isEmpty()) {
                continue;
            }
            // Prefer default price rows; otherwise include all priced models.
            List<Object> chosen = new List<Object>();
            for (Object rawPrice : prices) {
                if (!(rawPrice instanceof Map<String, Object>)) {
                    continue;
                }
                Map<String, Object> price = (Map<String, Object>) rawPrice;
                if (price.get('isDefault') == true) {
                    chosen.add(price);
                }
            }
            if (chosen.isEmpty()) {
                chosen.addAll(prices);
            }
            for (Object rawPrice : chosen) {
                Map<String, Object> price = (Map<String, Object>) rawPrice;
                if (price.get('priceBookEntryId') == null) {
                    continue;
                }
                Id pbeId;
                try {
                    pbeId = Id.valueOf(String.valueOf(price.get('priceBookEntryId')));
                } catch (Exception e) {
                    continue;
                }
                if (seenPbe.contains(pbeId)) {
                    continue;
                }
                seenPbe.add(pbeId);
                CatalogProductHit hit = new CatalogProductHit();
                hit.pricebookEntryId = pbeId;
                hit.productId = productId;
                hit.productName = productName;
                hit.productCode = productCode;
                hit.description = description;
                hit.isCommon = false;
                hit.source = 'Discovery';
                if (price.get('price') != null) {
                    try {
                        hit.listPrice = Decimal.valueOf(String.valueOf(price.get('price')));
                    } catch (Exception e) {
                        hit.listPrice = null;
                    }
                }
                Map<String, Object> model = null;
                if (price.get('pricingModel') instanceof Map<String, Object>) {
                    model = (Map<String, Object>) price.get('pricingModel');
                }
                if (model != null) {
                    if (model.get('id') != null) {
                        try {
                            hit.sellingModelId = Id.valueOf(String.valueOf(model.get('id')));
                        } catch (Exception e) {
                            hit.sellingModelId = null;
                        }
                    }
                    hit.sellingModelName = model.get('name') != null
                        ? String.valueOf(model.get('name'))
                        : null;
                }
                hit.label = String.isNotBlank(hit.sellingModelName)
                    ? hit.productName + ' · ' + hit.sellingModelName
                    : hit.productName;
                hits.add(hit);
                if (hits.size() >= CATALOG_SEARCH_LIMIT) {
                    return hits;
                }
            }
        }
        return hits;
    }

    private static List<CatalogProductHit> searchCatalogProductsByName(
        Id pricebookId,
        String searchTerm
    ) {
        List<CatalogProductHit> hits = new List<CatalogProductHit>();
        String term = '%' + searchTerm + '%';
        for (PricebookEntry pbe : [
            SELECT
                Id,
                UnitPrice,
                Product2Id,
                Product2.Name,
                Product2.ProductCode,
                Product2.Description,
                ProductSellingModelId,
                ProductSellingModel.Name
            FROM PricebookEntry
            WHERE Pricebook2Id = :pricebookId
                AND IsActive = TRUE
                AND Product2.IsActive = TRUE
                AND Product2.Name LIKE :term
            WITH USER_MODE
            ORDER BY Product2.Name ASC
            LIMIT :CATALOG_SEARCH_LIMIT
        ]) {
            CatalogProductHit hit = toCatalogHit(pbe, false);
            hit.source = 'PriceBook';
            hits.add(hit);
        }
        return hits;
    }

    /**
     * Seed the left catalog rail: curated SKUs first, then products most often
     * on Quote lines (with a PBE on this price book), then alphabetical fill.
     */
    private static List<CatalogProductHit> listCommonCatalogProducts(Id pricebookId) {
        List<CatalogProductHit> hits = new List<CatalogProductHit>();
        Set<Id> seenPbeIds = new Set<Id>();

        // 1) Curated hero SKUs (stable demo / sales favorites).
        Map<String, Integer> skuRank = new Map<String, Integer>();
        for (Integer i = 0; i < COMMON_PRODUCT_SKUS.size(); i++) {
            skuRank.put(COMMON_PRODUCT_SKUS[i], i);
        }
        List<PricebookEntry> curated = [
            SELECT
                Id,
                UnitPrice,
                Product2Id,
                Product2.Name,
                Product2.StockKeepingUnit,
                Product2.ProductCode,
                ProductSellingModelId,
                ProductSellingModel.Name
            FROM PricebookEntry
            WHERE Pricebook2Id = :pricebookId
                AND IsActive = TRUE
                AND Product2.IsActive = TRUE
                AND (
                    Product2.StockKeepingUnit IN :COMMON_PRODUCT_SKUS
                    OR Product2.ProductCode IN :COMMON_PRODUCT_SKUS
                )
            WITH USER_MODE
            LIMIT :CATALOG_LIST_LIMIT
        ];
        curated.sort(new CatalogSkuRankComparator(skuRank));
        for (PricebookEntry pbe : curated) {
            if (seenPbeIds.contains(pbe.Id) || hits.size() >= CATALOG_LIST_LIMIT) {
                break;
            }
            seenPbeIds.add(pbe.Id);
            hits.add(toCatalogHit(pbe, true));
        }

        // 2) Frequently quoted products (org-wide) that are on this price book.
        if (hits.size() < CATALOG_LIST_LIMIT) {
            Set<Id> popularProductIds = new Set<Id>();
            for (AggregateResult ar : [
                SELECT Product2Id prodId, COUNT(Id) cnt
                FROM QuoteLineItem
                WHERE Product2Id != NULL
                WITH USER_MODE
                GROUP BY Product2Id
                ORDER BY COUNT(Id) DESC
                LIMIT 50
            ]) {
                popularProductIds.add((Id) ar.get('prodId'));
            }
            if (!popularProductIds.isEmpty()) {
                for (PricebookEntry pbe : [
                    SELECT
                        Id,
                        UnitPrice,
                        Product2Id,
                        Product2.Name,
                        Product2.ProductCode,
                        ProductSellingModelId,
                        ProductSellingModel.Name
                    FROM PricebookEntry
                    WHERE Pricebook2Id = :pricebookId
                        AND IsActive = TRUE
                        AND Product2.IsActive = TRUE
                        AND Product2Id IN :popularProductIds
                        AND Id NOT IN :seenPbeIds
                    WITH USER_MODE
                    ORDER BY Product2.Name ASC
                    LIMIT :CATALOG_LIST_LIMIT
                ]) {
                    if (hits.size() >= CATALOG_LIST_LIMIT) {
                        break;
                    }
                    seenPbeIds.add(pbe.Id);
                    hits.add(toCatalogHit(pbe, true));
                }
            }
        }

        // 3) Alphabetical fill so the rail is never sparse on a full price book.
        if (hits.size() < CATALOG_LIST_LIMIT) {
            Integer remaining = CATALOG_LIST_LIMIT - hits.size();
            for (PricebookEntry pbe : [
                SELECT
                    Id,
                    UnitPrice,
                    Product2Id,
                    Product2.Name,
                    Product2.ProductCode,
                    ProductSellingModelId,
                    ProductSellingModel.Name
                FROM PricebookEntry
                WHERE Pricebook2Id = :pricebookId
                    AND IsActive = TRUE
                    AND Product2.IsActive = TRUE
                    AND Id NOT IN :seenPbeIds
                WITH USER_MODE
                ORDER BY Product2.Name ASC
                LIMIT :remaining
            ]) {
                seenPbeIds.add(pbe.Id);
                hits.add(toCatalogHit(pbe, true));
            }
        }
        return hits;
    }

    private static CatalogProductHit toCatalogHit(PricebookEntry pbe, Boolean isCommon) {
        CatalogProductHit hit = new CatalogProductHit();
        hit.pricebookEntryId = pbe.Id;
        hit.productId = pbe.Product2Id;
        hit.productName = pbe.Product2 != null ? pbe.Product2.Name : 'Product';
        if (pbe.Product2 != null) {
            hit.productCode = pbe.Product2.ProductCode;
        }
        hit.listPrice = pbe.UnitPrice;
        hit.sellingModelId = pbe.ProductSellingModelId;
        hit.sellingModelName =
            pbe.ProductSellingModel != null ? pbe.ProductSellingModel.Name : null;
        hit.label = String.isNotBlank(hit.sellingModelName)
            ? hit.productName + ' · ' + hit.sellingModelName
            : hit.productName;
        hit.isCommon = isCommon == true;
        hit.source = 'PriceBook';
        return hit;
    }

    public class PlatformWaterfallStep {
        @AuraEnabled public String key;
        @AuraEnabled public Integer sequence;
        @AuraEnabled public String label;
        @AuraEnabled public String elementType;
        @AuraEnabled public String valueLabel;
        @AuraEnabled public Boolean isAdjustment;
    }

    public class PlatformWaterfallResponse {
        @AuraEnabled public Id lineItemId;
        @AuraEnabled public String executionId;
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;
        @AuraEnabled public List<PlatformWaterfallStep> steps;
        /** Platform | Preview — UI can label the popover source. */
        @AuraEnabled public String source;
    }

    /** Skip noisy procedure bookkeeping steps in the AE-facing waterfall. */
    private static final Set<String> WATERFALL_SKIP_ELEMENT_TYPES = new Set<String>{
        'AssignmentElement',
        'GroupingAndAggregatePricing',
        // Unit-price hover: keep List → Discount → Net; hide term/bookkeeping noise.
        'SubscriptionPricing',
        'FormulaBasedPricing',
        'Proration'
    };

    /**
     * Fetch the OOTB pricing-procedure waterfall for a Quote line after reprice.
     * Uses QLI.PriceWaterfallIdentifier ("{lineItemId}:{executionId}") and
     * GET /connect/core-pricing/waterfall/{lineItemId}/{executionId}.
     */
    @AuraEnabled
    public static PlatformWaterfallResponse getLinePricingWaterfall(Id lineItemId) {
        PlatformWaterfallResponse resp = new PlatformWaterfallResponse();
        resp.steps = new List<PlatformWaterfallStep>();
        resp.success = false;
        resp.source = 'Platform';
        if (lineItemId == null || lineItemId.getSObjectType() != QuoteLineItem.SObjectType) {
            resp.message = 'Quote line Id is required.';
            return resp;
        }
        Id liId = Id.valueOf(String.valueOf(lineItemId));
        resp.lineItemId = liId;

        List<QuoteLineItem> lines = [
            SELECT Id, PriceWaterfallIdentifier
            FROM QuoteLineItem
            WHERE Id = :liId
            WITH USER_MODE
            LIMIT 1
        ];
        if (lines.isEmpty()) {
            resp.message = 'Quote line was not found.';
            return resp;
        }
        String identifier = lines[0].PriceWaterfallIdentifier;
        if (Test.isRunningTest() && String.isNotBlank(testWaterfallIdentifierOverride)) {
            identifier = testWaterfallIdentifierOverride;
        }
        if (String.isBlank(identifier) || !identifier.contains(':')) {
            resp.message = 'No persisted price waterfall yet — Update / Reprice the line first.';
            return resp;
        }
        List<String> parts = identifier.split(':', 2);
        String pathLineId = parts[0];
        String executionId = parts[1];
        resp.executionId = executionId;

        try {
            HttpRequest req = new HttpRequest();
            req.setMethod('GET');
            req.setEndpoint(
                URL.getOrgDomainUrl().toExternalForm()
                    + '/services/data/v67.0/connect/core-pricing/waterfall/'
                    + pathLineId
                    + '/'
                    + executionId
            );
            req.setHeader('Authorization', 'Bearer ' + getApiSessionId());
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(20000);
            HttpResponse httpRes = new Http().send(req);
            if (httpRes.getStatusCode() < 200 || httpRes.getStatusCode() >= 300) {
                resp.message =
                    'Waterfall API ' + httpRes.getStatusCode() + ': ' +
                    truncateMessage(httpRes.getBody(), 240);
                return resp;
            }
            Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(
                httpRes.getBody()
            );
            if (root.get('success') == false) {
                resp.message = truncateMessage(String.valueOf(root.get('error')), 240);
                return resp;
            }
            List<Object> waterfall = (List<Object>) root.get('waterfall');
            if (waterfall == null || waterfall.isEmpty()) {
                resp.message = 'Pricing returned an empty waterfall.';
                return resp;
            }
            Integer idx = 0;
            for (Object raw : waterfall) {
                Map<String, Object> step = (Map<String, Object>) raw;
                if (step.get('hideWaterfall') == true) {
                    continue;
                }
                Map<String, Object> pe = (Map<String, Object>) step.get('pricingElement');
                String elementType = pe != null ? String.valueOf(pe.get('elementType')) : null;
                if (elementType != null && WATERFALL_SKIP_ELEMENT_TYPES.contains(elementType)) {
                    continue;
                }
                Map<String, Object> outp = (Map<String, Object>) step.get('outputParameters');
                String valueLabel = formatWaterfallStepValue(pe, outp, elementType);
                // Drop empty / dash-only rows so the popover stays scannable.
                if (String.isBlank(valueLabel) || valueLabel == '—') {
                    continue;
                }
                PlatformWaterfallStep dto = new PlatformWaterfallStep();
                dto.key = 'pwf-' + String.valueOf(step.get('sequence')) + '-' + idx;
                Object seqObj = step.get('sequence');
                dto.sequence = seqObj == null ? idx : Integer.valueOf(String.valueOf(seqObj));
                dto.elementType = elementType;
                String rawName = pe != null && pe.get('name') != null
                    ? String.valueOf(pe.get('name'))
                    : elementType;
                dto.label = friendlyWaterfallLabel(elementType, rawName);
                dto.isAdjustment = isAdjustmentElement(elementType, pe);
                dto.valueLabel = valueLabel;
                resp.steps.add(dto);
                idx++;
            }
            if (resp.steps.isEmpty()) {
                resp.message = 'No displayable waterfall steps after filtering.';
                return resp;
            }
            // Mark the last money step as the net/total row for styling.
            PlatformWaterfallStep last = resp.steps[resp.steps.size() - 1];
            if (last.elementType == 'DiscountDistributionService' || last.label == 'Net unit price') {
                last.label = 'Net unit price';
                last.isAdjustment = false;
            }
            resp.success = true;
            resp.message = null;
            return resp;
        } catch (Exception e) {
            resp.message = 'Could not load pricing waterfall: ' + e.getMessage();
            return resp;
        }
    }

    private static String friendlyWaterfallLabel(String elementType, String rawName) {
        if (elementType == 'ListPrice') {
            return 'List price';
        }
        if (elementType == 'ManualDiscount') {
            return 'Discount';
        }
        if (elementType == 'Proration') {
            return 'Proration';
        }
        if (elementType == 'DiscountDistributionService') {
            return 'Net unit price';
        }
        if (elementType != null && elementType.toLowerCase().contains('discount')) {
            return 'Discount';
        }
        if (String.isBlank(rawName)) {
            return elementType != null ? elementType : 'Step';
        }
        // Collapse verbose procedure names to something an AE can scan.
        String cleaned = rawName.replace('Calculate ', '').replace(' for term-defined lines', '');
        if (cleaned.length() > 36) {
            return cleaned.substring(0, 34) + '…';
        }
        return cleaned;
    }

    private static Boolean isAdjustmentElement(String elementType, Map<String, Object> pe) {
        if (elementType != null) {
            String et = elementType.toLowerCase();
            if (et.contains('discount') || et.contains('adjustment') || et.contains('promotion')) {
                return true;
            }
            if (et == 'proration') {
                return true;
            }
        }
        if (pe != null && pe.get('adjustments') instanceof List<Object>) {
            List<Object> adjs = (List<Object>) pe.get('adjustments');
            if (!adjs.isEmpty()) {
                Map<String, Object> adj = (Map<String, Object>) adjs[0];
                if (adj.get('AdjustmentValue') != null) {
                    return true;
                }
            }
        }
        return false;
    }

    private static String formatWaterfallStepValue(
        Map<String, Object> pe,
        Map<String, Object> outp,
        String elementType
    ) {
        if (pe != null && pe.get('adjustments') instanceof List<Object>) {
            List<Object> adjs = (List<Object>) pe.get('adjustments');
            if (!adjs.isEmpty()) {
                Map<String, Object> adj = (Map<String, Object>) adjs[0];
                Object av = adj.get('AdjustmentValue');
                Object at = adj.get('AdjustmentType');
                if (av != null && at != null && String.valueOf(at).equalsIgnoreCase('Percentage')) {
                    return '−' + formatPercent(av);
                }
                if (av != null && at != null && String.valueOf(at).equalsIgnoreCase('Amount')) {
                    return '−' + formatMoney(av);
                }
                if (av != null) {
                    return String.valueOf(av);
                }
            }
        }
        if (outp != null) {
            if (elementType == 'Proration' || outp.get('ProrationMultiplier') != null) {
                Object mult = outp.get('ProrationMultiplier');
                if (mult != null) {
                    return formatProrationMultiplier(mult);
                }
            }
            if (elementType == 'ListPrice' && outp.get('ListPrice') != null) {
                return formatMoney(outp.get('ListPrice'));
            }
            if (outp.get('NetUnitPrice') != null) {
                return formatMoney(outp.get('NetUnitPrice'));
            }
            if (outp.get('ListPrice') != null) {
                return formatMoney(outp.get('ListPrice'));
            }
            // Prefer not to show huge Subtotals on a unit-price hover.
        }
        return '—';
    }

    private static String formatProrationMultiplier(Object raw) {
        try {
            Decimal m = Decimal.valueOf(String.valueOf(raw));
            Decimal pct = (m * 100).setScale(1, System.RoundingMode.HALF_UP);
            return pct.format() + '% of term';
        } catch (Exception e) {
            return String.valueOf(raw);
        }
    }

    private static String formatPercent(Object raw) {
        try {
            Decimal d = Decimal.valueOf(String.valueOf(raw));
            return d.setScale(1, System.RoundingMode.HALF_UP).format() + '%';
        } catch (Exception e) {
            return String.valueOf(raw) + '%';
        }
    }

    private static String formatMoney(Object raw) {
        if (raw == null) {
            return '—';
        }
        try {
            Decimal d = Decimal.valueOf(String.valueOf(raw));
            return '$' + d.setScale(2, System.RoundingMode.HALF_UP).format();
        } catch (Exception e) {
            return String.valueOf(raw);
        }
    }

    private static String truncateMessage(String body, Integer maxLen) {
        if (String.isBlank(body)) {
            return '';
        }
        String cleaned = body.replace('\n', ' ').trim();
        if (cleaned.length() <= maxLen) {
            return cleaned;
        }
        return cleaned.substring(0, maxLen) + '…';
    }

    /**
     * Full API session for same-org Connect callouts.
     * Lightning's UserInfo.getSessionId() is restricted; VF $Api.Session_ID is not.
     */
    @TestVisible
    private static String getApiSessionId() {
        if (Test.isRunningTest()) {
            return 'test-session-id';
        }
        return Page.RLM_CloseWon_SessionId.getContent().toString().trim();
    }

    /** Test-only override — PriceWaterfallIdentifier is not DML-writeable. */
    @TestVisible
    private static String testWaterfallIdentifierOverride;

    /** Sort curated PBEs into COMMON_PRODUCT_SKUS order. */
    private class CatalogSkuRankComparator implements Comparator<PricebookEntry> {
        private final Map<String, Integer> skuRank;

        CatalogSkuRankComparator(Map<String, Integer> skuRank) {
            this.skuRank = skuRank;
        }

        public Integer compare(PricebookEntry a, PricebookEntry b) {
            Integer ra = rankFor(a);
            Integer rb = rankFor(b);
            if (ra != rb) {
                return ra < rb ? -1 : 1;
            }
            String na = a.Product2 != null ? a.Product2.Name : '';
            String nb = b.Product2 != null ? b.Product2.Name : '';
            return na.toLowerCase().compareTo(nb.toLowerCase());
        }

        private Integer rankFor(PricebookEntry pbe) {
            if (pbe.Product2 == null) {
                return 9999;
            }
            if (skuRank.containsKey(pbe.Product2.StockKeepingUnit)) {
                return skuRank.get(pbe.Product2.StockKeepingUnit);
            }
            if (skuRank.containsKey(pbe.Product2.ProductCode)) {
                return skuRank.get(pbe.Product2.ProductCode);
            }
            return 9999;
        }
    }

    /**
     * Add a catalog product as a new Quote line (QuoteAction Type = Add), then force-reprice.
     * Used after the AE picks a product on a Studio draft "add line" row.
     */
    @AuraEnabled
    public static StudioPayload addCatalogProductLine(Id quoteId, Id pricebookEntryId) {
        if (quoteId == null || quoteId.getSObjectType() != Quote.SObjectType) {
            throw new AuraHandledException('Quote Id is required.');
        }
        if (pricebookEntryId == null || pricebookEntryId.getSObjectType() != PricebookEntry.SObjectType) {
            throw new AuraHandledException('Price book entry Id is required.');
        }
        Id qId = Id.valueOf(String.valueOf(quoteId));
        Id pbeId = Id.valueOf(String.valueOf(pricebookEntryId));

        List<Quote> quotes = [
            SELECT Id, Pricebook2Id, StartDate, EndDate
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        if (quotes.isEmpty()) {
            throw new AuraHandledException('Quote was not found.');
        }
        Quote q = quotes[0];

        List<PricebookEntry> pbes = [
            SELECT
                Id,
                Pricebook2Id,
                Product2Id,
                UnitPrice,
                ProductSellingModelId,
                ProductSellingModel.SellingModelType,
                ProductSellingModel.PricingTermUnit
            FROM PricebookEntry
            WHERE Id = :pbeId AND IsActive = TRUE
            WITH USER_MODE
            LIMIT 1
        ];
        if (pbes.isEmpty()) {
            throw new AuraHandledException('Price book entry was not found or is inactive.');
        }
        PricebookEntry pbe = pbes[0];
        if (q.Pricebook2Id != null && pbe.Pricebook2Id != q.Pricebook2Id) {
            throw new AuraHandledException('That product is not on this quote\'s price book.');
        }

        Date startDate = Date.today();
        Date endDate = null;
        List<QuoteLineItem> siblings = [
            SELECT StartDate, EndDate
            FROM QuoteLineItem
            WHERE QuoteId = :qId AND EndDate != NULL
            WITH USER_MODE
            ORDER BY CreatedDate ASC
            LIMIT 1
        ];
        if (!siblings.isEmpty()) {
            if (siblings[0].StartDate != null) {
                startDate = Date.today();
            }
            endDate = siblings[0].EndDate;
        } else if (q.EndDate != null) {
            endDate = q.EndDate;
        }

        try {
            QuoteAction action = new QuoteAction(QuoteId = qId, Type = 'Add');
            insert as user action;

            QuoteLineItem line = new QuoteLineItem(
                QuoteId = qId,
                QuoteActionId = action.Id,
                PricebookEntryId = pbe.Id,
                Product2Id = pbe.Product2Id,
                Quantity = 1,
                UnitPrice = pbe.UnitPrice != null ? pbe.UnitPrice : 0,
                StartDate = startDate
            );
            if (endDate != null) {
                line.EndDate = endDate;
            }
            insert as user line;
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }

        try {
            RLM_RepriceQuoteInvocable.repriceQuoteNow(qId);
        } catch (RLM_RepriceQuoteInvocable.RepriceException e) {
            throw new AuraHandledException(e.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Line added but reprice failed: ' + e.getMessage());
        }
        return getStudioPayload(qId);
    }

    /**
     * RLM rule: QuoteAction Type = No Change requires Quantity = 0.
     * Positive delta → Amend + qty; zero delta → No Change + qty 0.
     */
    private static void applyAmendmentQuantity(
        QuoteLineItem existing,
        String actionType,
        Decimal newQuantity
    ) {
        Boolean isNoChange = actionType == null || actionType == 'No Change';
        Boolean isAmend = actionType == 'Amend';

        if (newQuantity == 0) {
            if (!isNoChange && existing.QuoteActionId != null) {
                update as user new QuoteLineItem(Id = existing.Id, Quantity = 0);
                update as user new QuoteAction(Id = existing.QuoteActionId, Type = 'No Change');
            } else if (existing.Quantity != 0) {
                update as user new QuoteLineItem(Id = existing.Id, Quantity = 0);
            }
            return;
        }

        if (isNoChange) {
            if (existing.QuoteActionId == null) {
                throw new AuraHandledException(
                    'This line has no Quote Action; open Advanced line editor to amend it.'
                );
            }
            update as user new QuoteAction(Id = existing.QuoteActionId, Type = 'Amend');
            update as user new QuoteLineItem(Id = existing.Id, Quantity = newQuantity);
            return;
        }

        if (isAmend || actionType == 'Add') {
            update as user new QuoteLineItem(Id = existing.Id, Quantity = newQuantity);
            return;
        }

        throw new AuraHandledException(
            'Quantity edit is only supported for No Change / Amend lines (found: '
                + actionType
                + ').'
        );
    }

    /**
     * Seed sales UnitPrice when null so FORCE Place Sales Transaction can run the
     * pricing procedure. Amend lines from initiateAmendment sometimes arrive with
     * ListPrice set but UnitPrice null; FORCE reprice then "succeeds" with $0 totals.
     * Prefers ListPrice, then PricebookEntry.UnitPrice.
     */
    @TestVisible
    private static void ensureSalesUnitPriceForQuote(Id quoteId) {
        List<QuoteLineItem> lines = [
            SELECT Id, UnitPrice, ListPrice, PricebookEntryId, PricebookEntry.UnitPrice
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId AND UnitPrice = NULL
            WITH USER_MODE
        ];
        ensureSalesUnitPrice(lines);
    }

    @TestVisible
    private static void ensureSalesUnitPrice(List<QuoteLineItem> lines) {
        if (lines == null || lines.isEmpty()) {
            return;
        }
        List<QuoteLineItem> updates = new List<QuoteLineItem>();
        for (QuoteLineItem line : lines) {
            if (line == null || line.Id == null || line.UnitPrice != null) {
                continue;
            }
            Decimal seed = line.ListPrice;
            if (seed == null && line.PricebookEntry != null) {
                seed = line.PricebookEntry.UnitPrice;
            }
            if (seed == null) {
                continue;
            }
            updates.add(new QuoteLineItem(Id = line.Id, UnitPrice = seed));
            line.UnitPrice = seed;
        }
        if (updates.isEmpty()) {
            return;
        }
        try {
            update as user updates;
        } catch (DmlException e) {
            // Quote Line Detail lines block UnitPrice DML — Place Sales
            // Transaction owns sales price for those. Don't fail the Update path.
            System.debug(
                LoggingLevel.WARN,
                'ensureSalesUnitPrice: skipped UnitPrice seed (' + e.getDmlMessage(0) + ')'
            );
        }
    }

    /**
     * Price-only or combined amend: ensure Type = Amend (qty may stay 0),
     * then write QLI.Discount. Instant Pricing / PST reprice honors the %.
     */
    private static void applyAmendmentDiscount(
        QuoteLineItem existing,
        String actionType,
        Decimal discountPercent
    ) {
        Boolean isNoChange = actionType == null || actionType == 'No Change';
        if (isNoChange) {
            if (existing.QuoteActionId == null) {
                throw new AuraHandledException(
                    'This line has no Quote Action; open Advanced line editor to amend it.'
                );
            }
            update as user new QuoteAction(Id = existing.QuoteActionId, Type = 'Amend');
        } else if (actionType != 'Amend' && actionType != 'Add') {
            throw new AuraHandledException(
                'Discount edit is only supported for No Change / Amend lines (found: '
                    + actionType
                    + ').'
            );
        }
        update as user new QuoteLineItem(Id = existing.Id, Discount = discountPercent);
    }

    /** Start date drives proration; EndDate stays untouched (amendment term end). */
    private static void applyAmendmentStartDate(
        QuoteLineItem existing,
        String actionType,
        Date startDate
    ) {
        Boolean isNoChange = actionType == null || actionType == 'No Change';
        if (isNoChange) {
            if (existing.QuoteActionId == null) {
                throw new AuraHandledException(
                    'This line has no Quote Action; open Advanced line editor to amend it.'
                );
            }
            update as user new QuoteAction(Id = existing.QuoteActionId, Type = 'Amend');
        } else if (actionType != 'Amend' && actionType != 'Add') {
            throw new AuraHandledException(
                'Start date edit is only supported for No Change / Amend lines (found: '
                    + actionType
                    + ').'
            );
        }
        update as user new QuoteLineItem(Id = existing.Id, StartDate = startDate);
    }

    private static Map<Id, Decimal> installedQuantityByAsset(Set<Id> assetIds) {
        Map<Id, Decimal> result = new Map<Id, Decimal>();
        if (assetIds == null || assetIds.isEmpty()) {
            return result;
        }
        Datetime nowUtc = System.now();
        for (AssetStatePeriod asp : [
            SELECT AssetId, Quantity
            FROM AssetStatePeriod
            WHERE AssetId IN :assetIds
                AND StartDate <= :nowUtc
                AND EndDate >= :nowUtc
            WITH USER_MODE
        ]) {
            if (asp.AssetId != null && asp.Quantity != null && !result.containsKey(asp.AssetId)) {
                result.put(asp.AssetId, asp.Quantity);
            }
        }
        return result;
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
                HistoryRow orphan = baseRow(aa, assetNames);
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
                enrichLineEconomics(row);
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
     * Recompute and stamp Current / Proposed / Net Increase on the Quote.
     * Called after a successful force-reprice so DocGen / layouts stay current
     * without requiring the seller to open the history panel.
     * Best-effort: never throws.
     */
    public static void stampDifferenceFieldsForQuote(Id quoteId) {
        if (quoteId == null || quoteId.getSObjectType() != Quote.SObjectType) {
            return;
        }
        try {
            getHistoryForQuote(quoteId);
        } catch (Exception e) {
            System.debug(
                LoggingLevel.WARN,
                'RLM_AssetPriceHistoryController.stampDifferenceFieldsForQuote: '
                    + quoteId + ': ' + e.getMessage()
            );
        }
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
            Decimal effectiveNet = resolveEffectiveNetUnitPrice(
                qli.NetUnitPrice,
                qli.ListPrice,
                qli.Discount
            );
            HistoryRow tranche = new HistoryRow();
            tranche.category = 'This amendment';
            tranche.assetName = qli.Product2 != null ? qli.Product2.Name : null;
            tranche.quantity = qty;
            tranche.listPrice = qli.ListPrice;
            tranche.netUnitPrice = effectiveNet;
            tranche.discountPercent = resolveDiscountPercent(
                qli.Discount,
                qli.ListPrice,
                effectiveNet
            );
            if (qli.StartDate != null) {
                tranche.periodStart = Datetime.newInstance(qli.StartDate, Time.newInstance(0, 0, 0, 0));
            }
            if (qli.EndDate != null) {
                tranche.periodEnd = Datetime.newInstance(qli.EndDate, Time.newInstance(23, 59, 59, 0));
            }
            enrichLineEconomics(tranche);
            amendTranches.add(tranche);
            amendQty += qty;
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
    private static Decimal resolveEffectiveNetUnitPrice(
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
