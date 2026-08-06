---
release_version: 262
release_name: "Summer '26"
api_version: 67.0
area: "BambooHR Release Pack"
document_version: 0.2
status: draft
last_updated: 2026-08-06
authors:
  - Cameron Rieger
data_shape: bamboohr
prerequisites:
  - Org with BambooHR feature flag / prepare_bamboohr completed (PCM + pricing + overlays)
  - Search index rebuilt after catalog load (rebuild_search_index)
  - Quote DefaultPricing bound to RLM_DefaultPricingProcedure (not NearCore-only)
  - Optional for self-serve exercises: Get Pricing BFF running (scripts/bamboohr/get_pricing/)
sources:
  - datasets/sfdmu/bamboohr/en-US/bh-pcm/
  - datasets/sfdmu/bamboohr/en-US/bh-pricing/
  - datasets/expression_set_overlays/bamboohr_*.json
  - docs/enablement/262/bamboohr-hands-on.md
---

# Revenue Cloud — BambooHR Release Pack

**Enablement Exercises** · Version 0.2, Summer '26

> **Org / data shape:** `bamboohr`. These exercises assume an org provisioned with the BambooHR catalog and pricing plans (`insert_bamboohr_*` + `prepare_bamboohr`), not the QuantumBit workshop scenario. Demo accounts and SKUs below are loaded by those plans.

---

## Status of this document

| Field | Value |
|-------|-------|
| Status | **draft** v0.2 — commercial tables SME-confirmed for this pack (2026-08-06); runtime recordings still open |
| Audience | SE / partner / AE enablement for the BambooHR release pack |
| Companion SE script | Private working talk-track may exist outside this catalog; **this file is the curated hands-on** |

---

## Release Overview

The BambooHR release pack shows how Revenue Cloud models a public HRIS catalog and dual-channel motion (AE in Salesforce + self-serve Get Pricing):

1. **Three-plan catalog + US-only add-ons** — Core / Pro / Elite PEPM, Payroll & Benefits disqualified outside US (and UK for the US add-ons category).
2. **Volume ladder + Volume Tier Coach** — headcount qty drives tiered %; coach LWC guides the AE.
3. **Bundle & Save 15%** — Path A Workforce package (BBA) and Path B a la carte ManualDiscount.
4. **Nonprofit 15% list discount** — Account flag → context → Default procedure; AE can discount further.
5. **Small-business flat Core** — separate SKU `BAMBOO-CORE-FLAT-SM` ($250 / qty 1) for ≤25 employees.
6. **Convert-later free trial** — 30-day $0 quote/order; convert via a new paid quote.
7. **Get Pricing dual channel** — public form over RC APIs (discover → price → quote → DocGen PDF → checkout).
8. **Multi-currency CAD / GBP** — demo FX list prices and native-currency quote/order paths.

> **Not covered here:** QuantumBit Infinitech workshop narrative, platform “what’s new in 262” area extracts, or Time/Global inside the Workforce package (declined for this pack).

---

## Cast & catalog reference

| Account | Role |
|---------|------|
| **Acme** | US commercial — browse, volume, Workforce, Get Pricing US |
| **Prestige Worldwide** | CA — Payroll/Benefits hidden; CAD demo account |
| **BambooHR UK Demo** | UK — GBP demo account; US add-ons category disqualified |
| **BambooHR Nonprofit Demo** | `RLM_Is_Nonprofit__c=true` — automatic 15% list discount |

### Commercial reference (SME-confirmed for this pack — 2026-08-06)

Treat these as the **authoritative demo numbers** loaded in `bh-pricing`. They are pack commercial targets, not live BambooHR customer price lists.

| SKU | Role | Monthly list (USD) | Annual list (USD) |
|-----|------|--------------------|-------------------|
| `BAMBOO-CORE` | Plan PEPM | $10 | **$120** (= 12×) |
| `BAMBOO-PRO` | Plan PEPM | $17 | **$204** |
| `BAMBOO-ELITE` | Plan PEPM | $25 | **$300** |
| `BAMBOO-CORE-FLAT-SM` | Small-biz flat Core (≤25) | **$250** qty **1** | **$3,000** |
| `BAMBOO-ADD-PAYROLL` | US-only add-on PEPM | $8 | $96 |
| `BAMBOO-ADD-BENEFITS` | US-only add-on PEPM | $6 | $72 |
| `BAMBOO-ADD-TIME` | Add-on PEPM | $4 | $48 |
| `BAMBOO-ADD-GLOBAL` | Add-on PEPM | $12 | $144 |
| `BAMBOO-PKG-WORKFORCE` | Path A package header | $0 | $0 |

