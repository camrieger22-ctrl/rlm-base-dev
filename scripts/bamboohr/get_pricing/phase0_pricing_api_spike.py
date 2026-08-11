#!/usr/bin/env python3
"""Phase 0 spike: Pricing API (headless) vs sticky Quote System reprice.

Question: can we price the rail with Salesforce Pricing without creating
Opportunity/Quote on every configure change?

Runs against master-demo (default):
1. Ephemeral headless pricing (synthetic Quote/QLI ids, Path B flags in payload)
2. Same config via PST place + System reprice (today's path)
3. Compare PEPM nets + wall-clock latency

Usage:
  ~/.local/pipx/venvs/cumulusci/bin/python \\
    scripts/bamboohr/get_pricing/phase0_pricing_api_spike.py --org master-demo
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import uuid
from datetime import date, timedelta
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from service import (  # noqa: E402
    API,
    ADDON_LIST_USD,
    OrgSession,
    PATH_B_BUNDLE_SAVE,
    PLAN_LIST_USD,
    _pbe_for_sku,
    _system_reprice_quote,
    expected_addon_net,
    expected_net,
    volume_rate,
)

SKUS = ("BAMBOO-PRO", "BAMBOO-ADD-PAYROLL", "BAMBOO-ADD-BENEFITS")
PATH_B_TARGETS = frozenset({"BAMBOO-ADD-PAYROLL", "BAMBOO-ADD-BENEFITS"})


def _ctx_ids(session: OrgSession) -> tuple[str, str]:
    ctx = session._http(
        "GET",
        f"/services/data/{API}/connect/context-definitions/RLM_SalesTransactionContext",
    )
    ctx_def_id = ctx["contextDefinitionId"]
    mapping_id = None
    for version in ctx.get("contextDefinitionVersionList") or []:
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


def _waterfall_nets(priced: dict) -> dict[str, dict[str, Any]]:
    """Parse headless output → {key: {list, net, steps, dataPath}}."""
    if isinstance(priced, list):
        priced = priced[0]
    if priced.get("isSuccess") is False:
        raise RuntimeError(f"Headless pricing failed: {priced}")
    outs = priced.get("outputValues") or {}
    if outs.get("pricingProcessStatus") != "Completed":
        raise RuntimeError(f"Headless pricing not Completed: {outs or priced}")
    result = json.loads(outs["pricingResult"])
    out: dict[str, dict[str, Any]] = {}
    for i, row in enumerate(result.get("PriceWaterFall") or []):
        lid = row.get("lineId") or row.get("id") or ""
        data_path = row.get("dataPath") or ""
        if isinstance(data_path, list):
            data_path = "/".join(str(p) for p in data_path)
        data_path = str(data_path)
        wf = json.loads(row["value"]) if isinstance(row.get("value"), str) else row.get("value")
        if not isinstance(wf, dict):
            continue
        steps = []
        for step in wf.get("waterfall") or []:
            pe = step.get("pricingElement") or {}
            name = pe.get("name") or pe.get("label") or ""
            if name:
                steps.append(name)
        output = wf.get("output") or {}
        key = str(lid) if lid else (data_path or f"line{i}")
        out[key] = {
            "list": float(output.get("ListPrice") or 0),
            "net": float(output.get("NetUnitPrice") or 0),
            "steps": steps,
            "dataPath": data_path,
            "raw": wf,
        }
    return out


def _match_nets_to_skus(
    nets: dict[str, dict[str, Any]], lines: list[dict[str, Any]]
) -> dict[str, float]:
    """Map waterfall rows to SKUs via ListPrice (unique in Bamboo demo catalog)."""
    by_list: dict[float, str] = {}
    for line in lines:
        by_list[round(float(line.get("list") or 0), 4)] = line["sku"]
    matched: dict[str, float] = {}
    for info in nets.values():
        sku = by_list.get(round(float(info["list"]), 4))
        if sku:
            matched[sku] = float(info["net"])
    return matched


def headless_price(
    session: OrgSession,
    *,
    ctx_def_id: str,
    mapping_id: str,
    pricebook_id: str,
    lines: list[dict[str, Any]],
    quote_id: str,
    path_b: bool,
    persist_context: bool,
    quantity: int,
) -> tuple[float, dict[str, dict[str, Any]], dict]:
    """Run runSalesforceHeadlessPricing; return (elapsed_s, nets_by_line_id, raw)."""
    today = date.today().isoformat()
    end = (date.today() + timedelta(days=365)).isoformat()
    items = []
    for i, line in enumerate(lines):
        item = {
            "businessObjectType": "QuoteLineItem",
            "id": line["id"],
            "Product": line["product2Id"],
            "ProductSellingModel": line["productSellingModelId"],
            "Quantity": int(quantity),
            "SalesTransactionItemSource": f"LINE_ITEM{i + 1}",
            "EffectiveFrom": f"{today}T00:00:00.000Z",
            "EffectiveTo": f"{end}T00:00:00.000Z",
            # Inline Path B target — may or may not hydrate without SObject.
            "RLM_Bamboo_BundleSave_Target__c": line["sku"] in PATH_B_TARGETS,
        }
        items.append(item)
    pricing_data = {
        "SalesTransaction": {
            "businessObjectType": "Quote",
            "id": quote_id,
            "Pricebook": pricebook_id,
            "CurrencyIsoCode": "USD",
            "RLM_Bamboo_PathB_BundleSave__c": bool(path_b),
            "SalesTransactionItem": items,
        }
    }
    body = {
        "inputs": [
            {
                "contextDefinitionId": ctx_def_id,
                "contextMappingId": mapping_id,
                "pricingProcedureId": "RLM_DefaultPricingProcedure",
                "skipDiscovery": True,
                "displayContext": True,
                "isSkipWaterfall": False,
                "persistContext": bool(persist_context),
                "useSessionScopedContext": False,
                "taggedData": False,
                "pricingData": json.dumps(pricing_data, separators=(",", ":")),
            }
        ]
    }
    t0 = time.perf_counter()
    priced = session.post(
        f"/services/data/{API}/actions/standard/runSalesforceHeadlessPricing",
        body,
    )
    elapsed = time.perf_counter() - t0
    return elapsed, _waterfall_nets(priced), priced if isinstance(priced, dict) else priced[0]


def place_and_system_reprice(
    session: OrgSession,
    *,
    account_id: str,
    pricebook_id: str,
    lines: list[dict[str, Any]],
    quantity: int,
) -> tuple[float, str, dict[str, float]]:
    """Today's path: Opp+Quote place (Skip) + System reprice. Returns nets by SKU."""
    today = date.today().isoformat()
    end = (date.today() + timedelta(days=365)).isoformat()
    opp = session.create(
        "Opportunity",
        {
            "Name": f"Phase0 spike {uuid.uuid4().hex[:6]}",
            "AccountId": account_id,
            "StageName": "Prospecting",
            "CloseDate": (date.today() + timedelta(days=30)).isoformat(),
            "Pricebook2Id": pricebook_id,
        },
    )
    records: list[dict[str, Any]] = [
        {
            "referenceId": "refQuote",
            "record": {
                "attributes": {"method": "POST", "type": "Quote"},
                "Name": "Phase0 Pricing API spike",
                "OpportunityId": opp,
                "Pricebook2Id": pricebook_id,
                "QuoteAccountId": account_id,
                "CurrencyIsoCode": "USD",
            },
        }
    ]
    for i, line in enumerate(lines):
        records.append(
            {
                "referenceId": f"refL{i}",
                "record": {
                    "attributes": {"type": "QuoteLineItem", "method": "POST"},
                    "QuoteId": "@{refQuote.id}",
                    "Product2Id": line["product2Id"],
                    "PricebookEntryId": line["pbeId"],
                    "Quantity": str(int(quantity)),
                    "StartDate": today,
                    "EndDate": end,
                    "PeriodBoundary": "Anniversary",
                    "BillingFrequency": "Monthly",
                },
            }
        )
    t0 = time.perf_counter()
    placed = session.post(
        f"/services/data/{API}/connect/rev/sales-transaction/actions/place",
        {
            "pricingPref": "Skip",
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
                "graphId": f"p0{uuid.uuid4().hex[:8]}",
                "records": records,
            },
        },
    )
    if isinstance(placed, list):
        placed = placed[0]
    if not placed.get("isSuccess"):
        raise RuntimeError(f"Place failed: {placed}")
    quote_id = placed["salesTransactionId"]
    # Apex Path B stamp runs on QLI insert; System reprice applies Bundle+volume.
    _system_reprice_quote(session, quote_id)
    elapsed = time.perf_counter() - t0
    qlines = session.soql(
        "SELECT Product2.StockKeepingUnit, NetUnitPrice, UnitPrice, ListPrice, "
        "RLM_Bamboo_BundleSave_Target__c "
        f"FROM QuoteLineItem WHERE QuoteId = '{quote_id}'"
    )
    nets = {
        ((r.get("Product2") or {}).get("StockKeepingUnit") or "").upper(): float(
            r.get("NetUnitPrice") or r.get("UnitPrice") or 0
        )
        for r in qlines
    }
    qflag = session.soql(
        f"SELECT RLM_Bamboo_PathB_BundleSave__c FROM Quote WHERE Id = '{quote_id}'"
    )
    path_b = bool(qflag and qflag[0].get("RLM_Bamboo_PathB_BundleSave__c"))
    print(f"    Quote {quote_id} PathB={path_b}")
    return elapsed, quote_id, nets


