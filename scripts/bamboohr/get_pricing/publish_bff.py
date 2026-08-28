#!/usr/bin/env python3
"""Publish the local Get Pricing BFF and point Experience Cloud at it.

Two modes:

1) **Quick tunnel** (default) — Cloudflare ephemeral HTTPS URL. Captures the
   printed ``*.trycloudflare.com`` host and PATCHes Custom Label
   ``RLM_Bamboo_Get_Pricing_Bff_Url`` so EC Get Pricing / Manage licenses work
   from any browser while this process runs.

2) **Named tunnel** — stable hostname. Set ``BFF_PUBLIC_URL`` (and optionally
   ``CLOUDFLARE_TUNNEL_NAME``). Syncs the label once, then runs
   ``cloudflared tunnel run <name>`` (or a config file).

Examples::

  # Terminal A: BFF with JWT (HTTP :8765 or HTTPS :8443)
  # Terminal B (HTTPS local certs: publish_bff auto-detects + --no-tls-verify):
  ~/.local/pipx/venvs/cumulusci/bin/python \\
    scripts/bamboohr/get_pricing/publish_bff.py --org master-demo --port 8443

  # Stable named tunnel (after one-time Cloudflare setup — see HOSTED.md)
  BFF_PUBLIC_URL='https://gp.example.com' CLOUDFLARE_TUNNEL_NAME='bamboohr-gp' \\
    ~/.local/pipx/venvs/cumulusci/bin/python \\
      scripts/bamboohr/get_pricing/publish_bff.py --org master-demo --named
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SET_LABEL = REPO / "scripts" / "bamboohr" / "set_get_pricing_bff_url.py"

QUICK_URL_RE = re.compile(
    r"https://[a-zA-Z0-9-]+\.trycloudflare\.com",
)


def _health_url(url: str, timeout: float = 2.0, *, insecure: bool = False) -> bool:
    ctx = ssl._create_unverified_context() if insecure else None  # noqa: SLF001
    try:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            return resp.status == 200
    except (urllib.error.URLError, TimeoutError, OSError):
        return False


def _detect_origin(port: int) -> tuple[str, bool]:
    """Return (origin_url, use_tls_verify_skip) for the local BFF."""
    https = f"https://127.0.0.1:{port}"
    http = f"http://127.0.0.1:{port}"
    if _health_url(f"{https}/api/health", insecure=True):
        return https, True
    if _health_url(f"{http}/api/health"):
        return http, False
    return "", False


def _set_label(org: str, url: str) -> None:
    py = sys.executable
    cmd = [py, str(SET_LABEL), "--org", org, "--url", url]
    print(f"→ Syncing Custom Label to {url}")
    subprocess.check_call(cmd)


def _require_cloudflared() -> str:
    path = shutil.which("cloudflared")
    if not path:
        raise SystemExit(
            "cloudflared not found. Install: brew install cloudflare/cloudflare/cloudflared"
        )
    return path


def run_quick(org: str, port: int, sync_label: bool) -> int:
    cf = _require_cloudflared()
    origin, skip_tls = _detect_origin(port)
    if not origin:
        raise SystemExit(
            f"BFF not healthy on http(s)://127.0.0.1:{port}/api/health — "
            "start server.py first (JWT/.env or --org). HTTPS 8443 is detected automatically."
        )

    cmd = [cf, "tunnel", "--url", origin]
    if skip_tls:
        cmd.append("--no-tls-verify")
    print(f"Starting Cloudflare quick tunnel → {origin}")
    print("(URL changes each run; use --named + BFF_PUBLIC_URL for a stable host)")
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    assert proc.stdout is not None
    public_url: str | None = None
    try:
        for line in proc.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            if public_url is None:
                m = QUICK_URL_RE.search(line)
                if m:
                    public_url = m.group(0).rstrip("/")
                    print(f"\n*** Public BFF: {public_url} ***\n")
                    if sync_label:
                        try:
                            _set_label(org, public_url)
                            print(
                                "Experience Cloud shell will open this URL "
                                "(Get Pricing / Manage licenses).\n"
                            )
                        except subprocess.CalledProcessError as exc:
                            print(
                                f"WARN: label sync failed ({exc}). "
                                f"Run set_get_pricing_bff_url.py --url {public_url}",
                                file=sys.stderr,
                            )
        return proc.wait()
    except KeyboardInterrupt:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        print("\nTunnel stopped.")
        return 0


def run_named(org: str, port: int, sync_label: bool) -> int:
    cf = _require_cloudflared()
    public = (os.environ.get("BFF_PUBLIC_URL") or "").strip().rstrip("/")
    if not public:
        raise SystemExit(
            "Named mode requires BFF_PUBLIC_URL "
            "(e.g. https://bamboohr-gp.yourdomain.com)."
        )
    if not public.startswith("https://"):
        raise SystemExit("BFF_PUBLIC_URL must be https://…")

    origin, _skip_tls = _detect_origin(port)
    if not origin:
        raise SystemExit(
            f"BFF not healthy on http(s)://127.0.0.1:{port}/api/health — start server.py first."
        )

    if sync_label:
        _set_label(org, public)

    tunnel_name = (os.environ.get("CLOUDFLARE_TUNNEL_NAME") or "").strip()
    config = (os.environ.get("CLOUDFLARE_TUNNEL_CONFIG") or "").strip()
    if config:
        cmd = [cf, "tunnel", "--config", config, "run"]
    elif tunnel_name:
        cmd = [cf, "tunnel", "run", tunnel_name]
    else:
        raise SystemExit(
            "Set CLOUDFLARE_TUNNEL_NAME or CLOUDFLARE_TUNNEL_CONFIG "
            "(see HOSTED.md Path C)."
        )

    print(f"Stable public BFF: {public}")
    print(f"Running: {' '.join(cmd)}")
    # Give DNS a moment if route was just created
    time.sleep(0.5)
    return subprocess.call(cmd)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--org", default="master-demo")
    parser.add_argument("--port", type=int, default=int(os.environ.get("BFF_PORT") or 8765))
    parser.add_argument(
        "--named",
        action="store_true",
        help="Use named Cloudflare tunnel + BFF_PUBLIC_URL (stable hostname)",
    )
    parser.add_argument(
        "--no-sync-label",
        action="store_true",
        help="Do not PATCH RLM_Bamboo_Get_Pricing_Bff_Url",
    )
    args = parser.parse_args()
    sync = not args.no_sync_label
    if args.named:
        return run_named(args.org, args.port, sync)
    return run_quick(args.org, args.port, sync)


if __name__ == "__main__":
    raise SystemExit(main())
