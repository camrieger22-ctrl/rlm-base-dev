# BambooHR Get Pricing + Checkout (dual-channel P2/P3)

Thin BFF + branded form for the self-serve “Get Pricing” path (fork-only).
Runs **locally** (CCI) or **hosted** (public URL via tunnel / JWT Connected App).
See **[HOSTED.md](./HOSTED.md)** for public demos, **[EXPERIENCE_CLOUD.md](./EXPERIENCE_CLOUD.md)**
for the EC shell, and **[PAYNOW.md](./PAYNOW.md)** for Salesforce Payments /
Pay Now (checkout + Licenses weave-in plan).

## Flow

**Default path = micro self-serve (&lt;25)** per BambooHR workshop MVP:

0. **Qualify** (workshop 5-beat wizard): exact employee count → US/CA → needs
   (Payroll/Elite bounce live) → decision-maker role → **create account**
   (first / last / work email / company). Needs auto-select Core or Pro.
   At work email the BFF **looks up Contact** (never a Lead). Open sales Quote
   → “Sales is already working this.” Assets on the Account → “You already have
   BambooHR — sign in.” Otherwise stay on self-serve. Incomplete wizards persist
   server-side (`/qualify-inbox`) with **1-day / 1-week abandoned cadence**
   (demo mailto + mark-sent). Optional `?utm_campaign=` stamps journey #0.
   Agent chat reads `qualifyStep` / bounce context to walk the five beats.
1. User continues to **Core or Pro** only (Elite / add-ons hidden). Headcount 1–24.
   **Standard list PEPM** × headcount (no `BAMBOO-CORE-FLAT-SM` package).
   Month-to-month PEPM by default (`termMonths=1`); buyers can also pick a
   **12 / 24 / 36**-month commitment. Same Term Monthly PBEs; Quote line
   StartDate/EndDate span the selected window (`ALLOWED_TERM_MONTHS`).
2. Configurator changes call **`/api/get-pricing-estimate`**: Salesforce
   **Pricing API** (headless) prices the cart with synthetic Quote/QLI ids —
   **no Opportunity or Quote** is created while configuring. Local math paints
   the rail instantly; the API replaces it (~1–2s). Falls back to local
   Bundle→volume math if Pricing API is unavailable.
3. BFF **matches/updates Contact** at **Create your account** (beat 5), not only
   at Get your quote — so the record exists to mark *sales don’t touch*. Dual-motion
   / existing-customer emails return **409** and never place a competing Quote.
   Wizard bounces (Payroll / ≥25 / geo) still **capture the prospect for sales**.
4. **Get your quote** calls **`/api/get-pricing`**: places Opportunity + Quote
   named `SelfServe - …` with buyer-selected **StartDate / EndDate** on Quote
   lines and System reprice.
5. Browser shows a branded summary → **Place order** → Pay Now → Create login.

SE escape hatch: open `/?fullCatalog=1` (or `BAMBOO_MICRO_SELF_SERVE=0`) to restore
Elite / add-ons / UK / free trial. Optional `BAMBOO_SALES_HANDOFF_URL` for the
Talk to sales CTA.

### Why these CRM steps exist (Aug 12 workshop PDFs)

These are not extra product ideas. They close gaps the room named:

| What we added | Why (transcript / notes) |
|---------------|--------------------------|
| **Stamp Account/Contact at beat 5** (`POST /api/qualify-commit`) before Get your quote | Jeff ~01:59: *it has to exist so we can mark it “sales don’t touch.”* N 219 ~00:39: create-account is the moment they **stayed on self-serve**. Drop-off after recommend must still appear on **Self-serve — do not call**. |
| **Capture wizard bounces into sales** (`POST /api/qualify-handoff` + Task) | N 219 ~00:39: a 24-person company that needs Payroll is *qualified to talk to a person*, not discarded. SDRs stop collecting data and take **complex** leads. The panel asks for work email/company if missing so we don’t lose them. |
| **Suppress Flow** (`RLM_Bamboo_SelfServe_Contact_Gate` + Account stamp) | Jeff ~01:59 / quick notes: update the record **and suppress** standard sales outreach so they are not called while they self-serve. Demo proof: SelfServe Contact → Do Not Call, **no** `SDR: qualify inbound` Task; a normal inbound Contact still gets one. |

Never insert a Lead. Dual-motion (open AE Quote) still blocks a competing self-serve Quote.

