#!/usr/bin/env python3
"""BambooHR A6 smoke: search index / catalog browse.

Asserts against Connect PCM APIs (post-rebuild):

1. GET /connect/pcm/catalogs/{id}/categories — Plans, Add-ons, Packages
2. POST /connect/pcm/products searchTerm=Bamboo — Core/Pro/Elite + Workforce + add-ons
3. POST /connect/pcm/products categoryIds=PC-BH-PLANS — three plan SKUs

Usage:
  python scripts/bamboohr/browse_smoke.py --target-org master-demo --via-cci
  cci task run rebuild_search_index --org master-demo   # if catalog just loaded
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

API = "v67.0"
CATALOG_NAME = "BambooHR"
EXPECTED_ROOT_CODES = {"PC-BH-PLANS", "PC-BH-ADDONS", "PC-BH-PACKAGES"}
EXPECTED_SEARCH_SKUS = {
    "BAMBOO-CORE",
    "BAMBOO-PRO",
    "BAMBOO-ELITE",
    "BAMBOO-PKG-WORKFORCE",
    "BAMBOO-ADD-PAYROLL",
    "BAMBOO-ADD-BENEFITS",
}
EXPECTED_PLAN_NAMES = {"BambooHR Core", "BambooHR Pro", "BambooHR Elite"}


class OrgSession:
    def __init__(self, alias: str, *, via_cci: bool = False) -> None:
        self.alias = alias
        if not via_cci:
            raise SystemExit("browse_smoke currently requires --via-cci (CCI REST)")
        from cumulusci.cli.runtime import CliRuntime

        runtime = CliRuntime(load_keychain=True)
        org = runtime.keychain.get_org(alias)
        if hasattr(org, "refresh_oauth_token"):
            try:
                org.refresh_oauth_token(runtime.keychain)
            except Exception:  # noqa: BLE001
                pass
        self._token = org.access_token
        self._instance = str(org.instance_url).rstrip("/")

    def _http(self, method: str, path: str, body: dict | None = None) -> Any:
        data = json.dumps(body).encode() if body is not None else None
        headers = {
            "Authorization": f"Bearer {self._token}",
            "Accept": "application/json",
        }
        if body is not None:
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(
            f"{self._instance}{path}", data=data, headers=headers, method=method
        )
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                raw = resp.read().decode()
        except urllib.error.HTTPError as exc:
            err = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"{method} {path} -> HTTP {exc.code}: {err[:2000]}") from exc
        return json.loads(raw) if raw.strip() else {}

    def soql(self, query: str) -> list[dict]:
        q = urllib.parse.quote(query)
        return self._http("GET", f"/services/data/{API}/query?q={q}").get("records") or []


def product_sku(p: dict) -> str | None:
    return (
        p.get("stockKeepingUnit")
        or p.get("productCode")
        or (p.get("product") or {}).get("stockKeepingUnit")
    )


def product_name(p: dict) -> str | None:
    return p.get("name") or p.get("Name") or (p.get("product") or {}).get("name")


def step_categories(session: OrgSession, catalog_id: str) -> None:
    print("\n== 1/3) Browse catalog categories ==")
    payload = session._http(
        "GET", f"/services/data/{API}/connect/pcm/catalogs/{catalog_id}/categories"
    )
    cats = payload.get("categories") or []
    codes = {c.get("code") for c in cats}
    missing = EXPECTED_ROOT_CODES - codes
    if missing:
        raise AssertionError(f"Missing root categories {missing}; got {sorted(codes)}")
    for c in cats:
        if c.get("code") in EXPECTED_ROOT_CODES and not c.get("isNavigational"):
            raise AssertionError(f"{c.get('code')} should be navigational")
        print(
            f"  PASS {c.get('code')} name={c.get('name')!r} "
            f"products={c.get('numberOfProducts')} nav={c.get('isNavigational')}"
        )


def step_search(session: OrgSession, catalog_id: str) -> None:
    print("\n== 2/3) Indexed searchTerm=Bamboo ==")
    payload = session._http(
        "POST",
        f"/services/data/{API}/connect/pcm/products",
        {"catalogIds": [catalog_id], "searchTerm": "Bamboo", "pageSize": 50},
    )
    products = payload.get("products") or []
    skus = {product_sku(p) for p in products}
    missing = EXPECTED_SEARCH_SKUS - skus
    if missing:
        raise AssertionError(
            f"searchTerm Bamboo missing SKUs {sorted(missing)}; got {sorted(skus - {None})}"
        )
    print(f"  PASS search returned {len(products)} hits including {sorted(EXPECTED_SEARCH_SKUS)}")


def step_plans_category(session: OrgSession, catalog_id: str, plans_id: str) -> None:
    print("\n== 3/3) Category browse PC-BH-PLANS ==")
    payload = session._http(
        "POST",
        f"/services/data/{API}/connect/pcm/products",
        {
            "catalogIds": [catalog_id],
            "categoryIds": [plans_id],
            "pageSize": 50,
        },
    )
    products = payload.get("products") or []
    names = {product_name(p) for p in products}
    missing = EXPECTED_PLAN_NAMES - names
    if missing:
        raise AssertionError(f"Plans category missing {missing}; got {sorted(names - {None})}")
    print(f"  PASS Plans category has {sorted(EXPECTED_PLAN_NAMES)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target-org", default="master-demo")
    parser.add_argument("--via-cci", action="store_true")
    args = parser.parse_args()
    if not args.via_cci:
        print("Tip: pass --via-cci when sf keychain decrypt fails in this environment.")
        raise SystemExit("browse_smoke requires --via-cci for now")

    print(f"BambooHR A6 browse/search smoke against {args.target_org}")
    session = OrgSession(args.target_org, via_cci=True)
    catalog = session.soql(
        f"SELECT Id FROM ProductCatalog WHERE Name = '{CATALOG_NAME}' LIMIT 1"
    )[0]
    plans = session.soql("SELECT Id FROM ProductCategory WHERE Code = 'PC-BH-PLANS' LIMIT 1")[0]
    step_categories(session, catalog["Id"])
    step_search(session, catalog["Id"])
    step_plans_category(session, catalog["Id"], plans["Id"])
    print("\nA6 browse smoke PASSED")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"\nA6 browse smoke FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
