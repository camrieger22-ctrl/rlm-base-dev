#!/usr/bin/env python3
"""BambooHR B5 smoke — CAD/GBP Get Pricing → Order → Activate → Assets.

Proves the native-currency Force restamp survives createOrderFromQuote
(not just quote display). Amend is skipped to keep runtime focused.

Usage:
  ~/.local/pipx/venvs/cumulusci/bin/python \\
    scripts/bamboohr/checkout_multicurrency_smoke.py --target-org master-demo
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent / "get_pricing"
sys.path.insert(0, str(HERE))

from checkout import checkout_quote  # noqa: E402
from service import (  # noqa: E402
    GetPricingRequest,
    OrgSession,
    expected_net,
    get_pricing,
)


def _run_country(
    session: OrgSession,
    *,
    country: str,
    currency: str,
    headcount: int,
    poll_timeout: int,
) -> None:
    print(f"\n== {country} Pro @{headcount} ({currency}) ==")
    priced = get_pricing(
        session,
        GetPricingRequest(
            headcount=headcount,
            country=country,
            plan_sku="BAMBOO-PRO",
            place_quote=True,
        ),
    )
    expect = expected_net("BAMBOO-PRO", headcount, currency)
    if priced.currency != currency:
        raise AssertionError(f"Expected {currency}, got {priced.currency}")
    if not priced.quote_id:
        raise AssertionError("Missing quote_id")
    if abs(priced.net_pepm - expect) > 0.08:
        raise AssertionError(
            f"Quote net {priced.net_pepm} != expect {expect}"
        )
    print(
        f"  quote={priced.quote_id} net={priced.net_pepm} "
        f"monthly={priced.monthly_total}"
    )

    result = checkout_quote(
        session,
        priced.quote_id,
        amend_qty=None,
        poll_timeout=poll_timeout,
    )
    if not result.ok:
        raise AssertionError(result.error or "checkout failed")
    if not result.order_id:
        raise AssertionError("Missing order_id")
    if not result.asset_ids:
        raise AssertionError(
            f"No assets after activation. warnings={result.warnings}"
        )

    orows = session.soql(
        "SELECT CurrencyIsoCode, Status FROM Order "
        f"WHERE Id = '{result.order_id}'"
    )
    if not orows or orows[0].get("CurrencyIsoCode") != currency:
        raise AssertionError(
            f"Order currency expected {currency}, got {orows}"
        )
    items = session.soql(
        "SELECT UnitPrice, NetUnitPrice, Quantity, "
        "PricebookEntry.UnitPrice, PricebookEntry.CurrencyIsoCode, "
        "Product2.StockKeepingUnit "
        f"FROM OrderItem WHERE OrderId = '{result.order_id}'"
    )
    plan = next(
        (
            i
            for i in items
            if (i.get("Product2") or {}).get("StockKeepingUnit") == "BAMBOO-PRO"
        ),
        None,
    )
    if not plan:
        raise AssertionError(f"No BAMBOO-PRO order line: {items}")
    pbe = plan.get("PricebookEntry") or {}
    if pbe.get("CurrencyIsoCode") != currency:
        raise AssertionError(f"Order line PBE currency {pbe}")
    net = float(plan.get("NetUnitPrice") or plan.get("UnitPrice") or 0)
    if abs(net - expect) > 0.12:
        raise AssertionError(
            f"Order line net {net} != expect {expect} (UnitPrice={plan.get('UnitPrice')})"
        )
    print(
        f"  PASS order={result.order_number or result.order_id} "
        f"status={orows[0].get('Status')} currency={currency} "
        f"lineNet={net} assets={len(result.asset_ids)} "
        f"assetQty={result.asset_quantity}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target-org", default="master-demo")
    parser.add_argument("--poll-timeout", type=int, default=180)
    parser.add_argument("--headcount", type=int, default=25)
    args = parser.parse_args()

    print(f"BambooHR multicurrency checkout smoke against {args.target_org}")
    session = OrgSession(args.target_org)
    _run_country(
        session,
        country="UK",
        currency="GBP",
        headcount=args.headcount,
        poll_timeout=args.poll_timeout,
    )
    _run_country(
        session,
        country="CA",
        currency="CAD",
        headcount=args.headcount,
        poll_timeout=args.poll_timeout,
    )
    print("\nMulticurrency checkout smoke PASSED")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"\nMulticurrency checkout smoke FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
