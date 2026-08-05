/**
 * Maintains Quote.RLM_Bamboo_PathB_BundleSave__c for a la carte Bundle &amp; Save.
 *
 * Eligible when the quote has:
 *   - at least one of BAMBOO-CORE / BAMBOO-PRO / BAMBOO-ELITE
 *   - BAMBOO-ADD-PAYROLL
 *   - BAMBOO-ADD-BENEFITS
 *   - and no BAMBOO-PKG-* header (Path A uses BundleBasedAdjustment instead)
 */
public inherited sharing class RLM_BambooPathBBundleSave {

    private static final Set<String> PLAN_SKUS = new Set<String>{
        'BAMBOO-CORE',
        'BAMBOO-PRO',
        'BAMBOO-ELITE'
    };
    private static final String PAYROLL_SKU = 'BAMBOO-ADD-PAYROLL';
    private static final String BENEFITS_SKU = 'BAMBOO-ADD-BENEFITS';
    private static final String PACKAGE_PREFIX = 'BAMBOO-PKG-';

    /** Test-only overrides so SeeAllData=false tests can use unique SKUs. */
    @TestVisible
    private static Set<String> planSkuOverrides;
    @TestVisible
    private static String payrollSkuOverride;
    @TestVisible
    private static String benefitsSkuOverride;

    public static void syncFromLineItems(List<QuoteLineItem> lines) {
        if (lines == null || lines.isEmpty()) {
            return;
        }
        Set<Id> quoteIds = new Set<Id>();
        for (QuoteLineItem line : lines) {
            if (line.QuoteId != null) {
                quoteIds.add(line.QuoteId);
            }
        }
        syncQuotes(quoteIds);
    }

    public static void syncQuotes(Set<Id> quoteIds) {
        if (quoteIds == null || quoteIds.isEmpty()) {
            return;
        }

        Map<Id, Boolean> eligibleByQuote = new Map<Id, Boolean>();
        for (Id quoteId : quoteIds) {
            eligibleByQuote.put(quoteId, false);
        }

        Map<Id, Set<String>> skusByQuote = new Map<Id, Set<String>>();
        for (QuoteLineItem line : [
            SELECT QuoteId, Product2.StockKeepingUnit
            FROM QuoteLineItem
            WHERE QuoteId IN :quoteIds
        ]) {
            if (line.QuoteId == null || line.Product2 == null) {
                continue;
            }
            String sku = line.Product2.StockKeepingUnit;
            if (String.isBlank(sku)) {
                continue;
            }
            if (!skusByQuote.containsKey(line.QuoteId)) {
                skusByQuote.put(line.QuoteId, new Set<String>());
            }
            skusByQuote.get(line.QuoteId).add(sku.toUpperCase());
        }

        for (Id quoteId : quoteIds) {
            eligibleByQuote.put(quoteId, isEligible(skusByQuote.get(quoteId)));
        }

        List<Quote> toUpdate = new List<Quote>();
        for (Quote q : [
            SELECT Id, RLM_Bamboo_PathB_BundleSave__c
            FROM Quote
            WHERE Id IN :quoteIds
        ]) {
            Boolean desired = eligibleByQuote.get(q.Id) == true;
            if (q.RLM_Bamboo_PathB_BundleSave__c != desired) {
                toUpdate.add(
                    new Quote(Id = q.Id, RLM_Bamboo_PathB_BundleSave__c = desired)
                );
            }
        }
        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
    }

    @TestVisible
    private static Boolean isEligible(Set<String> skus) {
        if (skus == null || skus.isEmpty()) {
            return false;
        }
        Set<String> plans = planSkuOverrides != null ? planSkuOverrides : PLAN_SKUS;
        String payroll = payrollSkuOverride != null ? payrollSkuOverride : PAYROLL_SKU;
        String benefits = benefitsSkuOverride != null ? benefitsSkuOverride : BENEFITS_SKU;
        Boolean hasPlan = false;
        Boolean hasPackage = false;
        for (String sku : skus) {
            if (plans.contains(sku)) {
                hasPlan = true;
            }
            if (sku.startsWith(PACKAGE_PREFIX)) {
                hasPackage = true;
            }
        }
        return hasPlan
            && !hasPackage
            && skus.contains(payroll)
            && skus.contains(benefits);
    }
}