def expected_for(sku: str, qty: int, *, path_b: bool) -> float:
    if sku in PLAN_LIST_USD:
        return expected_net(sku, qty, "USD")
    return expected_addon_net(sku, path_b=path_b, currency="USD", headcount=qty)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--org", default="master-demo")
    parser.add_argument("--qty", type=int, default=50, help="Headcount for primary case")
    parser.add_argument(
        "--qty2", type=int, default=200, help="Second headcount (volume band change)"
    )
    parser.add_argument(
        "--account",
        default="",
        help="Account Id (default: Acme or first US commercial)",
    )
    args = parser.parse_args()

    print(f"Phase 0 Pricing API spike → org={args.org}")
    session = OrgSession(args.org)
    ctx_def_id, mapping_id = _ctx_ids(session)
    print(f"  Context def={ctx_def_id} mapping={mapping_id}")

    pb = session.soql("SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1")[0]["Id"]
    catalog_lines: list[dict[str, Any]] = []
    for sku in SKUS:
        pbe = _pbe_for_sku(session, sku, "USD")
        catalog_lines.append(
            {
                "sku": sku,
                "id": f"synth_{sku}_{uuid.uuid4().hex[:8]}",
                "product2Id": pbe["Product2Id"],
                "productSellingModelId": pbe["ProductSellingModelId"],
                "pbeId": pbe["Id"],
                "list": float(pbe["UnitPrice"]),
            }
        )
        print(f"  PBE {sku} list={pbe['UnitPrice']} psm={pbe['ProductSellingModelId']}")

    if args.account:
        account_id = args.account
    else:
        rows = session.soql(
            "SELECT Id, Name FROM Account WHERE Name = 'Acme' LIMIT 1"
        )
        if not rows:
            rows = session.soql(
                "SELECT Id, Name FROM Account WHERE BillingCountry = 'US' "
                "ORDER BY CreatedDate ASC LIMIT 1"
            )
        account_id = rows[0]["Id"]
        print(f"  Account {rows[0].get('Name')} ({account_id})")

    findings: list[str] = []
    results: dict[str, Any] = {
        "org": args.org,
        "skus": list(SKUS),
        "cases": [],
    }

    for qty in (args.qty, args.qty2):
        print(f"\n== Headcount {qty} (volume {volume_rate(qty) * 100:.0f}%) ==")
        expected = {sku: expected_for(sku, qty, path_b=True) for sku in SKUS}
        print("  Expected Bundle→volume:", expected)

        # --- A) Ephemeral headless (no real Quote) — one call, all lines ---
        synth_quote = f"0Q0PHASE0{uuid.uuid4().hex[:10].upper()}"
        print(f"\n  [A] Ephemeral headless multi-line (synthetic Quote {synth_quote})…")
        try:
            elapsed_a, nets_a, raw_a = headless_price(
                session,
                ctx_def_id=ctx_def_id,
                mapping_id=mapping_id,
                pricebook_id=pb,
                lines=catalog_lines,
                quote_id=synth_quote,
                path_b=True,
                persist_context=False,
                quantity=qty,
            )
            by_sku_a = _match_nets_to_skus(nets_a, catalog_lines)
            print(f"    elapsed={elapsed_a:.2f}s nets_by_sku={by_sku_a}")
            matches_a = {
                sku: abs(by_sku_a.get(sku, 0) - expected[sku]) < 0.08 for sku in SKUS
            }
            print(f"    match expected: {matches_a}")
            case_a = {
                "mode": "ephemeral_headless_multiline",
                "qty": qty,
                "elapsedSec": round(elapsed_a, 3),
                "netsBySku": by_sku_a,
                "expected": expected,
                "match": matches_a,
                "ok": all(matches_a.values()) and len(by_sku_a) == len(SKUS),
                "error": None,
            }
            if case_a["ok"]:
                findings.append(
                    f"qty={qty}: ephemeral multi-line MATCHED in {elapsed_a:.2f}s "
                    f"(no Quote created)"
                )
            else:
                findings.append(
                    f"qty={qty}: ephemeral multi-line incomplete/mismatch {by_sku_a}"
                )
        except Exception as exc:  # noqa: BLE001
            elapsed_a = None
            nets_a = {}
            case_a = {
                "mode": "ephemeral_headless_multiline",
                "qty": qty,
                "elapsedSec": None,
                "ok": False,
                "error": str(exc)[:500],
            }
            findings.append(f"qty={qty}: ephemeral FAILED: {exc}")
            print(f"    FAIL: {exc}")

        # --- A2) Per-SKU ephemeral (latency floor per line; not recommended) ---
        print("  [A2] Ephemeral per-SKU headless (serial — worst case)…")
        per_sku: dict[str, Any] = {}
        t_per = 0.0
        for line in catalog_lines:
            try:
                el, nets, _ = headless_price(
                    session,
                    ctx_def_id=ctx_def_id,
                    mapping_id=mapping_id,
                    pricebook_id=pb,
                    lines=[line],
                    quote_id=f"0Q0P0{uuid.uuid4().hex[:12].upper()}",
                    path_b=True,
                    persist_context=False,
                    quantity=qty,
                )
                t_per += el
                info = next(iter(nets.values())) if nets else None
                exp = expected[line["sku"]]
                match = info is not None and abs(info["net"] - exp) < 0.08
                per_sku[line["sku"]] = {
                    "net": None if not info else info["net"],
                    "list": None if not info else info["list"],
                    "expected": exp,
                    "match": match,
                    "steps": None if not info else info["steps"][:8],
                    "elapsedSec": round(el, 3),
                }
                print(
                    f"    {line['sku']}: net={None if not info else info['net']} "
                    f"expected={exp} match={match} ({el:.2f}s)"
                )
            except Exception as exc:  # noqa: BLE001
                per_sku[line["sku"]] = {"error": str(exc)[:300], "match": False}
                print(f"    {line['sku']}: FAIL {exc}")
        case_a2 = {
            "mode": "ephemeral_per_sku_serial",
            "qty": qty,
            "elapsedSecTotal": round(t_per, 3),
            "bySku": per_sku,
            "ok": all(v.get("match") for v in per_sku.values()),
        }
        findings.append(
            f"qty={qty}: per-SKU serial total {t_per:.2f}s "
            f"(use multi-line instead)"
        )

        # --- B) Quote + System reprice (baseline) ---
        print("  [B] Place Quote + System reprice…")
        try:
            elapsed_b, quote_id, nets_b = place_and_system_reprice(
                session,
                account_id=account_id,
                pricebook_id=pb,
                lines=catalog_lines,
                quantity=qty,
            )
            print(f"    elapsed={elapsed_b:.2f}s nets={nets_b}")
            matches_b = {
                sku: abs(nets_b.get(sku, 0) - expected[sku]) < 0.08 for sku in SKUS
            }
            print(f"    match expected: {matches_b}")
            case_b = {
                "mode": "quote_system_reprice",
                "qty": qty,
                "elapsedSec": round(elapsed_b, 3),
                "quoteId": quote_id,
                "nets": nets_b,
                "expected": expected,
                "match": matches_b,
                "ok": all(matches_b.values()),
            }
            findings.append(
                f"qty={qty}: Quote+System {elapsed_b:.2f}s "
                f"(match={all(matches_b.values())})"
            )
            # Optional: headless ON the real quote (still creates Quote first)
            print("  [C] Headless on real Quote (no extra System place)…")
            real_lines = session.soql(
                "SELECT Id, Product2Id, ProductSellingModelId, Product2.StockKeepingUnit "
                f"FROM QuoteLineItem WHERE QuoteId = '{quote_id}'"
            )
            hl_lines = [
                {
                    "sku": ((r.get("Product2") or {}).get("StockKeepingUnit") or "").upper(),
                    "id": r["Id"],
                    "product2Id": r["Product2Id"],
                    "productSellingModelId": r["ProductSellingModelId"],
                }
                for r in real_lines
            ]
            # price first add-on only for timing sample
            sample = next(l for l in hl_lines if l["sku"] in PATH_B_TARGETS)
            el_c, nets_c, _ = headless_price(
                session,
                ctx_def_id=ctx_def_id,
                mapping_id=mapping_id,
                pricebook_id=pb,
                lines=[sample],
                quote_id=quote_id,
                path_b=True,
                persist_context=False,
                quantity=qty,
            )
            info_c = next(iter(nets_c.values())) if nets_c else None
            print(
                f"    {sample['sku']} headless-on-quote: "
                f"net={None if not info_c else info_c['net']} ({el_c:.2f}s)"
            )
            case_c = {
                "mode": "headless_on_existing_quote",
                "qty": qty,
                "sku": sample["sku"],
                "elapsedSec": round(el_c, 3),
                "net": None if not info_c else info_c["net"],
                "steps": None if not info_c else info_c["steps"][:8],
            }
        except Exception as exc:  # noqa: BLE001
            case_b = {
                "mode": "quote_system_reprice",
                "qty": qty,
                "ok": False,
                "error": str(exc)[:500],
            }
            case_c = None
            findings.append(f"qty={qty}: Quote path FAILED: {exc}")
            print(f"    FAIL: {exc}")

        results["cases"].append(
            {"qty": qty, "A": case_a, "A2": case_a2, "B": case_b, "C": case_c}
        )

    # Verdict — prefer multi-line ephemeral success
    ephemeral_works = any(c.get("A", {}).get("ok") for c in results["cases"])
    quote_works = any(c.get("B", {}).get("ok") for c in results["cases"])
    best_eph = min(
        (
            c["A"]["elapsedSec"]
            for c in results["cases"]
            if c.get("A", {}).get("ok") and c["A"].get("elapsedSec")
        ),
        default=None,
    )
    best_quote = min(
        (
            c["B"]["elapsedSec"]
            for c in results["cases"]
            if c.get("B", {}).get("ok") and c["B"].get("elapsedSec")
        ),
        default=None,
    )
    if ephemeral_works and best_eph and best_quote:
        verdict = (
            f"GO — ephemeral multi-line headless matched Bundle→volume with no real "
            f"Quote (~{best_eph:.1f}s vs ~{best_quote:.1f}s Quote+System). "
            f"Use one Pricing API call for the rail; create Opp/Quote on Generate quote."
        )
    elif ephemeral_works:
        verdict = (
            "GO — ephemeral headless matched without a real Quote. "
            "Create Opp/Quote only on Generate quote."
        )
    elif quote_works:
        verdict = (
            "NO-GO for pure ephemeral — headless needs Quote SObject hydration "
            "in this org; use local rail OR headless-after-one-quote."
        )
    else:
        verdict = "BLOCKED — neither path matched expected nets; investigate org overlays"

    results["findings"] = findings
    results["verdict"] = verdict
    print("\n======== VERDICT ========")
    print(verdict)
    for f in findings:
        print(f"  - {f}")

    out = (
        Path(__file__).resolve().parents[3]
        / ".agents"
        / "artifacts"
        / "phase0-pricing-api-spike.md"
    )
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(
        "\n".join(
            [
                "# Phase 0 — Pricing API spike",
                "",
                f"**Org:** `{args.org}`",
                f"**SKUs:** {', '.join(SKUS)} (Path B a la carte)",
                f"**Verdict:** {verdict}",
                "",
                "## Findings",
                "",
                *[f"- {f}" for f in findings],
                "",
                "## Raw JSON",
                "",
                "```json",
                json.dumps(results, indent=2, default=str)[:120000],
                "```",
                "",
            ]
        ),
        encoding="utf-8",
    )
    print(f"\nWrote {out}")
    return 0 if ephemeral_works or quote_works else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"\nPhase 0 spike FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
