/**
 * Suite list PEPM = Elite ($25 monthly / $300 annual). Nonprofit = 85%.
 * Core/Pro stay as AttributeBasedAdjustment Overrides below list.
 */
List<PricebookEntry> pbes = [
    SELECT Id, UnitPrice, Pricebook2.Name, ProductSellingModel.Name
    FROM PricebookEntry
    WHERE Product2.StockKeepingUnit = 'BAMBOO-SUITE'
];
for (PricebookEntry pbe : pbes) {
    Decimal mult = pbe.Pricebook2.Name == 'Nonprofit' ? 0.85 : 1;
    if (pbe.ProductSellingModel.Name == 'Term Monthly') {
        pbe.UnitPrice = 25 * mult;
    } else if (pbe.ProductSellingModel.Name == 'Term Annual') {
        pbe.UnitPrice = 300 * mult;
    }
}
update pbes;
System.debug('Updated ' + pbes.size() + ' BAMBOO-SUITE PBEs to Elite list');
