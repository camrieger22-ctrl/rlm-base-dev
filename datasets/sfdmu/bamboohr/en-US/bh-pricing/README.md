# bh-pricing Data Plan

SFDMU data plan for BambooHR pricing — **three plan SKUs** + add-ons + Workforce package. No Plan attribute ABA.

## CCI Integration

| Task | Description |
|------|-------------|
| `delete_bamboohr_pricing_data` | Bamboo-scoped pricing cleanup (Apex — does not wipe QuantumBit) |
| `insert_bamboohr_pricing_data` | Runs this SFDMU plan |
| `activate_price_adjustment_schedules` | Activate PAS after load |
| `rebuild_search_index` | Refresh Browse catalog prices |

```yaml
insert_bamboohr_pricing_data:
  class_path: tasks.rlm_sfdmu.LoadSFDMUData
  options:
    pathtoexportjson: "datasets/sfdmu/bamboohr/en-US/bh-pricing"
```

## Commercial rules

| Rule | Implementation |
|------|----------------|
| Core / Pro / Elite PEPM | Own PBEs: **$10 / $17 / $25** Monthly; Annual = 12× |
| Add-on placeholders | Payroll $8, Benefits $6, Time $4, Global $12 |
| Volume demo ladder | `Standard Price Adjustment Tier` 5–25% on plans + add-ons |
| Bundle & Save 15% | `BundleBasedAdjustment` on Payroll + Benefits under `BAMBOO-PKG-WORKFORCE` |
| Nonprofit 15% | Nonprofit pricebook @ 85% of Standard |
| USD only | All `CurrencyIsoCode=USD` |
| PAS dates | `EffectiveFrom` **2023-01-01** (aligned with QuantumBit — do not use 2026) |
| PAS active flag | CSV loads schedules **`IsActive=false`**; run `activate_price_adjustment_schedules` after insert |

## Objects

| # | Object | Operation | External ID | Records |
|---|--------|-----------|-------------|---------|
| 1 | CurrencyType | Upsert | `IsoCode` | 1 |
| 2 | ProrationPolicy | Update | `Name` | 1 |
| 3 | ProductSellingModel | Readonly | `Name;SellingModelType` | 2 |
| 4 | AttributeDefinition | Readonly | `Code` | 0 (excluded) |
| 5 | Product2 | Readonly | `StockKeepingUnit` | 8 |
| 6 | CostBook | Upsert | `Name` | 0 (excluded) |
| 7 | Pricebook2 | Upsert | `Name;IsStandard` | 2 |
| 8 | PriceAdjustmentTier | Insert | `PriceAdjustmentSchedule.Name;Product2.StockKeepingUnit;ProductSellingModel.Name;ProductSellingModel.SellingModelType;TierType;TierValue;LowerBound;CurrencyIsoCode;EffectiveFrom` | 70 |
| 9 | PriceAdjustmentSchedule | Update | `Name;CurrencyIsoCode` | 2 |
| 10 | AttributeBasedAdjRule | Upsert | `Name` | 0 (excluded) |
| 11 | AttributeAdjustmentCondition | Insert | `AttributeBasedAdjRule.Name;AttributeDefinition.Code;Product.StockKeepingUnit` | 0 (excluded) |
| 12 | AttributeBasedAdjustment | Insert | `AttributeBasedAdjRule.Name;PriceAdjustmentSchedule.Name;Product.StockKeepingUnit;ProductSellingModel.Name;CurrencyIsoCode` | 0 (excluded) |
| 13 | BundleBasedAdjustment | Insert | `PriceAdjustmentSchedule.Name;Product.StockKeepingUnit;ParentProduct.StockKeepingUnit;RootBundle.StockKeepingUnit;ProductSellingModel.Name;ParentProductSellingModel.Name;RootProductSellingModel.Name;CurrencyIsoCode` | 4 |
| 14 | PricebookEntry | Insert | `Product2.StockKeepingUnit;ProductSellingModel.Name;CurrencyIsoCode;Pricebook2.Name` | 32 |
| 15 | PricebookEntryDerivedPrice | Insert | `Pricebook.Name;PricebookEntry.Product2.StockKeepingUnit;PricebookEntry.ProductSellingModel.Name;Product.StockKeepingUnit;ContributingProduct.StockKeepingUnit;ProductSellingModel.Name;CurrencyIsoCode` | 0 (excluded) |
| 16 | CostBookEntry | Insert | `CostBook.Name;Product.StockKeepingUnit;CurrencyIsoCode` | 0 (excluded) |
