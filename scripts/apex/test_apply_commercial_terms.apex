RLM_BambooSuiteApplyCommercialTerms.Request req =
    new RLM_BambooSuiteApplyCommercialTerms.Request();
req.opportunityId = '006gL00000VvVEvQAN';
req.termMonths = 36;
req.billingFrequency = 'Annual';
req.selectedQuoteId = '0Q0gL000002h0urSAA';

List<RLM_BambooSuiteApplyCommercialTerms.Result> results =
    RLM_BambooSuiteApplyCommercialTerms.apply(
        new List<RLM_BambooSuiteApplyCommercialTerms.Request>{ req }
    );
System.debug('SUCCESS=' + results[0].isSuccess);
System.debug('MSG=' + results[0].summary);
System.debug('ERR=' + results[0].errorMessage);
System.debug('COUNT=' + results[0].optionsUpdated);
