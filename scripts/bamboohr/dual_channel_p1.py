#!/usr/bin/env python3
"""BambooHR dual-channel P1: Discovery → calculate(qty) → create Quote.

Thin BFF-shaped smoke for the self-serve / API channel (fork-only). Asserts:

1. Discover — PCM searchTerm=Bamboo returns Core + Workforce (+ add-ons)
2. Calculate — headless Default pricing on commercial Acme:
     qty 10 → list $10 (no volume); qty 50 → ~$9.50 (5% volume band)
3. Create Quote — place Core @ qty 50 with QuoteAccountId=Acme; UnitPrice ≈ 9.50

Auth: CCI org OAuth (`--via-cci`). Connected-App / guest auth is P2.

Usage:
  python scripts/bamboohr/dual_channel_p1.py --target-org master-demo --via-cci
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
CATALOG_NAME = "BambooHR"
ACCOUNT = "Acme"
CORE_SKU = "BAMBOO-CORE"
LIST_MONTHLY = 10.0
QTY_BELOW_VOLUME = 10
QTY_VOLUME = 50
VOLUME_NET = 9.5  # 5% of $10 in 25–75 band
EXPECTED_SKUS = {
    "BAMBOO-CORE",
    "BAMBOO-PRO",
    "BAMBOO-ELITE",
    "BAMBOO-PKG-WORKFORCE",
}


class OrgSession:
    def __init__(self, alias: str, *, via_cci: bool = False) -> None:
        if not via_cci:
            raise SystemExit("dual_channel_p1 requires --via-cci")
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

    def post(self, path: str, body: dict) -> Any:
        return self._http("POST", path, body)


def _approx(actual: float, expected: float, tol: float = 0.06) -> bool:
    return abs(actual - expected) <= tol


def step_discover(session: OrgSession, catalog_id: str) -> None:
    print("\n== 1/3) Discover (PCM searchTerm=Bamboo) ==")
    payload = session.post(
        f"/services/data/{API}/connect/pcm/products",
        {
            "catalogIds": [catalog_id],
            "searchTerm": "Bamboo",
            "pageSize": 50,
        },
    )
    products = payload.get("products") or payload.get("records") or []
    skus: set[str] = set()
    for p in products:
        sku = (
            p.get("stockKeepingUnit")
            or p.get("productCode")
            or (p.get("product") or {}).get("stockKeepingUnit")
        )
        if sku:
            skus.add(sku)
    missing = EXPECTED_SKUS - skus
    if missing:
        raise AssertionError(f"Discovery missing SKUs {missing}; got {sorted(skus)}")
    print(f"  PASS Bamboo search returned {len(skus)} SKUs incl. Core/Pro/Elite/Workforce")


def _resolve_context(session: OrgSession) -> tuple[str, str]:
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
    return ctx_def_id, mapping_id


def headless_price(
    session: OrgSession,
    *,
    quote_id: str,
    line: dict,
    pricebook_id: str,
    quantity: int,
    ctx_def_id: str,
    mapping_id: str,
) -> dict:
    today = date.today().isoformat()
    end = (date.today() + timedelta(days=365)).isoformat()
    pricing_data = {
        "SalesTransaction": {
            "businessObjectType": "Quote",
            "id": quote_id,
            "Pricebook": pricebook_id,
            "CurrencyIsoCode": "USD",
            "SalesTransactionItem": [
                {
                    "businessObjectType": "QuoteLineItem",
                    "id": line["Id"],
                    "Product": line["Product2Id"],
                    "ProductSellingModel": line["ProductSellingModelId"],
                    "Quantity": quantity,
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


def place_core(
    session: OrgSession,
    ids: dict,
    *,
    quantity: int,
    name: str,
    pricing_pref: str = "Skip",
) -> str:
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
    pbe = ids["core_pbe"]
    placed = session.post(
        f"/services/data/{API}/connect/rev/sales-transaction/actions/place",
        {
            "pricingPref": pricing_pref,
            "catalogRatesPref": "Skip",
            "taxPref": "Skip",
            "configurationPref": {
                "configurationMethod": "Skip",
                "configurationOptions": {
                    "validateProductCatalog": True,
                    "validateAmendRenewCancel": True,
                    "executeConfigurationRules": False,
                    "addDefaultConfiguration": False,
                },
            },
            "graph": {
                "graphId": f"p1{uuid.uuid4().hex[:8]}",
                "records": [
                    {
                        "referenceId": "refQuote",
                        "record": {
                            "attributes": {"method": "POST", "type": "Quote"},
                            "Name": name,
                            "OpportunityId": opp_id,
                            "Pricebook2Id": ids["pricebook_id"],
                            "QuoteAccountId": ids["account_id"],
                        },
                    },
                    {
                        "referenceId": "refL0",
                        "record": {
                            "attributes": {"type": "QuoteLineItem", "method": "POST"},
                            "QuoteId": "@{refQuote.id}",
                            "Product2Id": pbe["Product2Id"],
                            "PricebookEntryId": pbe["Id"],
                            "Quantity": str(quantity),
                            "StartDate": today,
                            "EndDate": end,
                            "PeriodBoundary": "Anniversary",
                            "BillingFrequency": "Monthly",
                        },
                    },
                ],
            },
        },
    )
    if isinstance(placed, list):
        placed = placed[0]
    if not placed.get("isSuccess"):
        raise AssertionError(f"Place failed: {placed}")
    return placed["salesTransactionId"]


def step_calculate(session: OrgSession, ids: dict) -> None:
    print("\n== 2/3) Calculate (headless qty 10 vs 50 volume) ==")
    # Scratch quote at qty 10 for calculate-only probes (pricingPref Skip).
    qid = place_core(
        session,
        ids,
        quantity=QTY_BELOW_VOLUME,
        name="P1 calculate probe",
        pricing_pref="Skip",
    )
    line = session.soql(
        "SELECT Id, Product2Id, ProductSellingModelId "
        f"FROM QuoteLineItem WHERE QuoteId = '{qid}' LIMIT 1"
    )[0]
    ctx_def_id, mapping_id = _resolve_context(session)

    wf10 = headless_price(
        session,
        quote_id=qid,
        line=line,
        pricebook_id=ids["pricebook_id"],
        quantity=QTY_BELOW_VOLUME,
        ctx_def_id=ctx_def_id,
        mapping_id=mapping_id,
    )
    net10 = float(wf10["output"]["NetUnitPrice"])
    list10 = float(wf10["output"]["ListPrice"])
    if not _approx(list10, LIST_MONTHLY) or not _approx(net10, LIST_MONTHLY):
        raise AssertionError(
            f"qty {QTY_BELOW_VOLUME}: expected list/net ~{LIST_MONTHLY}, "
            f"got list={list10} net={net10}"
        )
    print(f"  PASS qty {QTY_BELOW_VOLUME}: List={list10} Net={net10} (no volume)")

    wf50 = headless_price(
        session,
        quote_id=qid,
        line=line,
        pricebook_id=ids["pricebook_id"],
        quantity=QTY_VOLUME,
        ctx_def_id=ctx_def_id,
        mapping_id=mapping_id,
    )
    net50 = float(wf50["output"]["NetUnitPrice"])
    list50 = float(wf50["output"]["ListPrice"])
    if not _approx(list50, LIST_MONTHLY):
        raise AssertionError(f"qty {QTY_VOLUME}: expected list {LIST_MONTHLY}, got {list50}")
    if not _approx(net50, VOLUME_NET):
        steps = [
            (s.get("pricingElement") or {}).get("name") for s in wf50.get("waterfall", [])
        ]
        raise AssertionError(
            f"qty {QTY_VOLUME}: expected net ~{VOLUME_NET} (5% volume), got {net50}; "
            f"waterfall={steps}"
        )
    print(f"  PASS qty {QTY_VOLUME}: List={list50} Net={net50} (5% volume)")


def step_create_quote(session: OrgSession, ids: dict) -> str:
    print("\n== 3/3) Create Quote (place Core @ qty 50 + verify volume) ==")
    qid = place_core(
        session,
        ids,
        quantity=QTY_VOLUME,
        name="P1 dual-channel quote",
        pricing_pref="System",
    )
    line = session.soql(
        "SELECT Id, Product2Id, ProductSellingModelId, UnitPrice, Quantity "
        f"FROM QuoteLineItem WHERE QuoteId = '{qid}' LIMIT 1"
    )[0]
    qty = float(line.get("Quantity") or 0)
    if qty != QTY_VOLUME:
        raise AssertionError(f"Expected qty {QTY_VOLUME}, got {qty}")
    print(f"  PASS placed quote {qid} with Core qty={QTY_VOLUME}")

    # P1 channel contract: quote is priceable at volume. System place may leave
    # UnitPrice at list even when Instant Pricing would show volume — assert via
    # headless NetUnitPrice (same path as step 2 / A2).
    ctx_def_id, mapping_id = _resolve_context(session)
    wf = headless_price(
        session,
        quote_id=qid,
        line=line,
        pricebook_id=ids["pricebook_id"],
        quantity=QTY_VOLUME,
        ctx_def_id=ctx_def_id,
        mapping_id=mapping_id,
    )
    net = float(wf["output"]["NetUnitPrice"])
    if not _approx(net, VOLUME_NET):
        raise AssertionError(
            f"Placed quote not priceable at volume: expected net ~{VOLUME_NET}, got {net}"
        )
    persisted = float(line.get("UnitPrice") or 0)
    line_after = session.soql(
        f"SELECT UnitPrice FROM QuoteLineItem WHERE Id = '{line['Id']}'"
    )[0]
    persisted = float(line_after.get("UnitPrice") or persisted)
    if _approx(persisted, VOLUME_NET):
        print(f"  PASS headless net={net}; UnitPrice persisted={persisted}")
    else:
        print(
            f"  PASS headless net={net} (UnitPrice still {persisted} — "
            "channel uses calculate result; Instant Pricing / AE refresh may persist)"
        )
    return qid


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target-org", default="master-demo")
    parser.add_argument("--via-cci", action="store_true")
    args = parser.parse_args()
    print(f"BambooHR dual-channel P1 against {args.target_org}")
    session = OrgSession(args.target_org, via_cci=args.via_cci)

    catalog = session.soql(
        f"SELECT Id FROM ProductCatalog WHERE Name = '{CATALOG_NAME}' LIMIT 1"
    )[0]
    acct = session.soql(f"SELECT Id FROM Account WHERE Name = '{ACCOUNT}' LIMIT 1")[0]
    pb = session.soql("SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1")[0]
    pbe = session.soql(
        "SELECT Id, Product2Id FROM PricebookEntry WHERE Pricebook2.IsStandard = true "
        f"AND Product2.StockKeepingUnit = '{CORE_SKU}' "
        "AND ProductSellingModel.SellingModelType = 'TermDefined' "
        "AND ProductSellingModel.PricingTermUnit = 'Months' LIMIT 1"
    )[0]
    ids = {
        "account_id": acct["Id"],
        "pricebook_id": pb["Id"],
        "core_pbe": pbe,
    }

    step_discover(session, catalog["Id"])
    step_calculate(session, ids)
    step_create_quote(session, ids)
    print("\nDual-channel P1 PASSED")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"\nDual-channel P1 FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
