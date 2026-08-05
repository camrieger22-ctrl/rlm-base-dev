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
| Bundle & Save 15% | **Path A:** `BundleBasedAdjustment` on Payroll + Benefits under `BAMBOO-PKG-WORKFORCE`. **Path B (a la carte):** Quote `RLM_Bamboo_PathB_BundleSave__c` (Apex when plan + Payroll + Benefits and no package) → ManualDiscount 15% on add-ons via `bamboohr_path_b_bundle_save` overlay. Smoke: `python scripts/bamboohr/path_b_bundle_save_smoke.py --via-cci` |
| Nonprofit 15% | Account `RLM_Is_Nonprofit__c` → Quote formula → pricing context → `RLM_DefaultPricingProcedure` **ManualDiscount 15%** (visible in Calculation Details) then copies net → `InputUnitPrice` so volume/BBA stack on the discounted list (Standard PB only) |
| USD only | All `CurrencyIsoCode=USD` |
| PAS dates | `EffectiveFrom` **2023-01-01** (aligned with QuantumBit — do not use 2026) |
| PAS active flag | CSV loads schedules **`IsActive=false`**; run `activate_price_adjustment_schedules` after insert |

## Nonprofit demo path (AE)

1. Open Account **BambooHR Nonprofit Demo** (`RLM_Is_Nonprofit__c=true`, BillingCountry `US`; loaded by this plan).
2. New Quote → leave **Price Book = Standard** (default).
3. Add BambooHR Core/Pro/Elite — Calculation Details shows **BambooHR Nonprofit 15% List Discount** (or percentage-based discount **15%**) between list and volume.
4. Volume tiers and Bundle & Save still stack **after** the nonprofit cut (Sales Price reflects the post-nonprofit list).

Requires `prepare_bamboohr` wiring: Account/Quote fields, `BambooHrNonprofitPricing` context plan, nonprofit overlays on **both** `RLM_DefaultPricingProcedure` and `RLM_DefaultNearCorePricingProcedure`, and `ensure_bamboohr_quote_default_pricing_procedure` (Quote plan DefaultPricing must use Default — NearCore drift skips Instant Pricing discounts).

**UI note:** List Price stays **$10**; Sales / Net reflect the 15% cut (**$8.50**). The ManualDiscount reads **ListPrice** (not `InputUnitPrice`) so Instant Pricing re-entry cannot compound to ~$7.23. If Instant Pricing shows no discount, check the Quote procedure plan is not bound to NearCore only.

## A2 API smoke

```bash
python scripts/bamboohr/api_smoke.py --target-org master-demo
```

Covers Discovery (`getCategories` / `getProducts`) → Place Sales Transaction quote (set **`QuoteAccountId`**) → headless pricing nonprofit **$8.50**. Quote formula `RLM_Is_Nonprofit_Account__c` is `QuoteAccount` **or** `Opportunity.Account` so API-created quotes still evaluate.

## Dual-channel P1 (Discover → calculate → Quote)

Thin BFF / API channel for commercial Acme (volume at qty 50 → ~$9.50 on Core):

```bash
python scripts/bamboohr/dual_channel_p1.py --target-org master-demo --via-cci
```

Postman: `postman/bamboohr-dual-channel-p1.postman_collection.json`.  
Notes: `.agents/artifacts/bamboohr-dual-channel-p1.md`.

## Dual-channel P2 (Get Pricing form)

Local thin BFF + branded HTML form (headcount + country → Quote summary):

```bash
~/.local/pipx/venvs/cumulusci/bin/python \
  scripts/bamboohr/get_pricing/server.py --org master-demo --port 8765
~/.local/pipx/venvs/cumulusci/bin/python \
  scripts/bamboohr/get_pricing_smoke.py --target-org master-demo
~/.local/pipx/venvs/cumulusci/bin/python \
  scripts/bamboohr/checkout_p3_smoke.py --target-org master-demo
```

See `scripts/bamboohr/get_pricing/README.md` (P2 form + P3 `/api/checkout`).

## Objects

| # | Object | Operation | External ID | Records |
|---|--------|-----------|-------------|---------|
| 0 | Account | Upsert | `Name` | 1 (`BambooHR Nonprofit Demo`) |
| 1 | CurrencyType | Upsert | `IsoCode` | 1 |
| 2 | ProrationPolicy | Update | `Name` | 1 |
| 3 | ProductSellingModel | Readonly | `Name;SellingModelType` | 2 |
| 4 | AttributeDefinition | Readonly | `Code` | 0 (excluded) |
| 5 | Product2 | Readonly | `StockKeepingUnit` | 8 |
| 6 | CostBook | Upsert | `Name` | 0 (excluded) |
| 7 | Pricebook2 | Upsert | `Name;IsStandard` | 1 (Standard only) |
| 8 | PriceAdjustmentTier | Insert | `PriceAdjustmentSchedule.Name;Product2.StockKeepingUnit;ProductSellingModel.Name;ProductSellingModel.SellingModelType;TierType;TierValue;LowerBound;CurrencyIsoCode;EffectiveFrom` | 70 |
| 9 | PriceAdjustmentSchedule | Update | `Name;CurrencyIsoCode` | 2 |
| 10 | AttributeBasedAdjRule | Upsert | `Name` | 0 (excluded) |
| 11 | AttributeAdjustmentCondition | Insert | `AttributeBasedAdjRule.Name;AttributeDefinition.Code;Product.StockKeepingUnit` | 0 (excluded) |
| 12 | AttributeBasedAdjustment | Insert | `AttributeBasedAdjRule.Name;PriceAdjustmentSchedule.Name;Product.StockKeepingUnit;ProductSellingModel.Name;CurrencyIsoCode` | 0 (excluded) |
| 13 | BundleBasedAdjustment | Insert | `PriceAdjustmentSchedule.Name;Product.StockKeepingUnit;ParentProduct.StockKeepingUnit;RootBundle.StockKeepingUnit;ProductSellingModel.Name;ParentProductSellingModel.Name;RootProductSellingModel.Name;CurrencyIsoCode` | 4 |
| 14 | PricebookEntry | Insert | `Product2.StockKeepingUnit;ProductSellingModel.Name;CurrencyIsoCode;Pricebook2.Name` | 16 |
| 15 | PricebookEntryDerivedPrice | Insert | `Pricebook.Name;PricebookEntry.Product2.StockKeepingUnit;PricebookEntry.ProductSellingModel.Name;Product.StockKeepingUnit;ContributingProduct.StockKeepingUnit;ProductSellingModel.Name;CurrencyIsoCode` | 0 (excluded) |
| 16 | CostBookEntry | Insert | `CostBook.Name;Product.StockKeepingUnit;CurrencyIsoCode` | 0 (excluded) |
