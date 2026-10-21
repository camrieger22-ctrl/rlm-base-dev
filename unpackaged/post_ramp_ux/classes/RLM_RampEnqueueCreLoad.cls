/**
 * Flow async-path entry: enqueue Lightning Configure after Hosted MCP
 * commits a Pending cache row. Must not run inside the MCP transaction.
 */
public with sharing class RLM_RampEnqueueCreLoad {
    @TestVisible
    static Boolean forceEnqueueInTest = false;

    public class Request {
        @InvocableVariable(required=true label='Cache Id')
        public Id cacheId;
        @InvocableVariable(label='Quote Id')
        public String quoteId;
        @InvocableVariable(label='Line Id')
        public String lineId;
    }

    @InvocableMethod(
        label='Enqueue Lightning CRE Load'
        description='Starts Configure after Hosted MCP commits a Pending cache row.'
    )
    public static void enqueue(List<Request> requests) {
        if (Test.isRunningTest() && !forceEnqueueInTest) {
            return;
        }
        if (requests == null || requests.isEmpty()) {
            return;
        }
        for (Request req : requests) {
            if (req == null || req.cacheId == null) {
                continue;
            }
            Id quoteId = toId(req.quoteId);
            Id lineId = toId(req.lineId);
            RLM_RampConfiguratorAction.enqueueLoadFromCache(
                req.cacheId, quoteId, lineId);
        }
    }

    static Id toId(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        try {
            return Id.valueOf(value);
        } catch (Exception e) {
            return null;
        }
    }
}
