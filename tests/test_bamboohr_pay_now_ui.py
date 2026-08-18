#!/usr/bin/env python3
"""Offline tests: quoted vs first bill, paid-applying invoices, Place recover."""

from __future__ import annotations

import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GP = os.path.join(REPO_ROOT, "scripts", "bamboohr", "get_pricing")
sys.path.insert(0, GP)

import checkout as co  # noqa: E402
import payments as pay  # noqa: E402

RESULTS: list[tuple[str, bool]] = []


def check(name: str, condition: bool) -> None:
    RESULTS.append((name, bool(condition)))
    print(f"  [{'PASS' if condition else 'FAIL'}] {name}")


def test_paid_applying_matches_this_bill_only() -> None:
    print("\npaid applying matches this bill, not leftover invoices")
    invoices = [
        {
            "id": "3I-047",
            "invoiceNumber": "INV-US-08-2026-000047",
            "balance": 18.70,
            "totalAmountWithTax": 18.70,
            "createdDate": "2026-08-18T18:00:00.000+0000",
            "paymentUrl": "https://example.test/pay/047",
        },
        {
            "id": "3I-041",
            "invoiceNumber": "INV-US-08-2026-000041",
            "balance": 132.00,
            "totalAmountWithTax": 132.00,
            "createdDate": "2026-08-01T12:00:00.000+0000",
            "paymentUrl": "https://example.test/pay/041",
        },
    ]
    sig = {
        "recentPayments": [
            {
                "id": "0aQpay",
                "amount": 18.70,
                "status": "Processed",
                "createdDate": "2026-08-18T18:05:00.000+0000",
            }
        ],
        "disabledPaymentLink": {
            "id": "0PL",
            "amount": 18.70,
            "status": "Disabled",
        },
    }
    out = pay.annotate_invoices_paid_applying(invoices, sig)
    by_id = {row["id"]: row for row in out}
    check("18.70 invoice paid applying", by_id["3I-047"]["paidApplying"] is True)
    check("18.70 pay url cleared", by_id["3I-047"]["paymentUrl"] is None)
    check("132 leftover still due", by_id["3I-041"]["paidApplying"] is False)
    check("132 keep pay url", by_id["3I-041"]["paymentUrl"] is not None)

    older_pay = pay.annotate_invoices_paid_applying(
        [
            {
                "id": "3I-041",
                "balance": 132.00,
                "createdDate": "2026-08-18T20:00:00.000+0000",
                "paymentUrl": "https://example.test/pay/041",
            }
        ],
        {
            "recentPayments": [
                {
                    "id": "0aQold",
                    "amount": 132.00,
                    "createdDate": "2026-08-01T12:00:00.000+0000",
                }
            ]
        },
    )
    check("older 132 payment does not mark later bill", older_pay[0]["paidApplying"] is False)


def test_disabled_link_alone_does_not_mark_bill() -> None:
    print("\ndisabled payment link without Processed payment is not paid")
    invoices = [
        {
            "id": "3I-a",
            "balance": 132.0,
            "createdDate": "2026-08-01T12:00:00.000+0000",
            "paymentUrl": "https://example.test/a",
        }
    ]
    out = pay.annotate_invoices_paid_applying(
        invoices,
        {"recentPayments": [], "disabledPaymentLink": {"amount": 132.0}},
    )
    check("leftover stays due", out[0]["paidApplying"] is False)
    check("pay url kept", out[0]["paymentUrl"] is not None)


def test_pick_activated_order_for_quotes() -> None:
    print("\nplace recover prefers newest activated order")
    orders = [
        {
            "Id": "801old",
            "Status": "Activated",
            "QuoteId": "0Q0upg",
            "CreatedDate": "2026-08-01T00:00:00.000+0000",
            "OrderNumber": "00000200",
        },
        {
            "Id": "801new",
            "Status": "Activated",
            "QuoteId": "0Q0upg",
            "CreatedDate": "2026-08-18T20:00:00.000+0000",
            "OrderNumber": "00000256",
        },
        {
            "Id": "801draft",
            "Status": "Draft",
            "QuoteId": "0Q0upg",
            "CreatedDate": "2026-08-18T21:00:00.000+0000",
            "OrderNumber": "00000299",
        },
    ]
    picked = co.pick_activated_order_for_quotes(orders, ["0Q0upg", "0Q0other"])
    check("picks newest activated", (picked or {}).get("Id") == "801new")
    check("ignores draft", (picked or {}).get("Status") == "Activated")
    none = co.pick_activated_order_for_quotes(orders, ["0Q0missing"])
    check("missing quote is none", none is None)