| Rule | Value |
|------|-------|
| Annual term | **12 × monthly** (not a prepaid discount) |
| Volume ladder (PEPM plans + add-ons) | 1–24 → 0%; **25–75 → 5%**; 76–150 → 10%; 151–300 → 15%; 301–500 → 20%; 501+ → 25% |
| Flat Core volume | **None** (qty always 1) |
| Bundle & Save | **15%** on Payroll + Benefits (Path A BBA / Path B ManualDiscount on ListPrice) |
| Nonprofit | **15%** list starting point; AE may discount further (Discount %) |
| Flat geography | Core flat applies in **other markets as well** (with multi-currency) |
| Global Employment | **PEPM** |
| Free trial | Convert-later, **30 days**, all plans; add-ons trialed with plan |
| CAD / GBP FX (vs USD list) | **CAD ×1.35**, **GBP ×0.79** on Standard PBEs |

**Worked nets (USD) to expect in walkthroughs:**

| Scenario | Expected |
|----------|----------|
| Core qty 1, nonprofit account | List $10 → UnitPrice **$8.50** |
| Same + AE Discount 10% | UnitPrice $8.50 → NetUnitPrice **$7.65** |
| Pro qty 50 (volume 5%) | Net PEPM ≈ **$16.15** |
| Path B Pro@50 + Payroll + Benefits | Plan ≈ $16.15; Payroll ≈ **$6.46**; Benefits ≈ **$4.845** (15% Bundle & Save × 5% volume on ListPrice) |
| Core flat ≤25 (Get Pricing) | Monthly **$250** on `BAMBOO-CORE-FLAT-SM` |
| UK Pro @ 25 (GBP) | Native GBP list/net (USD $17 × 0.79 = **£13.43** list before volume) |

---

## Prerequisites (org)

1. Load BambooHR PCM + pricing and run `prepare_bamboohr` (context plans + nonprofit / Path B / free-trial overlays). CCI: `cci flow run prepare_bamboohr --org <cci-alias>`.
2. Rebuild search: `cci task run rebuild_search_index --org <cci-alias>`.
3. Confirm Quote DefaultPricing uses `RLM_DefaultPricingProcedure`.
4. Optional smokes (SF CLI alias — e.g. `master-demo` → often `rlm-base__master-demo` if created via CCI):

```bash
python scripts/bamboohr/browse_smoke.py --target-org <sf-alias>
python scripts/bamboohr/api_smoke.py --target-org <sf-alias>
python scripts/bamboohr/nonprofit_further_discount_smoke.py --target-org <sf-alias>
python scripts/bamboohr/get_pricing_smoke.py --target-org <sf-alias>
python scripts/bamboohr/checkout_multicurrency_smoke.py --target-org <sf-alias>
```

5. For Get Pricing exercises, start the BFF:

```bash
set -a; source scripts/bamboohr/get_pricing/.env; set +a
~/.local/pipx/venvs/cumulusci/bin/python -u \
  scripts/bamboohr/get_pricing/server.py --host 127.0.0.1 --port 8765 --cors-origin '*'
```

Open **http://127.0.0.1:8765/** (http, not https). Hard-refresh after BFF restarts.

---

## Feature 1: Browse the BambooHR catalog

### Business Objective

Prove Product Discovery can surface a real-world HRIS catalog (plans, add-ons, packages) the same way buyers browse Bamboo’s public site.

### Use Cases

**AE persona:**

- Start a quote on **Acme** and find Core / Pro / Elite, add-ons, and the Workforce package without memorizing SKUs.

### Design Time Configuration

Catalog and categories ship in `datasets/sfdmu/bamboohr/en-US/bh-pcm/`. No per-exercise design-time steps beyond `prepare_bamboohr` + search index rebuild.

### Runtime walkthrough

1. App Launcher → your Revenue Cloud / quote app.
2. New Opportunity / Quote on **Acme** (US), Standard price book.
3. Browse Catalog / Product Discovery → catalog **BambooHR** (or search `Bamboo`).
4. Open categories **Plans**, **Add-ons**, **Packages**.
5. Confirm Core / Pro / Elite, Payroll / Benefits / Time / Global, and Workforce Package appear.

