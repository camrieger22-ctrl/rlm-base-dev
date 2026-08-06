#!/usr/bin/env python3
"""Verify AE further discount stacks on BambooHR nonprofit 15%.

SME requirement (E6): nonprofit 15% is the default starting point; AE must be
able to discount further on top.

Flow:
1. Place Quote on BambooHR Nonprofit Demo (System pricing → List 10 → Net 8.50)
2. Set QuoteLineItem.Discount = 10% (AE discretionary percent discount)
3. Reprice via headless pricing with Discount in the payload
4. Assert NetUnitPrice < 8.50 (≈ $7.65) with nonprofit still in the waterfall

Usage:
  ~/.local/pipx/venvs/cumulusci/bin/python \\
    scripts/bamboohr/nonprofit_further_discount_smoke.py --target-org master-demo
"""

from __future__ import annotations

import argparse
import json
import sys
import uuid
from datetime import date, timedelta
from pathlib import Path

# Reuse A2 helpers
sys.path.insert(0, str(Path(__file__).resolve().parent))
from api_smoke import (  # noqa: E402
    API,
    CORE_SKU,
    NONPROFIT_UNIT,
    NP_ACCOUNT,
    STANDARD_MONTHLY_LIST,
    api_post,
    api_request,
    create_record,
    resolve_ids,
    sf_json,
    soql,
)

# AE further discount as percentage (TLE Discount field). Amount path is awkward
# because System/nonprofit reprice leaves Discount=0, and the platform rejects
# setting DiscountAmount while Discount is non-null (even 0).
AE_DISCOUNT_PERCENT = 10.0
# After nonprofit 15% on $10 → $8.50; then 10% of that net → $7.65
EXPECTED_AFTER_AE = round(NONPROFIT_UNIT * (1 - AE_DISCOUNT_PERCENT / 100.0), 4)


def _ctx_ids(org: str) -> tuple[str, str]:
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
        raise RuntimeError("Could not resolve QuoteEntitiesMapping id")
    return ctx_def_id, mapping_id


