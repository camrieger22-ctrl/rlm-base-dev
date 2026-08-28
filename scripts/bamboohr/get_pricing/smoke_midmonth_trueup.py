#!/usr/bin/env python3
"""Mid-month seat true-up smoke (Phase A gap closure).

Calendar-correct path (preferred when today.day >= 15)::

  1. Core @ 15, start = 1st of current month, 12-mo term
  2. Invoice with targetDate = period start → one month @ 15
  3. Amend 15→23 starting day 15 of that month
  4. Collect amend invoice → prorated +8 stub
  5. Generate next period (NextBillingDate) → ~23 × PEPM

Same-day fallback (any calendar day)::

  start = amend start = today; stub ≈ full month of +8; still asserts ASP + schedules.

Usage::

  # BFF must be running (e.g. http://127.0.0.1:8765).
  # Org SOQL needs CumulusCI — use the CCI pipx Python (not bare ``python``):
  ~/.local/pipx/venvs/cumulusci/bin/python \\
    scripts/bamboohr/get_pricing/smoke_midmonth_trueup.py \\
    --org master-demo --base-url http://127.0.0.1:8765

Exit 0 on pass, 1 on assertion failure.
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

from billing_math import (  # noqa: E402
    month_period_containing,
    prorate_monthly_amount,
)
from service import OrgSession  # noqa: E402

PEPM = 10.0
QTY0 = 15
QTY1 = 23
DELTA = QTY1 - QTY0  # 8
MONTHLY0 = PEPM * QTY0  # 150
MONTHLY1 = PEPM * QTY1  # 230
DELTA_MONTHLY = PEPM * DELTA  # 80


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


def near(a: float, b: float, tol: float = 0.05) -> bool:
    return abs(float(a) - float(b)) <= tol


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--org", default="master-demo")
    ap.add_argument("--base-url", default="http://127.0.0.1:8765")
    ap.add_argument(
        "--mode",
        choices=("auto", "midmonth", "sameday"),
        default="auto",
        help="auto: midmonth when day>=15 else sameday",
    )
    args = ap.parse_args()
    base = args.base_url
    today = date.today()
    mode = args.mode
    if mode == "auto":
        mode = "midmonth" if today.day >= 15 else "sameday"

    period_start, _period_end = month_period_containing(today)
    if mode == "midmonth":
        term_start = period_start
        amend_start = date(today.year, today.month, 15)
        if amend_start > today:
            print("midmonth requested but day 15 is in the future; use sameday")
            return 1
    else:
        term_start = today
        amend_start = today

    # Fail before place/checkout if this interpreter cannot talk to the org.
    try:
        session = OrgSession(args.org)
        _ = session.soql("SELECT Id FROM Organization LIMIT 1")
    except Exception as exc:  # noqa: BLE001
        print(
            f"OrgSession failed ({exc}).\n"
            "Use CumulusCI's Python, e.g.:\n"
            "  ~/.local/pipx/venvs/cumulusci/bin/python \\\n"
            "    scripts/bamboohr/get_pricing/smoke_midmonth_trueup.py \\\n"
            f"    --org {args.org} --base-url {base}",
            file=sys.stderr,
        )
        return 1

    stamp = time.strftime("%H%M%S")
    email = f"trueup.smoke.{stamp}@example.com"
    company = f"Trueup Smoke {stamp}"
    print(f"mode={mode} term_start={term_start} amend_start={amend_start}")
    print(f"company={company}")

    health = _http_json(base, "GET", "/api/health")
    check("BFF health", bool(health.get("ok")), str(health.get("org") or ""))

    # --- qualify ---
    sess_body = _http_json(
        base,
        "POST",
        "/api/qualify-session",
        {
            "employeeCount": QTY0,
            "country": "US",
            "needs": ["hr"],
            "email": email,
            "company": company,
            "firstName": "True",
            "lastName": "Up",
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
            "firstName": "True",
            "lastName": "Up",
            "employeeCount": QTY0,
            "country": "US",
            "needs": ["hr"],
        },
    )
    acct = commit.get("accountId") or ""
    check("qualify commit", bool(commit.get("ok")) and bool(acct), str(commit.get("error")))

    # --- get pricing ---
    placed = _http_json(
        base,
        "POST",
        "/api/get-pricing",
        {
            "headcount": QTY0,
            "country": "US",
            "planSku": "BAMBOO-CORE",
            "addonSkus": [],
            "placeQuote": True,
            "startDate": term_start.isoformat(),
            "termMonths": 12,
            "qualifySessionId": sid,
            "buyer": {
                "company": company,
                "firstName": "True",
                "lastName": "Up",
                "email": email,
            },
        },
    )
    qid = placed.get("quoteId") or ""
    check("place quote", bool(placed.get("ok")) and bool(qid), str(placed.get("error")))
    check(
        "monthly total ~150",
        near(float(placed.get("monthlyTotal") or 0), MONTHLY0, 1.0),
        str(placed.get("monthlyTotal")),
    )

    # Activate without Pay Now so we can pin Billing generate targetDate.
    checkout = _http_json(
        base,
        "POST",
        "/api/checkout",
        {"quoteId": qid, "collectPayment": False},
        timeout=300,
    )
    oid = checkout.get("orderId") or ""
    check("checkout activate", bool(checkout.get("ok")) and bool(oid), str(checkout.get("error")))

    def invoice_lines(invoice_id: str) -> list[dict]:
        return session.soql(
            "SELECT ChargeAmount, Quantity, InvoiceLineStartDate, InvoiceLineEndDate "
            f"FROM InvoiceLine WHERE InvoiceId = '{invoice_id}' "
            "ORDER BY InvoiceLineStartDate"
        )

    collect1 = _http_json(
        base,
        "POST",
        "/api/collect-payment",
        {"orderId": oid, "targetDate": term_start.isoformat()},
        timeout=180,
    )
    inv1_id = collect1.get("invoiceId")
    check(
        "collect initial",
        bool(inv1_id),
        str(collect1.get("blockedReason") or collect1.get("error")),
    )

    lines1 = invoice_lines(inv1_id)
    check("initial invoice has lines", bool(lines1))
    if mode == "midmonth":
        check(
            "initial invoice single period (no catch-up)",
            len(lines1) == 1,
            f"lines={len(lines1)} amounts={[l.get('ChargeAmount') for l in lines1]}",
        )
        check(
            "initial charge ~150",
            near(float(lines1[0].get("ChargeAmount") or 0), MONTHLY0),
            str(lines1[0].get("ChargeAmount")),
        )
    else:
        # sameday: at least one line at 15 seats monthly
        total_charge = sum(float(l.get("ChargeAmount") or 0) for l in lines1)
        check(
            "initial charge includes ~150",
            near(total_charge, MONTHLY0, 1.0) or total_charge >= MONTHLY0 - 1,
            str(total_charge),
        )

    # --- amend estimate / preview / place ---
    est = _http_json(
        base,
        "POST",
        "/api/account-amend-estimate",
        {
            "accountId": acct,
            "newQty": QTY1,
            "startDate": amend_start.isoformat(),
        },
        timeout=120,
    )
    check("amend estimate ok", bool(est.get("ok")), str(est.get("error")))
    effective_start = date.fromisoformat(str(est.get("amendStartDate") or amend_start)[:10])
    if est.get("amendStartBumped") or effective_start != amend_start:
        print(
            f"  [warn] amend start bumped {amend_start} → {effective_start} "
            f"(Advance/ASP floor)"
        )

    prev = _http_json(
        base,
        "POST",
        "/api/account-amend-preview",
        {
            "accountId": acct,
            "newQty": QTY1,
            "startDate": effective_start.isoformat(),
        },
        timeout=180,
    )
    check("amend preview ok", bool(prev.get("ok")), str(prev.get("error")))
    aq = (prev.get("amendQuotes") or [{}])[0]
    aqid = aq.get("quoteId") if isinstance(aq, dict) else ""
    check("amend quote id", bool(aqid))
    quote_total = float(aq.get("totalPrice") or prev.get("dueToday") or 0)
    check("amend quote total > 0", quote_total > 0, str(quote_total))

    place = _http_json(
        base,
        "POST",
        "/api/account-amend",
        {
            "accountId": acct,
            "newQty": QTY1,
            "startDate": effective_start.isoformat(),
            "amendQuotes": [
                {
                    "quoteId": aqid,
                    "assetIds": aq.get("assetIds") or [],
                }
            ],
        },
        timeout=300,
    )
    check("amend place ok", bool(place.get("ok")), str(place.get("error")))
    amend_oid = place.get("amendOrderId") or place.get("orderId") or ""
    check("amend order id", bool(amend_oid))

    # collect amend — pin target to effective start for stub period
    collect2 = _http_json(
        base,
        "POST",
        "/api/collect-payment",
        {
            "orderId": amend_oid,
            "accountId": acct,
            "targetDate": effective_start.isoformat(),
        },
        timeout=180,
    )
    inv2_id = collect2.get("invoiceId")
    if not inv2_id and (place.get("payment") or {}).get("invoiceId"):
        inv2_id = place["payment"]["invoiceId"]
    check("amend invoice", bool(inv2_id), str(collect2.get("blockedReason") or collect2))

    lines2 = invoice_lines(inv2_id)
    check("amend invoice has +8 line", bool(lines2))
    stub_charge = sum(float(l.get("ChargeAmount") or 0) for l in lines2)
    # Expected proration within the calendar month of effective_start
    p_start, p_end = month_period_containing(effective_start)
    expected_stub = prorate_monthly_amount(
        DELTA_MONTHLY,
        period_start=p_start,
        period_end=p_end,
        charge_start=effective_start,
        charge_end=p_end,
    )
    check(
        "stub ≈ prorated +8",
        near(stub_charge, expected_stub, 0.5),
        f"got={stub_charge} expected={expected_stub}",
    )
    # Remaining-term Quote TCV ≫ first Billing stub (except same-day ≈ full month).
    if mode == "midmonth" and effective_start.day > 1:
        check(
            "stub << quote TCV",
            stub_charge < quote_total * 0.5,
            f"stub={stub_charge} quote={quote_total}",
        )

    # --- ASP ---
    asps = session.soql(
        "SELECT Quantity, Mrr, StartDate, EndDate "
        "FROM AssetStatePeriod "
        f"WHERE Asset.AccountId = '{acct}' "
        "AND Asset.Product2.StockKeepingUnit = 'BAMBOO-CORE' "
        "ORDER BY StartDate"
    )
    check("ASP rows", len(asps) >= 1)
    last = asps[-1]
    check(
        "ASP current qty 23",
        near(float(last.get("Quantity") or 0), QTY1, 0.01),
        str(last.get("Quantity")),
    )
    check(
        "ASP MRR ~230",
        near(float(last.get("Mrr") or 0), MONTHLY1, 1.0),
        str(last.get("Mrr")),
    )

    # --- next period generate ---
    scheds = session.soql(
        "SELECT Id, ReferenceEntityId, BillingPeriodAmount, NextBillingDate, "
        "BilledAmount, PendingAmount, Status "
        f"FROM BillingSchedule WHERE BillingAccountId = '{acct}' "
        "ORDER BY CreatedDate"
    )
    next_dates = []
    for srow in scheds:
        raw = srow.get("NextBillingDate")
        if raw:
            next_dates.append(date.fromisoformat(str(raw)[:10]))
    check("has NextBillingDate", bool(next_dates), str(scheds))
    next_bill = min(next_dates)
    print(f"  [info] next billing date {next_bill}")

    # Generate on both orders for next period (dual schedules)
    for order_ref in {oid, amend_oid}:
        _http_json(
            base,
            "POST",
            "/api/collect-payment",
            {"orderId": order_ref, "targetDate": next_bill.isoformat()},
            timeout=180,
        )

    # Sum charges whose line start falls on next_bill month
    all_lines = session.soql(
        "SELECT ChargeAmount, InvoiceLineStartDate, Quantity "
        "FROM InvoiceLine "
        f"WHERE Invoice.BillingAccountId = '{acct}' "
        "ORDER BY InvoiceLineStartDate"
    )
    nb_start, nb_end = month_period_containing(next_bill)
    period_charges = 0.0
    for ln in all_lines:
        ls = str(ln.get("InvoiceLineStartDate") or "")[:10]
        if not ls:
            continue
        ld = date.fromisoformat(ls)
        if nb_start <= ld <= nb_end:
            period_charges += float(ln.get("ChargeAmount") or 0)
    check(
        "next period charges ~230 (23×PEPM)",
        near(period_charges, MONTHLY1, 5.0)
        or period_charges >= MONTHLY1 - 5,
        f"got={period_charges} expected~{MONTHLY1}",
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
    except KeyboardInterrupt:
        raise SystemExit(130) from None
