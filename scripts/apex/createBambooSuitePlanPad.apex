/**
 * Ensure BambooHR Suite has a price-impacting Plan ProductAttributeDefinition.
 * Requires ProductClassification PC-BH-SUITE + ProductClassificationAttr Name=Plan.
 */
Id productId = [SELECT Id FROM Product2 WHERE StockKeepingUnit = 'BAMBOO-SUITE' LIMIT 1].Id;
Id attrDefId = [SELECT Id FROM AttributeDefinition WHERE Code = 'ATTR-BH-PLAN' LIMIT 1].Id;
Id catId = [SELECT Id FROM AttributeCategory WHERE Code = 'AC-BH-PLAN' LIMIT 1].Id;
Id classId = [SELECT Id FROM ProductClassification WHERE Code = 'PC-BH-SUITE' LIMIT 1].Id;

// Ensure classification attr
List<ProductClassificationAttr> pcas = [
    SELECT Id, IsPriceImpacting FROM ProductClassificationAttr
    WHERE ProductClassificationId = :classId AND AttributeDefinitionId = :attrDefId
    LIMIT 1
];
Id pcaId;
if (pcas.isEmpty()) {
    ProductClassificationAttr pca = new ProductClassificationAttr();
    pca.ProductClassificationId = classId;
    pca.AttributeDefinitionId = attrDefId;
    pca.AttributeCategoryId = catId;
    pca.Name = 'Plan';
    pca.AttributeNameOverride = 'Plan';
    pca.DefaultValue = 'Core';
    pca.DisplayType = 'RadioButton';
    pca.HelpText = 'Select Core, Pro, or Elite';
    pca.IsHidden = false;
    pca.IsPriceImpacting = true;
    pca.IsReadOnly = false;
    pca.IsRequired = true;
    pca.Sequence = 1;
    pca.Status = 'Active';
    insert pca;
    pcaId = pca.Id;
} else {
    pcaId = pcas[0].Id;
    if (pcas[0].IsPriceImpacting != true) {
        pcas[0].IsPriceImpacting = true;
        update pcas;
    }
}

// Bind product to classification if needed
Product2 suite = [SELECT Id, BasedOnId FROM Product2 WHERE Id = :productId];
if (suite.BasedOnId != classId) {
    suite.BasedOnId = classId;
    update suite;
}

Integer existing = [
    SELECT COUNT() FROM ProductAttributeDefinition
    WHERE Product2Id = :productId AND AttributeDefinitionId = :attrDefId
];
if (existing > 0) {
    List<ProductAttributeDefinition> pads = [
        SELECT Id, IsPriceImpacting, ProductClassificationAttributeId
        FROM ProductAttributeDefinition
        WHERE Product2Id = :productId AND AttributeDefinitionId = :attrDefId
    ];
    for (ProductAttributeDefinition pad : pads) {
        pad.IsPriceImpacting = true;
        if (pad.ProductClassificationAttributeId == null) {
            pad.ProductClassificationAttributeId = pcaId;
        }
    }
    update pads;
    System.debug('Updated existing PAD');
} else {
    ProductAttributeDefinition pad = new ProductAttributeDefinition();
    pad.Product2Id = productId;
    pad.AttributeDefinitionId = attrDefId;
    pad.AttributeCategoryId = catId;
    pad.ProductClassificationAttributeId = pcaId;
    pad.Name = 'Plan';
    pad.AttributeNameOverride = 'Plan';
    pad.DefaultValue = 'Core';
    pad.DisplayType = 'RadioButton';
    pad.HelpText = 'Select Core, Pro, or Elite';
    pad.IsHidden = false;
    pad.IsPriceImpacting = true;
    pad.IsReadOnly = false;
    pad.IsRequired = true;
    pad.Sequence = 1;
    pad.Status = 'Active';
    insert pad;
    System.debug('PAD Id=' + pad.Id);
}
