/**
 * Global MCP wrapper around RLM_AI_AddProductToQuoteService (managed add-line).
 */
global with sharing class RLM_MCP_AddProductToQuote {
    global class AddInput {
        @InvocableVariable(
            required=true
            label='Quote Id'
            description='18-character Quote Id (starts with 0Q0).'
        )
        global String quoteId;

        @InvocableVariable(
            label='Product Name'
            description='Product name or SKU fragment, e.g. QuantumBit Database or QB-DB.'
        )
        global String productName;

        @InvocableVariable(label='Product Id')
        global String productId;

        @InvocableVariable(label='Quantity')
        global Decimal quantity;

        @InvocableVariable(
            label='Selling Model Name'
            description='Optional. Only when the user names a selling model, e.g. Term Annual.'
        )
        global String sellingModelName;
    }

    global class AddOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(label='Quote Line Item Id')
        global String quoteLineItemId;
        @InvocableVariable(label='Product Name Added')
        global String productNameAdded;
        @InvocableVariable(label='Quantity Added')
        global Decimal quantityAdded;
        @InvocableVariable(label='Selling Model Name')
        global String sellingModelName;
        @InvocableVariable(label='Line Summary Display')
        global String lineSummaryDisplay;
        @InvocableVariable(label='Needs Disambiguation')
        global Boolean needsDisambiguation;
        @InvocableVariable(label='Candidate Summaries Display')
        global String candidateSummariesDisplay;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(
        label='Add Product To Revenue Cloud Quote'
        description='Adds a product to an existing Draft quote using the Revenue Cloud add-line action. Resolves product and default selling model. Ask the user to pick when the name is ambiguous.'
    )
    global static List<AddOutput> addProduct(List<AddInput> inputs) {
        List<AddOutput> results = new List<AddOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        List<RLM_AI_AddProductToQuoteService.AddInput> serviceInputs =
            new List<RLM_AI_AddProductToQuoteService.AddInput>();
        for (AddInput input : inputs) {
            RLM_AI_AddProductToQuoteService.AddInput mapped =
                new RLM_AI_AddProductToQuoteService.AddInput();
            mapped.quoteId = input.quoteId;
            mapped.productId = input.productId;
            mapped.productName = input.productName;
            mapped.quantity = input.quantity;
            mapped.sellingModelName = input.sellingModelName;
            serviceInputs.add(mapped);
        }
        for (RLM_AI_AddProductToQuoteService.AddOutput raw :
            RLM_AI_AddProductToQuoteService.addProduct(serviceInputs)
        ) {
            AddOutput out = new AddOutput();
            out.isSuccess = raw.isSuccess;
            out.quoteLineItemId = raw.quoteLineItemId;
            out.productNameAdded = raw.productNameAdded;
            out.quantityAdded = raw.quantityAdded;
            out.sellingModelName = raw.sellingModelName;
            out.lineSummaryDisplay = raw.lineSummaryDisplay;
            out.needsDisambiguation = raw.needsDisambiguation;
            out.candidateSummariesDisplay = raw.candidateSummariesDisplay;
            out.errorMessage = raw.errorMessage;
            results.add(out);
        }
        return results;
    }
}
