#!/usr/bin/env python3
"""BambooHR A4 smoke: Core XOR Pro XOR Elite.

Asserts (default):

1. Package Path A — PCG-BH-BASE Min/Max Bundle Components = 1
2. CML model BambooHrPlans_V1 is Active

Optional (--path-b):

3. A la carte Core+Pro → configurator returns the mutual-exclusivity message
4. A la carte Core alone → that message is absent

Use --path-b on a clean org after import_cml. Some orgs retain a sticky
configurator compile cache from earlier BambooHR experiments (old message
string); Path B asserts the current CML message only.

Usage:
  python scripts/bamboohr/plan_exclusivity_smoke.py --target-org master-demo --via-cci
  python scripts/bamboohr/plan_exclusivity_smoke.py --target-org master-demo --via-cci --path-b
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
EXCLUSIVITY_MSG = "BambooHR plans are mutually exclusive — choose Core, Pro, or Elite."
# Legacy string from early master-demo experiments (sticky compile cache).
PHANTOM_MSG = "Select only one BambooHR plan (Core, Pro, or Elite)."
ACCOUNT = "Acme"
MODEL_VERSION = "BambooHrPlans_V1"


class OrgSession:
    def __init__(self, alias: str, *, via_cci: bool = False) -> None:
        if not via_cci:
            raise SystemExit("plan_exclusivity_smoke requires --via-cci")
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

    def post(self, path: str, body: dict) -> dict:
        return self._http("POST", path, body)


def step_pcg(session: OrgSession) -> None:
    print("\n== 1) Package PCG-BH-BASE min/max = 1 ==")
    rows = session.soql(
        "SELECT Code, MinBundleComponents, MaxBundleComponents "
        "FROM ProductComponentGroup "
        "WHERE ParentProduct.StockKeepingUnit = 'BAMBOO-PKG-WORKFORCE' "
        "AND Code = 'PCG-BH-BASE'"
    )
    if not rows:
        raise AssertionError("PCG-BH-BASE missing on Workforce package")
    r = rows[0]
    if r.get("MinBundleComponents") != 1 or r.get("MaxBundleComponents") != 1:
        raise AssertionError(f"PCG-BH-BASE expected 1/1, got {r}")
    print("  PASS PCG-BH-BASE MinBundleComponents=1 MaxBundleComponents=1")


def step_model_active(session: OrgSession) -> None:
    print(f"\n== 2) {MODEL_VERSION} Active ==")
    rows = session.soql(
        "SELECT DeveloperName, Status FROM ExpressionSetDefinitionVersion "
        f"WHERE DeveloperName = '{MODEL_VERSION}'"
    )
    if not rows:
        raise AssertionError(f"{MODEL_VERSION} not found — run import_cml")
    if rows[0].get("Status") != "Active":
        raise AssertionError(
            f"{MODEL_VERSION} Status={rows[0].get('Status')} — activate_versions required"
        )
    print(f"  PASS {MODEL_VERSION} Active")


def _pbe(session: OrgSession, sku: str) -> dict:
    return session.soql(
        "SELECT Id, Product2Id FROM PricebookEntry WHERE Pricebook2.IsStandard = true "
        f"AND Product2.StockKeepingUnit = '{sku}' "
        "AND ProductSellingModel.SellingModelType = 'TermDefined' "
        "AND ProductSellingModel.PricingTermUnit = 'Months' LIMIT 1"
    )[0]


def place_plans(session: OrgSession, ids: dict, skus: list[str]) -> str:
    opp_id = session.create(
        "Opportunity",
        {
            "Name": f"A4 exclusivity {'+'.join(skus)}",
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
                "Name": f"A4 {'+'.join(skus)}",
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
    placed = session.post(
        f"/services/data/{API}/connect/rev/sales-transaction/actions/place",
        {
            "pricingPref": "System",
            "catalogRatesPref": "Skip",
            "taxPref": "Skip",
            "configurationPref": {
                "configurationMethod": "System",
                "configurationOptions": {
                    "validateProductCatalog": True,
                    "validateAmendRenewCancel": True,
                    "executeConfigurationRules": True,
                    "addDefaultConfiguration": False,
                },
            },
            "graph": {"graphId": f"a4{uuid.uuid4().hex[:8]}", "records": records},
        },
    )
    if not placed.get("isSuccess"):
        raise AssertionError(f"Place failed: {placed}")
    return placed["salesTransactionId"]


def configure(session: OrgSession, quote_id: str, line_id: str) -> dict:
    return session.post(
        f"/services/data/{API}/connect/cpq/configurator/actions/configure",
        {
            "transactionId": quote_id,
            "transactionLineId": line_id,
            "correlationId": str(uuid.uuid4()),
            "configuratorOptions": {
                "executeConfigurationRules": True,
                "validateProductCatalog": True,
            },
        },
    )


def _msgs_for_quote(cfg: dict, quote_id: str) -> list[str]:
    messages = cfg.get("messages") or {}
    entries = messages.get(quote_id) or []
    return [m.get("message") for m in entries if isinstance(m, dict) and m.get("message")]


def step_two_plans_error(session: OrgSession, ids: dict) -> None:
    print("\n== 3) A la carte Core+Pro → exclusivity error ==")
    qid = place_plans(session, ids, ["BAMBOO-CORE", "BAMBOO-PRO"])
    line = session.soql(
        f"SELECT Id FROM QuoteLineItem WHERE QuoteId = '{qid}' LIMIT 1"
    )[0]
    cfg = configure(session, qid, line["Id"])
    msgs = _msgs_for_quote(cfg, qid)
    if EXCLUSIVITY_MSG not in msgs:
        hint = ""
        if PHANTOM_MSG in msgs and EXCLUSIVITY_MSG not in msgs:
            hint = (
                " (only sticky legacy message seen — org compile cache may be "
                "contaminated; see .agents/artifacts/bamboohr-a4-plan-exclusivity.md)"
            )
        raise AssertionError(
            f"Missing exclusivity message on {qid}; "
            f"solver={cfg.get('solverStatus')} msgs={msgs}{hint}"
        )
    print(f"  PASS exclusivity message on Core+Pro (solver={cfg.get('solverStatus')})")
    print(f"  quote {qid}")


def step_one_plan_ok(session: OrgSession, ids: dict) -> None:
    print("\n== 4) A la carte Core alone → no exclusivity error ==")
    qid = place_plans(session, ids, ["BAMBOO-CORE"])
    line = session.soql(
        f"SELECT Id FROM QuoteLineItem WHERE QuoteId = '{qid}' LIMIT 1"
    )[0]
    cfg = configure(session, qid, line["Id"])
    msgs = _msgs_for_quote(cfg, qid)
    if EXCLUSIVITY_MSG in msgs:
        raise AssertionError(f"Unexpected exclusivity error on single plan {qid}: {msgs}")
    if PHANTOM_MSG in msgs:
        raise AssertionError(
            f"Sticky legacy exclusivity message on single plan {qid}: {msgs}. "
            "Deactivate/wipe BambooHR models does not clear this on contaminated orgs; "
            "verify Path B on a clean scratch after prepare_bamboohr."
        )
    print(
        f"  PASS single-plan configure (no exclusivity message; "
        f"solver={cfg.get('solverStatus')}) quote {qid}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target-org", default="master-demo")
    parser.add_argument("--via-cci", action="store_true")
    parser.add_argument(
        "--path-b",
        action="store_true",
        help="Also run a la carte configurator exclusivity checks",
    )
    args = parser.parse_args()
    print(f"BambooHR A4 plan exclusivity smoke against {args.target_org}")
    session = OrgSession(args.target_org, via_cci=args.via_cci)
    step_pcg(session)
    step_model_active(session)
    if args.path_b:
        acct = session.soql(f"SELECT Id FROM Account WHERE Name = '{ACCOUNT}' LIMIT 1")[0]
        pb = session.soql("SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1")[0]
        ids = {
            "account_id": acct["Id"],
            "pricebook_id": pb["Id"],
            "pbes": {
                "BAMBOO-CORE": _pbe(session, "BAMBOO-CORE"),
                "BAMBOO-PRO": _pbe(session, "BAMBOO-PRO"),
            },
        }
        step_two_plans_error(session, ids)
        step_one_plan_ok(session, ids)
    else:
        print("\n(skip Path B configurator checks — pass --path-b to run)")
    print("\nA4 plan exclusivity smoke PASSED")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"\nA4 plan exclusivity smoke FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
