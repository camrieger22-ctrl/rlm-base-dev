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

    /**
     * OOTB Place Sales Transaction: PATCH quote header + one line, FORCE price.
     * Prefer this over QLI DML when Quote Line Details / ramps own sales price
     * (UnitPrice DML is blocked once details exist).
     */
    public static void patchLineAndReprice(
        Id quoteId,
        Id lineItemId,
        Map<String, Object> lineFieldValues
    ) {
        if (quoteId == null || quoteId.getSObjectType() != Quote.SObjectType) {
            throw new RepriceException('Quote Id is required to reprice.');
        }
        if (lineItemId == null || lineItemId.getSObjectType() != QuoteLineItem.SObjectType) {
            throw new RepriceException('Quote line Id is required to patch.');
        }
        if (lineFieldValues == null || lineFieldValues.isEmpty()) {
            reprice(quoteId);
            return;
        }
        executeGraph(buildLinePatchGraph(quoteId, lineItemId, lineFieldValues), quoteId);
    }

    /**
     * OOTB Place Sales Transaction: add a catalog line (QuoteAction Type=Add +
     * QuoteLineItem POST) with FORCE pricing. Prefer this over Apex insert of
     * QuoteAction / QuoteLineItem. lineFieldValues should include Product2Id,
     * PricebookEntryId, Quantity, UnitPrice, and optional dates — QuoteId and
     * QuoteActionId are set by the graph builder.
     */
    public static void addCatalogLineAndReprice(
        Id quoteId,
        Map<String, Object> lineFieldValues
    ) {
        if (quoteId == null || quoteId.getSObjectType() != Quote.SObjectType) {
            throw new RepriceException('Quote Id is required to add a line.');
        }
        if (lineFieldValues == null || lineFieldValues.isEmpty()) {
            throw new RepriceException('Line field values are required to add a line.');
        }
        if (lineFieldValues.get('Product2Id') == null || lineFieldValues.get('PricebookEntryId') == null) {
            throw new RepriceException('Product2Id and PricebookEntryId are required to add a line.');
        }
        executeGraph(buildCatalogLineAddGraph(quoteId, lineFieldValues), quoteId);
    }

    /** Force-reprices a single quote. Throws RepriceException on failure. */
    @TestVisible
    private static void reprice(Id quoteId) {
        executeGraph(buildRepriceGraph(quoteId), quoteId);
    }

    private static void executeGraph(RevSalesTrxn.GraphRequest graph, Id quoteId) {
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

    @TestVisible
    private static RevSalesTrxn.GraphRequest buildLinePatchGraph(
        Id quoteId,
        Id lineItemId,
        Map<String, Object> lineFieldValues
    ) {
        List<RevSalesTrxn.RecordWithReferenceRequest> records =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        RevSalesTrxn.RecordResource header =
            new RevSalesTrxn.RecordResource(Quote.getSObjectType(), 'PATCH', String.valueOf(quoteId));
        header.fieldValues = new Map<String, Object>();
        records.add(new RevSalesTrxn.RecordWithReferenceRequest('refHeader', header));

        RevSalesTrxn.RecordResource line =
            new RevSalesTrxn.RecordResource(
                QuoteLineItem.getSObjectType(),
                'PATCH',
                String.valueOf(lineItemId)
            );
        line.fieldValues = normalizePstFieldValues(lineFieldValues);
        records.add(new RevSalesTrxn.RecordWithReferenceRequest('refLine', line));
        return new RevSalesTrxn.GraphRequest('RLM_Studio_LinePatch', records);
    }

    /**
     * PATCH Quote + POST QuoteAction(Type=Add) + POST QuoteLineItem linked via
     * @{refAction.id}. Verified live on amend Quotes (platform does not auto-
     * stamp QuoteAction when only the QLI is POSTed).
     */
    @TestVisible
    private static RevSalesTrxn.GraphRequest buildCatalogLineAddGraph(
        Id quoteId,
        Map<String, Object> lineFieldValues
    ) {
        String quoteIdStr = String.valueOf(quoteId);
        List<RevSalesTrxn.RecordWithReferenceRequest> records =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();

        RevSalesTrxn.RecordResource header =
            new RevSalesTrxn.RecordResource(Quote.getSObjectType(), 'PATCH', quoteIdStr);
        header.fieldValues = new Map<String, Object>();
        records.add(new RevSalesTrxn.RecordWithReferenceRequest('refHeader', header));

        RevSalesTrxn.RecordResource action =
            new RevSalesTrxn.RecordResource(QuoteAction.getSObjectType(), 'POST');
        action.fieldValues = new Map<String, Object>{
            'QuoteId' => quoteIdStr,
            'Type' => 'Add'
        };
        records.add(new RevSalesTrxn.RecordWithReferenceRequest('refAction', action));

        Map<String, Object> fields = normalizePstFieldValues(lineFieldValues);
        fields.put('QuoteId', quoteIdStr);
        fields.put('QuoteActionId', '@{refAction.id}');
        // Caller must not override action linkage / identity fields.
        fields.remove('Id');

        RevSalesTrxn.RecordResource line =
            new RevSalesTrxn.RecordResource(QuoteLineItem.getSObjectType(), 'POST');
        line.fieldValues = fields;
        records.add(new RevSalesTrxn.RecordWithReferenceRequest('refLine', line));

        return new RevSalesTrxn.GraphRequest('RLM_Studio_CatalogLineAdd', records);
    }

    /** PST JSON codec rejects Apex Date objects — send yyyy-MM-dd strings. */
    @TestVisible
    private static Map<String, Object> normalizePstFieldValues(Map<String, Object> fieldValues) {
        Map<String, Object> normalized = new Map<String, Object>();
        if (fieldValues == null) {
            return normalized;
        }
        for (String key : fieldValues.keySet()) {
            Object val = fieldValues.get(key);
            if (val instanceof Date) {
                Date d = (Date) val;
                normalized.put(
                    key,
                    String.valueOf(d.year()) +
                        '-' +
                        (d.month() < 10 ? '0' : '') +
                        String.valueOf(d.month()) +
                        '-' +
                        (d.day() < 10 ? '0' : '') +
                        String.valueOf(d.day())
                );
            } else {
                normalized.put(key, val);
            }
        }
        return normalized;
    }

    public class RepriceException extends Exception {}
}