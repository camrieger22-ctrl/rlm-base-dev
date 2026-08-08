# BambooHR Get Pricing + Checkout (dual-channel P2/P3)

Thin BFF + branded form for the self-serve “Get Pricing” path (fork-only).
Runs **locally** (CCI) or **hosted** (public URL via tunnel / JWT Connected App).
See **[HOSTED.md](./HOSTED.md)** for public demos, **[EXPERIENCE_CLOUD.md](./EXPERIENCE_CLOUD.md)**
for the EC shell, and **[PAYNOW.md](./PAYNOW.md)** for Salesforce Payments /
Pay Now (checkout + Licenses weave-in plan).

## Flow

1. User enters **company + work email** (Get Pricing hero), **headcount**,
   **country**, **plan**, and optional **add-ons**.
2. Configurator changes call **`/api/get-pricing-preview`**: **one Opportunity +
   one sticky Draft Quote** per Account. Lines mutate via PST place (`DELETE` +
   `POST`) then System reprice. The server also looks up the Account’s existing
   preview Draft (so overlapping clicks don’t spawn more Opps/Quotes). Recreate
   is only a fallback if PST replace fails.
3. BFF **creates Account + Contact** in Salesforce when the buyer is submitted
   (or reuses Contact email / Account name). Preview may already sit on that
   Account if company + email were present during configure.
4. **Get your quote** promotes the sticky Quote when Account + config match
   (`previewQuoteId`); otherwise places a fresh Quote and discards the preview.
5. Browser shows a branded summary (customer card + list→bundle→volume table).
6. **P3:** “Place order” → order → activate → assets; optional `amendQty`.

| Country | Fallback demo Account (no buyer) |
|---------|-----------------------------------|
| US | Acme |
| CA | Prestige Worldwide (Payroll/Benefits disqual) |
| UK | BambooHR UK Demo |

## Run (local)

Use the **CumulusCI pipx Python** (plain `python` usually lacks `cumulusci`):

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
| GET | `/api/catalog?country=US\|CA\|UK` | Curated SKUs → org PBE list PEPM / names / availability |
| GET | `/api/account-console?accountId=\|company=\|ecToken=` | Licenses & billing (demo pin or EC HMAC handoff); includes open `invoices` |
| GET | `/api/account-invoices?accountId=\|company=\|ecToken=` | Posted invoices with balance &gt; 0 (+ Active Pay Now URL when present) |
| GET | `/api/ec-handoff?token=` | Verify EC handoff → `{ accountId, contactId, exp }` |
| POST | `/api/create-login` | `{ accountId, contactId?, email, password }` → community User + `ecToken` handoff |
| POST | `/api/account-amend-preview` | `{ accountId, newQty?, addonSkus?, startDate?, amendQuotes?, moduleQuoteId? }` → sticky Draft Quotes + System reprice (no Activate); live UI debounce reuses Quotes |
| POST | `/api/account-amend` | `{ accountId, newQty?, addonSkus?, amendQuotes?, moduleQuoteId? }` → activate preview Quotes → Order (native createOrderFromQuote) |
| POST | `/api/get-pricing-preview` | Sticky Draft Quote + System reprice for configurator (plan/tier/add-ons). Pass `quoteId` to reuse. |
| POST | `/api/get-pricing` | `{ headcount, country, planSku, addonSkus?, placeQuote?, previewQuoteId? }` — promotes sticky preview when Account+config match |
| POST | `/api/collect-payment` | `{ orderId? \| invoiceId?, pollTimeout?, emailPayment?, toEmail? }` — invoice + PaymentLink; optional Pay Now email |
| POST | `/api/payment-email` | `{ paymentUrl? \| invoiceId? \| orderId?, toEmail?, accountId? }` — email Pay Now link via Apex |
| POST | `/api/checkout` | `{ quoteId, amendQty?, pollTimeout?, collectPayment?, emailPayment?, toEmail? }` — after activate, invoices the order and attempts Salesforce Payments Pay Now (`payment` on response; optional email) |
| POST | `/api/docgen-pdf` | `{ quoteId, templateName?, title?, timeout? }` → `downloadUrl` |
| GET | `/api/docgen-pdf/<contentVersionId>` | PDF bytes (attachment) |
| POST | `/api/quote-email` | `{ quoteId, toEmail?, attachPdf? }` → Salesforce sends quote email (+ DocGen PDF) |

**Licenses & billing UI:** `/account` — subscription, open invoices (Pay Now),
recent orders, qty amend preview/place.
Demo pin via Account Id / company name; buyer path via Experience Cloud login →
signed `ecToken` (see `EXPERIENCE_CLOUD.md`). Open **Pay** in a private window
if you’re also logged into Salesforce (guest Pay Now + admin cookies conflict).

Pay Now weave-in plan / phases: **[PAYNOW.md](./PAYNOW.md)**.

**Public / EC URL:** keep BFF running, then
`./scripts/bamboohr/get_pricing/run_tunnel.sh` (syncs Custom Label). Stable host:
HOSTED.md Path C (`publish_bff.py --named`).

**Licenses recurring totals** come from Salesforce ``Asset.CurrentMrr`` /
``CurrentQuantity`` (ASP fallback) — not a local catalog re-price. Amend
“after” amounts still use Revenue Cloud System reprice preview.

**Upcoming changes** on `/account` come from ``AssetStatePeriod`` (account-level
date ranges with seats + MRR). Draft Place-order math is never mixed into that
timeline.

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
`AssetStatePeriod` when needed) so **decreases** validate. Preview tags Draft
amendment Quotes with `[bamboohr-preview]` and discards leftovers before the
next preview / after activate.

Amend volume: BFF stamps `RLM_Bamboo_Amend_Volume__c` +
`RLM_Amend_Volume_Qty__c`, System-reprices (overlay
`ApplyBambooHRAmendVolumeDiscount`), and falls back to Force+`Discount` when
Net still misses the schedule tier.

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
