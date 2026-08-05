#!/usr/bin/env python3
"""BambooHR A2 API smoke: Discovery → Pricing → Quote.

Runs against a Salesforce org (default: master-demo) and asserts:

1. Discovery getCategories — US Add-ons qualified for Acme/US, not Prestige/CA
2. Discovery getProducts — BambooHR Core is returned and qualified
3. Place Sales Transaction quote with QuoteAccountId + System pricing
4. Headless pricing applies nonprofit 15% (List 10 → Net/Unit 8.5) on nonprofit account

Usage:
  python scripts/bamboohr/api_smoke.py --target-org master-demo
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from datetime import date, timedelta
from pathlib import Path

API = "v67.0"
CATALOG_NAME = "BambooHR"
CORE_SKU = "BAMBOO-CORE"
NP_ACCOUNT = "BambooHR Nonprofit Demo"
STANDARD_MONTHLY_LIST = 10.0
NONPROFIT_UNIT = 8.5


def run(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=check, capture_output=True, text=True)


def _loads_json_payload(text: str) -> dict:
    """Parse sf --json output that may include leading warnings or multiple docs."""
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


def sf_json(args: list[str], org: str) -> dict:
    cp = run(["sf", *args, "--target-org", org, "--json"], check=False)
    payload = (cp.stdout or "") + "\n" + (cp.stderr or "")
    if cp.returncode != 0:
        raise RuntimeError(f"sf {' '.join(args)} failed:\n{payload[:3000]}")
    return _loads_json_payload(payload)


def soql(org: str, query: str) -> list[dict]:
    return sf_json(["data", "query", "-q", query], org)["result"]["records"]


def create_record(org: str, sobject: str, values: str) -> str:
    result = sf_json(["data", "create", "record", "--sobject", sobject, "--values", values], org)
    return result["result"]["id"]


def api_request(org: str, path: str, method: str = "GET", body: dict | None = None) -> dict:
    cmd = [
        "sf",
        "api",
        "request",
        "rest",
        path,
        "--method",
        method,
        "--target-org",
        org,
    ]
    body_path = None
    if body is not None:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(body, f)
            body_path = f.name
        cmd.extend(["--body", f"@{body_path}"])
    cp = run(cmd, check=False)
    if body_path:
        Path(body_path).unlink(missing_ok=True)
    raw = (cp.stdout or "") + "\n" + (cp.stderr or "")
    try:
        return _loads_json_payload(raw)
    except RuntimeError as exc:
        raise RuntimeError(f"No JSON in API response for {path}:\n{raw[:2000]}") from exc


def api_post(org: str, path: str, body: dict) -> dict:
    return api_request(org, path, method="POST", body=body)


def apex_run(org: str, apex: str) -> str:
    with tempfile.NamedTemporaryFile("w", suffix=".apex", delete=False) as f:
        f.write(apex)
        path = f.name
    cp = run(["sf", "apex", "run", "--file", path, "--target-org", org], check=False)
    Path(path).unlink(missing_ok=True)
    out = (cp.stdout or "") + (cp.stderr or "")
    if cp.returncode != 0 and "USER_DEBUG" not in out:
        raise RuntimeError(f"Apex failed:\n{out[:3000]}")
    return out


def parse_debug_flags(log: str, prefix: str) -> list[str]:
    return re.findall(rf"DEBUG\|{re.escape(prefix)}(.+)", log)


def step_discovery(org: str, ids: dict) -> None:
    print("\n== 1) Discovery (getCategories + getProducts) ==")
    apex = f"""
String catalogId = '{ids["catalog_id"]}';
String parentAddons = '{ids["addons_category_id"]}';
Id prestigeId = '{ids["prestige_id"]}';
Id acmeId = '{ids["acme_id"]}';
Id npId = '{ids["np_id"]}';
String pbId = '{ids["pricebook_id"]}';

for (String label : new List<String>{{'Prestige', 'Acme'}}) {{
  Id acct = label == 'Prestige' ? prestigeId : acmeId;
  Invocable.Action action = Invocable.Action.createStandardAction('getCategories');
  ConnectApi.UserContextInputRepresentation uc = new ConnectApi.UserContextInputRepresentation();
  uc.accountId = acct;
  action.setInvocationParameter('catalogId', catalogId);
  action.setInvocationParameter('parentCategoryId', parentAddons);
  action.setInvocationParameter('userContextInputRepresentation', uc);
  action.setInvocationParameter('enableQualificationProcedure', true);
  List<Invocable.Action.Result> results = action.invoke();
  System.debug('CAT_' + label + '_OK=' + results[0].isSuccess());
  if (!results[0].isSuccess()) {{
    System.debug('CAT_' + label + '_ERR=' + results[0].getErrors());
    continue;
  }}
  String js = JSON.serialize(results[0].getOutputParameters());
  Integer i = js.indexOf('US Add-ons');
  if (i < 0) {{
    System.debug('CAT_' + label + '_QUAL=MISSING');
  }} else {{
    Integer start = Math.max(0, i - 120);
    System.debug('CAT_' + label + '_SNIP=' + js.substring(start, Math.min(js.length(), i + 80)));
  }}
}}

