@IsTest
private class RLM_MCP_DealResolverTest {
    @TestSetup
    static void setup() {
        update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
        Account account = new Account(Name = 'MCP Resolver Acme');
        insert account;
        insert new List<Opportunity>{
            new Opportunity(
                Name = 'Claude Email Test',
                AccountId = account.Id,
                StageName = 'Proposal/Quote',
                CloseDate = Date.today().addDays(30)
            ),
            new Opportunity(
                Name = 'Other Acme Deal',
                AccountId = account.Id,
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(45)
            )
        };
        Opportunity named = [
            SELECT Id FROM Opportunity WHERE Name = 'Claude Email Test' LIMIT 1
        ];
        insert new Quote(
            Name = 'Claude Email Test',
            OpportunityId = named.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft'
        );
    }

    @IsTest
    static void resolve_namedOppReusesMatchingDraft() {
        RLM_MCP_DealResolver.Result out = RLM_MCP_DealResolver.resolve(
            'MCP Resolver Acme',
            'Claude Email Test',
            'Claude Email Test'
        );
        System.assertNotEquals(null, out.account);
        System.assertNotEquals(null, out.opportunity);
        System.assertEquals('Claude Email Test', out.opportunity.Name);
        System.assertNotEquals(null, out.draft);
        System.assertEquals('Claude Email Test', out.draft.Name);
        System.assertEquals(false, out.needsDisambiguation);
    }

    @IsTest
    static void resolve_blankOppNameWithSeveralOppsDisambiguates() {
        RLM_MCP_DealResolver.Result out = RLM_MCP_DealResolver.resolve(
            'MCP Resolver Acme',
            null,
            'Claude Email Test'
        );
        System.assertEquals(true, out.needsDisambiguation);
        System.assert(out.errorMessage.contains('opportunityName'), '' + out.errorMessage);
        System.assertEquals(null, out.draft);
    }

    @IsTest
    static void resolve_newQuoteNameIsNotReusable() {
        RLM_MCP_DealResolver.Result out = RLM_MCP_DealResolver.resolve(
            'MCP Resolver Acme',
            'Claude Email Test',
            'Brand New Option'
        );
        System.assertNotEquals(null, out.opportunity);
        System.assertEquals(null, out.draft);
        System.assertEquals(1, out.drafts.size());
    }

    @IsTest
    static void unknownAccount() {
        RLM_MCP_DealResolver.Result out = RLM_MCP_DealResolver.resolveAccount('No Such Co XYZ');
        System.assertEquals(null, out.account);
        System.assert(out.errorMessage.contains('No account matched'), '' + out.errorMessage);
    }
}
