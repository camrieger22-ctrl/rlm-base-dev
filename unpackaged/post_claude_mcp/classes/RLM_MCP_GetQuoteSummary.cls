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
        @InvocableVariable(
            label='Quote Url'
            description='Lightning Quote page. Render as [Open Quote](quoteUrl) in the chat reply.'
        )
        global String quoteUrl;
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
        List<RLM_AI_QuoteDemoSummaryService.SummaryOutput> rawResults =
            RLM_AI_QuoteDemoSummaryService.getSummary(serviceInputs);
        for (Integer i = 0; i < rawResults.size(); i++) {
            RLM_AI_QuoteDemoSummaryService.SummaryOutput raw = rawResults[i];
            SummaryOutput out = new SummaryOutput();
            out.isSuccess = raw.isSuccess;
            out.summaryDisplay = raw.summaryDisplay;
            out.errorMessage = raw.errorMessage;
            if (out.isSuccess == true && i < inputs.size()) {
                Id quoteId = RLM_MCP_RecordLinks.toId(inputs[i].quoteId);
                if (quoteId != null) {
                    out.quoteUrl = RLM_MCP_RecordLinks.lightningUrl('Quote', quoteId);
                    String link = RLM_MCP_RecordLinks.markdown('Open Quote', 'Quote', quoteId);
                    if (String.isNotBlank(link)) {
                        out.summaryDisplay = String.isBlank(out.summaryDisplay)
                            ? link
                            : link + '\n\n' + out.summaryDisplay;
                    }
                }
            }
            results.add(out);
        }
        return results;
    }
}
