# BambooHR Get Pricing + Checkout (dual-channel P2/P3)

Local thin BFF + branded form for the self-serve “Get Pricing” path (fork-only).

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

## Run

Use the **CumulusCI pipx Python** (plain `python` usually lacks `cumulusci`):

```bash
# from repo root — note the space in --port 8765
~/.local/pipx/venvs/cumulusci/bin/python \
  scripts/bamboohr/get_pricing/server.py --org master-demo --port 8765
```

Then open http://127.0.0.1:8765/ in a browser (do not paste the `# open …` comment into the shell).

### API

| Method | Path | Body |
|--------|------|------|
| POST | `/api/get-pricing` | `{ headcount, country, planSku, addonSkus?, placeQuote? }` |
| POST | `/api/checkout` | `{ quoteId, amendQty?, pollTimeout? }` |

## Smokes (no browser)

```bash
~/.local/pipx/venvs/cumulusci/bin/python \
  scripts/bamboohr/get_pricing_smoke.py --target-org master-demo

~/.local/pipx/venvs/cumulusci/bin/python \
  scripts/bamboohr/checkout_p3_smoke.py --target-org master-demo
```

## Out of scope

- Guest Connected App in the browser
- Experience Cloud site hosting
- DocGen PDF binary (print-to-PDF is the stand-in)
