#!/usr/bin/env python3
"""Offline tests: evergreen vs committed subscription windows."""

from __future__ import annotations

import os
import sys
from datetime import date

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GP = os.path.join(REPO_ROOT, "scripts", "bamboohr", "get_pricing")
sys.path.insert(0, GP)

from service import (  # noqa: E402
    add_calendar_months,
    is_evergreen_term,
    pricing_window_end,
    quote_line_term_fields,
    resolve_subscription_window,
)

RESULTS: list[tuple[str, bool]] = []


def check(name: str, condition: bool) -> None:
    RESULTS.append((name, bool(condition)))
    print(f"  [{'PASS' if condition else 'FAIL'}] {name}")


def main() -> int:
    start = date(2026, 8, 1)
    print("\nevergreen termMonths=1")
    s, e, m = resolve_subscription_window(start_date=start, term_months=1)
    check("start", s == start)
    check("end is None", e is None)
    check("months 1", m == 1)
    check("is_evergreen", is_evergreen_term(1))
    check("pricing window +1mo", pricing_window_end(s, e) == add_calendar_months(start, 1))
    fields = quote_line_term_fields(s.isoformat(), None)
    check("no EndDate on line", "EndDate" not in fields)
    check("has BillingFrequency", fields.get("BillingFrequency") == "Monthly")
    check("PeriodBoundary Anniversary", fields.get("PeriodBoundary") == "Anniversary")

    print("\ncommitted termMonths=12")
    s2, e2, m2 = resolve_subscription_window(start_date=start, term_months=12)
    check("12 end", e2 == add_calendar_months(start, 12))
    check("not evergreen", not is_evergreen_term(12))
    fields2 = quote_line_term_fields(s2.isoformat(), e2.isoformat() if e2 else None)
    check("has EndDate", fields2.get("EndDate") == e2.isoformat())
    check("PeriodBoundary", fields2.get("PeriodBoundary") == "Anniversary")

    print("\nfree trial still dated")
    _s, te, _m = resolve_subscription_window(
        start_date=start, term_months=1, free_trial=True
    )
    check("trial has end", te is not None)
    check("trial not evergreen flag", not is_evergreen_term(1, free_trial=True))

    failed = sum(1 for _, ok in RESULTS if not ok)
    print(f"\n{len(RESULTS) - failed}/{len(RESULTS)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
