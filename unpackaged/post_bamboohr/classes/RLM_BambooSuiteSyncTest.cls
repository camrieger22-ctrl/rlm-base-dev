@IsTest
private class RLM_BambooSuiteSyncTest {
    static Opportunity makeOpp() {
        Account a = new Account(Name = 'Suite Sync Test');
        insert a;
        Opportunity opp = new Opportunity(
            Name = 'Suite Sync Opp',
            AccountId = a.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Pricebook2Id = Test.getStandardPricebookId()
        );
        insert opp;
        return opp;
    }

    @IsTest
    static void pauseForEditing_setsEditingMode() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session =
            RLM_BambooRevenueSuite.openFromOpportunity(opp.Id);

        Test.startTest();
        RLM_BambooSuiteSync.SyncResult result =
            RLM_BambooSuiteSync.pauseForEditing(opp.Id);
        Test.stopTest();

        System.assertEquals(RLM_BambooSuiteSync.MODE_EDITING, result.syncMode);
        System.assertNotEquals(null, session.quoteId);
    }

    @IsTest
    static void invocable_pause_ok() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.openFromOpportunity(opp.Id);

        RLM_BambooSuiteSync.InvocableRequest req =
            new RLM_BambooSuiteSync.InvocableRequest();
        req.action = 'Pause';
        req.opportunityId = String.valueOf(opp.Id);

        Test.startTest();
        List<RLM_BambooSuiteSync.InvocableResult> results =
            RLM_BambooSuiteSync.runInvocable(
                new List<RLM_BambooSuiteSync.InvocableRequest>{ req }
            );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(true, results[0].isSuccess);
        System.assertEquals(RLM_BambooSuiteSync.MODE_EDITING, results[0].syncMode);
    }

    @IsTest
    static void session_requireOpportunity_includesStagedField() {
        Opportunity opp = makeOpp();
        Test.startTest();
        Opportunity loaded = RLM_BambooSuiteSession.requireSessionOpportunity(opp.Id);
        Test.stopTest();
        // Access must not throw — proves OPP_SESSION_FIELDS includes staged/sync mode.
        System.assertEquals(null, loaded.RLM_Bamboo_Staged_Sync_Quote_Id__c);
        System.assertEquals(opp.Id, loaded.Id);
    }

    @IsTest
    static void commercial_unknownOp_throws() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session =
            RLM_BambooRevenueSuite.openFromOpportunity(opp.Id);
        RLM_BambooSuiteCommercial.OperationRequest req =
            new RLM_BambooSuiteCommercial.OperationRequest();
        req.operation = 'NotARealOp';
        req.quoteId = String.valueOf(session.quoteId);
        req.payloadJson = '{}';
        Boolean threw = false;
        try {
            RLM_BambooSuiteCommercial.run(req);
        } catch (RLM_BambooRevenueSuite.SuiteException e) {
            threw = true;
            System.assert(e.getMessage().contains('Unknown'), e.getMessage());
        }
        System.assertEquals(true, threw);
    }

    @IsTest
    static void applySyncAction_clear_viaAura() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.openFromOpportunity(opp.Id);

        Test.startTest();
        RLM_BambooRevenueSuite.SyncOpportunityResultDTO dto =
            RLM_BambooSuiteSync.applySyncAction(
                'Clear',
                String.valueOf(opp.Id),
                null
            );
        Test.stopTest();

        System.assertEquals(RLM_BambooSuiteSync.MODE_EDITING, dto.syncMode);
        System.assertEquals(null, dto.syncedQuoteId);
    }

    @IsTest
    static void approvals_quoteUrl() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session =
            RLM_BambooRevenueSuite.openFromOpportunity(opp.Id);
        String url = RLM_BambooSuiteApprovals.quoteApprovalsUrl(session.quoteId);
        System.assert(url.contains(String.valueOf(session.quoteId)), url);
        System.assert(url.contains('/lightning/r/Quote/'), url);
    }
}
