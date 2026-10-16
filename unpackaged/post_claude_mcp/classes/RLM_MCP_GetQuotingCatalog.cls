/**
 * Hosted MCP: one-line catalog / skill version ping so a stale Claude
 * connector is obvious after reconnect.
 */
global with sharing class RLM_MCP_GetQuotingCatalog {
    public static final String SKILL_VERSION = '2026-10-14.17';
    public static final String CATALOG_DATE = '2026-10-14';

    global class CatalogInput {
        @InvocableVariable(
            label='Unused'
            description='Optional. This tool ignores input; call it with an empty payload.'
        )
        global String unused;
    }

    global class CatalogOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(label='Skill Version')
        global String skillVersion;
        @InvocableVariable(label='Catalog Date')
        global String catalogDate;
        @InvocableVariable(label='Tool Count')
        global Decimal toolCount;
        @InvocableVariable(label='Summary Display')
        global String summaryDisplay;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(
        label='Get Revenue Cloud Quoting Catalog'
        description='Returns the quoting MCP skill version and tool names this org exposes. Call after reconnect or when a parameter is unknown. If this tool is missing, reconnect MCP and re-upload the skill.'
    )
    global static List<CatalogOutput> getCatalog(List<CatalogInput> inputs) {
        CatalogOutput out = new CatalogOutput();
        out.isSuccess = true;
        out.skillVersion = SKILL_VERSION;
        out.catalogDate = CATALOG_DATE;
        List<String> tools = toolNames();
        out.toolCount = tools.size();
        List<String> rows = new List<String>{
            'Revenue Cloud Quoting catalog ' + SKILL_VERSION + ' (' + CATALOG_DATE + ').',
            String.valueOf(tools.size()) + ' tools: ' + String.join(tools, ', ') + '.',
            'If this tool is missing, reconnect MCP and re-upload the revenue-cloud-quoting skill.'
        };
        out.summaryDisplay = String.join(rows, '\n');
        return new List<CatalogOutput>{ out };
    }

    private static List<String> toolNames() {
        return new List<String>{
            'getRevenueCloudQuotingCatalog',
            'buildRevenueCloudQuoteOptions',
            'cloneRevenueCloudQuote',
            'createRevenueCloudQuote',
            'createRevenueCloudProspect',
            'addRevenueCloudAccountContact',
            'checkRevenueCloudSenderContact',
            'addProductToRevenueCloudQuote',
            'applyRevenueCloudQuoteDiscount',
            'updateRevenueCloudQuoteLines',
            'getRevenueCloudQuoteSummary',
            'findRevenueCloudOpenQuotes',
            'submitRevenueCloudQuoteForApproval',
            'decideRevenueCloudQuoteApproval',
            'describeRevenueCloudBundleConfiguration',
            'configureRevenueCloudBundle',
            'createRevenueCloudOrderFromQuote',
            'activateRevenueCloudOrder',
            'amendRevenueCloudAsset',
            'explainRevenueCloudQuotePrice',
            'getRevenueCloudInstalledBase',
            'compareRevenueCloudQuoteToInstalledBase',
            'getRevenueCloudDealStatus',
            'renewOrCancelRevenueCloudAsset',
            'draftRevenueCloudCustomerReply',
            'createRevenueCloudRampSchedule',
            'applyRevenueCloudQuoteRamp',
            'getRevenueCloudBillingAndUsage',
            'previewRevenueCloudQuoteDocument'
        };
    }
}
