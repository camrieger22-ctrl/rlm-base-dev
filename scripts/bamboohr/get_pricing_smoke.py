#!/usr/bin/env python3
"""BambooHR Get Pricing smoke (service layer, no HTTP server).

Asserts:

1. US / Pro / qty 50 → net ≈ $16.15 (17 × 0.95), quote created
2. CA request carries disqualification warning
3. US Pro + Payroll + Benefits → Path B flag + add-on nets ≈ list × 0.85 × volume
   (single 15% on ListPrice; must not be list × 0.85² from Instant/System compound)
4. CA + Payroll requested → US-only add-ons stripped from quote

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
    print(f"BambooHR Get Pricing smoke against {args.target_org}")
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

    print("\n== 3) US Pro + Payroll + Benefits @ 50 (Path B) ==")
    path_b = get_pricing(
        session,
        GetPricingRequest(
            headcount=50,
            country="US",
            plan_sku="BAMBOO-PRO",
            addon_skus=["BAMBOO-ADD-PAYROLL", "BAMBOO-ADD-BENEFITS"],
            place_quote=True,
        ),
    )
    if not path_b.path_b_bundle_save:
        raise AssertionError("Expected Path B Bundle & Save flag on quote")
    by_sku = {li["sku"]: li for li in path_b.line_items}
    # qty 50 → plan volume band 5%; Path B ManualDiscount is on ListPrice so
    # Instant/System re-entry cannot compound 15% → net = list × 0.85 × 0.95.
    volume_at_50 = 0.95
    for sku, list_p in (
        ("BAMBOO-ADD-PAYROLL", 8.0),
        ("BAMBOO-ADD-BENEFITS", 6.0),
    ):
        if sku not in by_sku:
            raise AssertionError(f"Missing line {sku}: {path_b.line_items}")
        net = by_sku[sku]["netPepm"]
        expect_addon = round(list_p * 0.85 * volume_at_50, 3)
        compounded = round(list_p * 0.85 * 0.85 * volume_at_50, 3)
        if abs(net - expect_addon) > 0.05:
            raise AssertionError(
                f"{sku}: expected single Path B 15% then volume ≈ {expect_addon}, "
                f"got {net} (compounded-15% would be ≈ {compounded})"
            )
    if abs(path_b.net_pepm - expect) > 0.08:
        raise AssertionError(f"Plan net expected ~{expect}, got {path_b.net_pepm}")
    expect_monthly = round(sum(li["monthly"] for li in path_b.line_items), 2)
    if abs(path_b.monthly_total - expect_monthly) > 0.05:
        raise AssertionError(
            f"Monthly {path_b.monthly_total} != sum(lines) {expect_monthly}"
        )
    print(
        f"  PASS pathB quote={path_b.quote_id} monthly={path_b.monthly_total} "
        f"payrollNet={by_sku['BAMBOO-ADD-PAYROLL']['netPepm']} "
        f"benefitsNet={by_sku['BAMBOO-ADD-BENEFITS']['netPepm']}"
    )

    print("\n== 4) CA + Payroll requested (stripped) ==")
    ca_add = get_pricing(
        session,
        GetPricingRequest(
            headcount=10,
            country="CA",
            plan_sku="BAMBOO-CORE",
            addon_skus=["BAMBOO-ADD-PAYROLL", "BAMBOO-ADD-TIME"],
            place_quote=True,
        ),
    )
    if "BAMBOO-ADD-PAYROLL" in ca_add.addon_skus:
        raise AssertionError("Payroll should be stripped for CA")
    if "BAMBOO-ADD-TIME" not in ca_add.addon_skus:
        raise AssertionError("Time should remain for CA")
    if not any("Removed US-only" in w for w in ca_add.warnings):
        raise AssertionError(f"Expected strip warning, got {ca_add.warnings}")
    skus = {li["sku"] for li in ca_add.line_items}
    if "BAMBOO-ADD-PAYROLL" in skus:
        raise AssertionError("Payroll line should not be on CA quote")
    if "BAMBOO-ADD-TIME" not in skus:
        raise AssertionError("Time line missing on CA quote")
    print(f"  PASS stripped addons={ca_add.addon_skus} quote={ca_add.quote_id}")

    print("\nGet Pricing smoke PASSED")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"\nGet Pricing smoke FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
