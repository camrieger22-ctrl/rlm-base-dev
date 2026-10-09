@IsTest
private class RLM_MCP_GetBillingAndUsageTest {
    @TestSetup
    static void setup() {
        insert new Account(Name = 'MCP Billing Acme');
    }

    private static RLM_MCP_GetBillingAndUsage.BillingOutput run(String accountName) {
        RLM_MCP_GetBillingAndUsage.BillingInput input =
            new RLM_MCP_GetBillingAndUsage.BillingInput();
        input.accountName = accountName;
        return RLM_MCP_GetBillingAndUsage.getBilling(
            new List<RLM_MCP_GetBillingAndUsage.BillingInput>{ input }
        )[0];
    }

    @IsTest
    static void requiresAccountName() {
        RLM_MCP_GetBillingAndUsage.BillingOutput out = run(null);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('Account name'), '' + out.errorMessage);
    }

    @IsTest
    static void recapsEmptyBilling() {
        Test.startTest();
        RLM_MCP_GetBillingAndUsage.BillingOutput out = run('MCP Billing Acme');
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, '' + out.errorMessage);
        System.assert(out.summaryDisplay.contains('None scheduled'), '' + out.summaryDisplay);
        System.assert(out.summaryDisplay.contains('No usage summaries'), '' + out.summaryDisplay);
        System.assert(out.summaryDisplay.contains('TCV'), '' + out.summaryDisplay);
    }

    @IsTest
    static void unknownAccount() {
        RLM_MCP_GetBillingAndUsage.BillingOutput out = run('No Such Billing XYZ');
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('No account matched'), '' + out.errorMessage);
    }
}
