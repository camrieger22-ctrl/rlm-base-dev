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
| Core / Pro / Elite PEPM | Own PBEs: **USD $10 / $17 / $25** Monthly; Annual = 12×. **CAD** ×1.35, **GBP** ×0.79 (demo FX) |
| Core small-biz flat | `BAMBOO-CORE-FLAT-SM` **USD $250** / CAD **$337.50** / GBP **£197.50** Monthly (qty 1); Annual = 12×; **no volume tiers**; Get Pricing when Core + headcount ≤ 25 |
| Add-on placeholders | Payroll / Benefits / Time / Global: USD $8/$6/$4/$12; CAD/GBP scaled by same FX |
| Volume demo ladder | `Standard Price Adjustment Tier` 5–25% on PEPM plans + add-ons (not on flat SKU) — **USD + CAD + GBP** schedules |
| Bundle & Save 15% | **Path A:** `BundleBasedAdjustment` on Payroll + Benefits under `BAMBOO-PKG-WORKFORCE` (per currency). **Path B:** ManualDiscount 15% (currency-agnostic %). Smoke: `path_b_bundle_save_smoke.py --via-cci` |
| Nonprofit 15% | Account `RLM_Is_Nonprofit__c` → Quote formula → pricing context → `RLM_DefaultPricingProcedure` **ManualDiscount 15%** (visible in Calculation Details) then copies net → `InputUnitPrice` so volume/BBA stack on the discounted list (Standard PB only) |
| Multi-currency (B5) | Standard PB PBEs + PAS/PAT/BBA for **USD, CAD, GBP**. Accounts: Acme USD, Prestige CAD, BambooHR UK Demo GBP |
| PAS dates | `EffectiveFrom` **2023-01-01** (aligned with QuantumBit — do not use 2026) |
| PAS active flag | CSV loads schedules **`IsActive=false`**; run `activate_price_adjustment_schedules` after insert |

## Nonprofit demo path (AE)

1. Open Account **BambooHR Nonprofit Demo** (`RLM_Is_Nonprofit__c=true`, BillingCountry `US`; loaded by this plan).
2. New Quote → leave **Price Book = Standard** (default).
3. Add BambooHR Core/Pro/Elite — Calculation Details shows **BambooHR Nonprofit 15% List Discount** (or percentage-based discount **15%**) between list and volume.
4. Volume tiers and Bundle & Save still stack **after** the nonprofit cut (Sales Price reflects the post-nonprofit list).
5. **Further AE discount:** set line **Discount (%)** (e.g. 10). Sales/`UnitPrice` stays at the post-nonprofit price (**$8.50**); **`NetUnitPrice`** drops further (e.g. **$7.65**). Smoke: `scripts/bamboohr/nonprofit_further_discount_smoke.py`. Do not set Discount and DiscountAmount together.

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
| 0 | Account | Upsert | `Name` | 4 (Acme, Prestige, UK Demo, Nonprofit) |
| 1 | CurrencyType | Upsert | `IsoCode` | 3 (USD, CAD, GBP) |
| 2 | ProrationPolicy | Update | `Name` | 1 |
| 3 | ProductSellingModel | Readonly | `Name;SellingModelType` | 2 |
| 4 | AttributeDefinition | Readonly | `Code` | 0 (excluded) |
| 5 | Product2 | Readonly | `StockKeepingUnit` | 9 |
| 6 | CostBook | Upsert | `Name` | 0 (excluded) |
| 7 | Pricebook2 | Upsert | `Name;IsStandard` | 1 (Standard only) |
| 8 | PriceAdjustmentTier | Insert | `PriceAdjustmentSchedule.Name;Product2.StockKeepingUnit;ProductSellingModel.Name;ProductSellingModel.SellingModelType;TierType;TierValue;LowerBound;CurrencyIsoCode;EffectiveFrom` | 210 |
| 9 | PriceAdjustmentSchedule | Upsert | `Name;CurrencyIsoCode` | 6 |
| 10 | AttributeBasedAdjRule | Upsert | `Name` | 0 (excluded) |
| 11 | AttributeAdjustmentCondition | Insert | `AttributeBasedAdjRule.Name;AttributeDefinition.Code;Product.StockKeepingUnit` | 0 (excluded) |
| 12 | AttributeBasedAdjustment | Insert | `AttributeBasedAdjRule.Name;PriceAdjustmentSchedule.Name;Product.StockKeepingUnit;ProductSellingModel.Name;CurrencyIsoCode` | 0 (excluded) |
| 13 | BundleBasedAdjustment | Insert | `PriceAdjustmentSchedule.Name;Product.StockKeepingUnit;ParentProduct.StockKeepingUnit;RootBundle.StockKeepingUnit;ProductSellingModel.Name;ParentProductSellingModel.Name;RootProductSellingModel.Name;CurrencyIsoCode` | 12 |
| 14 | PricebookEntry | Insert | `Product2.StockKeepingUnit;ProductSellingModel.Name;CurrencyIsoCode;Pricebook2.Name` | 54 |
| 15 | PricebookEntryDerivedPrice | Insert | `Pricebook.Name;PricebookEntry.Product2.StockKeepingUnit;PricebookEntry.ProductSellingModel.Name;Product.StockKeepingUnit;ContributingProduct.StockKeepingUnit;ProductSellingModel.Name;CurrencyIsoCode` | 0 (excluded) |
| 16 | CostBookEntry | Insert | `CostBook.Name;Product.StockKeepingUnit;CurrencyIsoCode` | 0 (excluded) |
