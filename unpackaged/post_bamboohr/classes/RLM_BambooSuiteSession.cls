/**
 * Session / option lifecycle for Bamboo Revenue Suite.
 * Owns open / session field assembly helpers; Aura entry points remain on
 * RLM_BambooRevenueSuite as a thin façade.
 */
public with sharing class RLM_BambooSuiteSession {
    /**
     * Opportunity load for any path that later calls toSession.
     * Always includes RLM_BambooSuiteSync.OPP_SESSION_FIELDS.
     */
    public static Opportunity requireSessionOpportunity(Id opportunityId) {
        return RLM_BambooSuiteSync.loadOpp(opportunityId);
    }

    /** Pause forecast sync when opening the suite (Editing mode). */
    public static RLM_BambooSuiteSync.SyncResult enterEditMode(Id opportunityId) {
        return RLM_BambooSuiteSync.pauseForEditing(opportunityId);
    }
}
