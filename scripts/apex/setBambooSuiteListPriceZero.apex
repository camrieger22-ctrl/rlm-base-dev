/**
 * Set BAMBOO-SUITE PricebookEntry UnitPrice to 0 so Plan ABA owns Core/Pro/Elite list.
 */
List<PricebookEntry> pbes = [
    SELECT Id, UnitPrice, Pricebook2.Name, ProductSellingModel.Name
    FROM PricebookEntry
    WHERE Product2.StockKeepingUnit = 'BAMBOO-SUITE'
];
for (PricebookEntry pbe : pbes) {
    pbe.UnitPrice = 0;
}
update pbes;
System.debug('Updated ' + pbes.size() + ' BAMBOO-SUITE PBEs to UnitPrice=0');