**Checkpoint:** Search `Bamboo` returns plans + Workforce + add-ons. Empty results → rebuild search index. Flat SKU `BAMBOO-CORE-FLAT-SM` is cataloged but is **not** a Workforce plan picker option.

### Configuration and Runtime Video

No dedicated recording captured yet for Summer '26. Use the runtime walkthrough above as the SE self-record / studio script. [NEEDS REVIEW — drop URL when recorded.]

---

## Feature 2: Headcount volume and Volume Tier Coach

### Business Objective

Model PEPM pricing where **quantity = employee headcount**, with transparent volume bands and an in-quote coach so AEs know how close they are to the next tier.

### Use Cases

**AE persona:**

- Quote BambooHR Pro at 10 employees (below volume), then 50 (5% band), and use the coach to narrate the next tier.

### Design Time Configuration

Volume tiers and coach LWC ship with the BambooHR pack (`bh-pricing` PAS/PAT + flexipage patch). No additional design-time steps for this exercise.

### Runtime walkthrough

1. On an **Acme** quote, add **BambooHR Pro** (or Core PEPM), quantity **10**.
2. Price — expect full list (Pro **$17** / Core **$10**); coach shows below first band.
3. Change quantity to **50**, reprice — 5% volume (25–75 band); Pro net PEPM ≈ **$16.15**.
4. Open the quote line side panel / **Volume Tier Coach** — current band + units to next tier.
5. Optional: Calculation Details → volume adjustment on the waterfall.

**Checkpoint:** Coach fields stamp on `BAMBOO-*` PEPM lines (not the package header, not the flat SKU).

### Configuration and Runtime Video

No dedicated recording captured yet for Summer '26. Use the runtime walkthrough above as the SE self-record / studio script. [NEEDS REVIEW — drop URL when recorded.]

---

## Feature 3: Small-business flat Core

### Business Objective

Offer a public-site-style flat rate for small teams without overloading PEPM Core with a procedure floor — modeled as SKU `BAMBOO-CORE-FLAT-SM`.

### Use Cases

**AE persona:** Pick the flat SKU deliberately on a Salesforce quote.  
**Buyer persona:** Get Pricing auto-routes Core + ≤25 employees onto the flat SKU.

### Design Time Configuration

Flat SKU + PBE in `bh-pcm` / `bh-pricing`. Get Pricing swap logic lives in `scripts/bamboohr/get_pricing/service.py`.

### Runtime walkthrough

**AE path**

1. New Quote on **Acme**.
2. Add **`BAMBOO-CORE-FLAT-SM`** (search “Small Business” / flat), quantity **1**.
3. Confirm net **$250**; no volume coach band.
4. Contrast: **BAMBOO-CORE** qty **25** remains PEPM × headcount.

**Get Pricing path (preferred)**

1. Open http://127.0.0.1:8765/.
2. Headcount **25**, Plan **Core**, country **US**.
3. Get pricing — sell SKU `BAMBOO-CORE-FLAT-SM`, monthly **$250** (add-ons still PEPM × headcount if selected).
4. Raise headcount **above 25** — PEPM Core/Pro behavior returns.

### Configuration and Runtime Video

No dedicated recording captured yet for Summer '26. Use the runtime walkthrough above as the SE self-record / studio script. [NEEDS REVIEW — drop URL when recorded.]

---

## Feature 4: Workforce package (Path A Bundle & Save)

### Business Objective

Primary commercial path: one plan + required Payroll & Benefits under a package, with **15% Bundle & Save** on those add-ons and package quantity locking children 1:1 to headcount.

### Use Cases

**AE persona:** Configure Workforce Package for Pro @ 25 and show BBA on Payroll/Benefits.

### Design Time Configuration

Package structure, PCG exclusivity, and BBA rows ship in BambooHR PCM/pricing data. Time/Global are intentionally **not** package components.

### Runtime walkthrough

1. New Quote on **Acme**.
2. Add **BambooHR Workforce Package** and configure:
   - Base Plan group: pick **Pro** (default).
   - Workforce Add-ons: Payroll + Benefits required.
3. Set package quantity **25** — children quantity = **25** (not editable).
4. Instant Pricing / save — Payroll & Benefits show **15% Bundle & Save** (BBA).
5. Optional: bump package qty to **50** — children track to 50.

