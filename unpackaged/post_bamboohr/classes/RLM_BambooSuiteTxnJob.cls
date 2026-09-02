/**
 * Slice 4d Phase B — Queueable worker for serialized suite commercial jobs.
 */
public with sharing class RLM_BambooSuiteTxnJob implements Queueable {
    private final Id opportunityId;

    public RLM_BambooSuiteTxnJob(Id opportunityId) {
        this.opportunityId = opportunityId;
    }

    public void execute(QueueableContext ctx) {
        processOpportunityQueueSync(opportunityId);
    }

    /**
     * Process queued jobs for one Opportunity in order (sync — used by Queueable and invocables).
     */
    public static void processOpportunityQueueSync(Id opportunityId) {
        if (opportunityId == null) {
            return;
        }
        RLM_Bamboo_Suite_Txn__c next =
            RLM_BambooSuiteTxnOrchestrator.nextQueuedJob(opportunityId);
        if (next == null) {
            return;
        }
        processOneJob(next);
        processOpportunityQueueSync(opportunityId);
    }

    @TestVisible
    static void processOneJob(RLM_Bamboo_Suite_Txn__c job) {
        if (job == null || job.Id == null) {
            return;
        }
        job.Status__c = 'Running';
        update as user job;

        try {
            if (
                job.Staged_Sync_Quote__c != null &&
                RLM_BambooRevenueSuite.syncedQuoteIdForOpportunityPublic(
                    job.Opportunity__c
                ) != null
            ) {
                RLM_BambooRevenueSuite.clearOpportunitySyncedQuotePublic(
                    job.Opportunity__c
                );
            }
            RLM_BambooRevenueSuite.setTxnJobInProgress(true);
            dispatch(job);
            job.Status__c = 'Succeeded';
            job.Error_Code__c = null;
            job.Error_Message__c = null;
            update as user job;

            if (job.Restore_Sync__c == true && job.Staged_Sync_Quote__c != null) {
                RLM_BambooRevenueSuite.enqueueRestoreSyncedQuote(
                    job.Opportunity__c,
                    job.Staged_Sync_Quote__c
                );
            }
        } catch (Exception e) {
            String msg = e.getMessage();
            if (String.isBlank(msg)) {
                msg = e.getTypeName();
            }
            if (
                RLM_BambooRevenueSuite.isLockError(msg) &&
                (job.Attempt__c == null ||
                    job.Attempt__c < RLM_BambooSuiteTxnOrchestrator.MAX_LOCK_RETRIES)
            ) {
                job.Status__c = 'Queued';
                job.Attempt__c =
                    (job.Attempt__c == null ? 0 : job.Attempt__c) + 1;
                job.Error_Code__c = 'UNABLE_TO_LOCK_ROW';
                job.Error_Message__c = msg;
                update as user job;
                System.enqueueJob(new RLM_BambooSuiteTxnJob(job.Opportunity__c));
                return;
            }
            job.Status__c = 'Failed';
            job.Error_Code__c = RLM_BambooRevenueSuite.isLockError(msg)
                ? 'UNABLE_TO_LOCK_ROW'
                : 'JOB_FAILED';
            job.Error_Message__c = msg;
            update as user job;
        } finally {
            RLM_BambooRevenueSuite.setTxnJobInProgress(false);
        }
    }

    private static void dispatch(RLM_Bamboo_Suite_Txn__c job) {
        Map<String, Object> payload = String.isBlank(job.Payload__c)
            ? new Map<String, Object>()
            : (Map<String, Object>) JSON.deserializeUntyped(job.Payload__c);
        String handler = payload.containsKey('handler')
            ? String.valueOf(payload.get('handler'))
            : job.Request_Type__c;

        // Prefer commercial gateway for Place-style mutators (single dispatch table).
        String commercialOp = commercialOpForHandler(handler, job.Request_Type__c);
        if (String.isNotBlank(commercialOp)) {
            RLM_BambooSuiteCommercial.OperationRequest req =
                new RLM_BambooSuiteCommercial.OperationRequest();
            req.operation = commercialOp;
            req.quoteId = stringVal(payload, 'quoteId');
            req.opportunityId = stringVal(payload, 'opportunityId');
            if (String.isBlank(req.opportunityId) && job.Opportunity__c != null) {
                req.opportunityId = String.valueOf(job.Opportunity__c);
            }
            req.payloadJson = JSON.serialize(payload);
            RLM_BambooSuiteCommercial.run(req);
            return;
        }

        if (handler == 'UpdateSeats') {
            runUpdateSeats(payload);
            return;
        }
        if (handler == 'SyncCommit' || job.Request_Type__c == 'SyncCommit') {
            String quoteRaw = stringVal(payload, 'quoteId');
            RLM_BambooRevenueSuite.syncOptionToOpportunity(quoteRaw);
            return;
        }
        if (handler == 'ApplyCommercialTerms') {
            runApplyCommercialTerms(payload);
            return;
        }
        throw new RLM_BambooRevenueSuite.SuiteException(
            'Unsupported job handler: ' + handler
        );
    }

    private static String commercialOpForHandler(String handler, String requestType) {
        String h = String.isBlank(handler) ? requestType : handler;
        if (String.isBlank(h)) {
            return null;
        }
        if (h == 'UpdateLineQuantity') {
            return 'UpdateQty';
        }
        if (h == 'UpdateLineDiscount') {
            return 'UpdateDisc';
        }
        if (h == 'UpdateOptionDiscount') {
            return 'UpdateOptionDisc';
        }
        if (h == 'ApplyTermToOption') {
            return 'ApplyTerm';
        }
        if (h == 'ApplyTermToAllOptions') {
            return 'ApplyTermAll';
        }
        if (h == 'ApplyBillingToAllOptions') {
            return 'ApplyBillingAll';
        }
        if (h == 'RemoveLine' || h == 'RemoveLines') {
            return 'RemoveLines';
        }
        if (h == 'Reprice' || requestType == 'Reprice') {
            return 'Reprice';
        }
        if (h == 'AddLinesBySku') {
            return 'AddLinesBySku';
        }
        if (h == 'AddWorkforcePackage') {
            return 'AddWorkforcePackage';
        }
        return null;
    }

    private static void runUpdateSeats(Map<String, Object> payload) {
        RLM_BambooSuiteUpdateSeats.Request req = new RLM_BambooSuiteUpdateSeats.Request();
        req.quoteId = stringVal(payload, 'quoteId');
        req.opportunityId = stringVal(payload, 'opportunityId');
        req.optionLabel = stringVal(payload, 'optionLabel');
        req.seatCount = intVal(payload, 'seatCount');
        req.termMonths = intVal(payload, 'termMonths');
        req.billingFrequency = stringVal(payload, 'billingFrequency');
        req.startDate = stringVal(payload, 'startDate');
        RLM_BambooSuiteUpdateSeats.Result res = RLM_BambooSuiteUpdateSeats.updateOne(
            req
        );
        if (res.isSuccess != true) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                String.isNotBlank(res.errorMessage)
                    ? res.errorMessage
                    : res.summary
            );
        }
    }

    private static void runApplyCommercialTerms(Map<String, Object> payload) {
        RLM_BambooSuiteApplyCommercialTerms.Request req =
            new RLM_BambooSuiteApplyCommercialTerms.Request();
        req.opportunityId = stringVal(payload, 'opportunityId');
        req.termMonths = intVal(payload, 'termMonths');
        req.billingFrequency = stringVal(payload, 'billingFrequency');
        req.startDate = stringVal(payload, 'startDate');
        req.optionLabel = stringVal(payload, 'optionLabel');
        List<RLM_BambooSuiteApplyCommercialTerms.Result> results =
            RLM_BambooSuiteApplyCommercialTerms.apply(
                new List<RLM_BambooSuiteApplyCommercialTerms.Request>{ req }
            );
        if (results.isEmpty() || results[0].isSuccess != true) {
            String msg = results.isEmpty()
                ? 'Apply commercial terms failed.'
                : results[0].errorMessage;
            throw new RLM_BambooRevenueSuite.SuiteException(msg);
        }
    }

    private static String stringVal(Map<String, Object> payload, String key) {
        if (payload == null || !payload.containsKey(key) || payload.get(key) == null) {
            return null;
        }
        return String.valueOf(payload.get(key));
    }

    private static Integer intVal(Map<String, Object> payload, String key) {
        if (payload == null || !payload.containsKey(key) || payload.get(key) == null) {
            return null;
        }
        Object raw = payload.get(key);
        if (raw instanceof Integer) {
            return (Integer) raw;
        }
        if (raw instanceof Decimal) {
            return ((Decimal) raw).intValue();
        }
        return Integer.valueOf(String.valueOf(raw));
    }

    private static List<String> stringListVal(Map<String, Object> payload, String key) {
        if (payload == null || !payload.containsKey(key) || payload.get(key) == null) {
            return null;
        }
        List<String> out = new List<String>();
        Object raw = payload.get(key);
        if (raw instanceof List<Object>) {
            for (Object o : (List<Object>) raw) {
                if (o != null) {
                    out.add(String.valueOf(o));
                }
            }
        }
        return out;
    }

    private static Decimal decVal(Map<String, Object> payload, String key) {
        if (payload == null || !payload.containsKey(key) || payload.get(key) == null) {
            return null;
        }
        Object raw = payload.get(key);
        if (raw instanceof Decimal) {
            return (Decimal) raw;
        }
        if (raw instanceof Integer) {
            return Decimal.valueOf((Integer) raw);
        }
        return Decimal.valueOf(String.valueOf(raw));
    }
}
