/**
 * Syncs Quote.RLM_Bamboo_PathB_BundleSave__c after Quote Line Item changes.
 */
trigger RLM_BambooPathBBundleSaveTrigger on QuoteLineItem (
    after insert,
    after update,
    after delete,
    after undelete
) {
    if (Trigger.isAfter) {
        if (Trigger.isInsert || Trigger.isUpdate || Trigger.isUndelete) {
            RLM_BambooPathBBundleSave.syncFromLineItems(Trigger.new);
        } else if (Trigger.isDelete) {
            RLM_BambooPathBBundleSave.syncFromLineItems(Trigger.old);
        }
    }
}
