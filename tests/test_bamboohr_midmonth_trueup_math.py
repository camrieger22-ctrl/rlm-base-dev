#!/usr/bin/env python3
"""Offline tests: mid-month seat true-up proration math."""

from __future__ import annotations

import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GP = os.path.join(REPO_ROOT, "scripts", "bamboohr", "get_pricing")
sys.path.insert(0, GP)

from datetime import date

from billing_math import (  # noqa: E402
    inclusive_days,
    month_period_containing,
    prorate_monthly_amount,
)

RESULTS: list[tuple[str, bool]] = []


def check(name: str, condition: bool) -> None:
    RESULTS.append((name, bool(condition)))
    print(f"  [{'PASS' if condition else 'FAIL'}] {name}")


def test_aug_25_through_31() -> None:
    print("\nprorate Aug 25–31 of +$80/mo")
    # Matches live smoke: 8 × $10 × 7/31 ≈ 18.06
    got = prorate_monthly_amount(
        80.0,
        period_start=date(2026, 8, 1),
        period_end=date(2026, 8, 31),
        charge_start=date(2026, 8, 25),
    )
    check("≈ 18.06", abs(got - 18.06) < 0.01)
    check("7 inclusive days", inclusive_days(date(2026, 8, 25), date(2026, 8, 31)) == 7)


def test_mid_month_15() -> None:
    print("\nprorate Aug 15–31")
    got = prorate_monthly_amount(
        80.0,
        period_start=date(2026, 8, 1),
        period_end=date(2026, 8, 31),
        charge_start=date(2026, 8, 15),
    )
    # 17 days / 31 * 80
    expected = round(80.0 * 17 / 31, 2)
    check(f"≈ {expected}", abs(got - expected) < 0.01)


def test_month_period() -> None:
    print("\nmonth period")
    a, b = month_period_containing(date(2026, 8, 24))
    check("start", a == date(2026, 8, 1))
    check("end", b == date(2026, 8, 31))


def main() -> int:
    test_aug_25_through_31()
    test_mid_month_15()
    test_month_period()
    failed = sum(1 for _, ok in RESULTS if not ok)
    print(f"\n{len(RESULTS) - failed}/{len(RESULTS)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
