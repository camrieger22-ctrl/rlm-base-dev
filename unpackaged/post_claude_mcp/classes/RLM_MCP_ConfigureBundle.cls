/**
 * Global MCP wrapper: apply named component and attribute picks, then persist
 * through Place Sales Transaction (no Configurator HTTP).
 */
global with sharing class RLM_MCP_ConfigureBundle {
    global class ConfigureInput {
        @InvocableVariable(
            label='Quote Id'
            description='Optional 18-character Quote Id (starts with 0Q0). Takes precedence over names.'
        )
        global String quoteId;

        @InvocableVariable(
            label='Quote Name'
            description='Quote name or fragment. Also matched against the account name, so "Acme" works.'
        )
        global String quoteName;

        @InvocableVariable(
            label='Account Name'
            description='Optional account name to narrow the search, e.g. Acme.'
        )
        global String accountName;

        @InvocableVariable(
            label='Product Name'
            description='Bundle name or SKU, e.g. QuantumBit Complete or QB-COMPLETE.'
        )
        global String productName;

        @InvocableVariable(
            label='Selected Products'
            description='Comma-separated product names or SKUs to select, e.g. QB-MEM 32GB, QuantumBit Database. Required options stay selected.'
        )
        global String selectedProducts;

        @InvocableVariable(
            label='Unselected Products'
            description='Optional comma-separated names or SKUs to remove. Required options cannot be removed.'
        )
        global String unselectedProducts;

        @InvocableVariable(
            label='Attribute Picks JSON'
            description='Optional JSON object of attribute label to value, e.g. {"Operating System":"Redhat Enterprise Linux"}.'
        )
        global String attributePicksJson;

        @InvocableVariable(
            label='Quantities JSON'
            description='Optional JSON object of product name or SKU to quantity, e.g. {"QB-MEM 32GB":2}.'
        )
        global String quantitiesJson;
    }

    global class ConfigureOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(label='Quote Id')
        global String quoteId;
        @InvocableVariable(label='Quote Name')
        global String quoteName;
        @InvocableVariable(label='Quote Line Item Id')
        global String quoteLineItemId;
        @InvocableVariable(label='Product Name')
        global String productName;
        @InvocableVariable(
            label='Configuration Display'
            description='Updated names-only option groups, picks, attributes, and constraint messages after save.'
        )
        global String configurationDisplay;
        @InvocableVariable(label='Needs Disambiguation')
        global Boolean needsDisambiguation;
        @InvocableVariable(label='Candidate Summaries Display')
        global String candidateSummariesDisplay;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(
        label='Configure Revenue Cloud Bundle'
        description='Applies named bundle options and attributes, then saves them as child quote lines. Call Describe first. Never insert child QuoteLineItem rows yourself.'
    )
    global static List<ConfigureOutput> configure(List<ConfigureInput> inputs) {
        List<ConfigureOutput> results = new List<ConfigureOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (ConfigureInput input : inputs) {
            RLM_MCP_BundleConfigService.Request req = new RLM_MCP_BundleConfigService.Request();
            if (input != null) {
                req.quoteId = input.quoteId;
                req.quoteName = input.quoteName;
                req.accountName = input.accountName;
                req.productName = input.productName;
                req.selectedProducts = input.selectedProducts;
                req.unselectedProducts = input.unselectedProducts;
                req.attributePicksJson = input.attributePicksJson;
                req.quantitiesJson = input.quantitiesJson;
            }
            results.add(toOutput(RLM_MCP_BundleConfigService.configure(req)));
        }
        return results;
    }

    private static ConfigureOutput toOutput(RLM_MCP_BundleConfigService.Response raw) {
        ConfigureOutput out = new ConfigureOutput();
        out.isSuccess = raw.isSuccess;
        out.quoteId = raw.quoteId;
        out.quoteName = raw.quoteName;
        out.quoteLineItemId = raw.quoteLineItemId;
        out.productName = raw.productName;
        out.configurationDisplay = raw.configurationDisplay;
        out.needsDisambiguation = raw.needsDisambiguation;
        out.candidateSummariesDisplay = raw.candidateSummariesDisplay;
        out.errorMessage = raw.errorMessage;
        return out;
    }
}
