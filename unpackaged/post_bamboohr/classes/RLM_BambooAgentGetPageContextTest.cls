/**
 * Coverage for RLM_BambooAgentGetPageContext.
 *
 * MessagingSession cannot be inserted in an Apex test (it requires a
 * MessagingChannel + MessagingEndUser that are not creatable), so the record
 * path is exercised with a synthetic Id that resolves to no rows, and the
 * summary rendering is covered directly.
 */
@isTest
private class RLM_BambooAgentGetPageContextTest {
    static Id fakeSessionId() {
        String prefix = MessagingSession.SObjectType.getDescribe().getKeyPrefix();
        return Id.valueOf(prefix + '000000000001');
    }

    static RLM_BambooAgentGetPageContext.Request req(String sessionId) {
        RLM_BambooAgentGetPageContext.Request r = new RLM_BambooAgentGetPageContext.Request();
        r.messagingSessionId = sessionId;
        return r;
    }

    @isTest
    static void nullAndEmptyInput() {
        Test.startTest();
        List<RLM_BambooAgentGetPageContext.Result> nullIn = RLM_BambooAgentGetPageContext.run(null);
        List<RLM_BambooAgentGetPageContext.Result> emptyIn = RLM_BambooAgentGetPageContext.run(
            new List<RLM_BambooAgentGetPageContext.Request>()
        );
        Test.stopTest();

        System.assertEquals(0, nullIn.size(), 'Null input returns no results');
        System.assertEquals(0, emptyIn.size(), 'Empty input returns no results');
    }

    @isTest
    static void blankSessionIdFails() {
        List<RLM_BambooAgentGetPageContext.Result> out = RLM_BambooAgentGetPageContext.run(
            new List<RLM_BambooAgentGetPageContext.Request>{ req('   ') }
        );

        System.assertEquals(1, out.size(), 'One result per request');
        System.assertEquals(false, out[0].isSuccess, 'Blank Id fails');
        System.assert(
            out[0].errorMessage.contains('Messaging Session Id'),
            'Error names the missing input: ' + out[0].errorMessage
        );
    }

    @isTest
    static void nullRequestFails() {
        RLM_BambooAgentGetPageContext.Result res = RLM_BambooAgentGetPageContext.runOne(null);

        System.assertEquals(false, res.isSuccess, 'Null request fails');
        System.assertEquals(false, res.hasContext, 'Null request has no context');
    }

    @isTest
    static void malformedIdFails() {
        List<RLM_BambooAgentGetPageContext.Result> out = RLM_BambooAgentGetPageContext.run(
            new List<RLM_BambooAgentGetPageContext.Request>{ req('not-an-id') }
        );

        System.assertEquals(false, out[0].isSuccess, 'Malformed Id fails');
        System.assertEquals('Invalid Messaging Session Id.', out[0].errorMessage);
    }

    @isTest
    static void wrongObjectIdFails() {
        Account acct = new Account(Name = 'Page Context Test');
        insert acct;

        List<RLM_BambooAgentGetPageContext.Result> out = RLM_BambooAgentGetPageContext.run(
            new List<RLM_BambooAgentGetPageContext.Request>{ req(acct.Id) }
        );

        System.assertEquals(false, out[0].isSuccess, 'Account Id is rejected');
        System.assertEquals('Id is not a Messaging Session.', out[0].errorMessage);
    }

    @isTest
    static void missingSessionFails() {
        List<RLM_BambooAgentGetPageContext.Result> out = RLM_BambooAgentGetPageContext.run(
            new List<RLM_BambooAgentGetPageContext.Request>{ req(fakeSessionId()) }
        );

        System.assertEquals(false, out[0].isSuccess, 'Unknown session fails');
        System.assertEquals('Messaging Session not found.', out[0].errorMessage);
    }

    @isTest
    static void summaryRendersFullContext() {
        RLM_BambooAgentGetPageContext.Result res = new RLM_BambooAgentGetPageContext.Result();
        res.hasContext = true;
        res.qualifyStep = '4';
        res.qualifyStepLabel = 'decision-maker role';
        res.headcount = '12';
        res.page = 'quote';
        res.bounceType = 'payroll';
        res.quoteId = '0Q0TEST000000001AAA';
        res.accountId = '001TEST000000001AAA';
        res.qualifySessionId = 'sess-abc';

        String summary = RLM_BambooAgentGetPageContext.buildSummary(res);

        System.assert(summary.contains('beat 4 of 5'), 'States the beat: ' + summary);
        System.assert(summary.contains('decision-maker role'), 'Names the beat: ' + summary);
        System.assert(summary.contains('12 employees'), 'Reports headcount: ' + summary);
        System.assert(summary.contains('the quote summary'), 'Reports surface: ' + summary);
        System.assert(summary.contains('Payroll'), 'Explains the bounce: ' + summary);
        System.assert(summary.contains('0Q0TEST000000001AAA'), 'Sticky Quote: ' + summary);
        System.assert(summary.contains('001TEST000000001AAA'), 'Account: ' + summary);
        System.assert(summary.contains('sess-abc'), 'Qualify session: ' + summary);
    }

    @isTest
    static void summaryRendersLicensesAccount() {
        RLM_BambooAgentGetPageContext.Result res = new RLM_BambooAgentGetPageContext.Result();
        res.hasContext = true;
        res.page = 'account';
        res.accountId = '001TEST000000001AAA';
        String summary = RLM_BambooAgentGetPageContext.buildSummary(res);
        System.assert(summary.contains('Licenses & billing'), 'Names Licenses: ' + summary);
        System.assert(summary.contains('001TEST000000001AAA'), 'Includes Account Id: ' + summary);
    }

