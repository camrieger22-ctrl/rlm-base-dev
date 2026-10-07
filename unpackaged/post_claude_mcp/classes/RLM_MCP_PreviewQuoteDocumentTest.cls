@IsTest
private class RLM_MCP_PreviewQuoteDocumentTest {
    private class FakeStarter implements RLM_MCP_PreviewQuoteDocument.ProcessStarter {
        Id processId;
        String errorMessage;
        Integer calls = 0;
        FakeStarter(Id processId) {
            this.processId = processId;
        }
        public RLM_MCP_PreviewQuoteDocument.StartResult start(
            Id quoteId,
            Id templateId,
            String title
        ) {
            calls++;
            return new RLM_MCP_PreviewQuoteDocument.StartResult(processId, errorMessage);
        }
    }

    @TestSetup
    static void setup() {
        Id pbId = Test.getStandardPricebookId();
        update new Pricebook2(Id = pbId, IsActive = true);
        Account acct = new Account(Name = 'Zephyr Preview Co');
        insert acct;
        Opportunity opp = new Opportunity(
            Name = 'Zephyr Preview Opp',
            AccountId = acct.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Product2 product = new Product2(
            Name = 'Zephyr Preview Widget',
            StockKeepingUnit = 'ZPREV-WIDGET',
            IsActive = true
        );
        insert product;
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = pbId,
            Product2Id = product.Id,
            UnitPrice = 100,
            IsActive = true
        );
        insert pbe;
        Quote priced = new Quote(
            Name = 'Zephyr Preview Priced',
            OpportunityId = opp.Id,
            Pricebook2Id = pbId,
            Status = 'Draft'
        );
        Quote sibling = new Quote(
            Name = 'Zephyr Preview Sibling',
            OpportunityId = opp.Id,
            Pricebook2Id = pbId,
            Status = 'Draft'
        );
        Quote emptyQ = new Quote(
            Name = 'Zephyr Preview Empty',
            OpportunityId = opp.Id,
            Pricebook2Id = pbId,
            Status = 'Draft'
        );
        insert new List<Quote>{ priced, sibling, emptyQ };
        insert new List<QuoteLineItem>{
            new QuoteLineItem(
                QuoteId = priced.Id,
                PricebookEntryId = pbe.Id,
                Product2Id = product.Id,
                Quantity = 2,
                UnitPrice = 100
            ),
            new QuoteLineItem(
                QuoteId = sibling.Id,
                PricebookEntryId = pbe.Id,
                Product2Id = product.Id,
                Quantity = 1,
                UnitPrice = 100
            )
        };
        insert new List<DocumentTemplate>{
            new DocumentTemplate(
                Name = 'ZMCP_Preview_Proposal',
                Type = 'MicrosoftWord',
                TokenMappingType = 'JSON',
                TokenMappingMethodType = 'OmniDataTransform',
                Status = 'Active',
                IsActive = true
            ),
            new DocumentTemplate(
                Name = 'ZMCP_Preview_Draft',
                Type = 'MicrosoftWord',
                TokenMappingType = 'JSON',
                TokenMappingMethodType = 'OmniDataTransform',
                Status = 'Draft',
                IsActive = false
            )
        };
    }

    private static RLM_MCP_PreviewQuoteDocument.PreviewOutput run(
        RLM_MCP_PreviewQuoteDocument.PreviewInput input
    ) {
        return RLM_MCP_PreviewQuoteDocument.preview(
            new List<RLM_MCP_PreviewQuoteDocument.PreviewInput>{ input }
        )[0];
    }

    private static Quote pricedQuote() {
        return [SELECT Id FROM Quote WHERE Name = 'Zephyr Preview Priced'];
    }

    private static DocumentTemplate activeTemplate() {
        return [SELECT Id FROM DocumentTemplate WHERE Name = 'ZMCP_Preview_Proposal'];
    }

    private static ContentVersion insertFile(String title, String fileName) {
        ContentVersion cv = new ContentVersion(
            Title = title,
            PathOnClient = fileName,
            VersionData = Blob.valueOf('unit-test-file'),
            ContentLocation = 'S'
        );
        insert cv;
        return [
            SELECT Id, FileType, ContentDocumentId
            FROM ContentVersion
            WHERE Id = :cv.Id
        ];
    }

    private static DocumentGenerationProcess insertProcess(
        Id quoteId,
        Id templateId,
        String status,
        String responseText
    ) {
        ContentVersion templateBin = insertFile('ZMCP Template Bin', 'template.docx');
        DocumentGenerationProcess dgp = new DocumentGenerationProcess();
        dgp.Type = 'GenerateAndConvert';
        dgp.ReferenceObject = String.valueOf(quoteId);
        dgp.DocumentTemplateId = templateId;
        dgp.DocumentInputType = 'DocumentTemplate';
        dgp.DocGenApiVersionType = 'Advanced';
        dgp.Status = status;
        dgp.RequestText = JSON.serialize(
            new Map<String, Object>{
                'templateContentVersionId' => String.valueOf(templateBin.Id),
                'title' => 'ZMCP Preview'
            }
        );
        dgp.ResponseText = responseText;
        insert dgp;
        return dgp;
    }