> Term selection is commercial hygiene: it does **not** make monthly × 12 equal
> a prorated amend Quote total on Licenses.

| Country | Fallback demo Account (no buyer) |
|---------|-----------------------------------|
| US | Acme |
| CA | Prestige Worldwide (Payroll/Benefits disqual) |
| UK | BambooHR UK Demo |

## Run (local)

Preferred (uses CumulusCI pipx Python + PyJWT):

```bash
# from repo root
./scripts/bamboohr/get_pricing/run_server.sh master-demo
# HOST=0.0.0.0 PORT=8765 ./scripts/bamboohr/get_pricing/run_server.sh master-demo
```

Or call the CCI Python directly:

```bash
# from repo root — note the space in --port 8765
~/.local/pipx/venvs/cumulusci/bin/python \
  scripts/bamboohr/get_pricing/server.py --org master-demo --port 8765
```

Then open http://127.0.0.1:8765/ in a browser.

### Hosted (quick)

```bash
# terminal 1
~/.local/pipx/venvs/cumulusci/bin/python \
  scripts/bamboohr/get_pricing/server.py --org master-demo --host 0.0.0.0 --port 8765

# terminal 2 — public HTTPS URL
./scripts/bamboohr/get_pricing/run_tunnel.sh
```

Full JWT / Docker / Connected App steps: **HOSTED.md**.

### API

