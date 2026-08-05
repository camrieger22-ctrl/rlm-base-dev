# bh-pcm Data Plan

SFDMU data plan for BambooHR Product Catalog Management (PCM). **Three plan SKUs** (Core / Pro / Elite) + four add-ons + Workforce package. Loads alongside QuantumBit (no `prepare_product_data` gate — use standalone insert tasks).

## CCI Integration

| Task | Description |
|------|-------------|
| `insert_bamboohr_pcm_data` | Runs this SFDMU plan |
| `migrate_bamboohr_to_three_plan_skus` | Deactivates legacy `BAMBOO-SUITE` + Plan ABA after cutover |

```yaml
insert_bamboohr_pcm_data:
  class_path: tasks.rlm_sfdmu.LoadSFDMUData
  options:
    pathtoexportjson: "datasets/sfdmu/bamboohr/en-US/bh-pcm"
```

## Products (# 8 records)

| StockKeepingUnit | Name | Role |
|------------------|------|------|
| `BAMBOO-CORE` | BambooHR Core | Plan — $10 PEPM |
| `BAMBOO-PRO` | BambooHR Pro | Plan — $17 PEPM |
| `BAMBOO-ELITE` | BambooHR Elite | Plan — $25 PEPM |
| `BAMBOO-ADD-PAYROLL` | BambooHR Payroll | Add-on |
| `BAMBOO-ADD-BENEFITS` | BambooHR Benefits Administration | Add-on |
| `BAMBOO-ADD-TIME` | BambooHR Time & Attendance | Add-on |
| `BAMBOO-ADD-GLOBAL` | BambooHR Global Employment | Add-on |
| `BAMBOO-PKG-WORKFORCE` | BambooHR Workforce Package | Bundle header |

Legacy `BAMBOO-SUITE` (one SKU + Plan attribute) is obsolete after migrate.

## Objects

| # | Object | Operation | External ID | Records |
|---|--------|-----------|-------------|---------|
| 1 | AttributePicklist | Upsert | `Name` | 0 (excluded) |
| 2 | AttributePicklistValue | Upsert | `Code` | 0 (excluded) |
| 3 | UnitOfMeasureClass | Upsert | `Code` | 0 (excluded) |
| 4 | UnitOfMeasure | Upsert | `UnitCode` | 0 (excluded) |
| 5 | AttributeDefinition | Upsert | `Code` | 0 (excluded) |
| 6 | AttributeCategory | Upsert | `Code` | 0 (excluded) |
| 7 | AttributeCategoryAttribute | Upsert | `AttributeCategory.Code;AttributeDefinition.Code` | 0 (excluded) |
| 8 | ProductClassification | Upsert | `Code` | 0 (excluded) |
| 9 | ProductClassificationAttr | Upsert | `Name` | 0 (excluded) |
| 10 | Product2 | Upsert | `StockKeepingUnit` | 8 |
| 11 | ProductAttributeDefinition | Upsert | `AttributeDefinition.Code;Product2.StockKeepingUnit` | 0 (excluded) |
| 12 | ProductSellingModel | Upsert | `Name;SellingModelType` | 2 |
| 13 | ProrationPolicy | Upsert | `Name` | 1 |
| 14 | ProductSellingModelOption | Upsert | `Product2.StockKeepingUnit;ProductSellingModel.Name;ProductSellingModel.SellingModelType` | 16 |
| 15 | ProductRampSegment | Upsert | `Product.StockKeepingUnit;ProductSellingModel.SellingModelType;SegmentType` | 0 (excluded) |
| 16 | ProductRelationshipType | Upsert | `Name` | 1 |
| 17 | ProductComponentGroup | Upsert | `Code` | 2 |
| 18 | ProductRelatedComponent | Upsert | `ChildProductClassification.Code;ChildProduct.StockKeepingUnit;ParentProduct.StockKeepingUnit;ProductComponentGroup.Code;ProductRelationshipType.Name` | 5 |
| 19 | ProductComponentGrpOverride | Upsert | `Name` | 0 (excluded) |
| 20 | ProductRelComponentOverride | Upsert | `Name` | 0 (excluded) |
| 21 | ProductCatalog | Upsert | `Code` | 1 |
| 22 | ProductCategory | Upsert | `Code` | 4 |
| 23 | ProductCategoryProduct | Upsert | `ProductCategory.Code;Product.StockKeepingUnit` | 8 |
| 24 | ProductQualification | Upsert | `Name` | 0 (excluded) |
| 25 | ProductDisqualification | Upsert | `Name` | 0 (excluded) |
| 26 | ProductCategoryDisqual | Upsert | `RLM_Disqualification_Key__c` | 1 (`PC-BH-US-ADDONS|CA`) |
| 27 | ProductCategoryQualification | Upsert | `RLM_Qualification_Key__c` | 0 (excluded) |
| 28 | ProdtAttrScope | Upsert | `Name` | 0 (excluded) |

## Workforce package

- `PCG-BH-BASE` min/max **1** — exactly one of Core / Pro / Elite (Pro default)
- `PCG-BH-WORKFORCE` min/max **2** — Payroll + Benefits required
- `ProductRelatedComponent.ChildSellingModel` / `ParentSellingModel` must be **blank** (platform rejects selling models on configurable bundle components)
- **Qty = headcount:** every package child uses `QuantityScaleMethod=Proportional`,
  `Quantity=1`, and `IsQuantityEditable=false`. Package header quantity is the
  employee headcount; runtime child qty = parent qty × 1 (plan + Payroll +
  Benefits stay locked together). Smoke: `python scripts/bamboohr/qty_smoke.py`
- **Search / browse:** after PCM (or product) loads, run
  `cci task run rebuild_search_index --org <alias>` so Product Discovery can
  find Bamboo via indexed `searchTerm`. Smoke:
  `python scripts/bamboohr/browse_smoke.py --target-org <alias> --via-cci`

## US-only Payroll & Benefits

**Use disqualification, not qualification.** Unmatched qualification leaves
`IsCategoryQualified` null, and **null is treated as qualified** — so a
`ProductCategoryQualification` row for `US` does **not** hide add-ons for `CA`.

- Products tagged under category `PC-BH-US-ADDONS` (`IsNavigational=false`
  child of `PC-BH-ADDONS`, so Browse shows one Add-ons entry, not a duplicate).
- `ProductCategoryDisqual` row `PC-BH-US-ADDONS|CA` with `RLM_BillingCountry__c=CA`
  (org’s only non-US demo country today; add rows for other geos as needed).
- Requires Foundations wiring (deployed via `prepare_bamboohr`):
  - custom fields on `ProductCategoryDisqual`
  - `RLM_ProductCategoryDisqualification` DT (UsageType Product Category Qualification)
  - `RLM_ProductDiscoveryContext` Account.`BillingCountry__c` → Account.BillingCountry
  - procedure step `EvaluateCategoryDisqualification` + param `RLM_BillingCountry`
- After metadata: run `insert_bamboohr_pcm_data`, then refresh the disqual DT.
- AE check: Prestige Worldwide (CA) hides Payroll/Benefits; Acme (US) shows them.
