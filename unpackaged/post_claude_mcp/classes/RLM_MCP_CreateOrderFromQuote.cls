/**
 * Hosted MCP: create a Revenue Cloud Order from a Quote via createOrdersFromQuote.
 */
global with sharing class RLM_MCP_CreateOrderFromQuote {
    global class CreateInput {
        @InvocableVariable(
            label='Quote Id'
            description='Optional 18-character Quote Id (starts with 0Q0). Takes precedence over names.'
        )
        global String quoteId;

        @InvocableVariable(
            label='Quote Name'
            description='Quote name or fragment, e.g. Acme Convo Test. Also matched against the account name.'
        )
        global String quoteName;

        @InvocableVariable(
            label='Account Name'
            description='Optional account name to narrow the search, e.g. Acme.'
        )
        global String accountName;
    }

    global class CreateOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(
            label='Is Partial'
            description='True when quote pricing is still running. Call this tool again with the same quote.'
        )
        global Boolean isPartial;
        @InvocableVariable(label='Message')
        global String message;
        @InvocableVariable(label='Quote Id')
        global String quoteId;
        @InvocableVariable(
            label='Quote Url'
            description='Lightning Quote page. Render as [Open Quote](quoteUrl) in the chat reply.'
        )
        global String quoteUrl;
        @InvocableVariable(label='Quote Name')
        global String quoteName;
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
        @InvocableVariable(label='Needs Disambiguation')
        global Boolean needsDisambiguation;
        @InvocableVariable(label='Candidate Summaries Display')
        global String candidateSummariesDisplay;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(
        label='Create Revenue Cloud Order From Quote'
        description='Creates an Order from a quote using createOrdersFromQuote. Then call Activate Order so assets are created. Never insert Order rows yourself.'
    )
    global static List<CreateOutput> createOrder(List<CreateInput> inputs) {
        List<CreateOutput> results = new List<CreateOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (CreateInput input : inputs) {
            results.add(toOutput(RLM_MCP_OrderLifecycle.createOrderFromQuote(
                input == null ? null : input.quoteId,
                input == null ? null : input.quoteName,
                input == null ? null : input.accountName
            )));
        }
        return results;
    }

    private static CreateOutput toOutput(RLM_MCP_OrderLifecycle.Result raw) {
        CreateOutput out = new CreateOutput();
        out.isSuccess = raw.isSuccess;
        out.isPartial = raw.isPartial;
        out.message = raw.message;
        out.quoteId = raw.quoteId;
        out.quoteUrl = raw.quoteUrl;
        out.quoteName = raw.quoteName;
        out.orderId = raw.orderId;
        out.orderNumber = raw.orderNumber;
        out.orderStatus = raw.orderStatus;
        out.orderUrl = raw.orderUrl;
        out.needsDisambiguation = raw.needsDisambiguation;
        out.candidateSummariesDisplay = raw.candidateSummariesDisplay;
        out.errorMessage = raw.errorMessage;
        return out;
    }
}
