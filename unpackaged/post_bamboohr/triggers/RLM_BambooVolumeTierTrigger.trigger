/**
 * Stamps BambooHR volume-tier coach fields on Quote Line Items before save.
 * Eligible SKUs: BAMBOO-* except BAMBOO-PKG-* (package header has no volume PAT).
 */
trigger RLM_BambooVolumeTierTrigger on QuoteLineItem (before insert, before update) {
    if (Trigger.isBefore && (Trigger.isInsert || Trigger.isUpdate)) {
        RLM_BambooVolumeTiers.stampLines(Trigger.new);
    }
}
