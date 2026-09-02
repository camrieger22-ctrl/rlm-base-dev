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
- **Disc %** on each line (`QuoteLineItem.Discount` via Place + FORCE — Default
  ManualDiscount / `ItemDiscountPercentage`), or **Option** scope in the footer
  to fan the same % out to every line on that option Quote
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
option. **Stop sync** clears `SyncedQuoteId`. Deleting the synced (or staged)
option — or removing **all** of its lines — clears sync and sets
**Opportunity.Amount to $0** so the Opp does not keep the prior quote total.
Switching options prompts before replacing the currently synced quote.

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
action). Requires **Commit** mode (`Use for Opportunity`). Status is stored on
`Quote.RLM_Approval_Status__c` and shown as chips on option tabs, the detail
header, and Compare (`Draft` / `Pending` / `Approved` / `Rejected` / `Recalled`).

**Discount ladder** (standard `QuoteLineItem.Discount` → line formula
`RLM_Approval_Level_Calc__c` → Quote rollup-max `RLM_Approval_Level__c`):

| Max line Disc % | Level | Approvers |
|-----------------|-------|-----------|
| &lt; 15 | 0 | Auto-Approved when payment terms are Net 30 |
| 15–24 | 1 | Manager |
| 25–34 | 2 | Manager → Director |
| ≥ 35 | 3 | Manager → Director → VP |

Suite shows a **Requires …** chip on the option header when the rollup level
&gt; 0 and status is Draft, and a **Needs …** chip on each line whose own
`RLM_Approval_Level_Calc__c` is &gt; 0 (so mixed Disc % options show which lines
drive Manager / Director / VP). Lines that need no approval chain (Disc %
**&lt; 15%**, level 0) show **Auto approved**. Material Place (qty, Disc %, term, seats,
.add/remove, reprice) are **locked** while status is **Approved** or **Pending**.
**Pending** → **Recall** (platform) first, then edit. **Approved** stays locked —
add a **new option** to re-quote. Rejected / Recalled clear to Draft on the next
material Place.

If Smart Approval cannot start, Submit still demo-falls back to Approved and
surfaces a sticky warning toast (`DEMO FALLBACK` in the summary).

**Pending approvals** (header button) lists `ApprovalWorkItem` rows in
`Assigned` status for the active option. Prefer the Quote **Approvals** tab
**Work Guide** for Manager → Director → VP (suite panel has **Open on Quote**).
Assignees (or public-group members) can still **Approve** / **Reject** in-suite
via `reviewApprovalWorkItem`. **Submit** writes a line-level ask into submission
comments (product, qty, Disc %, net/list PEPM, ladder) so email / work-item
reviewers and the suite panel show what is being requested. After each decision
the suite syncs `Quote.RLM_Approval_Status__c` (Quote Path / TLE): **Rejected**
immediately on reject; **Approved** only when platform `ApprovalSubmission`
status is Approved (not merely when Assigned work items are empty — the next
Manager→Director→VP step can lag); stays **Pending** while the submission is
InProgress. The Pending panel briefly re-polls after Approve so the next step
appears. **Recall approval** calls `recallApprovalSubmission`, sets status to
**Recalled**, and **auto-recommits** the staged Opportunity winner when priced
so Submit does not require another Use for Opportunity click.

### Suite ↔ TLE approval sync

Both surfaces share one field: `Quote.RLM_Approval_Status__c` (Path assistant +
suite chips). Platform `ApprovalSubmission` / `ApprovalWorkItem` is the source
of truth.

- Suite **open / listOptions / getOptionDetail / Pending panel** reconciles the
  field from the latest submission before rendering.
- Suite Approve/Reject/Recall writes the same field immediately after the
  platform action.
- Orchestration also writes via `RLM_AA_Set_Quote_Status`.
- TLE line `RLM_Approval_Flag__c` (stamped text with icons — TLE does not render
  formula fields) shows ✅ Auto approved (&lt;15% Disc), ⚠ Needs Manager/Director,
  or 🔴 Needs VP from Disc %. Must be mapped on `RLM_SalesTransactionContext`
  (`apply_context_approvals`) or the column stays empty. Suite line chips still
  hide “Needs …” once Path status is Approved.

