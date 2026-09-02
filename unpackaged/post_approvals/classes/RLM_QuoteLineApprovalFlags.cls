/**
 * Stamps QuoteLineItem.RLM_Approval_Flag__c for the Transaction Line Editor.
 *
 * TLE displayFields do not reliably render formula/calculated fields; Volume Tier
 * Discount works because it is stamped. Mirror that pattern for approval flags.
 *
 * Ladder (matches RLM_Approval_Level_Calc__c; API Discount is 0–100):
 *   &lt;15 → ✅ Auto approved | 15–24 ⚠️ Needs Manager | 25–34 ⚠️ Needs Director | ≥35 🔴 Needs VP
 *
 * Unicode prefixes keep the column scannable in TLE (no IMAGE/formula support).
 */
public inherited sharing class RLM_QuoteLineApprovalFlags {
    @TestVisible
    static Boolean bypass = false;

    @TestVisible
    static final String AUTO_APPROVED = '\u2705 Auto approved';
    @TestVisible
    static final String NEEDS_MANAGER = '\u26A0\uFE0F Needs Manager';
    @TestVisible
    static final String NEEDS_DIRECTOR = '\u26A0\uFE0F Needs Director';
    @TestVisible
    static final String NEEDS_VP = '\uD83D\uDD34 Needs VP';

    public static String flagForDiscount(Decimal discountApi) {
        if (discountApi == null) {
            return null;
        }
        // Match formula: Discount >= 1 (100%+) → 0
        if (discountApi >= 100) {
            return null;
        }
        if (discountApi < 15) {
            return AUTO_APPROVED;
        }
        if (discountApi < 25) {
            return NEEDS_MANAGER;
        }
        if (discountApi < 35) {
            return NEEDS_DIRECTOR;
        }
        return NEEDS_VP;
    }

    public static void stampLines(List<QuoteLineItem> lines) {
        if (bypass || lines == null || lines.isEmpty()) {
            return;
        }
        for (QuoteLineItem line : lines) {
            line.RLM_Approval_Flag__c = flagForDiscount(line.Discount);
        }
    }

    /** Restamp all lines on the given quotes (e.g. after bulk Discount edits). */
    public static void restampForQuotes(Set<Id> quoteIds) {
        if (bypass || quoteIds == null || quoteIds.isEmpty()) {
            return;
        }

        List<QuoteLineItem> lines = [
            SELECT Id, QuoteId, Discount, RLM_Approval_Flag__c
            FROM QuoteLineItem
            WHERE QuoteId IN :quoteIds
            WITH SYSTEM_MODE
        ];
        if (lines.isEmpty()) {
            return;
        }

        stampLines(lines);
        update as system lines;
    }
}
