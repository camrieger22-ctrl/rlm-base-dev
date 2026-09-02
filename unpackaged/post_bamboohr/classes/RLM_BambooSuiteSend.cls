/**
 * Suite Send to customer — validates priced suite option, then QuoteEmail.
 * Flow RLM_Bamboo_Suite_Send and LWC share this Invocable / Aura entry.
 */
public with sharing class RLM_BambooSuiteSend {
    public class InvocableRequest {
        @InvocableVariable(required=true label='Quote Id')
        public String quoteId;
        @InvocableVariable(label='Contact Id')
        public String contactId;
        @InvocableVariable(label='To address override')
        public String toAddress;
        @InvocableVariable(label='Attach PDF')
        public Boolean attachPdf;
        @InvocableVariable(label='Generate PDF if missing')
        public Boolean generatePdfIfMissing;
    }

    public class InvocableResult {
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
        @InvocableVariable(label='Message')
        public String message;
        @InvocableVariable(label='To Address')
        public String toAddress;
        @InvocableVariable(label='Quote Id')
        public String quoteId;
        @InvocableVariable(label='Content Version Id')
        public String contentVersionId;
    }

    @InvocableMethod(
        label='BambooHR Suite Send to Customer'
        description='Email a priced suite option Quote via RLM_BambooQuoteEmail.'
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
            RLM_BambooRevenueSuite.SendResultDTO sent =
                RLM_BambooRevenueSuite.sendOptionToCustomerCore(
                    req.quoteId,
                    req.contactId,
                    req.toAddress,
                    req.attachPdf,
                    req.generatePdfIfMissing
                );
            res.isSuccess = sent.success == true;
            res.message = sent.message;
            res.toAddress = sent.toAddress;
            res.quoteId = sent.quoteId == null ? null : String.valueOf(sent.quoteId);
            res.contentVersionId = sent.contentVersionId == null
                ? null
                : String.valueOf(sent.contentVersionId);
            if (!res.isSuccess) {
                res.errorMessage = String.isNotBlank(sent.message)
                    ? sent.message
                    : 'Send email failed.';
            }
        } catch (Exception e) {
            res.errorMessage = e.getMessage();
        }
        return res;
    }

    /** LWC entry — same path as Flow RLM_Bamboo_Suite_Send. */
    @AuraEnabled
    public static RLM_BambooRevenueSuite.SendResultDTO sendOptionToCustomer(
        String quoteId,
        String contactId,
        String toAddress,
        Boolean attachPdf,
        Boolean generatePdfIfMissing
    ) {
        InvocableRequest req = new InvocableRequest();
        req.quoteId = quoteId;
        req.contactId = contactId;
        req.toAddress = toAddress;
        req.attachPdf = attachPdf;
        req.generatePdfIfMissing = generatePdfIfMissing;
        InvocableResult ir = runInvocableOne(req);
        if (ir == null || ir.isSuccess != true) {
            throw new RLM_BambooRevenueSuite.SuiteException(
                ir != null && String.isNotBlank(ir.errorMessage)
                    ? ir.errorMessage
                    : 'Send email failed.'
            );
        }
        RLM_BambooRevenueSuite.SendResultDTO out =
            new RLM_BambooRevenueSuite.SendResultDTO();
        out.success = true;
        out.message = ir.message;
        out.toAddress = ir.toAddress;
        out.quoteId = String.isBlank(ir.quoteId) ? null : Id.valueOf(ir.quoteId);
        out.contentVersionId = String.isBlank(ir.contentVersionId)
            ? null
            : Id.valueOf(ir.contentVersionId);
        return out;
    }
}
