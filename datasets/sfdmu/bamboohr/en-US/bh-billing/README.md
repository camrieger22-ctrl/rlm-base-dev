# bh-billing Data Plan

Assigns **`Billing Policy - Advance`** to BambooHR sellable products so
12‑month Term Monthly deals invoice **monthly PEPM × seats**, not the full
term Order amount in one shot.

Requires:

1. `qb-billing` (or equivalent) already loaded — `Billing Policy - Advance` must exist
2. `insert_bamboohr_pcm_data` already run — products must exist

## CCI

| Task | Description |
|------|-------------|
| `insert_bamboohr_billing_data` | Product2 Update: `BillingPolicy.Name` → Bamboo SKUs |

```bash
cci task run insert_bamboohr_billing_data --org <alias>
```

Run after `insert_bamboohr_pcm_data` and after billing policies are active.

## Objects

| # | Object | Operation | External ID | Records |
|---|--------|-----------|-------------|---------|
| 1 | BillingPolicy | Readonly | `Name` | 1 |
| 2 | Product2 | Update | `StockKeepingUnit` | 10 |

## SKUs

`BAMBOO-CORE`, `BAMBOO-CORE-FLAT-SM`, `BAMBOO-PRO`, `BAMBOO-ELITE`,
add-ons, Workforce package, and legacy `BAMBOO-SUITE` (if still present).
