# kld-pricing Data Plan

SFDMU data plan for **KLDiscovery** pricing. Loads USD list prices into the platform **Standard Price Book**, including volume tiers for GB/month hosting products.

**Prerequisite:** `insert_kld_pcm_data` — Product2 and ProductSellingModelOption must exist in the org.

## CCI Integration

### Flow: `prepare_pricing_data`

| Step | Task | When |
|------|------|------|
| 5 | `delete_kld_pricing_data` | `kld=true` |
| 6 | `insert_kld_pricing_data` | `kld=true` |

Runs after QuantumBit / Q3 pricing steps when those flags are enabled. **Can coexist with `qb=true`** (distinct `KLD-*` SKUs).

### Flow: `prepare_price_adjustment_schedules` (scratch orgs)

Activates `Standard Price Adjustment Tier` via `activatePriceAdjustmentSchedules.apex` — required for volume tier pricing.

### Task definitions

```yaml
delete_kld_pricing_data:
  class_path: tasks.rlm_sfdmu.DeleteSFDMUData
  options:
    pathtoexportjson: "datasets/sfdmu/kld/en-US/kld-pricing"

insert_kld_pricing_data:
  class_path: tasks.rlm_sfdmu.LoadSFDMUData
  options:
    pathtoexportjson: "datasets/sfdmu/kld/en-US/kld-pricing"
```

## Regeneration

```bash
python3 scripts/build_kld_pricing.py
```

## Data plan overview

Delete + insert pattern (same as qb-pricing). Insert objects pre-cleared by `delete_kld_pricing_data`.

### Objects

| # | Object | Operation | Records |
|---|--------|-----------|---------|
| 1 | CurrencyType | Upsert | 1 (USD) |
| 2 | ProrationPolicy | Update | 1 |
| 3 | ProductSellingModel | Readonly | 4 |
| 4 | AttributeDefinition | Readonly | 0 (excluded) |
| 5 | Product2 | Readonly | 39 |
| 6 | CostBook | Upsert | 1 |
| 7 | Pricebook2 | Upsert | 1 (Standard Price Book) |
| 8 | PriceAdjustmentTier | Insert | 38 |
| 9 | PriceAdjustmentSchedule | Update | 3 |
| 10 | AttributeBasedAdjRule | Upsert | 0 (excluded) |
| 11 | AttributeAdjustmentCondition | Insert | 0 (excluded) |
| 12 | AttributeBasedAdjustment | Insert | 0 (excluded) |
| 13 | BundleBasedAdjustment | Insert | 0 (excluded) |
| 14 | PricebookEntry | Insert | 42 |
| 15 | PricebookEntryDerivedPrice | Insert | 0 (excluded) |
| 16 | CostBookEntry | Insert | 36 |

## Rate card summary (USD)

### Pathway bundle — $0

`KLD-PATH-NEB-R1` (Nebula ECA to RelOne) — configuration shell; children carry price.

### Flat list prices

| Category | Key rates |
|----------|-----------|
| Staging / setup | $10/GB |
| Forensics | $350/hr onsite, $295/hr remote, Downtime/Travel Time list $175 (≈50% of onsite), $1,250 RMDC flat, $550/$850 RCMgr kits |
| Media | Hard Drive $199/each; Freight $0 (passthrough) |
| eDiscovery AI | ECI $0.04/doc-run, Relevance/Privilege $0.30, PII Detect $0.20, Redact $0.35/page |
| CaseBot | **$0.08/doc/quarter** (Evergreen - Quarterly) |
| Extenders | aiR Review/Privilege $0.15/doc, Translate $1/doc, Contracts $8.50/doc, PI Detect $0.95/doc-run, Breach $165/GB, Case Strategy $2,000/workspace |
| Cold Storage | $1.50/GB-mo (Evergreen + Term Monthly) |
| PS | PM $195/hr, Tech $175/hr, AA Consulting $350/hr, Consulting $395/hr, Expert Testimony $525/hr |
| Pass-through | Travel expense, Freight $0 |

### Volume tiers — hosting (GB/month)

**Nebula ECA Hosting**: $2.50 (0–500 GB) down to $1.50 (5001+ GB) — 11 bands.

**RelOne Review** (Nebula ECA→RelOne PDF): $14.00 (0–500), $12.50 (501–1,000), $12.00 (1,001–2,000), $11.50 (2,001–4,000), $11.00 (4,001–6,000), $10.50 (6,001–8,000), $10.00 (8,001–10,000), $9.00 (10,000.01+) — 8 bands.

Implemented via `PriceAdjustmentTier` on **Standard Price Adjustment Tier** with `TierType = OverrideAmount` / `AdjustmentType = Override` (absolute $/GB per band). Base `PricebookEntry` uses tier-1 rate.

## Dependencies

- **kld-pcm** — Product2 + PSMO (Readonly lookup in this plan)
- **prepare_price_adjustment_schedules** — activates volume schedule on scratch orgs

## Validation

```bash
python3 scripts/validate_sfdmu_v5_datasets.py
python3 scripts/ai/check_plan_readme_consistency.py datasets/sfdmu/kld/en-US/kld-pricing
```

## Load order (manual)

```bash
cci task run insert_kld_pcm_data --org <org>
cci task run delete_kld_pricing_data --org <org>
cci task run insert_kld_pricing_data --org <org>
cci flow run prepare_price_adjustment_schedules --org <org>   # scratch only
```

Or enable `kld: true` in org config and run `prepare_product_data` then `prepare_pricing_data`.

**After loading on a connected org** (not a full `prepare_rlm_org`), refresh pricing decision tables and rebuild the catalog search index so products appear in search and prices resolve — see [Post–data-load refresh](../../../../../docs/guides/post-data-load-refresh.md).