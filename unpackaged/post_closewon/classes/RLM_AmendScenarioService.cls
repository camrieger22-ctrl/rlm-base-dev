/**
 * Sibling amend-Quote scenario orchestration for Amendment Studio:
 * list / compare / duplicate / rename / set forecast, plus Opportunity
 * auto-create when OOTB amend omits OpportunityId.
 */
public with sharing class RLM_AmendScenarioService {

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
        /** Working lines for stacked Working-changes UI (same shape as StudioPayload). */
        @AuraEnabled public List<RLM_AssetPriceHistoryController.WorkingLine> workingLines;
    }

    public class ScenarioCompareResponse {
        @AuraEnabled public Id opportunityId;
        @AuraEnabled public Id syncedQuoteId;
        /** Shared installed baseline (same Source Asset history across siblings). */
        @AuraEnabled public RLM_AmendDifferenceService.HistorySummary current;
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
            RLM_AssetPriceHistoryController.StudioPayload payload = RLM_AssetPriceHistoryController.getStudioPayload(sibling.quoteId);
            if (resp.current == null && payload.history != null && payload.history.summary != null) {
                resp.current = payload.history.summary;
            }
            resp.scenarios.add(buildScenarioColumn(sibling, payload));
        }
        if (resp.current == null) {
            resp.current = new RLM_AmendDifferenceService.HistorySummary();
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
            // OOTB amend submit often omits amendOpportunityId — create one.
            try {
                oppId = ensureAmendmentOpportunity(sourceId);
            } catch (AuraHandledException ahe) {
                result.message = ahe.getMessage();
                return result;
            } catch (Exception e) {
                result.message =
                    'Could not create an Opportunity for this amendment: ' + e.getMessage();
                return result;
            }
        }
        if (oppId == null) {
            result.message =
                'Opportunity Id is required (source quote has none and auto-create failed).';
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
     * Rename a scenario Quote (updates Quote.Name). Used by editable option headers.
     */
    public static ScenarioMutationResult renameScenario(Id quoteId, String name) {
        ScenarioMutationResult result = new ScenarioMutationResult();
        result.success = false;
        if (quoteId == null || quoteId.getSObjectType() != Quote.SObjectType) {
            result.message = 'Quote Id is required.';
            return result;
        }
        if (String.isBlank(name)) {
            result.message = 'Option name is required.';
            return result;
        }
        Id qId = Id.valueOf(String.valueOf(quoteId));
        String newName = name.trim();
        if (newName.length() > 255) {
            newName = newName.substring(0, 255);
        }

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
        if (!isAmendScenarioQuote(q)) {
            result.message = 'Only amendment scenario quotes can be renamed here.';
            return result;
        }
        if (q.Name == newName) {
            result.success = true;
            result.scenario = new ScenarioSummary();
            result.scenario.quoteId = q.Id;
            result.scenario.quoteNumber = q.QuoteNumber;
            result.scenario.name = q.Name;
            result.scenario.grandTotal = q.GrandTotal;
            result.scenario.isSynced = q.IsSyncing == true;
            result.scenario.calculationStatus = q.CalculationStatus;
            result.scenario.validationResult = q.ValidationResult;
            result.opportunityId = q.OpportunityId;
            return result;
        }

        try {
            Quote upd = new Quote(Id = q.Id, Name = newName);
            update as user upd;
        } catch (Exception e) {
            result.message = 'Could not rename quote: ' + e.getMessage();
            return result;
        }

        result.success = true;
        result.scenario = new ScenarioSummary();
        result.scenario.quoteId = q.Id;
        result.scenario.quoteNumber = q.QuoteNumber;
        result.scenario.name = newName;
        result.scenario.grandTotal = q.GrandTotal;
        result.scenario.isSynced = q.IsSyncing == true;
        result.scenario.calculationStatus = q.CalculationStatus;
        result.scenario.validationResult = q.ValidationResult;
        result.opportunityId = q.OpportunityId;
        return result;
    }

    /**
     * Commit a scenario Quote as the Opportunity forecast (OOTB sync).
     * Sets Opportunity.SyncedQuoteId; IsSyncing flips on the Quotes.
     */
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

        // Sync alone leaves TransactionIncomplete until pricing runs; the on-sync
        // flow is async. Force-reprice here so Create Order is not blocked.
        String repriceWarning;
        try {
            RLM_RepriceQuoteInvocable.repriceQuoteNow(qId);
        } catch (RLM_RepriceQuoteInvocable.RepriceException e) {
            repriceWarning = e.getMessage();
        } catch (Exception e) {
            repriceWarning = e.getMessage();
        }

        Quote afterReprice = [
            SELECT Id, Name, QuoteNumber, GrandTotal, CalculationStatus, ValidationResult
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];

        result.syncedQuoteId = qId;
        result.scenario = new ScenarioSummary();
        result.scenario.quoteId = afterReprice.Id;
        result.scenario.quoteNumber = afterReprice.QuoteNumber;
        result.scenario.name = afterReprice.Name;
        result.scenario.grandTotal = afterReprice.GrandTotal;
        result.scenario.isSynced = true;
        result.scenario.calculationStatus = afterReprice.CalculationStatus;
        result.scenario.validationResult = afterReprice.ValidationResult;
        result.success = true;
        result.message = repriceWarning == null
            ? null
            : 'Forecast set, but reprice failed — Create Order may stay blocked until you Reprice All. '
                + repriceWarning;
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

    @TestVisible
    public static Boolean isAmendScenarioQuote(Quote q) {
        if (q == null) {
            return false;
        }
        if (Test.isRunningTest() && testBypassAmendScenarioCheck) {
            return true;
        }
        return q.OriginalActionType == 'Amend';
    }

    /**
     * OOTB initiateAmendment often omits amendOpportunityId, so amend Quotes can
     * land without an Opportunity. Scenario compare / forecast sync need a parent
     * Opp — create a draft one on the Quote's Account and attach the Quote.
     * Idempotent when OpportunityId is already set.
     */
    @TestVisible
    public static Id ensureAmendmentOpportunity(Id quoteId) {
        if (quoteId == null || quoteId.getSObjectType() != Quote.SObjectType) {
            throw new AuraHandledException('Quote Id is required to create an Opportunity.');
        }
        Id qId = Id.valueOf(String.valueOf(quoteId));
        List<Quote> rows = [
            SELECT
                Id,
                Name,
                QuoteNumber,
                OpportunityId,
                AccountId,
                Pricebook2Id,
                ContractId,
                OriginalActionType,
                Account.Name,
                Contract.AccountId,
                Contract.Account.Name
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            throw new AuraHandledException('Quote was not found.');
        }
        return ensureAmendmentOpportunity(rows[0]);
    }

    @TestVisible
    public static Id ensureAmendmentOpportunity(Quote q) {
        if (q == null) {
            throw new AuraHandledException('Quote is required to create an Opportunity.');
        }
        if (q.OpportunityId != null) {
            return q.OpportunityId;
        }
        if (!isAmendScenarioQuote(q)) {
            throw new AuraHandledException(
                'Only amendment quotes can auto-create an Opportunity for scenario compare.'
            );
        }

        Id accountId = null;
        String acctName = null;
        if (Test.isRunningTest() && testEnsureAccountIdOverride != null) {
            accountId = testEnsureAccountIdOverride;
            acctName = 'Test Account';
        } else {
            accountId = q.AccountId;
            if (q.Account != null && String.isNotBlank(q.Account.Name)) {
                acctName = q.Account.Name;
            }
            if (accountId == null && q.ContractId != null && q.Contract != null) {
                accountId = q.Contract.AccountId;
                if (q.Contract.Account != null && String.isNotBlank(q.Contract.Account.Name)) {
                    acctName = q.Contract.Account.Name;
                }
            }
            if (accountId == null) {
                for (QuoteAction qa : [
                    SELECT SourceAsset.AccountId, SourceAsset.Account.Name
                    FROM QuoteAction
                    WHERE QuoteId = :q.Id AND SourceAssetId != null
                    WITH USER_MODE
                    LIMIT 1
                ]) {
                    if (qa.SourceAsset != null && qa.SourceAsset.AccountId != null) {
                        accountId = qa.SourceAsset.AccountId;
                        if (
                            qa.SourceAsset.Account != null &&
                            String.isNotBlank(qa.SourceAsset.Account.Name)
                        ) {
                            acctName = qa.SourceAsset.Account.Name;
                        }
                    }
                }
            }
        }
        if (accountId == null) {
            throw new AuraHandledException(
                'Could not resolve an Account for this amendment Quote (no Account, Contract, or Source Asset).'
            );
        }
        if (String.isBlank(acctName)) {
            acctName = 'Account';
        }

        String oppName = 'Amendment — ' + acctName;
        if (String.isNotBlank(q.QuoteNumber)) {
            oppName += ' (' + q.QuoteNumber + ')';
        }
        if (oppName.length() > 120) {
            oppName = oppName.substring(0, 120);
        }

        Opportunity opp = new Opportunity(
            Name = oppName,
            AccountId = accountId,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Pricebook2Id = q.Pricebook2Id,
            ContractId = q.ContractId
        );
        try {
            insert as user opp;
        } catch (Exception e) {
            throw new AuraHandledException(
                'Could not create Opportunity for amendment: ' + e.getMessage()
            );
        }

        try {
            Quote link = new Quote(Id = q.Id, OpportunityId = opp.Id);
            update as user link;
        } catch (Exception e) {
            throw new AuraHandledException(
                'Opportunity created (' +
                    opp.Id +
                    ') but could not link the Quote: ' +
                    e.getMessage()
            );
        }
        return opp.Id;
    }

    /** Test-only: skip Connect clone and return this Quote Id as the clone. */
    @TestVisible
    private static Id testCloneSalesTransactionIdOverride;

    /** Test-only: OriginalActionType is not DML-writeable in unit tests. */
    @TestVisible
    private static Boolean testBypassAmendScenarioCheck = false;

    /** Test-only: Account resolution when Quote.AccountId is not writable. */
    @TestVisible
    private static Id testEnsureAccountIdOverride;

    @TestVisible
    public static ScenarioColumn buildScenarioColumn(
        ScenarioSummary sibling,
        RLM_AssetPriceHistoryController.StudioPayload payload
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
            for (RLM_AssetPriceHistoryController.WorkingLine line : payload.workingLines) {
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

        RLM_AmendDifferenceService.HistorySummary baseline =
            payload != null && payload.history != null ? payload.history.summary : null;
        RLM_AmendDifferenceService.HistorySummary proposed = null;
        RLM_AmendDifferenceService.ProjectionImpact projection =
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
        col.workingLines =
            payload != null && payload.workingLines != null
                ? payload.workingLines
                : new List<RLM_AssetPriceHistoryController.WorkingLine>();
        return col;
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
}