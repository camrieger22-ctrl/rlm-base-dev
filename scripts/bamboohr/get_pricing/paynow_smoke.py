#!/usr/bin/env python3
"""Pay Now smoke (Phase 6) — readiness + optional PaymentLink create.

Does **not** drive Stripe/Playwright by default (card entry stays on the Pay Now
site; use an incognito browser with ``4242…`` when you want a live charge).

Examples::

  ~/.local/pipx/venvs/cumulusci/bin/python \\
    scripts/bamboohr/get_pricing/paynow_smoke.py --org master-demo

  # Also create/reuse a link for the newest open invoice (any account)
  ~/.local/pipx/venvs/cumulusci/bin/python \\
    scripts/bamboohr/get_pricing/paynow_smoke.py --org master-demo --create-link

  # Target a specific account
  ~/.local/pipx/venvs/cumulusci/bin/python \\
    scripts/bamboohr/get_pricing/paynow_smoke.py --org master-demo \\
    --account-id 001… --create-link
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from payments import (  # noqa: E402
    build_payment_prompt_for_invoice,
    list_open_invoices,
    payments_readiness,
)
from service import OrgSession  # noqa: E402


def _pass(msg: str) -> None:
    print(f"  PASS  {msg}")


def _fail(msg: str) -> None:
    print(f"  FAIL  {msg}")


def _info(msg: str) -> None:
    print(f"  ·     {msg}")


def _newest_open_invoice(
    session: OrgSession, account_id: str | None
) -> dict[str, Any] | None:
    if account_id:
        invs = list_open_invoices(session, account_id, limit=5)
        return invs[0] if invs else None
    rows = session.soql(
        "SELECT Id, InvoiceNumber, DocumentNumber, Balance, BillingAccountId "
        "FROM Invoice WHERE Status = 'Posted' AND Balance > 0 "
        "ORDER BY CreatedDate DESC LIMIT 1"
    )
    if not rows:
        return None
    row = rows[0]
    number = row.get("InvoiceNumber") or row.get("DocumentNumber") or row["Id"]
    return {
        "id": row["Id"],
        "invoiceNumber": number,
        "balance": float(row.get("Balance") or 0),
        "billingAccountId": row.get("BillingAccountId"),
        "paymentUrl": None,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--org", required=True, help="SF CLI / CCI org alias")
    parser.add_argument(
        "--account-id",
        default=None,
        help="Optional Billing Account Id for invoice/link steps",
    )
    parser.add_argument(
        "--create-link",
        action="store_true",
        help="Create/reuse PaymentLink for newest open invoice",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit machine-readable JSON summary",
    )
    args = parser.parse_args()

    session = OrgSession(args.org)
    failures: list[str] = []
    summary: dict[str, Any] = {"org": args.org}

    print(f"Pay Now smoke — org={args.org}")
    print()
    print("1) payments_readiness")
    ready = payments_readiness(session)
    summary["readiness"] = {
        "readyForPayNow": ready.get("readyForPayNow"),
        "blocking": ready.get("blocking"),
        "payNowSiteUrl": ready.get("payNowSiteUrl"),
    }
    if ready.get("readyForPayNow"):
        _pass("readyForPayNow=true")
    else:
        _fail(f"readyForPayNow=false blocking={ready.get('blocking')}")
        failures.append("readyForPayNow")
        for step in ready.get("manualSteps") or []:
            _info(step)

    for check in ready.get("checks") or []:
        if check.get("informational"):
            continue
        if check.get("skipped"):
            _info(f"{check.get('id')}: skipped — {check.get('detail')}")
        elif check.get("ok"):
            _pass(f"{check.get('id')}: {check.get('detail')}")
        else:
            _fail(f"{check.get('id')}: {check.get('detail')}")
            if check.get("id") not in failures:
                failures.append(str(check.get("id")))

    print()
    print("2) open invoice (+ optional PaymentLink)")
    inv = _newest_open_invoice(session, args.account_id)
    if not inv:
        _info("no Posted invoice with Balance > 0 — skip link create")
        summary["invoice"] = None
        if args.create_link:
            _fail("--create-link requested but no open invoice found")
            failures.append("noOpenInvoice")
    else:
        _pass(
            f"invoice {inv.get('invoiceNumber')} balance={inv.get('balance')} "
            f"id={inv.get('id')}"
        )
        summary["invoice"] = {
            "id": inv.get("id"),
            "invoiceNumber": inv.get("invoiceNumber"),
            "balance": inv.get("balance"),
            "billingAccountId": inv.get("billingAccountId"),
        }
        if args.create_link:
            prompt = build_payment_prompt_for_invoice(session, inv["id"])
            summary["payment"] = prompt.as_dict()
            if prompt.ready and prompt.payment_url:
                _pass(f"paymentUrl ready linkId={prompt.payment_link_id}")
                _info(prompt.payment_url)
                _info(
                    "Open URL in incognito → Stripe test card 4242 4242 4242 4242"
                )
            else:
                _fail(
                    f"PaymentLink not ready: {prompt.blocked_reason or prompt.warnings}"
                )
                failures.append("paymentLink")

    print()
    print("3) stale Active links (informational)")
    active = session.soql(
        "SELECT Id, Title, Amount, Status, CreatedDate FROM PaymentLink "
        "WHERE Status = 'Active' ORDER BY CreatedDate DESC LIMIT 10"
    )
    summary["activePaymentLinks"] = len(active)
    if not active:
        _info("no Active PaymentLinks")
    else:
        _info(f"{len(active)} Active PaymentLink(s) (SingleUse — leave until paid)")
        for row in active[:5]:
            _info(
                f"  {row.get('Id')} amount={row.get('Amount')} "
                f"title={row.get('Title')}"
            )

    print()
    if failures:
        print(f"RESULT: FAIL ({', '.join(failures)})")
    else:
        print("RESULT: PASS")
        print(
            "Optional live charge: open a paymentUrl in incognito "
            "(admin cookies break guest Pay Now)."
        )

    if args.json:
        summary["ok"] = not failures
        summary["failures"] = failures
        print()
        print(json.dumps(summary, indent=2, default=str))

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
