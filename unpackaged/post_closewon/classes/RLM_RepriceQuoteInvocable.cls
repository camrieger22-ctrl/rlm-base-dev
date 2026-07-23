/**
 * Force-reprices existing Revenue Cloud quotes via the Place Sales Transaction
 * Apex executor (the headless equivalent of the "Reprice All" quote action).
 *
 * Primary caller is the record-triggered flow RLM_Reprice_Quote_On_Sync, which
 * invokes this when a quote is synced to an Opportunity (Opportunity.SyncedQuoteId
 * becomes populated). Repricing runs in a Queueable so the (potentially
 * tax/rate-callout-bearing) executor runs outside the triggering transaction.
 *
 * The reprice sends a header-only PATCH graph with PricingPreferenceEnum.FORCE and
 * ConfigurationExecutionEnum.SKIP, which recalculates and persists prices across the
 * quote's existing line items without changing structure.
 */
public with sharing class RLM_RepriceQuoteInvocable {

    /** Test-only seam: when true, skip the platform executor call (which cannot be
     *  meaningfully exercised in a unit-test context). Never set outside tests. */
    @TestVisible
    private static Boolean bypassPlatformCallForTest = false;

    /** Test-only seam: when true, reprice() throws so the failure-notification
     *  path can be exercised deterministically. Never set outside tests. */
    @TestVisible
    private static Boolean forceFailureForTest = false;

    /** Test-only counter: number of owner failure-notifications sent this
     *  transaction. Lets tests assert a silent failure was surfaced. */
    @TestVisible
    private static Integer failureNotificationsSent = 0;

    /** Flow-facing request: lets a record-triggered flow map a scalar quote Id. */
    public class Request {
        @InvocableVariable(label='Quote Id' description='Id of the quote to force-reprice.' required=true)
        public Id quoteId;
    }

    @InvocableMethod(
        label='Reprice Quote (Force)'
        category='Revenue Cloud'
        description='Force-reprices existing quotes via Place Sales Transaction so prices are current (e.g. after a quote is synced to an Opportunity). Runs asynchronously.'
    )
    public static void repriceQuotes(List<Request> requests) {
        Set<Id> quoteIds = new Set<Id>();
        if (requests != null) {
            for (Request req : requests) {
                if (req != null
                        && req.quoteId != null
                        && req.quoteId.getSObjectType() == Quote.SObjectType) {
                    quoteIds.add(req.quoteId);
                }
            }
        }
        if (quoteIds.isEmpty()) {
            return;
        }
        System.enqueueJob(new RepriceQuoteQueueable(quoteIds));
    }

    /** Async worker so the executor (which may perform tax/rate callouts) runs
     *  cleanly outside the record-triggered transaction. */
    public class RepriceQuoteQueueable implements Queueable, Database.AllowsCallouts {
        private final Set<Id> quoteIds;

        public RepriceQuoteQueueable(Set<Id> quoteIds) {
            this.quoteIds = quoteIds;
        }

        public void execute(QueueableContext ctx) {
            // Skip quotes that no longer exist (e.g. a line delete that was part of a
            // full-quote cascade delete) so the reprice never throws on a missing record.
            // Load the owner so a failure can be surfaced to a human instead of dying
            // silently in the async job.
            Map<Id, Quote> quotesById = new Map<Id, Quote>([
                SELECT Id, Name, OwnerId, Owner.Email
                FROM Quote
                WHERE Id IN :quoteIds
            ]);
            for (Quote q : quotesById.values()) {
                try {
                    reprice(q.Id);
                } catch (Exception e) {
                    // Isolate per quote: one failure must not abort repricing the rest,
                    // and it must be made visible rather than swallowed.
                    handleRepriceFailure(q, e);
                }
            }
        }
    }

    /**
     * Surfaces a silent async reprice failure: logs an ERROR (for admins reviewing
     * debug logs / Apex exception emails) and emails the quote owner with the error
     * and remediation. Never throws — notification problems must not mask the
     * original failure or fail the job.
     */
    @TestVisible
    private static void handleRepriceFailure(Quote q, Exception e) {
        Id quoteId = (q != null) ? q.Id : null;
        String quoteName = (q != null && q.Name != null) ? q.Name : String.valueOf(quoteId);
        System.debug(
            LoggingLevel.ERROR,
            'RLM_RepriceQuoteInvocable: automatic reprice failed for quote ' +
            quoteId + ' (' + quoteName + '): ' + e.getMessage()
        );
        try {
            String toAddress = (q != null && q.Owner != null) ? q.Owner.Email : null;
            if (String.isBlank(toAddress)) {
                toAddress = UserInfo.getUserEmail();
            }
            if (String.isBlank(toAddress)) {
                return; // nowhere to send; the ERROR log above is the record of record
            }
            String recordLink = URL.getOrgDomainUrl().toExternalForm() + '/' + quoteId;
            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            mail.setToAddresses(new List<String>{ toAddress });
            mail.setSubject('Action needed: automatic reprice failed for quote ' + quoteName);
            mail.setPlainTextBody(
                'The automatic reprice for quote "' + quoteName + '" (' + quoteId + ') failed.\n\n' +
                'Error: ' + e.getMessage() + '\n\n' +
                'Prices on this quote may be stale, which will block order creation with a ' +
                '"prices aren\'t updated" error. Open the quote and click "Reprice All", ' +
                'then try again:\n' + recordLink + '\n'
            );
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });
            failureNotificationsSent++;
        } catch (Exception notifyEx) {
            System.debug(
                LoggingLevel.ERROR,
                'RLM_RepriceQuoteInvocable: failed to notify owner of reprice failure for quote ' +
                quoteId + ': ' + notifyEx.getMessage()
            );
        }
    }

    /** Force-reprices a single quote synchronously. Throws RepriceException on failure.
     *  Used by Amendment Studio after in-panel QLI edits (qty / discount). */
    public static void repriceQuoteNow(Id quoteId) {
        if (quoteId == null || quoteId.getSObjectType() != Quote.SObjectType) {
            throw new RepriceException('Quote Id is required to reprice.');
        }
        reprice(quoteId);
    }

    /** Force-reprices a single quote. Throws RepriceException on failure. */
    @TestVisible
    private static void reprice(Id quoteId) {
        RevSalesTrxn.GraphRequest graph = buildRepriceGraph(quoteId);
        if (forceFailureForTest) {
            throw new RepriceException('Forced failure for test: ' + quoteId);
        }
        if (bypassPlatformCallForTest) {
            // Still stamp amendment KPIs so unit tests cover the post-reprice hook.
            stampAmendDifferenceFields(quoteId);
            return;
        }
        RevSalesTrxn.PlaceSalesTransactionResponse resp =
            RevSalesTrxn.PlaceSalesTransactionExecutor.execute(
                graph,
                RevSalesTrxn.PricingPreferenceEnum.FORCE,
                RevSalesTrxn.ConfigurationExecutionEnum.SKIP,
                new RevSalesTrxn.ConfigurationOptionsInput(),
                (String) null,
                (RevSalesTrxn.CatalogRatesPreferenceEnum) null,
                (RevSalesTrxn.TaxPreferenceEnum) null,
                (RevSalesTrxn.PersistPreferenceEnum) null
            );
        if (resp == null || !resp.isSuccess) {
            throw new RepriceException(
                'Reprice failed for quote ' + quoteId + ': ' +
                (resp != null && resp.errorResponse != null
                    ? String.valueOf(resp.errorResponse)
                    : 'no response')
            );
        }
        // Keep Current / Proposed / Net Increase in sync after prices change.
        stampAmendDifferenceFields(quoteId);
    }

    /** Best-effort stamp; never masks a successful reprice. */
    private static void stampAmendDifferenceFields(Id quoteId) {
        try {
            RLM_AssetPriceHistoryController.stampDifferenceFieldsForQuote(quoteId);
        } catch (Exception e) {
            System.debug(
                LoggingLevel.WARN,
                'RLM_RepriceQuoteInvocable: amend KPI stamp failed for ' +
                quoteId + ': ' + e.getMessage()
            );
        }
    }

    /** Builds a header-only PATCH graph that reprices the quote in place. */
    @TestVisible
    private static RevSalesTrxn.GraphRequest buildRepriceGraph(Id quoteId) {
        List<RevSalesTrxn.RecordWithReferenceRequest> records =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        RevSalesTrxn.RecordResource header =
            new RevSalesTrxn.RecordResource(Quote.getSObjectType(), 'PATCH', String.valueOf(quoteId));
        header.fieldValues = new Map<String, Object>();
        records.add(new RevSalesTrxn.RecordWithReferenceRequest('refHeader', header));
        return new RevSalesTrxn.GraphRequest('RLM_RepriceQuoteInvocable', records);
    }

    public class RepriceException extends Exception {}
}
