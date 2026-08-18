# Salesforce Pay Now — BambooHR self-service

Weave **invoice Pay Now** into the Get Pricing / Licenses BFF (fork demo).
Card entry stays on the Salesforce **Pay Now** Experience site; the BFF only
creates invoices / Payment Links and shows branded CTAs.

Related: [README.md](./README.md) · [HOSTED.md](./HOSTED.md) ·
[EXPERIENCE_CLOUD.md](./EXPERIENCE_CLOUD.md)

**Status:** Phases 0–6 shipped (Phase 5: Pay Now email + EC invoices focus)  
**Scope:** This BFF only — not Foundations product packaging.

---

## Goal

After any self-serve path that creates a billable Order, the buyer can **pay
the posted Invoice** via Salesforce Payments Pay Now, without leaving the
BambooHR-branded journey except for the hosted Pay Now tab.

**Non-goals**

- Embedding Stripe Elements inside the BFF
- Replacing Billing invoice generation with a custom charge
- Assigning Payments External PSLs to Experience Guest (not license-compatible)
- Live-mode merchant / production KYC

---

## Architecture

```
┌─────────────────────────────┐     invoice + PaymentLink      ┌──────────────────────┐
│ BambooHR BFF (branded UI)   │ ─────────────────────────────► │ Salesforce Billing   │
│ Get Pricing /quote          │                                 │ + Payments merchant  │
│ Licenses /account           │ ◄── payment { paymentUrl } ──── │ Pay Now LWR site     │
│ EC shell → opens BFF        │                                 │ /paynow/pay?...      │
└─────────────────────────────┘     target=_blank (guest)       └──────────────────────┘
```

| Layer | Owns |
|-------|------|
| BFF | When to invoice, create/reuse PaymentLink, show CTA, return URLs |
| Pay Now site | Guest checkout UI, Stripe card entry, authorization |
| Stripe (test) | Charge simulation |
| Billing | Invoice balance / apply payment (platform) |

**Demo rule:** Open Pay Now in a context **without** an admin/org session
cookie (incognito or a logged-out browser profile). An authenticated Salesforce
session on the same domain often breaks the guest pay page.

**Stripe test card:** `4242 4242 4242 4242` (any future expiry / CVC / ZIP).

---

## Current state

### Org (`master-demo` — verified)

- Stripe merchant Complete / Enabled (Test)
- Pay Now site Live + public guest routes
- Guest public APIs enabled on vanity `/paynow`
- Guest profile Read on WebStore (+ catalog / category / product / …)
- `WebStore.OptionsGuestBrowsingEnabled = true`
- Payment Method Set `Default_Card`
- Guest Pay Now + test charge succeeded end-to-end

### BFF (code)

| Piece | Location |
|-------|----------|
| Invoice + PaymentLink after activate | `payments.py` → `build_payment_prompt` |
| Checkout (`collectPayment` default true) | `checkout.py` |
| APIs | `GET /api/payments-readiness`, `POST /api/collect-payment`, checkout `payment` |
| Quote success **Pay now** card | `static/quote.html` |

### Gaps

| Gap | Impact |
|-----|--------|
| Invoice balance may lag after authorize | UI may still show balance until apply settles |
| PaymentLink has no return/redirect field | Buyer returns via email “View licenses” / EC deep-link (`paid=1`) — not auto-redirect from Pay Now |

### Shipped (Phases 0–6)

- `bootstrap_paynow.py` — Guest Browsing + Pay Now Profile commerce Reads
- Richer `GET /api/payments-readiness` → `readyForPayNow`, `checks`, `blocking`, guest probes
- `paynow_smoke.py` — readiness + optional `--create-link`
- `RLM_BambooPayNowEmail` + `POST /api/payment-email` (+ optional `emailPayment` on checkout/collect)
- EC / create-login handoff → `/account?…&focus=invoices`; `/account?paid=1` return banner
- PaymentLink describe: **no** Success/Return URL field — platform thank-you only

- `list_open_invoices` / `build_payment_prompt_for_invoice` (+ Active link reuse)
- `GET /api/account-invoices`, `collect-payment` accepts `invoiceId`
- `/account` **Invoices** section with **Pay** + refresh + incognito hint
- Account console payload includes `invoices[]`
- Amend / add-module activate returns `payment` + success **Pay now** card
- Shared `static/pay-now.js` for quote + amend cards; buyer hides Lightning invoice link unless `?demo=1`; **Retry pay** via `collect-payment`

