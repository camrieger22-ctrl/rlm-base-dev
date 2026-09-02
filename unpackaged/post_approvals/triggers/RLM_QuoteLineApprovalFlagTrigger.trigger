/**
 * Stamps RLM_Approval_Flag__c on Quote lines for TLE (formula fields do not render there).
 */
trigger RLM_QuoteLineApprovalFlagTrigger on QuoteLineItem (before insert, before update) {
    if (Trigger.isBefore && (Trigger.isInsert || Trigger.isUpdate)) {
        RLM_QuoteLineApprovalFlags.stampLines(Trigger.new);
    }
}
