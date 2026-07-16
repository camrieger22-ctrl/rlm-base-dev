# kld-pcm Data Plan

SFDMU data plan for **KLDiscovery** Product Catalog Management (PCM). Creates the KLD eDiscovery product structure from internal estimate/SOW templates (Nebula ECA → Nebula/RelOne pathways, hosting, forensics, eDiscovery AI, analytics, and professional services).

**Pricing is out of scope here** — this plan defines product structure, UoMs, selling models, bundles, and qualifications only. Rate cards and tiered GB pricing live in `kld-pricing`.

## Source documents

- Standard Average Estimate (Nebula ECA to Nebula) Template — APRIL 2024/2026
- US Subscription Work Order (Nebula) — Pricing A-La-Carte
- SOW templates: Neb ECA→Nebula, Neb ECA→RelOne, RelOne ECA→RelOne

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
| 5  | AttributeDefinition           | Upsert    | `Code`                                                                                                | 7       |
| 6  | AttributeCategory             | Upsert    | `Code`                                                                                                | 1       |
| 7  | AttributeCategoryAttribute    | Upsert    | `AttributeCategory.Code;AttributeDefinition.Code`                                                     | 7       |
| 8  | ProductClassification         | Upsert    | `Code`                                                                                                | 8       |
| 9  | ProductClassificationAttr     | Upsert    | `Name`                                                                                                | 7       |
| 10 | Product2                      | Upsert    | `StockKeepingUnit`                                                                                    | 37      |
| 11 | ProductAttributeDefinition    | Upsert    | `AttributeDefinition.Code;Product2.StockKeepingUnit`                                                  | 0 (excluded) |
| 12 | ProductSellingModel           | Upsert    | `Name;SellingModelType`                                                                               | 4       |
| 13 | ProrationPolicy               | Upsert    | `Name`                                                                                                | 1       |
| 14 | ProductSellingModelOption     | Upsert    | `Product2.StockKeepingUnit;ProductSellingModel.Name;ProductSellingModel.SellingModelType`              | 41      |
| 15 | ProductRampSegment            | Upsert    | `Product.StockKeepingUnit;ProductSellingModel.SellingModelType;SegmentType`                            | 0 (excluded) |
| 16 | ProductRelationshipType       | Upsert    | `Name`                                                                                                | 1       |
| 17 | ProductComponentGroup         | Upsert    | `Code`                                                                                                | 21      |
| 18 | ProductRelatedComponent       | Upsert    | `ChildProductClassification.Code;ChildProduct.StockKeepingUnit;ParentProduct.StockKeepingUnit;ProductComponentGroup.Code;ProductRelationshipType.Name` | 93 |
| 19 | ProductComponentGrpOverride   | Upsert    | `Name`                                                                                                | 0 (excluded) |
| 20 | ProductRelComponentOverride   | Upsert    | `Name`                                                                                                | 0 (excluded) |
| 21 | ProductCatalog                | Upsert    | `Code`                                                                                                | 5       |
| 22 | ProductCategory               | Upsert    | `Code`                                                                                                | 14      |
| 23 | ProductCategoryProduct        | Upsert    | `ProductCategory.Code;Product.StockKeepingUnit`                                                       | 37      |
| 24 | ProductQualification          | Upsert    | `Name`                                                                                                | 0       |
| 25 | ProductDisqualification       | (default) | `Name`                                                                                                | 0       |
| 26 | ProductCategoryDisqual        | (default) | `Name`                                                                                                | 0       |
| 27 | ProductCategoryQualification  | (default) | `Name`                                                                                                | 0       |
| 28 | ProdtAttrScope                | (default) | `Name`                                                                                                | 0 (excluded) |

## Product inventory (37)

### Pathway bundles — configuration shells (not priced)

| SKU | Name |
|-----|------|
| `KLD-PATH-NEB-NEB` | Nebula ECA to Nebula Review |
| `KLD-PATH-NEB-R1` | Nebula ECA to RelOne |
| `KLD-PATH-R1-R1` | RelOne ECA to RelOne |