---

## Phased delivery

### Phase 0 — Org bootstrap ✅

**Outcome:** Rebuild orgs get a working guest Pay Now path without tribal knowledge.

| # | Work | Status |
|---|------|--------|
| 0.1 | Setup checklist (below) | Done |
| 0.2 | `bootstrap_paynow.py` | Done — Guest Browsing + guest ObjectPermissions Reads |
| 0.3 | UI-only steps documented | Done — guest public APIs stay manual |
| 0.4 | Richer readiness | Done — `readyForPayNow` + guest `session-context` / `payment-link-configs` |

**Exit:** readiness returns `readyForPayNow: true` (or concrete failing checks).

```bash
# Dry-run, then apply + readiness
~/.local/pipx/venvs/cumulusci/bin/python \
  scripts/bamboohr/get_pricing/bootstrap_paynow.py --org master-demo
~/.local/pipx/venvs/cumulusci/bin/python \
  scripts/bamboohr/get_pricing/bootstrap_paynow.py --org master-demo \
  --execute --check
```

#### Setup checklist (manual / SE)

1. Salesforce Payments → Stripe merchant (Test) → Complete / payments Enabled  
2. Create / publish **Pay Now** Experience site; set **Pay Now site URL** in Payments setup  
3. Payment Method Set with **Card** on the merchant  
4. Site **Administration → Preferences** → allow guest users to access public APIs (**UI-only** — not flipped by bootstrap)  
5. Enable **Guest Browsing** on the Pay Now WebStore → `bootstrap_paynow.py --execute`  
6. Guest profile: Read on WebStore (+ catalog / category / product / …) → same script  

Prefer a **runtime guest API probe** over trusting `Site.OptionsAllowGuestPaymentsApi`
in SOQL (that field can lag or only reflect one Site record).

#### Brand the Pay Now site (Experience Builder Theme)

Card entry stays on the Salesforce Pay Now LWR page (do **not** iframe Stripe into
the BFF). You can still make that tab feel BambooHR by theming the site chrome —
logo, brand colors, fonts — so it matches Get Pricing / Licenses.

**Tokens** (same as `static/app.css`):

| Role | Hex | Notes |
|------|-----|--------|
| Brand / primary CTA | `#73C41D` | Lima |
| Accent / links / hover | `#2D7919` | Bilbao |
| Body text | `#1A1C1E` | Ink |
| Muted / secondary text | `#55575A` | Abbey |
| Page / surface background | `#F7FBF2` or `#FFFFFF` | Soft leaf wash → white |
| Soft highlight | `#EEF8E3` | Leaf wash |
| Borders | `#E3E5E8` | Line |

**Logo assets** (repo):

- Light chrome: `scripts/bamboohr/get_pricing/static/brand/wordmark-green.png`
- Dark chrome (if header is Bilbao): `…/wordmark-white.png`
- Favicon / small: `…/icon.png`

**`master-demo` site**

| Field | Value |
|-------|--------|
| Network | **Pay Now** (`0DBgL0000028O7FWAU`) |
| Status | Live |
| Path prefix | `paynowvforcesite` (vanity `/paynow` if configured) |
| Builder | Setup → Digital Experiences → All Sites → **Pay Now** → **Builder** |

Direct Builder URL (admin session on `master-demo`):

`https://trailsignup-b4759183862b2b.my.salesforce.com/sfsites/picasso/core/config/commeditor.jsp?orgId=00DgL00000XnZrG&siteId=0DBgL0000028O7F`

**Theme panel steps**

1. Open **Builder** for the **Pay Now** site (not Payments Webhook).
2. Left rail → **Theme** (paintbrush) → open the active theme (or **Clone** the
   default first so you keep a rollback).
3. **Images**
   - **Company Logo** / header logo → upload `wordmark-green.png`.
   - Optional favicon → `icon.png`.
   - Leave hero / large background images empty unless the template exposes them;
     Pay Now is a form page, not a marketing landing.
4. **Colors** (names vary slightly by LWR theme; map by role):
   - Brand / Primary → `#73C41D`
   - Brand / Primary Contrast (text on brand buttons) → `#FFFFFF`
   - Accent / Link → `#2D7919`
   - Text / Heading → `#1A1C1E`
   - Text / Detail or Secondary → `#55575A`
   - Background / Page → `#F7FBF2` (or `#FFFFFF` if the theme looks muddy)
   - Card / Surface → `#FFFFFF`
   - Border / Divider → `#E3E5E8` if exposed