    @isTest
    static void summaryHandlesUnknownCodes() {
        RLM_BambooAgentGetPageContext.Result res = new RLM_BambooAgentGetPageContext.Result();
        res.hasContext = true;
        res.qualifyStep = '9';
        res.bounceType = 'mystery';

        String summary = RLM_BambooAgentGetPageContext.buildSummary(res);

        System.assert(summary.contains('beat 9 of 5'), 'Falls back to the raw beat: ' + summary);
        System.assert(summary.contains('mystery'), 'Falls back to the raw bounce: ' + summary);
    }

    @isTest
    static void summaryHandlesNoContext() {
        RLM_BambooAgentGetPageContext.Result res = new RLM_BambooAgentGetPageContext.Result();
        res.hasContext = false;

        String summary = RLM_BambooAgentGetPageContext.buildSummary(res);

        System.assert(
            summary.contains('ask the buyer what they see'),
            'Tells the agent to ask: ' + summary
        );
    }

    @isTest
    static void preferQuoteAccountOverridesStalePin() {
        RLM_BambooAgentGetPageContext.Result res = new RLM_BambooAgentGetPageContext.Result();
        res.accountId = '001STALE00000000AAA';
        RLM_BambooAgentGetPageContext.preferQuoteAccount(res, '001QUOTE00000000AAA');
        System.assertEquals('001QUOTE00000000AAA', res.accountId);
    }

    @isTest
    static void summaryIncludesQuoteSnapshot() {
        RLM_BambooAgentGetPageContext.Result res = new RLM_BambooAgentGetPageContext.Result();
        res.hasContext = true;
        res.page = 'quote';
        res.planLabel = 'BambooHR Core';
        res.headcount = '12';
        res.startDate = '2026-08-19';
        res.monthlyTotalText = '124';
        String summary = RLM_BambooAgentGetPageContext.buildSummary(res);
        System.assert(summary.contains('BambooHR Core'), summary);
        System.assert(summary.contains('start 2026-08-19'), summary);
        System.assert(summary.contains('term total 124'), summary);
        System.assert(summary.contains('the quote summary'), summary);
    }

    @isTest
    static void placeRecitationIncludesQuoteFacts() {
        RLM_BambooAgentGetPageContext.Result res = new RLM_BambooAgentGetPageContext.Result();
        res.quoteId = '0Q0TEST000000001AAA';
        res.planLabel = 'BambooHR Core';
        res.headcount = '12';
        res.startDate = '2026-08-19';
        res.monthlyTotalText = '1443.87';
        String line = RLM_BambooAgentGetPageContext.buildPlaceRecitation(res);
        System.assert(line.contains('0Q0TEST000000001AAA'), line);
        System.assert(line.contains('BambooHR Core'), line);
        System.assert(line.contains('12 seats'), line);
        System.assert(line.contains('2026-08-19'), line);
        System.assert(line.contains('1443.87'), line);
        System.assert(line.contains('never ask the buyer to type yes'), line);
        System.assertEquals(null, RLM_BambooAgentGetPageContext.buildPlaceRecitation(new RLM_BambooAgentGetPageContext.Result()));
    }

    @isTest
    static void blankToNullNormalizes() {
        System.assertEquals(null, RLM_BambooAgentGetPageContext.blankToNull(null));
        System.assertEquals(null, RLM_BambooAgentGetPageContext.blankToNull('  '));
        System.assertEquals('4', RLM_BambooAgentGetPageContext.blankToNull(' 4 '));
    }

    @isTest
    static void mergeStickyKeepsCurrentWhenPageBlank() {
        RLM_BambooAgentGetPageContext.Request req = new RLM_BambooAgentGetPageContext.Request();
        req.currentQuoteId = '0Q0CURRENT000000AAA';
        req.currentAccountId = '001CURRENT000000AAA';
        req.currentQualifySessionId = 'sess-current';
        req.currentCommitted = 'true';
        RLM_BambooAgentGetPageContext.Result res = new RLM_BambooAgentGetPageContext.Result();
        RLM_BambooAgentGetPageContext.mergeSticky(res, null, null, null, req);
        System.assertEquals('0Q0CURRENT000000AAA', res.quoteId);
        System.assertEquals('001CURRENT000000AAA', res.accountId);
        System.assertEquals('sess-current', res.qualifySessionId);
        System.assertEquals('true', res.qualifyCommitted);
        System.assert(res.quoteUrl.contains('0Q0CURRENT000000AAA'));
    }

    @isTest
    static void mergeStickyPageWinsOverCurrent() {
        RLM_BambooAgentGetPageContext.Request req = new RLM_BambooAgentGetPageContext.Request();
        req.currentQuoteId = '0Q0OLD0000000000AAA';
        RLM_BambooAgentGetPageContext.Result res = new RLM_BambooAgentGetPageContext.Result();
        RLM_BambooAgentGetPageContext.mergeSticky(
            res,
            '001PAGE0000000000AAA',
            '0Q0PAGE0000000000AAA',
            'sess-page',
            req
        );
        System.assertEquals('0Q0PAGE0000000000AAA', res.quoteId);
        System.assertEquals('001PAGE0000000000AAA', res.accountId);
        System.assertEquals('sess-page', res.qualifySessionId);
        System.assertEquals('true', res.qualifyCommitted);
    }
}
