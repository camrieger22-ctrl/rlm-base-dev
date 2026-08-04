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
| 26 | ProductCategoryDisqual | Upsert | `Name` | 0 (excluded) |
| 27 | ProductCategoryQualification | Upsert | `Name` | 0 (excluded) |
| 28 | ProdtAttrScope | Upsert | `Name` | 0 (excluded) |

## Workforce package

- `PCG-BH-BASE` min/max **1** — exactly one of Core / Pro / Elite (Pro default)
- `PCG-BH-WORKFORCE` min/max **2** — Payroll + Benefits required
- `ProductRelatedComponent.ChildSellingModel` / `ParentSellingModel` must be **blank** (platform rejects selling models on configurable bundle components)

## Gaps

- US-only Payroll/Benefits: category tagging only; Discovery DT follow-on.
