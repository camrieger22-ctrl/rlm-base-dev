# kld-pcm Data Plan

SFDMU data plan for **KLDiscovery** Product Catalog Management (PCM). Creates the
**Nebula ECA → RelOne** demo catalog from the Standard Average Estimate / SOW
templates (hosting, forensics, eDiscovery AI, RelOne extenders, professional services).

**Pricing is out of scope here** — this plan defines product structure, UoMs, selling models, bundles, and qualifications only. Rate cards and tiered GB pricing live in `kld-pricing`.

## Source documents

- Standard Average Estimate (Nebula ECA to RelOne) — APRIL 2026
- US Subscription Work Order (Nebula) — Pricing A-La-Carte
- SOW template: Neb ECA→RelOne

## Regeneration

```bash
python3 scripts/build_kld_pcm.py
```

## Data Plan Overview

Single SFDMU pass; 28 object entries; 6 excluded (empty placeholders).

### Objects

| #  | Object                        | Operation | External ID                                                                                           | Records |
|----|-------------------------------|-----------|-------------------------------------------------------------------------------------------------------|---------|
| 1  | AttributePicklist             | Upsert    | `Name`                                                                                                | 0 (excluded) |
| 2  | AttributePicklistValue        | Upsert    | `Code`                                                                                                | 0 (excluded) |
| 3  | UnitOfMeasureClass            | Upsert    | `Code`                                                                                                | 4       |
| 4  | UnitOfMeasure                 | Upsert    | `UnitCode`                                                                                            | 11      |
| 5  | AttributeDefinition           | Upsert    | `Code`                                                                                                | 14      |
| 6  | AttributeCategory             | Upsert    | `Code`                                                                                                | 2       |
| 7  | AttributeCategoryAttribute    | Upsert    | `AttributeCategory.Code;AttributeDefinition.Code`                                                     | 14      |
| 8  | ProductClassification         | Upsert    | `Code`                                                                                                | 8       |
| 9  | ProductClassificationAttr     | Upsert    | `Name`                                                                                                | 14      |
| 10 | Product2                      | Upsert    | `StockKeepingUnit`                                                                                    | 39      |
| 11 | ProductAttributeDefinition    | Upsert    | `AttributeDefinition.Code;Product2.StockKeepingUnit`                                                  | 6       |
| 12 | ProductSellingModel           | Upsert    | `Name;SellingModelType`                                                                               | 4       |
| 13 | ProrationPolicy               | Upsert    | `Name`                                                                                                | 1       |
| 14 | ProductSellingModelOption     | Upsert    | `Product2.StockKeepingUnit;ProductSellingModel.Name;ProductSellingModel.SellingModelType`              | 42      |
| 15 | ProductRampSegment            | Upsert    | `Product.StockKeepingUnit;ProductSellingModel.SellingModelType;SegmentType`                            | 0 (excluded) |
| 16 | ProductRelationshipType       | Upsert    | `Name`                                                                                                | 1       |
| 17 | ProductComponentGroup         | Upsert    | `Code`                                                                                                | 8       |
| 18 | ProductRelatedComponent       | Upsert    | `ChildProductClassification.Code;ChildProduct.StockKeepingUnit;ParentProduct.StockKeepingUnit;ProductComponentGroup.Code;ProductRelationshipType.Name` | 37 |
| 19 | ProductComponentGrpOverride   | Upsert    | `Name`                                                                                                | 0 (excluded) |
| 20 | ProductRelComponentOverride   | Upsert    | `Name`                                                                                                | 0 (excluded) |
| 21 | ProductCatalog                | Upsert    | `Code`                                                                                                | 5       |
| 22 | ProductCategory               | Upsert    | `Code`                                                                                                | 14      |
| 23 | ProductCategoryProduct        | Upsert    | `ProductCategory.Code;Product.StockKeepingUnit`                                                       | 39      |
| 24 | ProductQualification          | Upsert    | `Name`                                                                                                | 0       |
| 25 | ProductDisqualification       | (default) | `Name`                                                                                                | 0       |
| 26 | ProductCategoryDisqual        | (default) | `Name`                                                                                                | 0       |
| 27 | ProductCategoryQualification  | (default) | `Name`                                                                                                | 0       |
| 28 | ProdtAttrScope                | (default) | `Name`                                                                                                | 0 (excluded) |

## Product inventory (39)

### Pathway bundle — configuration shell (not priced)

| SKU | Name |
|-----|------|
| `KLD-PATH-NEB-R1` | Nebula ECA to RelOne |

Demo scope is **this pathway only**. Eight optional sections (`MinBundleComponents = 0`) so configuration starts blank — reps select only the lines they need (typical demo: Staging, ECA Hosting, Online Data Hosting, Extenders, Professional Services).

### Setup / staging / hosting