Each pathway bundle has **seven optional sections** (`MinBundleComponents = 0`) so configuration starts blank — reps select only the lines they need (typical working demo: Staging, ECA Hosting, Online Data Hosting, Professional Services, Media).

### Setup / staging / hosting

| SKU | Name | UoM |
|-----|------|-----|
| `KLD-SETUP-MATTER-GB` | Transactional Matter Set Up Fee | GB |
| `KLD-STAGING` | Staging | GB |
| `KLD-NEB-ECA-HOST` | Nebula ECA Hosting | GB-MO |
| `KLD-NEB-REVIEW` | Nebula Review | GB-MO |
| `KLD-R1-ECA-HOST` | RelOne ECA Hosting | GB-MO |
| `KLD-R1-REVIEW` | RelOne Review | GB-MO |

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

### Analytics a-la-carte

| SKU | Name | UoM |
|-----|------|-----|
| `KLD-AN-ANALYTICS` | KLDiscovery Analytics | GB |
| `KLD-AN-SUM` | Nebula AI Summarization | MCHARS |
| `KLD-AN-SUM-MED` | Nebula AI Summarization (Medical) | PAGE |
| `KLD-AN-XLAT` | AI Translation | MCHARS |
| `KLD-AN-TRANSCRIBE` | KLD Transcription Service | ATRANS-HR |

### Professional services & delivery

| SKU | Name | UoM |
|-----|------|-----|
| `KLD-PS-PM` | Project Management | h |
| `KLD-PS-TECH` | Technical Support | h |
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

All component groups are optional (`min=0`). Same section order on every pathway; ECA / Online Data Hosting SKUs differ by pathway.

```
KLD-PATH-NEB-NEB / NEB-R1 / R1-R1
  1. Forensic Collection & Analysis (opt) → KLD-FOR-*, RMDC, RCMgr, Travel
  2. Staging (opt)                        → KLD-STAGING
  3. ECA Hosting (opt)                    → pathway ECA SKU
  4. Online Data Hosting (opt)            → pathway Review SKU
  5. Advanced Analytics / eDiscovery AI   → KLD-AI-* + KLD-AN-*
  6. Professional Services (opt)          → KLD-PS-PM, KLD-PS-TECH
  7. Media & Data Delivery (opt)          → KLD-MED-HDD, KLD-MED-FREIGHT

Hosting SKUs by pathway:
  NEB-NEB → KLD-NEB-ECA-HOST + KLD-NEB-REVIEW
  NEB-R1  → KLD-NEB-ECA-HOST + KLD-R1-REVIEW
  R1-R1   → KLD-R1-ECA-HOST  + KLD-R1-REVIEW
```

Pathway parents use `DoesBundlePriceIncludeChild = false` — children carry pricing in `kld-pricing`.

## Matter estimate attributes (pathway classification)

On `PC-KLD-PATHWAY`, matching the Standard Average Estimate **Assumptions** block.
Defaults below are the **Source Data = 1,000 GB** worked example (PM/Tech from the 500–1000 GB matrix).

| Attribute | Default | Notes |
|-----------|---------|-------|
| Source Data | 1000 GB | Driver; Staging est. quantity = this value |
| Decompression Rate (50%) | 1500 GB | Source × 1.50 |
| Storage Expansion Rate (25%) | 1875 GB | Decompression × 1.25 |
| ECA Data (70%) | 1313 GB | Storage Expansion × 0.70 → ECA Hosting qty / volume tier |
| Active Review (30%) | 562 GB | Storage Expansion × 0.30 → Online Data Hosting qty |
| PM Hours Per Month | 11 | Professional Services estimate |
| Tech Hours Per Month | 7 | Professional Services estimate |

**Worked example (not yet auto-wired to line quantities):** Source 1,000 → Staging qty 1,000 @ $10/GB; ECA Data 1,313 lands in Nebula ECA Hosting tier (1,001–1,500) @ $2.30/GB-month; Active Review 562 lands in Nebula Review tier (501–1,000) @ $13.50/GB-month.

Quantity / attribute-to-component wiring for the staged demo is deferred until the configurator flow is specified.

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
