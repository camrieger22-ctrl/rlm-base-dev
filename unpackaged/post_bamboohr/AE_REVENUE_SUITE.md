# BambooHR AE Revenue Suite (Phase 0)

AE-internal quoting workspace inspired by the Neocol Revenue Suite screenshots.
**Does not change** the self-serve Get Pricing BFF.

## Hosting note

Phase 0 ships as a **Lightning App + Lightning Component Tab + LWC shell**
(Foundations-native, deploys with `deploy_post_bamboohr`). The tab targets the
suite LWC directly (no App Page header chrome) so branding matches Neocol:
opportunity title + BambooHR wordmark live in the LWC header only.

A true Multi-Framework **UIBundle** (`/lwr/application/…`) remains an optional
hosting upgrade once Multi-Framework is enabled on the target org; Apex session
APIs stay the same.

## Locked product decisions

See `.agents/artifacts/bamboohr-ae-revenue-suite-plan.md`.

## What Phase 0 includes

| Piece | API name |
|---|---|
| Lightning app | `RLM_Bamboo_Revenue_Suite` |
| Component tab | `RLM_Bamboo_Revenue_Suite` → `rlmBambooRevenueSuite` |
| Suite shell LWC | `rlmBambooRevenueSuite` |
| Opp Create Quote action | `Opportunity.RLM_Bamboo_Create_Quote` → `rlmBambooCreateQuoteAction` |
| Bootstrap Apex | `RLM_BambooRevenueSuite` |

`openFromOpportunity` creates or reuses a **Draft Quote** named `… — Option A`
(native RC: one Quote per suite option).

## Deploy

Deploy Quick Action **after** the LWC (same-transaction deploy can fail to resolve the component):

```bash
# Core shell
sf project deploy start --target-org <sf_alias> \
  --source-dir unpackaged/post_bamboohr/classes/RLM_BambooRevenueSuite.cls \
  --source-dir unpackaged/post_bamboohr/classes/RLM_BambooRevenueSuite.cls-meta.xml \
  --source-dir unpackaged/post_bamboohr/classes/RLM_BambooRevenueSuiteTest.cls \
  --source-dir unpackaged/post_bamboohr/classes/RLM_BambooRevenueSuiteTest.cls-meta.xml \
  --source-dir unpackaged/post_bamboohr/lwc/rlmBambooRevenueSuite \
  --source-dir unpackaged/post_bamboohr/lwc/rlmBambooCreateQuoteAction \
  --source-dir unpackaged/post_bamboohr/tabs/RLM_Bamboo_Revenue_Suite.tab-meta.xml \
  --source-dir unpackaged/post_bamboohr/applications/RLM_Bamboo_Revenue_Suite.app-meta.xml \
  --source-dir unpackaged/post_bamboohr/staticresources \
  --source-dir unpackaged/post_bamboohr/permissionsets/RLM_BambooHR.permissionset-meta.xml

# Then Quick Action
sf project deploy start --target-org <sf_alias> \
  --source-dir unpackaged/post_bamboohr/quickActions/Opportunity.RLM_Bamboo_Create_Quote.quickAction-meta.xml
```

Or `cci task run deploy_post_bamboohr --org <cci_alias>` once DocumentTemplate packaging is fixed for that path.

Assign **RLM_BambooHR** (app + tab + Apex). The running user also needs **Quote
create/edit** and Opportunity read from an RLM / Sales permission set.

## Try it

1. Open an **Opportunity** (hard refresh the page if it was already open).
2. In the highlight panel actions (top right of the record), click
   **Create Quote (Bamboo Suite)** — it sits next to **New Quote**.
3. Suite opens with Option A Draft Quote context.

If the button is under the overflow (**▼**), open that menu.

Repo wiring: `templates/flexipages/patches/bamboohr/RLM_Opportunity_Record_Page.yml`
(inserts the action when `bamboohr` is on during `assemble_and_deploy_ux`).

## Phase 1 (manual quoting MVP)

