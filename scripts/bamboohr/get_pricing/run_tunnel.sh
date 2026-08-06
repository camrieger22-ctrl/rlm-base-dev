#!/usr/bin/env bash
# Publish a local Get Pricing BFF (default :8765) via Cloudflare quick tunnel or ngrok.
set -euo pipefail
PORT="${BFF_PORT:-8765}"

if command -v cloudflared >/dev/null 2>&1; then
  echo "Starting Cloudflare quick tunnel → http://127.0.0.1:${PORT}"
  echo "Ensure the BFF is listening: --host 0.0.0.0 --port ${PORT}"
  exec cloudflared tunnel --url "http://127.0.0.1:${PORT}"
fi

if command -v ngrok >/dev/null 2>&1; then
  echo "Starting ngrok → http://127.0.0.1:${PORT}"
  exec ngrok http "${PORT}"
fi

echo "Install cloudflared or ngrok, then re-run." >&2
echo "  brew install cloudflare/cloudflare/cloudflared" >&2
echo "  # or: brew install ngrok" >&2
exit 1
