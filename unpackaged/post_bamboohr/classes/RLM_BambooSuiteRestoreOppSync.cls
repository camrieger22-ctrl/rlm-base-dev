/**
 * Slice 4d Phase A — deferred Opportunity.SyncedQuoteId restore after suite Place.
 * Runs after PST so Opp DML does not race Place / platform auto-reprice in the
 * same synchronous transaction. Re-enqueues on UNABLE_TO_LOCK_ROW (up to 3 tries).
 */
public with sharing class RLM_BambooSuiteRestoreOppSync implements Queueable {
    @TestVisible
    static final Integer MAX_ATTEMPTS = 3;

    private final Id opportunityId;
    private final Id quoteIdToRestore;
    private final Integer attempt;

    public RLM_BambooSuiteRestoreOppSync(
        Id opportunityId,
        Id quoteIdToRestore,
        Integer attempt
    ) {
        this.opportunityId = opportunityId;
        this.quoteIdToRestore = quoteIdToRestore;
        this.attempt = attempt == null || attempt < 0 ? 0 : attempt;
    }

    public void execute(QueueableContext ctx) {
        if (opportunityId == null || quoteIdToRestore == null) {
            return;
        }
        try {
            RLM_BambooRevenueSuite.restoreOpportunitySyncedQuote(
                opportunityId,
                quoteIdToRestore
            );
        } catch (RLM_BambooRevenueSuite.SuiteException e) {
            if (
                attempt + 1 < MAX_ATTEMPTS &&
                RLM_BambooRevenueSuite.isLockError(e.getMessage())
            ) {
                System.enqueueJob(
                    new RLM_BambooSuiteRestoreOppSync(
                        opportunityId,
                        quoteIdToRestore,
                        attempt + 1
                    )
                );
                return;
            }
            // Exhausted retries or non-lock failure — leave sync cleared; AE can
            // Use for Opportunity again. Avoid throwing from Queueable (failed job noise).
        }
    }
}
