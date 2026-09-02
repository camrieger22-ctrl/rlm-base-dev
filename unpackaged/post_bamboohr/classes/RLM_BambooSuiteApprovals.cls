/**
 * Thin Advanced Approvals wrappers for Bamboo Revenue Suite.
 * Process design stays in RLM_Quote_Smart_Approval. Prefer Quote Work Guide for
 * approve/reject; suite panel remains a convenience list + deep link.
 */
public with sharing class RLM_BambooSuiteApprovals {
    @AuraEnabled
    public static RLM_BambooRevenueSuite.ApprovalResultDTO submitOptionForApproval(
        String quoteId,
        String comments
    ) {
        return RLM_BambooRevenueSuite.submitOptionForApproval(quoteId, comments);
    }

    @AuraEnabled
    public static RLM_BambooRevenueSuite.PendingApprovalsDTO listPendingApprovalWorkItems(
        String quoteId
    ) {
        return RLM_BambooRevenueSuite.listPendingApprovalWorkItems(quoteId);
    }

    @AuraEnabled
    public static RLM_BambooRevenueSuite.ApprovalResultDTO reviewSuiteApprovalWorkItem(
        String workItemId,
        String decision,
        String comments
    ) {
        return RLM_BambooRevenueSuite.reviewSuiteApprovalWorkItem(
            workItemId,
            decision,
            comments
        );
    }

    @AuraEnabled
    public static RLM_BambooRevenueSuite.ApprovalResultDTO recallOptionApproval(
        String quoteId,
        String comments
    ) {
        return RLM_BambooRevenueSuite.recallOptionApproval(quoteId, comments);
    }

    /** Lightning record URL for Quote Approvals / Work Guide. */
    public static String quoteApprovalsUrl(Id quoteId) {
        if (quoteId == null) {
            return null;
        }
        return '/lightning/r/Quote/' + quoteId + '/view';
    }
}