| SKU | Name | UoM |
|-----|------|-----|
| `KLD-SETUP-MATTER-GB` | Transactional Matter Set Up Fee | GB |
| `KLD-STAGING` | Staging | GB |
| `KLD-NEB-ECA-HOST` | Nebula ECA Hosting | GB-MO |
| `KLD-R1-REVIEW` | RelOne Review | GB-MO |
| `KLD-R1-COLD` | Cold Storage - No Access | GB-MO |

### Forensics & collection

| SKU | Name | UoM |
|-----|------|-----|
| `KLD-FOR-COLL` | Forensic Data Collection | h |
| `KLD-FOR-RCOLL` | Remote Forensic Data Collection | h |
| `KLD-FOR-DOWNTIME` | Forensic Data Collection - Downtime | h |
| `KLD-RMDC-HR` | RMDC - Remote Mobile Device Collection (Hourly) | h |
| `KLD-RMDC-FLAT` | RMDC - Remote Mobile Device Collection (Flat) | EACH |
| `KLD-RCMGR-PC` | RCMgr Self Collection Computer | EACH |
| `KLD-RCMGR-SRV` | RCMgr Self Collection Server | EACH |
| `KLD-RCMGR-DECRYPT` | RCMgr Drive Decryption | EACH |
| `KLD-FOR-ANALYSIS` | Forensic Analysis | h |
| `KLD-TRAVEL-TIME` | Travel Time | h |
| `KLD-TRAVEL-EXP` | Travel Expense | USD |

### eDiscovery AI

| SKU | Name | UoM |
|-----|------|-----|
| `KLD-AI-ECI-CORE` | eDiscovery AI - Early Case Insight (Core) | DOC-RUN |
| `KLD-AI-ECI-ELEMENTS` | eDiscovery AI - Early Case Insight (Case Elements) | DOC-RUN |
| `KLD-AI-CASEBOT` | eDiscovery AI - Early Case Bot (CaseBot) | DOC-QTR | Evergreen - Quarterly |
| `KLD-AI-RELEVANCE` | eDiscovery AI - Relevance | DOC-RUN |
| `KLD-AI-PRIVILEGE` | eDiscovery AI - Privilege | DOC-RUN |
| `KLD-AI-PII-DETECT` | eDiscovery AI - PII Detect | DOC |
| `KLD-AI-PII-EXTRACT` | eDiscovery AI - PII Extract | DOC |
| `KLD-AI-PII-REDACT` | eDiscovery AI - PII Redact | PAGE |

**Note:** An “ELEMENTS requires CORE” catalog dependency is **not** modelled with `ProductQualification` — that object is for eligibility in a **bundle parent/child** context (CORE and ELEMENTS are siblings under pathways). Enforce ELEMENTS→CORE later via configurator constraints if needed.

### Extenders (RelativityOne)

| SKU | Name | UoM |
|-----|------|-----|
| `KLD-EXT-AIR-REVIEW` | RelativityOne - aiR for Review | DOC |
| `KLD-EXT-AIR-PRIV` | RelativityOne - aiR for Privilege | DOC |
| `KLD-EXT-XLAT` | RelativityOne Translate | DOC |
| `KLD-EXT-CONTRACTS` | Relativity Contracts | DOC |
| `KLD-EXT-PI-DETECT` | Relativity PI Detect | DOC-RUN |
| `KLD-EXT-BREACH` | Relativity Data Breach Response | GB |
| `KLD-EXT-CASE-STRAT` | Relativity aiR Case Strategy | EACH |

### Professional services & delivery

| SKU | Name | UoM |
|-----|------|-----|
| `KLD-PS-PM` | Project Management | h |
| `KLD-PS-TECH` | Technical Support | h |
| `KLD-PS-AA-CONSULT` | Advanced Analytics Consulting | h |
| `KLD-PS-CONSULT` | Consulting Services | h |
| `KLD-PS-EXPERT` | Expert Testimony | h |
| `KLD-MED-HDD` | Hard Drive | EACH |
| `KLD-MED-FREIGHT` | Freight | USD |

## Catalogs

| Code | Name |
|------|------|
| `CAT-KLD-EDISC` | KLDiscovery eDiscovery |
| `CAT-KLD-AI` | KLDiscovery AI & Analytics |
| `CAT-KLD-FORENS` | KLDiscovery Forensics |
| `CAT-KLD-PS` | KLDiscovery Professional Services |
| `CAT-KLD-MEDIA` | KLDiscovery Media & Delivery |

## Pathway bundle structure

All component groups are optional (`min=0`).

