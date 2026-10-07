/**
 * Global MCP wrapper that submits a Revenue Cloud Quote for approval by quote
 * name, account name, or Quote Id.
 *
 * Implementation boundary (same pattern as RLM_AI_AddProductToQuoteService):
 * this Apex is a RESOLVER, not an approval engine. It finds the single Draft
 * quote the user means (or returns candidates when ambiguous), then invokes the
 * native flow approval process RLM_Quote_Smart_Approval. Approval routing, steps
 * and approvers stay in the flow.
 *
 * Flow inputs (verified in org): recordId, submitter, submissionComments, firstApprover.
 */
global with sharing class RLM_MCP_SubmitQuoteForApproval {
    private static final String APPROVAL_FLOW = 'RLM_Quote_Smart_Approval';
    private static final Integer MAX_CANDIDATES = 50;

    global class SubmitInput {
        @InvocableVariable(
            label='Quote Id'
            description='Optional 18-character Quote Id (starts with 0Q0). Takes precedence over names.'
        )
        global String quoteId;

        @InvocableVariable(
            label='Quote Name'
            description='Quote name or fragment from the user, e.g. Claude MCP Test. Also matched against the account name, so "Acme" works.'
        )
        global String quoteName;

        @InvocableVariable(
            label='Account Name'
            description='Optional account name to narrow the search, e.g. Acme.'
        )
        global String accountName;

        @InvocableVariable(
            label='Comments'
            description='Optional submission comments shown to approvers.'
        )
        global String comments;

        @InvocableVariable(
            label='First Approver'
            description='Optional. Only when the user names a specific first approver (User Id).'
        )
        global String firstApprover;
    }

    global class SubmitOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(label='Message')
        global String message;
        @InvocableVariable(label='Quote Id')
        global String quoteId;
        @InvocableVariable(
            label='Quote Url'
            description='Lightning Quote page. Render as [Open Quote](quoteUrl) in the chat reply.'
        )
        global String quoteUrl;
        @InvocableVariable(label='Quote Name')
        global String quoteName;
        @InvocableVariable(label='Approval Submission Id')
        global String approvalSubmissionId;
        @InvocableVariable(label='Approval Status')
        global String approvalStatus;
        @InvocableVariable(label='Needs Disambiguation')
        global Boolean needsDisambiguation;
        @InvocableVariable(label='Candidate Summaries Display')
        global String candidateSummariesDisplay;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(
        label='Submit Revenue Cloud Quote for Approval'
        description='Submits a Draft quote for approval by quote name, account name, or Quote Id. Ask the user to pick when more than one quote matches.'
    )
    global static List<SubmitOutput> submit(List<SubmitInput> inputs) {
        List<SubmitOutput> results = new List<SubmitOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (SubmitInput input : inputs) {
            results.add(submitOne(input));
        }
        return results;
    }

    private static SubmitOutput submitOne(SubmitInput input) {
        SubmitOutput out = new SubmitOutput();
        out.isSuccess = false;
        out.needsDisambiguation = false;
        try {
            if (input == null) {
                out.errorMessage = 'Provide a quote name, account name, or Quote Id.';
                return out;
            }

            // 1. Resolve the quote.
            Quote q = resolveQuote(input, out);
            if (q == null) {
                return out;
            }
            out.quoteId = q.Id;
            out.quoteUrl = RLM_MCP_RecordLinks.lightningUrl('Quote', q.Id);
            out.quoteName = q.Name;

            // 2. Validate it can be submitted.
            if (q.Status != 'Draft') {
                out.errorMessage = 'Quote ' + q.Name + ' is in status ' + q.Status
                    + '. Only Draft quotes can be submitted.';
                return out;
            }
            if (q.LineItemCount == null || q.LineItemCount == 0) {
                out.errorMessage = 'Quote ' + q.Name + ' has no lines. Add a product before submitting.';
                return out;
            }

            // 3. Start the native approval flow.
            Map<String, Object> params = new Map<String, Object>{
                'recordId' => String.valueOf(q.Id),
                'submitter' => UserInfo.getUserId()
            };
            if (String.isNotBlank(input.comments)) {
                params.put('submissionComments', input.comments);
            }
            if (String.isNotBlank(input.firstApprover)) {
                params.put('firstApprover', input.firstApprover);
            }
            InvokeResult r = invoker.start(params);
            if (r == null || r.isSuccess != true) {
                out.errorMessage = 'The approval flow did not start: '
                    + (r != null && String.isNotBlank(r.errorMessage) ? r.errorMessage : 'no details returned.');
                return out;
            }

            // 4. Report the resulting submission.
            out.isSuccess = true;
            List<ApprovalSubmission> subs = [
                SELECT Id, Status
                FROM ApprovalSubmission
                WHERE RelatedRecordId = :q.Id
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
            String quoteLink = RLM_MCP_RecordLinks.markdown('Open Quote', 'Quote', q.Id);
            if (subs.isEmpty()) {
                out.message = 'Submitted **' + q.Name + '** for approval. No approval submission is visible yet; check the quote shortly.';
            } else {
                out.approvalSubmissionId = subs[0].Id;
                out.approvalStatus = String.valueOf(subs[0].Status);
                out.message = 'Submitted **' + q.Name + '** for approval. Status: ' + out.approvalStatus + '.';
            }
            if (String.isNotBlank(quoteLink)) {
                out.message += '\n' + quoteLink;
            }
        } catch (Exception e) {
            out.isSuccess = false;
            out.errorMessage = e.getMessage();
        }
        return out;
    }

    /**
     * Returns the single quote the user means, or null with an error or
     * disambiguation payload on `out`.
     */
    private static Quote resolveQuote(SubmitInput input, SubmitOutput out) {
        if (String.isNotBlank(input.quoteId)) {
            Id qid = toQuoteId(input.quoteId);
            if (qid == null) {
                out.errorMessage = 'Invalid Quote Id: ' + input.quoteId;
                return null;
            }
            List<Quote> byId = [
                SELECT Id, Name, Status, LineItemCount, GrandTotal, Account.Name
                FROM Quote WHERE Id = :qid LIMIT 1
            ];
            if (byId.isEmpty()) {
                out.errorMessage = 'No quote found for Id ' + qid + '.';
                return null;
            }
            return byId[0];
        }

        String nameTerm = String.isBlank(input.quoteName) ? null : input.quoteName.trim();
        String acctTerm = String.isBlank(input.accountName) ? null : input.accountName.trim();
        if (nameTerm == null && acctTerm == null) {
            out.errorMessage = 'Provide a quote name, account name, or Quote Id.';
            return null;
        }

        List<Quote> matches = findDraftQuotes(nameTerm, acctTerm);
        if (matches.isEmpty()) {
            out.errorMessage = 'No draft quote found matching "'
                + (nameTerm != null ? nameTerm : acctTerm) + '".';
            return null;
        }

        // An exact quote-name match wins outright.
        if (nameTerm != null) {
            List<Quote> exact = new List<Quote>();
            for (Quote m : matches) {
                if (m.Name != null && m.Name.equalsIgnoreCase(nameTerm)) {
                    exact.add(m);
                }
            }
            if (exact.size() == 1) {
                return exact[0];
            }
        }

        // Only quotes with lines can be submitted, so drop empty drafts.
        List<Quote> submittable = new List<Quote>();
        List<String> emptyNames = new List<String>();
        for (Quote m : matches) {
            if (m.LineItemCount != null && m.LineItemCount > 0) {
                submittable.add(m);
            } else {
                emptyNames.add(m.Name);
            }
        }
        if (submittable.isEmpty()) {
            out.errorMessage = 'The matching draft quotes have no lines: '
                + String.join(emptyNames, ', ') + '. Add a product before submitting.';
            return null;
        }
        if (submittable.size() == 1) {
            return submittable[0];
        }

        out.needsDisambiguation = true;
        out.candidateSummariesDisplay = buildCandidateDisplay(submittable);
        out.errorMessage = 'Multiple draft quotes match. Ask the user which one to submit.';
        return null;
    }

    private static List<Quote> findDraftQuotes(String nameTerm, String acctTerm) {
        String np = nameTerm == null ? null : '%' + nameTerm + '%';
        String ap = acctTerm == null ? null : '%' + acctTerm + '%';
        if (np != null && ap != null) {
            return [
                SELECT Id, Name, Status, LineItemCount, GrandTotal, Account.Name
                FROM Quote
                WHERE Status = 'Draft'
                AND (Name LIKE :np OR Account.Name LIKE :np)
                AND Account.Name LIKE :ap
                ORDER BY LastModifiedDate DESC
                LIMIT :MAX_CANDIDATES
            ];
        }
        if (np != null) {
            return [
                SELECT Id, Name, Status, LineItemCount, GrandTotal, Account.Name
                FROM Quote
                WHERE Status = 'Draft'
                AND (Name LIKE :np OR Account.Name LIKE :np)
                ORDER BY LastModifiedDate DESC
                LIMIT :MAX_CANDIDATES
            ];
        }
        return [
            SELECT Id, Name, Status, LineItemCount, GrandTotal, Account.Name
            FROM Quote
            WHERE Status = 'Draft'
            AND Account.Name LIKE :ap
            ORDER BY LastModifiedDate DESC
            LIMIT :MAX_CANDIDATES
        ];
    }

    private static String buildCandidateDisplay(List<Quote> quotes) {
        List<String> lines = new List<String>();
        lines.add('Multiple draft quotes match. Which one should I submit?');
        Integer ordinal = 1;
        for (Quote q : quotes) {
            String line = ordinal + '. **' + q.Name + '**';
            if (q.Account != null && String.isNotBlank(q.Account.Name)) {
                line += ' (' + q.Account.Name + ')';
            }
            line += ', ' + q.LineItemCount + (q.LineItemCount == 1 ? ' line' : ' lines');
            if (q.GrandTotal != null) {
                line += ', $' + String.valueOf(q.GrandTotal.setScale(2));
            }
            String quoteLink = RLM_MCP_RecordLinks.markdown('Open', 'Quote', q.Id);
            if (String.isNotBlank(quoteLink)) {
                line += ' · ' + quoteLink;
            }
            lines.add(line);
            ordinal++;
        }
        return String.join(lines, '\n');
    }

    private static Id toQuoteId(String raw) {
        try {
            Id parsed = Id.valueOf(raw.trim());
            return parsed.getSObjectType() == Quote.SObjectType ? parsed : null;
        } catch (Exception e) {
            return null;
        }
    }

    // ---- Approval flow invocation seam (injectable for tests) ----

    public class InvokeResult {
        public Boolean isSuccess;
        public String errorMessage;
        public InvokeResult(Boolean isSuccess, String errorMessage) {
            this.isSuccess = isSuccess;
            this.errorMessage = errorMessage;
        }
    }

    public interface ApprovalFlowInvoker {
        InvokeResult start(Map<String, Object> params);
    }

    /**
     * Default invoker: starts RLM_Quote_Smart_Approval via Invocable.Action,
     * the same call pattern RLM_AI_AddProductToQuoteService uses for the
     * managed add-line flow.
     */
    public class DefaultApprovalFlowInvoker implements ApprovalFlowInvoker {
        public InvokeResult start(Map<String, Object> params) {
            Invocable.Action action = Invocable.Action.createCustomAction('flow', APPROVAL_FLOW);
            for (String key : params.keySet()) {
                action.setInvocationParameter(key, params.get(key));
            }
            List<Invocable.Action.Result> results = action.invoke();
            if (results.isEmpty()) {
                return new InvokeResult(false, 'The approval flow returned no result.');
            }
            if (!results[0].isSuccess()) {
                List<String> msgs = new List<String>();
                for (Invocable.Action.Error e : results[0].getErrors()) {
                    msgs.add(e.getMessage());
                }
                return new InvokeResult(false, String.join(msgs, '; '));
            }
            return new InvokeResult(true, null);
        }
    }

    @TestVisible
    private static ApprovalFlowInvoker invoker = new DefaultApprovalFlowInvoker();
}