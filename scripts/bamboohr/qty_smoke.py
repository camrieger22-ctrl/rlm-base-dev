#!/usr/bin/env python3
"""BambooHR A5 smoke: Workforce package qty = headcount for children.

Asserts:

1. ProductRelatedComponent rows for BAMBOO-PKG-WORKFORCE use
   QuantityScaleMethod=Proportional, Quantity=1, IsQuantityEditable=false
2. Place Sales Transaction with package qty HEADCOUNT expands default
   Pro + Payroll + Benefits, each with Quantity == HEADCOUNT
3. Second place at HEADCOUNT_2 proves children track a different package qty

Usage:
  python scripts/bamboohr/qty_smoke.py --target-org master-demo
  python scripts/bamboohr/qty_smoke.py --target-org master-demo --via-cci
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, timedelta
from pathlib import Path
from typing import Any

API = "v67.0"
PKG_SKU = "BAMBOO-PKG-WORKFORCE"
EXPECTED_CHILDREN = ("BAMBOO-PRO", "BAMBOO-ADD-PAYROLL", "BAMBOO-ADD-BENEFITS")
ACCOUNT = "Acme"
HEADCOUNT = 25
HEADCOUNT_2 = 50


class OrgSession:
    """SOQL / create / REST against one org (sf CLI or CCI token)."""

    def __init__(self, alias: str, *, via_cci: bool = False) -> None:
        self.alias = alias
        self.via_cci = via_cci
        self._token: str | None = None
        self._instance: str | None = None
        if via_cci:
            self._init_cci()

    def _init_cci(self) -> None:
        from cumulusci.cli.runtime import CliRuntime

        runtime = CliRuntime(load_keychain=True)
        org = runtime.keychain.get_org(self.alias)
        # Refresh if needed; get_org typically loads a usable token.
        if hasattr(org, "refresh_oauth_token"):
            try:
                org.refresh_oauth_token(runtime.keychain)
            except Exception:  # noqa: BLE001 — fall through to existing token
                pass
        token = getattr(org, "access_token", None)
        instance = getattr(org, "instance_url", None)
        if not token or not instance:
            raise RuntimeError(
                f"CCI org {self.alias!r} missing access_token/instance_url"
            )
        self._token = token
        self._instance = str(instance).rstrip("/")

    def _rest(
        self, method: str, path: str, body: dict | None = None
    ) -> Any:
        if not self.via_cci:
            return self._rest_sf(method, path, body)
        assert self._token and self._instance
        url = f"{self._instance}{path}"
        data = None
        headers = {
            "Authorization": f"Bearer {self._token}",
            "Accept": "application/json",
        }
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                raw = resp.read().decode("utf-8")
        except urllib.error.HTTPError as exc:
            err = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"{method} {path} -> HTTP {exc.code}: {err[:2000]}") from exc
        if not raw.strip():
            return {}
        return json.loads(raw)

    def _rest_sf(self, method: str, path: str, body: dict | None = None) -> Any:
        cmd = [
            "sf",
            "api",
            "request",
            "rest",
            path,
            "--method",
            method,
            "--target-org",
            self.alias,
        ]
        body_path = None
        if body is not None:
            with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
                json.dump(body, f)
                body_path = f.name
            cmd.extend(["--body", f"@{body_path}"])
        cp = subprocess.run(cmd, check=False, capture_output=True, text=True)
        if body_path:
            Path(body_path).unlink(missing_ok=True)
        raw = (cp.stdout or "") + "\n" + (cp.stderr or "")
        if cp.returncode != 0:
            raise RuntimeError(f"sf api request failed:\n{raw[:3000]}")
        return _loads_json_payload(raw)

    def soql(self, query: str) -> list[dict]:
        if self.via_cci:
            q = urllib.parse.quote(query)
            payload = self._rest("GET", f"/services/data/{API}/query?q={q}")
            return payload.get("records") or []
        cp = subprocess.run(
            ["sf", "data", "query", "-q", query, "--target-org", self.alias, "--json"],
            check=False,
            capture_output=True,
            text=True,
        )
        payload = (cp.stdout or "") + "\n" + (cp.stderr or "")
        if cp.returncode != 0:
            raise RuntimeError(f"sf data query failed:\n{payload[:3000]}")
        return _loads_json_payload(payload)["result"]["records"]

    def create_record(self, sobject: str, fields: dict[str, Any]) -> str:
        if self.via_cci:
            result = self._rest("POST", f"/services/data/{API}/sobjects/{sobject}", fields)
            rid = result.get("id")
            if not rid:
                raise RuntimeError(f"Create {sobject} failed: {result}")
            return rid
        values = " ".join(f"{k}={_sf_value(v)}" for k, v in fields.items())
        cp = subprocess.run(
            [
                "sf",
                "data",
                "create",
                "record",
                "--sobject",
                sobject,
                "--values",
                values,
                "--target-org",
                self.alias,
                "--json",
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        payload = (cp.stdout or "") + "\n" + (cp.stderr or "")
        if cp.returncode != 0:
            raise RuntimeError(f"sf data create failed:\n{payload[:3000]}")
        return _loads_json_payload(payload)["result"]["id"]

    def api_post(self, path: str, body: dict) -> dict:
        return self._rest("POST", path, body)


def _sf_value(v: Any) -> str:
    if isinstance(v, str) and (" " in v or "'" in v):
        return "'" + v.replace("'", "\\'") + "'"
    return str(v)


def _loads_json_payload(text: str) -> dict:
    text = text.strip()
    decoder = json.JSONDecoder()
    idx = 0
    while idx < len(text):
        while idx < len(text) and text[idx] not in "{[":
            idx += 1
        if idx >= len(text):
            break
        try:
            obj, end = decoder.raw_decode(text, idx)
        except json.JSONDecodeError:
            idx += 1
            continue
        if isinstance(obj, dict) and ("result" in obj or "status" in obj or "isSuccess" in obj):
            return obj
        if isinstance(obj, list) and obj:
            return obj[0] if isinstance(obj[0], dict) else {"result": obj}
        idx = end
    raise RuntimeError(f"Could not parse JSON payload:\n{text[:2000]}")


def step_prc(session: OrgSession) -> None:
    print("\n== 1/2) ProductRelatedComponent scale methods ==")
    rows = session.soql(
        "SELECT ChildProduct.StockKeepingUnit, Quantity, QuantityScaleMethod, "
        "IsQuantityEditable FROM ProductRelatedComponent "
        f"WHERE ParentProduct.StockKeepingUnit = '{PKG_SKU}'"
    )
    if len(rows) < 5:
        raise AssertionError(f"Expected >=5 PRC rows for {PKG_SKU}, got {len(rows)}")
    for r in rows:
        sku = r["ChildProduct"]["StockKeepingUnit"]
        if r.get("QuantityScaleMethod") != "Proportional":
            raise AssertionError(f"{sku}: QuantityScaleMethod={r.get('QuantityScaleMethod')}")
        if float(r.get("Quantity") or 0) != 1.0:
            raise AssertionError(f"{sku}: Quantity={r.get('Quantity')} (want 1)")
        if r.get("IsQuantityEditable") is not False:
            raise AssertionError(
                f"{sku}: IsQuantityEditable={r.get('IsQuantityEditable')} "
                "(want false so only package qty is the headcount knob)"
            )
        print(f"  PASS {sku}: Proportional qty=1 editable=false")


def place_package(session: OrgSession, ids: dict, headcount: int) -> str:
    opp_id = session.create_record(
        "Opportunity",
        {
            "Name": f"A5 Qty Smoke {headcount}",
            "AccountId": ids["account_id"],
            "StageName": "Prospecting",
            "CloseDate": "2026-12-31",
            "Pricebook2Id": ids["pricebook_id"],
        },
    )
    today = date.today().isoformat()
    end = (date.today() + timedelta(days=365)).isoformat()
    body = {
        "pricingPref": "System",
        "catalogRatesPref": "Skip",
        # Skip skips configurator entirely (no child expansion). System/Force
        # + addDefaultConfiguration expands Pro + Payroll + Benefits.
        "configurationPref": {
            "configurationMethod": "System",
            "configurationOptions": {
                "validateProductCatalog": True,
                "validateAmendRenewCancel": True,
                "executeConfigurationRules": True,
                "addDefaultConfiguration": True,
            },
        },
        "taxPref": "Skip",
        "graph": {
            "graphId": f"a5BambooQty{headcount}",
            "records": [
                {
                    "referenceId": "refQuote",
                    "record": {
                        "attributes": {"method": "POST", "type": "Quote"},
                        "Name": f"A5 Qty Smoke headcount={headcount}",
                        "OpportunityId": opp_id,
                        "Pricebook2Id": ids["pricebook_id"],
                        "QuoteAccountId": ids["account_id"],
                    },
                },
                {
                    "referenceId": "refQuoteLine0",
                    "record": {
                        "attributes": {"type": "QuoteLineItem", "method": "POST"},
                        "QuoteId": "@{refQuote.id}",
                        "Product2Id": ids["pkg_product_id"],
                        "PricebookEntryId": ids["pkg_pbe_id"],
                        "Quantity": str(headcount),
                        "StartDate": today,
                        "EndDate": end,
                        "PeriodBoundary": "Anniversary",
                        "BillingFrequency": "Monthly",
                    },
                },
            ],
        },
    }
    placed = session.api_post(
        f"/services/data/{API}/connect/rev/sales-transaction/actions/place", body
    )
    if not placed.get("isSuccess"):
        raise AssertionError(f"Place sales transaction failed: {placed}")
    return placed["salesTransactionId"]


def assert_child_qtys(session: OrgSession, quote_id: str, headcount: int) -> None:
    lines = session.soql(
        "SELECT Id, Quantity, Product2.StockKeepingUnit, ParentQuoteLineItemId "
        f"FROM QuoteLineItem WHERE QuoteId = '{quote_id}'"
    )
    by_sku = {r["Product2"]["StockKeepingUnit"]: r for r in lines}
    root = by_sku.get(PKG_SKU)
    if not root:
        raise AssertionError(f"Missing package root line; SKUs={sorted(by_sku)}")
    if float(root["Quantity"]) != float(headcount):
        raise AssertionError(
            f"Package qty expected {headcount}, got {root['Quantity']}"
        )
    if root.get("ParentQuoteLineItemId"):
        raise AssertionError("Package root unexpectedly has ParentQuoteLineItemId")

    for sku in EXPECTED_CHILDREN:
        child = by_sku.get(sku)
        if not child:
            raise AssertionError(
                f"Missing child {sku} after default config; SKUs={sorted(by_sku)}"
            )
        if child.get("ParentQuoteLineItemId") != root["Id"]:
            raise AssertionError(
                f"{sku} ParentQuoteLineItemId={child.get('ParentQuoteLineItemId')} "
                f"want {root['Id']}"
            )
        if float(child["Quantity"]) != float(headcount):
            raise AssertionError(
                f"{sku} qty expected {headcount} (proportional to package), "
                f"got {child['Quantity']}"
            )
        print(f"  PASS {sku} qty={child['Quantity']} (= package headcount)")


def step_place_and_scale(session: OrgSession, ids: dict) -> list[str]:
    print("\n== 2/2) Place Workforce package at two headcounts ==")
    quote_ids = []
    for hc in (HEADCOUNT, HEADCOUNT_2):
        qid = place_package(session, ids, hc)
        print(f"  placed quote {qid} package qty={hc}")
        assert_child_qtys(session, qid, hc)
        quote_ids.append(qid)
    return quote_ids


def resolve_ids(session: OrgSession) -> dict:
    pkg = session.soql(
        f"SELECT Id FROM Product2 WHERE StockKeepingUnit = '{PKG_SKU}' LIMIT 1"
    )[0]
    pbe = session.soql(
        "SELECT Id FROM PricebookEntry WHERE Pricebook2.IsStandard = true "
        f"AND Product2.StockKeepingUnit = '{PKG_SKU}' "
        "AND ProductSellingModel.SellingModelType = 'TermDefined' "
        "AND ProductSellingModel.PricingTermUnit = 'Months' LIMIT 1"
    )[0]
    pb = session.soql("SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1")[0]
    acct = session.soql(f"SELECT Id FROM Account WHERE Name = '{ACCOUNT}' LIMIT 1")[0]
    return {
        "pkg_product_id": pkg["Id"],
        "pkg_pbe_id": pbe["Id"],
        "pricebook_id": pb["Id"],
        "account_id": acct["Id"],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target-org", default="master-demo")
    parser.add_argument(
        "--via-cci",
        action="store_true",
        help="Use CumulusCI org auth + REST (when sf keychain decrypt fails)",
    )
    args = parser.parse_args()
    org = args.target_org
    via_cci = args.via_cci
    print(f"BambooHR A5 qty/headcount smoke against {org} (via_cci={via_cci})")
    session = OrgSession(org, via_cci=via_cci)
    ids = resolve_ids(session)
    step_prc(session)
    quote_ids = step_place_and_scale(session, ids)
    print("\nA5 qty smoke PASSED")
    for qid in quote_ids:
        print(f"  Quote: {qid}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001 — CLI entrypoint
        print(f"\nA5 qty smoke FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
