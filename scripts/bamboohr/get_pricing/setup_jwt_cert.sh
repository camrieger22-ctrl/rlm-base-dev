#!/usr/bin/env bash
# Generate RSA key + self-signed cert for a Salesforce JWT Connected App.
# Private key stays under .secrets/ (gitignored). Upload only .crt to Setup.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SECRETS="$ROOT/.secrets"
mkdir -p "$SECRETS"
chmod 700 "$SECRETS"
KEY="$SECRETS/server.key"
CRT="$SECRETS/server.crt"
if [[ -f "$KEY" || -f "$CRT" ]]; then
  echo "Refusing to overwrite existing $KEY / $CRT" >&2
  exit 1
fi
openssl req -x509 -sha256 -nodes -days 3650 -newkey rsa:2048 \
  -keyout "$KEY" -out "$CRT" \
  -subj "/CN=BambooHR Get Pricing BFF JWT/O=Demo/C=US"
chmod 600 "$KEY"
echo "Wrote $KEY"
echo "Wrote $CRT  ← upload this to Connected App → Use digital signatures"
echo "Set SF_PRIVATE_KEY_PATH=$KEY"
