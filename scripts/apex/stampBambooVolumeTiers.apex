/**
 * Backfill BambooHR volume-tier coach fields on existing Quote Line Items.
 * Run after deploy_post_bamboohr when quotes already contain Bamboo lines.
 *
 *   cci task run anon_apex --org <alias> -o path scripts/apex/stampBambooVolumeTiers.apex
 *   # or: sf apex run --file scripts/apex/stampBambooVolumeTiers.apex --target-org <sf_alias>
 */
List<QuoteLineItem> lines = [
    SELECT Id, Quantity, Product2Id, Product2.StockKeepingUnit,
           RLM_Volume_Tier_Band__c, RLM_Volume_Tier_Discount__c, RLM_Volume_Tier_Next__c
    FROM QuoteLineItem
    WHERE Product2.StockKeepingUnit LIKE 'BAMBOO-%'
];
RLM_BambooVolumeTiers.stampLines(lines);
update lines;
System.debug('Stamped Bamboo volume tiers on ' + lines.size() + ' quote line(s).');
