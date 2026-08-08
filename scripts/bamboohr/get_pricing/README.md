# BambooHR Get Pricing + Checkout (dual-channel P2/P3)

Thin BFF + branded form for the self-serve “Get Pricing” path (fork-only).
Runs **locally** (CCI) or **hosted** (public URL via tunnel / JWT Connected App).
See **[HOSTED.md](./HOSTED.md)** for public demos, **[EXPERIENCE_CLOUD.md](./EXPERIENCE_CLOUD.md)**
for the EC shell, and **[PAYNOW.md](./PAYNOW.md)** for Salesforce Payments /
Pay Now (checkout + Licenses weave-in plan).

## Flow

1. User enters **company + work email** (Get Pricing hero), **headcount**,
   **country**, **plan**, and optional **add-ons**.
2. BFF **creates Account + Contact** in Salesforce (or reuses Contact email /
   Account name). API callers that omit buyer still use seeded demo Accounts.
3. BFF places a multi-line Quote on that Account, System-reprices (volume +
   Path B Bundle & Save when plan + Payroll + Benefits). Canada/UK strip
   US-only add-ons.
4. Browser shows a branded summary (customer card + list→bundle→volume table).
5. **P3:** “Place order” → order → activate → assets; optional `amendQty`.

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
| POST | `/api/account-amend-preview` | `{ accountId, newQty?, addonSkus?, startDate? }` → draft Quotes + System reprice totals (no Activate) |
| POST | `/api/account-amend` | `{ accountId, newQty?, addonSkus?, amendQuotes?, moduleQuoteId? }` → activate preview Quotes (or create if omitted) |
| POST | `/api/get-pricing` | `{ headcount, country, planSku, addonSkus?, placeQuote? }` |
| POST | `/api/checkout` | `{ quoteId, amendQty?, pollTimeout?, collectPayment? }` — after activate, invoices the order and attempts Salesforce Payments Pay Now (`payment` on response) |
| GET | `/api/payments-readiness` | Merchant / webhook probe for Pay Now |
| POST | `/api/collect-payment` | `{ orderId? \| invoiceId?, pollTimeout? }` — invoice + PaymentLink (order path generates; invoice path reuses/creates link) |
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
