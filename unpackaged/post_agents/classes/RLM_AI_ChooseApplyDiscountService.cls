/**
 * Invocable: collect a discount choice via Custom Lightning Type (clickable
 * radios) and apply it to matching quote lines. Backs Quinn AmendmentStudio →
 * Choose_And_Apply_Discount. Delegates mutation to
 * RLM_AI_ApplyQuoteLineDiscountsService.
 *
 * CLT data shape: DiscountChoice (selectedOption + customPercent). Request
 * field names must match Agent Script action inputs exactly.
 */
public with sharing class RLM_AI_ChooseApplyDiscountService {

    /** CLT input shape — referenced by lightningTypes/rlmDiscountChoice/schema.json */
    public class DiscountChoice {
        @InvocableVariable(
            label='Selected Option'
            description='One of: 10, 20, 30, 40, other. Blank while the picker is open.'
        )
        public String selectedOption;

        @InvocableVariable(
            label='Custom Percent'
            description='Used when selectedOption is other (0-100).'
        )
        public Decimal customPercent;

        /** Seed fields so the LWC can load / show price-history context above the buttons. */
        @InvocableVariable(label='Context Quote Id')
        public String contextQuoteId;

        @InvocableVariable(label='Context Product Name')
        public String contextProductName;
    }

    /** Payload for the CLT editor — full history text above the discount buttons. */
    public class PickerContext {
        @AuraEnabled public String historyDisplay;
        @AuraEnabled public String productName;
        @AuraEnabled public Boolean isSuccess;
        @AuraEnabled public String errorMessage;
    }

    /** Invocable request — field names match Agent Script action inputs. */
    public class ChooseRequest {
        @InvocableVariable(required=true label='Discount Choice')
        public DiscountChoice discount_choice;

        @InvocableVariable(required=true label='Quote Id')
        public String quoteId;

        @InvocableVariable(label='Product Name')
        public String productName;
    }

    public class ChooseResponse {
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;

        @InvocableVariable(label='Results Display')
        public String resultsDisplay;

        @InvocableVariable(label='Error Message')
        public String errorMessage;

        @InvocableVariable(label='Discount Percentage')
        public Decimal discountPercentage;

        public ChooseResponse() {
            this.isSuccess = false;
            this.resultsDisplay = '';
        }
    }

    /**
     * Loads the same plain-text history card used by Get_Asset_Price_History so the
     * CLT picker can show context above the discount buttons (Agentforce user_input
     * forms replace chat text, so history must live inside the picker).
     */
    @AuraEnabled(cacheable=true)
    public static PickerContext getPickerContext(String quoteId, String productName) {
        PickerContext ctx = new PickerContext();
        ctx.productName = productName;
        RLM_AI_AssetPriceHistoryService.HistoryInput hi =
            new RLM_AI_AssetPriceHistoryService.HistoryInput();
        hi.quoteId = quoteId;
        hi.productName = productName;
        List<RLM_AI_AssetPriceHistoryService.HistoryOutput> hist =
            RLM_AI_AssetPriceHistoryService.getHistory(
                new List<RLM_AI_AssetPriceHistoryService.HistoryInput>{ hi }
            );
        if (hist == null || hist.isEmpty()) {
            ctx.isSuccess = false;
            ctx.errorMessage = 'Could not load price history.';
            ctx.historyDisplay = '';
            return ctx;
        }
        ctx.isSuccess = hist[0].isSuccess == true;
        ctx.errorMessage = hist[0].errorMessage;
        ctx.historyDisplay = hist[0].historyDisplay;
        return ctx;
    }

    @InvocableMethod(
        label='Choose And Apply Discount'
        description='Applies a percent discount chosen from the CLT radio picker (10/20/30/40/Other) to matching quote lines.'
    )
    public static List<ChooseResponse> chooseAndApply(List<ChooseRequest> requests) {
        List<ChooseResponse> results = new List<ChooseResponse>();
        if (requests == null || requests.isEmpty()) {
            return results;
        }
        for (ChooseRequest req : requests) {
            results.add(processOne(req));
        }
        return results;
    }

    private static ChooseResponse processOne(ChooseRequest req) {
        ChooseResponse out = new ChooseResponse();
        if (req == null || String.isBlank(req.quoteId)) {
            out.errorMessage = 'Quote Id is required.';
            return out;
        }
        if (req.discount_choice == null
            || String.isBlank(req.discount_choice.selectedOption)) {
            out.errorMessage = 'Pick a discount option (10%, 20%, 30%, 40%, or Other).';
            return out;
        }

        Decimal percent = resolvePercent(req.discount_choice);
        if (percent == null) {
            out.errorMessage =
                'Enter a custom discount percent between 0 and 100 when Other is selected.';
            return out;
        }
        out.discountPercentage = percent;

        RLM_AI_ApplyQuoteLineDiscountsService.DiscountInput di =
            new RLM_AI_ApplyQuoteLineDiscountsService.DiscountInput();
        di.quoteId = req.quoteId;
        di.discountMode = 'percent';
        di.discountPercentage = percent;
        di.productName = String.isNotBlank(req.productName)
            ? req.productName
            : (req.discount_choice != null
                ? req.discount_choice.contextProductName
                : null);
        if (String.isBlank(di.productName)) {
            di.applyToAll = false;
            out.errorMessage =
                'Product name is required to target the discount. Ask which product line.';
            return out;
        }

        List<RLM_AI_ApplyQuoteLineDiscountsService.DiscountOutput> applied =
            RLM_AI_ApplyQuoteLineDiscountsService.applyDiscounts(
                new List<RLM_AI_ApplyQuoteLineDiscountsService.DiscountInput>{ di }
            );
        if (applied == null || applied.isEmpty()) {
            out.errorMessage = 'Discount could not be applied.';
            return out;
        }
        RLM_AI_ApplyQuoteLineDiscountsService.DiscountOutput d = applied[0];
        out.isSuccess = d.isSuccess == true;
        out.resultsDisplay = d.resultsDisplay;
        out.errorMessage = d.errorMessage;
        if (d.needsDisambiguation == true) {
            out.isSuccess = false;
            if (String.isBlank(out.errorMessage)) {
                out.errorMessage =
                    'Multiple matching lines — pick the line in Amendment Studio or name it.';
            }
            if (String.isNotBlank(d.candidateSummariesDisplay)) {
                out.resultsDisplay = d.candidateSummariesDisplay;
            }
        }
        return out;
    }

    private static Decimal resolvePercent(DiscountChoice choice) {
        String opt = choice.selectedOption == null
            ? ''
            : choice.selectedOption.trim().toLowerCase().replace('%', '');
        if (opt == '10' || opt == '20' || opt == '30' || opt == '40') {
            return Decimal.valueOf(opt);
        }
        if (opt == 'other') {
            if (choice.customPercent == null) {
                return null;
            }
            if (choice.customPercent < 0 || choice.customPercent > 100) {
                return null;
            }
            return choice.customPercent.setScale(2, RoundingMode.HALF_UP);
        }
        // Allow a raw numeric option string as a fallback.
        try {
            Decimal n = Decimal.valueOf(opt);
            if (n >= 0 && n <= 100) {
                return n.setScale(2, RoundingMode.HALF_UP);
            }
        } catch (Exception e) {
            // fall through
        }
        return null;
    }
}
