# Hosted self-serve — BambooHR Get Pricing BFF

Buyer-facing URL for Get Pricing + checkout **without** Experience Cloud.
Secrets stay on the server (or your laptop behind a tunnel). The browser never
holds a Salesforce token.

## Auth modes

| Mode | When | Env / flags |
|------|------|-------------|
| **CCI** (default local) | Laptop with CumulusCI keychain | `--org master-demo` |
| **Bearer token** | CI, container, quick tunnel bootstrap | `SF_ACCESS_TOKEN` + `SF_INSTANCE_URL` |
| **JWT Connected App** | Long-lived hosted process | `SF_CLIENT_ID` + `SF_USERNAME` + `SF_PRIVATE_KEY_PATH` (+ `SF_LOGIN_URL`) |

Resolution order is implemented in `auth.py`.

## Path A — Public URL in minutes (quick tunnel + EC label sync)

Keeps JWT/CCI auth on your machine; Cloudflare quick tunnel publishes HTTPS.
`publish_bff.py` **captures the URL and PATCHes** Custom Label
`RLM_Bamboo_Get_Pricing_Bff_Url` so Experience Cloud Get Pricing / Manage
licenses open the live host (not `127.0.0.1`).

```bash
# terminal 1 — BFF (JWT .env recommended for demos)
set -a; source scripts/bamboohr/get_pricing/.env; set +a
~/.local/pipx/venvs/cumulusci/bin/python \
  scripts/bamboohr/get_pricing/server.py --host 127.0.0.1 --port 8765

# terminal 2 — public HTTPS + sync EC label
./scripts/bamboohr/get_pricing/run_tunnel.sh
# or: ~/.local/pipx/venvs/cumulusci/bin/python \
#       scripts/bamboohr/get_pricing/publish_bff.py --org master-demo
```

Open the printed `https://….trycloudflare.com/` URL. Health:
`GET /api/health` → `{"ok": true, "authMode": "jwt"|…}`.

**Caveat:** quick-tunnel hostnames change every run. Re-run `publish_bff.py`
(or Path C) before an EC demo. Requires
[`cloudflared`](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/).

## Path C — Stable hostname (named Cloudflare Tunnel)

Same laptop/JWT process, **fixed** public URL for EC and buyers.

```bash
# One-time (Cloudflare account + DNS zone on Cloudflare)
cloudflared tunnel login
cloudflared tunnel create bamboohr-gp
cloudflared tunnel route dns bamboohr-gp gp.YOURDOMAIN.com
# Copy cloudflared.named.example.yml → .secrets/cloudflared.yml and fill UUID

# Every demo session
# terminal 1: BFF as usual
# terminal 2:
BFF_PUBLIC_URL='https://gp.YOURDOMAIN.com' \
CLOUDFLARE_TUNNEL_NAME='bamboohr-gp' \
  ~/.local/pipx/venvs/cumulusci/bin/python \
    scripts/bamboohr/get_pricing/publish_bff.py --org master-demo --named
```

Or `CLOUDFLARE_TUNNEL_CONFIG` pointing at the filled YAML (see
`cloudflared.named.example.yml`). Label sync uses `BFF_PUBLIC_URL`.

## Path B — JWT Connected App (real host / always-on)

**Live on `master-demo` (2026-08-06):** Connected App **BambooHR Get Pricing BFF**
(`BambooHR_Get_Pricing_BFF`), cert under `.secrets/`, Permission Set
`BambooHR_Get_Pricing_BFF_Access` assigned to the demo admin. Local
`scripts/bamboohr/get_pricing/.env` (gitignored) wires the Consumer Key.
Verified: `GET /api/health` → `"authMode": "jwt"`.

### 1. Generate a cert (once; never commit the private key)

```bash
./scripts/bamboohr/get_pricing/setup_jwt_cert.sh
# writes scripts/bamboohr/get_pricing/.secrets/server.key + server.crt
```

### 2. Create Connected App in `master-demo` (Setup or Metadata)

1. **App Manager → New Connected App** (or deploy `ConnectedApp` metadata with
   `oauthConfig.certificate` = PEM body of `server.crt`)
2. Enable **OAuth Settings**
3. Enable **Use digital signatures** → upload `server.crt`
4. Selected OAuth scopes: **Full access (full)** or API + refresh (demo: `full` + `refresh_token` is fine)
5. **Manage → Edit Policies**
   - Permitted Users: **Admin approved users are pre-authorized**
   - IP Relaxation: relax for demos if needed
6. **Manage Profiles / Permission Sets** — pre-authorize via a **dedicated
   Permission Set** assigned to the integration user (or demo admin).  
   Relying only on `profileName` / System Administrator in metadata often still
   yields `invalid_grant: user hasn't approved this consumer` for JWT until the
   PS → Connected App → user chain exists (`SetupEntityAccess` +
   `PermissionSetAssignment`).
7. Copy **Consumer Key** → `SF_CLIENT_ID`

### 3. Run with JWT

**Quote every `.env` value** (zsh treats `@` in emails as special if unquoted).

```bash
# Prefer gitignored .env (see .env.example). Always quote:
#   SF_USERNAME='camriegermasterdemoorg@demo.com'
set -a; source scripts/bamboohr/get_pricing/.env; set +a

# Or export by hand:
export SF_CLIENT_ID='…consumer key…'
export SF_USERNAME='camriegermasterdemoorg@demo.com'   # pre-authorized user
export SF_PRIVATE_KEY_PATH="$PWD/scripts/bamboohr/get_pricing/.secrets/server.key"
export SF_LOGIN_URL='https://trailsignup-b4759183862b2b.my.salesforce.com'  # My Domain
# optional: BFF_CORS_ORIGIN='*' PORT=8765

~/.local/pipx/venvs/cumulusci/bin/python \
  scripts/bamboohr/get_pricing/server.py --host 0.0.0.0 --port 8765
```

Do **not** pass `--org` when using JWT (avoids confusion; JWT env wins over CCI
anyway as long as `SF_CLIENT_ID` / `SF_USERNAME` / key are set and bearer env
is unset).

### 4. Bootstrap bearer token from CCI (no Connected App yet)

```bash
eval "$(~/.local/pipx/venvs/cumulusci/bin/python \
  scripts/bamboohr/get_pricing/export_cci_token.py --org master-demo)"
# exports SF_ACCESS_TOKEN + SF_INSTANCE_URL into the shell
```

## Docker (optional)

```bash
docker build -t bamboohr-get-pricing -f scripts/bamboohr/get_pricing/Dockerfile .
docker run --rm -p 8765:8765 \
  -e SF_ACCESS_TOKEN -e SF_INSTANCE_URL \
  bamboohr-get-pricing
```

## Security notes (demo)

- Do **not** put the Connected App secret or private key in the browser or static JS.
- Prefer a least-privilege integration user once past the demo.
- Tunnel URLs are public — treat as demo-only; revoke / stop when finished.
- Experience Cloud guest UI can come later as a thin shell that posts to this BFF.

## Verify

```bash
curl -sS http://127.0.0.1:8765/api/health
~/.local/pipx/venvs/cumulusci/bin/python \
  scripts/bamboohr/get_pricing_smoke.py --target-org master-demo
```
