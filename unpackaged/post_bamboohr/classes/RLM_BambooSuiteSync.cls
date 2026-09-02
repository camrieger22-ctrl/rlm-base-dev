/**
 * Suite Edit/Commit sync — Opportunity.SyncedQuoteId + staged winner + sync mode.
 * Single owner of OPP_SESSION_FIELDS so toSession paths never miss SOQL columns.
 * Flow RLM_Bamboo_Suite_Sync and LWC Aura both use this Invocable / applySyncAction.
 */
public with sharing class RLM_BambooSuiteSync {
    public static final String MODE_EDITING = 'Editing';
    public static final String MODE_COMMITTED = 'Committed';

    /** Fields required whenever Opportunity is passed to toSession / sync DTOs. */
    public static final Set<String> OPP_SESSION_FIELDS = new Set<String>{
        'Id',
        'Name',
        'AccountId',
        'Account.Name',
        'CloseDate',
        'Pricebook2Id',
        'CurrencyIsoCode',
        'Amount',
        'SyncedQuoteId',
        'RLM_Bamboo_Staged_Sync_Quote_Id__c',
        'RLM_Bamboo_Sync_Mode__c'
    };

    public class SyncResult {
        @AuraEnabled
        public Id syncedQuoteId;
        @AuraEnabled
        public Id stagedSyncQuoteId;
        @AuraEnabled
        public String syncMode;
        @AuraEnabled
        public String summary;
        @AuraEnabled
        public Boolean pausedToast;
        @AuraEnabled
        public Id opportunityId;
    }

    public class InvocableRequest {
        @InvocableVariable(
            required=true
            label='Action'
            description='Pause, Commit, Clear, or RecommitStaged'
        )
        public String action;
        @InvocableVariable(required=true label='Opportunity Id')
        public String opportunityId;
        @InvocableVariable(label='Quote Id' description='Required for Commit')
        public String quoteId;
    }

    public class InvocableResult {
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
        @InvocableVariable(label='Sync Mode')
        public String syncMode;
        @InvocableVariable(label='Synced Quote Id')
        public String syncedQuoteId;
        @InvocableVariable(label='Staged Sync Quote Id')
        public String stagedSyncQuoteId;
        @InvocableVariable(label='Summary')
        public String summary;
    }

    @InvocableMethod(
        label='BambooHR Suite Sync Action'
        description='Pause, Commit, Clear, or RecommitStaged Opportunity sync for Bamboo Revenue Suite.'
        category='BambooHR'
    )
    public static List<InvocableResult> runInvocable(List<InvocableRequest> requests) {
        List<InvocableResult> out = new List<InvocableResult>();
        if (requests == null) {
            return out;
        }
        for (InvocableRequest req : requests) {
            out.add(runInvocableOne(req));
        }
        return out;
    }

    @TestVisible
    static InvocableResult runInvocableOne(InvocableRequest req) {
        InvocableResult res = new InvocableResult();
        res.isSuccess = false;
        try {
            if (
                req == null ||
                String.isBlank(req.action) ||
                String.isBlank(req.opportunityId)
            ) {
                res.errorMessage = 'action and opportunityId are required.';
                return res;
            }
            String action = req.action.trim().toLowerCase();
            Id oppId = Id.valueOf(req.opportunityId.trim());
            SyncResult syncResult;
            if (action == 'pause') {
                syncResult = pauseForEditing(oppId);
            } else if (action == 'commit') {
                if (String.isBlank(req.quoteId)) {
                    res.errorMessage = 'quoteId is required for Commit.';
                    return res;
                }
                syncResult = commitOption(Id.valueOf(req.quoteId.trim()));
            } else if (action == 'clear') {
                syncResult = clearSync(oppId);
            } else if (action == 'recommitstaged') {
                syncResult = recommitStagedWinner(oppId);
            } else {
                res.errorMessage =
                    'Unknown action: ' +
                    req.action +
                    '. Use Pause, Commit, Clear, or RecommitStaged.';
                return res;
            }
            res.isSuccess = true;
            res.syncMode = syncResult.syncMode;
            res.syncedQuoteId = syncResult.syncedQuoteId == null
                ? null
                : String.valueOf(syncResult.syncedQuoteId);
            res.stagedSyncQuoteId = syncResult.stagedSyncQuoteId == null
                ? null
                : String.valueOf(syncResult.stagedSyncQuoteId);
            res.summary = syncResult.summary;
        } catch (Exception e) {
            res.errorMessage = e.getMessage();
        }
        return res;
    }

    /** Open-suite path: clear SyncedQuoteId, stage prior winner, set Editing. */
    public static SyncResult pauseForEditing(Id opportunityId) {
        Opportunity opp = loadOpp(opportunityId);
        SyncResult result = new SyncResult();
        result.opportunityId = opportunityId;
        result.pausedToast = false;
        if (opp.SyncedQuoteId != null) {
            Id staged = opp.RLM_Bamboo_Staged_Sync_Quote_Id__c != null
                ? opp.RLM_Bamboo_Staged_Sync_Quote_Id__c
                : opp.SyncedQuoteId;
            RLM_BambooRevenueSuite.clearOpportunitySyncedQuotePublic(opp.Id);
            Database.update(
                new Opportunity(
                    Id = opp.Id,
                    RLM_Bamboo_Staged_Sync_Quote_Id__c = staged,
                    RLM_Bamboo_Sync_Mode__c = MODE_EDITING
                ),
                false,
                AccessLevel.USER_MODE
            );
            result.stagedSyncQuoteId = staged;
            result.syncMode = MODE_EDITING;
            result.syncedQuoteId = null;
            result.pausedToast = true;
            result.summary = 'Forecast sync paused for editing.';
        } else {
            if (String.isBlank(opp.RLM_Bamboo_Sync_Mode__c)) {
                Database.update(
                    new Opportunity(
                        Id = opp.Id,
                        RLM_Bamboo_Sync_Mode__c = MODE_EDITING
                    ),
                    false,
                    AccessLevel.USER_MODE
                );
            }
            result.stagedSyncQuoteId = opp.RLM_Bamboo_Staged_Sync_Quote_Id__c;
            result.syncMode = String.isNotBlank(opp.RLM_Bamboo_Sync_Mode__c)
                ? opp.RLM_Bamboo_Sync_Mode__c
                : MODE_EDITING;
            result.syncedQuoteId = null;
            result.summary = 'Already in Editing mode.';
        }
        return result;
    }

    /** Use for Opportunity — Commit mode. */
    public static SyncResult commitOption(Id quoteId) {
        if (quoteId == null) {
            throw new RLM_BambooRevenueSuite.SuiteException('Quote Id is required.');
        }
        Quote q = [
            SELECT Id, Name, OpportunityId, GrandTotal, TotalPrice
            FROM Quote
            WHERE Id = :quoteId
            WITH USER_MODE
            LIMIT 1
        ];
        if (q.OpportunityId == null) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Quote is not linked to an Opportunity.'
            );
        }
        if (!isSuiteOptionName(q.Name)) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Only Bamboo Revenue Suite option quotes can sync to the Opportunity.'
            );
        }
        RLM_BambooRevenueSuite.OptionDetailDTO detail =
            RLM_BambooRevenueSuite.getOptionDetail(String.valueOf(q.Id));
        if (detail == null || detail.priced != true) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Price the option before syncing it to the Opportunity.'
            );
        }

        Opportunity opp = loadOpp(q.OpportunityId);
        if (opp.SyncedQuoteId != q.Id) {
            RLM_BambooRevenueSuite.restoreOpportunitySyncedQuote(opp.Id, q.Id);
        }
        Database.update(
            new Opportunity(
                Id = opp.Id,
                RLM_Bamboo_Staged_Sync_Quote_Id__c = q.Id,
                RLM_Bamboo_Sync_Mode__c = MODE_COMMITTED
            ),
            false,
            AccessLevel.USER_MODE
        );

        Opportunity afterSync = loadOpp(opp.Id);
        if (afterSync.Amount == null) {
            Decimal total = q.GrandTotal != null ? q.GrandTotal : q.TotalPrice;
            if (total != null) {
                Database.update(
                    new Opportunity(Id = afterSync.Id, Amount = total.setScale(2)),
                    false,
                    AccessLevel.USER_MODE
                );
            }
        }

        SyncResult result = new SyncResult();
        result.opportunityId = q.OpportunityId;
        result.syncedQuoteId = q.Id;
        result.stagedSyncQuoteId = q.Id;
        result.syncMode = MODE_COMMITTED;
        result.summary = 'Option committed to Opportunity.';
        result.pausedToast = false;
        return result;
    }

    /** Stop sync — keep staged winner for later recommit. */
    public static SyncResult clearSync(Id opportunityId) {
        Opportunity opp = loadOpp(opportunityId);
        Id staged = opp.SyncedQuoteId != null
            ? opp.SyncedQuoteId
            : opp.RLM_Bamboo_Staged_Sync_Quote_Id__c;
        if (opp.SyncedQuoteId != null) {
            RLM_BambooRevenueSuite.clearOpportunitySyncedQuotePublic(opp.Id);
        }
        Database.update(
            new Opportunity(
                Id = opp.Id,
                RLM_Bamboo_Staged_Sync_Quote_Id__c = staged,
                RLM_Bamboo_Sync_Mode__c = MODE_EDITING
            ),
            false,
            AccessLevel.USER_MODE
        );
        SyncResult result = new SyncResult();
        result.opportunityId = opportunityId;
        result.syncedQuoteId = null;
        result.stagedSyncQuoteId = staged;
        result.syncMode = MODE_EDITING;
        result.summary = 'Opportunity sync cleared.';
        result.pausedToast = false;
        return result;
    }

    /**
     * After Recall/Reject: restore Commit on the staged winner so AE can
     * resubmit without another Use for Opportunity click.
     */
    public static SyncResult recommitStagedWinner(Id opportunityId) {
        Opportunity opp = loadOpp(opportunityId);
        Id target = opp.RLM_Bamboo_Staged_Sync_Quote_Id__c != null
            ? opp.RLM_Bamboo_Staged_Sync_Quote_Id__c
            : opp.SyncedQuoteId;
        SyncResult result = new SyncResult();
        result.opportunityId = opportunityId;
        result.pausedToast = false;
        if (target == null) {
            result.syncMode = String.isNotBlank(opp.RLM_Bamboo_Sync_Mode__c)
                ? opp.RLM_Bamboo_Sync_Mode__c
                : MODE_EDITING;
            result.syncedQuoteId = opp.SyncedQuoteId;
            result.stagedSyncQuoteId = opp.RLM_Bamboo_Staged_Sync_Quote_Id__c;
            result.summary = 'No staged option to recommit.';
            return result;
        }
        List<Quote> quotes = [
            SELECT Id, Name
            FROM Quote
            WHERE Id = :target AND OpportunityId = :opportunityId
            WITH USER_MODE
            LIMIT 1
        ];
        if (quotes.isEmpty()) {
            result.syncMode = MODE_EDITING;
            result.summary = 'Staged option quote no longer exists.';
            return result;
        }
        try {
            return commitOption(quotes[0].Id);
        } catch (RLM_BambooRevenueSuite.SuiteException e) {
            // Unpriced / locked option — leave Editing; AE can Commit after edits.
            result.syncMode = MODE_EDITING;
            result.stagedSyncQuoteId = target;
            result.syncedQuoteId = null;
            result.summary = 'Could not auto-recommit: ' + e.getMessage();
            return result;
        }
    }

    public static Opportunity loadOpp(Id opportunityId) {
        if (opportunityId == null) {
            throw new RLM_BambooRevenueSuite.SuiteException('Opportunity Id is required.');
        }
        String soql =
            'SELECT ' +
            String.join(new List<String>(OPP_SESSION_FIELDS), ', ') +
            ' FROM Opportunity WHERE Id = :opportunityId WITH USER_MODE LIMIT 1';
        List<Opportunity> rows = Database.query(soql);
        if (rows.isEmpty()) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Opportunity not found or you no longer have access.'
            );
        }
        return rows[0];
    }

    private static Boolean isSuiteOptionName(String quoteName) {
        return String.isNotBlank(quoteName) && quoteName.contains(' — Option ');
    }

    /**
     * LWC / Aura entry for Sync Flow actions. Same implementation as Flow
     * RLM_Bamboo_Suite_Sync → this Invocable (single source of truth).
     */
    @AuraEnabled
    public static RLM_BambooRevenueSuite.SyncOpportunityResultDTO applySyncAction(
        String action,
        String opportunityId,
        String quoteId
    ) {
        InvocableRequest req = new InvocableRequest();
        req.action = action;
        req.opportunityId = opportunityId;
        req.quoteId = quoteId;
        InvocableResult ir = runInvocableOne(req);
        if (ir == null || ir.isSuccess != true) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                ir != null && String.isNotBlank(ir.errorMessage)
                    ? ir.errorMessage
                    : 'Sync action failed.'
            );
        }
        RLM_BambooRevenueSuite.SyncOpportunityResultDTO dto =
            new RLM_BambooRevenueSuite.SyncOpportunityResultDTO();
        dto.syncMode = ir.syncMode;
        dto.syncedQuoteId = String.isBlank(ir.syncedQuoteId)
            ? null
            : Id.valueOf(ir.syncedQuoteId);
        dto.stagedSyncQuoteId = String.isBlank(ir.stagedSyncQuoteId)
            ? null
            : Id.valueOf(ir.stagedSyncQuoteId);
        String oppForList = opportunityId;
        if (String.isBlank(oppForList) && dto.syncedQuoteId != null) {
            List<Quote> qs = [
                SELECT OpportunityId
                FROM Quote
                WHERE Id = :dto.syncedQuoteId
                WITH USER_MODE
                LIMIT 1
            ];
            if (!qs.isEmpty()) {
                oppForList = String.valueOf(qs[0].OpportunityId);
            }
        }
        if (String.isNotBlank(oppForList)) {
            dto.options = RLM_BambooRevenueSuite.listOptions(
                oppForList,
                String.isNotBlank(quoteId) ? quoteId : ir.syncedQuoteId
            );
        }
        return dto;
    }
}