Act in either Work Guide (Quote) or suite Pending approvals; hard-refresh the
other surface (or reopen the suite) to pick up reconcile.

### Option 2 — Reject → edit → resubmit (OOTB)

Approvals are **quote-level**, not per-line Approve/Reject. To refuse only some
of the ask (e.g. keep Core 25%, refuse Payroll 50%):

1. **Reject** the open work item with **required comments** naming the failing
   line(s) (e.g. `Reject Payroll @ 50%. Keep Core @ 25%.`).
2. Option becomes **Rejected** and **editable**. The suite shows a banner with
   those comments and next steps.
3. AE edits only the named products/discounts (acceptable lines stay as-is).
4. Edit as needed, then **Submit for approval** again (Recall auto-restores
   **Committed** sync when the staged option is still priced; otherwise
   **Use for Opportunity** first).
5. Platform **Smart Approval** (steps have `CanUseSmartApproval=true`) may skip
   re-review of unchanged conditions on resubmit after Rejected/Recalled.
   Changed lines / a higher max Disc % re-enter the Manager→Director→VP ladder.

This matches standard Revenue Cloud Advanced Approvals (Help: reject the quote
submission, adjust line discounts, resubmit). True split Approve-one/Reject-one
in a single work item is out of scope.

**Send to customer** emails an Opportunity Account contact (or an address
override) through `RLM_BambooQuoteEmail`, optionally attaching a DocGen proposal
PDF (generates via Preview when Attach PDF is checked). Allowed when the option
is **priced**, **Committed**, and **Approved**.

## Instant Pricing estimate (Slice 6)

Catalog **Preview RC pricing** (link under the list-price summary) runs `runSalesforceHeadlessPricing` via
`RLM_BambooHeadlessPricing` before **Add to option** — ephemeral RC pricing
through `RLM_SalesTransactionContext` / `QuoteEntitiesMapping` without creating
Quote lines. Workforce package still requires Add (configurator expand). Falls
back to list pricing if headless is unavailable.

## Next

### Pragmatic maintainability — Flow / RC first, Apex where needed

**Baseline (2026-09-02, post Wave 0–4):**
- `RLM_BambooRevenueSuite.cls` ~3583 LOC (was ~4312; Place bodies moved to edge)
- `RLM_BambooSuitePlace.cls` ~1020 LOC (single Place/FORCE edge)
- Suite LWC **21** Apex imports (was ~33): DTO reads + `runCommercialOperation` + Sync/DocGen/Send + approvals + txn poll
- Place hot path: `RevSalesTrxn` via Place edge / Commercial (not Flow-per-keystroke)

**Principle:** Lead with Flow and Revenue Cloud APIs for **lifecycle**. Use Apex only
for Place/FORCE (+ sync suspend), headless estimate, and thin DTO reads. Never wrap
qty/disc/add in a Flow interview (performance).

| Concern | Prefer | Apex role |
|---------|--------|-----------|
| Sync Pause/Commit/Clear/Recommit | Flow `RLM_Bamboo_Suite_Sync` | Invocable behind Flow (`RLM_BambooSuiteSync`) |
| Approval ladder / submit / recall | Flow `RLM_Quote_Smart_Approval` + AA | Thin submit/list/recall façade |
| Approver Approve/Reject | Quote Work Guide | Optional thin review until verified |
| DocGen start | Flow `RLM_Bamboo_Suite_DocGen_Start` | Thin poll Apex (`getProposalStatus`) |
| Send to customer | Flow `RLM_Bamboo_Suite_Send` | Invocable → `RLM_BambooQuoteEmail` |
| Place mutates (qty/disc/add/reprice/…) | RC Place via **`RLM_BambooSuitePlace`** | Commercial + Agentforce Invocables |
| Headless estimate | RC headless action | `RLM_BambooHeadlessPricing` |
| Session / catalog / option DTOs | — | Keep thin Apex reads |
| Agent BFF (`RLM_BambooAgent*`) | Out of scope | Untouched |

