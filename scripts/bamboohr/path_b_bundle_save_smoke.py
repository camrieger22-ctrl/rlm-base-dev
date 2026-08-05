#!/usr/bin/env python3
"""BambooHR A7 smoke: Path B Bundle & Save (a la carte).

Asserts:

1. Place Core + Payroll + Benefits (no package) → Quote.RLM_Bamboo_PathB_BundleSave__c
2. Headless Default pricing → Payroll/Benefits NetUnitPrice ≈ list × 0.85
   and waterfall includes Path B Bundle & Save ManualDiscount
3. Path A Workforce package quote keeps flag false (BBA owns Bundle & Save)

Usage:
  python scripts/bamboohr/path_b_bundle_save_smoke.py --target-org master-demo --via-cci
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import date, timedelta
from typing import Any

API = "v67.0"
ACCOUNT = "Acme"
BUNDLE_SAVE = 0.85
LIST = {
    "BAMBOO-CORE": 10.0,
    "BAMBOO-ADD-PAYROLL": 8.0,
    "BAMBOO-ADD-BENEFITS": 6.0,
}


class OrgSession:
    def __init__(self, alias: str, *, via_cci: bool = False) -> None:
        if not via_cci:
            raise SystemExit("path_b_bundle_save_smoke requires --via-cci")
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
            with urllib.request.urlopen(req, timeout=180) as resp:
                raw = resp.read().decode()
        except urllib.error.HTTPError as exc:
            err = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"{method} {path} -> HTTP {exc.code}: {err[:2500]}") from exc
        return json.loads(raw) if raw.strip() else {}

    def soql(self, query: str) -> list[dict]:
        q = urllib.parse.quote(query)
        return self._http("GET", f"/services/data/{API}/query?q={q}").get("records") or []

    def create(self, sobject: str, fields: dict) -> str:
        result = self._http("POST", f"/services/data/{API}/sobjects/{sobject}", fields)
        rid = result.get("id")
        if not rid:
            raise RuntimeError(f"Create {sobject} failed: {result}")
        return rid

    def post(self, path: str, body: dict) -> dict | list:
        return self._http("POST", path, body)


def _pbe(session: OrgSession, sku: str) -> dict:
    return session.soql(
        "SELECT Id, Product2Id, UnitPrice FROM PricebookEntry "
        "WHERE Pricebook2.IsStandard = true "
        f"AND Product2.StockKeepingUnit = '{sku}' "
        "AND ProductSellingModel.SellingModelType = 'TermDefined' "
        "AND ProductSellingModel.PricingTermUnit = 'Months' LIMIT 1"
    )[0]


def place(session: OrgSession, ids: dict, skus: list[str], name: str) -> str:
    opp_id = session.create(
        "Opportunity",
        {
            "Name": name,
            "AccountId": ids["account_id"],
            "StageName": "Prospecting",
            "CloseDate": "2026-12-31",
            "Pricebook2Id": ids["pricebook_id"],
        },
    )
    today = date.today().isoformat()
    end = (date.today() + timedelta(days=365)).isoformat()
    records: list[dict] = [
        {
            "referenceId": "refQuote",
            "record": {
                "attributes": {"method": "POST", "type": "Quote"},
                "Name": name,
                "OpportunityId": opp_id,
                "Pricebook2Id": ids["pricebook_id"],
                "QuoteAccountId": ids["account_id"],
            },
        }
    ]
    for i, sku in enumerate(skus):
        pbe = ids["pbes"][sku]
        records.append(
            {
                "referenceId": f"refL{i}",
                "record": {
                    "attributes": {"type": "QuoteLineItem", "method": "POST"},
                    "QuoteId": "@{refQuote.id}",
                    "Product2Id": pbe["Product2Id"],
                    "PricebookEntryId": pbe["Id"],
                    "Quantity": "10",
                    "StartDate": today,
                    "EndDate": end,
                    "PeriodBoundary": "Anniversary",
                    "BillingFrequency": "Monthly",
                },
            }
        )
    # Skip System pricing on place — Path B flag is set in QLI after-insert;
    # headless pricing after place hydrates the flag reliably (same pattern as A2).
    placed = session.post(
        f"/services/data/{API}/connect/rev/sales-transaction/actions/place",
        {
            "pricingPref": "Skip",
            "catalogRatesPref": "Skip",
            "taxPref": "Skip",
            "configurationPref": {
                "configurationMethod": "System",
                "configurationOptions": {
                    "validateProductCatalog": True,
                    "validateAmendRenewCancel": True,
                    "executeConfigurationRules": False,
                    "addDefaultConfiguration": False,
                },
            },
            "graph": {"graphId": f"a7{uuid.uuid4().hex[:8]}", "records": records},
        },
    )
    if isinstance(placed, list):
        placed = placed[0]
    if not placed.get("isSuccess"):
        raise AssertionError(f"Place failed: {placed}")
    return placed["salesTransactionId"]


def _approx(actual: float, expected: float, tol: float = 0.05) -> bool:
    return abs(actual - expected) <= tol


def headless_price_line(session: OrgSession, ids: dict, quote_id: str, line: dict) -> dict:
    """Run Default headless pricing for one line; return waterfall JSON."""
    today = date.today().isoformat()
    end = (date.today() + timedelta(days=365)).isoformat()
    ctx_payload = session._http(
        "GET",
        f"/services/data/{API}/connect/context-definitions/RLM_SalesTransactionContext",
    )
    ctx_def_id = ctx_payload["contextDefinitionId"]
    mapping_id = None
    for version in ctx_payload.get("contextDefinitionVersionList") or []:
        for mapping in version.get("contextMappings") or []:
            base = mapping.get("baseReference") or ""
            if base.endswith("/QuoteEntitiesMapping") or "QuoteEntitiesMapping" in base:
                mapping_id = mapping.get("contextMappingId")
                break
        if mapping_id:
            break
    if not mapping_id:
        raise RuntimeError("Could not resolve QuoteEntitiesMapping id")

    pricing_data = {
        "SalesTransaction": {
            "businessObjectType": "Quote",
            "id": quote_id,
            "Pricebook": ids["pricebook_id"],
            "CurrencyIsoCode": "USD",
            "SalesTransactionItem": [
                {
                    "businessObjectType": "QuoteLineItem",
                    "id": line["Id"],
                    "Product": line["Product2Id"],
                    "ProductSellingModel": line["ProductSellingModelId"],
                    "Quantity": 10,
                    "SalesTransactionItemSource": "LINE_ITEM1",
                    "EffectiveFrom": f"{today}T00:00:00.000Z",
                    "EffectiveTo": f"{end}T00:00:00.000Z",
                }
            ],
        }
    }
    price_body = {
        "inputs": [
            {
                "contextDefinitionId": ctx_def_id,
                "contextMappingId": mapping_id,
                "pricingProcedureId": "RLM_DefaultPricingProcedure",
                "skipDiscovery": True,
                "displayContext": True,
                "isSkipWaterfall": False,
                "persistContext": True,
                "useSessionScopedContext": False,
                "taggedData": False,
                "pricingData": json.dumps(pricing_data, separators=(",", ":")),
            }
        ]
    }
    priced = session.post(
        f"/services/data/{API}/actions/standard/runSalesforceHeadlessPricing",
        price_body,
    )
    if isinstance(priced, list):
        priced = priced[0]
    if priced.get("isSuccess") is False:
        raise AssertionError(f"Headless pricing failed: {priced}")
    outs = priced.get("outputValues") or {}
    if outs.get("pricingProcessStatus") != "Completed":
        raise AssertionError(f"Headless pricing failed: {outs or priced}")
    return json.loads(json.loads(outs["pricingResult"])["PriceWaterFall"][0]["value"])


def step_path_b(session: OrgSession, ids: dict) -> None:
    print("\n== 1) A la carte Core+Payroll+Benefits → Path B 15% ==")
    qid = place(
        session,
        ids,
        ["BAMBOO-CORE", "BAMBOO-ADD-PAYROLL", "BAMBOO-ADD-BENEFITS"],
        "A7 Path B Bundle Save",
    )
    q = session.soql(
        f"SELECT Id, RLM_Bamboo_PathB_BundleSave__c FROM Quote WHERE Id = '{qid}'"
    )[0]
    if not q.get("RLM_Bamboo_PathB_BundleSave__c"):
        raise AssertionError(f"Path B flag false on {qid} after place")
    print(f"  PASS flag true on {qid}")

    lines = session.soql(
        "SELECT Id, Product2Id, ProductSellingModelId, Product2.StockKeepingUnit, "
        "UnitPrice, ListPrice, RLM_Bamboo_BundleSave_Target__c "
        f"FROM QuoteLineItem WHERE QuoteId = '{qid}'"
    )
    by_sku = {r["Product2"]["StockKeepingUnit"]: r for r in lines}

    for sku in ("BAMBOO-ADD-PAYROLL", "BAMBOO-ADD-BENEFITS"):
        line = by_sku.get(sku)
        if not line:
            raise AssertionError(f"Missing line {sku} on {qid}")
        if not line.get("RLM_Bamboo_BundleSave_Target__c"):
            raise AssertionError(f"{sku} target formula false on {qid}")
        wf = headless_price_line(session, ids, qid, line)
        expected = LIST[sku] * BUNDLE_SAVE
        net = float(wf["output"]["NetUnitPrice"])
        if not _approx(net, expected):
            steps = [
                (s.get("pricingElement") or {}).get("name")
                for s in wf.get("waterfall", [])
            ]
            raise AssertionError(
                f"{sku} expected ~{expected} after Path B Bundle & Save, got {net}; "
                f"waterfall={steps}"
            )
        bundle_step = any(
            "Bundle" in ((s.get("pricingElement") or {}).get("name") or "")
            or "Path B" in ((s.get("pricingElement") or {}).get("name") or "")
            or "a la carte" in ((s.get("pricingElement") or {}).get("name") or "")
            for s in wf.get("waterfall", [])
        )
        if not bundle_step:
            raise AssertionError(
                f"Path B Bundle & Save step missing from waterfall for {sku}: "
                f"{[(s.get('pricingElement') or {}).get('name') for s in wf.get('waterfall', [])]}"
            )
        line_after = session.soql(
            f"SELECT UnitPrice FROM QuoteLineItem WHERE Id = '{line['Id']}'"
        )[0]
        if not _approx(float(line_after["UnitPrice"]), expected):
            raise AssertionError(
                f"{sku} persisted UnitPrice expected ~{expected}, "
                f"got {line_after['UnitPrice']}"
            )
        print(f"  PASS {sku} headless+persisted ≈ {expected} (net={net})")


def step_path_a_flag_off(session: OrgSession, ids: dict) -> None:
    print("\n== 2) Workforce package → Path B flag false ==")
    qid = place(session, ids, ["BAMBOO-PKG-WORKFORCE"], "A7 Path A Package")
    q = session.soql(
        f"SELECT Id, RLM_Bamboo_PathB_BundleSave__c FROM Quote WHERE Id = '{qid}'"
    )[0]
    if q.get("RLM_Bamboo_PathB_BundleSave__c"):
        raise AssertionError(
            f"Path B flag unexpectedly true on package quote {qid} "
            "(would double-discount with BBA)"
        )
    print(f"  PASS flag false on package quote {qid}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target-org", default="master-demo")
    parser.add_argument("--via-cci", action="store_true")
    args = parser.parse_args()
    print(f"BambooHR A7 Path B Bundle & Save smoke against {args.target_org}")
    session = OrgSession(args.target_org, via_cci=args.via_cci)
    acct = session.soql(f"SELECT Id FROM Account WHERE Name = '{ACCOUNT}' LIMIT 1")[0]
    pb = session.soql("SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1")[0]
    ids = {
        "account_id": acct["Id"],
        "pricebook_id": pb["Id"],
        "pbes": {
            "BAMBOO-CORE": _pbe(session, "BAMBOO-CORE"),
            "BAMBOO-ADD-PAYROLL": _pbe(session, "BAMBOO-ADD-PAYROLL"),
            "BAMBOO-ADD-BENEFITS": _pbe(session, "BAMBOO-ADD-BENEFITS"),
            "BAMBOO-PKG-WORKFORCE": _pbe(session, "BAMBOO-PKG-WORKFORCE"),
        },
    }
    step_path_b(session, ids)
    step_path_a_flag_off(session, ids)
    print("\nA7 Path B Bundle & Save smoke PASSED")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"\nA7 Path B Bundle & Save smoke FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
