/**
 * After insert_bamboohr_pcm_data with 3 plan SKUs:
 * - Deactivate legacy BAMBOO-SUITE
 * - Remove Plan attribute ABA / rules (AAC is MD→rule; delete rule cascades)
 * - Remove suite from Workforce package component rows
 *
 * Note: AttributeAdjustmentCondition is not directly deletable via Apex DML.
 */
List<Product2> suite = [
    SELECT Id, IsActive FROM Product2 WHERE StockKeepingUnit = 'BAMBOO-SUITE'
];
for (Product2 p : suite) {
    p.IsActive = false;
}
if (!suite.isEmpty()) {
    update suite;
    System.debug('Deactivated BAMBOO-SUITE');
}

Set<Id> ruleIds = new Map<Id, AttributeBasedAdjRule>([
    SELECT Id FROM AttributeBasedAdjRule WHERE Name LIKE 'BH_Plan_%'
]).keySet();
if (!ruleIds.isEmpty()) {
    delete [SELECT Id FROM AttributeBasedAdjustment WHERE AttributeBasedAdjRuleId IN :ruleIds];
    delete [SELECT Id FROM AttributeBasedAdjRule WHERE Id IN :ruleIds];
    System.debug('Deleted BH_Plan_* ABA stack');
}

List<ProductRelatedComponent> suitePrcs = [
    SELECT Id FROM ProductRelatedComponent
    WHERE ChildProduct.StockKeepingUnit = 'BAMBOO-SUITE'
       OR ParentProduct.StockKeepingUnit = 'BAMBOO-SUITE'
];
if (!suitePrcs.isEmpty()) {
    delete suitePrcs;
    System.debug('Deleted suite ProductRelatedComponent rows: ' + suitePrcs.size());
}

List<ProductCategoryProduct> suiteCats = [
    SELECT Id FROM ProductCategoryProduct
    WHERE Product.StockKeepingUnit = 'BAMBOO-SUITE'
];
if (!suiteCats.isEmpty()) {
    delete suiteCats;
    System.debug('Deleted suite category links: ' + suiteCats.size());
}

System.debug('Bamboo 3-SKU migration cleanup complete');