**Checkpoint:** Cannot select two plans in the package (PCG min/max 1). Flat Core is not a package plan option.

### Configuration and Runtime Video

No dedicated recording captured yet for Summer '26. Use the runtime walkthrough above as the SE self-record / studio script. [NEEDS REVIEW — drop URL when recorded.]

---

## Feature 5: A la carte Bundle & Save (Path B)

### Business Objective

If the customer builds the same stack **without** the package (plan + Payroll + Benefits as siblings), still apply Bundle & Save 15% on the add-ons — without compounding on Instant/System reprice.

### Use Cases

**AE persona:** Show Path B when the deal is a la carte.  
**Buyer persona:** Check Payroll + Benefits together on Get Pricing.

### Design Time Configuration

Path B uses Quote flag + ManualDiscount overlay on ListPrice (`bamboohr_path_b_bundle_save*.json`). Path B flag clears when a Workforce package line is present so BBA does not double-stack.

### Runtime walkthrough

1. New Quote on **Acme** with **no** Workforce package line.
2. Add **Core** (or Pro) + **Payroll** + **Benefits**, quantity **10**.
3. Price — Calculation Details on Payroll/Benefits shows **BambooHR Bundle & Save 15% (a la carte)** (e.g. $8→$6.80, $6→$5.10).
4. Contrast a package quote — Path B flag stays false.

> Skip in short sessions if Act/Feature 4 already carried the commercial story.

### Configuration and Runtime Video

No dedicated recording captured yet for Summer '26. Use the runtime walkthrough above as the SE self-record / studio script. [NEEDS REVIEW — drop URL when recorded.]

---

## Feature 6: Nonprofit 15% and further AE discount

### Business Objective

Nonprofits get an automatic **15% list discount** from an Account flag (no special price book). AEs must still be able to **discount further** for strategic deals.

### Use Cases

**AE persona:**

- Quote Core on **BambooHR Nonprofit Demo** and show the nonprofit waterfall step.
- Apply an additional **Discount (%)** and show Net dropping further while Sales/`UnitPrice` stays at the post-nonprofit price.

### Design Time Configuration

- Account field `RLM_Is_Nonprofit__c`, Quote formula `RLM_Is_Nonprofit_Account__c`
- Context plan `BambooHrNonprofitPricing`
- Overlay `bamboohr_nonprofit_list_discount*.json` on Default + NearCore procedures

### Runtime walkthrough

1. Open Account **BambooHR Nonprofit Demo** — nonprofit flag true, BillingCountry **US**.
2. New Quote (Standard PB) → add **BambooHR Core**, quantity **1**.
3. Price — List stays **$10**; Sales/`UnitPrice` ≈ **$8.50**.
4. Calculation Details — **BambooHR Nonprofit 15% List Discount**.
5. Optional: quantity **50** — nonprofit first, then volume on the discounted input.
6. **Further discount:** set line **Discount (%)** to **10**, reprice.
7. Confirm `UnitPrice` remains **$8.50** and **`NetUnitPrice` ≈ $7.65**.

**Do not** set both Discount (%) and Discount Amount — platform integrity error.

**If Instant Pricing shows no nonprofit cut:** Quote procedure plan may be NearCore-only — repair with `ensure_bamboohr_quote_default_pricing_procedure`.

**Smoke:** `scripts/bamboohr/nonprofit_further_discount_smoke.py`.

### Configuration and Runtime Video

No dedicated recording captured yet for Summer '26. Use the runtime walkthrough above as the SE self-record / studio script. [NEEDS REVIEW — drop URL when recorded.]

---

## Feature 7: Country-gated add-ons (CA / UK)

### Business Objective

Payroll and Benefits are **US-only**. Canada and UK accounts must not see those add-ons in Discovery; plans and other add-ons remain available.

### Use Cases

**AE persona:** Browse Add-ons on **Prestige Worldwide** (CA) vs **Acme** (US).  
**Buyer persona:** Get Pricing country **CA** / **UK** disables Payroll/Benefits checkboxes.

### Design Time Configuration

Product Category Disqualification on `PC-BH-US-ADDONS` for non-US countries (including `GB` for UK). Null qualification is treated as qualified — use **disqualification**, not qualification-only rules.

### Runtime walkthrough

