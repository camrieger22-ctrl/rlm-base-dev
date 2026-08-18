#!/usr/bin/env python3
"""Offline tests: amend summary charge lines include Quote service dates."""

from __future__ import annotations

import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GP = os.path.join(REPO_ROOT, "scripts", "bamboohr", "get_pricing")
sys.path.insert(0, GP)

import amend_summary as am  # noqa: E402

RESULTS: list[tuple[str, bool]] = []


def check(name: str, condition: bool) -> None:
    RESULTS.append((name, bool(condition)))
    print(f"  [{'PASS' if condition else 'FAIL'}] {name}")


def test_charge_line_keeps_quote_window() -> None:
    print("\ncharge line service window")
    line = am._charge_line_from_qli(
        {
            "sku": "BAMBOO-PRO",
            "name": "Pro",
            "quantity": 12,
            "listPepm": 17.0,
            "unitPrice": 17.0,
            "netUnitPrice": 17.0,
            "totalPrice": 1005.29,
            "startDate": "2026-08-19T00:00:00.000Z",
            "endDate": "2027-08-17",
        },
        path_b=False,
        volume_percent=0.0,
    )
    check("start is ISO day", line["startDate"] == "2026-08-19")
    check("end is ISO day", line["endDate"] == "2027-08-17")
    check("charge unchanged", line["lineTotal"] == 1005.29)
    blank = am._charge_line_from_qli(
        {
            "sku": "BAMBOO-CORE",
            "name": "Core",
            "quantity": 12,
            "totalPrice": -84.0,
        },
        path_b=False,
        volume_percent=None,
    )
    check("missing start stays empty", blank["startDate"] is None)
    check("missing end stays empty", blank["endDate"] is None)


def test_view_passes_dates_to_due_lines() -> None:
    print("\namend summary view charge dates")
    view = am.build_amend_summary_view(
        {
            "ok": True,
            "accountId": "001TEST",
            "accountName": "Date Proof LLC",
            "currency": "USD",
            "currentQty": 12,
            "baselineQty": 12,
            "newQty": 12,
            "dueToday": 1005.29,
            "dueParts": [
                {
                    "kind": "upgrade",
                    "quoteId": "0Q0TEST",
                    "quoteNumber": "00000860",
                    "totalPrice": 1005.29,
                    "lines": [
                        {
                            "sku": "BAMBOO-CORE",
                            "name": "Core",
                            "quantity": 12,
                            "totalPrice": -420.0,
                            "startDate": "2026-08-19",
                            "endDate": "2027-08-17",
                        },
                        {
                            "sku": "BAMBOO-PRO",
                            "name": "Pro",
                            "quantity": 12,
                            "listPepm": 17.0,
                            "netUnitPrice": 17.0,
                            "totalPrice": 1425.29,
                            "startDate": "2026-08-19",
                            "endDate": "2027-08-17",
                        },
                    ],
                }
            ],
        }
    )
    lines = (view.get("dueForChange") or {}).get("lines") or []
    check("two charge lines", len(lines) == 2)
    check("core start", lines[0]["startDate"] == "2026-08-19")
    check("core end", lines[0]["endDate"] == "2027-08-17")
    check("pro end matches remaining term", lines[1]["endDate"] == "2027-08-17")


def test_hero_is_quoted_remaining_term() -> None:
    print("\nquoted remaining term vs first bill")
    check("charge label", am.HERO_LABEL_CHARGE == "Quoted now (remaining term)")
    check("credit label", am.HERO_LABEL_CREDIT.startswith("Quoted credit"))
    check("hint mentions Pay Now first bill", "first Billing invoice" in am.COMPARE_HINT)
    view = am.build_amend_summary_view(
        {
            "ok": True,
            "accountId": "001TEST",
            "accountName": "Quote Vs Bill LLC",
            "currency": "USD",
            "currentQty": 12,
            "baselineQty": 12,
            "newQty": 13,
            "dueToday": 203.45,
            "amendStartDate": "2026-09-01",
            "dueParts": [
                {
                    "kind": "qtyAmend",
                    "quoteId": "0Q0TEST",
                    "quoteNumber": "00000862",
                    "totalPrice": 203.45,
                    "lines": [],
                }
            ],
        }
    )
    check("hero uses quoted label", view["hero"]["label"] == am.HERO_LABEL_CHARGE)
    check("hero amount is quote total", view["hero"]["amount"] == 203.45)
    check("cash due is amend start", view.get("cashDueDate") == "2026-09-01")
    check("cash due hint", "not today" in (view.get("cashDueHint") or ""))


def main() -> int:
    test_charge_line_keeps_quote_window()
    test_view_passes_dates_to_due_lines()
    test_hero_is_quoted_remaining_term()
    passed = sum(1 for _, ok in RESULTS if ok)
    print(f"\n{passed}/{len(RESULTS)} passed")
    return 0 if passed == len(RESULTS) else 1


if __name__ == "__main__":
    raise SystemExit(main())