    @IsTest
    static void emptyInputIsEmpty() {
        System.assertEquals(0, RLM_MCP_PreviewQuoteDocument.preview(null).size());
        System.assertEquals(
            0,
            RLM_MCP_PreviewQuoteDocument.preview(
                new List<RLM_MCP_PreviewQuoteDocument.PreviewInput>()
            ).size()
        );
    }

    @IsTest
    static void missingIdentity() {
        RLM_MCP_PreviewQuoteDocument.PreviewOutput out =
            run(new RLM_MCP_PreviewQuoteDocument.PreviewInput());
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('quote name'), out.errorMessage);
    }

    @IsTest
    static void invalidQuoteId() {
        RLM_MCP_PreviewQuoteDocument.PreviewInput input =
            new RLM_MCP_PreviewQuoteDocument.PreviewInput();
        input.quoteId = 'not-an-id';
        RLM_MCP_PreviewQuoteDocument.PreviewOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.startsWith('Invalid Quote Id'), out.errorMessage);
    }

    @IsTest
    static void noMatch() {
        RLM_MCP_PreviewQuoteDocument.PreviewInput input =
            new RLM_MCP_PreviewQuoteDocument.PreviewInput();
        input.quoteName = 'No Such Quote XYZ';
        RLM_MCP_PreviewQuoteDocument.PreviewOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.startsWith('No quote found'), out.errorMessage);
    }

    @IsTest
    static void emptyQuoteRejected() {
        RLM_MCP_PreviewQuoteDocument.PreviewInput input =
            new RLM_MCP_PreviewQuoteDocument.PreviewInput();
        input.quoteName = 'Zephyr Preview Empty';
        input.templateName = 'ZMCP_Preview_Proposal';
        RLM_MCP_PreviewQuoteDocument.PreviewOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('no lines'), out.errorMessage);
    }

    @IsTest
    static void disambiguatesMultiple() {
        RLM_MCP_PreviewQuoteDocument.PreviewInput input =
            new RLM_MCP_PreviewQuoteDocument.PreviewInput();
        input.quoteName = 'Zephyr Preview';
        RLM_MCP_PreviewQuoteDocument.PreviewOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assertEquals(true, out.needsDisambiguation);
        System.assert(
            out.candidateSummariesDisplay.contains('Zephyr Preview Priced'),
            out.candidateSummariesDisplay
        );
    }

    @IsTest
    static void inactiveTemplateRejected() {
        RLM_MCP_PreviewQuoteDocument.PreviewInput input =
            new RLM_MCP_PreviewQuoteDocument.PreviewInput();
        input.quoteName = 'Zephyr Preview Priced';
        input.templateName = 'ZMCP_Preview_Draft';
        RLM_MCP_PreviewQuoteDocument.PreviewOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('not Active'), out.errorMessage);
    }

    @IsTest
    static void unknownTemplateRejected() {
        RLM_MCP_PreviewQuoteDocument.PreviewInput input =
            new RLM_MCP_PreviewQuoteDocument.PreviewInput();
        input.quoteName = 'Zephyr Preview Priced';
        input.templateName = 'No Such Template';
        RLM_MCP_PreviewQuoteDocument.PreviewOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('No document template'), out.errorMessage);
    }

    @IsTest
    static void pendingPdfReturnsPartial() {
        Quote q = pricedQuote();
        DocumentTemplate dt = activeTemplate();
        DocumentGenerationProcess dgp = insertProcess(q.Id, dt.Id, 'Success', null);
        RLM_MCP_PreviewQuoteDocument.PreviewInput input =
            new RLM_MCP_PreviewQuoteDocument.PreviewInput();
        input.quoteId = String.valueOf(q.Id);
        input.templateName = 'ZMCP_Preview_Proposal';
        input.documentGenerationProcessId = String.valueOf(dgp.Id);
        Test.startTest();
        RLM_MCP_PreviewQuoteDocument.PreviewOutput out = run(input);
        Test.stopTest();

        String dump = 'success=' + out.isSuccess + ' partial=' + out.isPartial
            + ' err=' + out.errorMessage + ' msg=' + out.message;
        Assert.isTrue(out.isSuccess == true, dump);
        Assert.isTrue(out.isPartial == true, dump);
        Assert.areEqual(String.valueOf(dgp.Id), out.documentGenerationProcessId);
        Assert.isTrue(out.message.contains('RETRY_NOW'), dump);
        Assert.isTrue(out.message.contains(String.valueOf(q.Id)), dump);
        Assert.isTrue(out.message.contains(String.valueOf(dgp.Id)), dump);
    }

    @IsTest
    static void reuseExistingPdfSkipsStart() {
        Quote q = pricedQuote();
        DocumentTemplate dt = activeTemplate();
        ContentVersion cv = insertFile('ZMCP Preview PDF', 'preview.pdf');
        DocumentGenerationProcess dgp = insertProcess(
            q.Id,
            dt.Id,
            'Success',
            String.valueOf(cv.Id)
        );
        FakeStarter fake = new FakeStarter(dgp.Id);
        RLM_MCP_PreviewQuoteDocument.starter = fake;

        RLM_MCP_PreviewQuoteDocument.PreviewInput input =
            new RLM_MCP_PreviewQuoteDocument.PreviewInput();
        input.quoteId = String.valueOf(q.Id);
        input.templateName = 'ZMCP_Preview_Proposal';
        Test.startTest();
        RLM_MCP_PreviewQuoteDocument.PreviewOutput out = run(input);
        Test.stopTest();

        Assert.isTrue(out.isSuccess == true, String.valueOf(out.errorMessage) + ' ' + out.message);
        Assert.isTrue(out.isPartial != true, out.message);
        Assert.isTrue(
            out.pdfUrl != null && out.pdfUrl.contains('/lightning/r/ContentDocument/'),
            String.valueOf(out.pdfUrl)
        );
        Assert.isTrue(out.message.contains('Open PDF'), out.message);
        Assert.isTrue(out.message.contains('Open Quote'), out.message);
        Assert.areEqual(String.valueOf(cv.ContentDocumentId), out.contentDocumentId);
        Assert.areEqual(String.valueOf(dgp.Id), out.documentGenerationProcessId);
        Assert.areEqual(0, fake.calls);
    }

    @IsTest
    static void startWhenNoCachedPdfReturnsPartialWithoutPolling() {
        Quote q = pricedQuote();
        DocumentTemplate dt = activeTemplate();
        DocumentGenerationProcess dgp = insertProcess(q.Id, dt.Id, 'Success', null);
        FakeStarter fake = new FakeStarter(dgp.Id);
        RLM_MCP_PreviewQuoteDocument.starter = fake;

        RLM_MCP_PreviewQuoteDocument.PreviewInput input =
            new RLM_MCP_PreviewQuoteDocument.PreviewInput();
        input.quoteId = String.valueOf(q.Id);
        input.templateName = 'ZMCP_Preview_Proposal';
        Test.startTest();
        RLM_MCP_PreviewQuoteDocument.PreviewOutput out = run(input);
        Test.stopTest();

        String dump = 'success=' + out.isSuccess + ' partial=' + out.isPartial
            + ' err=' + out.errorMessage + ' msg=' + out.message;
        Assert.isTrue(out.isSuccess == true, dump);
        Assert.isTrue(out.isPartial == true, dump);
        Assert.areEqual(1, fake.calls);
        Assert.areEqual(String.valueOf(dgp.Id), out.documentGenerationProcessId);
        Assert.isTrue(out.message.contains('RETRY_NOW'), dump);
    }

    @IsTest
    static void successReturnsPdfLinkWhenProcessIdPassed() {
        Quote q = pricedQuote();
        DocumentTemplate dt = activeTemplate();
        ContentVersion cv = insertFile('ZMCP Preview PDF', 'preview.pdf');
        DocumentGenerationProcess dgp = insertProcess(
            q.Id,
            dt.Id,
            'Success',
            String.valueOf(cv.Id)
        );

        RLM_MCP_PreviewQuoteDocument.PreviewInput input =
            new RLM_MCP_PreviewQuoteDocument.PreviewInput();
        input.quoteId = String.valueOf(q.Id);
        input.templateName = 'ZMCP_Preview_Proposal';
        input.documentGenerationProcessId = String.valueOf(dgp.Id);
        Test.startTest();
        RLM_MCP_PreviewQuoteDocument.PreviewOutput out = run(input);
        Test.stopTest();

        Assert.isTrue(out.isSuccess == true, String.valueOf(out.errorMessage) + ' ' + out.message);
        Assert.isTrue(out.isPartial != true, out.message);
        Assert.isTrue(
            out.pdfUrl != null && out.pdfUrl.contains('/lightning/r/ContentDocument/'),
            String.valueOf(out.pdfUrl)
        );
        Assert.isTrue(out.message.contains('Open PDF'), out.message);
        Assert.areEqual(String.valueOf(cv.ContentDocumentId), out.contentDocumentId);
    }

    @IsTest
    static void failedProcessSurfacesError() {
        Quote q = pricedQuote();
        DocumentTemplate dt = activeTemplate();
        DocumentGenerationProcess dgp = insertProcess(
            q.Id,
            dt.Id,
            'Failure',
            'template binary missing'
        );

        RLM_MCP_PreviewQuoteDocument.PreviewInput input =
            new RLM_MCP_PreviewQuoteDocument.PreviewInput();
        input.quoteId = String.valueOf(q.Id);
        input.templateName = 'ZMCP_Preview_Proposal';
        input.documentGenerationProcessId = String.valueOf(dgp.Id);
        RLM_MCP_PreviewQuoteDocument.PreviewOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('template binary missing'), out.errorMessage);
    }
}
