@isTest
private class RLM_AI_ChooseApplyDiscountServiceTest {

    @isTest
    static void rejectsBlankQuoteId() {
        RLM_AI_ChooseApplyDiscountService.ChooseRequest req =
            new RLM_AI_ChooseApplyDiscountService.ChooseRequest();
        req.quoteId = '';
        req.discount_choice = new RLM_AI_ChooseApplyDiscountService.DiscountChoice();
        req.discount_choice.selectedOption = '10';

        List<RLM_AI_ChooseApplyDiscountService.ChooseResponse> results =
            RLM_AI_ChooseApplyDiscountService.chooseAndApply(
                new List<RLM_AI_ChooseApplyDiscountService.ChooseRequest>{ req }
            );

        System.assertEquals(false, results[0].isSuccess);
        System.assert(results[0].errorMessage.contains('Quote Id is required'));
    }

    @isTest
    static void rejectsMissingChoice() {
        RLM_AI_ChooseApplyDiscountService.ChooseRequest req =
            new RLM_AI_ChooseApplyDiscountService.ChooseRequest();
        req.quoteId = '0Q0000000000000001';
        req.productName = 'Generative AI';

        List<RLM_AI_ChooseApplyDiscountService.ChooseResponse> results =
            RLM_AI_ChooseApplyDiscountService.chooseAndApply(
                new List<RLM_AI_ChooseApplyDiscountService.ChooseRequest>{ req }
            );

        System.assertEquals(false, results[0].isSuccess);
        System.assert(results[0].errorMessage.contains('Pick a discount'));
    }

    @isTest
    static void otherWithoutCustomPercentFails() {
        RLM_AI_ChooseApplyDiscountService.ChooseRequest req =
            new RLM_AI_ChooseApplyDiscountService.ChooseRequest();
        req.quoteId = '0Q0000000000000001';
        req.productName = 'Generative AI';
        req.discount_choice = new RLM_AI_ChooseApplyDiscountService.DiscountChoice();
        req.discount_choice.selectedOption = 'other';

        List<RLM_AI_ChooseApplyDiscountService.ChooseResponse> results =
            RLM_AI_ChooseApplyDiscountService.chooseAndApply(
                new List<RLM_AI_ChooseApplyDiscountService.ChooseRequest>{ req }
            );

        System.assertEquals(false, results[0].isSuccess);
        System.assert(results[0].errorMessage.contains('custom discount'));
    }

    @isTest
    static void requiresProductName() {
        RLM_AI_ChooseApplyDiscountService.ChooseRequest req =
            new RLM_AI_ChooseApplyDiscountService.ChooseRequest();
        req.quoteId = '0Q0000000000000001';
        req.discount_choice = new RLM_AI_ChooseApplyDiscountService.DiscountChoice();
        req.discount_choice.selectedOption = '20';

        List<RLM_AI_ChooseApplyDiscountService.ChooseResponse> results =
            RLM_AI_ChooseApplyDiscountService.chooseAndApply(
                new List<RLM_AI_ChooseApplyDiscountService.ChooseRequest>{ req }
            );

        System.assertEquals(false, results[0].isSuccess);
        System.assert(results[0].errorMessage.contains('Product name'));
        System.assertEquals(20, results[0].discountPercentage);
    }
}
