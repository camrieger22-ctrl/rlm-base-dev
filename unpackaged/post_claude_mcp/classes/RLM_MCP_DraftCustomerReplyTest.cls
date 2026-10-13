@IsTest
private class RLM_MCP_DraftCustomerReplyTest {
    @TestSetup
    static void setup() {
        Id pbId = Test.getStandardPricebookId();
        update new Pricebook2(Id = pbId, IsActive = true);
        Account account = new Account(Name = 'MCP Reply Acme');
        insert account;
        Contact contact = new Contact(
            FirstName = 'Dana',
            LastName = 'Rivera',
            AccountId = account.Id,
            Email = 'dana.rivera@example.com'
        );
        insert contact;
        Opportunity opp = new Opportunity(
            Name = 'MCP Reply Opp',
            AccountId = account.Id,
            StageName = 'Proposal/Quote',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Product2 parent = new Product2(
            Name = 'QuantumBit Database',
            StockKeepingUnit = 'ZMCP-RPL-DB',
            IsActive = true
        );
        insert parent;
        insert new PricebookEntry(
            Pricebook2Id = pbId, Product2Id = parent.Id, UnitPrice = 12000, IsActive = true
        );
        Quote quote = new Quote(
            Name = 'MCP Reply Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = pbId,
            Status = 'Draft',
            ContactId = contact.Id,
            StartDate = Date.newInstance(2026, 10, 1),
            EndDate = Date.newInstance(2028, 10, 1)
        );
        insert quote;
        Id parentPbe = [
            SELECT Id FROM PricebookEntry WHERE Product2Id = :parent.Id LIMIT 1
        ].Id;
        insert new QuoteLineItem(
            QuoteId = quote.Id,
            PricebookEntryId = parentPbe,
            Product2Id = parent.Id,
            Quantity = 10,
            UnitPrice = 12000,
            Discount = 20
        );
        ContentVersion pdf = new ContentVersion(
            Title = 'MCP Reply Proposal',
            PathOnClient = 'mcp-reply-proposal.pdf',
            VersionData = Blob.valueOf('%PDF-1.4 test'),
            IsMajorVersion = true
        );
        insert pdf;
        Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :pdf.Id].ContentDocumentId;
        insert new ContentDocumentLink(
            LinkedEntityId = quote.Id,
            ContentDocumentId = docId,
            ShareType = 'V',
            Visibility = 'AllUsers'
        );
    }

    private static RLM_MCP_DraftCustomerReply.ReplyOutput run(
        RLM_MCP_DraftCustomerReply.ReplyInput input
    ) {
        return RLM_MCP_DraftCustomerReply.draft(
            new List<RLM_MCP_DraftCustomerReply.ReplyInput>{ input }
        )[0];
    }

    @IsTest
    static void requiresIdentity() {
        RLM_MCP_DraftCustomerReply.ReplyOutput out =
            run(new RLM_MCP_DraftCustomerReply.ReplyInput());
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('quoteId'), '' + out.errorMessage);
    }

    @IsTest
    static void draftsCustomerSafeBody() {
        Id quoteId = [SELECT Id FROM Quote WHERE Name = 'MCP Reply Quote'].Id;
        RLM_MCP_DraftCustomerReply.ReplyInput input =
            new RLM_MCP_DraftCustomerReply.ReplyInput();
        input.quoteId = String.valueOf(quoteId);
        input.purpose = 'follow-up';
        Test.startTest();
        RLM_MCP_DraftCustomerReply.ReplyOutput out = run(input);
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, '' + out.errorMessage);
        System.assertEquals(
            'MCP Reply Acme — 24-month proposal',
            out.subject,
            '' + out.subject
        );
        System.assert(out.bodyDisplay.contains('Hi Dana,'), '' + out.bodyDisplay);
        System.assert(out.bodyDisplay.contains('24-month proposal'), '' + out.bodyDisplay);
        System.assert(out.bodyDisplay.contains('QuantumBit Database (10) — $'), '' + out.bodyDisplay);
        System.assert(out.bodyDisplay.contains('20% applied to the subscription lines'), '' + out.bodyDisplay);
        System.assert(out.bodyDisplay.contains('October 1, 2026'), '' + out.bodyDisplay);
        System.assert(out.bodyDisplay.contains('Best regards,'), '' + out.bodyDisplay);
        System.assert(!out.bodyDisplay.contains('has not been sent'), '' + out.bodyDisplay);
        System.assert(!out.bodyDisplay.contains('/lightning/r/'), '' + out.bodyDisplay);
        System.assert(
            out.bodyDisplay.contains('proposal PDF (attached)')
                || (out.bodyDisplay.contains('<a href=')
                    && out.bodyDisplay.contains('>proposal PDF</a>')),
            '' + out.bodyDisplay
        );
        System.assert(out.coachDisplay.contains('has not been sent'), '' + out.coachDisplay);
        System.assert(out.coachDisplay.contains('Open Quote'), '' + out.coachDisplay);
        System.assert(out.coachDisplay.contains('Open PDF'), '' + out.coachDisplay);
        System.assert(out.coachDisplay.contains('Do not preview'), '' + out.coachDisplay);
        System.assert(String.isNotBlank(out.quoteUrl), '' + out.quoteUrl);
        System.assert(out.quoteUrl.contains('/lightning/r/Quote/'), '' + out.quoteUrl);
    }

    @IsTest
    static void publicLinkUsesLatestPdfAfterQuoteEdit() {
        Quote quote = [SELECT Id, Name FROM Quote WHERE Name = 'MCP Reply Quote' LIMIT 1];
        quote.Name = 'MCP Reply Quote Edited';
        update quote;
        RLM_MCP_DraftCustomerReply.ReplyInput input =
            new RLM_MCP_DraftCustomerReply.ReplyInput();
        input.quoteId = String.valueOf(quote.Id);
        Test.startTest();
        RLM_MCP_DraftCustomerReply.ReplyOutput out = run(input);
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, '' + out.errorMessage);
        System.assert(String.isNotBlank(out.pdfUrl), '' + out.pdfUrl);
        System.assert(
            out.bodyDisplay.contains('proposal PDF (attached)')
                || (out.bodyDisplay.contains('<a href=')
                    && out.bodyDisplay.contains('>proposal PDF</a>')),
            '' + out.bodyDisplay
        );
        System.assert(!out.bodyDisplay.contains('/lightning/r/'), '' + out.bodyDisplay);
        System.assert(out.coachDisplay.contains('Do not preview'), '' + out.coachDisplay);
    }

    @IsTest
    static void disambiguatesMatchingQuotes() {
        Quote original = [
            SELECT OpportunityId, Pricebook2Id, AccountId, ContactId
            FROM Quote
            WHERE Name = 'MCP Reply Quote'
            LIMIT 1
        ];
        insert new Quote(
            Name = 'MCP Reply Quote Twin',
            OpportunityId = original.OpportunityId,
            Pricebook2Id = original.Pricebook2Id,
            Status = 'Draft'
        );
        RLM_MCP_DraftCustomerReply.ReplyInput input =
            new RLM_MCP_DraftCustomerReply.ReplyInput();
        input.accountName = 'MCP Reply Acme';
        Test.startTest();
        RLM_MCP_DraftCustomerReply.ReplyOutput out = run(input);
        Test.stopTest();
        System.assertEquals(false, out.isSuccess);
        System.assertEquals(true, out.needsDisambiguation);
        System.assert(out.candidateSummariesDisplay.contains('MCP Reply Quote'), '' + out.candidateSummariesDisplay);
    }
}
