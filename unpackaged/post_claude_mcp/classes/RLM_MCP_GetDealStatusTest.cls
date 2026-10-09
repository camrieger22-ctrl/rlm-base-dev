@IsTest
private class RLM_MCP_GetDealStatusTest {
    @TestSetup
    static void setup() {
        update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
        Account account = new Account(Name = 'MCP Deal Status Acme');
        insert account;
        Opportunity opp = new Opportunity(
            Name = 'MCP Deal Status Opp',
            AccountId = account.Id,
            StageName = 'Proposal/Quote',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        insert new Quote(
            Name = 'MCP Deal Status Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft'
        );
    }

    private static RLM_MCP_GetDealStatus.StatusOutput run(
        RLM_MCP_GetDealStatus.StatusInput input
    ) {
        return RLM_MCP_GetDealStatus.getStatus(
            new List<RLM_MCP_GetDealStatus.StatusInput>{ input }
        )[0];
    }

    @IsTest
    static void requiresIdentity() {
        RLM_MCP_GetDealStatus.StatusOutput out =
            run(new RLM_MCP_GetDealStatus.StatusInput());
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('quoteId'), '' + out.errorMessage);
    }

    @IsTest
    static void recapsDraftQuote() {
        Id quoteId = [SELECT Id FROM Quote WHERE Name = 'MCP Deal Status Quote'].Id;
        RLM_MCP_GetDealStatus.StatusInput input = new RLM_MCP_GetDealStatus.StatusInput();
        input.quoteId = String.valueOf(quoteId);
        Test.startTest();
        RLM_MCP_GetDealStatus.StatusOutput out = run(input);
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, '' + out.errorMessage);
        System.assertEquals('Draft quote', out.stage);
        System.assert(out.summaryDisplay.contains('Approval: None'), '' + out.summaryDisplay);
        System.assert(out.summaryDisplay.contains('None yet'), '' + out.summaryDisplay);
    }
}
