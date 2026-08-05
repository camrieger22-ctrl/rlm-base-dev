#!/usr/bin/env python3
"""BambooHR P2 Get Pricing smoke (service layer, no HTTP server).

Asserts:

1. US / Pro / qty 50 → net ≈ $16.15 (17 × 0.95), quote created
2. CA request carries disqualification warning

Usage:
  python scripts/bamboohr/get_pricing_smoke.py --target-org master-demo
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent / "get_pricing"
sys.path.insert(0, str(HERE))

from service import GetPricingRequest, OrgSession, expected_net, get_pricing  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target-org", default="master-demo")
    args = parser.parse_args()
    print(f"BambooHR Get Pricing P2 smoke against {args.target_org}")
    session = OrgSession(args.target_org)

    print("\n== 1) US Pro @ 50 ==")
    us = get_pricing(
        session,
        GetPricingRequest(
            headcount=50, country="US", plan_sku="BAMBOO-PRO", place_quote=True
        ),
    )
    expect = expected_net("BAMBOO-PRO", 50)
    if abs(us.net_pepm - expect) > 0.08:
        raise AssertionError(f"Expected net ~{expect}, got {us.net_pepm}")
    if not us.quote_id:
        raise AssertionError("Expected quote_id for US path")
    if "BAMBOO-PRO" not in us.discovered_skus:
        raise AssertionError("Discovery missing BAMBOO-PRO")
    print(f"  PASS net={us.net_pepm} quote={us.quote_id} monthly={us.monthly_total}")

    print("\n== 2) CA Core @ 10 (warning + quote) ==")
    ca = get_pricing(
        session,
        GetPricingRequest(
            headcount=10, country="CA", plan_sku="BAMBOO-CORE", place_quote=True
        ),
    )
    if not any("Canada" in w or "disqual" in w.lower() for w in ca.warnings):
        raise AssertionError(f"Expected CA disqual warning, got {ca.warnings}")
    if abs(ca.net_pepm - 10.0) > 0.08:
        raise AssertionError(f"CA qty 10 expected ~10.0, got {ca.net_pepm}")
    print(f"  PASS warning + net={ca.net_pepm} quote={ca.quote_id}")

    print("\nGet Pricing P2 smoke PASSED")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"\nGet Pricing P2 smoke FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
