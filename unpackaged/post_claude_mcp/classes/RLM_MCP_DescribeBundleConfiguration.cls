/**
 * Global MCP wrapper: load option groups, attributes, and constraint messages
 * for a bundle parent line. Does not persist. Call configure after the user picks.
 */
global with sharing class RLM_MCP_DescribeBundleConfiguration {
    global class DescribeInput {
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
            description='Bundle name or SKU, e.g. QuantumBit Complete or QB-COMPLETE. If blank, uses the only bundle parent line on the quote.'
        )
        global String productName;
    }

    global class DescribeOutput {
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
            description='Names-only option groups, current picks, attributes, and constraint messages. Ask the user about unanswered groups, then call Configure Bundle.'
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
        label='Describe Revenue Cloud Bundle Configuration'
        description='Loads option groups for a bundle on a Draft quote. Does not save. Checked items include a reason (required, catalog default, or already on the quote). Explain those reasons to the user. Ask them to pick, then call Configure Bundle. Never insert child QuoteLineItem rows yourself.'
    )
    global static List<DescribeOutput> describe(List<DescribeInput> inputs) {
        List<DescribeOutput> results = new List<DescribeOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (DescribeInput input : inputs) {
            RLM_MCP_BundleConfigService.Request req = new RLM_MCP_BundleConfigService.Request();
            if (input != null) {
                req.quoteId = input.quoteId;
                req.quoteName = input.quoteName;
                req.accountName = input.accountName;
                req.productName = input.productName;
            }
            results.add(toOutput(RLM_MCP_BundleConfigService.describe(req)));
        }
        return results;
    }

    private static DescribeOutput toOutput(RLM_MCP_BundleConfigService.Response raw) {
        DescribeOutput out = new DescribeOutput();
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
