# Experience Cloud shell — BambooHR Get Pricing

Thin Salesforce Experience Cloud / Lightning page that **opens the hosted BFF**.
Revenue Cloud APIs stay on the BFF; the site is only branding + navigation.

## What’s in the repo

| Asset | Path |
|-------|------|
| LWC | `unpackaged/post_bamboohr/lwc/rlmBambooGetPricingShell` |
| Apex handoff | `RLM_BambooEcIdentity` (User → Contact → Account + HMAC token) |
| EC buyer PS | `RLM_BambooEcBuyer` (assign to community users) |
| App page | `unpackaged/post_bamboohr/flexipages/RLM_Bamboo_Get_Pricing` |
| Tab | `unpackaged/post_bamboohr/tabs/RLM_Bamboo_Get_Pricing` |
| BFF URL label | `RLM_Bamboo_Get_Pricing_Bff_Url` (default `http://127.0.0.1:8765`) |
| Handoff secret | `RLM_Bamboo_Ec_Handoff_Secret` ↔ BFF `EC_HANDOFF_SECRET` |
| Set URL script | `scripts/bamboohr/set_get_pricing_bff_url.py` |
| Provision user | `scripts/bamboohr/get_pricing/provision_ec_demo_user.py` |

## Deploy

```bash
cci task run deploy_post_bamboohr --org master-demo
cci task run assign_permission_sets --org master-demo -o api_names RLM_BambooHR
```

(Or `cci flow run prepare_bamboohr --org master-demo -o bamboohr True`.)

## Point at your public BFF

```bash
# Preferred: publish_bff.py starts the tunnel and syncs this label automatically
./scripts/bamboohr/get_pricing/run_tunnel.sh

# Or set manually:
~/.local/pipx/venvs/cumulusci/bin/python \
  scripts/bamboohr/set_get_pricing_bff_url.py --org master-demo \
  --url https://YOUR-SUBDOMAIN.trycloudflare.com
```

For a **stable** hostname (named Cloudflare Tunnel), see HOSTED.md Path C.

## Use inside Salesforce (SE path)

App Launcher → **BambooHR Get Pricing** (Lightning App Page).

## Use in Experience Cloud (buyer-facing URL)

Dedicated site on `master-demo` (do **not** put this on Partner `/partners`):

| Field | Value |
|-------|--------|
| Network | **BambooHR Get Pricing** (`Live`) |
| Path prefix | `bamboohr` |
| Public URL | https://trailsignup-b4759183862b2b.my.site.com/bamboohr/s/ |
| Home page | `c:rlmBambooGetPricingShell` (new-tab CTA → BFF) |

### Recreate / update via CLI

```bash
# Create (once)
sf community create --name "BambooHR Get Pricing" \
  --template-name "Build Your Own" --url-path-prefix bamboohr \
  --target-org master-demo

# After editing ExperienceBundle home view to host rlmBambooGetPricingShell:
sf project deploy start --source-dir <path-to>/experiences --target-org master-demo
sf community publish --name "BambooHR Get Pricing" --target-org master-demo
sf data update record --sobject Network --record-id <networkId> \
  --values "Status=Live" --target-org master-demo
```

### Builder (manual alternative)

1. **Digital Experiences** → **BambooHR Get Pricing** → **Builder**
2. Home already has the shell; or drag **BambooHR Get Pricing Shell**
3. Optional design properties:
   - **BFF base URL override** — temporary override without changing the label
   - **Auto-redirect on load** — skip the CTA
   - **Open BFF in a new tab** — default true
4. **Publish**

Guest users: home route is `pageAccess: Public`. Guests see **Sign in for
licenses** (no Apex). Authenticated Customer Community users with
`RLM_BambooEcBuyer` see **Manage licenses & billing**, which calls Apex to mint
a short-lived HMAC handoff and opens the BFF `/account?ecToken=…`. The BFF
verifies the token (`EC_HANDOFF_SECRET`) and loads that Account’s console.
Guests never receive a Salesforce token. Keep the BFF URL label pointed at a
live tunnel/host (`set_get_pricing_bff_url.py`).

## Returning customer login (5b)

```bash
# 1) Deploy Apex + PS + LWC, assign internal PS for SE Lightning testing
cci task run deploy_post_bamboohr --org master-demo
cci task run assign_permission_sets --org master-demo -o api_names RLM_BambooHR

# 2) BFF secret must match Custom Label RLM_Bamboo_Ec_Handoff_Secret
#    Add to scripts/bamboohr/get_pricing/.env:
#    EC_HANDOFF_SECRET='bh-ec-handoff-demo-master-2026'

# 3) Deploy custom community profile (preferred) + provision Northwind user
sf project deploy start --source-dir unpackaged/post_bamboohr/profiles \
  --target-org master-demo
set -a; source scripts/bamboohr/get_pricing/.env; set +a
~/.local/pipx/venvs/cumulusci/bin/python \
  scripts/bamboohr/get_pricing/provision_ec_demo_user.py --org master-demo
# Credentials → .agents/artifacts/bamboohr-ec-demo-login.md (private)

# 4) Experience Builder → Administration → Members:
#    allow "BambooHR Customer Login" (script adds NetworkMemberGroup when possible).
#    Publish if you change membership.
```

**Why a custom profile?** Creating users on the standard
`Customer Community Login User` profile requires Setup → Digital Experiences →
Settings → *Allow using standard external profiles…*. That org preference is not
reliably deployable via Metadata API here, so the repo ships
`BambooHR Customer Login` (Customer Community Login license) instead.

## Golden demo identity: Northwind (sign-in story)

Use **Northwind Robotics** as the prepared Experience Cloud login for the
returning-customer story. New Get Pricing buyers can create a community login
on the order-success screen (`POST /api/create-login` → Customer Community User
+ `ecToken` into Licenses & billing).

| Role | Account | How to open Licenses |
|------|---------|----------------------|
| **Sign-in demo** | Northwind Robotics 170200 | EC login → Manage licenses & billing |
| **New-customer demo** | Whatever the hero form creates | Create login on checkout success, or demo pin (company / `accountId`) |

Demo path (Northwind):

1. Open https://trailsignup-b4759183862b2b.my.site.com/bamboohr/s/login/
2. Sign in with the Northwind credentials (private artifact
   `.agents/artifacts/bamboohr-ec-demo-login.md`)
3. Home → **Manage licenses & billing** → BFF `/account?ecToken=…&focus=invoices`
   (invoices panel is scrolled into view; Pay Now stays on `/paynow`, not inside EC)

Re-seed after cleanup: place Get Pricing for Northwind (or reuse Account Id
`001gL00001enzlyQAA`), then
`provision_ec_demo_user.py` if the community user is missing.

## Why not iframe?

Cloudflare quick tunnels and many hosts send `X-Frame-Options` / CSP that block
embedding. Redirect / new-tab is the reliable thin-shell pattern.
