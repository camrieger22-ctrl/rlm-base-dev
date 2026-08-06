#!/usr/bin/env python3
"""Update Custom Label RLM_Bamboo_Get_Pricing_Bff_Url in a Salesforce org.

Usage:
  ~/.local/pipx/venvs/cumulusci/bin/python \\
    scripts/bamboohr/set_get_pricing_bff_url.py --org master-demo \\
    --url https://calculation-magnitude-informed-outreach.trycloudflare.com
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

LABEL_NAME = "RLM_Bamboo_Get_Pricing_Bff_Url"
API = "v67.0"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--org", default="master-demo", help="CCI org alias")
    parser.add_argument("--url", required=True, help="BFF base URL (no trailing slash)")
    args = parser.parse_args()

    url = args.url.strip().rstrip("/")
    if not url:
        raise SystemExit("--url is required")

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
        print(f"PATCH failed HTTP {code}: {resp}", file=sys.stderr)
        return 1
    print(f"Updated {LABEL_NAME} → {url}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
