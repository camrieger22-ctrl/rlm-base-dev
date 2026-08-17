#!/usr/bin/env python3
"""Update Custom Label + Remote Site for BambooHR Get Pricing BFF URL.

Sets:
  - Custom Label RLM_Bamboo_Get_Pricing_Bff_Url
  - Remote Site Setting BambooHR_Get_Pricing_BFF (Agentforce Apex callouts)

Usage:
  ~/.local/pipx/venvs/cumulusci/bin/python \\
    scripts/bamboohr/set_get_pricing_bff_url.py --org master-demo \\
    --url https://calculation-magnitude-informed-outreach.trycloudflare.com

Agentforce actions cannot call 127.0.0.1 — use a public HTTPS URL.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

LABEL_NAME = "RLM_Bamboo_Get_Pricing_Bff_Url"
REMOTE_SITE_NAME = "BambooHR_Get_Pricing_BFF"
API = "v67.0"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--org", default="master-demo", help="CCI org alias")
    parser.add_argument("--url", required=True, help="BFF base URL (no trailing slash)")
    args = parser.parse_args()

    url = args.url.strip().rstrip("/")
    if not url:
        raise SystemExit("--url is required")
    if url.startswith("http://127.") or url.startswith("http://localhost"):
        print(
            "Warning: Salesforce Apex callouts cannot reach localhost. "
            "EC shell / DocGen may still use this URL; Agentforce Phase 2 needs public HTTPS.",
            file=sys.stderr,
        )

    from cumulusci.cli.runtime import CliRuntime

    runtime = CliRuntime(load_keychain=True)
    org = runtime.keychain.get_org(args.org)
    try:
        org.refresh_oauth_token(runtime.keychain)
    except Exception:  # noqa: BLE001
        pass
    token = org.access_token
    inst = str(org.instance_url).rstrip("/")

    def http(path: str, method: str = "GET", body: dict | None = None):
        data = json.dumps(body).encode() if body is not None else None
        headers = {
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
        }
        if body is not None:
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(
            f"{inst}{path}", data=data, headers=headers, method=method
        )
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                raw = resp.read().decode() or "{}"
                return resp.status, json.loads(raw) if raw.strip() else {}
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read().decode("utf-8", errors="replace")

    # --- Custom Label ---
    q = (
        "SELECT Id, Name, Value FROM ExternalString "
        f"WHERE Name = '{LABEL_NAME}' LIMIT 1"
    )
    code, payload = http(
        f"/services/data/{API}/tooling/query?q={urllib.parse.quote(q)}"
    )
    if code != 200 or not isinstance(payload, dict):
        print(f"Tooling query failed HTTP {code}: {payload}", file=sys.stderr)
        return 1
    rows = payload.get("records") or []
    if not rows:
        print(
            f"Label {LABEL_NAME} not found. Deploy unpackaged/post_bamboohr first.",
            file=sys.stderr,
        )
        return 1

    label_id = rows[0]["Id"]
    code, resp = http(
        f"/services/data/{API}/tooling/sobjects/ExternalString/{label_id}",
        "PATCH",
        {"Value": url},
    )
    if code not in (200, 204):
        print(f"Label PATCH failed HTTP {code}: {resp}", file=sys.stderr)
        return 1
    print(f"Updated {LABEL_NAME} → {url}")

    # --- Remote Site Setting (callout allow-list) ---
    rq = (
        "SELECT Id, SiteName, EndpointUrl, IsActive FROM RemoteProxy "
        f"WHERE SiteName = '{REMOTE_SITE_NAME}' LIMIT 1"
    )
    code, payload = http(
        f"/services/data/{API}/tooling/query?q={urllib.parse.quote(rq)}"
    )
    if code != 200 or not isinstance(payload, dict):
        print(
            f"RemoteProxy query failed HTTP {code}: {payload} "
            "(label updated; fix Remote Site manually if needed)",
            file=sys.stderr,
        )
        return 0

    rrows = payload.get("records") or []
    if rrows:
        rid = rrows[0]["Id"]
        code, resp = http(
            f"/services/data/{API}/tooling/sobjects/RemoteProxy/{rid}",
            "PATCH",
            {
                "Metadata": {
                    "disableProtocolSecurity": False,
                    "isActive": True,
                    "url": url,
                    "description": (
                        "BambooHR Get Pricing BFF for Agentforce callouts"
                    ),
                }
            },
        )
        if code not in (200, 204):
            print(f"Remote Site PATCH failed HTTP {code}: {resp}", file=sys.stderr)
            return 1
        print(f"Updated Remote Site {REMOTE_SITE_NAME} → {url}")
    else:
        code, resp = http(
            f"/services/data/{API}/tooling/sobjects/RemoteProxy",
            "POST",
            {
                "FullName": REMOTE_SITE_NAME,
                "Metadata": {
                    "disableProtocolSecurity": False,
                    "isActive": True,
                    "url": url,
                    "description": (
                        "BambooHR Get Pricing BFF for Agentforce callouts"
                    ),
                },
            },
        )
        if code not in (200, 201):
            print(
                f"Remote Site create failed HTTP {code}: {resp}\n"
                f"Deploy unpackaged/post_bamboohr/remoteSiteSettings, then re-run.",
                file=sys.stderr,
            )
            return 1
        print(f"Created Remote Site {REMOTE_SITE_NAME} → {url}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