**Aura surface matrix** (`RLM_BambooRevenueSuite` unless noted):

| Method | Lead with | Notes |
|--------|-----------|-------|
| `openFromOpportunity`, `getSession`, `listOptions`, `addOption`, `deleteOption` | **keep Apex (DTO)** | Session; `OPP_SESSION_FIELDS` |
| Sync Commit/Clear | **Flow** | LWC → `RLM_BambooSuiteSync.applySyncAction` |
| `getCatalog`, `getOptionDetail`, contacts | **keep Apex (DTO)** | Read models |
| `estimateCatalogAdd` | **RC via thin Apex** | HeadlessPricing |
| DocGen Preview / Send | **Flow + thin Apex** | `RLM_BambooSuiteDocGen` / `RLM_BambooSuiteSend`; poll Apex |
| Approvals submit/list/review/recall | **Flow / OOTB** | Prefer Work Guide for act |
| Commercial mutates | **RC via Place edge** | LWC → `runCommercialOperation` only |
| `ensureGoodBetterBestOptions`, `fillTierOption` | **Place edge** | Ensure = DTO; fill → `RLM_BambooSuitePlace.fillTierOption` |
| Agentforce seats / commercial terms / tiers | **Place edge** | UpdateSeats / ApplyCommercialTerms / BuildTiers → Place |

**Domain classes:**

| Class | Owns |
|-------|------|
| `RLM_BambooSuiteSync` | Edit/Commit + Flow invocable + LWC `applySyncAction` |
| `RLM_BambooSuiteSession` | Session Opp load / enter Edit |
| `RLM_BambooSuiteApprovals` | Thin AA + Quote deep-link |
| `RLM_BambooSuiteCommercial` | Op table → Place edge |
| `RLM_BambooSuitePlace` | Place/FORCE: qty, disc, seats, remove, reprice, term, billing, add, workforce, fillTier |
| `RLM_BambooSuiteDocGen` | DocGen start Invocable / Aura |
| `RLM_BambooSuiteSend` | Send-to-customer Invocable / Aura → QuoteEmail |
| `RLM_BambooSuiteUpdateSeats` | Agentforce seats → Place |
| `RLM_BambooSuiteApplyCommercialTerms` | Agentforce term/billing → Place |
| `RLM_BambooSuiteBuildTiers` | Agentforce Good/Better/Best fill → Place |
| Flow `RLM_Bamboo_Suite_Sync` | Pause / Commit / Clear / RecommitStaged |
| Flow `RLM_Bamboo_Suite_DocGen_Start` | Proposal DocGen start |
| Flow `RLM_Bamboo_Suite_Send` | Send option email |

**Frozen:** do not add new Place graph builders to `RLM_BambooRevenueSuite` — put them on
`RLM_BambooSuitePlace` / Commercial only. Façade keeps Place **engine** only
(`placeForcePublic` / sync suspend + reprice assist).

**Product behaviors:**

- After **Recall**, auto-**RecommitStaged** when priced.
- Pending panel: **Open on Quote** (Work Guide primary).
- LWC mutates → `runCommercialOperation` / Place edge (not Flow-per-keystroke).

4d Phase B (orchestrator + Edit/Commit sync) — **PR1+PR2 implemented**:

- `RLM_Bamboo_Suite_Txn__c` + `RLM_BambooSuiteTxnOrchestrator` / `TxnJob`
- Opening the suite enters **Edit** mode (clears `SyncedQuoteId`, stages winner)
- **Use for Opportunity** commits sync (`Committed` mode)
- Approvals / Send require Commit mode
- Suite mutators enqueue+poll when orchestrator flag is on (default on)

Slice 7 ships Update Seats invocable, Quinn routing away from LineManagement
Quantity DML on suite options, and suite hard-refresh hints for stale Quote TLE.
