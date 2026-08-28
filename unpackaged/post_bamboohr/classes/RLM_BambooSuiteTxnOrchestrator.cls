/**
 * Slice 4d Phase B — enqueue and poll serialized suite commercial jobs per Opportunity.
 * Feature-flagged via RLM_BambooRevenueSuite.isTxnOrchestratorEnabled().
 */
public with sharing class RLM_BambooSuiteTxnOrchestrator {
    public static final Integer MAX_LOCK_RETRIES = 3;
    public static final Integer DEFAULT_POLL_MS = 500;
    public static final Integer DEFAULT_WAIT_MS = 120000;

    public class EnqueueRequest {
        public Id opportunityId;
        public Id quoteId;
        public String requestType;
        public String payloadJson;
        public Boolean restoreSync;
    }

    public class JobStatusDTO {
        @AuraEnabled public String jobId;
        @AuraEnabled public String status;
        @AuraEnabled public String errorCode;
        @AuraEnabled public String errorMessage;
        @AuraEnabled public Id quoteId;
        @AuraEnabled public Boolean isTerminal;
    }

    /**
     * Enqueue a suite commercial mutation. LWC polls getJobStatus(jobId).
     * When orchestrator is disabled, throws — caller should use direct Apex.
     */
    @AuraEnabled
    public static String enqueueSuiteMutation(
        String opportunityId,
        String quoteId,
        String requestType,
        String handler,
        String payloadJson,
        Boolean restoreSync
    ) {
        if (!RLM_BambooRevenueSuite.isTxnOrchestratorEnabled()) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Txn orchestrator is not enabled.'
            );
        }
        Id oppId = Id.valueOf(opportunityId.trim());
        Id qId = String.isBlank(quoteId) ? null : Id.valueOf(quoteId.trim());
        Map<String, Object> fields = String.isBlank(payloadJson)
            ? new Map<String, Object>()
            : (Map<String, Object>) JSON.deserializeUntyped(payloadJson);
        if (String.isNotBlank(handler)) {
            fields.put('handler', handler);
        }
        if (qId != null && !fields.containsKey('quoteId')) {
            fields.put('quoteId', String.valueOf(qId));
        }
        if (!fields.containsKey('opportunityId')) {
            fields.put('opportunityId', String.valueOf(oppId));
        }

        Boolean restore = restoreSync;
        if (restore == null) {
            // Edit mode: do not restore SyncedQuoteId after Place.
            List<Opportunity> opps = [
                SELECT RLM_Bamboo_Sync_Mode__c, SyncedQuoteId
                FROM Opportunity
                WHERE Id = :oppId
                WITH USER_MODE
                LIMIT 1
            ];
            restore =
                !opps.isEmpty() &&
                opps[0].RLM_Bamboo_Sync_Mode__c == 'Committed' &&
                opps[0].SyncedQuoteId != null;
        }

        EnqueueRequest req = new EnqueueRequest();
        req.opportunityId = oppId;
        req.quoteId = qId;
        req.requestType = String.isBlank(requestType) ? 'Place' : requestType;
        req.payloadJson = JSON.serialize(fields);
        req.restoreSync = restore;
        return enqueue(req);
    }

    @AuraEnabled
    public static Boolean isOrchestratorEnabled() {
        return RLM_BambooRevenueSuite.isTxnOrchestratorEnabled();
    }

    /**
     * Enqueue a commercial mutation job. Returns correlation id for polling.
     */
    public static String enqueue(EnqueueRequest req) {
        if (req == null || req.opportunityId == null) {
            throw new RLM_BambooRevenueSuite.SuiteException('opportunityId is required.');
        }
        if (String.isBlank(req.requestType)) {
            throw new RLM_BambooRevenueSuite.SuiteException('requestType is required.');
        }

        Id stagedSync = RLM_BambooRevenueSuite.syncedQuoteIdForOpportunityPublic(
            req.opportunityId
        );
        String correlationId = generateCorrelationId();

        RLM_Bamboo_Suite_Txn__c row = new RLM_Bamboo_Suite_Txn__c(
            Opportunity__c = req.opportunityId,
            Quote__c = req.quoteId,
            Status__c = 'Queued',
            Request_Type__c = req.requestType,
            Payload__c = req.payloadJson,
            Staged_Sync_Quote__c = stagedSync,
            Restore_Sync__c = req.restoreSync != null ? req.restoreSync : true,
            Attempt__c = 0,
            Correlation_Id__c = correlationId
        );
        insert row;

        if (!isJobAlreadyRunning(req.opportunityId)) {
            System.enqueueJob(new RLM_BambooSuiteTxnJob(req.opportunityId));
        }
        return correlationId;
    }

    /**
     * Enqueue then drain the Opp queue synchronously (agent invocables / tests).
     * Does not rely on Queueable delay.
     */
    public static JobStatusDTO enqueueAndRunSync(EnqueueRequest req) {
        if (req == null || req.opportunityId == null) {
            throw new RLM_BambooRevenueSuite.SuiteException('opportunityId is required.');
        }
        if (String.isBlank(req.requestType)) {
            throw new RLM_BambooRevenueSuite.SuiteException('requestType is required.');
        }
        Id stagedSync = RLM_BambooRevenueSuite.syncedQuoteIdForOpportunityPublic(
            req.opportunityId
        );
        String correlationId = generateCorrelationId();
        RLM_Bamboo_Suite_Txn__c row = new RLM_Bamboo_Suite_Txn__c(
            Opportunity__c = req.opportunityId,
            Quote__c = req.quoteId,
            Status__c = 'Queued',
            Request_Type__c = req.requestType,
            Payload__c = req.payloadJson,
            Staged_Sync_Quote__c = stagedSync,
            Restore_Sync__c = req.restoreSync != null ? req.restoreSync : true,
            Attempt__c = 0,
            Correlation_Id__c = correlationId
        );
        insert row;
        RLM_BambooSuiteTxnJob.processOpportunityQueueSync(req.opportunityId);
        return getJobStatus(correlationId);
    }

    @AuraEnabled
    public static JobStatusDTO getJobStatus(String jobId) {
        JobStatusDTO dto = new JobStatusDTO();
        dto.jobId = jobId;
        dto.isTerminal = true;
        dto.status = 'Failed';
        dto.errorMessage = 'Job not found.';
        if (String.isBlank(jobId)) {
            return dto;
        }
        List<RLM_Bamboo_Suite_Txn__c> rows = [
            SELECT
                Id,
                Status__c,
                Error_Code__c,
                Error_Message__c,
                Quote__c,
                Correlation_Id__c
            FROM RLM_Bamboo_Suite_Txn__c
            WHERE Correlation_Id__c = :jobId.trim()
            WITH USER_MODE
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            return dto;
        }
        RLM_Bamboo_Suite_Txn__c row = rows[0];
        dto.status = row.Status__c;
        dto.errorCode = row.Error_Code__c;
        dto.errorMessage = row.Error_Message__c;
        dto.quoteId = row.Quote__c;
        dto.isTerminal =
            row.Status__c == 'Succeeded' ||
            row.Status__c == 'Failed' ||
            row.Status__c == 'Cancelled';
        return dto;
    }

    /**
     * Blocking wait for invocable callers (max ~120s).
     */
    public static JobStatusDTO waitForCompletion(
        String jobId,
        Integer maxWaitMs
    ) {
        Integer cap = maxWaitMs == null || maxWaitMs <= 0 ? DEFAULT_WAIT_MS : maxWaitMs;
        Long deadline = System.now().getTime() + cap;
        JobStatusDTO status;
        do {
            status = getJobStatus(jobId);
            if (status.isTerminal) {
                return status;
            }
            // Queueable-safe poll — no Sleep in Apex; tight spin with limit
        } while (System.now().getTime() < deadline);
        status = getJobStatus(jobId);
        if (!status.isTerminal) {
            status.status = 'Running';
            status.errorMessage = 'Job still running — refresh Revenue Suite.';
            status.isTerminal = false;
        }
        return status;
    }

    public static String buildPayload(String handler, Map<String, Object> fields) {
        Map<String, Object> body = fields == null
            ? new Map<String, Object>()
            : new Map<String, Object>(fields);
        body.put('handler', handler);
        return JSON.serialize(body);
    }

    @TestVisible
    static Boolean isJobAlreadyRunning(Id opportunityId) {
        Integer running = [
            SELECT COUNT()
            FROM RLM_Bamboo_Suite_Txn__c
            WHERE Opportunity__c = :opportunityId AND Status__c = 'Running'
            WITH USER_MODE
        ];
        return running > 0;
    }

    @TestVisible
    static RLM_Bamboo_Suite_Txn__c nextQueuedJob(Id opportunityId) {
        List<RLM_Bamboo_Suite_Txn__c> rows = [
            SELECT
                Id,
                Opportunity__c,
                Quote__c,
                Status__c,
                Request_Type__c,
                Payload__c,
                Staged_Sync_Quote__c,
                Restore_Sync__c,
                Attempt__c,
                Correlation_Id__c
            FROM RLM_Bamboo_Suite_Txn__c
            WHERE Opportunity__c = :opportunityId AND Status__c = 'Queued'
            WITH USER_MODE
            ORDER BY CreatedDate ASC
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    private static String generateCorrelationId() {
        String hex = EncodingUtil.convertToHex(Crypto.generateAesKey(128));
        return hex.substring(0, 32);
    }
}
