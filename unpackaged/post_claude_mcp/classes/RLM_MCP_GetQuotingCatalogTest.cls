@IsTest
private class RLM_MCP_GetQuotingCatalogTest {
    @IsTest
    static void returnsVersionAndTools() {
        Test.startTest();
        List<RLM_MCP_GetQuotingCatalog.CatalogOutput> results =
            RLM_MCP_GetQuotingCatalog.getCatalog(
                new List<RLM_MCP_GetQuotingCatalog.CatalogInput>{
                    new RLM_MCP_GetQuotingCatalog.CatalogInput()
                }
            );
        Test.stopTest();
        System.assertEquals(1, results.size());
        System.assertEquals(true, results[0].isSuccess);
        System.assertEquals(RLM_MCP_GetQuotingCatalog.SKILL_VERSION, results[0].skillVersion);
        System.assert(results[0].summaryDisplay.contains('getRevenueCloudQuotingCatalog'),
            results[0].summaryDisplay);
        System.assert(results[0].summaryDisplay.contains('createRevenueCloudRampSchedule'),
            results[0].summaryDisplay);
        System.assert(results[0].toolCount > 20, '' + results[0].toolCount);
    }
}