5. **Fonts** (optional): pick a clean sans close to the BFF. Exact webfont matching
   is not required for demo.
6. **Preview** as **Guest User** (Builder preview → Guest). Confirm logo + green
   chrome; Stripe / card fields will still look like Salesforce Payments — that is
   expected.
7. **Publish** the site. Theme edits are not live until publish.
8. Smoke: from BFF **Pay now** → open link in **incognito** → confirm branded header
   and successful `4242…` test charge.

**What Theme will not change**

- Stripe Elements / card iframe chrome inside the Payments component
- BFF pages (`/quote`, `/account`) — already BambooHR-styled in `static/`
- Email body beyond what `RLM_BambooPayNowEmail` already sends

**After org rebuild:** re-upload logo and re-apply colors (Theme is not covered by
`bootstrap_paynow.py`).

---

### Phase 1 — Shared payment prompt (BFF)

**Outcome:** One payload and helpers for every surface.

| # | Work | Detail |
|---|------|--------|
| 1.1 | Freeze `PaymentPrompt.as_dict()` | `ready`, ids, balances, `paymentUrl`, `blockedReason`, `warnings` |
| 1.2 | `list_open_invoices(accountId)` | Posted invoices with `Balance > 0` |
| 1.3 | `payment_prompt_for_invoice(invoiceId)` | Link by billing account + balance (Order optional) |
| 1.4 | Idempotency | Reuse Active PaymentLink when possible; else SingleUse create |
| 1.5 | Post-pay helper | Per-invoice `paidApplying` when a **Processed Payment** amount matches that bill (leftover invoices stay payable). Disabled PaymentLink alone is not enough. |

**API**

| Method | Path | Notes |
|--------|------|--------|
| GET | `/api/account-invoices?accountId=` | Open invoices (+ optional Active URLs) |
| POST | `/api/collect-payment` | Accept `invoiceId` **or** `orderId` |
| GET | `/api/payments-readiness` | `readyForPayNow`, `checks`, `blocking`, guest probes |

---

### Phase 2 — Checkout polish (quote success)

| # | Work |
|---|------|
| 2.1 | Shared pay-now card markup/JS for quote + account |
| 2.2 | Primary **Pay now**; hide Lightning invoice link for buyers (SE / `?demo=1` only) |
| 2.3 | One-line incognito hint near Pay now |
| 2.4 | Retry pay via `collect-payment` without re-checkout |

---

### Phase 3 — Licenses & billing (`/account`) — primary remaining work

| # | Work |
|---|------|
| 3.1 | Console payload includes `invoices[]` |
| 3.2 | **Invoices** section: number, balance, status, **Pay** |
| 3.3 | Pay → `POST /api/collect-payment` `{ invoiceId }` → open URL in new tab |
| 3.4 | Empty / readiness-blocked states |
| 3.5 | Refresh after return from Pay Now |

Use the same `accountId` / `ecToken` auth as the rest of `/account`.

---

### Phase 4 — Amend / module pay prompt

After amend activate, call the payment prompt and reuse the pay-now card on
`#changeSuccess`. Skip CTA when invoice balance is $0.

---

### Phase 5 — Notify & Experience Cloud ✅

- Email `paymentUrl` via `RLM_BambooPayNowEmail` (Actions API) after checkout/collect when `emailPayment` / `toEmail`, or **Email pay link** CTA  
- EC handoff → `/account?ecToken=…&focus=invoices` (Apex + portal create-login)  
- Do **not** host Pay Now inside the BambooHR EC site — deep-link only  
- PaymentLink has **no** return/redirect field (describe on `master-demo`) — use BFF `/account?paid=1&focus=invoices` from email “View licenses” when `BFF_PUBLIC_URL` is set  

Deploy Apex before first email:

```bash
sf project deploy start \
  --source-dir unpackaged/post_bamboohr/classes/RLM_BambooPayNowEmail.cls \
  --source-dir unpackaged/post_bamboohr/classes/RLM_BambooPayNowEmailTest.cls \
  --source-dir unpackaged/post_bamboohr/classes/RLM_BambooEcIdentity.cls \
  --source-dir unpackaged/post_bamboohr/permissionsets/RLM_BambooHR.permissionset-meta.xml \
  --target-org master-demo
```

---

