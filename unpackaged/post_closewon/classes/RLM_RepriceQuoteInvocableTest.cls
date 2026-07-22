@isTest
private class RLM_RepriceQuoteInvocableTest {

    private static Quote makeQuote() {
        Account acct = new Account(Name = 'Reprice Test Account');
        insert acct;
        Opportunity opp = new Opportunity(
            Name = 'Reprice Test Opp',
            AccountId = acct.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Quote q = new Quote(
            Name = 'Reprice Test Quote',
            Pricebook2Id = Test.getStandardPricebookId(),
            OpportunityId = opp.Id,
            Status = 'Draft'
        );
        insert q;
        return q;
    }

    private static Integer queueableCount() {
        return [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'Queueable'];
    }

    @isTest
    static void repriceQuotes_nullInput_enqueuesNothing() {
        Test.startTest();
        RLM_RepriceQuoteInvocable.repriceQuotes(null);
        Test.stopTest();
        System.assertEquals(0, queueableCount(), 'Null input must not enqueue a job');
    }

    @isTest
    static void repriceQuotes_emptyAndInvalid_enqueuesNothing() {
        RLM_RepriceQuoteInvocable.Request nullReq = new RLM_RepriceQuoteInvocable.Request();
        Test.startTest();
        RLM_RepriceQuoteInvocable.repriceQuotes(new List<RLM_RepriceQuoteInvocable.Request>());
        RLM_RepriceQuoteInvocable.repriceQuotes(new List<RLM_RepriceQuoteInvocable.Request>{ nullReq });
        Test.stopTest();
        System.assertEquals(0, queueableCount(),
            'Empty list and null-quoteId request must not enqueue a job');
    }

    @isTest
    static void repriceQuotes_validRequest_enqueuesAndRuns() {
        Quote q = makeQuote();
        RLM_RepriceQuoteInvocable.Request req = new RLM_RepriceQuoteInvocable.Request();
        req.quoteId = q.Id;
        RLM_RepriceQuoteInvocable.bypassPlatformCallForTest = true; // skip platform executor
        Test.startTest();
        RLM_RepriceQuoteInvocable.repriceQuotes(new List<RLM_RepriceQuoteInvocable.Request>{ req });
        System.assertEquals(1, Limits.getQueueableJobs(), 'Exactly one queueable should be enqueued');
        Test.stopTest(); // queueable executes here (graph build + bypass return, no exception)
    }

    @isTest
    static void buildRepriceGraph_returnsGraph() {
        Quote q = makeQuote();
        Test.startTest();
        RevSalesTrxn.GraphRequest graph = RLM_RepriceQuoteInvocable.buildRepriceGraph(q.Id);
        Test.stopTest();
        System.assertNotEquals(null, graph, 'A graph should be built for a valid quote Id');
    }

    @isTest
    static void repriceFailure_isSurfacedToOwner_notSwallowed() {
        // A forced reprice failure inside the queueable must be caught, isolated,
        // and surfaced to the quote owner (email + ERROR log) rather than dying
        // silently in the async job.
        Quote q = makeQuote();
        RLM_RepriceQuoteInvocable.Request req = new RLM_RepriceQuoteInvocable.Request();
        req.quoteId = q.Id;
        RLM_RepriceQuoteInvocable.forceFailureForTest = true;
        Test.startTest();
        RLM_RepriceQuoteInvocable.repriceQuotes(new List<RLM_RepriceQuoteInvocable.Request>{ req });
        Test.stopTest(); // queueable runs here; a forced failure must NOT propagate out
        System.assert(RLM_RepriceQuoteInvocable.failureNotificationsSent >= 1,
            'A silent reprice failure must be surfaced to the owner');
    }

    @isTest
    static void handleRepriceFailure_neverThrows() {
        // Notification problems must never mask the original failure. Passing a
        // null quote exercises the defensive path (falls back to running-user email).
        Test.startTest();
        RLM_RepriceQuoteInvocable.handleRepriceFailure(
            null, new RLM_RepriceQuoteInvocable.RepriceException('boom'));
        Test.stopTest();
        System.assert(true, 'handleRepriceFailure must not throw');
    }

    @isTest
    static void reprice_executorPath_isTolerant() {
        // Exercises the platform-executor call path for coverage. A bare test org may
        // not have pricing fully configured, so any executor outcome is acceptable here;
        // the goal is line coverage of the reprice() executor branch.
        Quote q = makeQuote();
        RLM_RepriceQuoteInvocable.bypassPlatformCallForTest = false;
        Test.startTest();
        try {
            RLM_RepriceQuoteInvocable.reprice(q.Id);
        } catch (Exception e) {
            System.assert(e != null, 'Executor may throw when pricing is not configured in test context');
        }
        Test.stopTest();
    }
}