- Left catalog: Bamboo `BAMBOO-%` Standard PBEs (search + Frequent)
- Center: quantity + **Add to Option A**
- Right: live lines + MRR/ARR/**Grand total** + **Priced** chip
- Term pills select Evergreen (M2M) vs TermDefined PBE when adding lines
- **Add / qty / Reprice** use `RevSalesTrxn.PlaceSalesTransactionExecutor` with
  `PricingPreferenceEnum.FORCE` (RC pricing engine — no Apex list×qty math for nets)

Hard-refresh the suite after deploy. Try:

`/lightning/n/RLM_Bamboo_Revenue_Suite?c__opportunityId=<OppId>`

Change line quantity on the option card (debounced 400ms) to re-run FORCE pricing.

## Phase 2 (multi-option)

- **+ Add option** creates the next native Draft Quote (`… — Option B`, then C…)
- Option tabs switch the active Quote (Add / qty / Reprice target that Quote)
- **Compare** shows **Term**, **Billing**, **Grand total** (per-option commercial terms), plus MRR/ARR run rates and lines side-by-side; click a column to edit
- Catalog multi-select with **per-product quantity** in the queue, then one Place
- Path A Workforce bundle expand (Pro default); option lines group by
  `ParentQuoteLineItemId` — bundle head shows rolled-up list/net, children
  indented underneath. After configurator expand, suite **stamps** StartDate /
  EndDate / BillingFrequency onto **all** lines (parent + children) so a
  multi-year term is not left only on the package root. Term ribbon changes
  use Place **PATCH** (not DELETE+POST) so the bundle hierarchy survives.

## DocGen Preview

Header **Preview** starts `DocumentGenerationProcess` (GenerateAndConvert) for
the active option Quote via `RLM_Bamboo_QuoteProposal`, polls status, then opens
Lightning file preview for the PDF.

## Slice 4+ — Quoting Assistant + suite Agent column

Header **Agent** opens a slim right rail:

1. **Open Agentforce** opens Quoting Assistant (Quinn) via `lightning/accApi`.
   When a suite Opportunity is loaded, the suite also `execute`s a one-shot seed
   utterance with that Opp Id so Quinn sets `activeOpportunityId` — you do not
   need to paste the Id for later Good / Better / Best turns.
2. Chat only in the Agentforce panel (not a second composer in the suite).
3. **Refresh options** / **Compare** after Quinn builds tiers.

**Tier map (via Quinn BambooSuiteTiers):** Good = Core+Payroll+Benefits (Path B);
Better = Workforce Pro (Path A); Best = Elite+Payroll+Benefits+Time (Path B).

Does **not** call self-serve BFF `RLM_BambooAgent*` actions.

Demo user needs **RLM_QuotingAssistant** + **RLM_BambooHR**. After `.agent`
changes: `deploy_agents` → `publish_agents` → `activate_agents`.

### Agent — term / billing on existing options

When Quinn changes **term** or **billing** on Options A/B/C (without rebuilding
tiers or changing seat count), it must call **`BambooHR Suite Apply Commercial
Terms`** (`RLM_BambooSuiteApplyCommercialTerms`) — Place + FORCE on **all**
suite options, quantities preserved.

Do **not** use LineManagement `Update_Record_Fields` or `BambooHR Suite Build
Tier` with a tierKey for this path (Build Tier clears lines and defaults seats
to 50).

After agent changes: **Refresh options** or **Compare** in the suite.

### Agent — seat count on existing options

When Quinn changes **seat count / headcount** on one Option A/B/C (without
rebuilding tiers), it must call **`BambooHR Suite Update Seats`**
(`RLM_BambooSuiteUpdateSeats`) — Place + FORCE on **all lines** of that option.
Do **not** use LineManagement `Update_Record_Fields` for `Quantity` on suite
option quotes (`… — Option A/B/C`).

When the utterance also changes **term and/or billing** on the same option, or
names **two or more options with different settings each** (e.g. Option B 5,000
seats / 2-year / Annual; Option C 7,000 / 3-year / Quarterly), Quinn uses
**PATH A3**: one **Update Seats** call per named option with `seatCount`,
`termMonths`, and `billingFrequency` together. Do **not** call Apply Commercial
Terms to all options in that scenario — the second global apply would overwrite
the first option’s terms.

Apply Commercial Terms supports `optionLabel` when only one option should change
term/billing with **unchanged** seat count.

After agent seat changes: **Refresh options** in the suite. If the native Quote
**line editor** still shows the old qty, hard-refresh that Quote tab (the TLE
client cache is platform-owned; suite Refresh and `Quote.GrandTotal` are
authoritative).

## Sync winning option to Opportunity

After pricing an option, **Use for Opportunity** sets `Opportunity.SyncedQuoteId`
to that option Quote (platform Start Sync). Opp Amount / products update for
forecasting. Tabs and Compare show an **On Opportunity** badge on the synced
option. **Stop sync** clears `SyncedQuoteId`. Switching options prompts before
replacing the currently synced quote.

Does not invent a custom PrimaryQuote field — uses classic RC Quote sync.

While an option is synced, Place (term/qty/add/reprice) **automatically pauses**
`SyncedQuoteId` for the PST call. Restore runs on a **Queueable** after Place
(with lock retries) so Opp DML does not race Place or platform automatic reprice.
You do not need to Stop sync before editing sibling options.

### Opp lock / stale price (Slice 4d Phase A)

Multi-option suites share one Opportunity. When `SyncedQuoteId` is set, PST can
hit `UNABLE_TO_LOCK_ROW` if platform automatic reprice or another writer holds
the Opp. Suite Place paths:

1. Clear sync (retry up to 3× on lock)
2. Place FORCE (+ one verify reprice if `ValidationResult` / nets look stale)
3. Enqueue restore of the prior `SyncedQuoteId` (retry on lock)

If the suite still surfaces a row-lock error: wait and retry, or open the option
Quote → **Reprice All** → **Refresh options** in the suite. After Agentforce or
suite Place, **hard-refresh** the native Quote page if Instant Pricing shows
stale dates/totals (TLE client cache; suite Grand total is authoritative).

## MRR, ARR, and Grand total

| Metric | Source | Meaning |
|--------|--------|---------|
| **MRR** | Sum of priced net units × qty on lines (monthly run rate) | Suite-computed monthly subscription |
| **ARR** | MRR × 12 | 12-month run rate — **not** full contract value on multi-year terms |
| **Grand total** | `Quote.GrandTotal` (fallback `TotalPrice`) | RC header rollup — full contract value; matches Quote record and synced **Opportunity Amount** |

On 36-month deals, Grand total ≈ MRR × 36 while ARR stays MRR × 12. Reps should cite **Grand total** for contract value and **ARR** for annual run-rate conversations.

Option tabs, the detail metrics row, Compare, and the footer **Grand total** row all read the platform header — not MRR × term.

Native Quote with Instant Pricing **Active** may show billing-period line totals
and first-period dates; after a hard refresh (IP off) the grid matches persisted
contract totals and suite Grand total.

## Approvals + Send (Slice 5)

**Submit for approval** on the active option starts `RLM_Quote_Smart_Approval`
via `RLM_AA_Submit_Approval` (same path as the Quote **Submit for Approval**
action). Status is stored on `Quote.RLM_Approval_Status__c` and shown as chips
on option tabs, the detail header, and Compare (`Draft` / `Pending` /
`Approved` / `Rejected` / `Recalled`). Quotes with no discount / payment-terms
criteria often move straight to **Approved**.

**Send to customer** emails an Opportunity Account contact (or an address
override) through `RLM_BambooQuoteEmail`, optionally attaching a DocGen proposal
PDF (generates via Preview when Attach PDF is checked). Allowed when the option
is **priced** and **not Pending**.

## Instant Pricing estimate (Slice 6)

Catalog **Estimate** runs `runSalesforceHeadlessPricing` via
`RLM_BambooHeadlessPricing` before **Add to option** — ephemeral RC pricing
through `RLM_SalesTransactionContext` / `QuoteEntitiesMapping` without creating
Quote lines. Workforce package still requires Add (configurator expand). Falls
back to list pricing if headless is unavailable.

## Next

4d Phase B (orchestrator + Edit/Commit sync) remains deferred.

Slice 7 ships Update Seats invocable, Quinn routing away from LineManagement
Quantity DML on suite options, and suite hard-refresh hints for stale Quote TLE.
