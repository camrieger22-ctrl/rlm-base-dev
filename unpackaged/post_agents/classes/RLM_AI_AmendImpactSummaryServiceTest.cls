@isTest
private class RLM_AI_AmendImpactSummaryServiceTest {

    @isTest
    static void summarizeRejectsBlankQuoteId() {
        RLM_AI_AmendImpactSummaryService.SummaryInput input =
            new RLM_AI_AmendImpactSummaryService.SummaryInput();
        input.quoteId = '  ';

        List<RLM_AI_AmendImpactSummaryService.SummaryOutput> results =
            RLM_AI_AmendImpactSummaryService.summarize(
                new List<RLM_AI_AmendImpactSummaryService.SummaryInput>{ input }
            );

        System.assertEquals(false, results[0].isSuccess);
        System.assert(results[0].errorMessage.contains('Quote Id is required'));
    }

    @isTest
    static void summarizeRejectsInvalidQuoteId() {
        RLM_AI_AmendImpactSummaryService.SummaryInput input =
            new RLM_AI_AmendImpactSummaryService.SummaryInput();
        input.quoteId = 'not-an-id';

        List<RLM_AI_AmendImpactSummaryService.SummaryOutput> results =
            RLM_AI_AmendImpactSummaryService.summarize(
                new List<RLM_AI_AmendImpactSummaryService.SummaryInput>{ input }
            );

        System.assertEquals(false, results[0].isSuccess);
        System.assert(results[0].errorMessage.contains('Invalid quote Id'));
    }

    @isTest
    static void summarizeNonAmendQuote() {
        Quote q = createQuote('Non Amend Summary');

        RLM_AI_AmendImpactSummaryService.SummaryInput input =
            new RLM_AI_AmendImpactSummaryService.SummaryInput();
        input.quoteId = String.valueOf(q.Id);

        Test.startTest();
        List<RLM_AI_AmendImpactSummaryService.SummaryOutput> results =
            RLM_AI_AmendImpactSummaryService.summarize(
                new List<RLM_AI_AmendImpactSummaryService.SummaryInput>{ input }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess);
        System.assertEquals(false, results[0].isAmendmentQuote);
        System.assert(results[0].summaryDisplay.contains('does not look like an amendment'));
        System.assert(!results[0].summaryDisplay.contains(String.valueOf(q.Id)));
    }

    @isTest
    static void summarizeAmendViaStampFields() {
        Quote q = createQuote('Amend Stamp Summary');
        q.RLM_Amend_Current_ARR__c = 120000;
        q.RLM_Amend_Current_MRR__c = 10000;
        q.RLM_Amend_Current_Qty__c = 1000;
        q.RLM_Amend_Proposed_ARR__c = 150000;
        q.RLM_Amend_Proposed_MRR__c = 12500;
        q.RLM_Amend_Proposed_Qty__c = 1250;
        q.RLM_Amend_Net_Increase_ARR__c = 30000;
        q.RLM_Amend_Net_Increase_MRR__c = 2500;
        q.RLM_Amend_Net_Increase_Qty__c = 250;
        q.RLM_Amend_This_Add_Prorated__c = 15000;
        update q;

        RLM_AI_AmendImpactSummaryService.SummaryInput input =
            new RLM_AI_AmendImpactSummaryService.SummaryInput();
        input.quoteId = String.valueOf(q.Id);

        Test.startTest();
        List<RLM_AI_AmendImpactSummaryService.SummaryOutput> results =
            RLM_AI_AmendImpactSummaryService.summarize(
                new List<RLM_AI_AmendImpactSummaryService.SummaryInput>{ input }
            );
        Test.stopTest();

        System.assertEquals(true, results[0].isSuccess);
        System.assertEquals(true, results[0].isAmendmentQuote);
        System.assert(results[0].summaryDisplay.contains('Current contract'));
        System.assert(results[0].summaryDisplay.contains('This add'));
        System.assert(results[0].summaryDisplay.contains('Finalized if accepted'));
        System.assert(!results[0].summaryDisplay.contains(String.valueOf(q.Id)));
    }

    @isTest
    static void summarizeReturnsEmptyForNullInputList() {
        System.assertEquals(
            0,
            RLM_AI_AmendImpactSummaryService.summarize(null).size()
        );
    }

    private static Quote createQuote(String name) {
        Account acct = new Account(Name = name + ' Account');
        insert acct;
        Opportunity opp = new Opportunity(
            Name = name + ' Opp',
            AccountId = acct.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Quote q = new Quote(
            Name = name,
            Pricebook2Id = Test.getStandardPricebookId(),
            OpportunityId = opp.Id,
            Status = 'Draft'
        );
        insert q;
        return q;
    }
}