| Method | Path | Body |
|--------|------|------|
| GET | `/api/health` | — |
| GET | `/api/qualify-sessions?incomplete=1` | Abandoned wizard sessions (demo inbox). `?sessionId=` returns one. |
| GET | `/qualify-inbox` | Abandoned sessions + cadence stage (waiting / 1-day due / 1-week due) + resume / mailto / mark-sent |
| POST | `/api/qualify-cadence` | Demo inbox: `{ sessionId, which: day1\|week1 }` marks follow-up sent |
| GET | `/api/agent-config` | Agentforce / Messaging embed flags (`enabled`, `preview`, deployment ids) — no secrets |
| GET | `/api/catalog?country=US\|CA\|UK` | Curated SKUs → org PBE list PEPM / names / availability |
| GET | `/api/account-console?accountId=\|company=\|ecToken=` | Licenses & billing (demo pin or EC HMAC handoff); includes open `invoices` and `team` (named onboard Contacts vs licensed seats) |
| GET | `/api/account-invoices?accountId=\|company=\|ecToken=` | Posted invoices with balance &gt; 0 (+ Active Pay Now URL when present). Per-invoice `paidApplying` when a Processed Payment of that amount was created at or after the invoice (Balance lag). `bucket` is `thisBill` (invoices of the latest Activated Order that still has an open/paid-applying bill) or `earlier` (prior-change leftovers — stay earlier after this bill applies, unless the only remaining group is paid-applying). Leftover invoices of other amounts stay payable. Also account-level `paymentReceived` / `pendingBalanceApply`. |
| GET | `/api/account-amend-place-status?accountId=&quoteIds=` | Recover Place: newest Activated Order for those Quote ids (success when Place HTTP timed out). |
| GET | `/api/activate?accountId=\|company=\|ecToken=` | Post-pay activation: `customerSteps` (paid / licensed / signed in) + `ahaSteps` (employees, invite, time-off, licenses). `setup` is Day N of 14 from Pay Now. `needs` personalizes aha order/copy from Account `RLM_Bamboo_PrimaryNeeds__c`. Invite and time-off are done only when the CRM Task exists. |
| POST | `/api/activate` | Complete an aha step: `{ accountId\|company\|ecToken, firstName+lastName+email?, adminEmail?, timeOffPolicy? }`. Person → Contact (`RLM_Bamboo_OnboardEmployee__c`). `adminEmail` → Contact + Task *Invited as BambooHR admin*. `timeOffPolicy` → Account field + Task *Set time-off policy* (no email / no PTO engine). |
| GET | `/activate` | Branded activate checklist UI |
| GET | `/api/catalog?country=&fullCatalog=` | Hydrated plans/add-ons. Micro mode (default) returns **Core/Pro only**; `fullCatalog=1` for full catalog. |
| GET | `/api/ec-handoff?token=` | Verify EC handoff → `{ accountId, contactId, exp }` |
| POST | `/api/create-login` | `{ accountId, contactId?, email, password }` → community User + `ecToken` handoff |
| POST | `/api/account-amend-estimate` | Pricing API before/after → est. prorated change lines (`dueToday` provisional). `{ accountId, newQty?, addonSkus?, upgradeSku?, startDate? }` — Core→Pro uses `upgradeSku=BAMBOO-PRO`. Exact charge after Generate quote |
| POST | `/api/account-amend-preview` | Generate / **update** quote: sticky Draft Quotes + System reprice (no Activate). Pass prior `amendQuotes` / `moduleQuoteId` / `upgradeQuoteId`. `upgradeSku` calls Initiate Upgrade (one Quote). Returns `dueToday` from Quote TotalPrice |
| POST | `/api/account-amend` | `{ accountId, newQty?, addonSkus?, upgradeSku?, amendQuotes?, moduleQuoteId?, upgradeQuoteId? }` → activate preview Quotes → Order. Returns when the Order is Activated (invoice/Pay Now is collected after). Core→Pro is OOTB Initiate Upgrade, not cancel + replace. |
| POST | `/api/qualify-session` | Persist wizard progress (size/geo/needs/role/email/UTM). `{ sessionId?, step, headcount, country, needs, dmRole, email, company, utm }` |
| POST | `/api/qualify-lookup` | `{ email }` → `{ status: selfServe\|salesWorking\|existingCustomer }` — Contact lookup, never a Lead |
| POST | `/api/qualify-commit` | Beat 5: match/update Account+Contact and stamp SelfServe **before** Quote. `{ buyer?, headcount, country, needs?, dmRole?, utm? }` — top-level discovery fields merge into `buyer` |
| POST | `/api/qualify-handoff` | Wizard bounce: upsert Contact (not SelfServe), stamp Account `SalesHandoff` + HC/needs, reuse open “Qualified to talk…” Task (or create). Re-entry → `salesWorking`. `{ buyer, bounceReason, bounceType }` · `alreadyWorking` when prior sales path |
| POST | `/api/get-pricing-estimate` | Pricing API rail estimate (no Opp/Quote). `{ headcount, country, planSku, addonSkus?, freeTrial?, startDate?, termMonths? }` |
| POST | `/api/get-pricing-preview` | (Legacy / rollback) Sticky Draft Quote + System reprice. Pass `quoteId` to reuse. |
| POST | `/api/get-pricing` | `{ headcount, country, planSku, addonSkus?, placeQuote?, previewQuoteId?, startDate?, termMonths?, buyer? }` — places Opp+Quote (or promotes sticky preview if provided). `buyer` includes `email`, `needs`, `dmRole`, `sessionId`, `utm`. Dual-motion / existing customer → **409**. `termMonths` ∈ {1,12,24,36}; defaults start=today, term=**1** (month-to-month) |
| POST | `/api/collect-payment` | `{ orderId? \| invoiceId?, pollTimeout?, emailPayment?, toEmail? }` — invoice + PaymentLink; optional Pay Now email |
| POST | `/api/payment-email` | `{ paymentUrl? \| invoiceId? \| orderId?, toEmail?, accountId? }` — email Pay Now link via Apex |
| POST | `/api/checkout` | `{ quoteId, amendQty?, pollTimeout?, collectPayment?, emailPayment?, toEmail? }` — after activate, invoices the order and attempts Salesforce Payments Pay Now (`payment` on response; optional email) |
| POST | `/api/docgen-pdf` | `{ quoteId, templateName?, title?, timeout? }` → `downloadUrl` |
| GET | `/api/docgen-pdf/<contentVersionId>` | PDF bytes (attachment) |
| POST | `/api/quote-email` | `{ quoteId, toEmail?, attachPdf? }` → Salesforce sends quote email (+ DocGen PDF) |

**Licenses & billing UI:** `/account` — subscription snapshot (**month-to-month
vs 12/24/36-month term**, paid PEPM, recurring monthly total), **Your plan**
(Core→Pro in-product upgrade; Elite stays with sales), **Your team** (same
Contacts as `/activate`; add-teammate does not change Asset quantity), open
invoices (Pay Now), recent orders, qty amend preview/place.
Demo pin via Account Id / company name; buyer path via Experience Cloud login →
signed `ecToken` (see `EXPERIENCE_CLOUD.md`). Open **Pay** in a private window
if you’re also logged into Salesforce (guest Pay Now + admin cookies conflict).

Pay Now weave-in plan / phases: **[PAYNOW.md](./PAYNOW.md)**.

