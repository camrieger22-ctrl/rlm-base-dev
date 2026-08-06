# Experience Cloud shell — BambooHR Get Pricing

Thin Salesforce Experience Cloud / Lightning page that **opens the hosted BFF**.
Revenue Cloud APIs stay on the BFF; the site is only branding + navigation.

## What’s in the repo

| Asset | Path |
|-------|------|
| LWC | `unpackaged/post_bamboohr/lwc/rlmBambooGetPricingShell` |
| App page | `unpackaged/post_bamboohr/flexipages/RLM_Bamboo_Get_Pricing` |
| Tab | `unpackaged/post_bamboohr/tabs/RLM_Bamboo_Get_Pricing` |
| BFF URL label | `RLM_Bamboo_Get_Pricing_Bff_Url` (default `http://127.0.0.1:8765`) |
| Set URL script | `scripts/bamboohr/set_get_pricing_bff_url.py` |

## Deploy

```bash
cci task run deploy_post_bamboohr --org master-demo
cci task run assign_permission_sets --org master-demo -o api_names RLM_BambooHR
```

(Or `cci flow run prepare_bamboohr --org master-demo -o bamboohr True`.)

## Point at your public BFF

```bash
# BFF + tunnel running (see HOSTED.md)
~/.local/pipx/venvs/cumulusci/bin/python \
  scripts/bamboohr/set_get_pricing_bff_url.py --org master-demo \
  --url https://YOUR-SUBDOMAIN.trycloudflare.com
```

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

Guest users: home route is `pageAccess: Public`. Custom Labels resolve without
Apex. The BFF still uses server-side Salesforce auth — guests never receive a
Salesforce token. Keep the Custom Label pointed at a live tunnel/host
(`set_get_pricing_bff_url.py`).

## Why not iframe?

Cloudflare quick tunnels and many hosts send `X-Frame-Options` / CSP that block
embedding. Redirect / new-tab is the reliable thin-shell pattern.