def _headless_price(
    org: str,
    *,
    quote_id: str,
    line: dict,
    pricebook_id: str,
    ctx_def_id: str,
    mapping_id: str,
    item_extras: dict | None = None,
) -> tuple[float, float, dict]:
    today = date.today().isoformat()
    end = (date.today() + timedelta(days=365)).isoformat()
    item = {
        "businessObjectType": "QuoteLineItem",
        "id": line["Id"],
        "Product": line["Product2Id"],
        "ProductSellingModel": line["ProductSellingModelId"],
        "Quantity": 1,
        "SalesTransactionItemSource": "LINE_ITEM1",
        "EffectiveFrom": f"{today}T00:00:00.000Z",
        "EffectiveTo": f"{end}T00:00:00.000Z",
    }
    if item_extras:
        item.update(item_extras)
    pricing_data = {
        "SalesTransaction": {
            "businessObjectType": "Quote",
            "id": quote_id,
            "Pricebook": pricebook_id,
            "CurrencyIsoCode": "USD",
            "SalesTransactionItem": [item],
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
    return list_price, net, wf


def _waterfall_names(wf: dict) -> list[str]:
    names = []
    for step in wf.get("waterfall") or []:
        pe = step.get("pricingElement") or {}
        name = pe.get("name") or pe.get("label") or ""
        if name:
            names.append(name)
    return names


def place_nonprofit_quote(org: str, ids: dict) -> tuple[str, dict]:
    opp_id = create_record(
        org,
        "Opportunity",
        f"Name='Nonprofit Further Discount Smoke' AccountId={ids['np_id']} "
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
            "graphId": "npFurtherDiscount",
            "records": [
                {
                    "referenceId": "refQuote",
                    "record": {
                        "attributes": {"method": "POST", "type": "Quote"},
                        "Name": "Nonprofit Further Discount Smoke",
                        "OpportunityId": opp_id,
                        "Pricebook2Id": ids["pricebook_id"],
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
    q = soql(
        org,
        "SELECT Id, RLM_Is_Nonprofit_Account__c FROM Quote "
        f"WHERE Id = '{quote_id}'",
    )[0]
    if not q.get("RLM_Is_Nonprofit_Account__c"):
        raise AssertionError("Quote nonprofit formula false")
    line = soql(
        org,
        "SELECT Id, Product2Id, ProductSellingModelId, UnitPrice, ListPrice, "
        "Discount, DiscountAmount "
        f"FROM QuoteLineItem WHERE QuoteId = '{quote_id}'",
    )[0]
    return quote_id, line


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target-org", default="master-demo")
    args = parser.parse_args()
    org = args.target_org
    print(f"BambooHR nonprofit further-discount smoke against {org}")

    ids = resolve_ids(org)
    np = soql(
        org,
        "SELECT Id, RLM_Is_Nonprofit__c FROM Account "
        f"WHERE Name = '{NP_ACCOUNT}'",
    )[0]
    if not np.get("RLM_Is_Nonprofit__c"):
        raise AssertionError(f"{NP_ACCOUNT} missing RLM_Is_Nonprofit__c=true")
    print(f"  PASS account {NP_ACCOUNT} is nonprofit")

    quote_id, line = place_nonprofit_quote(org, ids)
    print(f"  PASS placed quote {quote_id}")

    ctx_def_id, mapping_id = _ctx_ids(org)

    list_price, net, wf = _headless_price(
        org,
        quote_id=quote_id,
        line=line,
        pricebook_id=ids["pricebook_id"],
        ctx_def_id=ctx_def_id,
        mapping_id=mapping_id,
    )
    if abs(list_price - STANDARD_MONTHLY_LIST) > 0.001:
        raise AssertionError(f"Expected list {STANDARD_MONTHLY_LIST}, got {list_price}")
    if abs(net - NONPROFIT_UNIT) > 0.001:
        raise AssertionError(f"Expected nonprofit net {NONPROFIT_UNIT}, got {net}")
    names = _waterfall_names(wf)
    if not any("Nonprofit" in n for n in names):
        raise AssertionError(f"Nonprofit step missing from waterfall: {names}")
    print(f"  PASS baseline nonprofit List={list_price} → Net={net}")

    # Persist AE percent discount on the line (TLE Discount field).
    sf_json(
        [
            "data",
            "update",
            "record",
            "--sobject",
            "QuoteLineItem",
            "--record-id",
            line["Id"],
            "--values",
            f"Discount={AE_DISCOUNT_PERCENT}",
        ],
        org,
    )
    line_updated = soql(
        org,
        "SELECT Id, Product2Id, ProductSellingModelId, Discount, UnitPrice "
        f"FROM QuoteLineItem WHERE Id = '{line['Id']}'",
    )[0]
    if abs(float(line_updated.get("Discount") or 0) - AE_DISCOUNT_PERCENT) > 0.001:
        raise AssertionError(f"Discount % not persisted: {line_updated.get('Discount')}")
    print(f"  PASS set Discount={AE_DISCOUNT_PERCENT}% on {line['Id']}")

    # Reprice with Discount mapped into ItemDiscountPercentage consumption path
    list2, net2, wf2 = _headless_price(
        org,
        quote_id=quote_id,
        line=line_updated,
        pricebook_id=ids["pricebook_id"],
        ctx_def_id=ctx_def_id,
        mapping_id=mapping_id,
        item_extras={"Discount": AE_DISCOUNT_PERCENT},
    )
    names2 = _waterfall_names(wf2)
    print(f"  waterfall after AE: {names2}")
    print(f"  net after AE: List={list2} Net={net2}")

    if net2 >= NONPROFIT_UNIT - 0.001:
        raise AssertionError(
            f"AE further discount did not stack. "
            f"Nonprofit net stayed {net2} (expected < {NONPROFIT_UNIT}). "
            f"Waterfall={names2}"
        )
    if abs(net2 - EXPECTED_AFTER_AE) > 0.08:
        print(
            f"  WARN net {net2} != exact {EXPECTED_AFTER_AE}, "
            "but further reduction confirmed"
        )
    else:
        print(
            f"  PASS AE percent discount stacked: "
            f"{NONPROFIT_UNIT} → {net2} (expected {EXPECTED_AFTER_AE})"
        )

    if not any("Nonprofit" in n for n in names2):
        raise AssertionError(
            f"Nonprofit step missing after AE reprice — overlay may have been skipped: {names2}"
        )
    if not any("percentagebaseddiscount" in n.lower() for n in names2):
        raise AssertionError(
            f"Percentage-based discount step missing from waterfall: {names2}"
        )

    # PST System reprice persists NetUnitPrice (UnitPrice stays at post-nonprofit
    # sales price; Discount % reduces Net — standard TLE waterfall display).
    _system_reprice_quote(org, quote_id, line["Id"])
    persisted = soql(
        org,
        "SELECT UnitPrice, NetUnitPrice, Discount, DiscountAmount "
        f"FROM QuoteLineItem WHERE Id = '{line['Id']}'",
    )[0]
    print(
        f"  persisted after System reprice UnitPrice={persisted['UnitPrice']} "
        f"NetUnitPrice={persisted['NetUnitPrice']} Discount={persisted['Discount']}"
    )
    if abs(float(persisted["UnitPrice"]) - NONPROFIT_UNIT) > 0.08:
        raise AssertionError(
            f"UnitPrice should remain nonprofit sales price {NONPROFIT_UNIT}, "
            f"got {persisted['UnitPrice']}"
        )
    if abs(float(persisted["NetUnitPrice"]) - EXPECTED_AFTER_AE) > 0.08:
        raise AssertionError(
            f"NetUnitPrice expected ~{EXPECTED_AFTER_AE}, got {persisted['NetUnitPrice']}"
        )

    print("\nNonprofit further-discount smoke PASSED")
    print(f"  Quote: {quote_id}")
    print(f"  SKU: {CORE_SKU}")
    return 0


def _system_reprice_quote(org: str, quote_id: str, line_id: str) -> None:
    """PST System reprice so AE Discount % persists onto UnitPrice."""
    body = {
        "pricingPref": "System",
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
            "graphId": f"npfd{uuid.uuid4().hex[:8]}",
            "records": [
                {
                    "referenceId": "refQuote",
                    "record": {
                        "attributes": {
                            "method": "PATCH",
                            "type": "Quote",
                            "id": quote_id,
                        }
                    },
                },
                {
                    "referenceId": "refL0",
                    "record": {
                        "attributes": {
                            "type": "QuoteLineItem",
                            "method": "PATCH",
                            "id": line_id,
                        },
                        "Quantity": "1",
                        "Discount": AE_DISCOUNT_PERCENT,
                    },
                },
            ],
        },
    }
    placed = api_post(
        org, f"/services/data/{API}/connect/rev/sales-transaction/actions/place", body
    )
    if isinstance(placed, list):
        placed = placed[0]
    if not placed.get("isSuccess"):
        raise AssertionError(f"System reprice failed: {placed}")
    print("  PASS PST System reprice after AE Discount")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"\nNonprofit further-discount smoke FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