```
KLD-PATH-NEB-R1 (Nebula ECA to RelOne)
  1. Forensic Collection & Analysis (opt) → KLD-FOR-*, RMDC, RCMgr, Travel
  2. Staging (opt)                        → KLD-STAGING
  3. ECA Hosting (opt)                    → KLD-NEB-ECA-HOST
  4. Online Data Hosting (opt)            → KLD-R1-REVIEW + KLD-R1-COLD
  5. Extenders (opt)                      → KLD-EXT-* (RelativityOne extenders)
  6. Advanced Analytics (opt)             → KLD-AI-* (eDiscovery AI)
  7. Professional Services (opt)          → PM, Tech, AA Consulting, Consulting, Expert Testimony
  8. Media & Data Delivery (opt)          → KLD-MED-HDD, KLD-MED-FREIGHT
```

Pathway parent uses `DoesBundlePriceIncludeChild = false` — children carry pricing in `kld-pricing`.

## Matter estimate attributes (pathway classification)

On `PC-KLD-PATHWAY`, matching the Standard Average Estimate **Assumptions** block.
Defaults = **Source Data = 1,000 GB** worked example (PM/Tech from Hosting **500–1000 GB** matrix).

Editable assumption rates are separate attributes; derived GB volumes are read-only
(CML `KLDPathway` recomputes them when rates change).

| Attribute | Default | Editable | Notes |
|-----------|---------|----------|-------|
| Source Data | 1000 GB | Yes | Drives Staging `Billable_GB` |
| Decompression Rate (%) | 50 | Yes | Assumption; feeds Decompression GB |
| Storage Expansion Rate (%) | 25 | Yes | Assumption; feeds Storage Expansion GB |
| ECA Data (%) | 70 | Yes | Share of Storage Expansion → ECA |
| Active Review (%) | 30 | Yes | Share of Storage Expansion → Review |
| Decompression GB | 1500 GB | No | Source × (1 + decomp%/100) |
| Storage Expansion GB | 1875 GB | No | Decompression × (1 + expand%/100) |
| ECA Data GB | 1313 GB | No | → ECA Hosting `Billable_GB` (tier input) |
| Active Review GB | 562 GB | No | → Review `Billable_GB` |
| PM Hours Per Month | 11 | No | Hosting 500–1000 GB matrix |
| Tech Hours Per Month | 7 | No | Hosting 500–1000 GB matrix |
| Term Months | 12 | Yes | Multiplier for Billable_Hours / estimate term |

### Billable volume attributes (component classifications)

| Classification | Attribute | Used by |
|----------------|-----------|---------|
| `PC-KLD-HOST` | `Billable_GB` (read-only; `IsPriceImpacting=false` until pricing overlay) | Staging, ECA, Review |
| `PC-KLD-PS` | `Billable_Hours` (read-only; `IsPriceImpacting=false` until pricing overlay) | PM, Tech |

Explicit `ProductAttributeDefinition` rows (7) materialize these onto the products.
Classification attrs alone do **not** create PADs; missing PADs + price-impacting caused
configurator NPE `productDetails is null` when selecting Staging.

### Worked example Est. Price (12-month term)

| Line | Math | Est. Price |
|------|------|------------|
| Staging | $10 × 1,000 GB | **$10,000.00** |
| Nebula ECA Hosting | $2.30 (tier on **ECA 1,313**) × 1,313 × 12 | **$36,238.80** |
| RelOne Review | $12.50 (tier on **Review 562** → 501–1,000) × 562 × 12 | **$84,300.00** |
| Project Management | $195 × 11 × 12 | **$25,740.00** |
| Technical Support | $175 × 7 × 12 | **$14,700.00** |

Pathway volume components use **Quantity = 1** (locked). CML `KLDPathway` syncs
`Billable_GB` / `Billable_Hours` when the component is selected. List×qty pricing still
sees qty=1 until a pricing-procedure overlay maps `Billable_*` into quantity or
`ListPrice × Billable_*`.
## Dependencies

- **Standalone** — does not require `qb-pcm`. Uses distinct `KLD-` / `CAT-KLD-` / `PC-KLD-` prefixes. Can load alongside QB when `kld=true` and `qb=true`.
- **Downstream:** `kld-pricing` (this plan's prices), future `kld-rating` / `kld-billing`.

## After load (connected orgs)

SFDMU alone does not refresh pricing decision tables or the PCM search index. After `insert_kld_pcm_data` (and pricing), follow
[Post–data-load refresh](../../../../../docs/guides/post-data-load-refresh.md)
(`refresh_dt_default_pricing` + `rebuild_search_index`) so products show in search and quote pricing picks up new entries.

## Validation

```bash
python3 scripts/validate_sfdmu_v5_datasets.py
python3 scripts/ai/check_plan_readme_consistency.py datasets/sfdmu/kld/en-US/kld-pcm
```

## Phase 2 (not in this plan)

ReadySuite, Managed Review, Scanning, human Translation, Data Recovery — estimators exist in SharePoint but are deferred.