Invocable.Action gp = Invocable.Action.createStandardAction('getProducts');
ConnectApi.UserContextInputRepresentation uc2 = new ConnectApi.UserContextInputRepresentation();
uc2.accountId = npId;
gp.setInvocationParameter('catalogId', catalogId);
gp.setInvocationParameter('userContextInputRepresentation', uc2);
gp.setInvocationParameter('priceBookId', pbId);
gp.setInvocationParameter('currencyCode', 'USD');
gp.setInvocationParameter('enablePricing', true);
gp.setInvocationParameter('enableQualification', true);
gp.setInvocationParameter('limit', 50);
List<Invocable.Action.Result> gpRes = gp.invoke();
System.debug('PROD_OK=' + gpRes[0].isSuccess());
if (!gpRes[0].isSuccess()) {{
  System.debug('PROD_ERR=' + gpRes[0].getErrors());
}} else {{
  String js = JSON.serialize(gpRes[0].getOutputParameters().get('results'));
  Integer i = js.indexOf('BambooHR Core');
  System.debug('PROD_CORE=' + (i >= 0));
  if (i >= 0) {{
    Integer p = js.lastIndexOf('"prices"', i);
    System.debug('PROD_PRICES=' + (p >= 0 ? js.substring(p, Math.min(js.length(), p + 350)) : 'none'));
  }}
}}
"""
    log = apex_run(org, apex)
    prestige = "\n".join(parse_debug_flags(log, "CAT_Prestige_SNIP="))
    acme = "\n".join(parse_debug_flags(log, "CAT_Acme_SNIP="))
    if '"isQualified":false' not in prestige and "isQualified\":false" not in prestige:
        raise AssertionError(f"Prestige/CA should disqualify US Add-ons. snip={prestige!r}")
    if '"isQualified":true' not in acme and "isQualified\":true" not in acme:
        raise AssertionError(f"Acme/US should qualify US Add-ons. snip={acme!r}")
    if "PROD_OK=true" not in log:
        raise AssertionError("getProducts failed:\n" + log[-2000:])
    if "PROD_CORE=true" not in log:
        raise AssertionError("BambooHR Core not returned by getProducts")
    print("  PASS getCategories Prestige isQualified=false, Acme=true")
    print("  PASS getProducts returns BambooHR Core (list PBE prices)")


def step_quote_and_price(org: str, ids: dict) -> str:
    print("\n== 2/3) Place Quote + Headless Pricing ==")
    opp_id = create_record(
        org,
        "Opportunity",
        f"Name='A2 API Smoke Opp' AccountId={ids['np_id']} "
        f"StageName=Prospecting CloseDate=2026-12-31 Pricebook2Id={ids['pricebook_id']}",
    )
    today = date.today().isoformat()
    end = (date.today() + timedelta(days=365)).isoformat()
    body = {
        "pricingPref": "System",
        "catalogRatesPref": "Skip",
        "configurationPref": {
            "configurationMethod": "Skip",
            "configurationOptions": {
                "validateProductCatalog": True,
                "validateAmendRenewCancel": True,
                "executeConfigurationRules": False,
                "addDefaultConfiguration": False,
            },
        },
        "taxPref": "Skip",
        "graph": {
            "graphId": "a2BambooSmoke",
            "records": [
                {
                    "referenceId": "refQuote",
                    "record": {
                        "attributes": {"method": "POST", "type": "Quote"},
                        "Name": "A2 API Smoke BambooHR Nonprofit",
                        "OpportunityId": opp_id,
                        "Pricebook2Id": ids["pricebook_id"],
                        # Required for QuoteAccount.* formulas / RLM context
                        "QuoteAccountId": ids["np_id"],
                    },
                },
                {
                    "referenceId": "refQuoteLine0",
                    "record": {
                        "attributes": {"type": "QuoteLineItem", "method": "POST"},
                        "QuoteId": "@{refQuote.id}",
                        "Product2Id": ids["core_product_id"],
                        "PricebookEntryId": ids["core_pbe_id"],
                        "Quantity": "1",
                        "StartDate": today,
                        "EndDate": end,
                        "PeriodBoundary": "Anniversary",
                        "BillingFrequency": "Monthly",
                    },
                },
            ],
        },
    }
    placed = api_post(
        org, f"/services/data/{API}/connect/rev/sales-transaction/actions/place", body
    )
    if not placed.get("isSuccess"):
        raise AssertionError(f"Place sales transaction failed: {placed}")
    quote_id = placed["salesTransactionId"]
    print(f"  PASS place quote {quote_id}")

    q = soql(
        org,
        "SELECT Id, RLM_Is_Nonprofit_Account__c, QuoteAccountId "
        f"FROM Quote WHERE Id = '{quote_id}'",
    )[0]
    if not q.get("RLM_Is_Nonprofit_Account__c"):
        raise AssertionError(
            "Quote.RLM_Is_Nonprofit_Account__c is false — set QuoteAccountId "
            "(and/or Opportunity.Account nonprofit). "
            f"QuoteAccountId={q.get('QuoteAccountId')}"
        )
    print("  PASS Quote nonprofit formula true")

    line = soql(
        org,
        "SELECT Id, Product2Id, ProductSellingModelId, UnitPrice, ListPrice "
        f"FROM QuoteLineItem WHERE QuoteId = '{quote_id}'",
    )[0]

    ctx_payload = api_request(
        org, f"/services/data/{API}/connect/context-definitions/RLM_SalesTransactionContext"
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
        raise RuntimeError(
            "Could not resolve QuoteEntitiesMapping id from "
            "RLM_SalesTransactionContext Connect payload."
        )

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
                    "Quantity": 1,
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
    priced = api_post(
        org, f"/services/data/{API}/actions/standard/runSalesforceHeadlessPricing", price_body
    )
    if isinstance(priced, list):
        priced = priced[0]
    if priced.get("isSuccess") is False:
        raise AssertionError(f"Headless pricing failed: {priced}")
    outs = priced.get("outputValues") or {}
    if outs.get("pricingProcessStatus") != "Completed":
        raise AssertionError(f"Headless pricing failed: {outs or priced}")

    wf = json.loads(json.loads(outs["pricingResult"])["PriceWaterFall"][0]["value"])
    net = float(wf["output"]["NetUnitPrice"])
    list_price = float(wf["output"]["ListPrice"])
    if list_price != STANDARD_MONTHLY_LIST:
        raise AssertionError(f"Expected list {STANDARD_MONTHLY_LIST}, got {list_price}")
    if abs(net - NONPROFIT_UNIT) > 0.001:
        raise AssertionError(f"Expected nonprofit net {NONPROFIT_UNIT}, got {net}")

    nonprofit_step = any(
        "Nonprofit" in ((s.get("pricingElement") or {}).get("name") or "")
        for s in wf.get("waterfall", [])
    )
    if not nonprofit_step:
        raise AssertionError("Nonprofit ManualDiscount step missing from waterfall")

    line_after = soql(
        org,
        f"SELECT UnitPrice, ListPrice FROM QuoteLineItem WHERE Id = '{line['Id']}'",
    )[0]
    if abs(float(line_after["UnitPrice"]) - NONPROFIT_UNIT) > 0.001:
        raise AssertionError(
            f"Persisted UnitPrice expected {NONPROFIT_UNIT}, got {line_after['UnitPrice']}"
        )

    print(f"  PASS headless pricing List={list_price} → Unit/Net={net}")
    print(f"  PASS persisted UnitPrice={line_after['UnitPrice']} on {quote_id}")
    return quote_id


def resolve_ids(org: str) -> dict:
    catalog = soql(org, f"SELECT Id FROM ProductCatalog WHERE Name = '{CATALOG_NAME}' LIMIT 1")[0]
    addons = soql(org, "SELECT Id FROM ProductCategory WHERE Code = 'PC-BH-ADDONS' LIMIT 1")[0]
    core = soql(
        org, f"SELECT Id FROM Product2 WHERE StockKeepingUnit = '{CORE_SKU}' LIMIT 1"
    )[0]
    pbe = soql(
        org,
        "SELECT Id FROM PricebookEntry WHERE Pricebook2.IsStandard = true "
        f"AND Product2.StockKeepingUnit = '{CORE_SKU}' "
        "AND ProductSellingModel.SellingModelType = 'TermDefined' "
        "AND ProductSellingModel.PricingTermUnit = 'Months' LIMIT 1",
    )[0]
    pb = soql(org, "SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1")[0]
    accounts = {
        r["Name"]: r["Id"]
        for r in soql(
            org,
            "SELECT Id, Name FROM Account WHERE Name IN "
            f"('{NP_ACCOUNT}','Acme','Prestige Worldwide')",
        )
    }
    for required in (NP_ACCOUNT, "Acme", "Prestige Worldwide"):
        if required not in accounts:
            raise RuntimeError(f"Missing account {required}")
    return {
        "catalog_id": catalog["Id"],
        "addons_category_id": addons["Id"],
        "core_product_id": core["Id"],
        "core_pbe_id": pbe["Id"],
        "pricebook_id": pb["Id"],
        "np_id": accounts[NP_ACCOUNT],
        "acme_id": accounts["Acme"],
        "prestige_id": accounts["Prestige Worldwide"],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target-org", default="master-demo")
    args = parser.parse_args()
    org = args.target_org
    print(f"BambooHR A2 API smoke against {org}")
    ids = resolve_ids(org)
    step_discovery(org, ids)
    quote_id = step_quote_and_price(org, ids)
    print("\nA2 API smoke PASSED")
    print(f"  Quote: {quote_id}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001 — CLI entrypoint
        print(f"\nA2 API smoke FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
