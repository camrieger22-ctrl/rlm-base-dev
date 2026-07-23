# Close-Won Order & Reprice Automation

A thin, out-of-the-box-respecting automation layer that streamlines the
Revenue Cloud quote → order → renewal lifecycle. When an Opportunity is
closed as **Won**, the user is prompted to create the order from the synced
quote; quotes are auto-repriced so they're always current; and reprice
failures are surfaced instead of failing silently.

This document records **what we built vs. what is standard**, so future
maintainers know the automation orchestrates platform behavior rather than
replacing it.

## What is / isn't out of the box

The end-to-end renewal lifecycle itself is **standard**. What this feature
adds is a custom automation + UX layer that *drives* those standard
capabilities (removing manual clicks and adding guardrails). Nothing here
forks, overrides, or replaces platform behavior — it is fully removable
without breaking any standard function.

### Tier 1 — Salesforce Revenue Cloud platform (used/verified, not built)

- Order creation from a quote — `createOrdersFromQuote` action
- Repricing engine — Place Sales Transaction / "Reprice All"
  (`RevSalesTrxn.PlaceSalesTransactionExecutor`)
- Order activation → DRO fulfillment (BillingSchedules)
- Assetization — `createOrUpdateAssetFromOrder` / `CreateAssetOrderEvent`
- Renewal opportunity generation from renewable assets

### Tier 2 — Foundations repo baseline (shipped with the base org build)

These `RLM_*` flows already exist in `force-app/` and orchestrate the Tier‑1
actions. They were **not** authored as part of this feature:

- `RLM_CreateOrdersFromQuote`
- `RLM_Submit_Order_on_Activation`
- `RLM_CreateUpdateRenewalOpportunities`
- `RLM_Platform_Event_CreateAssetOrderEvent_Stamp_Asset_Renewal_Info`

The renewal chain (activate → fulfillment → assetization → renewal opp) lives
entirely in Tiers 1–2. It was verified live, not built here.

### Tier 3 — Built by this feature (custom)

| Component | Path | What standard does without it |
| --- | --- | --- |
| Close-Won order prompt (wrapper flow) | `force-app/main/default/flows/RLM_Opp_Create_Orders_Prompt.flow-meta.xml` | User manually hits "Create Order" |
| Inline placement of the prompt on the Opportunity page | `templates/flexipages/base/RLM_Opportunity_Record_Page.flexipage-meta.xml` (assembled to `unpackaged/post_ux/`) | No inline prompt |
| Auto-reprice on quote sync | `force-app/main/default/flows/RLM_Reprice_Quote_On_Sync.flow-meta.xml` | User manually clicks "Reprice All" |
| Auto-reprice on line add/change | `force-app/main/default/flows/RLM_Reprice_Quote_On_Line_Change.flow-meta.xml` | User manually clicks "Reprice All" |
| Auto-reprice on line delete | `force-app/main/default/flows/RLM_Reprice_Quote_On_Line_Delete.flow-meta.xml` | User manually clicks "Reprice All" |
| Force-reprice invocable + async worker | `force-app/main/default/classes/RLM_RepriceQuoteInvocable.cls` (+ test) | n/a (wraps the standard executor) |
| Reprice-failure owner notification | `RLM_RepriceQuoteInvocable.handleRepriceFailure` | Failure is silent until the "prices aren't updated" error at order time |
| Enforce synced quote before Closed Won | `force-app/main/default/objects/Opportunity/validationRules/RLM_Sync_Quote_Before_Closed_Won.validationRule-meta.xml` | No enforcement |

## How it fits together

1. A quote is synced to the Opportunity (`Opportunity.SyncedQuoteId` populated).
   - `RLM_Reprice_Quote_On_Sync` fires → `RLM_RepriceQuoteInvocable` force-reprices
     the quote asynchronously so prices are current by Closed Won.
2. While the quote is the synced (syncing) quote, line add/change/delete triggers
   (`RLM_Reprice_Quote_On_Line_Change`, `RLM_Reprice_Quote_On_Line_Delete`) keep
   it repriced.
3. The `RLM_Sync_Quote_Before_Closed_Won` validation rule blocks the transition
   to Closed Won unless a quote is synced. It is scoped to the *transition* only,
   so it never blocks later edits (e.g. clearing `SyncedQuoteId` on an
   already-Closed-Won opp during an account reset).
4. On Closed Won, the inline `RLM_Opp_Create_Orders_Prompt` wrapper looks up
   `SyncedQuoteId` server-side from the Opportunity `recordId`, then subflows into
   the standard `RLM_CreateOrdersFromQuote`. (The wrapper exists because passing
   `{!Record.SyncedQuoteId}` directly to the screen flow bound a literal string
   and faulted.)
