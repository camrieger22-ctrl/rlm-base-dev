@IsTest
private class RLM_MCP_FindOpenQuotesTest {
    @TestSetup
    static void setup() {
        update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
        Account acme = new Account(Name = 'MCP Open Quotes Acme');
        insert acme;
        Opportunity opp = new Opportunity(
            Name = 'Claude Email Test 4',
            AccountId = acme.Id,
            StageName = 'Proposal/Quote',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        insert new List<Quote>{
            new Quote(
                Name = 'Acme Quote Request - 12 Months',
                OpportunityId = opp.Id,
                Pricebook2Id = Test.getStandardPricebookId(),
                Status = 'Draft'
            ),
            new Quote(
                Name = 'Older Draft',
                OpportunityId = opp.Id,
                Pricebook2Id = Test.getStandardPricebookId(),
                Status = 'Draft'
            )
        };
    }

    private static RLM_MCP_FindOpenQuotes.FindOutput run(String accountName) {
        RLM_MCP_FindOpenQuotes.FindInput input = new RLM_MCP_FindOpenQuotes.FindInput();
        input.accountName = accountName;
        return RLM_MCP_FindOpenQuotes.findOpenQuotes(
            new List<RLM_MCP_FindOpenQuotes.FindInput>{ input }
        )[0];
    }

    @IsTest
    static void requiresAccountName() {
        RLM_MCP_FindOpenQuotes.FindOutput out = run(null);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('Account name'), '' + out.errorMessage);
    }

    @IsTest
    static void listsDraftQuotes() {
        Test.startTest();
        RLM_MCP_FindOpenQuotes.FindOutput out = run('MCP Open Quotes Acme');
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, '' + out.errorMessage);
        System.assertEquals(2, out.quoteCount);
        System.assert(out.summaryDisplay.contains('Acme Quote Request - 12 Months'), '' + out.summaryDisplay);
        System.assert(out.summaryDisplay.contains('Claude Email Test 4'), '' + out.summaryDisplay);
        System.assertNotEquals(null, out.latestQuoteId);
    }

    @IsTest
    static void unknownAccount() {
        RLM_MCP_FindOpenQuotes.FindOutput out = run('No Such Account XYZ');
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('No account matched'), '' + out.errorMessage);
    }
}