1. New Quote on **Prestige Worldwide** (BillingCountry **CA**).
2. Browse Add-ons / search Bamboo — **Payroll & Benefits hidden**; Time/Global (and plans) still available.
3. Contrast the same browse on **Acme** (US) — Payroll & Benefits visible.
4. Optional: Get Pricing country **CA** or **UK** — Payroll/Benefits disabled; Time/Global remain.

### Configuration and Runtime Video

No dedicated recording captured yet for Summer '26. Use the runtime walkthrough above as the SE self-record / studio script. [NEEDS REVIEW — drop URL when recorded.]

---

## Feature 8: Get Pricing dual channel (quote, PDF, checkout)

### Business Objective

Buyers can discover, price, open a real Quote, download a DocGen PDF, and checkout to assets without living in the Salesforce UI — same RC APIs the AE uses.

### Use Cases

**Buyer persona:** US · Pro · 50 · Payroll + Benefits → Path B nets → PDF → place order.  
**AE persona:** Open the resulting Quote in Salesforce and continue the deal.

### Design Time Configuration

BFF under `scripts/bamboohr/get_pricing/` (JWT Connected App recommended). DocGen template `RLM_QuoteProposal`. Optional thin Experience Cloud shell opens the BFF.

### Runtime walkthrough

1. Open http://127.0.0.1:8765/.
2. Country **US**, plan **Pro**, headcount **50**, add-ons **Payroll + Benefits**.
3. Get pricing — Path B note; summary ≈ Pro **$16.15**, Payroll **$6.46**, Benefits **$4.845** PEPM (see commercial table).
4. **Download PDF** — DocGen proposal (summary page stays open).
5. **Place order (checkout)** — Order → activate → assets.
6. Optional longer demo: amend true-up after activation.

**Checkpoint:** `GET /api/health` shows `authMode=jwt` (or CCI). Stale UI → hard refresh; stale logic → restart BFF.

### Configuration and Runtime Video

No dedicated recording captured yet for Summer '26. Use the runtime walkthrough above as the SE self-record / studio script. [NEEDS REVIEW — drop URL when recorded.]

---

## Feature 9: Convert-later free trial

### Business Objective

Offer a **30-day convert-later trial** at $0 for the plan and selected add-ons, capturing headcount up front so conversion reuses the same configuration.

### Use Cases

**Buyer persona:** Start trial from Get Pricing, see $0 nets + “If converted — your cost,” then convert to a paid quote.  
**AE persona:** Inspect `RLM_Bamboo_FreeTrial__c` and line EndDate ≈ today+30 on the Salesforce quote.

### Design Time Configuration

- Quote/Order field `RLM_Bamboo_FreeTrial__c`
- Context plan `BambooHrFreeTrial`
- Overlay `bamboohr_free_trial*.json` (100% ManualDiscount on ListPrice)

### Runtime walkthrough

1. Get Pricing form — check **Start with 30-day free trial**.
2. e.g. US · Pro · **50** (+ optional add-ons).
3. Summary — Plan net / Monthly / Annual = **$0.00**; trial banner visible.
4. **If converted — your cost** — paid line table + monthly/annual at that headcount.
5. Open the Salesforce Quote — flag true; EndDate ≈ today+30.
6. **Convert to paid pricing** — new paid quote (trial off), same plan/add-ons/headcount.
7. Optional: place order on the trial quote first ($0 trial assets), then convert for paid.

**Checkpoint:** Get Pricing smoke step for trial — monthly ~$0, paid estimate populated, EndDate +30d. Add-ons selected with the plan are also trialed at $0.

### Configuration and Runtime Video

No dedicated recording captured yet for Summer '26. Use the runtime walkthrough above as the SE self-record / studio script. [NEEDS REVIEW — drop URL when recorded.]

---

## Feature 10: Multi-currency CAD and GBP

### Business Objective

Demo Canada and UK deals in **native currency** (CAD / GBP) with matching price book entries, volume, and checkout — including renewal forecast opportunities stamped in the order currency.

### Use Cases

**AE / buyer persona:** Get Pricing country **CA** or **UK** produces CAD/GBP quotes and activated orders with native line nets.

### Design Time Configuration

CurrencyType + multi-currency PBEs / PAS / PAT / BBA clones in `bh-pricing`. Renewal flow customization stamps `Opportunity.CurrencyIsoCode` from the Order (`RLM_CreateUpdateRenewalOpportunities`).

