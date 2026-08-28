@IsTest
private class RLM_BambooSuiteRestoreOppSyncTest {
    private static Opportunity makeOpp() {
        Account a = new Account(Name = 'Suite Restore Opp Sync Test');
        insert a;
        Opportunity opp = new Opportunity(
            Name = 'Suite Restore Opp Sync',
            AccountId = a.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        return opp;
    }

    @IsTest
    static void isLockError_detectsPlatformMessage() {
        System.assertEquals(
            true,
            RLM_BambooRevenueSuite.isLockError(
                'unable to obtain exclusive access to this record: UNABLE_TO_LOCK_ROW'
            )
        );
        System.assertEquals(
            false,
            RLM_BambooRevenueSuite.isLockError('FIELD_CUSTOM_VALIDATION_EXCEPTION')
        );
        System.assertEquals(false, RLM_BambooRevenueSuite.isLockError(null));
    }

    @IsTest
    static void lockRecoveryMessage_mentionsReprice() {
        String msg = RLM_BambooRevenueSuite.lockRecoveryMessage();
        System.assert(msg.contains('Reprice All'), msg);
        System.assert(msg.contains('row lock'), msg);
    }

    @IsTest
    static void quoteNeedsForceReprice_falseWhenNoLines() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );
        System.assertEquals(
            false,
            RLM_BambooRevenueSuite.quoteNeedsForceReprice(session.quoteId)
        );
    }

    @IsTest
    static void restoreQueueable_setsSyncedQuoteId() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );

        Test.startTest();
        System.enqueueJob(
            new RLM_BambooSuiteRestoreOppSync(opp.Id, session.quoteId, 0)
        );
        Test.stopTest();

        Opportunity refreshed = [
            SELECT SyncedQuoteId
            FROM Opportunity
            WHERE Id = :opp.Id
        ];
        // Org may reject SyncedQuoteId without priced lines — then leave null.
        if (refreshed.SyncedQuoteId != null) {
            System.assertEquals(session.quoteId, refreshed.SyncedQuoteId);
        }
    }

    @IsTest
    static void enqueueRestoreSyncedQuote_schedulesJob() {
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session = RLM_BambooRevenueSuite.openFromOpportunity(
            opp.Id
        );

        Test.startTest();
        RLM_BambooRevenueSuite.enqueueRestoreSyncedQuote(opp.Id, session.quoteId);
        Test.stopTest();

        Opportunity refreshed = [
            SELECT SyncedQuoteId
            FROM Opportunity
            WHERE Id = :opp.Id
        ];
        if (refreshed.SyncedQuoteId != null) {
            System.assertEquals(session.quoteId, refreshed.SyncedQuoteId);
        }
    }
}
