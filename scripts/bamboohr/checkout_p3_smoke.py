#!/usr/bin/env python3
"""BambooHR dual-channel P3 smoke — Quote → Order → Asset → Amend E2E.

Asserts Initial Sale assetize plus amend quote → order → activate with
AssetAction Upsells bringing qty to --amend-qty.

Usage (CCI pipx Python):
  ~/.local/pipx/venvs/cumulusci/bin/python \\
    scripts/bamboohr/checkout_p3_smoke.py --target-org master-demo
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent / "get_pricing"
sys.path.insert(0, str(HERE))

from checkout import checkout_quote  # noqa: E402
from service import GetPricingRequest, OrgSession, get_pricing  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target-org", default="master-demo")
    parser.add_argument(
        "--amend-qty",
        type=int,
        default=30,
        help="True-up headcount after assetize (default 30; place uses 25)",
    )
    parser.add_argument("--poll-timeout", type=int, default=180)
    args = parser.parse_args()

    print(f"BambooHR P3 checkout smoke against {args.target_org}")
    session = OrgSession(args.target_org)

    print("\n== 1) Place Get Pricing quote (US Core @ 25) ==")
    priced = get_pricing(
        session,
        GetPricingRequest(
            headcount=25,
            country="US",
            plan_sku="BAMBOO-CORE",
            place_quote=True,
        ),
    )
    if not priced.quote_id:
        raise AssertionError("Expected quote_id from Get Pricing")
    print(f"  quote={priced.quote_id} net={priced.net_pepm}")

    print("\n== 2) createOrderFromQuote → ship → Activate → poll assets ==")
    print("== 3) Amend quote → order → Activate → Upsells qty ==")
    result = checkout_quote(
        session,
        priced.quote_id,
        amend_qty=args.amend_qty,
        poll_timeout=args.poll_timeout,
    )
    print(json.dumps(result.as_dict(), indent=2))
    if not result.ok:
        raise AssertionError(result.error or "checkout failed")
    if not result.order_id:
        raise AssertionError("Missing order_id")
    if not result.asset_ids:
        raise AssertionError(
            "No assets after activation — cannot prove assetize. "
            f"warnings={result.warnings}"
        )
    if not result.amend_quote_id:
        raise AssertionError(
            "Amend did not return a quote id — true-up incomplete. "
            f"warnings={result.warnings}"
        )
    if not result.amend_order_id:
        raise AssertionError(
            "Amend quote was not ordered/activated — E2E incomplete. "
            f"warnings={result.warnings}"
        )
    if result.asset_quantity is None or result.asset_quantity + 1e-6 < args.amend_qty:
        raise AssertionError(
            f"Expected asset qty >= {args.amend_qty}, got {result.asset_quantity}"
        )
    print(
        f"  PASS amend quote={result.amend_quote_id} "
        f"order={result.amend_order_number or result.amend_order_id} "
        f"assetQty={result.asset_quantity}"
    )

    print(
        f"\nP3 checkout smoke PASSED order={result.order_id} "
        f"assets={len(result.asset_ids)} assetQty={result.asset_quantity}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"\nP3 checkout smoke FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
