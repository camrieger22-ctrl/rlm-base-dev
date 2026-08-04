@isTest
private class RLM_AI_PartnershipDocsServiceTest {

    private static void resetSeams() {
        RLM_AI_GeneratePartnershipDocsService.skipDocumentCreate = false;
        RLM_AI_GeneratePartnershipDocsService.templateIdByNameOverride = null;
    }

    @isTest
    static void generateRejectsBlankQuoteId() {
        resetSeams();
        RLM_AI_GeneratePartnershipDocsService.GenerateInput input =
            new RLM_AI_GeneratePartnershipDocsService.GenerateInput();
        input.quoteId = '';
        input.documentType = 'both';

        List<RLM_AI_GeneratePartnershipDocsService.GenerateOutput> results =
            RLM_AI_GeneratePartnershipDocsService.generate(
                new List<RLM_AI_GeneratePartnershipDocsService.GenerateInput>{ input }
            );

        System.assertEquals(false, results[0].isSuccess);
        System.assert(results[0].errorMessage.contains('Quote Id is required'));
    }

    @isTest
    static void generateRejectsBadDocumentType() {
        resetSeams();
        Quote q = createQuote('DocGen Bad Type');

        RLM_AI_GeneratePartnershipDocsService.GenerateInput input =
            new RLM_AI_GeneratePartnershipDocsService.GenerateInput();
        input.quoteId = String.valueOf(q.Id);
        input.documentType = 'invoice';

        List<RLM_AI_GeneratePartnershipDocsService.GenerateOutput> results =
            RLM_AI_GeneratePartnershipDocsService.generate(
                new List<RLM_AI_GeneratePartnershipDocsService.GenerateInput>{ input }
            );

        System.assertEquals(false, results[0].isSuccess);
        System.assert(results[0].errorMessage.contains('proposal, deck, or both'));
    }

    @isTest
    static void generateQueuesBothWithTestSeams() {
        resetSeams();
        Quote q = createQuote('DocGen Both');
        RLM_AI_GeneratePartnershipDocsService.skipDocumentCreate = true;
        RLM_AI_GeneratePartnershipDocsService.templateIdByNameOverride = new Map<String, Id>{
            RLM_AI_GeneratePartnershipDocsService.TEMPLATE_PROPOSAL => q.Id,
            RLM_AI_GeneratePartnershipDocsService.TEMPLATE_DECK => q.Id
        };

        RLM_AI_GeneratePartnershipDocsService.GenerateInput input =
            new RLM_AI_GeneratePartnershipDocsService.GenerateInput();
        input.quoteId = String.valueOf(q.Id);
        input.documentType = 'both';

        Test.startTest();
        List<RLM_AI_GeneratePartnershipDocsService.GenerateOutput> results =
            RLM_AI_GeneratePartnershipDocsService.generate(
                new List<RLM_AI_GeneratePartnershipDocsService.GenerateInput>{ input }
            );
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Expected one generate result');
        System.assertEquals(
            true,
            results[0].isSuccess,
            'Expected success but got: ' + String.valueOf(results[0].errorMessage)
        );
        System.assert(results[0].resultDisplay.contains('Word proposal'));
        System.assert(results[0].resultDisplay.contains('PowerPoint deck'));
        System.assert(results[0].resultDisplay.contains('Queued Advanced DocGen'));
        System.assert(!results[0].resultDisplay.contains(String.valueOf(q.Id)));
    }

    @isTest
    static void generateReportsMissingTemplates() {
        resetSeams();
        Quote q = createQuote('DocGen Missing Tmpl');
        RLM_AI_GeneratePartnershipDocsService.skipDocumentCreate = true;
        RLM_AI_GeneratePartnershipDocsService.templateIdByNameOverride = new Map<String, Id>();

        RLM_AI_GeneratePartnershipDocsService.GenerateInput input =
            new RLM_AI_GeneratePartnershipDocsService.GenerateInput();
        input.quoteId = String.valueOf(q.Id);
        input.documentType = 'proposal';

        List<RLM_AI_GeneratePartnershipDocsService.GenerateOutput> results =
            RLM_AI_GeneratePartnershipDocsService.generate(
                new List<RLM_AI_GeneratePartnershipDocsService.GenerateInput>{ input }
            );

        System.assertEquals(false, results[0].isSuccess);
        System.assert(results[0].errorMessage.contains('not found'));
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
