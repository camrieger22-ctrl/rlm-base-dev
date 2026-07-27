/**
 * Amendment Studio Aura façade: Working mutators (PST), catalog/scenario
 * delegates, OOTB Connect waterfall. Difference KPIs live in
 * RLM_AmendDifferenceService.
 */
public with sharing class RLM_AssetPriceHistoryController {

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
        @AuraEnabled public RLM_AmendDifferenceService.HistoryResponse history;
        @AuraEnabled public List<WorkingLine> workingLines;
        @AuraEnabled public String quoteNumber;
        @AuraEnabled public String quoteName;
        /** Account name for Studio chrome (Quote.Account or Contract.Account). */
        @AuraEnabled public String accountName;
        @AuraEnabled public Decimal grandTotal;
        @AuraEnabled public String status;
        /** Parent Opportunity for scenario compare (may be null on unlinked amends). */
        @AuraEnabled public Id opportunityId;
        /** True when Studio auto-created an Opportunity for an orphan amend Quote. */
        @AuraEnabled public Boolean opportunityAutoCreated;
        /** Quote.CalculationStatus after last pricing run (informational). */
        @AuraEnabled public String calculationStatus;
        /** Quote.ValidationResult — non-null means prices/transaction need attention. */
        @AuraEnabled public String validationResult;
        /** Lets Studio re-baseline its pricing pulse after a KPI stamp. */
        @AuraEnabled public Datetime lastModifiedDate;
    }

    /**
     * Lightweight pricing pulse for Studio — poll after TLE Save without
     * rebuilding full history/working-line payload every tick.
     */
    public class PricingPulse {
        @AuraEnabled public String calculationStatus;
        @AuraEnabled public String validationResult;
        @AuraEnabled public Decimal grandTotal;
        @AuraEnabled public Datetime lastModifiedDate;
    }

    /**
     * Sibling amend scenarios — delegated to RLM_AmendScenarioService.
     */
    @AuraEnabled
    public static List<RLM_AmendScenarioService.ScenarioSummary> listScenarios(Id opportunityId) {
        return RLM_AmendScenarioService.listScenarios(opportunityId);
    }

    @AuraEnabled
    public static RLM_AmendScenarioService.ScenarioCompareResponse getScenarioCompare(
        Id opportunityId
    ) {
        return RLM_AmendScenarioService.getScenarioCompare(opportunityId);
    }

    @AuraEnabled
    public static RLM_AmendScenarioService.ScenarioMutationResult createScenario(
        Id sourceQuoteId,
        String label,
        Id opportunityId
    ) {
        return RLM_AmendScenarioService.createScenario(sourceQuoteId, label, opportunityId);
    }

    @AuraEnabled
    public static RLM_AmendScenarioService.ScenarioMutationResult renameScenario(
        Id quoteId,
        String name
    ) {
        return RLM_AmendScenarioService.renameScenario(quoteId, name);
    }

    @AuraEnabled
    public static RLM_AmendScenarioService.ScenarioMutationResult setForecastScenario(
        Id opportunityId,
        Id quoteId
    ) {
        return RLM_AmendScenarioService.setForecastScenario(opportunityId, quoteId);
    }

    /**
     * Seller-triggered Opportunity create for orphan amend Quotes.
     * Never call from getStudioPayload / page load — Quote DML races the QLE.
     */
    @AuraEnabled
    public static Id ensureAmendmentOpportunityForStudio(Id quoteId) {
        if (quoteId == null || quoteId.getSObjectType() != Quote.SObjectType) {
            return null;
        }
        Id qId = Id.valueOf(String.valueOf(quoteId));
        for (Quote q : [
            SELECT
                Id,
                Name,
                QuoteNumber,
                OpportunityId,
                OriginalActionType,
                AccountId,
                Account.Name,
                ContractId,
                Contract.AccountId,
                Contract.Account.Name,
                Pricebook2Id
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ]) {
            if (q.OpportunityId != null) {
                return q.OpportunityId;
            }
            if (!RLM_AmendScenarioService.isAmendScenarioQuote(q)) {
                return null;
            }
            return RLM_AmendScenarioService.ensureAmendmentOpportunity(q);
        }
        return null;
    }

    public class LinkOpportunityRequest {
        @InvocableVariable(label='Quote Id' required=true)
        public Id quoteId;
    }

    public class LinkOpportunityResult {
        @InvocableVariable(label='Opportunity Id')
        public Id opportunityId;
        @InvocableVariable(label='Message')
        public String message;
    }

    /**
     * Flow entry point for Quote header action Link Opportunity.
     */
    @InvocableMethod(
        label='Link Amendment Opportunity'
        description='Creates a draft Opportunity and links an orphan amendment Quote.'
    )
    public static List<LinkOpportunityResult> linkAmendmentOpportunity(
        List<LinkOpportunityRequest> requests
    ) {
        List<LinkOpportunityResult> results = new List<LinkOpportunityResult>();
        if (requests == null) {
            return results;
        }
        for (LinkOpportunityRequest req : requests) {
            LinkOpportunityResult row = new LinkOpportunityResult();
            if (req == null || req.quoteId == null) {
                row.message = 'Quote Id is required.';
                results.add(row);
                continue;
            }
            try {
                Id oppId = ensureAmendmentOpportunityForStudio(req.quoteId);
                row.opportunityId = oppId;
                row.message = oppId == null
                    ? 'Could not link Opportunity (not an amendment Quote, or Account could not be resolved).'
                    : 'Opportunity linked.';
            } catch (AuraHandledException ahe) {
                row.message = ahe.getMessage();
            } catch (Exception e) {
                row.message = e.getMessage();
            }
            results.add(row);
        }
        return results;
    }

    @TestVisible
    public static RLM_AmendScenarioService.ScenarioColumn buildScenarioColumn(
        RLM_AmendScenarioService.ScenarioSummary sibling,
        StudioPayload payload
    ) {
        return RLM_AmendScenarioService.buildScenarioColumn(sibling, payload);
    }

    @AuraEnabled
    public static PricingPulse getQuotePricingPulse(Id quoteId) {
        PricingPulse pulse = new PricingPulse();
        if (quoteId == null || quoteId.getSObjectType() != Quote.SObjectType) {
            return pulse;
        }
        Id qId = Id.valueOf(String.valueOf(quoteId));
        for (Quote q : [
            SELECT CalculationStatus, ValidationResult, GrandTotal, LastModifiedDate
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ]) {
            pulse.calculationStatus = q.CalculationStatus;
            pulse.validationResult = q.ValidationResult;
            pulse.grandTotal = q.GrandTotal;
            pulse.lastModifiedDate = q.LastModifiedDate;
        }
        return pulse;
    }

    /**
     * Amendment Studio payload: history/projection KPIs + working Quote lines.
     * Not cacheable (same timing reasons as getHistoryForQuote).
     */
    @AuraEnabled
    public static StudioPayload getStudioPayload(Id quoteId) {
        StudioPayload payload = new StudioPayload();
        payload.workingLines = new List<WorkingLine>();
        payload.history = RLM_AmendDifferenceService.getHistoryForQuote(quoteId);
        if (quoteId == null || quoteId.getSObjectType() != Quote.SObjectType) {
            return payload;
        }
        Id qId = Id.valueOf(String.valueOf(quoteId));
        payload.opportunityAutoCreated = false;
        for (Quote q : [
            SELECT
                Id,
                QuoteNumber,
                Name,
                Status,
                GrandTotal,
                OpportunityId,
                AccountId,
                Pricebook2Id,
                ContractId,
                OriginalActionType,
                CalculationStatus,
                ValidationResult,
                LastModifiedDate,
                Account.Name,
                Contract.AccountId,
                Contract.Account.Name
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ]) {
            payload.lastModifiedDate = q.LastModifiedDate;
            payload.quoteNumber = q.QuoteNumber;
            payload.quoteName = q.Name;
            payload.grandTotal = q.GrandTotal;
            payload.status = q.Status;
            if (q.Account != null && String.isNotBlank(q.Account.Name)) {
                payload.accountName = q.Account.Name;
            } else if (q.Contract != null && q.Contract.Account != null) {
                payload.accountName = q.Contract.Account.Name;
            }
            payload.calculationStatus = q.CalculationStatus;
            payload.validationResult = q.ValidationResult;
            // Opportunity linking is seller-triggered (Link Opportunity in Studio).
            payload.opportunityId = q.OpportunityId;
            // Prefer Account from Source Asset when Quote.Account is blank (common on OOTB amend).
            if (String.isBlank(payload.accountName)) {
                for (QuoteAction qa : [
                    SELECT SourceAsset.Account.Name
                    FROM QuoteAction
                    WHERE QuoteId = :qId AND SourceAssetId != null
                    WITH USER_MODE
                    LIMIT 1
                ]) {
                    if (
                        qa.SourceAsset != null &&
                        qa.SourceAsset.Account != null &&
                        String.isNotBlank(qa.SourceAsset.Account.Name)
                    ) {
                        payload.accountName = qa.SourceAsset.Account.Name;
                    }
                }
            }
        }
        payload.workingLines = RLM_AmendDifferenceService.loadWorkingLines(qId);
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
            // Catalog add-ons (Type=Add, or orphan with no QuoteAction) delete;
            // asset-backed Amend / No Change reset to qty 0.
            Boolean isCatalogAdd =
                actionType == 'Add' || existing.QuoteActionId == null;
            if (isCatalogAdd) {
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

    /**
     * Recompute the Quote KPI stamps and Amend Breakdown rows from the current
     * Quote Lines, then return a refreshed payload.
     *
     * Without this the only stamp path is a force-reprice, so Quote Line Editor
     * edits (quantity, discount, catalog adds) leave the proposal rendering
     * figures from an earlier state.
     *
     * User-initiated only — Amendment Studio calls it from the "Update proposal
     * figures" button. This updates the Quote, and Quote DML from outside the
     * Quote Line Editor invalidates the version the editor holds, so the next QLE
     * save fails with "refresh and try again". Do NOT call it from a poll, a
     * trigger, or the Studio read path (see the comment on the read path in
     * RLM_AmendDifferenceService.buildHistoryResponse).
     */
    @AuraEnabled
    public static StudioPayload refreshAmendKpis(Id quoteId) {
        if (quoteId == null || quoteId.getSObjectType() != Quote.SObjectType) {
            throw new AuraHandledException('Quote Id is required.');
        }
        Id qId = Id.valueOf(String.valueOf(quoteId));
        RLM_AmendDifferenceService.stampDifferenceFieldsForQuote(qId);
        return getStudioPayload(qId);
    }

    /**
     * Catalog / Discovery — delegated to RLM_CatalogDiscoveryService (OOTB
     * getCatalogs / getCategories / getProducts / findProducts; no curated SKUs).
     */
    @AuraEnabled
    public static RLM_CatalogDiscoveryService.CatalogBrowseContext getCatalogBrowseContext(
        Id quoteId
    ) {
        return RLM_CatalogDiscoveryService.getCatalogBrowseContext(quoteId);
    }

    @AuraEnabled
    public static List<RLM_CatalogDiscoveryService.CatalogTaxonomyNode> getCatalogCategories(
        Id quoteId,
        Id catalogId
    ) {
        return RLM_CatalogDiscoveryService.getCatalogCategories(quoteId, catalogId);
    }

    @AuraEnabled
    public static List<RLM_CatalogDiscoveryService.CatalogProductHit> searchCatalogProducts(
        Id quoteId,
        String searchTerm,
        Id catalogId,
        Id categoryId
    ) {
        return RLM_CatalogDiscoveryService.searchCatalogProducts(
            quoteId,
            searchTerm,
            catalogId,
            categoryId
        );
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

    /**
     * Skip pure bookkeeping nodes the procedure often returns with no money.
     * Do not filter Proration / SubscriptionPricing / Formula — those are part
     * of the OOTB waterfall AEs should see. Platform hideWaterfall still applies.
     */
    private static final Set<String> WATERFALL_SKIP_ELEMENT_TYPES = new Set<String>{
        'AssignmentElement',
        'GroupingAndAggregatePricing'
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
                if (outp.get('ProratedAmount') != null) {
                    return formatMoney(outp.get('ProratedAmount'));
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

    /**
     * Add a catalog product via Place Sales Transaction (QuoteAction Type=Add +
     * QuoteLineItem POST + FORCE price). No Apex insert of QuoteAction/QLI.
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
            endDate = siblings[0].EndDate;
        } else if (q.EndDate != null) {
            endDate = q.EndDate;
        }

        Map<String, Object> lineFields = new Map<String, Object>{
            'Product2Id' => pbe.Product2Id,
            'PricebookEntryId' => pbe.Id,
            'Quantity' => 1,
            'UnitPrice' => pbe.UnitPrice != null ? pbe.UnitPrice : 0
        };
        applySellingModelFieldsForCatalogAdd(lineFields, pbe, startDate, endDate);

        try {
            RLM_RepriceQuoteInvocable.addCatalogLineAndReprice(qId, lineFields);
        } catch (RLM_RepriceQuoteInvocable.RepriceException e) {
            throw new AuraHandledException(e.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Add line failed: ' + e.getMessage());
        }
        return getStudioPayload(qId);
    }

    /**
     * PST catalog-add selling-model fields (parity with RLM_SetUpQuoteInvocable).
     * TermDefined / Evergreen require PeriodBoundary + BillingFrequency or the
     * platform returns INVALID_PERIOD_BOUNDARY. One-Time gets StartDate only.
     */
    @TestVisible
    private static void applySellingModelFieldsForCatalogAdd(
        Map<String, Object> lineFields,
        PricebookEntry pbe,
        Date startDate,
        Date endDate
    ) {
        if (lineFields == null || pbe == null) {
            return;
        }
        Date start = startDate != null ? startDate : Date.today();
        String sellingModelType =
            pbe.ProductSellingModel != null
                ? String.valueOf(pbe.ProductSellingModel.SellingModelType)
                : null;
        String pricingTermUnit =
            pbe.ProductSellingModel != null
                ? String.valueOf(pbe.ProductSellingModel.PricingTermUnit)
                : null;
        String billingFrequency = billingFrequencyForPricingTerm(pricingTermUnit);

        if ('TermDefined' == sellingModelType && String.isNotBlank(billingFrequency)) {
            lineFields.put('StartDate', start);
            Date termEnd = endDate != null ? endDate : start.addYears(1);
            lineFields.put('EndDate', termEnd);
            lineFields.put('PeriodBoundary', 'Anniversary');
            lineFields.put('BillingFrequency', billingFrequency);
        } else if ('Evergreen' == sellingModelType && String.isNotBlank(billingFrequency)) {
            lineFields.put('StartDate', start);
            lineFields.put('PeriodBoundary', 'Anniversary');
            lineFields.put('BillingFrequency', billingFrequency);
        } else {
            // One-Time / unknown — start only; do not send EndDate (platform rejects it).
            lineFields.put('StartDate', start);
        }
    }

    @TestVisible
    private static String billingFrequencyForPricingTerm(String pricingTermUnit) {
        if (String.isBlank(pricingTermUnit)) {
            return null;
        }
        if (pricingTermUnit == 'Months') {
            return 'Monthly';
        }
        if (pricingTermUnit == 'Annual') {
            return 'Annual';
        }
        if (pricingTermUnit == 'Quarterly') {
            return 'Quarterly';
        }
        if (pricingTermUnit == 'Semi-Annual') {
            return 'Semi-Annual';
        }
        return null;
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

    /**
     * Difference history / stamps — delegated to RLM_AmendDifferenceService.
     */
    @AuraEnabled
    public static RLM_AmendDifferenceService.HistoryResponse getHistoryForQuote(Id quoteId) {
        return RLM_AmendDifferenceService.getHistoryForQuote(quoteId);
    }

    /**
     * Recompute and stamp Current / Proposed / Net Increase on the Quote.
     * Called after a successful force-reprice so DocGen / layouts stay current.
     */
    public static void stampDifferenceFieldsForQuote(Id quoteId) {
        RLM_AmendDifferenceService.stampDifferenceFieldsForQuote(quoteId);
    }

    @TestVisible
    public static Decimal resolveEffectiveNetUnitPrice(
        Decimal netUnitPrice,
        Decimal listPrice,
        Decimal discountPercent
    ) {
        return RLM_AmendDifferenceService.resolveEffectiveNetUnitPrice(
            netUnitPrice,
            listPrice,
            discountPercent
        );
    }

}