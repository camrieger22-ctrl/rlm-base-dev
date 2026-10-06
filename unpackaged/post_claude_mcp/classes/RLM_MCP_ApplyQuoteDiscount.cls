/**
 * Global MCP wrapper around RLM_AI_ApplyQuoteLineDiscountsService.
 */
global with sharing class RLM_MCP_ApplyQuoteDiscount {
    global class DiscountInput {
        @InvocableVariable(required=true label='Quote Id')
        global String quoteId;

        @InvocableVariable(
            label='Discount Percentage'
            description='Percent off (0-100). Used when applying a simple percent discount.'
        )
        global Decimal discountPercentage;

        @InvocableVariable(
            label='Apply To All'
            description='When true, discount every line on the quote.'
        )
        global Boolean applyToAll;

        @InvocableVariable(
            label='Product Name'
            description='Discount lines whose product name matches this term.'
        )
        global String productName;
    }

    global class DiscountOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(label='Applied Count')
        global Decimal appliedCount;
        @InvocableVariable(label='Results Display')
        global String resultsDisplay;
        @InvocableVariable(label='Needs Disambiguation')
        global Boolean needsDisambiguation;
        @InvocableVariable(label='Candidate Summaries Display')
        global String candidateSummariesDisplay;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(
        label='Apply Discount To Revenue Cloud Quote'
        description='Applies a percent discount to one product or all lines on a quote using the Revenue Cloud discount action. Prefer applyToAll or productName targeting.'
    )
    global static List<DiscountOutput> applyDiscount(List<DiscountInput> inputs) {
        List<DiscountOutput> results = new List<DiscountOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        List<RLM_AI_ApplyQuoteLineDiscountsService.DiscountInput> serviceInputs =
            new List<RLM_AI_ApplyQuoteLineDiscountsService.DiscountInput>();
        for (DiscountInput input : inputs) {
            RLM_AI_ApplyQuoteLineDiscountsService.DiscountInput mapped =
                new RLM_AI_ApplyQuoteLineDiscountsService.DiscountInput();
            mapped.quoteId = input.quoteId;
            mapped.discountMode = 'percent';
            mapped.discountPercentage = input.discountPercentage;
            mapped.applyToAll = input.applyToAll == true;
            mapped.productName = input.productName;
            serviceInputs.add(mapped);
        }
        for (RLM_AI_ApplyQuoteLineDiscountsService.DiscountOutput raw :
            RLM_AI_ApplyQuoteLineDiscountsService.applyDiscounts(serviceInputs)
        ) {
            DiscountOutput out = new DiscountOutput();
            out.isSuccess = raw.isSuccess;
            out.appliedCount = raw.appliedCount;
            out.resultsDisplay = raw.resultsDisplay;
            out.needsDisambiguation = raw.needsDisambiguation;
            out.candidateSummariesDisplay = raw.candidateSummariesDisplay;
            out.errorMessage = raw.errorMessage;
            results.add(out);
        }
        return results;
    }
}
