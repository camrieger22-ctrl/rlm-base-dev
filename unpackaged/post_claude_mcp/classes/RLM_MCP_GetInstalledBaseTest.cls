@IsTest
private class RLM_MCP_GetInstalledBaseTest {
    @TestSetup
    static void setup() {
        Account acme = new Account(Name = 'MCP Installed Acme');
        Account other = new Account(Name = 'MCP Installed Other');
        Account emptyAcct = new Account(Name = 'MCP Installed Empty');
        insert new List<Account>{ acme, other, emptyAcct };
        Product2 database = new Product2(
            Name = 'QuantumBit Database',
            StockKeepingUnit = 'ZMCP-IB-DB',
            IsActive = true
        );
        insert database;
        insert new List<Asset>{
            new Asset(
                Name = 'QuantumBit Database',
                AccountId = acme.Id,
                Product2Id = database.Id,
                Quantity = 1,
                Status = 'Purchased'
            ),
            new Asset(
                Name = 'Other Database',
                AccountId = other.Id,
                Product2Id = database.Id,
                Quantity = 2,
                Status = 'Purchased'
            )
        };
        Asset acmeAsset = [
            SELECT Id FROM Asset WHERE AccountId = :acme.Id LIMIT 1
        ];
        Datetime startAt = Datetime.newInstance(Date.today(), Time.newInstance(0, 0, 0, 0));
        try {
            insert new AssetStatePeriod(
                AssetId = acmeAsset.Id,
                StartDate = startAt,
                EndDate = startAt.addYears(1).addSeconds(-1),
                Quantity = 6,
                Mrr = 5520,
                UnitPrice = 12000,
                Discount = 8
            );
        } catch (Exception e) {
            // Period insert is org-gated; recap still lists the asset.
        }
    }

    private static RLM_MCP_GetInstalledBase.InstalledOutput run(String accountName) {
        RLM_MCP_GetInstalledBase.InstalledInput input =
            new RLM_MCP_GetInstalledBase.InstalledInput();
        input.accountName = accountName;
        return RLM_MCP_GetInstalledBase.getInstalledBase(
            new List<RLM_MCP_GetInstalledBase.InstalledInput>{ input }
        )[0];
    }

    @IsTest
    static void requiresAccountName() {
        RLM_MCP_GetInstalledBase.InstalledOutput out =
            run(null);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('Account name'), out.errorMessage);
    }

    @IsTest
    static void unknownAccount() {
        RLM_MCP_GetInstalledBase.InstalledOutput out = run('No Such Account XYZ');
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('No account matched'), out.errorMessage);
    }

    @IsTest
    static void emptyInstalledBase() {
        Test.startTest();
        RLM_MCP_GetInstalledBase.InstalledOutput out = run('MCP Installed Empty');
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, '' + out.errorMessage);
        System.assert(out.summaryDisplay != null && out.summaryDisplay.contains('no lifecycle assets'), '' + out.summaryDisplay);
    }

    @IsTest
    static void recapsOwnedAssets() {
        Test.startTest();
        RLM_MCP_GetInstalledBase.InstalledOutput out = run('MCP Installed Acme');
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, '' + out.errorMessage);
        System.assert(out.summaryDisplay != null && out.summaryDisplay.contains('QuantumBit Database'), '' + out.summaryDisplay);
        System.assert(out.summaryDisplay.contains('ARR (MRR × 12)'), '' + out.summaryDisplay);
        System.assert(out.summaryDisplay.toLowerCase().contains('derived'), '' + out.summaryDisplay);
        System.assertEquals(out.currentMrr * 12, out.arr);
        System.assert(out.summaryDisplay.contains('Add-ons:'), out.summaryDisplay);
        System.assert(out.summaryDisplay.contains('Current discounts'), '' + out.summaryDisplay);
    }

    @IsTest
    static void disambiguatesAccounts() {
        RLM_MCP_GetInstalledBase.InstalledOutput out = run('MCP Installed');
        System.assertEquals(false, out.isSuccess);
        System.assertEquals(true, out.needsDisambiguation);
        System.assert(out.candidateSummariesDisplay.contains('MCP Installed Acme'), out.candidateSummariesDisplay);
    }
}
