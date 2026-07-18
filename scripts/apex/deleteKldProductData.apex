// Delete KLDiscovery (KLD-*) product catalog data only — leaves QuantumBit intact.
// Safe for Option B reload on a shared org (e.g. camkld).
// Does NOT use delete_kld_pricing_data (that clears ALL PricebookEntry / PAT / CBE).
//
// Order: transaction lines → pricing → bundle structure → attributes → products.

List<Product2> kldProducts = [
    SELECT Id, StockKeepingUnit
    FROM Product2
    WHERE StockKeepingUnit LIKE 'KLD-%'
];
Set<Id> kldIds = new Map<Id, Product2>(kldProducts).keySet();
System.debug('KLD products to remove: ' + kldProducts.size());

if (kldIds.isEmpty()) {
    System.debug('No KLD products found. Nothing to delete.');
} else {
    // Quote lines block Product2 delete
    List<QuoteLineItem> qlis = [
        SELECT Id FROM QuoteLineItem WHERE Product2Id IN :kldIds
    ];
    if (!qlis.isEmpty()) {
        delete qlis;
        System.debug('Deleted QuoteLineItem: ' + qlis.size());
    }

    List<OrderItem> ois = [
        SELECT Id FROM OrderItem WHERE Product2Id IN :kldIds
    ];
    if (!ois.isEmpty()) {
        delete ois;
        System.debug('Deleted OrderItem: ' + ois.size());
    }

    List<PriceAdjustmentTier> pats = [
        SELECT Id FROM PriceAdjustmentTier WHERE Product2Id IN :kldIds
    ];
    if (!pats.isEmpty()) {
        delete pats;
        System.debug('Deleted PriceAdjustmentTier: ' + pats.size());
    }

    List<CostBookEntry> cbes = [
        SELECT Id FROM CostBookEntry WHERE ProductId IN :kldIds
    ];
    if (!cbes.isEmpty()) {
        delete cbes;
        System.debug('Deleted CostBookEntry: ' + cbes.size());
    }

    List<PricebookEntry> pbes = [
        SELECT Id FROM PricebookEntry WHERE Product2Id IN :kldIds
    ];
    if (!pbes.isEmpty()) {
        delete pbes;
        System.debug('Deleted PricebookEntry: ' + pbes.size());
    }

    List<ProductRelatedComponent> prcs = [
        SELECT Id
        FROM ProductRelatedComponent
        WHERE ParentProductId IN :kldIds OR ChildProductId IN :kldIds
    ];
    if (!prcs.isEmpty()) {
        delete prcs;
        System.debug('Deleted ProductRelatedComponent: ' + prcs.size());
    }

    List<ProductComponentGroup> groups = [
        SELECT Id FROM ProductComponentGroup WHERE ParentProductId IN :kldIds
    ];
    if (!groups.isEmpty()) {
        delete groups;
        System.debug('Deleted ProductComponentGroup: ' + groups.size());
    }

    List<ProductAttributeDefinition> pads = [
        SELECT Id FROM ProductAttributeDefinition WHERE Product2Id IN :kldIds
    ];
    if (!pads.isEmpty()) {
        delete pads;
        System.debug('Deleted ProductAttributeDefinition: ' + pads.size());
    }

    List<ProductSellingModelOption> psmos = [
        SELECT Id FROM ProductSellingModelOption WHERE Product2Id IN :kldIds
    ];
    if (!psmos.isEmpty()) {
        delete psmos;
        System.debug('Deleted ProductSellingModelOption: ' + psmos.size());
    }

    List<ProductCategoryProduct> pcps = [
        SELECT Id FROM ProductCategoryProduct WHERE ProductId IN :kldIds
    ];
    if (!pcps.isEmpty()) {
        delete pcps;
        System.debug('Deleted ProductCategoryProduct: ' + pcps.size());
    }

    // ESC rows that pin obsolete pathway types (re-import will recreate)
    List<ExpressionSetConstraintObj> escs = [
        SELECT Id
        FROM ExpressionSetConstraintObj
        WHERE ExpressionSet.ApiName = 'KLDPathway'
           OR ReferenceObjectId IN :kldIds
    ];
    if (!escs.isEmpty()) {
        delete escs;
        System.debug('Deleted ExpressionSetConstraintObj: ' + escs.size());
    }

    delete kldProducts;
    System.debug('Deleted Product2: ' + kldProducts.size());
}

System.debug('KLD product cleanup complete.');