5. Order activation, DRO fulfillment, assetization, and renewal-opportunity
   creation all proceed via the standard Tier‑1/Tier‑2 chain.

## Reprice failure handling

Repricing runs in a `Queueable` (outside the triggering transaction, since the
executor may perform tax/rate callouts). Each quote's reprice is isolated in a
`try/catch`; on failure the quote owner is emailed (with the error, a record
link, and the "Reprice All" remediation) and an `ERROR` is logged. The notifier
never throws, so a notification problem cannot mask the original failure.

## Deployment status

Wired into the org build behind the `closewon` feature flag (default
`true`):

| Piece | Where |
| --- | --- |
| Feature flag | `project.custom.closewon` in `cumulusci.yml` |
| Metadata bundle | `unpackaged/post_closewon/` (flows, Apex, validation rule) |
| Deploy task | `deploy_post_closewon` |
| Sub-flow | `prepare_closewon` (step 28 of `prepare_rlm_org`) |
| Opportunity page embed | `templates/flexipages/patches/closewon/` (applied during `prepare_ux` only when `closewon` is true) |

Set `closewon: false` to omit the automation from a build. The Tier‑1 /
Tier‑2 renewal chain is unaffected either way.

## Amendment difference quoting (Current → Proposed → Net increase)

Locked definitions (use these for UI, Quote fields, and future DocGen):

| KPI | Definition |
| --- | --- |
| **Current spend (ARR)** | Σ(`NetUnitPrice` × `Quantity`) across Asset Action Source rows for assets on the amendment quote |
| **Current MRR** | Current ARR ÷ 12 |
| **Current qty** | Σ Asset Action Source `Quantity` on those rows |
| **Proposed spend (ARR)** | Same formula after adding positive-qty amendment Quote Line Item(s) as an extra tranche |
| **Proposed MRR / qty** | From the proposed rollup |
| **Net increase** | Proposed − Current (ARR, MRR, and qty) |

Decrease/cancel projection is parked; when no add projection exists, Proposed is stamped equal to Current and Net Increase is 0.

| Piece | Location |
| --- | --- |
| Quote fields | `RLM_Amend_Current_*` / `RLM_Amend_Proposed_*` / `RLM_Amend_Net_Increase_*` (`ARR`, `MRR`, `Qty`) in `unpackaged/post_closewon/objects/Quote/fields/` |
| Stamp | `RLM_AssetPriceHistoryController` on panel load/refresh **and** after successful `RLM_RepriceQuoteInvocable` force-reprice |
| Seller UI | `rlmAssetPriceHistory` — Current contract / Proposed / Impact (Δ); Details tab **Difference quoting** field section (closewon flexipage patch) |
| Amendment Studio (Phase 2+) | `rlmAmendmentStudio` embeds on Amend Quotes (`OriginalActionType = Amend`) as the primary workspace after Managed Asset Viewer → `initiateAmendment`. Layout: left **Catalog** (common products + search/add) · Current / This add / Finalized KPIs · Working changes (qty, discount, start, **OOTB pricing-procedure waterfall** after reprice + list/discount preview while dirty, prorated term) · **Installed** ledger in a slide-over (header + Current KPIs). Classic TLE/summary hidden on Amend Quotes. Surfaces `ValidationResult` / `CalculationStatus` when pricing needs attention. **Next:** Product Discovery / configurator, decrease/cancel + multi-asset. |
| Pricing: Discount % off list on LastTransaction | Overlay `datasets/expression_set_overlays/amendment_list_percent_discount.json` (applied in `prepare_closewon`) |
| DocGen | `RLM_QuoteProposal` tokens `AmendCurrent*` / `AmendProposed*` / `AmendNetIncrease*` via `RLMQuoteExtractBasic` + `RLMQuoteTransformBasic` (blank on non-amendment quotes) |

## Verification

- Renewal chain (Tier 1–2) verified live: order activated → BillingSchedule
  generated → 1 asset assetized → renewal opportunity auto-created with the
  product line pulled in and a close date matching the asset's term end.
- Amendment path (Tier 1–2) verified live against the same asset: `initiateAmendment`
  (+1 quantity) → amendment quote → order → activate → asset state periods
  split (qty 1 then qty 2) → **existing** renewal opportunity updated in place
  (OLI quantity 1→2, amount $450→$900). No second renewal opp was created.
- `RLM_RepriceQuoteInvocable` unit tests pass (reprice paths, deleted-quote
  skip, surfaced-failure path, never-throws guarantee).
