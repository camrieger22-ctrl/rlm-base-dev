"""Pure billing/proration helpers for BambooHR self-serve smokes and tests."""

from __future__ import annotations

import calendar
from datetime import date


def days_in_month(day: date) -> int:
    return calendar.monthrange(day.year, day.month)[1]


def inclusive_days(start: date, end: date) -> int:
    """Calendar days in [start, end] inclusive. 0 if end < start."""
    if end < start:
        return 0
    return (end - start).days + 1


def prorate_monthly_amount(
    monthly: float,
    *,
    period_start: date,
    period_end: date,
    charge_start: date,
    charge_end: date | None = None,
) -> float:
    """Prorate a monthly amount over part of a billing period (inclusive days).

    ``charge_end`` defaults to ``period_end``. Result rounded to cents.
    """
    end = charge_end or period_end
    if end < charge_start:
        return 0.0
    # Clip to period
    start = max(charge_start, period_start)
    end = min(end, period_end)
    period_days = inclusive_days(period_start, period_end)
    if period_days <= 0:
        return 0.0
    charged = inclusive_days(start, end)
    return round(float(monthly) * charged / period_days, 2)


def month_period_containing(day: date) -> tuple[date, date]:
    """Return (first, last) calendar dates of the month containing ``day``."""
    first = date(day.year, day.month, 1)
    last = date(day.year, day.month, days_in_month(day))
    return first, last
