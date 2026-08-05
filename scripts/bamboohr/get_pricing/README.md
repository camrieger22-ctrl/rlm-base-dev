# BambooHR Get Pricing (dual-channel P2)

Local thin BFF + branded form for the self-serve “Get Pricing” path (fork-only).

## Flow

1. User enters **headcount**, **country** (US/CA), and **plan**.
2. BFF (CCI org OAuth) discovers the Bamboo catalog, places a Quote on the
   mapped demo Account, and headless-prices volume PEPM.
3. Browser shows a branded summary (print → PDF). Cart = Salesforce Quote Id.

| Country | Demo Account |
|---------|----------------|
| US | Acme |
| CA | Prestige Worldwide (Payroll/Benefits disqualified) |

## Run

```bash
# from repo root — needs CCI auth to master-demo
python scripts/bamboohr/get_pricing/server.py --org master-demo --port 8765
# open http://127.0.0.1:8765/
```

## Smoke (no browser)

```bash
python scripts/bamboohr/get_pricing_smoke.py --target-org master-demo
```

## Out of scope (later / P3)

- Guest Connected App in the browser
- Experience Cloud site hosting
- DocGen PDF binary (print-to-PDF is the P2 stand-in)
- Place Order / checkout
