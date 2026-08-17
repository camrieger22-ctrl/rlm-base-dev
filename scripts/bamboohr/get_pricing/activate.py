"""Post-pay activation checklist (thin BFF stub).

Real product onboarding lives later in Experience Cloud / BambooHR product.
This module returns a demo checklist so buyers see an aha step after Pay Now.
"""

from __future__ import annotations

from typing import Any
from urllib.parse import quote

from service import OrgSession


def _soql_str(value: str) -> str:
    return (value or "").replace("\\", "\\\\").replace("'", "\\'")


def build_activate_checklist(
    session: OrgSession,
    *,
    account_id: str | None = None,
    company: str | None = None,
) -> dict[str, Any]:
    """Return activation checklist for an Account (or empty stub when unknown)."""
    account_id = (account_id or "").strip() or None
    company = (company or "").strip() or None

    acct: dict[str, Any] | None = None
    if account_id or company:
        from account_console import resolve_account_id

        acct = resolve_account_id(session, account_id=account_id, company=company)
        account_id = acct["Id"]

    paid = False
    payment: dict[str, Any] | None = None
    login_ready = False
    asset_count = 0
    contact_id: str | None = None

    if account_id:
        aid = _soql_str(account_id)
        pays = session.soql(
            "SELECT Id, Amount, Status, CreatedDate "
            f"FROM Payment WHERE AccountId = '{aid}' AND Status = 'Processed' "
            "ORDER BY CreatedDate DESC LIMIT 3"
        )
        if pays:
            paid = True
            payment = {
                "id": pays[0]["Id"],
                "amount": pays[0].get("Amount"),
                "status": pays[0].get("Status"),
                "createdDate": pays[0].get("CreatedDate"),
            }
        else:
            links = session.soql(
                "SELECT Id, Status, Amount FROM PaymentLink "
                f"WHERE AccountId = '{aid}' AND Status = 'Disabled' "
                "ORDER BY CreatedDate DESC LIMIT 1"
            )
            if links:
                paid = True
                payment = {
                    "paymentLinkId": links[0]["Id"],
                    "amount": links[0].get("Amount"),
                    "status": "link_disabled",
                }

        asset_rows = session.soql(
            f"SELECT Id FROM Asset WHERE AccountId = '{aid}' LIMIT 50"
        )
        asset_count = len(asset_rows)

        contacts = session.soql(
            f"SELECT Id FROM Contact WHERE AccountId = '{aid}' "
            "ORDER BY CreatedDate DESC LIMIT 1"
        )
        if contacts:
            contact_id = contacts[0]["Id"]
            users = session.soql(
                "SELECT Id FROM User WHERE ContactId = "
                f"'{_soql_str(contact_id)}' AND IsActive = true LIMIT 1"
            )
            login_ready = bool(users)

    name = (acct or {}).get("Name") or "your company"
    aid_q = quote(account_id or "", safe="")
    licenses_href = (
        f"/account?accountId={aid_q}&focus=invoices" if account_id else "/account"
    )

    steps = [
        {
            "id": "paid",
            "label": "Payment received",
            "done": paid,
            "detail": (
                f"${float(payment['amount']):,.2f} processed"
                if payment and payment.get("amount") is not None
                else ("Card authorized" if paid else "Complete Pay Now first")
            ),
        },
        {
            "id": "assets",
            "label": "Licenses activated in Revenue Cloud",
            "done": asset_count > 0,
            "detail": f"{asset_count} asset(s)" if asset_count else "Waiting on assets",
        },
        {
            "id": "login",
            "label": "Create your BambooHR login",
            "done": login_ready,
            "detail": "Community user ready" if login_ready else "Use Create login on your quote",
        },
        {
            "id": "licenses",
            "label": "Review seats & modules",
            "done": False,
            "href": licenses_href,
            "detail": "Open Licenses & billing",
        },
        {
            "id": "employees",
            "label": "Add your first employees",
            "done": False,
            "stub": True,
            "detail": "Coming soon — product onboarding",
        },
        {
            "id": "invite",
            "label": "Invite an admin teammate",
            "done": False,
            "stub": True,
            "detail": "Coming soon — product onboarding",
        },
        {
            "id": "timeoff",
            "label": "Set up time off policies",
            "done": False,
            "stub": True,
            "detail": "Coming soon — product onboarding",
        },
    ]

    done_count = sum(1 for s in steps if s.get("done"))
    return {
        "ok": True,
        "accountId": account_id,
        "accountName": name if acct else None,
        "contactId": contact_id,
        "paid": paid,
        "payment": payment,
        "assetCount": asset_count,
        "loginReady": login_ready,
        "licensesUrl": licenses_href,
        "steps": steps,
        "progress": {"done": done_count, "total": len(steps)},
        "message": (
            f"Welcome to BambooHR, {name} — finish the checklist to get value fast."
            if account_id
            else "Pay your invoice, create a login, then return here to activate."
        ),
        "stub": True,
    }
