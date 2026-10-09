@IsTest
private class RLM_MCP_CreateProspectTest {
    private static RLM_MCP_CreateProspect.ProspectOutput run(
        RLM_MCP_CreateProspect.ProspectInput input
    ) {
        return RLM_MCP_CreateProspect.createProspect(
            new List<RLM_MCP_CreateProspect.ProspectInput>{ input }
        )[0];
    }

    @IsTest
    static void requiresAccountName() {
        RLM_MCP_CreateProspect.ProspectOutput out =
            run(new RLM_MCP_CreateProspect.ProspectInput());
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('Account name'), '' + out.errorMessage);
    }

    @IsTest
    static void createsAccountAndContact() {
        RLM_MCP_CreateProspect.ProspectInput input =
            new RLM_MCP_CreateProspect.ProspectInput();
        input.accountName = 'MCP Prospect Northwind';
        input.contactFirstName = 'Jane';
        input.contactLastName = 'Doe';
        input.contactEmail = 'jane.doe.mcp@example.com';

        Test.startTest();
        RLM_MCP_CreateProspect.ProspectOutput out = run(input);
        Test.stopTest();

        System.assertEquals(true, out.isSuccess, '' + out.errorMessage);
        System.assertEquals(true, out.accountCreated);
        System.assertEquals(true, out.contactCreated);
        System.assertEquals(
            1,
            [SELECT COUNT() FROM Account WHERE Name = 'MCP Prospect Northwind']
        );
        Contact created = [
            SELECT Email, AccountId FROM Contact WHERE Id = :out.contactId
        ];
        System.assertEquals('jane.doe.mcp@example.com', created.Email);
        System.assertEquals(out.accountId, String.valueOf(created.AccountId));
        System.assert(out.resultsDisplay.contains('Created account'), '' + out.resultsDisplay);
    }

    @IsTest
    static void reusesExactAccount() {
        insert new Account(Name = 'MCP Prospect Reuse Co');
        RLM_MCP_CreateProspect.ProspectInput input =
            new RLM_MCP_CreateProspect.ProspectInput();
        input.accountName = 'MCP Prospect Reuse Co';
        input.contactEmail = 'reuse.mcp@example.com';
        input.contactLastName = 'Reuse';

        Test.startTest();
        RLM_MCP_CreateProspect.ProspectOutput out = run(input);
        Test.stopTest();

        System.assertEquals(true, out.isSuccess, '' + out.errorMessage);
        System.assertEquals(false, out.accountCreated);
        System.assertEquals(true, out.contactCreated);
        System.assertEquals(
            1,
            [SELECT COUNT() FROM Account WHERE Name = 'MCP Prospect Reuse Co']
        );
        System.assert(out.resultsDisplay.contains('Reused account'), '' + out.resultsDisplay);
    }

    @IsTest
    static void asksBeforeFuzzyCreate() {
        insert new Account(Name = 'MCP Prospect Similar Holdings');
        RLM_MCP_CreateProspect.ProspectInput input =
            new RLM_MCP_CreateProspect.ProspectInput();
        input.accountName = 'MCP Prospect Similar';

        RLM_MCP_CreateProspect.ProspectOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assertEquals(true, out.needsDisambiguation);
        System.assertEquals(
            1,
            [SELECT COUNT() FROM Account WHERE Name LIKE 'MCP Prospect Similar%']
        );
    }
}
