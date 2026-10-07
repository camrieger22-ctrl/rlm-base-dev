/**
 * Hosted MCP: activate a Revenue Cloud Order so the platform creates assets.
 */
global with sharing class RLM_MCP_ActivateOrder {
    global class ActivateInput {
        @InvocableVariable(
            label='Order Id'
            description='Optional 18-character Order Id (starts with 801). Takes precedence over names.'
        )
        global String orderId;

        @InvocableVariable(
            label='Order Number'
            description='Order number, e.g. 00000123.'
        )
        global String orderNumber;

        @InvocableVariable(
            label='Quote Name'
            description='Quote name or fragment used to find the order, e.g. Acme Convo Test.'
        )
        global String quoteName;

        @InvocableVariable(
            label='Account Name'
            description='Optional account name to narrow the search, e.g. Acme.'
        )
        global String accountName;
    }

    global class ActivateOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(
            label='Is Partial'
            description='True when activation started but assets are not visible yet. Call this tool again with the same order Id.'
        )
        global Boolean isPartial;
        @InvocableVariable(label='Message')
        global String message;
        @InvocableVariable(label='Order Id')
        global String orderId;
        @InvocableVariable(label='Order Number')
        global String orderNumber;
        @InvocableVariable(label='Order Status')
        global String orderStatus;
        @InvocableVariable(
            label='Order Url'
            description='Lightning Order page. Render as [Open Order](orderUrl) in the chat reply.'
        )
        global String orderUrl;
        @InvocableVariable(label='Quote Id')
        global String quoteId;
        @InvocableVariable(
            label='Quote Url'
            description='Lightning Quote page. Render as [Open Quote](quoteUrl) in the chat reply.'
        )
        global String quoteUrl;
        @InvocableVariable(label='Asset Count')
        global Decimal assetCount;
        @InvocableVariable(
            label='Assets Display'
            description='Names-only asset list with Open Asset markdown links. Render in the chat reply.'
        )
        global String assetsDisplay;
        @InvocableVariable(label='Needs Disambiguation')
        global Boolean needsDisambiguation;
        @InvocableVariable(label='Candidate Summaries Display')
        global String candidateSummariesDisplay;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(
        label='Activate Revenue Cloud Order'
        description='Activates a Draft order (Status = Activated) so Salesforce creates assets. Stamps Bill to Contact and addresses from the account when missing. If isPartial, call again with the same order Id. Never insert Asset rows yourself.'
    )
    global static List<ActivateOutput> activate(List<ActivateInput> inputs) {
        List<ActivateOutput> results = new List<ActivateOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (ActivateInput input : inputs) {
            results.add(toOutput(RLM_MCP_OrderLifecycle.activateOrder(
                input == null ? null : input.orderId,
                input == null ? null : input.orderNumber,
                input == null ? null : input.quoteName,
                input == null ? null : input.accountName
            )));
        }
        return results;
    }

    private static ActivateOutput toOutput(RLM_MCP_OrderLifecycle.Result raw) {
        ActivateOutput out = new ActivateOutput();
        out.isSuccess = raw.isSuccess;
        out.isPartial = raw.isPartial;
        out.message = raw.message;
        out.orderId = raw.orderId;
        out.orderNumber = raw.orderNumber;
        out.orderStatus = raw.orderStatus;
        out.orderUrl = raw.orderUrl;
        out.quoteId = raw.quoteId;
        out.quoteUrl = raw.quoteUrl;
        out.assetCount = raw.assetCount;
        out.assetsDisplay = raw.assetsDisplay;
        out.needsDisambiguation = raw.needsDisambiguation;
        out.candidateSummariesDisplay = raw.candidateSummariesDisplay;
        out.errorMessage = raw.errorMessage;
        return out;
    }
}