### Phase 6 — Docs & smoke ✅

- Keep this file + README API table in sync  
- Smoke: `paynow_smoke.py` — readiness + optional `--create-link`  
- Live Stripe charge remains manual (incognito + `4242…`)  
- Cleanup: leave unused Active SingleUse links; don’t casually delete Payment history  

```bash
~/.local/pipx/venvs/cumulusci/bin/python \
  scripts/bamboohr/get_pricing/paynow_smoke.py --org master-demo --create-link
```

---

## Build order

```
Phase 0 (org bootstrap + readiness)     parallel with SE Setup
Phase 1 (API: invoices + invoiceId)     foundation
Phase 3 (/account invoices UI)          highest buyer value
Phase 2 (quote polish + shared card)    alongside 3
Phase 4 (amend pay prompt)              after 1–3
Phase 5 (email / EC / return)           optional
Phase 6 (docs / smoke)                  continuous
```

**First mergeable slice:** Phase 1.2–1.3 + Phase 3.1–3.3.

---

## UX principles

1. Show Pay only when balance &gt; 0 and a URL exists (or a clear SE `blockedReason`).
2. New tab + `rel="noopener"` — never iframe Pay Now.
3. Don’t assume paid from click — use PaymentLink / Payment status.
4. Lightning invoice links are SE tooling; hide from default buyer UI.
5. Incognito callout once, muted, next to Pay now.

---

## Constraints (do not regress)

- Guest **cannot** take `PayNow_Shopper` / Payments External PSL — public Payments APIs + guest browsing + object Reads.
- Prefer **Test** merchant mode for demo orgs.
- Payment links are **SingleUse**; after pay expect Status **Disabled**.
- Never commit Stripe secrets; publishable key comes from Payments at runtime.
- Without WebStore Read + Guest Browsing, the pay page contact form stays on stencils / “access to stores”.

---

## Verification

- [x] `GET /api/payments-readiness` / `paynow_smoke.py` → `readyForPayNow`  
- [x] Guest `payment-link-configs/{id}?asGuest=true` → 200 (readiness probe)  
- [x] Guest `session-context?asGuest=true` → 200 (readiness probe)  
- [x] Checkout → Pay now → Stripe `4242…` → thank-you confirmation (manual / prior E2E)  
- [x] Payment **Processed**; PaymentLink **Disabled** (prior E2E)  
- [x] `/account` lists open invoice; Pay works in incognito  
- [x] Amend activate (balance &gt; 0) shows Pay now  
- [x] Admin cookie session documented as failure mode; incognito succeeds  

---

## Risks

| Risk | Mitigation |
|------|------------|
| Balance not zero right after authorize | “Payment received — balance may update”; refresh control |
| Guest public API toggle not automatable | Checklist + readiness fails loudly |
| Cart/session 400s on Pay Now page | Observed; checkout can still complete — don’t block on cart-items |
| Duplicate PaymentLinks | Reuse Active links (Phase 1.4) |
| Scratch / Trail org rebuild drift | `bootstrap_paynow.py` + readiness `blocking` |

---

## Decisions

| Decision | Default | Change only if… |
|----------|---------|-----------------|
| Host card UI | Salesforce Pay Now site | Product requires embedded Stripe |
| Collect on checkout | `collectPayment: true` | Demo wants activate-only |
| Account pay entry | By `invoiceId` | Billing is order-only in the org |
| Email link | Phase 5 optional | SE needs email-first demo |

---

## Code map

| File | Role |
|------|------|
| `payments.py` | Invoice generate, PaymentLink create, readiness, bootstrap helpers |
| `bootstrap_paynow.py` | CLI: Guest Browsing + guest ObjectPermissions |
| `payment_email.py` | Actions API → `RLM_BambooPayNowEmail` |
| `paynow_smoke.py` | Phase 6 smoke: readiness + optional link create |
| `RLM_BambooPayNowEmail.cls` | Org email with Pay Now URL + optional licenses deep-link |
| `checkout.py` | Post-activate `build_payment_prompt` |
| `account_console.py` | Account invoices payload + amend `payment` |
| `server.py` | `/api/checkout`, `/api/collect-payment`, `/api/account-invoices`, readiness |
| `static/quote.html` | Pay now success card (via `pay-now.js`) |
| `static/pay-now.js` | Shared Pay now render / Retry / demo invoice link |
| `static/account.html` / `account.js` | Invoices list + amend Pay now card |
