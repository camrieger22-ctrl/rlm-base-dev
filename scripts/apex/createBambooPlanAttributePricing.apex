/**
 * BambooHR Plan attribute + pricing:
 * 1) ProductClassification / ProductClassificationAttr / ProductAttributeDefinition (price-impacting)
 * 2) AttributeAdjustmentCondition + AttributeBasedAdjustment (Core/Pro/Elite PEPM)
 *
 * Run AFTER insert_bamboohr_pcm_data + insert_bamboohr_pricing_data.
 * Monthly: Core 10 / Pro 17 / Elite 25. Annual = 12 × monthly.
 */
String suiteSku = 'BAMBOO-SUITE';
Id productId = [SELECT Id FROM Product2 WHERE StockKeepingUnit = :suiteSku LIMIT 1].Id;
Id attrDefId = [SELECT Id FROM AttributeDefinition WHERE Code = 'ATTR-BH-PLAN' LIMIT 1].Id;
Id catId = [SELECT Id FROM AttributeCategory WHERE Code = 'AC-BH-PLAN' LIMIT 1].Id;

List<ProductClassification> classes = [
    SELECT Id FROM ProductClassification WHERE Code = 'PC-BH-SUITE' LIMIT 1
];
Id classId;
if (classes.isEmpty()) {
    ProductClassification pc = new ProductClassification(
        Code = 'PC-BH-SUITE',
        Name = 'BambooHR Suite',
        Status = 'Active'
    );
    insert pc;
    classId = pc.Id;
} else {
    classId = classes[0].Id;
}

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
    pca.DefaultValue = null;
    pca.DisplayType = 'RadioButton';
    pca.HelpText = 'Select Core, Pro, or Elite';
    pca.IsHidden = false;
    pca.IsPriceImpacting = true;
    pca.IsReadOnly = false;
    pca.IsRequired = false;
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

Product2 suite = [SELECT Id, BasedOnId FROM Product2 WHERE Id = :productId];
if (suite.BasedOnId != classId) {
    suite.BasedOnId = classId;
    update suite;
}

List<ProductAttributeDefinition> pads = [
    SELECT Id, IsPriceImpacting, ProductClassificationAttributeId
    FROM ProductAttributeDefinition
    WHERE Product2Id = :productId AND AttributeDefinitionId = :attrDefId
];
if (pads.isEmpty()) {
    ProductAttributeDefinition pad = new ProductAttributeDefinition();
    pad.Product2Id = productId;
    pad.AttributeDefinitionId = attrDefId;
    pad.AttributeCategoryId = catId;
    pad.ProductClassificationAttributeId = pcaId;
    pad.Name = 'Plan';
    pad.AttributeNameOverride = 'Plan';
    pad.DefaultValue = null;
    pad.DisplayType = 'RadioButton';
    pad.HelpText = 'Select Core, Pro, or Elite';
    pad.IsHidden = false;
    pad.IsPriceImpacting = true;
    pad.IsReadOnly = false;
    pad.IsRequired = false;
    pad.Sequence = 1;
    pad.Status = 'Active';
    insert pad;
    System.debug('Created PAD Id=' + pad.Id);
} else {
    for (ProductAttributeDefinition pad : pads) {
        pad.IsPriceImpacting = true;
        if (pad.ProductClassificationAttributeId == null) {
            pad.ProductClassificationAttributeId = pcaId;
        }
    }
    update pads;
    System.debug('Updated existing PAD');
}

Map<String, Decimal> monthlyByPlan = new Map<String, Decimal>{
    'Core' => 10,
    'Pro' => 17,
    'Elite' => 25
};

Id scheduleId = [
    SELECT Id FROM PriceAdjustmentSchedule
    WHERE Name = 'Standard Attribute Based Adjustment' AND CurrencyIsoCode = 'USD'
    LIMIT 1
].Id;

Map<String, Id> psmByName = new Map<String, Id>();
for (ProductSellingModel psm : [
    SELECT Id, Name FROM ProductSellingModel
    WHERE Name IN ('Term Monthly', 'Term Annual') AND SellingModelType = 'TermDefined'
]) {
    psmByName.put(psm.Name, psm.Id);
}

