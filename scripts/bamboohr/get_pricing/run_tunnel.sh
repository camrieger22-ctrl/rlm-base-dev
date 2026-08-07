#!/usr/bin/env bash
# Publish local BFF (:8765) and sync Experience Cloud Custom Label.
# Prefer publish_bff.py (captures URL + PATCHes RLM_Bamboo_Get_Pricing_Bff_Url).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PY="${PYTHON:-$HOME/.local/pipx/venvs/cumulusci/bin/python}"
PORT="${BFF_PORT:-8765}"
ORG="${CCI_ORG:-master-demo}"

if [[ ! -x "$PY" ]]; then
  PY="$(command -v python3)"
fi

exec "$PY" "$ROOT/scripts/bamboohr/get_pricing/publish_bff.py" \
  --org "$ORG" \
  --port "$PORT" \
  "$@"
