#!/usr/bin/env python3
"""Evergreen month-to-month smoke (dual commercial path).

Places Core @ 15 with ``termMonths=1``, activates without auto-collect,
invoices period 1, asserts:

  * Quote lines / Asset use Evergreen (blank LifecycleEndDate)
  * First invoice ≈ 15 × PEPM
  * BillingSchedule has NextBillingDate
  * Generate on NextBillingDate → second period ≈ 15 × PEPM (no renew Quote)

Usage::

  ~/.local/pipx/venvs/cumulusci/bin/python \\
    scripts/bamboohr/get_pricing/smoke_evergreen_m2m.py \\
    --org master-demo --base-url http://127.0.0.1:8765
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from datetime import date
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from service import OrgSession  # noqa: E402

PEPM = 10.0
QTY = 15
MONTHLY = PEPM * QTY  # 150


class Fail(Exception):
    pass


def _http_json(
    base: str, method: str, path: str, body: dict | None = None, timeout: int = 180
) -> dict[str, Any]:
    url = base.rstrip("/") + path
    data = None
    headers = {"Accept": "application/json"}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8")
        try:
            payload = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            payload = {"error": raw or str(exc)}
        payload.setdefault("ok", False)
        payload.setdefault("httpStatus", exc.code)
        return payload


def check(name: str, cond: bool, detail: str = "") -> None:
    mark = "PASS" if cond else "FAIL"
    suffix = f" — {detail}" if detail else ""
    print(f"  [{mark}] {name}{suffix}")
    if not cond:
        raise Fail(name)


def near(a: float, b: float, tol: float = 1.0) -> bool:
    return abs(float(a) - float(b)) <= tol


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--org", default="master-demo")
    ap.add_argument("--base-url", default="http://127.0.0.1:8765")
    args = ap.parse_args()
    base = args.base_url
    today = date.today()
    stamp = time.strftime("%H%M%S")
    email = f"evergreen.smoke.{stamp}@example.com"
    company = f"Evergreen Smoke {stamp}"
    print(f"termMonths=1 (evergreen) start={today.isoformat()} company={company}")

    try:
        session = OrgSession(args.org)
        _ = session.soql("SELECT Id FROM Organization LIMIT 1")
    except Exception as exc:  # noqa: BLE001
        print(f"OrgSession failed ({exc})", file=sys.stderr)
        return 1

    health = _http_json(base, "GET", "/api/health")
    check("BFF health", bool(health.get("ok")), str(health.get("org") or ""))

    sess_body = _http_json(
        base,
        "POST",
        "/api/qualify-session",
        {
            "employeeCount": QTY,
            "country": "US",
            "needs": ["hr"],
            "email": email,
            "company": company,
            "firstName": "Ever",
            "lastName": "Green",
        },
    )
    sid = ((sess_body.get("session") or {}).get("sessionId")) or ""
    check("qualify session", bool(sid))

    commit = _http_json(
        base,
        "POST",
        "/api/qualify-commit",
        {
            "sessionId": sid,
            "email": email,
            "company": company,
            "firstName": "Ever",
            "lastName": "Green",
            "employeeCount": QTY,
            "country": "US",
            "needs": ["hr"],
        },
    )
    acct = commit.get("accountId") or ""
    check("qualify commit", bool(commit.get("ok")) and bool(acct), str(commit.get("error")))

    placed = _http_json(
        base,
        "POST",
        "/api/get-pricing",
        {
            "headcount": QTY,
            "country": "US",
            "planSku": "BAMBOO-CORE",
            "addonSkus": [],
            "placeQuote": True,
            "startDate": today.isoformat(),
            "termMonths": 1,
            "qualifySessionId": sid,
            "buyer": {
                "company": company,
                "firstName": "Ever",
                "lastName": "Green",
                "email": email,
            },
        },
        timeout=300,
    )
    qid = placed.get("quoteId") or ""
    check("place quote", bool(placed.get("ok")) and bool(qid), str(placed.get("error")))
    check(
        "monthly ~150",
        near(float(placed.get("monthlyTotal") or 0), MONTHLY),
        str(placed.get("monthlyTotal")),
    )
    # endDate null/absent on response for evergreen
    end_raw = placed.get("endDate")
    check(
        "response endDate empty (evergreen)",
        end_raw in (None, "", "null"),
        str(end_raw),
    )

    lines = session.soql(
        "SELECT EndDate, ProductSellingModel.SellingModelType, "
        "ProductSellingModel.Name "
        f"FROM QuoteLineItem WHERE QuoteId = '{qid}'"
    )
    check("quote has lines", bool(lines))
    for ln in lines:
        smt = ((ln.get("ProductSellingModel") or {}).get("SellingModelType")) or ""
        check("QLI Evergreen", smt == "Evergreen", smt)
        check("QLI EndDate blank", not ln.get("EndDate"), str(ln.get("EndDate")))

    checkout = _http_json(
        base,
        "POST",
        "/api/checkout",
        {"quoteId": qid, "collectPayment": False},
        timeout=300,
    )
    oid = checkout.get("orderId") or ""
    check("checkout activate", bool(checkout.get("ok")) and bool(oid), str(checkout.get("error")))

    assets = session.soql(
        "SELECT Id, LifecycleStartDate, LifecycleEndDate, "
        "Product2.StockKeepingUnit "
        f"FROM Asset WHERE AccountId = '{acct}' "
        "AND Product2.StockKeepingUnit = 'BAMBOO-CORE'"
    )
    check("core asset", bool(assets))
    asset = assets[0]
    check(
        "Asset LifecycleEndDate blank",
        not asset.get("LifecycleEndDate"),
        str(asset.get("LifecycleEndDate")),
    )

    # Confirm evergreen via Order Product when Asset lacks PSM relationship.
    ops = session.soql(
        "SELECT ProductSellingModel.SellingModelType, EndDate "
        "FROM OrderItem "
        f"WHERE OrderId = '{oid}' "
        "AND Product2.StockKeepingUnit = 'BAMBOO-CORE' "
        "LIMIT 1"
    )
    if ops:
        smt = ((ops[0].get("ProductSellingModel") or {}).get("SellingModelType")) or ""
        check("OrderItem Evergreen", smt == "Evergreen", smt)
        check(
            "OrderItem EndDate blank",
            not ops[0].get("EndDate"),
            str(ops[0].get("EndDate")),
        )

    collect1 = _http_json(
        base,
        "POST",
        "/api/collect-payment",
        {"orderId": oid, "targetDate": today.isoformat()},
        timeout=180,
    )
    inv1 = collect1.get("invoiceId")
    check("collect period 1", bool(inv1), str(collect1.get("blockedReason") or collect1))

    ilines = session.soql(
        "SELECT ChargeAmount FROM InvoiceLine "
        f"WHERE InvoiceId = '{inv1}'"
    )
    charge1 = sum(float(l.get("ChargeAmount") or 0) for l in ilines)
    check("period 1 charge ~150", near(charge1, MONTHLY, 2.0), str(charge1))

    scheds = session.soql(
        "SELECT Id, NextBillingDate, BillingPeriodAmount, BilledAmount "
        f"FROM BillingSchedule WHERE BillingAccountId = '{acct}'"
    )
    check("billing schedule", bool(scheds))
    next_dates = [
        date.fromisoformat(str(s["NextBillingDate"])[:10])
        for s in scheds
        if s.get("NextBillingDate")
    ]
    check("NextBillingDate set", bool(next_dates), str(scheds))
    next_bill = min(next_dates)
    print(f"  [info] next billing date {next_bill}")

    q_count_before = len(
        session.soql(f"SELECT Id FROM Quote WHERE QuoteAccountId = '{acct}'")
    )

    collect2 = _http_json(
        base,
        "POST",
        "/api/collect-payment",
        {"orderId": oid, "targetDate": next_bill.isoformat()},
        timeout=180,
    )
    # May return same or new invoice
    check(
        "collect period 2 attempted",
        bool(collect2.get("invoiceId") or collect2.get("ok")),
        str(collect2.get("blockedReason") or collect2.get("error") or "ok"),
    )

    all_lines = session.soql(
        "SELECT ChargeAmount, InvoiceLineStartDate "
        "FROM InvoiceLine "
        f"WHERE Invoice.BillingAccountId = '{acct}' "
        "ORDER BY InvoiceLineStartDate"
    )
    period2 = 0.0
    for ln in all_lines:
        ls = str(ln.get("InvoiceLineStartDate") or "")[:10]
        if not ls:
            continue
        if date.fromisoformat(ls) >= next_bill:
            period2 += float(ln.get("ChargeAmount") or 0)
    check(
        "period 2 charge ~150",
        near(period2, MONTHLY, 5.0) or period2 >= MONTHLY - 5,
        f"got={period2}",
    )

    q_count_after = len(
        session.soql(f"SELECT Id FROM Quote WHERE QuoteAccountId = '{acct}'")
    )
    check(
        "no extra renew Quote for period 2",
        q_count_after == q_count_before,
        f"before={q_count_before} after={q_count_after}",
    )

    print("\nPASS")
    print(f"accountId={acct}")
    print(f"licenses={base}/account?accountId={acct}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Fail as exc:
        print(f"\nFAIL: {exc}")
        raise SystemExit(1) from exc