Set<String> ruleNames = new Set<String>();
for (String plan : monthlyByPlan.keySet()) {
    ruleNames.add('BH_Plan_' + plan);
}
Map<String, Id> ruleIdByName = new Map<String, Id>();
for (AttributeBasedAdjRule rule : [
    SELECT Id, Name FROM AttributeBasedAdjRule WHERE Name IN :ruleNames
]) {
    ruleIdByName.put(rule.Name, rule.Id);
}

Set<Id> rulesWithConditions = new Set<Id>();
for (AggregateResult ar : [
    SELECT AttributeBasedAdjRuleId rid
    FROM AttributeAdjustmentCondition
    WHERE AttributeBasedAdjRuleId IN :ruleIdByName.values()
    GROUP BY AttributeBasedAdjRuleId
]) {
    rulesWithConditions.add((Id) ar.get('rid'));
}

List<AttributeAdjustmentCondition> conditionsToInsert = new List<AttributeAdjustmentCondition>();
for (String plan : monthlyByPlan.keySet()) {
    Id ruleId = ruleIdByName.get('BH_Plan_' + plan);
    if (ruleId == null || rulesWithConditions.contains(ruleId)) {
        continue;
    }
    AttributeAdjustmentCondition cond = new AttributeAdjustmentCondition();
    cond.AttributeBasedAdjRuleId = ruleId;
    cond.AttributeDefinitionId = attrDefId;
    cond.ProductId = productId;
    cond.Operator = 'equals';
    cond.StringValue = plan;
    conditionsToInsert.add(cond);
}
if (!conditionsToInsert.isEmpty()) {
    insert conditionsToInsert;
    System.debug('Inserted ' + conditionsToInsert.size() + ' AttributeAdjustmentCondition rows');
}

Set<Id> existingRuleIds = new Set<Id>();
for (AggregateResult ar : [
    SELECT AttributeBasedAdjRuleId rid
    FROM AttributeBasedAdjustment
    WHERE ProductId = :productId
      AND CurrencyIsoCode = 'USD'
      AND AttributeBasedAdjRuleId IN :ruleIdByName.values()
    GROUP BY AttributeBasedAdjRuleId
]) {
    existingRuleIds.add((Id) ar.get('rid'));
}

List<AttributeBasedAdjustment> toInsert = new List<AttributeBasedAdjustment>();
Datetime effectiveFrom = Datetime.newInstanceGmt(2026, 1, 1, 0, 0, 0);
Id monthlyPsm = psmByName.get('Term Monthly');
Id annualPsm = psmByName.get('Term Annual');

for (String plan : monthlyByPlan.keySet()) {
    Id ruleId = ruleIdByName.get('BH_Plan_' + plan);
    if (ruleId == null || existingRuleIds.contains(ruleId)) {
        continue;
    }
    Decimal monthly = monthlyByPlan.get(plan);

    AttributeBasedAdjustment monthlyAdj = new AttributeBasedAdjustment();
    monthlyAdj.AttributeBasedAdjRuleId = ruleId;
    monthlyAdj.PriceAdjustmentScheduleId = scheduleId;
    monthlyAdj.ProductId = productId;
    monthlyAdj.ProductSellingModelId = monthlyPsm;
    monthlyAdj.AdjustmentType = 'Override';
    monthlyAdj.AdjustmentValue = monthly;
    monthlyAdj.CurrencyIsoCode = 'USD';
    monthlyAdj.EffectiveFrom = effectiveFrom;
    toInsert.add(monthlyAdj);

    AttributeBasedAdjustment annualAdj = new AttributeBasedAdjustment();
    annualAdj.AttributeBasedAdjRuleId = ruleId;
    annualAdj.PriceAdjustmentScheduleId = scheduleId;
    annualAdj.ProductId = productId;
    annualAdj.ProductSellingModelId = annualPsm;
    annualAdj.AdjustmentType = 'Override';
    annualAdj.AdjustmentValue = monthly * 12;
    annualAdj.CurrencyIsoCode = 'USD';
    annualAdj.EffectiveFrom = effectiveFrom;
    toInsert.add(annualAdj);
}

if (!toInsert.isEmpty()) {
    insert toInsert;
    System.debug('Inserted ' + toInsert.size() + ' AttributeBasedAdjustment rows');
} else {
    System.debug('No AttributeBasedAdjustment rows to insert');
}
