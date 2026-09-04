/**
 * BambooHR AE Revenue Suite — Phase 0–1 bootstrap, catalog, add-line, RC reprice.
 * Native RC: each suite option = one Quote. Catalog mirrors Get Pricing PBE rules
 * (BAMBOO-% Standard PB, Months PSM, Evergreen vs TermDefined by termMonths).
 * Line add / qty / reprice go through RevSalesTrxn PlaceSalesTransactionExecutor
 * (FORCE pricing) — thin Apex adapter, no custom pricing math.
 */
public with sharing class RLM_BambooRevenueSuite {
    public class SuiteException extends Exception {
    }

    public class SessionDTO {
        @AuraEnabled
        public Id opportunityId;
        @AuraEnabled
        public String opportunityName;
        @AuraEnabled
        public Id accountId;
        @AuraEnabled
        public String accountName;
        @AuraEnabled
        public Id quoteId;
        @AuraEnabled
        public String quoteName;
        @AuraEnabled
        public String quoteNumber;
        @AuraEnabled
        public Date closeDate;
        @AuraEnabled
        public String currencyIsoCode;
        @AuraEnabled
        public Integer termMonths;
        @AuraEnabled
        public String billingFrequency;
        @AuraEnabled
        public Boolean evergreen;
        @AuraEnabled
        public String optionLabel;
        /** Opportunity.SyncedQuoteId when set (winning option for forecasting). */
        @AuraEnabled
        public Id syncedQuoteId;
        /** 4d Phase B — Editing | Committed. */
        @AuraEnabled
        public String syncMode;
        /** Intended winner while Editing (SyncedQuoteId cleared). */
        @AuraEnabled
        public Id stagedSyncQuoteId;
        /** True when openFromOpportunity just paused forecast sync. */
        @AuraEnabled
        public Boolean syncPausedToast;
        /** 4d Phase B — suite mutators may enqueue via txn orchestrator. */
        @AuraEnabled
        public Boolean txnOrchestratorEnabled;
    }

    public class CatalogProductDTO {
        @AuraEnabled
        public String sku;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String badge;
        @AuraEnabled
        public Boolean frequent;
        @AuraEnabled
        public Decimal listPrice;
        @AuraEnabled
        public String currencyIsoCode;
        @AuraEnabled
        public Id product2Id;
        @AuraEnabled
        public String description;
    }

    public class OptionLineDTO {
        @AuraEnabled
        public Id lineId;
        @AuraEnabled
        public String sku;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public Decimal quantity;
        @AuraEnabled
        public Decimal unitPrice;
        @AuraEnabled
        public Decimal listUnitPrice;
        /** List line total (monthly): listUnit × qty. */
        @AuraEnabled
        public Decimal listTotal;
        @AuraEnabled
        public Decimal netTotal;
        @AuraEnabled
        public Decimal discountPercent;
        /** Per-line Smart Approval ladder from RLM_Approval_Level_Calc__c. */
        @AuraEnabled
        public Decimal approvalLevel;
        @AuraEnabled
        public String approvalRequiredLabel;
        @AuraEnabled
        public String startDate;
        @AuraEnabled
        public String endDate;
        /** Inclusive day count between start and end; null when evergreen / open-ended. */
        @AuraEnabled
        public Integer dayCount;
        @AuraEnabled
        public Boolean priced;
        /** Parent bundle QLI when this row is a bundle component. */
        @AuraEnabled
        public Id parentLineId;
        @AuraEnabled
        public Boolean isBundleRoot;
        @AuraEnabled
        public Boolean isBundleChild;
    }

    public class OptionDetailDTO {
        @AuraEnabled
        public Id quoteId;
        @AuraEnabled
        public String optionLabel;
        @AuraEnabled
        public Decimal mrr;
        @AuraEnabled
        public Decimal arr;
        /** RC Quote header rollup (contract value); matches synced Opp Amount. */
        @AuraEnabled
        public Decimal grandTotal;
        /**
         * Suite approval chip: Draft | Pending | Approved | Rejected | Recalled.
         * Sourced from Quote.RLM_Approval_Status__c (null → Draft).
         */
        @AuraEnabled
        public String approvalStatus;
        /** Max line discount ladder level (Quote.RLM_Approval_Level__c rollup). */
        @AuraEnabled
        public Decimal approvalLevel;
        /** Human label for who must approve when level &gt; 0 (e.g. Manager → Director). */
        @AuraEnabled
        public String approvalRequiredLabel;
        /**
         * Latest Reject/Recall reviewer comments (Option 2: name which lines to fix).
         * Null when none / not Rejected or Recalled.
         */
        @AuraEnabled
        public String lastDecisionComments;
        @AuraEnabled
        public Integer termMonths;
        @AuraEnabled
        public Boolean evergreen;
        @AuraEnabled
        public Boolean priced;
        @AuraEnabled
        public String startDate;
        @AuraEnabled
        public String endDate;
        @AuraEnabled
        public String billingFrequency;
        @AuraEnabled
        public List<OptionLineDTO> lines;
    }

    public class AddLineResultDTO {
        @AuraEnabled
        public Id lineId;
        /** All line Ids created in this Place (single or multi-add). */
        @AuraEnabled
        public List<Id> lineIds;
        @AuraEnabled
        public OptionDetailDTO option;
    }

    /** Inbound from LWC — properties need get/set for Aura deserialization. */
    public class LineInputDTO {
        @AuraEnabled
        public String sku { get; set; }
        @AuraEnabled
        public Decimal quantity { get; set; }
    }

    /** One suite option = one Draft Quote named "… — Option X". */
    public class OptionSummaryDTO {
        @AuraEnabled
        public Id quoteId;
        @AuraEnabled
        public String quoteName;
        @AuraEnabled
        public String quoteNumber;
        @AuraEnabled
        public String optionLabel;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public Integer lineCount;
        @AuraEnabled
        public Decimal mrr;
        @AuraEnabled
        public Decimal arr;
        /** RC Quote header rollup (contract value); matches synced Opp Amount. */
        @AuraEnabled
        public Decimal grandTotal;
        @AuraEnabled
        public Boolean priced;
        @AuraEnabled
        public Boolean selected;
        /** True when this option Quote is Opportunity.SyncedQuoteId. */
        @AuraEnabled
        public Boolean syncedToOpportunity;
        /**
         * Suite approval chip: Draft | Pending | Approved | Rejected | Recalled.
         * Sourced from Quote.RLM_Approval_Status__c (null → Draft).
         */
        @AuraEnabled
        public String approvalStatus;
        @AuraEnabled
        public Decimal approvalLevel;
        @AuraEnabled
        public String approvalRequiredLabel;
    }

    /** Result of Start Sync / Stop Sync against the suite Opportunity. */
    public class SyncOpportunityResultDTO {
        @AuraEnabled
        public Id syncedQuoteId;
        @AuraEnabled
        public List<OptionSummaryDTO> options;
        @AuraEnabled
        public String syncMode;
        @AuraEnabled
        public Id stagedSyncQuoteId;
    }

    public class AddOptionResultDTO {
        @AuraEnabled
        public OptionSummaryDTO created;
        @AuraEnabled
        public List<OptionSummaryDTO> options;
        @AuraEnabled
        public SessionDTO session;
    }

    public class PreviewResultDTO {
        @AuraEnabled
        public Id processId;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public Id contentVersionId;
        @AuraEnabled
        public Id contentDocumentId;
        @AuraEnabled
        public String downloadUrl;
        @AuraEnabled
        public String title;
        @AuraEnabled
        public String message;
    }

    /** Slice 5 — submit / refresh approval status for one suite option. */
    public class ApprovalResultDTO {
        @AuraEnabled
        public Id quoteId;
        @AuraEnabled
        public String approvalStatus;
        @AuraEnabled
        public String summary;
        /** True when Smart Approval failed to start and status was demo-forced to Approved. */
        @AuraEnabled
        public Boolean usedApprovalFallback;
        @AuraEnabled
        public OptionDetailDTO option;
        @AuraEnabled
        public List<OptionSummaryDTO> options;
    }

    /** Opp Contact row for Send to customer picker. */
    public class ContactOptionDTO {
        @AuraEnabled
        public Id contactId;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String email;
    }

    /** Slice 5 — email option quote (+ optional DocGen PDF). */
    public class SendResultDTO {
        @AuraEnabled
        public Boolean success;
        @AuraEnabled
        public String message;
        @AuraEnabled
        public String toAddress;
        @AuraEnabled
        public Id quoteId;
        @AuraEnabled
        public Id contentVersionId;
    }

    /** Advanced Approvals work item row for the in-suite pending-approvals panel. */
    public class ApprovalWorkItemRowDTO {
        @AuraEnabled
        public Id workItemId;
        @AuraEnabled
        public String stepName;
        @AuraEnabled
        public String chainName;
        @AuraEnabled
        public String assignedToLabel;
        @AuraEnabled
        public Boolean canAct;
        @AuraEnabled
        public String status;
    }

    /** Pending approval work items on one suite option quote. */
    public class PendingApprovalsDTO {
        @AuraEnabled
        public Id quoteId;
        @AuraEnabled
        public String optionLabel;
        /** Submission comments / deal ask shown to approvers. */
        @AuraEnabled
        public String requestSummary;
        @AuraEnabled
        public List<ApprovalWorkItemRowDTO> items;
        @AuraEnabled
        public Integer actionableCount;
        /** Deep link to Quote record (Approvals tab / Work Guide). */
        @AuraEnabled
        public String quoteApprovalsUrl;
        @AuraEnabled
        public String workGuideHint;
    }

    /** Good / Better / Best option quotes prepared for the AE agent rail. */
    public class TierOptionsResultDTO {
        @AuraEnabled
        public List<OptionSummaryDTO> options;
        @AuraEnabled
        public SessionDTO session;
        @AuraEnabled
        public Id goodQuoteId;
        @AuraEnabled
        public Id betterQuoteId;
        @AuraEnabled
        public Id bestQuoteId;
        @AuraEnabled
        public String summary;
    }

    private static final Set<Integer> ALLOWED_TERMS = new Set<Integer>{ 1, 12, 24, 36 };
    private static final String OPTION_NAME_MARKER = ' — Option ';
    private static final Integer MAX_OPTIONS = 6;
    private static final Set<String> FREQUENT_SKUS = new Set<String>{
        'BAMBOO-CORE',
        'BAMBOO-PRO',
        'BAMBOO-ELITE',
        'BAMBOO-ADD-PAYROLL'
    };
    private static final String WORKFORCE_PKG_SKU = 'BAMBOO-PKG-WORKFORCE';
    private static final Set<String> WORKFORCE_PLAN_SKUS = new Set<String>{
        'BAMBOO-CORE',
        'BAMBOO-PRO',
        'BAMBOO-ELITE'
    };
    private static final String WORKFORCE_DEFAULT_PLAN = 'BAMBOO-PRO';
    private static final String PROPOSAL_TEMPLATE_NAME = 'RLM_Bamboo_QuoteProposal';

    @AuraEnabled
    public static SessionDTO openFromOpportunity(String opportunityId) {
        Id oppId = parseId(opportunityId, 'Opportunity');
        Opportunity opp = RLM_BambooSuiteSession.requireSessionOpportunity(oppId);

        Boolean pausedToast = false;
        // Edit mode: keep SyncedQuoteId clear while AE compares/edits options.
        try {
            RLM_BambooSuiteSync.SyncResult paused =
                RLM_BambooSuiteSession.enterEditMode(opp.Id);
            pausedToast = paused != null && paused.pausedToast == true;
            opp = RLM_BambooSuiteSession.requireSessionOpportunity(opp.Id);
        } catch (Exception e) {
            // Fall through — suite still opens; AE can Stop sync manually.
        }

        Quote draft = resolveSuiteEntryQuote(opp);
        // Path/TLE and suite share RLM_Approval_Status__c — refresh from AA first.
        reconcileSuiteOptionApprovals(opp.Id);
        SessionDTO session = toSession(opp, draft);
        session.syncPausedToast = pausedToast;
        return session;
    }

    @AuraEnabled(cacheable=true)
    public static SessionDTO getSession(String quoteId) {
        Id qId = parseId(quoteId, 'Quote');
        Quote q = requireQuote(
            qId,
            new Set<String>{
                'Id',
                'Name',
                'QuoteNumber',
                'OpportunityId',
                'CurrencyIsoCode',
                'Status'
            }
        );
        if (q.OpportunityId == null) {
            throw new SuiteException(
                'Quote is not linked to an Opportunity. Re-open the suite from the Opportunity.'
            );
        }
        Opportunity opp = requireOpportunity(
            q.OpportunityId,
            RLM_BambooSuiteSync.OPP_SESSION_FIELDS
        );
        SessionDTO dto = new SessionDTO();
        dto.opportunityId = opp.Id;
        dto.opportunityName = opp.Name;
        dto.accountId = opp.AccountId;
        dto.accountName = opp.Account != null ? opp.Account.Name : null;
        dto.closeDate = opp.CloseDate;
        dto.currencyIsoCode = String.isNotBlank(q.CurrencyIsoCode)
            ? q.CurrencyIsoCode
            : opp.CurrencyIsoCode;
        dto.quoteId = q.Id;
        dto.quoteName = q.Name;
        dto.quoteNumber = q.QuoteNumber;
        Integer months = inferTermMonths(q.Id);
        dto.termMonths = months;
        dto.billingFrequency = 'Monthly';
        dto.evergreen = isEvergreen(months);
        dto.optionLabel = optionLabelFromName(q.Name);
        dto.syncedQuoteId = opp.SyncedQuoteId;
        dto.stagedSyncQuoteId = opp.RLM_Bamboo_Staged_Sync_Quote_Id__c;
        dto.syncMode = String.isNotBlank(opp.RLM_Bamboo_Sync_Mode__c)
            ? opp.RLM_Bamboo_Sync_Mode__c
            : (opp.SyncedQuoteId != null ? 'Committed' : 'Editing');
        dto.syncPausedToast = false;
        dto.txnOrchestratorEnabled = isTxnOrchestratorEnabled();
        return dto;
    }

    /**
     * All suite options on the Opportunity (Draft Quotes named "… — Option X").
     * selectedQuoteId marks the active card; blank selects none.
     */
    @AuraEnabled
    public static List<OptionSummaryDTO> listOptions(
        String opportunityId,
        String selectedQuoteId
    ) {
        Id oppId = parseId(opportunityId, 'Opportunity');
        Id selectedId = String.isBlank(selectedQuoteId)
            ? null
            : parseId(selectedQuoteId, 'Quote');
        reconcileSuiteOptionApprovals(oppId);
        return buildOptionSummaries(oppId, selectedId);
    }

    /**
     * Creates the next empty option Quote (B, C, …) under the Opportunity.
     * Native RC: each option is a real Quote — no shadow cart.
     */
    @AuraEnabled
    public static AddOptionResultDTO addOption(String opportunityId) {
        Id oppId = parseId(opportunityId, 'Opportunity');
        Opportunity opp = RLM_BambooSuiteSession.requireSessionOpportunity(oppId);

        List<OptionSummaryDTO> existing = buildOptionSummaries(oppId, null);
        if (existing.size() >= MAX_OPTIONS) {
            throw new SuiteException(
                'Maximum of ' + MAX_OPTIONS + ' options per opportunity.'
            );
        }
        String nextLetter = nextOptionLetter(existing);
        Quote created = createOptionQuote(opp, nextLetter);
        AddOptionResultDTO result = new AddOptionResultDTO();
        Boolean synced =
            opp.SyncedQuoteId != null && created.Id == opp.SyncedQuoteId;
        result.created = toSummary(
            created,
            buildOptionDetail(created.Id),
            true,
            synced
        );
        result.options = buildOptionSummaries(oppId, created.Id);
        result.session = toSession(opp, created);
        return result;
    }

    /**
     * Delete a suite option Quote (and its lines). Keeps at least one option.
     * If the deleted quote was selected, session switches to another remaining option.
     * If it was the synced / staged winner, clears sync and sets Opportunity.Amount to 0.
     */
    @AuraEnabled
    public static AddOptionResultDTO deleteOption(String quoteId) {
        Id qId = parseId(quoteId, 'Quote');
        Quote q = [
            SELECT
                Id,
                Name,
                Status,
                OpportunityId,
                Opportunity.Name,
                Opportunity.AccountId,
                Opportunity.Account.Name,
                Opportunity.CloseDate,
                Opportunity.Pricebook2Id,
                Opportunity.CurrencyIsoCode,
                Opportunity.SyncedQuoteId,
                Opportunity.RLM_Bamboo_Staged_Sync_Quote_Id__c,
                CurrencyIsoCode
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        if (optionLetterFromName(q.Name) == null) {
            throw new SuiteException('Only suite option quotes can be deleted from the Revenue Suite.');
        }
        if (q.Status != null && q.Status != 'Draft') {
            throw new SuiteException('Only Draft options can be deleted.');
        }

        Id oppId = q.OpportunityId;
        List<OptionSummaryDTO> existing = buildOptionSummaries(oppId, null);
        if (existing.size() <= 1) {
            throw new SuiteException('Keep at least one option. Add another before deleting this one.');
        }

        // Clear sync before deleting the Quote so SyncedQuoteId cannot dangle.
        clearOpportunityForecastForOption(oppId, qId);

        List<QuoteLineItem> lines = [
            SELECT Id
            FROM QuoteLineItem
            WHERE QuoteId = :qId
            WITH USER_MODE
        ];
        if (!lines.isEmpty()) {
            Database.DeleteResult[] lineDrs = Database.delete(lines, false, AccessLevel.USER_MODE);
            for (Database.DeleteResult dr : lineDrs) {
                if (!dr.isSuccess()) {
                    throw new SuiteException(firstError(dr));
                }
            }
        }
        Database.DeleteResult qDr = Database.delete(q, false, AccessLevel.USER_MODE);
        if (!qDr.isSuccess()) {
            throw new SuiteException(firstError(qDr));
        }

        List<OptionSummaryDTO> remaining = buildOptionSummaries(oppId, null);
        if (remaining.isEmpty()) {
            throw new SuiteException('Option delete left no remaining options.');
        }
        Id nextQuoteId = remaining[0].quoteId;
        Quote nextQuote = [
            SELECT Id, Name, QuoteNumber, CurrencyIsoCode, Status
            FROM Quote
            WHERE Id = :nextQuoteId
            WITH USER_MODE
            LIMIT 1
        ];
        Opportunity opp = [
            SELECT
                Id,
                Name,
                AccountId,
                Account.Name,
                CloseDate,
                Pricebook2Id,
                CurrencyIsoCode,
                SyncedQuoteId,
                RLM_Bamboo_Staged_Sync_Quote_Id__c,
                RLM_Bamboo_Sync_Mode__c
            FROM Opportunity
            WHERE Id = :oppId
            WITH USER_MODE
            LIMIT 1
        ];
        AddOptionResultDTO result = new AddOptionResultDTO();
        result.created = null;
        result.options = buildOptionSummaries(oppId, nextQuoteId);
        result.session = toSession(opp, nextQuote);
        return result;
    }

    /**
     * Start Quote→Opportunity sync for a suite option (sets Opportunity.SyncedQuoteId).
     * Same effect as Quote UI Start Sync — Opp products/Amount track this Quote for forecasting.
     */
        public static SyncOpportunityResultDTO syncOptionToOpportunity(String quoteId) {
        Id qId = parseId(quoteId, 'Quote');
        Quote q = [
            SELECT OpportunityId
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        return RLM_BambooSuiteSync.applySyncAction(
            'Commit',
            q.OpportunityId == null ? null : String.valueOf(q.OpportunityId),
            String.valueOf(qId)
        );
    }

    /**
     * Stop Quote→Opportunity sync (clears Opportunity.SyncedQuoteId).
     * Same path as Flow RLM_Bamboo_Suite_Sync action Clear.
     */
        public static SyncOpportunityResultDTO unsyncOpportunity(String opportunityId) {
        return RLM_BambooSuiteSync.applySyncAction(
            'Clear',
            opportunityId,
            null
        );
    }

    @AuraEnabled(cacheable=true)
    public static List<CatalogProductDTO> getCatalog(String currencyIsoCode) {
        String ccy = String.isBlank(currencyIsoCode) ? 'USD' : currencyIsoCode.trim();
        List<PricebookEntry> rows = [
            SELECT
                Id,
                UnitPrice,
                CurrencyIsoCode,
                Product2Id,
                Product2.Name,
                Product2.StockKeepingUnit,
                Product2.Description,
                Product2.Type,
                ProductSellingModel.SellingModelType,
                ProductSellingModel.PricingTermUnit
            FROM PricebookEntry
            WHERE
                Pricebook2.IsStandard = TRUE
                AND IsActive = TRUE
                AND Product2.IsActive = TRUE
                AND Product2.StockKeepingUnit LIKE 'BAMBOO-%'
                AND CurrencyIsoCode = :ccy
                AND ProductSellingModel.PricingTermUnit = 'Months'
                AND ProductSellingModel.SellingModelType = 'TermDefined'
            WITH SYSTEM_MODE
            ORDER BY Product2.StockKeepingUnit
        ];

        Map<String, CatalogProductDTO> bySku = new Map<String, CatalogProductDTO>();
        for (PricebookEntry pbe : rows) {
            String sku = pbe.Product2.StockKeepingUnit;
            if (String.isBlank(sku) || bySku.containsKey(sku)) {
                continue;
            }
            CatalogProductDTO dto = new CatalogProductDTO();
            dto.sku = sku;
            dto.name = pbe.Product2.Name;
            dto.description = pbe.Product2.Description;
            dto.listPrice = pbe.UnitPrice;
            dto.currencyIsoCode = pbe.CurrencyIsoCode;
            dto.product2Id = pbe.Product2Id;
            dto.badge = badgeForSku(sku, pbe.Product2.Type);
            dto.frequent = FREQUENT_SKUS.contains(sku);
            bySku.put(sku, dto);
        }
        return bySku.values();
    }

    @AuraEnabled
    public static OptionDetailDTO getOptionDetail(String quoteId) {
        Id qId = parseId(quoteId, 'Quote');
        reconcileQuoteApprovalStatusFromPlatform(qId);
        return buildOptionDetail(qId);
    }

    /**
     * Headless Instant Pricing estimate for the catalog queue before Place add.
     * Does not create Quote lines — returns RC-priced nets when available.
     */
    @AuraEnabled
    public static RLM_BambooHeadlessPricing.EstimateResultDTO estimateCatalogAdd(
        String currencyIsoCode,
        Integer termMonths,
        String startDateIso,
        List<LineInputDTO> lines
    ) {
        return RLM_BambooHeadlessPricing.estimateLines(
            currencyIsoCode,
            termMonths,
            startDateIso,
            lines
        );
    }

        public static AddLineResultDTO addProductLine(
        String quoteId,
        String sku,
        Decimal quantity,
        Integer termMonths,
        String startDateIso,
        String billingFrequency
    ) {
        LineInputDTO line = new LineInputDTO();
        line.sku = sku;
        line.quantity = quantity;
        return addProductLines(
            quoteId,
            new List<LineInputDTO>{ line },
            termMonths,
            startDateIso,
            billingFrequency
        );
    }

    /**
     * LWC-friendly multi-add with per-SKU quantities (parallel lists avoid nested
     * DTO deserialization gaps from the client).
     * skus[i] pairs with quantities[i]; missing/blank qty defaults to 1.
     */
        public static AddLineResultDTO addProductLinesBySku(
        String quoteId,
        List<String> skus,
        List<Decimal> quantities,
        Integer termMonths,
        String startDateIso,
        String billingFrequency
    ) {
        return RLM_BambooSuitePlace.addProductLinesBySku(
            quoteId,
            skus,
            quantities,
            termMonths,
            startDateIso,
            billingFrequency
        );
    }

    /**
     * Add one or more catalog lines in a single Place + FORCE. Shared term/billing
     * apply to every line in the request. Implementation on RLM_BambooSuitePlace.
     */
        public static AddLineResultDTO addProductLines(
        String quoteId,
        List<LineInputDTO> lines,
        Integer termMonths,
        String startDateIso,
        String billingFrequency
    ) {
        return RLM_BambooSuitePlace.addProductLines(
            quoteId,
            lines,
            termMonths,
            startDateIso,
            billingFrequency
        );
    }

    /**
     * Path A Workforce package: Place package root with configurator default
     * expand. Implementation on RLM_BambooSuitePlace.
     */
        public static AddLineResultDTO addWorkforcePackage(
        String quoteId,
        String planSku,
        Decimal quantity,
        Integer termMonths,
        String startDateIso,
        String billingFrequency
    ) {
        return RLM_BambooSuitePlace.addWorkforcePackage(
            quoteId,
            planSku,
            quantity,
            termMonths,
            startDateIso,
            billingFrequency
        );
    }

    /**
     * Start DocGen for the active option Quote using RLM_Bamboo_QuoteProposal.
     * Returns a process Id; poll {@link #getProposalStatus} until Completed.
     * Same path as Flow RLM_Bamboo_Suite_DocGen_Start / RLM_BambooSuiteDocGen.
     */
        public static PreviewResultDTO previewProposal(String quoteId) {
        return RLM_BambooSuiteDocGen.startPreview(quoteId);
    }

    /** Core DocGen start (shared by Aura + Invocable; avoids recursion). */
    public static PreviewResultDTO previewProposalCore(String quoteId) {
        Id qId = parseId(quoteId, 'Quote');
        Quote q = [
            SELECT Id, Name, QuoteNumber
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];

        List<DocumentTemplate> templates = [
            SELECT Id, Name, TokenMappingMethodType
            FROM DocumentTemplate
            WHERE Name = :PROPOSAL_TEMPLATE_NAME AND IsActive = TRUE
            WITH USER_MODE
            ORDER BY VersionNumber DESC
            LIMIT 1
        ];
        if (templates.isEmpty()) {
            throw new SuiteException(
                'Document template ' +
                    PROPOSAL_TEMPLATE_NAME +
                    ' is not active in this org.'
            );
        }
        DocumentTemplate tmpl = templates[0];

        String title =
            'BambooHR Proposal — ' +
            (String.isNotBlank(q.QuoteNumber) ? q.QuoteNumber : q.Name);

        Map<String, Object> requestText = new Map<String, Object>{
            'keepIntermediate' => true,
            'title' => title
        };
        Id templateCvId = resolveTemplateContentVersionId(tmpl.Name);
        if (templateCvId != null) {
            requestText.put('templateContentVersionId', String.valueOf(templateCvId));
        }

        DocumentGenerationProcess process = new DocumentGenerationProcess();
        process.Type = 'GenerateAndConvert';
        process.ReferenceObject = q.Id;
        process.DocumentTemplateId = tmpl.Id;
        process.RequestText = JSON.serialize(requestText);
        process.DocGenApiVersionType = 'Advanced';
        process.DocumentInputType = 'DocumentTemplate';
        if (tmpl.TokenMappingMethodType == 'ContextService') {
            process.DocGenAdditionalInputType = 'ContextService';
            process.DocGenAdditionalInput = String.valueOf(q.Id);
        } else {
            process.DataRaptorInput = JSON.serialize(
                new Map<String, Object>{ 'Id' => q.Id }
            );
        }
        insert as user process;

        PreviewResultDTO out = new PreviewResultDTO();
        out.processId = process.Id;
        out.status = 'InProgress';
        out.title = title;
        out.message = 'Generating proposal…';
        return out;
    }

    /** Poll DocGen process; when Completed, prefer the PDF ContentVersion. */
    @AuraEnabled
    public static PreviewResultDTO getProposalStatus(String processId) {
        Id pId = parseId(processId, 'DocumentGenerationProcess');
        List<DocumentGenerationProcess> rows = [
            SELECT Id, Status, ResponseText, ReferenceObject
            FROM DocumentGenerationProcess
            WHERE Id = :pId
            WITH USER_MODE
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            throw new SuiteException('Document generation process not found.');
        }
        DocumentGenerationProcess dgp = rows[0];
        PreviewResultDTO out = new PreviewResultDTO();
        out.processId = dgp.Id;
        out.status = dgp.Status;
        if (dgp.Status == 'Failed' || dgp.Status == 'Error') {
            out.message = String.isNotBlank(dgp.ResponseText)
                ? dgp.ResponseText
                : 'Document generation failed.';
            return out;
        }
        if (dgp.Status != 'Completed' && dgp.Status != 'Success') {
            out.message = 'Generating proposal…';
            return out;
        }

        List<Id> versionIds = parseContentVersionIds(dgp.ResponseText);
        if (versionIds.isEmpty()) {
            out.message = 'Generation completed but no file was returned.';
            return out;
        }
        List<ContentVersion> pdfs = [
            SELECT Id, ContentDocumentId, Title, FileType
            FROM ContentVersion
            WHERE Id IN :versionIds AND FileType = 'PDF'
            WITH USER_MODE
            LIMIT 1
        ];
        List<ContentVersion> files = pdfs;
        if (files.isEmpty()) {
            files = [
                SELECT Id, ContentDocumentId, Title, FileType
                FROM ContentVersion
                WHERE Id IN :versionIds
                WITH USER_MODE
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
        }
        if (files.isEmpty()) {
            out.message = 'Generation completed but no readable file was found.';
            return out;
        }
        ContentVersion file = files[0];
        out.contentVersionId = file.Id;
        out.contentDocumentId = file.ContentDocumentId;
        out.title = file.Title;
        out.downloadUrl = '/sfc/servlet.shepherd/version/download/' + file.Id;
        out.message = 'Proposal ready';
        return out;
    }

    /**
     * Submit a suite option Quote into RLM Quote Smart Approval (orchestration).
     * Sets RLM_Approval_Status__c to Pending first; orchestration may move it to
     * Approved immediately when no discount / payment-terms criteria apply.
     * If the orchestration Apex cannot start, falls back to Approved for demo orgs.
     */
    @AuraEnabled
    public static ApprovalResultDTO submitOptionForApproval(
        String quoteId,
        String comments
    ) {
        Id qId = parseId(quoteId, 'Quote');
        Quote q = [
            SELECT
                Id,
                Name,
                OpportunityId,
                RLM_Approval_Status__c,
                RLM_Approval_Level__c
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        if (optionLetterFromName(q.Name) == null) {
            throw new SuiteException(
                'Only Bamboo Revenue Suite option quotes can be submitted for approval.'
            );
        }
        OptionDetailDTO detail = buildOptionDetail(qId);
        if (detail == null || detail.priced != true) {
            throw new SuiteException('Price the option before submitting for approval.');
        }
        String current = normalizeApprovalStatus(q.RLM_Approval_Status__c);
        if (current == 'Pending') {
            throw new SuiteException(
                'This option is already pending approval. Refresh options to check status.'
            );
        }
        if (current == 'Approved') {
            ApprovalResultDTO already = new ApprovalResultDTO();
            already.quoteId = qId;
            already.approvalStatus = 'Approved';
            already.summary = 'Option is already approved.';
            already.option = detail;
            already.options = buildOptionSummaries(q.OpportunityId, qId);
            return already;
        }

        setQuoteApprovalStatus(qId, 'Pending');

        String requestSummary = buildApprovalRequestSummary(qId, detail);
        String submitComments;
        if (String.isBlank(comments)) {
            submitComments = requestSummary;
        } else {
            submitComments = comments.trim() + '\n\n' + requestSummary;
        }

        String summary;
        Boolean usedFallback = false;
        try {
            RLM_AA_Submit_Approval.svcParameter param =
                new RLM_AA_Submit_Approval.svcParameter();
            param.flowName = 'RLM_Quote_Smart_Approval';
            param.recordId = String.valueOf(qId);
            param.approvalLevel = q.RLM_Approval_Level__c == null
                ? null
                : String.valueOf(q.RLM_Approval_Level__c);
            param.comments = submitComments;
            RLM_AA_Submit_Approval.callFlow(
                new List<RLM_AA_Submit_Approval.svcParameter>{ param }
            );
            Decimal level = q.RLM_Approval_Level__c == null ? 0 : q.RLM_Approval_Level__c;
            if (level > 0) {
                summary =
                    'Submitted for Smart Approval (' +
                    approvalRequiredLabelFor(level) +
                    '). Approvers see the line-level ask in submission comments.';
            } else {
                summary =
                    'Submitted for Smart Approval. No discount approval required — refresh if status is not Approved yet.';
            }
        } catch (Exception e) {
            // Orchestration may be unavailable for the running user — demo fallback.
            usedFallback = true;
            setQuoteApprovalStatus(qId, 'Approved');
            String detailMsg = e.getMessage();
            summary =
                'DEMO FALLBACK: Marked Approved because Smart Approval did not start' +
                (String.isBlank(detailMsg) ? '' : ' (' + detailMsg + ')') +
                '. Fix orchestration/assignees on this org for a real approval path.';
        }

        ApprovalResultDTO result = new ApprovalResultDTO();
        result.quoteId = qId;
        result.option = buildOptionDetail(qId);
        result.approvalStatus = result.option != null
            ? result.option.approvalStatus
            : normalizeApprovalStatus(null);
        result.summary = summary;
        result.usedApprovalFallback = usedFallback;
        result.options = buildOptionSummaries(q.OpportunityId, qId);
        return result;
    }

    /**
     * List Assigned Advanced Approvals work items for a suite option Quote.
     * Rows the running user can act on (direct assignee or public-group member)
     * set canAct=true for Approve/Reject in the suite panel.
     */
    @AuraEnabled
    public static PendingApprovalsDTO listPendingApprovalWorkItems(String quoteId) {
        Id qId = parseId(quoteId, 'Quote');
        Quote q = [
            SELECT Id, Name
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        if (optionLetterFromName(q.Name) == null) {
            throw new SuiteException(
                'Only Bamboo Revenue Suite option quotes support in-suite approvals.'
            );
        }

        PendingApprovalsDTO out = new PendingApprovalsDTO();
        out.quoteId = qId;
        out.optionLabel = 'Option ' + optionLetterFromName(q.Name);
        out.items = new List<ApprovalWorkItemRowDTO>();
        out.actionableCount = 0;
        reconcileQuoteApprovalStatusFromPlatform(qId);
        out.requestSummary = latestApprovalSubmissionComments(qId);
        if (String.isBlank(out.requestSummary)) {
            out.requestSummary = buildApprovalRequestSummary(qId, null);
        }

        Set<Id> userGroupIds = groupIdsForUser(UserInfo.getUserId());
        Id currentUserId = UserInfo.getUserId();

        for (ApprovalWorkItem wi : [
            SELECT
                Id,
                Name,
                Status,
                AssignedToId,
                AssignedTo.Name,
                ApprovalChainName
            FROM ApprovalWorkItem
            WHERE RelatedRecordId = :qId AND Status = 'Assigned'
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ]) {
            ApprovalWorkItemRowDTO row = new ApprovalWorkItemRowDTO();
            row.workItemId = wi.Id;
            row.stepName = wi.Name;
            row.chainName = wi.ApprovalChainName;
            row.assignedToLabel = wi.AssignedTo != null ? wi.AssignedTo.Name : null;
            row.status = wi.Status;
            row.canAct =
                wi.AssignedToId == currentUserId ||
                (wi.AssignedToId != null && userGroupIds.contains(wi.AssignedToId));
            if (row.canAct == true) {
                out.actionableCount++;
            }
            out.items.add(row);
        }
        out.quoteApprovalsUrl = RLM_BambooSuiteApprovals.quoteApprovalsUrl(qId);
        out.workGuideHint =
            'Prefer the Quote Approvals tab Work Guide for Manager → Director → VP. ' +
            'This panel lists Assigned steps for convenience.';
        return out;
    }

    /**
     * Approve or reject one Assigned work item via platform reviewApprovalWorkItem.
     * Refreshes option approval status after the decision.
     */
    @AuraEnabled
    public static ApprovalResultDTO reviewSuiteApprovalWorkItem(
        String workItemId,
        String decision,
        String comments
    ) {
        Id wiId = parseId(workItemId, 'ApprovalWorkItem');
        String normalizedDecision = normalizeReviewDecision(decision);

        ApprovalWorkItem wi = [
            SELECT
                Id,
                Status,
                RelatedRecordId,
                AssignedToId,
                Name,
                ApprovalChainName
            FROM ApprovalWorkItem
            WHERE Id = :wiId
            WITH USER_MODE
            LIMIT 1
        ];
        if (wi.Status != 'Assigned') {
            throw new SuiteException(
                'This approval step is no longer waiting for a decision.'
            );
        }
        Id qId = wi.RelatedRecordId;
        Quote q = [
            SELECT Id, Name, OpportunityId
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        if (optionLetterFromName(q.Name) == null) {
            throw new SuiteException(
                'Only Bamboo Revenue Suite option quotes support in-suite approvals.'
            );
        }

        Set<Id> userGroupIds = groupIdsForUser(UserInfo.getUserId());
        Id currentUserId = UserInfo.getUserId();
        Boolean canAct =
            wi.AssignedToId == currentUserId ||
            (wi.AssignedToId != null && userGroupIds.contains(wi.AssignedToId));
        if (!canAct) {
            throw new SuiteException(
                'You are not the assignee for this approval step. Sign in as the Manager/Director/VP assignee or a group member.'
            );
        }
        if (
            normalizedDecision == 'Reject' &&
            String.isBlank(comments)
        ) {
            throw new SuiteException(
                'Reject requires comments naming which line(s) to fix ' +
                '(e.g. Reject Payroll @ 50%. Keep Core @ 25%.).'
            );
        }

        invokeReviewApprovalWorkItem(wiId, normalizedDecision, comments);
        String syncedStatus = syncQuoteApprovalStatusFromPlatform(
            qId,
            normalizedDecision
        );

        ApprovalResultDTO result = new ApprovalResultDTO();
        result.quoteId = qId;
        result.option = buildOptionDetail(qId);
        result.approvalStatus = result.option != null
            ? result.option.approvalStatus
            : syncedStatus;
        String stepBit =
            (normalizedDecision == 'Approve' ? 'Approved' : 'Rejected') +
            ' ' +
            (String.isBlank(wi.Name) ? 'approval step' : wi.Name) +
            (String.isBlank(wi.ApprovalChainName)
                ? ''
                : ' (' + wi.ApprovalChainName + ')');
        if (syncedStatus == 'Approved') {
            result.summary = stepBit + '. Quote approval status is Approved.';
        } else if (syncedStatus == 'Rejected') {
            result.summary =
                stepBit +
                '. Quote is Rejected — edit the lines named in your comments, ' +
                'then Commit and Submit again (unchanged conditions may Smart-Approve).';
        } else {
            result.summary =
                stepBit +
                '. Quote stays Pending until remaining steps finish.';
        }
        result.options = buildOptionSummaries(q.OpportunityId, qId);
        return result;
    }

    /**
     * Recall the open Advanced Approvals submission for a suite option and set
     * Quote.RLM_Approval_Status__c to Recalled (Quote Path / TLE).
     */
    @AuraEnabled
    public static ApprovalResultDTO recallOptionApproval(
        String quoteId,
        String comments
    ) {
        Id qId = parseId(quoteId, 'Quote');
        Quote q = [
            SELECT Id, Name, OpportunityId, RLM_Approval_Status__c
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        if (optionLetterFromName(q.Name) == null) {
            throw new SuiteException(
                'Only Bamboo Revenue Suite option quotes support in-suite approvals.'
            );
        }
        if (normalizeApprovalStatus(q.RLM_Approval_Status__c) != 'Pending') {
            throw new SuiteException(
                'Only Pending options can be recalled.'
            );
        }
        List<ApprovalSubmission> subs = [
            SELECT Id, Status
            FROM ApprovalSubmission
            WHERE RelatedRecordId = :qId AND Status IN ('InProgress', 'Suspended')
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (subs.isEmpty()) {
            setQuoteApprovalStatus(qId, 'Recalled');
        } else {
            invokeRecallApprovalSubmission(
                subs[0].Id,
                comments
            );
            setQuoteApprovalStatus(qId, 'Recalled');
        }

        ApprovalResultDTO result = new ApprovalResultDTO();
        result.quoteId = qId;
        result.option = buildOptionDetail(qId);
        result.approvalStatus = result.option != null
            ? result.option.approvalStatus
            : 'Recalled';
        result.summary = 'Approval recalled. Quote status is Recalled.';
        result.options = buildOptionSummaries(q.OpportunityId, qId);
        try {
            RLM_BambooSuiteSync.SyncResult sync =
                RLM_BambooSuiteSync.recommitStagedWinner(q.OpportunityId);
            if (
                sync != null &&
                sync.syncMode == RLM_BambooSuiteSync.MODE_COMMITTED
            ) {
                result.summary =
                    result.summary +
                    ' Opportunity sync restored (Committed) for resubmit.';
                result.options = buildOptionSummaries(q.OpportunityId, qId);
                if (result.option != null) {
                    // Refresh option so session chips can pick up sync from options list.
                }
            }
        } catch (Exception e) {
            // Recall succeeded; recommit is best-effort.
        }
        return result;
    }

    /** Contacts on the suite Opportunity Account (email required) for Send picker. */
    @AuraEnabled(cacheable=true)
    public static List<ContactOptionDTO> listOpportunityContacts(String opportunityId) {
        Id oppId = parseId(opportunityId, 'Opportunity');
        Opportunity opp = [
            SELECT AccountId
            FROM Opportunity
            WHERE Id = :oppId
            WITH USER_MODE
            LIMIT 1
        ];
        List<ContactOptionDTO> out = new List<ContactOptionDTO>();
        if (opp.AccountId == null) {
            return out;
        }
        for (Contact c : [
            SELECT Id, Name, Email
            FROM Contact
            WHERE AccountId = :opp.AccountId AND Email != NULL
            WITH USER_MODE
            ORDER BY Name ASC
            LIMIT 50
        ]) {
            ContactOptionDTO row = new ContactOptionDTO();
            row.contactId = c.Id;
            row.name = c.Name;
            row.email = c.Email;
            out.add(row);
        }
        return out;
    }

    /**
     * Email the active option to an Opp Contact (or toAddress override).
     * Same path as Flow RLM_Bamboo_Suite_Send / RLM_BambooSuiteSend.
     */
        public static SendResultDTO sendOptionToCustomer(
        String quoteId,
        String contactId,
        String toAddress,
        Boolean attachPdf,
        Boolean generatePdfIfMissing
    ) {
        return RLM_BambooSuiteSend.sendOptionToCustomer(
            quoteId,
            contactId,
            toAddress,
            attachPdf,
            generatePdfIfMissing
        );
    }

    /** Core send (shared by Aura + Invocable; avoids recursion). */
    public static SendResultDTO sendOptionToCustomerCore(
        String quoteId,
        String contactId,
        String toAddress,
        Boolean attachPdf,
        Boolean generatePdfIfMissing
    ) {
        Id qId = parseId(quoteId, 'Quote');
        Quote q = [
            SELECT
                Id,
                Name,
                OpportunityId,
                ContactId,
                RLM_Approval_Status__c
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        if (optionLetterFromName(q.Name) == null) {
            throw new SuiteException(
                'Only Bamboo Revenue Suite option quotes can be sent from the suite.'
            );
        }
        OptionDetailDTO detail = buildOptionDetail(qId);
        if (detail == null || detail.priced != true) {
            throw new SuiteException('Price the option before sending to the customer.');
        }
        String approval = normalizeApprovalStatus(q.RLM_Approval_Status__c);
        if (approval == 'Pending') {
            throw new SuiteException(
                'Cannot send while approval is Pending. Wait for Approved or recall first.'
            );
        }

        Id cvId = null;
        if (attachPdf != false) {
            cvId = findLatestProposalContentVersionId(qId);
            if (cvId == null && generatePdfIfMissing == true) {
                throw new SuiteException(
                    'No proposal PDF found. Click Preview to generate one, then Send again.'
                );
            }
        }

        if (String.isNotBlank(contactId)) {
            Id cId = parseId(contactId, 'Contact');
            if (q.ContactId != cId) {
                Database.update(
                    new Quote(Id = qId, ContactId = cId),
                    false,
                    AccessLevel.USER_MODE
                );
            }
        }

        RLM_BambooQuoteEmail.Request req = new RLM_BambooQuoteEmail.Request();
        req.quoteId = qId;
        req.contentVersionId = cvId;
        if (String.isNotBlank(toAddress)) {
            req.toAddress = toAddress.trim();
        }
        RLM_BambooQuoteEmail.Result emailed = RLM_BambooQuoteEmail.sendOne(req);

        SendResultDTO out = new SendResultDTO();
        out.success = emailed.success == true;
        out.message = emailed.message;
        out.toAddress = emailed.toAddress;
        out.quoteId = qId;
        out.contentVersionId = cvId;
        if (!out.success) {
            throw new SuiteException(
                String.isNotBlank(out.message) ? out.message : 'Send email failed.'
            );
        }
        return out;
    }

    /**
     * Line-level ask for approvers (submission comments + suite panel).
     * Example: "90% off · BambooHR Core · 700 users · $0.75/user/mo (list $7.50)".
     */
    @TestVisible
    static String buildApprovalRequestSummary(
        Id quoteId,
        OptionDetailDTO detail
    ) {
        OptionDetailDTO d = detail != null ? detail : buildOptionDetail(quoteId);
        List<String> lines = new List<String>();
        lines.add('BambooHR Revenue Suite approval request');
        if (d != null) {
            if (String.isNotBlank(d.optionLabel)) {
                lines.add('Option: ' + d.optionLabel);
            }
            Decimal level = d.approvalLevel == null ? 0 : d.approvalLevel;
            lines.add(
                'Approval ladder: ' +
                approvalRequiredLabelFor(level) +
                ' (level ' +
                String.valueOf(level) +
                ')'
            );
            if (d.grandTotal != null) {
                lines.add('Grand total: ' + formatApprovalMoney(d.grandTotal));
            }
            if (d.mrr != null) {
                lines.add('MRR: ' + formatApprovalMoney(d.mrr));
            }
        }

        List<QuoteLineItem> qlis = [
            SELECT
                Id,
                Quantity,
                Discount,
                UnitPrice,
                NetUnitPrice,
                ParentQuoteLineItemId,
                Product2.Name,
                Product2.StockKeepingUnit,
                RLM_Approval_Level_Calc__c
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            WITH USER_MODE
            ORDER BY CreatedDate ASC
            LIMIT 50
        ];
        List<String> needsApproval = new List<String>();
        List<String> otherLines = new List<String>();
        for (QuoteLineItem qi : qlis) {
            if (qi.ParentQuoteLineItemId != null) {
                continue;
            }
            String row = formatApprovalLineAsk(qi);
            Decimal lvl = qi.RLM_Approval_Level_Calc__c == null
                ? 0
                : qi.RLM_Approval_Level_Calc__c;
            if (lvl > 0) {
                needsApproval.add('• ' + row);
            } else {
                otherLines.add('• ' + row);
            }
        }
        if (!needsApproval.isEmpty()) {
            lines.add('Lines requiring approval:');
            lines.addAll(needsApproval);
        }
        if (!otherLines.isEmpty() && otherLines.size() <= 8) {
            lines.add('Other lines (auto / no ladder):');
            lines.addAll(otherLines);
        }
        if (needsApproval.isEmpty() && otherLines.isEmpty()) {
            lines.add('No priced lines on this option.');
        }
        return String.join(lines, '\n');
    }

    private static String formatApprovalLineAsk(QuoteLineItem qi) {
        Decimal disc = qi.Discount == null ? 0 : qi.Discount;
        // Discount is stored as percent 0–100 in API for suite edits.
        if (disc > 0 && disc <= 1) {
            disc = disc * 100;
        }
        String name = qi.Product2 != null && String.isNotBlank(qi.Product2.Name)
            ? qi.Product2.Name
            : (qi.Product2 != null ? qi.Product2.StockKeepingUnit : 'Product');
        Decimal qty = qi.Quantity == null ? 0 : qi.Quantity;
        Decimal net = qi.NetUnitPrice != null ? qi.NetUnitPrice : qi.UnitPrice;
        Decimal listPrice = qi.UnitPrice;
        String ask =
            String.valueOf(disc.setScale(1, System.RoundingMode.HALF_UP)) +
            '% off · ' +
            name +
            ' · ' +
            String.valueOf(qty.setScale(0, System.RoundingMode.HALF_UP)) +
            ' users';
        if (net != null) {
            ask += ' · ' + formatApprovalMoney(net) + '/user/mo';
        }
        if (listPrice != null && net != null && listPrice != net) {
            ask += ' (list ' + formatApprovalMoney(listPrice) + ')';
        }
        return ask;
    }

    private static String formatApprovalMoney(Decimal amount) {
        if (amount == null) {
            return '$0';
        }
        Decimal scaled = amount.setScale(2, System.RoundingMode.HALF_UP);
        // Keep fractional cents when present (e.g. $0.75).
        String raw = String.valueOf(scaled);
        if (!raw.contains('.')) {
            raw = raw + '.00';
        }
        return '$' + raw;
    }

    private static String latestApprovalSubmissionComments(Id quoteId) {
        List<ApprovalSubmission> subs = [
            SELECT Comments
            FROM ApprovalSubmission
            WHERE RelatedRecordId = :quoteId
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (subs.isEmpty() || String.isBlank(subs[0].Comments)) {
            return null;
        }
        return subs[0].Comments;
    }

    /**
     * Latest Reject (or Recall) comments for Option 2 guidance on the option.
     * Prefers rejected work-item Comments; falls back to recall/submission notes.
     */
    @TestVisible
    static String latestDecisionCommentsForGuidance(Id quoteId) {
        if (quoteId == null) {
            return null;
        }
        List<ApprovalWorkItem> rejected = [
            SELECT Comments, ReviewedDate
            FROM ApprovalWorkItem
            WHERE RelatedRecordId = :quoteId AND Status = 'Rejected'
            WITH SYSTEM_MODE
            ORDER BY ReviewedDate DESC NULLS LAST, CreatedDate DESC
            LIMIT 5
        ];
        for (ApprovalWorkItem wi : rejected) {
            if (String.isNotBlank(wi.Comments)) {
                return wi.Comments.trim();
            }
        }
        List<ApprovalSubmission> recalled = [
            SELECT Comments, Status
            FROM ApprovalSubmission
            WHERE
                RelatedRecordId = :quoteId
                AND Status IN ('Recalled', 'Rejected')
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (
            !recalled.isEmpty() &&
            String.isNotBlank(recalled[0].Comments)
        ) {
            return recalled[0].Comments.trim();
        }
        return null;
    }

    /**
     * Block commercial Place/edits while approval is Pending or Approved.
     * Pending → Recall first; Approved stays locked (add a new option to re-quote).
     */
    @TestVisible
    static void assertOptionEditable(Id quoteId) {
        if (quoteId == null) {
            return;
        }
        List<Quote> rows = [
            SELECT Id, RLM_Approval_Status__c
            FROM Quote
            WHERE Id = :quoteId
            WITH USER_MODE
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            return;
        }
        String current = normalizeApprovalStatus(rows[0].RLM_Approval_Status__c);
        if (current == 'Approved') {
            throw new SuiteException(
                'This option is Approved and locked. Add a new option to re-quote the deal.'
            );
        }
        if (current == 'Pending') {
            throw new SuiteException(
                'This option is Pending approval and locked. Recall first if you need to edit.'
            );
        }
    }

    private static void setQuoteApprovalStatus(Id quoteId, String status) {
        Database.SaveResult sr = Database.update(
            new Quote(Id = quoteId, RLM_Approval_Status__c = status),
            false,
            AccessLevel.USER_MODE
        );
        if (!sr.isSuccess()) {
            throw new SuiteException(firstError(sr));
        }
    }

    /**
     * Align Quote.RLM_Approval_Status__c (Path / TLE) with Advanced Approvals.
     * Platform ApprovalSubmission is authoritative. Used after suite review and
     * on suite open/refresh so TLE Path and suite chips stay in sync when the
     * AE acts in either surface.
     * SYSTEM_MODE for ApprovalSubmission — object CRUD not grantable on BambooHR license.
     */
    @TestVisible
    static String syncQuoteApprovalStatusFromPlatform(
        Id quoteId,
        String lastDecision
    ) {
        if (quoteId == null) {
            return null;
        }
        if (lastDecision == 'Reject') {
            setQuoteApprovalStatus(quoteId, 'Rejected');
            return 'Rejected';
        }
        return reconcileQuoteApprovalStatusFromPlatform(quoteId);
    }

    /**
     * Re-read latest ApprovalSubmission / work items and write RLM_Approval_Status__c.
     * Does not invent Approved when work items are temporarily empty.
     */
    @TestVisible
    static String reconcileQuoteApprovalStatusFromPlatform(Id quoteId) {
        if (quoteId == null) {
            return null;
        }
        List<Quote> quotes = [
            SELECT Id, RLM_Approval_Status__c
            FROM Quote
            WHERE Id = :quoteId
            WITH USER_MODE
            LIMIT 1
        ];
        if (quotes.isEmpty()) {
            return null;
        }
        String current = normalizeApprovalStatus(quotes[0].RLM_Approval_Status__c);

        List<ApprovalSubmission> subs = [
            SELECT Id, Status
            FROM ApprovalSubmission
            WHERE RelatedRecordId = :quoteId
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (subs.isEmpty()) {
            // Orphan Pending with no platform submission — clear to blank (suite "Draft").
            if (current == 'Pending') {
                setQuoteApprovalStatus(quoteId, null);
                return 'Draft';
            }
            return current;
        }

        String subStatus = subs[0].Status;
        if (subStatus == 'Approved') {
            setQuoteApprovalStatus(quoteId, 'Approved');
            return 'Approved';
        }
        if (subStatus == 'Rejected') {
            setQuoteApprovalStatus(quoteId, 'Rejected');
            return 'Rejected';
        }
        if (subStatus == 'Recalled') {
            setQuoteApprovalStatus(quoteId, 'Recalled');
            return 'Recalled';
        }

        Id submissionId = subs[0].Id;
        Integer rejectedCount = [
            SELECT COUNT()
            FROM ApprovalWorkItem
            WHERE
                ApprovalSubmissionId = :submissionId
                AND Status = 'Rejected'
            WITH SYSTEM_MODE
        ];
        if (rejectedCount > 0) {
            setQuoteApprovalStatus(quoteId, 'Rejected');
            return 'Rejected';
        }

        setQuoteApprovalStatus(quoteId, 'Pending');
        return 'Pending';
    }

    /**
     * Reconcile Path/TLE approval status for every suite option on the Opp.
     */
    @TestVisible
    static void reconcileSuiteOptionApprovals(Id opportunityId) {
        if (opportunityId == null) {
            return;
        }
        for (Quote q : [
            SELECT Id
            FROM Quote
            WHERE OpportunityId = :opportunityId AND Name LIKE '%Option %'
            WITH USER_MODE
        ]) {
            reconcileQuoteApprovalStatusFromPlatform(q.Id);
        }
    }

    private static void invokeRecallApprovalSubmission(
        Id submissionId,
        String comments
    ) {
        Invocable.Action action = Invocable.Action.createStandardAction(
            'recallApprovalSubmission'
        );
        action.setInvocationParameter(
            'approvalSubmissionId',
            String.valueOf(submissionId)
        );
        action.setInvocationParameter(
            'comments',
            String.isBlank(comments)
                ? 'Recalled from BambooHR Revenue Suite'
                : comments.trim()
        );
        List<Invocable.Action.Result> results = action.invoke();
        if (results == null || results.isEmpty()) {
            throw new SuiteException(
                'Recall approval submission returned no result.'
            );
        }
        Invocable.Action.Result res = results[0];
        if (!res.isSuccess()) {
            List<String> msgs = new List<String>();
            if (res.getErrors() != null) {
                for (Invocable.Action.Error err : res.getErrors()) {
                    msgs.add(err.getMessage());
                }
            }
            throw new SuiteException(
                'Could not recall approval: ' +
                (msgs.isEmpty() ? 'Unknown error' : String.join(msgs, '; '))
            );
        }
    }

    /**
     * After a material commercial Place, Rejected/Recalled options return to Draft
     * so Send stays gated until the AE resubmits. Approved/Pending are blocked by
     * assertOptionEditable (explicit Recall when Pending; Approved stays locked)
     * — not auto-cleared.
     */
    @TestVisible
    static void invalidateOptionApprovalIfNeeded(Id quoteId) {
        if (quoteId == null) {
            return;
        }
        List<Quote> rows = [
            SELECT Id, RLM_Approval_Status__c
            FROM Quote
            WHERE Id = :quoteId
            WITH USER_MODE
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            return;
        }
        String current = normalizeApprovalStatus(rows[0].RLM_Approval_Status__c);
        if (current == 'Rejected' || current == 'Recalled') {
            setQuoteApprovalStatus(quoteId, null);
        }
    }

    @TestVisible
    static String approvalRequiredLabelFor(Decimal level) {
        Decimal n = level == null ? 0 : level;
        if (n >= 3) {
            return 'Manager → Director → VP';
        }
        if (n >= 2) {
            return 'Manager → Director';
        }
        if (n >= 1) {
            return 'Manager';
        }
        return 'None';
    }

    @TestVisible
    static String normalizeApprovalStatus(String raw) {
        if (String.isBlank(raw)) {
            return 'Draft';
        }
        String v = raw.trim();
        if (v.equalsIgnoreCase('Pending')) {
            return 'Pending';
        }
        if (v.equalsIgnoreCase('Approved')) {
            return 'Approved';
        }
        if (v.equalsIgnoreCase('Rejected')) {
            return 'Rejected';
        }
        if (v.equalsIgnoreCase('Recalled')) {
            return 'Recalled';
        }
        return v;
    }

    private static Id findLatestProposalContentVersionId(Id quoteId) {
        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :quoteId
            WITH USER_MODE
            ORDER BY SystemModstamp DESC
            LIMIT 20
        ];
        if (links.isEmpty()) {
            return null;
        }
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink link : links) {
            docIds.add(link.ContentDocumentId);
        }
        List<ContentVersion> versions = [
            SELECT Id, Title, FileType
            FROM ContentVersion
            WHERE
                ContentDocumentId IN :docIds
                AND IsLatest = TRUE
                AND FileType = 'PDF'
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 10
        ];
        for (ContentVersion cv : versions) {
            if (
                String.isNotBlank(cv.Title) &&
                cv.Title.toLowerCase().contains('proposal')
            ) {
                return cv.Id;
            }
        }
        return versions.isEmpty() ? null : versions[0].Id;
    }

    /**
     * Commercial operation gateway — prefer this for new LWC mutators.
     * @see RLM_BambooSuiteCommercial
     */
    @AuraEnabled
    public static RLM_BambooSuiteCommercial.OperationResult runCommercialOperation(
        String operation,
        String quoteId,
        String opportunityId,
        String payloadJson
    ) {
        RLM_BambooSuiteCommercial.OperationRequest req =
            new RLM_BambooSuiteCommercial.OperationRequest();
        req.operation = operation;
        req.quoteId = quoteId;
        req.opportunityId = opportunityId;
        req.payloadJson = payloadJson;
        return RLM_BambooSuiteCommercial.run(req);
    }

    /**
     * BotDefinition Id for Quoting Assistant (Quinn) — used by suite rail
     * lightning/accApi open/execute. Null when the agent is not published in the org.
     */
    @AuraEnabled(cacheable=true)
    public static String getQuotingAssistantBotId() {
        List<BotDefinition> bots = [
            SELECT Id
            FROM BotDefinition
            WHERE DeveloperName = 'RLM_Quoting_Assistant'
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return bots.isEmpty() ? null : String.valueOf(bots[0].Id);
    }

    /**
     * Ensure Option A/B/C exist for the Opportunity (create empty B/C as needed).
     * Does not clear or fill lines — call {@link #fillTierOption} per tier.
     */
    @AuraEnabled
    public static TierOptionsResultDTO ensureGoodBetterBestOptions(String opportunityId) {
        Id oppId = parseId(opportunityId, 'Opportunity');
        Opportunity opp = RLM_BambooSuiteSession.requireSessionOpportunity(oppId);

        List<OptionSummaryDTO> options = buildOptionSummaries(oppId, null);
        while (options.size() < 3) {
            if (options.size() >= MAX_OPTIONS) {
                throw new SuiteException(
                    'Need Options A–C for Good/Better/Best, but the opportunity already has ' +
                        MAX_OPTIONS +
                        ' options.'
                );
            }
            String nextLetter = nextOptionLetter(options);
            createOptionQuote(opp, nextLetter);
            options = buildOptionSummaries(oppId, null);
        }

        Id goodId = quoteIdForLetter(options, 'A');
        Id betterId = quoteIdForLetter(options, 'B');
        Id bestId = quoteIdForLetter(options, 'C');
        if (goodId == null || betterId == null || bestId == null) {
            throw new SuiteException(
                'Could not resolve Option A/B/C for Good/Better/Best.'
            );
        }

        Quote goodQuote = [
            SELECT Id, Name, QuoteNumber, CurrencyIsoCode, Status
            FROM Quote
            WHERE Id = :goodId
            WITH USER_MODE
            LIMIT 1
        ];

        TierOptionsResultDTO result = new TierOptionsResultDTO();
        result.options = buildOptionSummaries(oppId, goodId);
        result.session = toSession(opp, goodQuote);
        result.goodQuoteId = goodId;
        result.betterQuoteId = betterId;
        result.bestQuoteId = bestId;
        result.summary =
            'Ready to fill Good (A), Better (B), and Best (C) for ' + opp.Name + '.';
        return result;
    }

    /**
     * Clear existing lines on a suite option and fill Good / Better / Best catalog.
     * Implementation on RLM_BambooSuitePlace.
     */
    @AuraEnabled
    public static OptionDetailDTO fillTierOption(
        String quoteId,
        String tierKey,
        Decimal seats,
        Integer termMonths,
        String startDateIso,
        String billingFrequency
    ) {
        return RLM_BambooSuitePlace.fillTierOption(
            quoteId,
            tierKey,
            seats,
            termMonths,
            startDateIso,
            billingFrequency
        );
    }

    private static Id quoteIdForLetter(List<OptionSummaryDTO> options, String letter) {
        if (options == null || String.isBlank(letter)) {
            return null;
        }
        for (OptionSummaryDTO opt : options) {
            if (opt != null && optionLetter(opt.optionLabel) == letter) {
                return opt.quoteId;
            }
        }
        return null;
    }

    private static Id resolveTemplateContentVersionId(String templateName) {
        List<ContentWorkspace> libs = [
            SELECT Id
            FROM ContentWorkspace
            WHERE DeveloperName = 'DocgenDocumentTemplateLibrary'
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (libs.isEmpty()) {
            return null;
        }
        List<ContentDocument> docs = [
            SELECT Id
            FROM ContentDocument
            WHERE
                Title = :templateName
                AND Id IN (
                    SELECT ContentDocumentId
                    FROM ContentWorkspaceDoc
                    WHERE ContentWorkspaceId = :libs[0].Id
                )
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (docs.isEmpty()) {
            return null;
        }
        List<ContentVersion> versions = [
            SELECT Id
            FROM ContentVersion
            WHERE ContentDocumentId = :docs[0].Id
            WITH SYSTEM_MODE
            ORDER BY VersionNumber DESC
            LIMIT 1
        ];
        return versions.isEmpty() ? null : versions[0].Id;
    }

    private static List<Id> parseContentVersionIds(String responseText) {
        List<Id> ids = new List<Id>();
        if (String.isBlank(responseText)) {
            return ids;
        }
        String text = responseText.trim();
        if (text.startsWith('{') || text.startsWith('[')) {
            return ids;
        }
        for (String token : text.split(',')) {
            String trimmed = token.trim();
            if (String.isBlank(trimmed)) {
                continue;
            }
            try {
                ids.add((Id) trimmed);
            } catch (Exception e) {
                // skip non-Id tokens
            }
        }
        return ids;
    }

    /**
     * Persist quantity via Place Sales Transaction + FORCE pricing (RC engine).
     * LWC should debounce (300–500ms); not every keystroke.
     * Implementation lives on RLM_BambooSuitePlace (Place edge).
     */
        public static OptionDetailDTO updateLineQuantity(
        String quoteId,
        String lineId,
        Decimal quantity
    ) {
        return RLM_BambooSuitePlace.updateLineQuantity(quoteId, lineId, quantity);
    }

    /**
     * Persist AE line discount % via QuoteLineItem.Discount + FORCE pricing.
     * Implementation lives on RLM_BambooSuitePlace (Place edge).
     */
        public static OptionDetailDTO updateLineDiscount(
        String quoteId,
        String lineId,
        Decimal discountPercent
    ) {
        return RLM_BambooSuitePlace.updateLineDiscount(quoteId, lineId, discountPercent);
    }

    /**
     * Broadcast the same AE Discount % to every line on a suite option quote
     * via Place + FORCE. Null / blank clears the AE discount.
     */
        public static OptionDetailDTO updateOptionDiscount(
        String quoteId,
        Decimal discountPercent
    ) {
        return RLM_BambooSuitePlace.updateOptionDiscount(quoteId, discountPercent);
    }

    /**
     * Set the same seat count on every line of a suite option quote via PST + FORCE.
     * Use for Agentforce seat-only changes (not tier rebuilds). Preserves bundle
     * hierarchy and reprices volume tiers.
     */
        public static OptionDetailDTO updateOptionSeatCount(
        String quoteId,
        Decimal seats
    ) {
        return RLM_BambooSuitePlace.updateOptionSeatCount(quoteId, seats);
    }

    /**
     * Resolve a suite option Quote Id from an Opportunity plus Good/Better/Best
     * or Option A/B/C label. Used by Agentforce seat-update invocable.
     */
    @AuraEnabled
    public static Id resolveSuiteOptionQuoteId(
        String opportunityId,
        String optionLabel
    ) {
        Id oppId = parseId(opportunityId, 'Opportunity');
        String letter = suiteOptionLetterFromLabel(optionLabel);
        if (String.isBlank(letter)) {
            throw new SuiteException(
                'optionLabel must be Good, Better, Best, or Option A/B/C.'
            );
        }
        List<OptionSummaryDTO> options = buildOptionSummaries(oppId, null);
        Id qId = quoteIdForLetter(options, letter);
        if (qId == null) {
            throw new SuiteException(
                'No Option ' + letter + ' quote found on this Opportunity.'
            );
        }
        return qId;
    }

    /** Re-run System pricing on the option quote (FORCE) without structural changes. */
        public static OptionDetailDTO repriceOption(String quoteId) {
        return RLM_BambooSuitePlace.repriceOption(quoteId);
    }

    /**
     * Remove a line via Place Sales Transaction DELETE + FORCE reprice.
     */
        public static OptionDetailDTO removeLine(String quoteId, String lineId) {
        return RLM_BambooSuitePlace.removeLine(quoteId, lineId);
    }

    /**
     * Remove one or more lines in a single Place DELETE + FORCE reprice.
     */
        public static OptionDetailDTO removeLines(String quoteId, List<String> lineIds) {
        return RLM_BambooSuitePlace.removeLines(quoteId, lineIds);
    }

    /**
     * Apply term length (+ optional start date) to the active option: restamp every
     * line onto the matching Evergreen / TermDefined PBE with Start/End dates via
     * Place DELETE+POST + FORCE. Empty options are a no-op (UI keeps ribbon until add).
     * End date = start + termMonths − 1 day (Neocol-style inclusive term).
     */
        public static OptionDetailDTO applyTermToOption(
        String quoteId,
        Integer termMonths,
        String startDateIso,
        String billingFrequency
    ) {
        return RLM_BambooSuitePlace.applyTermToOption(
            quoteId,
            termMonths,
            startDateIso,
            billingFrequency
        );
    }

        public static OptionDetailDTO applyTermToAllOptions(
        String opportunityId,
        String selectedQuoteId,
        Integer termMonths,
        String startDateIso,
        List<String> quoteIds
    ) {
        return RLM_BambooSuitePlace.applyTermToAllOptions(
            opportunityId,
            selectedQuoteId,
            termMonths,
            startDateIso,
            quoteIds
        );
    }

        public static OptionDetailDTO applyBillingToAllOptions(
        String opportunityId,
        String selectedQuoteId,
        String billingFrequency,
        Map<String, Integer> termMonthsByQuoteId,
        Map<String, String> startDateByQuoteId,
        List<String> quoteIds
    ) {
        return RLM_BambooSuitePlace.applyBillingToAllOptions(
            opportunityId,
            selectedQuoteId,
            billingFrequency,
            termMonthsByQuoteId,
            startDateByQuoteId,
            quoteIds
        );
    }

    /**
     * Blanket the same manual discount across every line of every suite option
     * on the opportunity via Place + FORCE. Fans out to updateOptionDiscount per
     * option; empty options are skipped. Pass quoteIds to scope; null = all.
     */
        public static OptionDetailDTO applyDiscountToAllOptions(
        String opportunityId,
        String selectedQuoteId,
        Decimal discountPercent,
        List<String> quoteIds
    ) {
        return RLM_BambooSuitePlace.applyDiscountToAllOptions(
            opportunityId,
            selectedQuoteId,
            discountPercent,
            quoteIds
        );
    }

    /** Slice 4d Phase A — immediate retries on Opp row lock. */
    @TestVisible
    private static final Integer LOCK_RETRY_ATTEMPTS = 3;

    /** Slice 4d Phase B — route commercial mutations through txn orchestrator when true. */
    @TestVisible
    private static Boolean USE_TXN_ORCHESTRATOR = true;

    /** When true, Place runs without nested suspend/restore (orchestrator owns sync lifecycle). */
    @TestVisible
    private static Boolean TXN_JOB_IN_PROGRESS = false;

    public static Boolean isTxnOrchestratorEnabled() {
        return USE_TXN_ORCHESTRATOR == true;
    }

    @TestVisible
    public static void setTxnJobInProgress(Boolean value) {
        TXN_JOB_IN_PROGRESS = value == true;
    }

    public static Boolean isTxnJobInProgressPublic() {
        return TXN_JOB_IN_PROGRESS == true;
    }

    public static Id syncedQuoteIdForOpportunityPublic(Id opportunityId) {
        return syncedQuoteIdForOpportunity(opportunityId);
    }

    public static void clearOpportunitySyncedQuotePublic(Id opportunityId) {
        setOpportunitySyncedQuote(opportunityId, null);
    }

    /**
     * PST locks the parent Opportunity when SyncedQuoteId is set (even for a sibling
     * option quote). Clear sync before Place, verify pricing while still unsynced, then
     * restore SyncedQuoteId asynchronously (Queueable) so PST and Opp DML do not race.
     */
    public static void placeForcePublic(
        Id quoteId,
        List<RevSalesTrxn.RecordWithReferenceRequest> nodes
    ) {
        executePlaceForce(quoteId, nodes);
    }

    public static void placeConfigurePublic(
        Id quoteId,
        List<RevSalesTrxn.RecordWithReferenceRequest> nodes
    ) {
        executePlaceConfigure(quoteId, nodes);
    }

    public static OptionDetailDTO buildOptionDetailPublic(Id quoteId) {
        return buildOptionDetail(quoteId);
    }

    public static List<OptionSummaryDTO> buildOptionSummariesPublic(
        Id opportunityId,
        Id selectedQuoteId
    ) {
        return buildOptionSummaries(opportunityId, selectedQuoteId);
    }

    public static Id parseIdPublic(String raw, String label) {
        return parseId(raw, label);
    }

    public static String optionLetterFromNamePublic(String quoteName) {
        return optionLetterFromName(quoteName);
    }

    public static void zeroOpportunityAmountForOptionIfWinningPublic(Id optionQuoteId) {
        zeroOpportunityAmountForOptionIfWinning(optionQuoteId);
    }

    public static Integer normalizeTermPublic(Integer termMonths) {
        return normalizeTerm(termMonths);
    }

    public static String normalizeBillingPublic(String billingFrequency) {
        return normalizeBilling(billingFrequency);
    }

    public static Date parseStartDatePublic(String startDateIso) {
        return parseStartDate(startDateIso);
    }

    public static Date computeEndDatePublic(Date startDate, Integer termMonths) {
        return computeEndDate(startDate, termMonths);
    }

    public static Boolean isEvergreenPublic(Integer termMonths) {
        return isEvergreen(termMonths);
    }

    public static Id resolveBillingTreatmentIdPublic(String currencyIsoCode) {
        return resolveBillingTreatmentId(currencyIsoCode);
    }

    public static PricebookEntry resolvePbePublic(
        String sku,
        String ccy,
        Integer termMonths
    ) {
        return resolvePbe(sku, ccy, termMonths);
    }

    public static Set<Id> existingLineIdsPublic(Id quoteId) {
        return existingLineIds(quoteId);
    }

    public static String workforcePkgSku() {
        return WORKFORCE_PKG_SKU;
    }

    public static String workforceDefaultPlan() {
        return WORKFORCE_DEFAULT_PLAN;
    }

    public static Boolean isWorkforcePlanSku(String plan) {
        return String.isNotBlank(plan) && WORKFORCE_PLAN_SKUS.contains(plan);
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
            return normalizeBilling(lines[0].BillingFrequency);
        }
        return 'Monthly';
    }

    private static void executePlaceForce(
        Id quoteId,
        List<RevSalesTrxn.RecordWithReferenceRequest> nodes
    ) {
        runPlaceWithOpportunitySyncSuspended(
            quoteId,
            nodes,
            RevSalesTrxn.PricingPreferenceEnum.FORCE,
            RevSalesTrxn.ConfigurationExecutionEnum.SKIP,
            new RevSalesTrxn.ConfigurationOptionsInput()
        );
    }

    /** Place with configurator expand (Workforce Path A default components). */
    private static void executePlaceConfigure(
        Id quoteId,
        List<RevSalesTrxn.RecordWithReferenceRequest> nodes
    ) {
        RevSalesTrxn.ConfigurationOptionsInput opts =
            new RevSalesTrxn.ConfigurationOptionsInput();
        opts.addDefaultConfiguration = true;
        opts.executeConfigurationRules = true;
        opts.validateProductCatalog = true;
        opts.validateAmendRenewCancel = true;
        runPlaceWithOpportunitySyncSuspended(
            quoteId,
            nodes,
            RevSalesTrxn.PricingPreferenceEnum.FORCE,
            RevSalesTrxn.ConfigurationExecutionEnum.SYSTEM,
            opts
        );
    }

    private static void runPlaceWithOpportunitySyncSuspended(
        Id quoteId,
        List<RevSalesTrxn.RecordWithReferenceRequest> nodes,
        RevSalesTrxn.PricingPreferenceEnum pricingPref,
        RevSalesTrxn.ConfigurationExecutionEnum configExec,
        RevSalesTrxn.ConfigurationOptionsInput configOpts
    ) {
        assertOptionEditable(quoteId);
        invalidateOptionApprovalIfNeeded(quoteId);
        if (TXN_JOB_IN_PROGRESS) {
            executePlace(nodes, pricingPref, configExec, configOpts);
            ensureQuotePricedWhileSyncSuspended(quoteId);
            return;
        }
        Id oppId = opportunityIdForQuote(quoteId);
        Id syncedQuoteId = syncedQuoteIdForOpportunity(oppId);
        if (syncedQuoteId != null) {
            setOpportunitySyncedQuote(oppId, null);
        }
        try {
            executePlace(nodes, pricingPref, configExec, configOpts);
            ensureQuotePricedWhileSyncSuspended(quoteId);
        } finally {
            if (syncedQuoteId != null) {
                enqueueRestoreSyncedQuote(oppId, syncedQuoteId);
            }
        }
    }

    /**
     * After Place FORCE: if the quote still looks unpriced / invalid, run one
     * quantity-assert reprice while SyncedQuoteId is still cleared (reduces
     * platform automatic-reprice jobs that lock the Opportunity).
     */
    private static void ensureQuotePricedWhileSyncSuspended(Id quoteId) {
        if (!quoteNeedsForceReprice(quoteId)) {
            return;
        }
        List<QuoteLineItem> lines = [
            SELECT Id, Quantity
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            WITH USER_MODE
        ];
        if (lines.isEmpty()) {
            return;
        }
        List<RevSalesTrxn.RecordWithReferenceRequest> nodes =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        nodes.add(
            new RevSalesTrxn.RecordWithReferenceRequest(
                'refQuote',
                new RevSalesTrxn.RecordResource(Quote.getSObjectType(), 'PATCH', quoteId)
            )
        );
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
                new RevSalesTrxn.RecordWithReferenceRequest('refVerify' + i++, lineNode)
            );
        }
        // Direct Place — do not nest executePlaceForce (would suspend/restore again).
        executePlace(
            nodes,
            RevSalesTrxn.PricingPreferenceEnum.FORCE,
            RevSalesTrxn.ConfigurationExecutionEnum.SKIP,
            new RevSalesTrxn.ConfigurationOptionsInput()
        );
    }

    @TestVisible
    public static Boolean quoteNeedsForceReprice(Id quoteId) {
        if (quoteId == null) {
            return false;
        }
        List<Quote> headers = [
            SELECT Id, CalculationStatus, ValidationResult
            FROM Quote
            WHERE Id = :quoteId
            WITH USER_MODE
            LIMIT 1
        ];
        if (headers.isEmpty()) {
            return false;
        }
        Quote header = headers[0];
        if (String.isNotBlank(header.ValidationResult)) {
            return true;
        }
        String status = header.CalculationStatus;
        if (String.isNotBlank(status)) {
            String s = status.toLowerCase();
            if (
                s.contains('fail') ||
                s.contains('inprogress') ||
                s.contains('incomplete') ||
                s.contains('error')
            ) {
                return true;
            }
        }
        List<QuoteLineItem> lines = [
            SELECT Id, NetUnitPrice, ParentQuoteLineItemId
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            WITH USER_MODE
        ];
        if (lines.isEmpty()) {
            return false;
        }
        Set<Id> bundleParentIds = new Set<Id>();
        for (QuoteLineItem row : lines) {
            if (row.ParentQuoteLineItemId != null) {
                bundleParentIds.add(row.ParentQuoteLineItemId);
            }
        }
        Boolean anyBillable = false;
        Boolean anyPriced = false;
        for (QuoteLineItem qi : lines) {
            if (bundleParentIds.contains(qi.Id)) {
                continue;
            }
            anyBillable = true;
            if (qi.NetUnitPrice != null) {
                anyPriced = true;
            }
        }
        return anyBillable && !anyPriced;
    }

    private static Id opportunityIdForQuote(Id quoteId) {
        List<Quote> rows = [
            SELECT OpportunityId
            FROM Quote
            WHERE Id = :quoteId
            WITH USER_MODE
            LIMIT 1
        ];
        if (rows.isEmpty() || rows[0].OpportunityId == null) {
            throw new SuiteException('Quote is not linked to an Opportunity.');
        }
        return rows[0].OpportunityId;
    }

    private static Id syncedQuoteIdForOpportunity(Id opportunityId) {
        List<Opportunity> rows = [
            SELECT SyncedQuoteId
            FROM Opportunity
            WHERE Id = :opportunityId
            WITH USER_MODE
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0].SyncedQuoteId;
    }

    @TestVisible
    public static void enqueueRestoreSyncedQuote(Id opportunityId, Id quoteId) {
        if (opportunityId == null || quoteId == null) {
            return;
        }
        System.enqueueJob(
            new RLM_BambooSuiteRestoreOppSync(opportunityId, quoteId, 0)
        );
    }

    /**
     * Restore SyncedQuoteId with lock retries. Used by Queueable and tests.
     */
    public static void restoreOpportunitySyncedQuote(Id opportunityId, Id quoteId) {
        setOpportunitySyncedQuote(opportunityId, quoteId);
    }

    private static void setOpportunitySyncedQuote(Id opportunityId, Id quoteId) {
        SuiteException last = null;
        for (Integer attempt = 0; attempt < LOCK_RETRY_ATTEMPTS; attempt++) {
            Database.SaveResult sr = Database.update(
                new Opportunity(Id = opportunityId, SyncedQuoteId = quoteId),
                false,
                AccessLevel.USER_MODE
            );
            if (sr.isSuccess()) {
                return;
            }
            String msg = firstError(sr);
            if (!isLockError(msg)) {
                throw new SuiteException(msg);
            }
            last = new SuiteException(msg);
        }
        throw wrapLockException(last);
    }

    /**
     * When deleting the synced/staged option, clear SyncedQuoteId (if pointing at
     * that quote) and force Opportunity.Amount to 0 so forecasting does not keep
     * the prior quote total.
     */
    private static void clearOpportunityForecastForOption(
        Id opportunityId,
        Id optionQuoteId
    ) {
        if (opportunityId == null || optionQuoteId == null) {
            return;
        }
        List<Opportunity> rows = [
            SELECT
                Id,
                Amount,
                SyncedQuoteId,
                RLM_Bamboo_Staged_Sync_Quote_Id__c,
                RLM_Bamboo_Sync_Mode__c
            FROM Opportunity
            WHERE Id = :opportunityId
            WITH USER_MODE
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            return;
        }
        Opportunity opp = rows[0];
        Boolean wasSynced = opp.SyncedQuoteId == optionQuoteId;
        Boolean wasStaged = opp.RLM_Bamboo_Staged_Sync_Quote_Id__c == optionQuoteId;
        if (!wasSynced && !wasStaged) {
            return;
        }
        if (wasSynced) {
            try {
                setOpportunitySyncedQuote(opportunityId, null);
            } catch (SuiteException e) {
                throw wrapLockException(e);
            }
        }
        // SyncedQuoteId clear does not always remove Opp products / Amount rollup.
        List<OpportunityLineItem> olis = [
            SELECT Id
            FROM OpportunityLineItem
            WHERE OpportunityId = :opportunityId
            WITH USER_MODE
        ];
        if (!olis.isEmpty()) {
            Database.DeleteResult[] oliDrs = Database.delete(
                olis,
                false,
                AccessLevel.USER_MODE
            );
            for (Database.DeleteResult dr : oliDrs) {
                if (!dr.isSuccess()) {
                    throw new SuiteException(firstError(dr));
                }
            }
        }
        Opportunity patch = new Opportunity(Id = opportunityId, Amount = 0);
        if (wasStaged) {
            patch.RLM_Bamboo_Staged_Sync_Quote_Id__c = null;
        }
        patch.RLM_Bamboo_Sync_Mode__c = 'Editing';
        Database.SaveResult sr = Database.update(patch, false, AccessLevel.USER_MODE);
        if (!sr.isSuccess()) {
            throw new SuiteException(firstError(sr));
        }
    }

    /**
     * After all lines are removed from an option that is (or was) the Opp winner,
     * zero Opportunity.Amount and clear sync so the Opp does not keep the old total.
     */
    private static void zeroOpportunityAmountForOptionIfWinning(Id optionQuoteId) {
        if (optionQuoteId == null) {
            return;
        }
        List<Quote> quotes = [
            SELECT Id, OpportunityId
            FROM Quote
            WHERE Id = :optionQuoteId
            WITH USER_MODE
            LIMIT 1
        ];
        if (quotes.isEmpty() || quotes[0].OpportunityId == null) {
            return;
        }
        clearOpportunityForecastForOption(quotes[0].OpportunityId, optionQuoteId);
    }

    private static void executePlace(
        List<RevSalesTrxn.RecordWithReferenceRequest> nodes,
        RevSalesTrxn.PricingPreferenceEnum pricingPref,
        RevSalesTrxn.ConfigurationExecutionEnum configExec,
        RevSalesTrxn.ConfigurationOptionsInput configOpts
    ) {
        SuiteException last = null;
        for (Integer attempt = 0; attempt < LOCK_RETRY_ATTEMPTS; attempt++) {
            RevSalesTrxn.GraphRequest graph = new RevSalesTrxn.GraphRequest(
                'BambooRevenueSuite',
                nodes
            );
            RevSalesTrxn.PlaceSalesTransactionResponse resp = RevSalesTrxn.PlaceSalesTransactionExecutor.execute(
                graph,
                pricingPref,
                configExec,
                configOpts == null
                    ? new RevSalesTrxn.ConfigurationOptionsInput()
                    : configOpts,
                null
            );
            if (resp != null && resp.isSuccess) {
                return;
            }
            String msg = pstError(resp);
            if (!isLockError(msg)) {
                throw new SuiteException(msg);
            }
            last = new SuiteException(msg);
        }
        throw wrapLockException(last);
    }

    @TestVisible
    public static Boolean isLockError(String message) {
        if (String.isBlank(message)) {
            return false;
        }
        String m = message.toUpperCase();
        return m.contains('UNABLE_TO_LOCK_ROW') || m.contains('UNABLE TO LOCK ROW');
    }

    @TestVisible
    public static String lockRecoveryMessage() {
        return 'Opportunity is busy (row lock). Wait a moment and retry, or open this ' +
            'option Quote and click Reprice All, then Refresh options in the suite.';
    }

    private static SuiteException wrapLockException(SuiteException e) {
        if (e == null) {
            return new SuiteException(lockRecoveryMessage());
        }
        String msg = e.getMessage();
        if (String.isNotBlank(msg) && msg.startsWith('Opportunity is busy')) {
            return e;
        }
        if (isLockError(msg)) {
            return new SuiteException(lockRecoveryMessage() + ' (' + msg + ')');
        }
        return e;
    }

    private static String pstError(RevSalesTrxn.PlaceSalesTransactionResponse resp) {
        if (resp == null) {
            return 'Place Sales Transaction returned no response.';
        }
        if (resp.errorResponse == null || resp.errorResponse.isEmpty()) {
            return 'Place Sales Transaction failed.';
        }
        List<String> parts = new List<String>();
        for (Object err : resp.errorResponse) {
            parts.add(String.valueOf(err));
        }
        return String.join(parts, '; ');
    }

    private static Set<Id> existingLineIds(Id quoteId) {
        Set<Id> ids = new Set<Id>();
        for (QuoteLineItem qi : [
            SELECT Id
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            WITH USER_MODE
        ]) {
            ids.add(qi.Id);
        }
        return ids;
    }

    private static Id newestLineId(Id quoteId, Set<Id> beforeIds) {
        for (QuoteLineItem qi : [
            SELECT Id
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 20
        ]) {
            if (beforeIds == null || !beforeIds.contains(qi.Id)) {
                return qi.Id;
            }
        }
        throw new SuiteException('Line was priced but could not be resolved on the quote.');
    }

    private static OptionDetailDTO buildOptionDetail(Id quoteId) {
        Quote header = requireQuote(
            quoteId,
            new Set<String>{
                'Id',
                'Name',
                'GrandTotal',
                'TotalPrice',
                'RLM_Approval_Status__c',
                'RLM_Approval_Level__c'
            }
        );
        Integer months = inferTermMonths(quoteId);
        List<QuoteLineItem> qlis = [
            SELECT
                Id,
                ParentQuoteLineItemId,
                Quantity,
                UnitPrice,
                ListPrice,
                NetUnitPrice,
                NetTotalPrice,
                TotalPrice,
                Discount,
                PartnerDiscountPercent,
                RLM_Approval_Level_Calc__c,
                StartDate,
                EndDate,
                BillingFrequency,
                Product2.Name,
                Product2.StockKeepingUnit
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ];

        Set<Id> bundleParentIds = new Set<Id>();
        for (QuoteLineItem row : qlis) {
            if (row.ParentQuoteLineItemId != null) {
                bundleParentIds.add(row.ParentQuoteLineItemId);
            }
        }

        OptionDetailDTO dto = new OptionDetailDTO();
        dto.quoteId = quoteId;
        dto.optionLabel = optionLabelFromName(header.Name);
        dto.termMonths = months;
        dto.evergreen = isEvergreen(months);
        dto.billingFrequency = billingFrequencyForOption(quoteId);
        dto.lines = new List<OptionLineDTO>();
        dto.priced = false;
        if (!qlis.isEmpty() && qlis[0].StartDate != null) {
            dto.startDate = String.valueOf(qlis[0].StartDate);
            dto.endDate = qlis[0].EndDate == null
                ? null
                : String.valueOf(qlis[0].EndDate);
        }
        Decimal mrr = 0;
        for (QuoteLineItem qi : qlis) {
            OptionLineDTO line = new OptionLineDTO();
            line.lineId = qi.Id;
            line.parentLineId = qi.ParentQuoteLineItemId;
            line.isBundleChild = qi.ParentQuoteLineItemId != null;
            line.isBundleRoot = bundleParentIds.contains(qi.Id);
            line.sku = qi.Product2 != null ? qi.Product2.StockKeepingUnit : null;
            line.name = qi.Product2 != null ? qi.Product2.Name : null;
            line.quantity = qi.Quantity;
            Decimal listUnit = qi.ListPrice != null ? qi.ListPrice : qi.UnitPrice;
            line.listUnitPrice = listUnit;
            Decimal qty = qi.Quantity == null ? 0 : qi.Quantity;
            line.listTotal = listUnit == null ? 0 : listUnit * qty;
            Boolean hasNet = qi.NetUnitPrice != null;
            line.priced = hasNet;
            if (hasNet) {
                dto.priced = true;
            }
            // Prefer RC-priced net unit (monthly PEPM/flat after FORCE).
            Decimal pricedUnit = hasNet ? qi.NetUnitPrice : qi.UnitPrice;
            line.unitPrice = pricedUnit;
            Decimal net = qi.NetTotalPrice != null
                ? qi.NetTotalPrice
                : (qi.TotalPrice != null
                      ? qi.TotalPrice
                      : (pricedUnit == null || qi.Quantity == null
                            ? 0
                            : pricedUnit * qi.Quantity));
            line.netTotal = net;
            // Discount drives Default ManualDiscount (ItemDiscountPercentage).
            if (qi.Discount != null) {
                line.discountPercent = qi.Discount;
            } else if (qi.PartnerDiscountPercent != null) {
                line.discountPercent = qi.PartnerDiscountPercent;
            } else {
                line.discountPercent = 0;
            }
            line.approvalLevel = qi.RLM_Approval_Level_Calc__c == null
                ? 0
                : qi.RLM_Approval_Level_Calc__c;
            line.approvalRequiredLabel = approvalRequiredLabelFor(line.approvalLevel);
            if (qi.StartDate != null) {
                line.startDate = String.valueOf(qi.StartDate);
            }
            if (qi.EndDate != null) {
                line.endDate = String.valueOf(qi.EndDate);
                if (qi.StartDate != null) {
                    line.dayCount = qi.StartDate.daysBetween(qi.EndDate) + 1;
                }
            }
            // Bundle roots with children are $0 containers — MRR lives on components.
            if (!line.isBundleRoot) {
                Decimal lineMrr = (pricedUnit == null || qi.Quantity == null)
                    ? 0
                    : pricedUnit * qi.Quantity;
                mrr += lineMrr;
            }
            dto.lines.add(line);
        }
        dto.mrr = mrr;
        dto.arr = mrr * 12;
        dto.grandTotal = header.GrandTotal != null
            ? header.GrandTotal
            : (header.TotalPrice != null ? header.TotalPrice : 0);
        dto.approvalStatus = normalizeApprovalStatus(header.RLM_Approval_Status__c);
        dto.approvalLevel = header.RLM_Approval_Level__c == null
            ? 0
            : header.RLM_Approval_Level__c;
        dto.approvalRequiredLabel = approvalRequiredLabelFor(dto.approvalLevel);
        if (dto.approvalStatus == 'Rejected' || dto.approvalStatus == 'Recalled') {
            dto.lastDecisionComments = latestDecisionCommentsForGuidance(quoteId);
        }
        return dto;
    }

    private static List<OptionSummaryDTO> buildOptionSummaries(
        Id opportunityId,
        Id selectedQuoteId
    ) {
        Id syncedQuoteId = null;
        List<Opportunity> opps = [
            SELECT SyncedQuoteId
            FROM Opportunity
            WHERE Id = :opportunityId
            WITH USER_MODE
            LIMIT 1
        ];
        if (!opps.isEmpty()) {
            syncedQuoteId = opps[0].SyncedQuoteId;
        }

        List<Quote> quotes = [
            SELECT Id, Name, QuoteNumber, Status
            FROM Quote
            WHERE
                OpportunityId = :opportunityId
                AND Name LIKE '%Option %'
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ];
        Map<String, OptionSummaryDTO> byLetter = new Map<String, OptionSummaryDTO>();
        for (Quote q : quotes) {
            String letter = optionLetterFromName(q.Name);
            if (letter == null) {
                continue;
            }
            OptionDetailDTO detail = buildOptionDetail(q.Id);
            Boolean selected = selectedQuoteId != null && q.Id == selectedQuoteId;
            Boolean synced = syncedQuoteId != null && q.Id == syncedQuoteId;
            byLetter.put(letter, toSummary(q, detail, selected, synced));
        }
        List<OptionSummaryDTO> out = new List<OptionSummaryDTO>();
        for (Integer i = 0; i < MAX_OPTIONS; i++) {
            String letter = String.fromCharArray(new List<Integer>{ 65 + i });
            if (byLetter.containsKey(letter)) {
                out.add(byLetter.get(letter));
            }
        }
        return out;
    }

    private static OptionSummaryDTO toSummary(
        Quote q,
        OptionDetailDTO detail,
        Boolean selected,
        Boolean syncedToOpportunity
    ) {
        OptionSummaryDTO s = new OptionSummaryDTO();
        s.quoteId = q.Id;
        s.quoteName = q.Name;
        s.quoteNumber = q.QuoteNumber;
        s.optionLabel = detail != null
            ? detail.optionLabel
            : optionLabelFromName(q.Name);
        s.status = q.Status;
        s.lineCount = detail != null && detail.lines != null
            ? detail.lines.size()
            : 0;
        s.mrr = detail != null ? detail.mrr : 0;
        s.arr = detail != null ? detail.arr : 0;
        s.grandTotal = detail != null ? detail.grandTotal : 0;
        s.priced = detail != null ? detail.priced : false;
        s.selected = selected == true;
        s.syncedToOpportunity = syncedToOpportunity == true;
        s.approvalStatus = detail != null
            ? detail.approvalStatus
            : normalizeApprovalStatus(null);
        s.approvalLevel = detail != null && detail.approvalLevel != null
            ? detail.approvalLevel
            : 0;
        s.approvalRequiredLabel = detail != null
            ? detail.approvalRequiredLabel
            : approvalRequiredLabelFor(0);
        return s;
    }

    private static String nextOptionLetter(List<OptionSummaryDTO> existing) {
        Set<String> used = new Set<String>();
        if (existing != null) {
            for (OptionSummaryDTO s : existing) {
                String letter = optionLetter(s.optionLabel);
                if (letter != null) {
                    used.add(letter);
                }
            }
        }
        for (Integer i = 0; i < MAX_OPTIONS; i++) {
            String letter = String.fromCharArray(new List<Integer>{ 65 + i });
            if (!used.contains(letter)) {
                return letter;
            }
        }
        throw new SuiteException('No option letters remaining.');
    }

    private static String optionLabelFromName(String quoteName) {
        String letter = optionLetterFromName(quoteName);
        return letter == null ? 'Option A' : 'Option ' + letter;
    }

    private static String optionLetter(String optionLabel) {
        if (String.isBlank(optionLabel) || !optionLabel.startsWith('Option ')) {
            return null;
        }
        String rest = optionLabel.substring(7).trim();
        return String.isBlank(rest) ? null : rest.substring(0, 1).toUpperCase();
    }

    /**
     * Groups the user can act for on ApprovalWorkItem assignees.
     * Includes direct membership, role / role-and-subordinates auto-groups,
     * and nested public groups (Manager → CEO Role on this org).
     * SYSTEM_MODE: Group/GroupMember CRUD is not grantable on the BambooHR
     * user license; this is eligibility only, not exposed record data.
     */
    private static Set<Id> groupIdsForUser(Id userId) {
        Set<Id> memberKeys = new Set<Id>{ userId };
        List<User> users = [
            SELECT UserRoleId
            FROM User
            WHERE Id = :userId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (!users.isEmpty() && users[0].UserRoleId != null) {
            Id roleId = users[0].UserRoleId;
            memberKeys.add(roleId);
            for (Group roleGroup : [
                SELECT Id
                FROM Group
                WHERE RelatedId = :roleId
                WITH SYSTEM_MODE
            ]) {
                memberKeys.add(roleGroup.Id);
            }
        }

        Set<Id> groupIds = new Set<Id>();
        Boolean grew = true;
        Integer guard = 0;
        while (grew && guard < 10) {
            grew = false;
            guard++;
            for (GroupMember gm : [
                SELECT GroupId
                FROM GroupMember
                WHERE UserOrGroupId IN :memberKeys
                WITH SYSTEM_MODE
            ]) {
                if (groupIds.add(gm.GroupId)) {
                    memberKeys.add(gm.GroupId);
                    grew = true;
                }
            }
        }
        return groupIds;
    }

    @TestVisible
    private static String normalizeReviewDecision(String raw) {
        if (String.isBlank(raw)) {
            throw new SuiteException('Approval decision is required.');
        }
        String d = raw.trim().toLowerCase();
        if (d == 'approve' || d == 'approved') {
            // Platform invocable expects title case (REST sample: "Approve").
            return 'Approve';
        }
        if (d == 'reject' || d == 'rejected') {
            return 'Reject';
        }
        throw new SuiteException('Decision must be Approve or Reject.');
    }

    private static void invokeReviewApprovalWorkItem(
        Id workItemId,
        String decision,
        String comments
    ) {
        Invocable.Action action = Invocable.Action.createStandardAction(
            'reviewApprovalWorkItem'
        );
        action.setInvocationParameter(
            'approvalWorkItemId',
            String.valueOf(workItemId)
        );
        action.setInvocationParameter('approvalDecision', decision);
        action.setInvocationParameter(
            'comments',
            String.isBlank(comments)
                ? 'Reviewed from BambooHR Revenue Suite'
                : comments.trim()
        );
        action.setInvocationParameter('channelType', 'InvocableAction');
        List<Invocable.Action.Result> results = action.invoke();
        if (results == null || results.isEmpty()) {
            throw new SuiteException(
                'Review approval work item returned no result.'
            );
        }
        Invocable.Action.Result res = results[0];
        if (!res.isSuccess()) {
            List<String> msgs = new List<String>();
            if (res.getErrors() != null) {
                for (Invocable.Action.Error err : res.getErrors()) {
                    msgs.add(err.getMessage());
                }
            }
            throw new SuiteException(
                'Could not review approval work item: ' +
                (msgs.isEmpty() ? 'Unknown error' : String.join(msgs, '; '))
            );
        }
    }

    private static String optionLetterFromName(String quoteName) {
        if (String.isBlank(quoteName)) {
            return null;
        }
        Integer idx = quoteName.indexOf('Option ');
        if (idx < 0) {
            return null;
        }
        String rest = quoteName.substring(idx + 7).trim();
        if (String.isBlank(rest)) {
            return null;
        }
        String ch = rest.substring(0, 1).toUpperCase();
        if (ch < 'A' || ch > 'Z') {
            return null;
        }
        return ch;
    }

    /** Map Good/Better/Best or Option A/B/C to option letter A/B/C. */
    private static String suiteOptionLetterFromLabel(String optionLabel) {
        if (String.isBlank(optionLabel)) {
            return null;
        }
        String key = optionLabel.trim().toLowerCase();
        if (key == 'good' || key == 'a' || key == 'option a') {
            return 'A';
        }
        if (key == 'better' || key == 'b' || key == 'option b') {
            return 'B';
        }
        if (key == 'best' || key == 'c' || key == 'option c') {
            return 'C';
        }
        return optionLetter(optionLabel);
    }

    /**
     * TermDefined/Evergreen lines require BillingFrequency AND a BillingTreatment
     * with CanChangeBillingFrequency=true. Prefer Advance treatments for the
     * quote currency (Bamboo products use Billing Policy - Advance).
     */
    private static Id resolveBillingTreatmentId(String currencyIsoCode) {
        String ccy = String.isBlank(currencyIsoCode) ? 'USD' : currencyIsoCode.trim();
        List<BillingTreatment> rows = [
            SELECT Id, Name, CanChangeBillingFrequency
            FROM BillingTreatment
            WHERE Status = 'Active' AND CurrencyIsoCode = :ccy
            WITH SYSTEM_MODE
            ORDER BY Name
        ];
        if (rows.isEmpty()) {
            throw new SuiteException(
                'No active Billing Treatment for ' +
                    ccy +
                    '. Load qb-billing (or enable CanChangeBillingFrequency).'
            );
        }
        BillingTreatment preferred = null;
        for (BillingTreatment t : rows) {
            if (
                t.CanChangeBillingFrequency == true &&
                t.Name != null &&
                t.Name.containsIgnoreCase('Advance')
            ) {
                return t.Id;
            }
            if (preferred == null && t.CanChangeBillingFrequency == true) {
                preferred = t;
            }
        }
        if (preferred != null) {
            return preferred.Id;
        }
        throw new SuiteException(
            'Billing Treatment for ' +
                ccy +
                ' exists but CanChangeBillingFrequency is false. ' +
                'Update the treatment (qb-billing sets this to true) so Monthly / ' +
                'Quarterly / Annual can be selected on quote lines.'
        );
    }

    private static PricebookEntry resolvePbe(String sku, String ccy, Integer termMonths) {
        String smt = isEvergreen(termMonths) ? 'Evergreen' : 'TermDefined';
        List<PricebookEntry> rows = [
            SELECT
                Id,
                UnitPrice,
                ProductSellingModelId,
                Product2Id,
                Product2.StockKeepingUnit
            FROM PricebookEntry
            WHERE
                Pricebook2.IsStandard = TRUE
                AND IsActive = TRUE
                AND Product2.IsActive = TRUE
                AND Product2.StockKeepingUnit = :sku
                AND CurrencyIsoCode = :ccy
                AND ProductSellingModel.PricingTermUnit = 'Months'
                AND ProductSellingModel.SellingModelType = :smt
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (rows.isEmpty() && smt == 'Evergreen') {
            // Fall back to Term Monthly twin if Evergreen PBE missing on org.
            rows = [
                SELECT
                    Id,
                    UnitPrice,
                    ProductSellingModelId,
                    Product2Id,
                    Product2.StockKeepingUnit
                FROM PricebookEntry
                WHERE
                    Pricebook2.IsStandard = TRUE
                    AND IsActive = TRUE
                    AND Product2.IsActive = TRUE
                    AND Product2.StockKeepingUnit = :sku
                    AND CurrencyIsoCode = :ccy
                    AND ProductSellingModel.PricingTermUnit = 'Months'
                    AND ProductSellingModel.SellingModelType = 'TermDefined'
                WITH SYSTEM_MODE
                LIMIT 1
            ];
        }
        if (rows.isEmpty()) {
            throw new SuiteException(
                'No active Standard Price Book entry for ' +
                    sku +
                    ' (' +
                    smt +
                    ', ' +
                    ccy +
                    ').'
            );
        }
        return rows[0];
    }

    private static Integer inferTermMonths(Id quoteId) {
        List<QuoteLineItem> dated = [
            SELECT StartDate, EndDate
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId AND EndDate != NULL
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (dated.isEmpty()) {
            List<QuoteLineItem> anyLine = [
                SELECT Id
                FROM QuoteLineItem
                WHERE QuoteId = :quoteId
                WITH USER_MODE
                LIMIT 1
            ];
            // Lines with blank EndDate → evergreen M2M; no lines → default 12.
            return anyLine.isEmpty() ? 12 : 1;
        }
        QuoteLineItem qi = dated[0];
        if (qi.StartDate == null || qi.EndDate == null) {
            return 12;
        }
        Integer months =
            qi.StartDate.monthsBetween(qi.EndDate.addDays(1));
        if (!ALLOWED_TERMS.contains(months)) {
            return 12;
        }
        return months;
    }

    private static Integer normalizeTerm(Integer termMonths) {
        Integer months = termMonths == null ? 12 : termMonths;
        if (!ALLOWED_TERMS.contains(months)) {
            throw new SuiteException('termMonths must be 1, 12, 24, or 36.');
        }
        return months;
    }

    private static Boolean isEvergreen(Integer termMonths) {
        return termMonths != null && termMonths == 1;
    }

    /** Inclusive term end: start + N months − 1 day (matches Neocol ribbon). */
    private static Date computeEndDate(Date startDate, Integer termMonths) {
        if (startDate == null || isEvergreen(termMonths)) {
            return null;
        }
        return startDate.addMonths(termMonths).addDays(-1);
    }

    private static Date parseStartDate(String startDateIso) {
        if (String.isBlank(startDateIso)) {
            return Date.today();
        }
        try {
            return Date.valueOf(startDateIso.trim());
        } catch (Exception e) {
            throw new SuiteException('Invalid term start date. Use YYYY-MM-DD.');
        }
    }

    private static String normalizeBilling(String billingFrequency) {
        if (String.isBlank(billingFrequency)) {
            return 'Monthly';
        }
        String v = billingFrequency.trim();
        if (v.equalsIgnoreCase('Quarterly')) {
            return 'Quarterly';
        }
        if (v.equalsIgnoreCase('Annual') || v.equalsIgnoreCase('Annually')) {
            return 'Annual';
        }
        return 'Monthly';
    }

    private static String badgeForSku(String sku, String productType) {
        if (String.isNotBlank(productType) && productType.equalsIgnoreCase('Bundle')) {
            return 'BUNDLE';
        }
        if (sku == null) {
            return 'FLAT';
        }
        if (sku.startsWith('BAMBOO-PKG-')) {
            return 'BUNDLE';
        }
        if (sku.contains('-FLAT-')) {
            return 'FLAT';
        }
        if (
            sku == 'BAMBOO-CORE' ||
            sku == 'BAMBOO-PRO' ||
            sku == 'BAMBOO-ELITE'
        ) {
            return 'TIERED';
        }
        return 'FLAT';
    }

    /**
     * Re-open path after TLE edits: prefer staged/sync winner, then the most
     * recently touched suite option — not always a fresh empty Option A.
     */
    private static Quote resolveSuiteEntryQuote(Opportunity opp) {
        Id preferredId = opp.RLM_Bamboo_Staged_Sync_Quote_Id__c != null
            ? opp.RLM_Bamboo_Staged_Sync_Quote_Id__c
            : opp.SyncedQuoteId;
        if (preferredId != null) {
            List<Quote> preferred = [
                SELECT Id, Name, QuoteNumber, CurrencyIsoCode, Status
                FROM Quote
                WHERE Id = :preferredId AND OpportunityId = :opp.Id
                WITH USER_MODE
                LIMIT 1
            ];
            if (!preferred.isEmpty() && optionLetterFromName(preferred[0].Name) != null) {
                return preferred[0];
            }
        }
        List<Quote> recent = [
            SELECT Id, Name, QuoteNumber, CurrencyIsoCode, Status
            FROM Quote
            WHERE OpportunityId = :opp.Id AND Name LIKE '%Option %'
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        if (!recent.isEmpty()) {
            return recent[0];
        }
        Quote draft = findOptionADraft(opp.Id);
        if (draft != null) {
            return draft;
        }
        return createOptionAQuote(opp);
    }

    private static Quote findOptionADraft(Id opportunityId) {
        List<Quote> rows = [
            SELECT Id, Name, QuoteNumber, CurrencyIsoCode, Status
            FROM Quote
            WHERE
                OpportunityId = :opportunityId
                AND Status = 'Draft'
                AND Name LIKE '%Option A%'
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    private static Quote createOptionAQuote(Opportunity opp) {
        return createOptionQuote(opp, 'A');
    }

    private static Quote createOptionQuote(Opportunity opp, String letter) {
        Id pricebookId = opp.Pricebook2Id;
        if (pricebookId == null) {
            pricebookId = Test.isRunningTest()
                ? Test.getStandardPricebookId()
                : resolveStandardPricebookId();
        }
        String name = truncateName(opp.Name + OPTION_NAME_MARKER + letter);
        Quote q = new Quote(
            Name = name,
            OpportunityId = opp.Id,
            Pricebook2Id = pricebookId,
            Status = 'Draft'
        );
        // The platform auto-copies the legacy Quote.AccountId from the
        // Opportunity on insert, but NOT the newer QuoteAccountId — and the
        // Account "Quotes" related list is keyed on QuoteAccountId, not
        // AccountId (whose child relationship on Account is null). Stamp it so
        // suite option quotes surface on the account, not just the opportunity.
        if (opp.AccountId != null) {
            q.QuoteAccountId = opp.AccountId;
        }
        if (String.isNotBlank(opp.CurrencyIsoCode)) {
            q.CurrencyIsoCode = opp.CurrencyIsoCode;
        }
        Database.SaveResult sr = Database.insert(q, false, AccessLevel.USER_MODE);
        if (!sr.isSuccess()) {
            throw new SuiteException(firstError(sr));
        }
        return [
            SELECT Id, Name, QuoteNumber, CurrencyIsoCode, Status
            FROM Quote
            WHERE Id = :sr.getId()
            WITH USER_MODE
            LIMIT 1
        ];
    }

    private static SessionDTO toSession(Opportunity opp, Quote q) {
        SessionDTO dto = new SessionDTO();
        dto.opportunityId = opp.Id;
        dto.opportunityName = opp.Name;
        dto.accountId = opp.AccountId;
        dto.accountName = opp.Account != null ? opp.Account.Name : null;
        dto.closeDate = opp.CloseDate;
        dto.currencyIsoCode = String.isNotBlank(q.CurrencyIsoCode)
            ? q.CurrencyIsoCode
            : opp.CurrencyIsoCode;
        dto.quoteId = q.Id;
        dto.quoteName = q.Name;
        dto.quoteNumber = q.QuoteNumber;
        Integer months = inferTermMonths(q.Id);
        dto.termMonths = months;
        dto.billingFrequency = 'Monthly';
        dto.evergreen = isEvergreen(months);
        dto.optionLabel = optionLabelFromName(q.Name);
        dto.syncedQuoteId = opp.SyncedQuoteId;
        dto.stagedSyncQuoteId = opp.RLM_Bamboo_Staged_Sync_Quote_Id__c;
        dto.syncMode = String.isNotBlank(opp.RLM_Bamboo_Sync_Mode__c)
            ? opp.RLM_Bamboo_Sync_Mode__c
            : (opp.SyncedQuoteId != null ? 'Committed' : 'Editing');
        dto.syncPausedToast = false;
        dto.txnOrchestratorEnabled = isTxnOrchestratorEnabled();
        return dto;
    }

    private static Id resolveStandardPricebookId() {
        List<Pricebook2> pbs = [
            SELECT Id
            FROM Pricebook2
            WHERE IsStandard = TRUE
            WITH USER_MODE
            LIMIT 1
        ];
        if (pbs.isEmpty()) {
            throw new SuiteException('Standard Price Book not found.');
        }
        return pbs[0].Id;
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

    private static Quote requireQuote(Id quoteId, Set<String> extraFields) {
        if (quoteId == null) {
            throw new SuiteException('Quote Id is required.');
        }
        Set<String> fields = new Set<String>{ 'Id' };
        if (extraFields != null) {
            fields.addAll(extraFields);
        }
        String soql =
            'SELECT ' +
            String.join(new List<String>(fields), ', ') +
            ' FROM Quote WHERE Id = :quoteId WITH USER_MODE LIMIT 1';
        List<Quote> rows = Database.query(soql);
        if (rows.isEmpty()) {
            throw new SuiteException(
                'Quote not found or you no longer have access. Re-open BambooHR Revenue Suite from the Opportunity.'
            );
        }
        return rows[0];
    }

    private static Opportunity requireOpportunity(
        Id opportunityId,
        Set<String> extraFields
    ) {
        if (opportunityId == null) {
            throw new SuiteException('Opportunity Id is required.');
        }
        Set<String> fields = new Set<String>{ 'Id' };
        if (extraFields != null) {
            fields.addAll(extraFields);
        }
        String soql =
            'SELECT ' +
            String.join(new List<String>(fields), ', ') +
            ' FROM Opportunity WHERE Id = :opportunityId WITH USER_MODE LIMIT 1';
        List<Opportunity> rows = Database.query(soql);
        if (rows.isEmpty()) {
            throw new SuiteException(
                'Opportunity not found or you no longer have access.'
            );
        }
        return rows[0];
    }

    private static Id parseId(String raw, String label) {
        if (String.isBlank(raw)) {
            throw new SuiteException(label + ' Id is required.');
        }
        try {
            return Id.valueOf(raw.trim());
        } catch (Exception e) {
            throw new SuiteException('Invalid ' + label + ' Id.');
        }
    }

    private static String truncateName(String value) {
        if (value == null) {
            return 'Option A';
        }
        return value.length() > 120 ? value.substring(0, 120) : value;
    }

    private static String firstError(Database.SaveResult sr) {
        if (sr == null || sr.getErrors().isEmpty()) {
            return 'Unable to save record.';
        }
        return sr.getErrors()[0].getMessage();
    }

    private static String firstError(Database.DeleteResult dr) {
        if (dr == null || dr.getErrors().isEmpty()) {
            return 'Unable to delete record.';
        }
        return dr.getErrors()[0].getMessage();
    }
}
