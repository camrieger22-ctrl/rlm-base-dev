/**
 * Shared add-line retry: One-Time / configured bundles (Q-Rack 750) often
 * fail Salesforce validation at qty &gt; 1 with "Cannot have a fractional
 * quantity" on a child component. Retry that line once at quantity 1.
 */
public inherited sharing class RLM_MCP_LineAddRetry {
    public interface Adder {
        List<RLM_AI_AddProductToQuoteService.AddOutput> add(
            List<RLM_AI_AddProductToQuoteService.AddInput> inputs
        );
    }

    public static Boolean isFractionalQuantityError(String errorMessage) {
        if (String.isBlank(errorMessage)) {
            return false;
        }
        return errorMessage.toLowerCase().contains('fractional quantity');
    }

    public static Boolean shouldRetryAtOne(
        RLM_AI_AddProductToQuoteService.AddInput request,
        RLM_AI_AddProductToQuoteService.AddOutput result
    ) {
        if (request == null || result == null) {
            return false;
        }
        if (result.isSuccess == true || result.needsDisambiguation == true) {
            return false;
        }
        if (request.quantity == null || request.quantity <= 1) {
            return false;
        }
        return isFractionalQuantityError(result.errorMessage);
    }

    public static String retryNote(String productName, Decimal requestedQty) {
        String name = String.isBlank(productName) ? 'This product' : productName;
        String asked = requestedQty == null ? '?' : String.valueOf(requestedQty.intValue());
        return name + ' was added at quantity 1. Quantity ' + asked
            + ' failed Salesforce bundle validation (fractional component'
            + ' quantity). This One-Time bundle is sold per rack.';
    }

    public static List<RLM_AI_AddProductToQuoteService.AddOutput> addWithRetry(
        Adder adder,
        List<RLM_AI_AddProductToQuoteService.AddInput> inputs,
        List<String> retryNotes
    ) {
        if (adder == null) {
            return new List<RLM_AI_AddProductToQuoteService.AddOutput>();
        }
        List<RLM_AI_AddProductToQuoteService.AddOutput> added = adder.add(inputs);
        if (added == null || inputs == null || inputs.isEmpty()) {
            return added;
        }
        Integer n = Math.min(added.size(), inputs.size());
        for (Integer i = 0; i < n; i++) {
            RLM_AI_AddProductToQuoteService.AddInput request = inputs[i];
            RLM_AI_AddProductToQuoteService.AddOutput row = added[i];
            if (!shouldRetryAtOne(request, row)) {
                continue;
            }
            RLM_AI_AddProductToQuoteService.AddInput retry = copyAtQuantityOne(request);
            List<RLM_AI_AddProductToQuoteService.AddOutput> again =
                adder.add(new List<RLM_AI_AddProductToQuoteService.AddInput>{ retry });
            if (again == null || again.isEmpty() || again[0] == null || again[0].isSuccess != true) {
                continue;
            }
            added[i] = again[0];
            if (retryNotes != null) {
                retryNotes.add(retryNote(request.productName, request.quantity));
            }
        }
        return added;
    }

    private static RLM_AI_AddProductToQuoteService.AddInput copyAtQuantityOne(
        RLM_AI_AddProductToQuoteService.AddInput source
    ) {
        RLM_AI_AddProductToQuoteService.AddInput copy =
            new RLM_AI_AddProductToQuoteService.AddInput();
        copy.quoteId = source.quoteId;
        copy.productId = source.productId;
        copy.productName = source.productName;
        copy.quantity = 1;
        copy.sellingModelName = source.sellingModelName;
        copy.startDate = source.startDate;
        copy.endDate = source.endDate;
        return copy;
    }
}
