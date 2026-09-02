/**
 * When Quote approval status changes, restamp line Approval flags from Disc %.
 * (Kept so status transitions still refresh the TLE column after bulk edits.)
 */
trigger RLM_QuoteApprovalFlagClearTrigger on Quote (after update) {
    Set<Id> changed = new Set<Id>();
    for (Quote q : Trigger.new) {
        Quote oldQ = Trigger.oldMap.get(q.Id);
        if (q.RLM_Approval_Status__c != oldQ.RLM_Approval_Status__c) {
            changed.add(q.Id);
        }
    }
    if (!changed.isEmpty()) {
        RLM_QuoteLineApprovalFlags.restampForQuotes(changed);
    }
}