def test_payment_prompt_flags() -> None:
    print("\npayment prompt paid applying / collect pending")
    applying = pay.PaymentPrompt(
        ready=False,
        invoice_id="3I",
        invoice_number="INV-047",
        invoice_balance=18.70,
        paid_applying=True,
    ).as_dict()
    check("paidApplying in dict", applying["paidApplying"] is True)
    check("not ready while applying", applying["ready"] is False)
    pending = pay.PaymentPrompt(
        ready=False, order_id="801x", collect_pending=True
    ).as_dict()
    check("collectPending in dict", pending["collectPending"] is True)
    check("orderId present", pending["orderId"] == "801x")


def test_bucket_this_bill_vs_earlier() -> None:
    print("\nearlier invoices are not this bill")
    orders = [
        {
            "id": "801-257",
            "status": "Activated",
            "createdDate": "2026-08-18T17:16:58.000+0000",
        },
        {
            "id": "801-255",
            "status": "Activated",
            "createdDate": "2026-08-18T15:44:43.000+0000",
        },
    ]
    rows = pay.bucket_open_invoices(
        [
            {
                "id": "047",
                "createdDate": "2026-08-18T17:17:29.000+0000",
                "paidApplying": True,
            },
            {
                "id": "044",
                "createdDate": "2026-08-18T15:48:18.000+0000",
            },
            {
                "id": "043",
                "createdDate": "2026-08-18T15:47:59.000+0000",
            },
        ],
        orders=orders,
    )
    by = {r["id"]: r["bucket"] for r in rows}
    check("newest is this bill", by["047"] == "thisBill")
    check("044 earlier", by["044"] == "earlier")
    check("043 earlier", by["043"] == "earlier")
    check("047 attributed to 257", rows[0].get("orderId") == "801-257")


def test_bucket_this_bill_gone_leftovers_stay_earlier() -> None:
    print("\nafter this bill applies, leftovers stay earlier")
    orders = [
        {
            "id": "801-257",
            "status": "Activated",
            "createdDate": "2026-08-18T17:16:58.000+0000",
        },
        {
            "id": "801-255",
            "status": "Activated",
            "createdDate": "2026-08-18T15:44:43.000+0000",
        },
    ]
    rows = pay.bucket_open_invoices(
        [
            {
                "id": "044",
                "createdDate": "2026-08-18T15:48:18.000+0000",
            },
            {
                "id": "043",
                "createdDate": "2026-08-18T15:47:59.000+0000",
            },
        ],
        orders=orders,
    )
    by = {r["id"]: r["bucket"] for r in rows}
    check("044 stays earlier", by["044"] == "earlier")
    check("043 stays earlier", by["043"] == "earlier")


def test_bucket_future_upgrade_keeps_paid_original() -> None:
    print("\nlatest order has no invoice — paid original stays this bill")
    orders = [
        {
            "id": "801-256",
            "status": "Activated",
            "createdDate": "2026-08-18T17:08:07.000+0000",
        },
        {
            "id": "801-251",
            "status": "Activated",
            "createdDate": "2026-08-14T16:59:44.000+0000",
        },
    ]
    rows = pay.bucket_open_invoices(
        [
            {
                "id": "041",
                "createdDate": "2026-08-14T17:00:30.000+0000",
                "paidApplying": True,
            }
        ],
        orders=orders,
    )
    check("041 this bill", rows[0]["bucket"] == "thisBill")
    check("041 attributed to 251", rows[0].get("orderId") == "801-251")


def test_preview_leftover_draft_names() -> None:
    print("\npreview leftover draft matcher")
    import checkout as co

    check(
        "amendment named",
        co._is_preview_leftover_draft("Amendment Quote", "") is True,
    )
    check(
        "upgrade named",
        co._is_preview_leftover_draft("Upgrade Quote", "") is True,
    )
    check(
        "add modules named",
        co._is_preview_leftover_draft("Add modules — Time Tracking", "") is True,
    )
    check(
        "self-serve untagged kept",
        co._is_preview_leftover_draft("SelfServe - BambooHR Core", "") is False,
    )
    check(
        "tagged self-serve swept",
        co._is_preview_leftover_draft(
            "SelfServe - BambooHR Core", "[bamboohr-preview] get-pricing"
        )
        is True,
    )


def main() -> int:
    test_paid_applying_matches_this_bill_only()
    test_disabled_link_alone_does_not_mark_bill()
    test_pick_activated_order_for_quotes()
    test_payment_prompt_flags()
    test_bucket_this_bill_vs_earlier()
    test_bucket_this_bill_gone_leftovers_stay_earlier()
    test_bucket_future_upgrade_keeps_paid_original()
    test_preview_leftover_draft_names()
    passed = sum(1 for _, ok in RESULTS if ok)
    print(f"\n{passed}/{len(RESULTS)} passed")
    return 0 if passed == len(RESULTS) else 1


if __name__ == "__main__":
    raise SystemExit(main())