**Public / EC URL:** keep BFF running, then
`./scripts/bamboohr/get_pricing/run_tunnel.sh` (syncs Custom Label). Stable host:
HOSTED.md Path C (`publish_bff.py --named`).

**Licenses rail** shows an **estimated prorated charge** from the Pricing API
(monthly delta × remaining term) with per-line seat deltas. ``Asset.CurrentMrr``
still drives “today” on the account. **Generate quote** creates Draft Quotes +
System reprice; the amend summary shows the exact Quote TotalPrice.

**Core→Pro (month-to-month and annual):** same OOTB Initiate Upgrade. Pro
inherits Core’s remaining lifecycle window — it does **not** restart a new
year and it does **not** convert month-to-month into annual.

| Current Core term | After upgrade |
|-------------------|---------------|
| Month-to-month (~1-month Asset window) | Pro through this period end; still month-to-month |
| 12 / 24 / 36-month | Pro through original term end (coterminous) |

Estimate math is monthly delta ($7 PEPM × seats) × remaining calendar-month
fraction from Core `LifecycleEndDate`. If that end date is missing, the rail
withholds the estimate instead of inventing 365 days. UpgradeTo `EndDate`
defaults to **+1 month** when the source window is absent (Get Pricing default
term), never +12. Quote TotalPrice after System reprice is the charged amount.

Smoke both term types on **fresh** Core accounts (do not reuse an already
upgraded demo Account). Place + Pay on Get Pricing, then Licenses → Upgrade
to Pro, seats unchanged, no add-ons:

1. **Annual** — buy Core with `termMonths` 12/24/36. Expect Pro `EndDate` =
   remaining Core end (not a new 12-month restart). Prorated charge ≈ rest of
   commitment × $7 × seats.
2. **Month-to-month** — buy Core with default `termMonths=1`. Expect Pro
   `EndDate` ≈ Core period end (~1 month), **not** +12 months. Prorated
   charge ≈ rest of this month × $7 × seats.

After Pay, Asset Actions should be **UpgradeFrom / UpgradeTo**. If Initiate
Upgrade 404s or 500s, fail openly — there is no cancel+replace fallback.
Account billing address is required for Order Activate.

**Amend summary:** ``POST /api/account-amend-preview`` attaches
``amendSummaryView``. The ``/amend-quote/{id}`` page renders that view
(**Quoted now (remaining term)** hero, line items with each line's start and
end dates, Place order; per-Quote parts when both seat-change and add-module
Quotes exist). Pay Now is the **first Billing invoice**, which can be a shorter
slice than this Quote total. Generate quote from Licenses caches the preview
(including the view) then opens the summary.

**Upcoming changes** on `/account` come from ``AssetStatePeriod`` (account-level
date ranges with seats + MRR). Draft Place-order math is never mixed into that
timeline.

### Agent chat (Phase 1 embed)

BFF pages load `/static/agent-chat.js`. By default you get a **preview launcher**
(“Ask assistant”) so demos can see the surface before Messaging is connected.

| Env | Effect |
|-----|--------|
| unset / `AGENT_CHAT_PREVIEW=1` | Preview shell only (no Salesforce chat) |
| `AGENT_CHAT_ENABLED=1` + deployment fields | Loads Messaging for In-App and Web |
| `AGENT_CHAT_PREVIEW=0` and not enabled | No launcher |

Context (`page`, `accountId`, sticky Draft ids, …) is published as
`window.BH_AGENT_CONTEXT`. Locked product rules: guest may **estimate**; Quote
create needs company + email; **Place order stays on the summary CTA**; actions
call the BFF (Phase 2). Plan:
`.agents/artifacts/bamboohr-bff-agentforce-implementation-plan.md`.

### Agentforce → BFF actions (Phase 2)

Apex Invocables (`RLM_BambooAgent*`) call these BFF routes with
`callout=true`. Base URL = Custom Label `RLM_Bamboo_Get_Pricing_Bff_Url` +
Remote Site `BambooHR_Get_Pricing_BFF` (both updated by
`scripts/bamboohr/set_get_pricing_bff_url.py`). **Public HTTPS required** —
Apex cannot reach `127.0.0.1`.

| Action | BFF |
|--------|-----|
| Estimate Get Pricing | `POST /api/get-pricing-estimate` |
| Create Get Pricing Quote | `POST /api/get-pricing` |
| Get Licenses Summary | `GET /api/account-console` |
| Estimate Amend | `POST /api/account-amend-estimate` |
| Generate Or Update Amend Quote | `POST /api/account-amend-preview` + cache |

