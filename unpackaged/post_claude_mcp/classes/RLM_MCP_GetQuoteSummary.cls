/**
 * Global MCP wrapper around RLM_AI_QuoteDemoSummaryService.
 */
global with sharing class RLM_MCP_GetQuoteSummary {
    global class SummaryInput {
        @InvocableVariable(
            required=true
            label='Quote Id'
            description='18-character Quote Id (starts with 0Q0).'
        )
        global String quoteId;
    }

    global class SummaryOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(label='Summary Display')
        global String summaryDisplay;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(
        label='Get Revenue Cloud Quote Summary'
        description='Read-only names-only recap of quote lines (product, quantity, prices). Use after create or add-line.'
    )
    global static List<SummaryOutput> getSummary(List<SummaryInput> inputs) {
        List<SummaryOutput> results = new List<SummaryOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        List<RLM_AI_QuoteDemoSummaryService.SummaryInput> serviceInputs =
            new List<RLM_AI_QuoteDemoSummaryService.SummaryInput>();
        for (SummaryInput input : inputs) {
            RLM_AI_QuoteDemoSummaryService.SummaryInput mapped =
                new RLM_AI_QuoteDemoSummaryService.SummaryInput();
            mapped.quoteId = input.quoteId;
            serviceInputs.add(mapped);
        }
        for (RLM_AI_QuoteDemoSummaryService.SummaryOutput raw :
            RLM_AI_QuoteDemoSummaryService.getSummary(serviceInputs)
        ) {
            SummaryOutput out = new SummaryOutput();
            out.isSuccess = raw.isSuccess;
            out.summaryDisplay = raw.summaryDisplay;
            out.errorMessage = raw.errorMessage;
            results.add(out);
        }
        return results;
    }
}
