#!/usr/bin/env bash
# Start the BambooHR Get Pricing BFF with the CumulusCI pipx Python
# (plain `python` usually lacks PyJWT / cumulusci).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
CCI_PY="${CCI_PY:-$HOME/.local/pipx/venvs/cumulusci/bin/python}"
ORG="${1:-master-demo}"
PORT="${PORT:-8765}"
HOST="${HOST:-127.0.0.1}"

if [[ ! -x "$CCI_PY" ]]; then
  echo "CumulusCI Python not found at: $CCI_PY" >&2
  echo "Install CCI via pipx, or set CCI_PY=/path/to/python" >&2
  exit 1
fi

exec "$CCI_PY" "$ROOT/scripts/bamboohr/get_pricing/server.py" \
  --org "$ORG" --host "$HOST" --port "$PORT"