Checklist: `.agents/artifacts/bamboohr-agentforce-phase2-checklist.md`.

```bash
# Spot-check an Account (Rick Worldwide example)
curl -sS 'http://127.0.0.1:8765/api/account-console?company=Rick%20Worldwide' \
  | python -c 'import sys,json; d=json.load(sys.stdin); s=d["subscription"]; print(s["currentQuantity"], s["recurringMonthly"], len(s.get("timeline",{}).get("periods") or []))'
```

**Pay Now org bootstrap** (Guest Browsing + guest profile Reads; UI public-APIs toggle stays manual — see PAYNOW.md):

```bash
~/.local/pipx/venvs/cumulusci/bin/python \
  scripts/bamboohr/get_pricing/bootstrap_paynow.py --org master-demo --execute --check
```

**Pay Now smoke** (readiness; add `--create-link` to reuse/create a PaymentLink):

```bash
~/.local/pipx/venvs/cumulusci/bin/python \
  scripts/bamboohr/get_pricing/paynow_smoke.py --org master-demo --create-link
```

**Demo cleanup** (Quotes / Orders / Assets — not catalog pricing):

```bash
# Dry-run (default)
~/.local/pipx/venvs/cumulusci/bin/python \
  scripts/bamboohr/get_pricing/cleanup_demo_data.py --org master-demo \
  --preset northwind

# Apply
~/.local/pipx/venvs/cumulusci/bin/python \
  scripts/bamboohr/get_pricing/cleanup_demo_data.py --org master-demo \
  --preset northwind --execute --delete-opps

# Ephemeral buyer Accounts (allowlist + 24h age gate; dry-run)
~/.local/pipx/venvs/cumulusci/bin/python \
  scripts/bamboohr/get_pricing/cleanup_demo_data.py --org master-demo \
  --preset ephemeral --min-age-hours 24
```

Qty amends use ASP quantity on the effective start date (bumped to the latest
`AssetStatePeriod` when needed) so **decreases** validate. Live plan/qty is
today's ASP with qty &gt; 0 — a future Pro at qty 0 is scheduled, not current.
After a future Core→Pro swap (both qty 0 until the start date), Licenses
shows Pro as the upcoming plan, not Core.
Seat changes amend only assets with qty &gt; 0 on that date (never Core and Pro
together). No covering ASP that day is qty 0, not `AssetAction.TotalQuantity`.
Preview tags Draft amendment Quotes with `[bamboohr-preview]` and discards
leftovers before the next preview / after activate.

Amend volume + Path B: BFF stamps `RLM_Bamboo_Amend_Volume__c` +
`RLM_Amend_Volume_Qty__c`, resolves Path B from Account Assets ∪ Quote lines
(module Quotes often omit the plan SKU), stamps
`RLM_Bamboo_PathB_BundleSave__c`, System-reprices, and verifies **Bundle & Save
→ volume** nets (Force + combined `Discount` fallback). Needed because the
Path B overlay skips `LastTransaction` amend lines and Apex Path B sync is
Quote-line-only.

Presets: `northwind`, `seeded` (Acme / Prestige / BambooHR UK Demo), `get-pricing` (both).

DocGen defaults to Active `RLM_Bamboo_QuoteProposal` (Bamboo-branded `.docx` in
`assets/`, same ODTs as Foundations `RLM_QuoteProposal`). Override with
`DOCGEN_TEMPLATE_NAME` or API `templateName`. Quote summary **Download PDF**
triggers generation then download.

## Smokes (no browser)

```bash
~/.local/pipx/venvs/cumulusci/bin/python \
  scripts/bamboohr/get_pricing_smoke.py --target-org master-demo

~/.local/pipx/venvs/cumulusci/bin/python \
  scripts/bamboohr/checkout_p3_smoke.py --target-org master-demo

~/.local/pipx/venvs/cumulusci/bin/python \
  scripts/bamboohr/docgen_pdf_smoke.py --target-org master-demo \
  --out /tmp/bamboo-quote.pdf
```

## Experience Cloud shell

Lightning / Experience Builder LWC that opens this BFF — see
**[EXPERIENCE_CLOUD.md](./EXPERIENCE_CLOUD.md)**.

## Still deferred

- Browser-held guest Connected App (secrets stay server-side by design)
- Dedicated Customer Digital Experience site metadata (use Builder + LWC today)
