/**
 * Global MCP wrapper around RLM_AI_AddProductToQuoteService (managed add-line).
 * Optional linesJson adds several products in one call on an existing Draft.
 */
global with sharing class RLM_MCP_AddProductToQuote {
    private static final Integer MAX_LINES = 20;

    public interface LineAdder {
        List<RLM_AI_AddProductToQuoteService.AddOutput> add(
            List<RLM_AI_AddProductToQuoteService.AddInput> inputs
        );
    }

    public class DefaultLineAdder implements LineAdder {
        public List<RLM_AI_AddProductToQuoteService.AddOutput> add(
            List<RLM_AI_AddProductToQuoteService.AddInput> inputs
        ) {
            return RLM_AI_AddProductToQuoteService.addProduct(inputs);
        }
    }

    @TestVisible
    static LineAdder lineAdder = new DefaultLineAdder();

    global class AddInput {
        @InvocableVariable(
            required=true
            label='Quote Id'
            description='18-character Quote Id (starts with 0Q0).'
        )
        global String quoteId;

        @InvocableVariable(
            label='Lines JSON'
            description='Optional JSON array to add several products in this call: [{"product":"Name","quantity":2}]. Do not call add-product per SKU when this is set.'
        )
        global String linesJson;

        @InvocableVariable(
            label='Product Name'
            description='Product name or SKU fragment, e.g. QuantumBit Database or QB-DB. Skip when linesJson is set.'
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
        @InvocableVariable(
            label='Quote Url'
            description='Lightning Quote page. Render as [Open Quote](quoteUrl) in the chat reply.'
        )
        global String quoteUrl;
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
        description='Adds products to an existing Draft quote. Pass linesJson ([{product, quantity}]) to add every new SKU in this call. Do not add-product per SKU when linesJson is set.'
    )
    global static List<AddOutput> addProduct(List<AddInput> inputs) {
        List<AddOutput> results = new List<AddOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (AddInput input : inputs) {
            results.add(addOne(input));
        }
        return results;
    }

    private static AddOutput addOne(AddInput input) {
        AddOutput out = new AddOutput();
        out.isSuccess = false;
        if (input == null || String.isBlank(input.quoteId)) {
            out.errorMessage = 'Quote Id is required.';
            return out;
        }
        List<RLM_AI_AddProductToQuoteService.AddInput> serviceInputs =
            new List<RLM_AI_AddProductToQuoteService.AddInput>();
        if (String.isNotBlank(input.linesJson)) {
            String parseError = parseLinesJson(input, serviceInputs);
            if (parseError != null) {
                out.errorMessage = parseError;
                return out;
            }
        } else {
            RLM_AI_AddProductToQuoteService.AddInput mapped =
                new RLM_AI_AddProductToQuoteService.AddInput();
            mapped.quoteId = input.quoteId;
            mapped.productId = input.productId;
            mapped.productName = input.productName;
            mapped.quantity = input.quantity;
            mapped.sellingModelName = input.sellingModelName;
            serviceInputs.add(mapped);
        }
        List<RLM_AI_AddProductToQuoteService.AddOutput> rawResults = lineAdder.add(serviceInputs);
        if (rawResults == null || rawResults.isEmpty()) {
            out.errorMessage = 'Add product returned no result.';
            return out;
        }
        Boolean allOk = true;
        List<String> recap = new List<String>();
        RLM_AI_AddProductToQuoteService.AddOutput last = rawResults[rawResults.size() - 1];
        for (RLM_AI_AddProductToQuoteService.AddOutput raw : rawResults) {
            if (raw.needsDisambiguation == true) {
                out.needsDisambiguation = true;
                out.candidateSummariesDisplay = raw.candidateSummariesDisplay;
                out.errorMessage = raw.errorMessage;
                return out;
            }
            if (raw.isSuccess != true) {
                allOk = false;
                if (String.isNotBlank(raw.errorMessage)) {
                    recap.add(raw.errorMessage);
                }
            } else if (String.isNotBlank(raw.lineSummaryDisplay)) {
                recap.add(raw.lineSummaryDisplay);
            } else if (String.isNotBlank(raw.productNameAdded)) {
                recap.add(raw.productNameAdded);
            }
        }
        out.isSuccess = allOk;
        out.quoteLineItemId = last.quoteLineItemId;
        out.productNameAdded = last.productNameAdded;
        out.quantityAdded = last.quantityAdded;
        out.sellingModelName = last.sellingModelName;
        out.errorMessage = allOk ? null : last.errorMessage;
        Id quoteId = RLM_MCP_RecordLinks.toId(input.quoteId);
        if (quoteId != null) {
            out.quoteUrl = RLM_MCP_RecordLinks.lightningUrl('Quote', quoteId);
            String link = RLM_MCP_RecordLinks.markdown('Open Quote', 'Quote', quoteId);
            if (String.isNotBlank(link)) {
                recap.add(link);
            }
        }
        out.lineSummaryDisplay = recap.isEmpty() ? last.lineSummaryDisplay : String.join(recap, '\n');
        return out;
    }

    private static String parseLinesJson(
        AddInput input,
        List<RLM_AI_AddProductToQuoteService.AddInput> serviceInputs
    ) {
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(input.linesJson);
        } catch (Exception e) {
            return 'linesJson is not valid JSON. Pass [{"product":"Name","quantity":2}].';
        }
        if (!(parsed instanceof List<Object>)) {
            return 'linesJson must be a JSON array.';
        }
        for (Object item : (List<Object>) parsed) {
            if (serviceInputs.size() >= MAX_LINES) {
                break;
            }
            if (!(item instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> row = (Map<String, Object>) item;
            String product = asString(first(row, new List<String>{ 'product', 'name', 'sku' }));
            if (String.isBlank(product)) {
                continue;
            }
            RLM_AI_AddProductToQuoteService.AddInput mapped =
                new RLM_AI_AddProductToQuoteService.AddInput();
            mapped.quoteId = input.quoteId;
            mapped.productName = product;
            mapped.quantity = asDecimal(first(row, new List<String>{ 'quantity', 'qty' }));
            mapped.sellingModelName = asString(first(row, new List<String>{
                'sellingModel', 'sellingModelName'
            }));
            serviceInputs.add(mapped);
        }
        if (serviceInputs.isEmpty()) {
            return 'linesJson had no products.';
        }
        return null;
    }

    private static Object first(Map<String, Object> raw, List<String> keys) {
        for (String key : keys) {
            if (raw.containsKey(key) && raw.get(key) != null) {
                return raw.get(key);
            }
        }
        return null;
    }

    private static String asString(Object value) {
        return value == null ? null : String.valueOf(value).trim();
    }

    private static Decimal asDecimal(Object value) {
        if (value == null) {
            return 1;
        }
        if (value instanceof Decimal) {
            return (Decimal) value;
        }
        try {
            return Decimal.valueOf(String.valueOf(value).trim());
        } catch (Exception e) {
            return 1;
        }
    }
}
