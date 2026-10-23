/**
 * Global MCP wrapper: load option groups, attributes, and CRE-selected qty
 * from Lightning Configure. Does not persist. Call configure after the user picks.
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

        @InvocableVariable(
            label='Quote Line Item Id'
            description='Optional parent QuoteLineItem Id. Required when the same SKU is on more than one ramp year.'
        )
        global String quoteLineItemId;
    }

    global class DescribeOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(label='Quote Id')
        global String quoteId;
        @InvocableVariable(
            label='Quote Url'
            description='Lightning Quote page. Render as [Open Quote](quoteUrl) in the chat reply.'
        )
        global String quoteUrl;
        @InvocableVariable(label='Quote Name')
        global String quoteName;
        @InvocableVariable(label='Quote Line Item Id')
        global String quoteLineItemId;
        @InvocableVariable(label='Product Name')
        global String productName;
        @InvocableVariable(
            label='Configuration Display'
            description='Names-only option groups, picks, and attributes. Keep-or-drill: names then Keep current selection cards. Never dump every value. Then Configure with attributePicksJson.'
        )
        global String configurationDisplay;
        @InvocableVariable(
            label='Constraint Coach Display'
            description='When needsAction is true, paste this card verbatim, ask the user to pick a number, and do not call configure until they reply. Never invent Dual/Gold.'
        )
        global String constraintCoachDisplay;
        @InvocableVariable(
            label='Needs Action'
            description='True when this bundle still needs picks or constraints block. If constraintCoachDisplay is set, paste the Rule card verbatim. Do not reword Dual/Gold/lanes. Wait for a number. Do not PDF, email, or submit.'
        )
        global Boolean needsAction;
        @InvocableVariable(label='Needs Disambiguation')
        global Boolean needsDisambiguation;
        @InvocableVariable(label='Candidate Summaries Display')
        global String candidateSummariesDisplay;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(
        label='Describe Revenue Cloud Bundle Configuration'
        description='Loads Lightning CRE mix. Pass quoteLineItemId. Keep-or-drill. Recite engine picks and hidden/required qty. Never invent Dual/Gold. Never insert child QuoteLineItem rows.'
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
                req.quoteLineItemId = input.quoteLineItemId;
            }
            results.add(toOutput(RLM_MCP_BundleConfigService.describe(req)));
        }
        return results;
    }

    private static DescribeOutput toOutput(RLM_MCP_BundleConfigService.Response raw) {
        DescribeOutput out = new DescribeOutput();
        out.isSuccess = raw.isSuccess;
        out.quoteId = raw.quoteId;
        out.quoteUrl = RLM_MCP_RecordLinks.lightningUrl(
            'Quote', RLM_MCP_RecordLinks.toId(raw.quoteId));
        out.quoteName = raw.quoteName;
        out.quoteLineItemId = raw.quoteLineItemId;
        out.productName = raw.productName;
        out.configurationDisplay = raw.configurationDisplay;
        out.constraintCoachDisplay = raw.constraintCoachDisplay;
        out.needsAction = raw.needsAction;
        out.needsDisambiguation = raw.needsDisambiguation;
        out.candidateSummariesDisplay = raw.candidateSummariesDisplay;
        out.errorMessage = raw.errorMessage;
        return out;
    }
}