### Runtime walkthrough

1. Get Pricing — country **UK**, Pro @ **25** → GBP quote (list ≈ **£13.43**, volume 5% → net ≈ **£12.76**).
2. Checkout → Activated order, currency **GBP**, assets created.
3. Repeat for **CA** / CAD (Pro list ≈ **C$22.95** before volume).
4. Optional: open **Renewal Forecast Opportunity** on the account — currency matches the order (GBP/CAD), not corporate USD.

**Smoke:** `scripts/bamboohr/checkout_multicurrency_smoke.py`.

### Configuration and Runtime Video

No dedicated recording captured yet for Summer '26. Use the runtime walkthrough above as the SE self-record / studio script. [NEEDS REVIEW — drop URL when recorded.]

---

## Suggested session cuts

### 15-minute AE cut

1. Feature 1 browse (2 min)  
2. Feature 2 volume + coach (3 min)  
3. Feature 4 Workforce package (5 min)  
4. Feature 6 nonprofit **or** Feature 7 CA disqual (5 min)

### 20-minute dual-channel cut

1. Feature 1 browse (2 min)  
2. Feature 3 flat via Get Pricing @ 25 Core (3 min)  
3. Feature 8 Get Pricing Pro@50 + Path B + PDF (7 min)  
4. Feature 9 free trial + convert preview (5 min)  
5. Optional checkout (3 min)

### 25–30 minute full story

Features 1–4 → 7 (CA) → 8–9 self-serve (flat + trial + convert). Add Feature 10 if multi-currency is in scope.

---

## Known issues / avoid

| Issue | Guidance |
|-------|----------|
| Empty Discovery search | `rebuild_search_index` |
| Nonprofit Instant Pricing missing | Ensure Default pricing procedure on Quote plan (not NearCore-only) |
| Double Bundle & Save | Don’t mix Workforce package + duplicate a la carte Payroll/Benefits expecting two 15%s |
| Flat vs PEPM Core | ≤25 Core in Get Pricing uses **flat SKU**; AE must pick `BAMBOO-CORE-FLAT-SM` deliberately in Salesforce |
| Free trial still priced | Confirm free-trial overlay + context on org; restart BFF after code pulls |
| BFF “Failed to fetch” | Use **http://127.0.0.1:8765/** and keep the server running |
| Discount % + Discount Amount together | Platform rejects both — use one |
| Rounding drift vs table | Worked nets are 2–3 decimal demo targets; Instant Pricing may show slight float differences |

---

## Repo pointers

| Asset | Path |
|-------|------|
| PCM plan | `datasets/sfdmu/bamboohr/en-US/bh-pcm/` |
| Pricing plan | `datasets/sfdmu/bamboohr/en-US/bh-pricing/` |
| Expression overlays | `datasets/expression_set_overlays/bamboohr_*.json` |
| Get Pricing BFF | `scripts/bamboohr/get_pricing/` |
| Prepare flow | `cci flow run prepare_bamboohr --org <cci-alias>` |
| Nonprofit further-discount smoke | `scripts/bamboohr/nonprofit_further_discount_smoke.py` |
| Multicurrency checkout smoke | `scripts/bamboohr/checkout_multicurrency_smoke.py` |
| Hands-on (this file) | `docs/enablement/262/bamboohr-hands-on.md` |

---

## Recordings backlog

Capture one short runtime clip per feature (or one combined AE cut + one dual-channel cut). Drop URLs into each feature’s **Configuration and Runtime Video** subsection when available.

| Suggested clip | Features covered |
|----------------|------------------|
| AE catalog → volume coach → Workforce package | 1, 2, 4 |
| Nonprofit + further Discount % | 6 |
| CA disqual vs Acme | 7 |
| Get Pricing flat @25 → Pro@50 Path B → PDF → checkout | 3, 8 |
| Free trial + convert preview | 9 |
| UK/CA multi-currency checkout | 10 |

---

## Open questions for author

- `[NEEDS REVIEW]` Runtime recording URLs (see backlog above).
- Whether to promote a shortened partner PDF once status → `review`.
- D2 feature attributes remain **parked optional** (not in this exercise).

---

## Footer

© Copyright 2000–2026 Salesforce, Inc. All rights reserved. Salesforce is a registered trademark of Salesforce, Inc., as are other names and marks.
