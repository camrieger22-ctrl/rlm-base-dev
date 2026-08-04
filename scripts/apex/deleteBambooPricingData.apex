/**
 * Delete BambooHR-scoped pricing Insert rows only (SKU prefix BAMBOO-).
 * Safe alongside QuantumBit — does not wipe all org PricebookEntry / tier rows.
 *
 * Deactivates shared PAS so tiers can be deleted. Leaves schedules inactive for
 * `activate_price_adjustment_schedules` to re-enable after insert.
 *
 * AttributeAdjustmentCondition is not deletable via Apex; ABA + rules cleaned instead.
 */
List<Product2> bambooProducts = [
    SELECT Id FROM Product2 WHERE StockKeepingUnit LIKE 'BAMBOO-%'
];
if (bambooProducts.isEmpty()) {
    System.debug('No BAMBOO-* products; nothing to delete');
    return;
}
Set<Id> productIds = new Map<Id, Product2>(bambooProducts).keySet();

List<PriceAdjustmentSchedule> schedules = [
    SELECT Id, IsActive, Name
    FROM PriceAdjustmentSchedule
    WHERE Name IN (
        'Standard Price Adjustment Tier',
        'Standard Bundle Based Adjustment',
        'Standard Attribute Based Adjustment'
    )
    AND IsActive = true
];
for (PriceAdjustmentSchedule s : schedules) {
    s.IsActive = false;
}
if (!schedules.isEmpty()) {
    update schedules;
    System.debug('Deactivated ' + schedules.size() + ' price adjustment schedules');
}

delete [
    SELECT Id FROM BundleBasedAdjustment
    WHERE ProductId IN :productIds
       OR ParentProductId IN :productIds
       OR RootBundleId IN :productIds
];
delete [SELECT Id FROM AttributeBasedAdjustment WHERE ProductId IN :productIds];

Set<Id> planRuleIds = new Map<Id, AttributeBasedAdjRule>([
    SELECT Id FROM AttributeBasedAdjRule WHERE Name LIKE 'BH_Plan_%'
]).keySet();
if (!planRuleIds.isEmpty()) {
    delete [SELECT Id FROM AttributeBasedAdjustment WHERE AttributeBasedAdjRuleId IN :planRuleIds];
    try {
        delete [SELECT Id FROM AttributeBasedAdjRule WHERE Id IN :planRuleIds];
    } catch (DmlException e) {
        System.debug('Could not delete BH_Plan_* rules (AAC may block): ' + e.getMessage());
    }
}

delete [SELECT Id FROM PriceAdjustmentTier WHERE Product2Id IN :productIds];

List<PricebookEntry> pbes = [
    SELECT Id, IsActive FROM PricebookEntry WHERE Product2Id IN :productIds
];
if (!pbes.isEmpty()) {
    Database.DeleteResult[] results = Database.delete(pbes, false);
    Integer failed = 0;
    List<PricebookEntry> deactivate = new List<PricebookEntry>();
    for (Integer i = 0; i < results.size(); i++) {
        if (!results[i].isSuccess()) {
            failed++;
            PricebookEntry p = pbes[i];
            if (p.IsActive) {
                p.IsActive = false;
                deactivate.add(p);
            }
        }
    }
    if (!deactivate.isEmpty()) {
        update deactivate;
    }
    System.debug('PBE delete attempted=' + pbes.size() + ' failed=' + failed + ' deactivated=' + deactivate.size());
}

System.debug('Deleted BambooHR pricing rows for ' + productIds.size() + ' products');
