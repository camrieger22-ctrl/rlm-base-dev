#!/usr/bin/env python3
"""Offline tests: Licenses snapshot — month-to-month vs termed, paid PEPM."""

from __future__ import annotations

import os
import sys
from datetime import date

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GP = os.path.join(REPO_ROOT, "scripts", "bamboohr", "get_pricing")
sys.path.insert(0, GP)

from account_console import paid_pepm  # noqa: E402
from service import add_calendar_months, commercial_term_from_window  # noqa: E402

RESULTS: list[tuple[str, bool]] = []


def check(name: str, condition: bool) -> None:
    RESULTS.append((name, bool(condition)))
    print(f"  [{'PASS' if condition else 'FAIL'}] {name}")


def test_commercial_term() -> None:
    print("\ncommercial term from lifecycle window")
    start = date(2026, 9, 1)
    m2m = commercial_term_from_window(start, add_calendar_months(start, 1))
    check("m2m kind", m2m["termKind"] == "month_to_month")
    check("m2m label", m2m["termLabel"] == "Month-to-month")
    check("m2m months", m2m["termMonths"] == 1)
    check("m2m exact", m2m["termExact"] is True)

    y12 = commercial_term_from_window(start, add_calendar_months(start, 12))
    check("12mo kind", y12["termKind"] == "committed")
    check("12mo label", y12["termLabel"] == "12-month term")
    check("12mo months", y12["termMonths"] == 12)

    y24 = commercial_term_from_window(start, add_calendar_months(start, 24))
    check("24mo label", y24["termLabel"] == "24-month term")
    y36 = commercial_term_from_window(start, add_calendar_months(start, 36))
    check("36mo label", y36["termLabel"] == "36-month term")

    # Asset end is often 23:59:59 on the anniversary date.
    iso = commercial_term_from_window(
        "2026-08-17T00:00:00.000+0000",
        "2027-08-17T23:59:59.000+0000",
    )
    check("iso 12mo", iso["termLabel"] == "12-month term")

    leftover = commercial_term_from_window(date(2026, 10, 15), date(2027, 8, 12))
    check("leftover committed", leftover["termKind"] == "committed")
    check("leftover not snapped to 12", leftover["termLabel"] == "Committed term")

    missing = commercial_term_from_window(None, None)
    check("unknown", missing["termKind"] == "unknown")


def test_paid_pepm() -> None:
    print("\npaid PEPM")
    check("120 / 12 = 10", paid_pepm(quantity=12, mrr=120) == 10.0)
    check("volume 8.50", paid_pepm(quantity=100, mrr=850) == 8.5)
    check("flat none", paid_pepm(quantity=1, mrr=199, is_flat=True) is None)
    check("zero qty", paid_pepm(quantity=0, mrr=120) is None)
    check("missing mrr", paid_pepm(quantity=12, mrr=None) is None)


def main() -> int:
    test_commercial_term()
    test_paid_pepm()
    passed = sum(1 for _, ok in RESULTS if ok)
    print(f"\n{passed}/{len(RESULTS)} passed")
    return 0 if passed == len(RESULTS) else 1


if __name__ == "__main__":
    raise SystemExit(main())
