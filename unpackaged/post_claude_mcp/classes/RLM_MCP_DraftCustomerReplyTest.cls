@IsTest
private class RLM_MCP_DraftCustomerReplyTest {
    @TestSetup
    static void setup() {
        Id pbId = Test.getStandardPricebookId();
        update new Pricebook2(Id = pbId, IsActive = true);
        Account account = new Account(Name = 'MCP Reply Acme');
        insert account;
        Opportunity opp = new Opportunity(
            Name = 'MCP Reply Opp',
            AccountId = account.Id,
            StageName = 'Proposal/Quote',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Product2 product = new Product2(
            Name = 'QuantumBit Database',
            StockKeepingUnit = 'ZMCP-RPL-DB',
            IsActive = true
        );
        insert product;
        insert new PricebookEntry(
            Pricebook2Id = pbId, Product2Id = product.Id, UnitPrice = 12000, IsActive = true
        );
        Quote quote = new Quote(
            Name = 'MCP Reply Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = pbId,
            Status = 'Draft'
        );
        insert quote;
        Id pbeId = [SELECT Id FROM PricebookEntry WHERE Product2Id = :product.Id].Id;
        insert new QuoteLineItem(
            QuoteId = quote.Id,
            PricebookEntryId = pbeId,
            Product2Id = product.Id,
            Quantity = 10,
            UnitPrice = 12000,
            Discount = 20
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
    static void draftsUnsentBody() {
        Id quoteId = [SELECT Id FROM Quote WHERE Name = 'MCP Reply Quote'].Id;
        RLM_MCP_DraftCustomerReply.ReplyInput input =
            new RLM_MCP_DraftCustomerReply.ReplyInput();
        input.quoteId = String.valueOf(quoteId);
        input.purpose = 'follow-up';
        Test.startTest();
        RLM_MCP_DraftCustomerReply.ReplyOutput out = run(input);
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, '' + out.errorMessage);
        System.assert(out.bodyDisplay.contains('QuantumBit Database'), '' + out.bodyDisplay);
        System.assert(out.bodyDisplay.contains('has not been sent'), '' + out.bodyDisplay);
        System.assert(out.bodyDisplay.contains('20% off'), '' + out.bodyDisplay);
        System.assert(out.subject.contains('MCP Reply Quote'), '' + out.subject);
    }
}
