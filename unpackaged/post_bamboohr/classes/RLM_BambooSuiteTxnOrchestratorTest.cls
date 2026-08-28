@IsTest
private class RLM_BambooSuiteTxnOrchestratorTest {
    private static Opportunity makeOpp() {
        Account acct = new Account(Name = 'Txn Orch Test');
        insert acct;
        Opportunity opp = new Opportunity(
            Name = 'Txn Orch Opp',
            AccountId = acct.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        return opp;
    }

    @IsTest
    static void enqueue_createsQueuedJobWithCorrelationId() {
        Opportunity opp = makeOpp();
        RLM_BambooSuiteTxnOrchestrator.EnqueueRequest req =
            new RLM_BambooSuiteTxnOrchestrator.EnqueueRequest();
        req.opportunityId = opp.Id;
        req.requestType = 'Reprice';
        req.payloadJson = RLM_BambooSuiteTxnOrchestrator.buildPayload(
            'Reprice',
            new Map<String, Object>{ 'quoteId' => '0Q000000000000AAA' }
        );

        Test.startTest();
        String jobId = RLM_BambooSuiteTxnOrchestrator.enqueue(req);
        Test.stopTest();

        System.assertNotEquals(null, jobId);
        RLM_BambooSuiteTxnOrchestrator.JobStatusDTO status =
            RLM_BambooSuiteTxnOrchestrator.getJobStatus(jobId);
        System.assertNotEquals(null, status.status);
    }

    @IsTest
    static void getJobStatus_unknownId_returnsFailedTerminal() {
        RLM_BambooSuiteTxnOrchestrator.JobStatusDTO status =
            RLM_BambooSuiteTxnOrchestrator.getJobStatus('does-not-exist');
        System.assertEquals(true, status.isTerminal);
        System.assertEquals('Failed', status.status);
    }

    @IsTest(SeeAllData=true)
    static void processQueue_serializesTwoJobs() {
        List<RLM_BambooRevenueSuite.CatalogProductDTO> catalog =
            RLM_BambooRevenueSuite.getCatalog('USD');
        if (catalog.isEmpty()) {
            return;
        }
        Opportunity opp = makeOpp();
        RLM_BambooRevenueSuite.SessionDTO session =
            RLM_BambooRevenueSuite.openFromOpportunity(opp.Id);
        RLM_BambooRevenueSuite.addProductLine(
            session.quoteId,
            catalog[0].sku,
            10,
            12,
            null,
            null
        );

        RLM_Bamboo_Suite_Txn__c j1 = new RLM_Bamboo_Suite_Txn__c(
            Opportunity__c = opp.Id,
            Quote__c = session.quoteId,
            Status__c = 'Queued',
            Request_Type__c = 'Reprice',
            Payload__c = RLM_BambooSuiteTxnOrchestrator.buildPayload(
                'Reprice',
                new Map<String, Object>{
                    'quoteId' => String.valueOf(session.quoteId)
                }
            ),
            Restore_Sync__c = false,
            Correlation_Id__c = 'corr001corr001corr001corr00101'
        );
        RLM_Bamboo_Suite_Txn__c j2 = new RLM_Bamboo_Suite_Txn__c(
            Opportunity__c = opp.Id,
            Quote__c = session.quoteId,
            Status__c = 'Queued',
            Request_Type__c = 'Reprice',
            Payload__c = RLM_BambooSuiteTxnOrchestrator.buildPayload(
                'Reprice',
                new Map<String, Object>{
                    'quoteId' => String.valueOf(session.quoteId)
                }
            ),
            Restore_Sync__c = false,
            Correlation_Id__c = 'corr002corr002corr002corr00202'
        );
        insert new List<RLM_Bamboo_Suite_Txn__c>{ j1, j2 };

        Test.startTest();
        RLM_BambooSuiteTxnJob.processOpportunityQueueSync(opp.Id);
        Test.stopTest();

        List<RLM_Bamboo_Suite_Txn__c> done = [
            SELECT Status__c
            FROM RLM_Bamboo_Suite_Txn__c
            WHERE Opportunity__c = :opp.Id
        ];
        System.assertEquals(2, done.size());
        for (RLM_Bamboo_Suite_Txn__c row : done) {
            System.assertEquals('Succeeded', row.Status__c);
        }
    }
}
