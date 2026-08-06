# BambooHR Get Pricing + Checkout (dual-channel P2/P3)

Thin BFF + branded form for the self-serve “Get Pricing” path (fork-only).
Runs **locally** (CCI) or **hosted** (public URL via tunnel / JWT Connected App).
See **[HOSTED.md](./HOSTED.md)** for public demos.

## Flow

1. User enters **headcount**, **country** (US/CA), **plan**, and optional
   **add-ons** (Payroll / Benefits / Time / Global).
2. BFF places a multi-line Quote, System-reprices (volume + Path B Bundle & Save
   when plan + Payroll + Benefits). Canada strips Payroll/Benefits.
3. Browser shows a branded summary with line table (print → PDF). Cart = Quote Id.
4. **P3:** “Place order (checkout)” → order → activate → assets; optional
   `amendQty` true-up through Upsells.

| Country | Demo Account |
|---------|----------------|
| US | Acme |
| CA | Prestige Worldwide (Payroll/Benefits disqual) |

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
| POST | `/api/get-pricing` | `{ headcount, country, planSku, addonSkus?, placeQuote? }` |
| POST | `/api/checkout` | `{ quoteId, amendQty?, pollTimeout? }` |
| POST | `/api/docgen-pdf` | `{ quoteId, templateName?, title?, timeout? }` → `downloadUrl` |
| GET | `/api/docgen-pdf/<contentVersionId>` | PDF bytes (attachment) |

DocGen uses Active `RLM_QuoteProposal` (override with `DOCGEN_TEMPLATE_NAME` or
`templateName`). Quote summary **Download PDF** triggers generation then download.

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

## Still deferred

- Experience Cloud site shell (can embed/redirect to this BFF)
- Browser-held guest Connected App (secrets stay server-side by design)
- Bamboo-branded custom `.docx` (today uses Foundations `RLM_QuoteProposal`)
