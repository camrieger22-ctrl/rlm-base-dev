/**
 * Hosted MCP cannot Http.send or enqueueJob in the tool transaction
 * (uncatchable Script-thrown). A record-triggered Flow async path on
 * the Pending cache row starts this job after that transaction commits;
 * Claude retries describe/configure immediately.
 */
public with sharing class RLM_RampConfigureCallout implements Queueable, Database.AllowsCallouts, Finalizer {
    Id cacheId;
    Id quoteId;
    Id lineId;
    String payload;
    String sessionId;
    Boolean completed;

    public RLM_RampConfigureCallout(
        Id cacheId,
        Id quoteId,
        Id lineId,
        String payload,
        String sessionId
    ) {
        this.cacheId = cacheId;
        this.quoteId = quoteId;
        this.lineId = lineId;
        this.payload = payload;
        this.sessionId = sessionId;
        this.completed = false;
    }

    public void execute(QueueableContext ctx) {
        System.attachFinalizer(this);
        RLM_RampConfiguratorAction.runQueuedConfigure(
            cacheId, quoteId, lineId, payload, null);
        completed = true;
    }

    public void execute(FinalizerContext ctx) {
        if (completed == true) {
            return;
        }
        if (ctx == null || ctx.getResult() != ParentJobResult.UNHANDLED_EXCEPTION) {
            return;
        }
        Exception failure = ctx.getException();
        String message = failure == null || String.isBlank(failure.getMessage())
            ? 'Configurator callout failed.'
            : failure.getMessage();
        RLM_RampConfiguratorAction.markQueuedConfigureError(cacheId, message);
    }
}
