/**
 * Hosted MCP: approve or reject an assigned ApprovalWorkItem via
 * reviewApprovalWorkItem. Do not PATCH Quote.Status.
 */
global with sharing class RLM_MCP_DecideQuoteApproval {
    global class DecideInput {
        @InvocableVariable(
            required=true
            label='Decision'
            description='approve or reject. Caller must be an assignee of the open work item.'
        )
        global String decision;

        @InvocableVariable(
            label='Quote Id'
            description='Optional 18-character Quote Id (starts with 0Q0). Takes precedence over names.'
        )
        global String quoteId;

        @InvocableVariable(label='Quote Name')
        global String quoteName;

        @InvocableVariable(label='Account Name')
        global String accountName;

        @InvocableVariable(label='Opportunity Name')
        global String opportunityName;

        @InvocableVariable(label='Comments')
        global String comments;
    }

    global class DecideOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(label='Quote Id')
        global String quoteId;
        @InvocableVariable(label='Quote Url')
        global String quoteUrl;
        @InvocableVariable(label='Approval Status')
        global String approvalStatus;
        @InvocableVariable(label='Message')
        global String message;
        @InvocableVariable(label='Needs Disambiguation')
        global Boolean needsDisambiguation;
        @InvocableVariable(label='Candidate Summaries Display')
        global String candidateSummariesDisplay;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    public class InvokeResult {
        public Boolean isSuccess;
        public String errorMessage;
        public InvokeResult(Boolean isSuccess, String errorMessage) {
            this.isSuccess = isSuccess;
            this.errorMessage = errorMessage;
        }
    }

    public interface DecisionInvoker {
        InvokeResult decide(Id workItemId, String decision, String comments);
    }

    public class DefaultDecisionInvoker implements DecisionInvoker {
        public InvokeResult decide(Id workItemId, String decision, String comments) {
            try {
                Invocable.Action action =
                    Invocable.Action.createStandardAction('reviewApprovalWorkItem');
                action.setInvocationParameter('approvalWorkItemId', String.valueOf(workItemId));
                action.setInvocationParameter('approvalDecision', decision);
                action.setInvocationParameter('channelType', 'InvocableAction');
                if (String.isNotBlank(comments)) {
                    action.setInvocationParameter('comments', comments);
                }
                List<Invocable.Action.Result> results = action.invoke();
                if (results == null || results.isEmpty()) {
                    return new InvokeResult(false, 'reviewApprovalWorkItem returned no result.');
                }
                if (!results[0].isSuccess()) {
                    List<String> msgs = new List<String>();
                    for (Invocable.Action.Error err : results[0].getErrors()) {
                        msgs.add(err.getMessage());
                    }
                    return new InvokeResult(false, String.join(msgs, '; '));
                }
                return new InvokeResult(true, null);
            } catch (Exception e) {
                return new InvokeResult(false, e.getMessage());
            }
        }
    }

    @TestVisible
    static DecisionInvoker invoker = new DefaultDecisionInvoker();
    @TestVisible
    static Id injectedWorkItemId;

    @InvocableMethod(
        label='Decide Revenue Cloud Quote Approval'
        description='Approves or rejects the assigned ApprovalWorkItem for a submitted quote. Caller must be an assignee. Never PATCH Quote.Status.'
    )
    global static List<DecideOutput> decide(List<DecideInput> inputs) {
        List<DecideOutput> results = new List<DecideOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (DecideInput input : inputs) {
            results.add(decideOne(input));
        }
        return results;
    }

    private static DecideOutput decideOne(DecideInput input) {
        DecideOutput out = new DecideOutput();
        out.isSuccess = false;
        out.needsDisambiguation = false;
        try {
            String decision = normalizeDecision(input == null ? null : input.decision);
            if (decision == null) {
                out.errorMessage = 'Decision must be approve or reject.';
                return out;
            }
            Quote quote = resolveQuote(input, out);
            if (quote == null) {
                return out;
            }
            out.quoteId = quote.Id;
            out.quoteUrl = RLM_MCP_RecordLinks.lightningUrl('Quote', quote.Id);
            Id workItemId = findAssignedWorkItem(quote.Id, out);
            if (workItemId == null) {
                return out;
            }
            InvokeResult decided = invoker.decide(workItemId, decision, input.comments);
            if (decided == null || decided.isSuccess != true) {
                out.errorMessage = decided != null && String.isNotBlank(decided.errorMessage)
                    ? decided.errorMessage
                    : 'Could not ' + decision.toLowerCase() + ' this approval.';
                return out;
            }
            out.isSuccess = true;
            out.approvalStatus = decision;
            List<String> rows = new List<String>{
                decision + 'd quote ' + quote.Name + '.'
            };
            String link = RLM_MCP_RecordLinks.markdown('Open Quote', 'Quote', quote.Id);
            if (String.isNotBlank(link)) {
                rows.add(link);
            }
            out.message = String.join(rows, '\n');
        } catch (Exception e) {
            out.isSuccess = false;
            out.errorMessage = e.getMessage() == null ? 'Approval decision failed.' : e.getMessage();
        }
        return out;
    }

    private static String normalizeDecision(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        String value = raw.trim().toLowerCase();
        if (value == 'approve' || value == 'approved') {
            return 'Approve';
        }
        if (value == 'reject' || value == 'rejected') {
            return 'Reject';
        }
        return null;
    }

    private static Quote resolveQuote(DecideInput input, DecideOutput out) {
        if (input != null && String.isNotBlank(input.quoteId)) {
            Id quoteId = RLM_MCP_RecordLinks.toId(input.quoteId);
            if (quoteId == null) {
                out.errorMessage = 'Invalid quote Id.';
                return null;
            }
            List<Quote> byId = [
                SELECT Id, Name
                FROM Quote
                WHERE Id = :quoteId
                WITH USER_MODE
                LIMIT 1
            ];
            if (byId.isEmpty()) {
                out.errorMessage = 'No quote found for that Id.';
                return null;
            }
            return byId[0];
        }
        if (input == null || String.isBlank(input.accountName)) {
            out.errorMessage = 'Provide a Quote Id or account name.';
            return null;
        }
        RLM_MCP_DealResolver.Result deal = RLM_MCP_DealResolver.resolve(
            input.accountName,
            input.opportunityName,
            input.quoteName
        );
        if (deal.needsDisambiguation == true) {
            out.needsDisambiguation = true;
            out.candidateSummariesDisplay = deal.candidateSummariesDisplay;
            out.errorMessage = deal.errorMessage;
            return null;
        }
        if (deal.account == null) {
            out.errorMessage = deal.errorMessage;
            return null;
        }
        if (deal.draft != null) {
            return deal.draft;
        }
        List<Quote> drafts = RLM_MCP_DealResolver.listDrafts(
            deal.account.Id,
            deal.opportunity == null ? null : deal.opportunity.Id
        );
        if (drafts.isEmpty()) {
            out.errorMessage = 'No Draft quote found for that account.';
            return null;
        }
        if (drafts.size() > 1) {
            out.needsDisambiguation = true;
            out.errorMessage = 'Several Draft quotes match. Pass quoteId or quoteName.';
            return null;
        }
        return drafts[0];
    }

    private static Id findAssignedWorkItem(Id quoteId, DecideOutput out) {
        if (injectedWorkItemId != null) {
            return injectedWorkItemId;
        }
        List<ApprovalSubmission> submissions = [
            SELECT Id
            FROM ApprovalSubmission
            WHERE RelatedRecordId = :quoteId
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 5
        ];
        Set<Id> relatedIds = new Set<Id>{ quoteId };
        for (ApprovalSubmission row : submissions) {
            relatedIds.add(row.Id);
        }
        List<ApprovalWorkItem> items = [
            SELECT Id, Status
            FROM ApprovalWorkItem
            WHERE RelatedRecordId IN :relatedIds
            AND Status = 'Assigned'
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 5
        ];
        if (items.isEmpty() && submissions.isEmpty()) {
            out.errorMessage = 'This quote has no approval submission.';
            return null;
        }
        if (items.isEmpty()) {
            out.errorMessage =
                'No assigned approval work item. The connected user may not be an assignee, or the quote is not waiting on approval.';
            return null;
        }
        if (items.size() > 1) {
            out.needsDisambiguation = true;
            out.errorMessage = 'Several assigned approval work items. Ask which step to decide.';
            return null;
        }
        return items[0].Id;
    }
}
