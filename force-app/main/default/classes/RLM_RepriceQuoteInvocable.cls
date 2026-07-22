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
            Set<Id> existingQuoteIds =
                new Map<Id, Quote>([SELECT Id FROM Quote WHERE Id IN :quoteIds]).keySet();
            for (Id quoteId : existingQuoteIds) {
                reprice(quoteId);
            }
        }
    }

    /** Force-reprices a single quote. Throws RepriceException on failure. */
    @TestVisible
    private static void reprice(Id quoteId) {
        RevSalesTrxn.GraphRequest graph = buildRepriceGraph(quoteId);
        if (bypassPlatformCallForTest) {
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
