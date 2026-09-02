/**
 * DocGen start for Bamboo Revenue Suite proposals.
 * Flow RLM_Bamboo_Suite_DocGen_Start and LWC share this Invocable / Aura entry;
 * poll remains on RLM_BambooRevenueSuite.getProposalStatus (performance).
 */
public with sharing class RLM_BambooSuiteDocGen {
    public class InvocableRequest {
        @InvocableVariable(required=true label='Quote Id')
        public String quoteId;
    }

    public class InvocableResult {
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
        @InvocableVariable(label='Process Id')
        public String processId;
        @InvocableVariable(label='Status')
        public String status;
        @InvocableVariable(label='Title')
        public String title;
        @InvocableVariable(label='Message')
        public String message;
    }

    @InvocableMethod(
        label='BambooHR Suite DocGen Start'
        description='Start Document Generation for a suite option Quote (RLM_Bamboo_QuoteProposal).'
        category='BambooHR'
    )
    public static List<InvocableResult> runInvocable(List<InvocableRequest> requests) {
        List<InvocableResult> out = new List<InvocableResult>();
        if (requests == null) {
            return out;
        }
        for (InvocableRequest req : requests) {
            out.add(runInvocableOne(req));
        }
        return out;
    }

    @TestVisible
    static InvocableResult runInvocableOne(InvocableRequest req) {
        InvocableResult res = new InvocableResult();
        res.isSuccess = false;
        try {
            if (req == null || String.isBlank(req.quoteId)) {
                res.errorMessage = 'quoteId is required.';
                return res;
            }
            RLM_BambooRevenueSuite.PreviewResultDTO preview =
                RLM_BambooRevenueSuite.previewProposalCore(req.quoteId.trim());
            res.isSuccess = true;
            res.processId = preview.processId == null
                ? null
                : String.valueOf(preview.processId);
            res.status = preview.status;
            res.title = preview.title;
            res.message = preview.message;
        } catch (Exception e) {
            res.errorMessage = e.getMessage();
        }
        return res;
    }

    /** LWC entry — same path as Flow RLM_Bamboo_Suite_DocGen_Start. */
    @AuraEnabled
    public static RLM_BambooRevenueSuite.PreviewResultDTO startPreview(String quoteId) {
        InvocableRequest req = new InvocableRequest();
        req.quoteId = quoteId;
        InvocableResult ir = runInvocableOne(req);
        if (ir == null || ir.isSuccess != true) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                ir != null && String.isNotBlank(ir.errorMessage)
                    ? ir.errorMessage
                    : 'DocGen start failed.'
            );
        }
        RLM_BambooRevenueSuite.PreviewResultDTO out =
            new RLM_BambooRevenueSuite.PreviewResultDTO();
        out.processId = String.isBlank(ir.processId) ? null : Id.valueOf(ir.processId);
        out.status = ir.status;
        out.title = ir.title;
        out.message = ir.message;
        return out;
    }
}
