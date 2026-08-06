---
release_version: 262
release_name: "Summer '26"
area: "BambooHR Release Pack"
document_version: 0.1
status: draft
last_updated: 2026-08-06
purpose: SE/studio capture script for hands-on runtime clips
companion: docs/enablement/262/bamboohr-hands-on.md
---

# BambooHR hands-on — recording runbook

Use this to capture the **Configuration and Runtime** clips for [`bamboohr-hands-on.md`](bamboohr-hands-on.md). Record in 1080p; one take per clip; pause 1s on each checkpoint.

**Org:** `master-demo` · **BFF:** http://127.0.0.1:8765/ · **Price book:** Standard

After each clip is uploaded, paste the URL into the matching feature’s **Configuration and Runtime Video** section in the hands-on doc (or the clip map below).

---

## Pre-flight (5 min)

1. BFF healthy:

```bash
set -a; source scripts/bamboohr/get_pricing/.env; set +a
~/.local/pipx/venvs/cumulusci/bin/python -u \
  scripts/bamboohr/get_pricing/server.py --host 127.0.0.1 --port 8765 --cors-origin '*'
curl -sS http://127.0.0.1:8765/api/health
```

2. Salesforce: logged in as AE on `master-demo`, Lightning, wide browser window.
3. Optional smoke: `python scripts/bamboohr/get_pricing_smoke.py --target-org master-demo`
4. Close notifications / hide bookmarks bar.

---

## Clip map (paste URLs when done)

| Clip ID | Title | Features | Duration | URL |
|---------|-------|----------|----------|-----|
| C1 | AE catalog → volume → Workforce | 1, 2, 4 | ~4–5 min | `[NEEDS URL]` |
| C2 | Nonprofit + further Discount % | 6 | ~2–3 min | `[NEEDS URL]` |
| C3 | CA add-on disqual vs Acme | 7 | ~2 min | `[NEEDS URL]` |
| C4 | Get Pricing flat → Path B → PDF → checkout | 3, 8 | ~5–6 min | `[NEEDS URL]` |
| C5 | Free trial + convert preview | 9 | ~3 min | `[NEEDS URL]` |
| C6 | UK (or CA) multi-currency checkout | 10 | ~3 min | `[NEEDS URL]` |

**Minimum viable set for partners:** C1 + C4 (+ C2 if nonprofit is in the talk track).

---

## C1 — AE catalog → volume coach → Workforce (~5 min)

**Talk track:** “Same public catalog in Revenue Cloud — PEPM headcount, volume coach, Workforce Bundle & Save.”

| # | Action | On screen (expect) |
|---|--------|--------------------|
| 1 | App Launcher → Quote / Revenue app | — |
| 2 | New Quote on **Acme**, Standard PB | Account Acme |
| 3 | Browse / search `Bamboo` | Plans, Add-ons, Packages |
| 4 | Add **BambooHR Pro**, qty **10**, price | List **$17**; below volume |
| 5 | Open line side panel / Volume Tier Coach | Below first band |
| 6 | Qty → **50**, reprice | Net ≈ **$16.15**; coach 5% band |
| 7 | Clear / new quote → add **Workforce Package** | Configurator |
| 8 | Plan **Pro**; Payroll + Benefits required; package qty **25** | Children qty 25 |
| 9 | Price / Calculation Details on Payroll | **15% Bundle & Save** (BBA) |

**End freeze:** Calculation Details or line net showing Bundle & Save.

---

## C2 — Nonprofit + further discount (~3 min)

**Talk track:** “Nonprofit is an Account flag — 15% list starting point; AE can still discount further.”

| # | Action | On screen (expect) |
|---|--------|--------------------|
| 1 | Open Account **BambooHR Nonprofit Demo** | Nonprofit flag true |
| 2 | New Quote → add **Core** qty **1** | List **$10**, UnitPrice **$8.50** |
| 3 | Calculation Details | **BambooHR Nonprofit 15% List Discount** |
| 4 | Set line **Discount (%)** = **10**, reprice | UnitPrice **$8.50**, NetUnitPrice **$7.65** |

**End freeze:** NetUnitPrice 7.65 with Discount 10.

---

## C3 — CA disqual (~2 min)

**Talk track:** “Payroll and Benefits are US-only via category disqualification.”

| # | Action | On screen (expect) |
|---|--------|--------------------|
| 1 | New Quote on **Prestige Worldwide** (CA) | — |
| 2 | Browse Add-ons / search Bamboo | Payroll & Benefits **hidden** |
| 3 | Switch / second quote on **Acme** (US) | Payroll & Benefits **visible** |

**End freeze:** side-by-side or quick cut Acme vs Prestige browse.

---

## C4 — Get Pricing dual channel (~6 min)

**Talk track:** “Buyer form over the same RC APIs — flat small-biz, Path B, PDF, checkout.”

| # | Action | On screen (expect) |
|---|--------|--------------------|
| 1 | Open http://127.0.0.1:8765/ | Get Pricing form |
| 2 | Headcount **25**, Core, US → Get pricing | Flat SKU, monthly **$250** |
| 3 | Reset → Pro, headcount **50**, Payroll + Benefits, US | Path B note |
| 4 | Get pricing | Plan ≈ $16.15; Payroll ≈ $6.46; Benefits ≈ $4.845 |
| 5 | **Download PDF** | DocGen opens / downloads |
| 6 | **Place order** (checkout) | Order activated; assets |

**End freeze:** success / order confirmation or asset count.

---

## C5 — Free trial convert-later (~3 min)

**Talk track:** “Thirty days at $0; convert later with the same configuration.”

| # | Action | On screen (expect) |
|---|--------|--------------------|
| 1 | Get Pricing → check **Start with 30-day free trial** | — |
| 2 | US · Pro · **50** (+ optional add-ons) → Get pricing | Nets **$0.00**; trial banner |
| 3 | Scroll **If converted — your cost** | Paid estimate table |
| 4 | Open Quote in Salesforce | `RLM_Bamboo_FreeTrial__c`; EndDate ≈ +30d |
| 5 | **Convert to paid pricing** | New paid quote, trial off |

**End freeze:** paid quote summary vs trial $0.

---

## C6 — Multi-currency UK (~3 min)

**Talk track:** “Native GBP — not corporate USD stamped on the lines.”

| # | Action | On screen (expect) |
|---|--------|--------------------|
| 1 | Get Pricing country **UK**, Pro @ **25** | GBP nets (≈ £12.76) |
| 2 | Checkout | Order **GBP**, Activated |
| 3 | Optional: Account → Renewal Forecast Opportunity | Currency **GBP** |

**End freeze:** Order currency GBP + line net.

---

## After capture

1. Upload clips (Drive / Slack / Loom — team convention).
2. Fill the **Clip map** URL column above.
3. Copy each URL into `bamboohr-hands-on.md` under the matching features’ **Configuration and Runtime Video** sections.
4. Bump hands-on `document_version` / note recordings complete; set status → `review` when ready.
