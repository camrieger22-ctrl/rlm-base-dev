"""Salesforce Payments / Pay Now after BambooHR checkout.

Platform path (invoice-centric):

  Order Activated
    → BillingSchedule (ReadyForInvoicing)
    → POST /commerce/invoicing/invoices/collection/actions/generate
    → Posted Invoice
    → PaymentLink (Pay Now) → PaymentUrl

``master-demo`` typically has billing schedules after activate, but Pay Now
requires a merchant account + Pay Now site URL in Payments setup. This module
always returns a structured prompt: either a live ``paymentUrl`` or a clear
``blockedReason`` plus Invoice Lightning link when an invoice exists.
"""

from __future__ import annotations

import time
import uuid
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from typing import Any

from service import API, OrgSession


@dataclass
class PaymentPrompt:
    ready: bool
    order_id: str = ""
    invoice_id: str | None = None
    invoice_number: str | None = None
    invoice_balance: float | None = None
    payment_link_id: str | None = None
    payment_url: str | None = None
    invoice_url: str | None = None
    blocked_reason: str | None = None
    warnings: list[str] = field(default_factory=list)

    def as_dict(self) -> dict[str, Any]:
        return {
            "ready": self.ready,
            "orderId": self.order_id or None,
            "invoiceId": self.invoice_id,
            "invoiceNumber": self.invoice_number,
            "invoiceBalance": self.invoice_balance,
            "paymentLinkId": self.payment_link_id,
            "paymentUrl": self.payment_url,
            "invoiceUrl": self.invoice_url,
            "blockedReason": self.blocked_reason,
            "warnings": self.warnings,
        }


def payments_readiness(session: OrgSession) -> dict[str, Any]:
    """Lightweight org probe — does not create records."""
    gateways = session.soql(
        "SELECT Id, PaymentGatewayName, Status FROM PaymentGateway LIMIT 5"
    )
    merchants = session.soql("SELECT Id, Name FROM MerchantAccount LIMIT 5")
    webhook = session.soql(
        "SELECT Id, Name, Status FROM Network "
        "WHERE Name LIKE '%Payment%' LIMIT 5"
    )
    return {
        "paymentGatewayCount": len(gateways),
        "merchantAccountCount": len(merchants),
        "paymentsWebhookLive": any(
            (n.get("Status") or "").lower() == "live" for n in webhook
        ),
        "gateways": [
            {
                "id": g.get("Id"),
                "name": g.get("PaymentGatewayName"),
                "status": g.get("Status"),
            }
            for g in gateways
        ],
        "merchants": [
            {"id": m.get("Id"), "name": m.get("Name")} for m in merchants
        ],
    }


def _lex_url(session: OrgSession, entity: str, record_id: str) -> str:
    base = (session._instance or "").rstrip("/")
    return f"{base}/lightning/r/{entity}/{record_id}/view" if record_id else ""


def _billing_schedules_for_order(
    session: OrgSession, order_id: str
) -> list[dict[str, Any]]:
    return session.soql(
        "SELECT Id, Status, NextBillingDate FROM BillingSchedule "
        f"WHERE ReferenceEntityId = '{order_id}' "
        "ORDER BY NextBillingDate ASC NULLS LAST"
    )


def _earliest_next_billing_date(schedules: list[dict[str, Any]]) -> date | None:
    dates: list[date] = []
    for row in schedules:
        raw = row.get("NextBillingDate")
        if not raw:
            continue
        if isinstance(raw, str):
            dates.append(date.fromisoformat(raw[:10]))
        elif isinstance(raw, date):
            dates.append(raw)
    return min(dates) if dates else None


def _find_invoice_for_account(
    session: OrgSession,
    account_id: str,
    *,
    since: datetime | None = None,
) -> dict[str, Any] | None:
    """Best-effort invoice lookup (ReferenceEntityId is often null after generate)."""
    clause = f"BillingAccountId = '{account_id}' AND Status = 'Posted' AND Balance > 0"
    if since is not None:
        stamp = since.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000+0000")
        clause += f" AND CreatedDate >= {stamp}"
    rows = session.soql(
        "SELECT Id, InvoiceNumber, Status, Balance, TotalAmountWithTax, "
        "BillingAccountId, CreatedDate "
        f"FROM Invoice WHERE {clause} "
        "ORDER BY CreatedDate DESC LIMIT 5"
    )
    return rows[0] if rows else None


def generate_invoice_for_order(
    session: OrgSession,
    order_id: str,
    *,
    action: str = "Posted",
    poll_timeout: int = 90,
) -> dict[str, Any] | None:
    """Invoice the order via Billing Business API; poll for a Posted invoice.

    Uses ``targetDate`` = max(today, earliest NextBillingDate) so future-dated
    BambooHR amend starts still invoice when schedules exist.
    """
    order_rows = session.soql(
        f"SELECT Id, AccountId FROM Order WHERE Id = '{order_id}'"
    )
    if not order_rows:
        raise RuntimeError(f"Order {order_id} not found")
    account_id = order_rows[0].get("AccountId")
    if not account_id:
        raise RuntimeError(f"Order {order_id} has no AccountId")

    schedules = _billing_schedules_for_order(session, order_id)
    if not schedules:
        # Activation → BSG can lag a few seconds
        deadline = time.time() + 30
        while time.time() < deadline and not schedules:
            time.sleep(2)
            schedules = _billing_schedules_for_order(session, order_id)
    if not schedules:
        raise RuntimeError(
            f"Order {order_id} has no BillingSchedule records — "
            "Billing may not be configured for these products"
        )

    today = date.today()
    next_bill = _earliest_next_billing_date(schedules) or today
    target = max(today, next_bill)
    target_s = target.isoformat()
    started = datetime.now(timezone.utc) - timedelta(seconds=5)

    body = {
        "billingTransactionId": order_id,
        "action": action,
        "invoiceDate": target_s,
        "targetDate": target_s,
        "correlationId": f"bh-pay-{uuid.uuid4().hex[:12]}",
    }
    result = session.post(
        f"/services/data/{API}/commerce/invoicing/invoices/collection/actions/generate",
        body,
    )
    if isinstance(result, list):
        # Error array shape
        err = result[0] if result else {}
        raise RuntimeError(
            f"Invoice generate failed: {err.get('message') or err}"
        )
    if isinstance(result, dict) and result.get("success") is False:
        raise RuntimeError(f"Invoice generate failed: {result.get('errors')}")

    deadline = time.time() + poll_timeout
    while time.time() < deadline:
        inv = _find_invoice_for_account(session, account_id, since=started)
        if inv:
            return inv
        time.sleep(2)
    # Last chance without CreatedDate filter (async lag)
    return _find_invoice_for_account(session, account_id)


def _default_payment_method_set_id(session: OrgSession) -> str | None:
    """First MerchAccPaymentMethodSet on an enabled Test/Complete merchant."""
    rows = session.soql(
        "SELECT Id, MerchantAccountId, DeveloperName "
        "FROM MerchAccPaymentMethodSet "
        "ORDER BY CreatedDate ASC LIMIT 5"
    )
    return rows[0]["Id"] if rows else None


def _find_active_payment_link(
    session: OrgSession,
    *,
    account_id: str,
    amount: float,
    title_hint: str | None = None,
) -> dict[str, Any] | None:
    """Reuse an Active SingleUse link for the same account + amount when present."""
    amt = round(float(amount), 2)
    rows = session.soql(
        "SELECT Id, PaymentLinkNumber, PaymentUrl, Status, Amount, Title "
        "FROM PaymentLink "
        f"WHERE AccountId = '{account_id}' AND Status = 'Active' "
        f"AND Amount = {amt} "
        "ORDER BY CreatedDate DESC LIMIT 10"
    )
    if not rows:
        return None
    if title_hint:
        hint = title_hint[:40]
        for row in rows:
            if hint and hint in (row.get("Title") or ""):
                return row
    return rows[0]


def _create_payment_link(
    session: OrgSession,
    *,
    account_id: str,
    amount: float,
    title: str,
    reuse_active: bool = True,
) -> dict[str, Any]:
    """Create a PredefinedAmount Pay Now link; raises with Setup guidance on failure."""
    if reuse_active:
        existing = _find_active_payment_link(
            session,
            account_id=account_id,
            amount=amount,
            title_hint=title,
        )
        if existing and existing.get("PaymentUrl"):
            return existing

    expiry = (datetime.now(timezone.utc) + timedelta(days=7)).strftime(
        "%Y-%m-%dT%H:%M:%S.000Z"
    )
    method_set_id = _default_payment_method_set_id(session)
    if not method_set_id:
        raise RuntimeError(
            "No MerchAccPaymentMethodSet found — add a Card payment method "
            "set on the Stripe merchant account in Payments Setup"
        )
    fields: dict[str, Any] = {
        "Amount": round(float(amount), 2),
        "AccountId": account_id,
        "Status": "Active",
        "Type": "PredefinedAmount",
        "UsageType": "SingleUse",
        "IsBusinessAccountPayment": True,
        "Title": title[:80],
        "ExpiryTime": expiry,
        "Description": "BambooHR Get Pricing checkout",
        "PaymentMethodSetId": method_set_id,
    }
    link_id = session.create("PaymentLink", fields)
    rows = session.soql(
        f"SELECT Id, PaymentLinkNumber, PaymentUrl, Status, Amount "
        f"FROM PaymentLink WHERE Id = '{link_id}'"
    )
    if not rows:
        raise RuntimeError(f"PaymentLink {link_id} created but not readable")
    return rows[0]


def list_open_invoices(
    session: OrgSession,
    account_id: str,
    *,
    limit: int = 20,
) -> list[dict[str, Any]]:
    """Posted invoices with remaining balance for an Account (buyer Licenses UI)."""
    if not account_id:
        return []
    lim = max(1, min(int(limit), 50))
    rows = session.soql(
        "SELECT Id, InvoiceNumber, DocumentNumber, Status, Balance, "
        "TotalAmountWithTax, BillingAccountId, ReferenceEntityId, CreatedDate "
        f"FROM Invoice WHERE BillingAccountId = '{account_id}' "
        "AND Status = 'Posted' AND Balance > 0 "
        f"ORDER BY CreatedDate DESC LIMIT {lim}"
    )
    out: list[dict[str, Any]] = []
    for row in rows:
        inv_id = row["Id"]
        number = row.get("InvoiceNumber") or row.get("DocumentNumber") or inv_id
        balance = float(row.get("Balance") or 0)
        active = _find_active_payment_link(
            session,
            account_id=account_id,
            amount=balance,
            title_hint=f"Pay invoice {number}",
        )
        out.append(
            {
                "id": inv_id,
                "invoiceNumber": number,
                "documentNumber": row.get("DocumentNumber"),
                "status": row.get("Status"),
                "balance": balance,
                "totalAmountWithTax": row.get("TotalAmountWithTax"),
                "referenceEntityId": row.get("ReferenceEntityId"),
                "createdDate": row.get("CreatedDate"),
                "invoiceUrl": _lex_url(session, "Invoice", inv_id),
                "paymentLinkId": (active or {}).get("Id"),
                "paymentUrl": (active or {}).get("PaymentUrl"),
            }
        )
    return out


def build_payment_prompt_for_invoice(
    session: OrgSession,
    invoice_id: str,
) -> PaymentPrompt:
    """Create/reuse a Pay Now link for an existing Posted invoice."""
    warnings: list[str] = []
    inv_id = (invoice_id or "").strip()
    if not inv_id:
        return PaymentPrompt(
            ready=False,
            blocked_reason="invoiceId is required",
        )

    rows = session.soql(
        "SELECT Id, InvoiceNumber, DocumentNumber, Status, Balance, "
        "BillingAccountId, ReferenceEntityId "
        f"FROM Invoice WHERE Id = '{inv_id}' LIMIT 1"
    )
    if not rows:
        return PaymentPrompt(
            ready=False,
            blocked_reason=f"Invoice {inv_id} not found",
        )
    invoice = rows[0]
    account_id = invoice.get("BillingAccountId") or ""
    number = invoice.get("InvoiceNumber") or invoice.get("DocumentNumber") or inv_id
    balance = float(invoice.get("Balance") or 0)
    ref = invoice.get("ReferenceEntityId") or ""
    order_id = ref if str(ref).startswith("801") else ""

    prompt = PaymentPrompt(
        ready=False,
        order_id=order_id,
        invoice_id=inv_id,
        invoice_number=number,
        invoice_balance=balance,
        invoice_url=_lex_url(session, "Invoice", inv_id),
        warnings=warnings,
    )

    if (invoice.get("Status") or "") != "Posted":
        prompt.blocked_reason = (
            f"Invoice status is {invoice.get('Status')!r} — only Posted invoices "
            "can be collected via Pay Now"
        )
        return prompt
    if balance <= 0:
        prompt.blocked_reason = "Invoice balance is zero — nothing to collect"
        return prompt
    if not account_id:
        prompt.blocked_reason = "Invoice has no BillingAccountId"
        return prompt

    readiness = payments_readiness(session)
    if not readiness["paymentsWebhookLive"]:
        warnings.append("Payments Webhook Experience Cloud site is not Live")
        prompt.warnings = warnings
    if readiness["merchantAccountCount"] == 0:
        prompt.blocked_reason = (
            "No MerchantAccount in this org. Complete Salesforce Payments "
            "guided setup (Stripe/Adyen), set the Pay Now site URL, then retry."
        )
        return prompt

    try:
        link = _create_payment_link(
            session,
            account_id=account_id,
            amount=balance,
            title=f"Pay invoice {number}",
        )
    except Exception as exc:  # noqa: BLE001
        msg = str(exc)
        if "Pay Now site URL" in msg:
            prompt.blocked_reason = (
                "Enter the Pay Now site URL in Payments setup, then retry. "
                f"({msg[:300]})"
            )
        elif "Payment Method Set" in msg:
            prompt.blocked_reason = (
                "Payment Method Set missing — finish merchant setup in "
                f"Salesforce Payments. ({msg[:300]})"
            )
        else:
            prompt.blocked_reason = f"PaymentLink create failed: {msg[:500]}"
        return prompt

    url = link.get("PaymentUrl")
    prompt.payment_link_id = link.get("Id")
    prompt.payment_url = url
    prompt.ready = bool(url)
    if not url:
        prompt.blocked_reason = (
            "PaymentLink created but PaymentUrl is empty — check Pay Now site URL"
        )
    return prompt


def build_payment_prompt(
    session: OrgSession,
    order_id: str,
    *,
    collect: bool = True,
    poll_timeout: int = 90,
) -> PaymentPrompt:
    """After order activate: invoice + Pay Now URL when org is configured."""
    warnings: list[str] = []
    if not collect:
        return PaymentPrompt(
            ready=False,
            order_id=order_id,
            blocked_reason="collectPayment disabled for this checkout",
        )

    readiness = payments_readiness(session)
    if not readiness["paymentsWebhookLive"]:
        warnings.append("Payments Webhook Experience Cloud site is not Live")

    try:
        invoice = generate_invoice_for_order(
            session, order_id, poll_timeout=poll_timeout
        )
    except Exception as exc:  # noqa: BLE001
        return PaymentPrompt(
            ready=False,
            order_id=order_id,
            blocked_reason=f"Could not generate invoice: {exc}",
            warnings=warnings,
        )

    if not invoice:
        return PaymentPrompt(
            ready=False,
            order_id=order_id,
            blocked_reason=(
                "Invoice generate accepted but no Posted Invoice appeared "
                "within the poll window"
            ),
            warnings=warnings,
        )

    inv_id = invoice["Id"]
    balance = float(invoice.get("Balance") or 0)
    prompt = PaymentPrompt(
        ready=False,
        order_id=order_id,
        invoice_id=inv_id,
        invoice_number=invoice.get("InvoiceNumber"),
        invoice_balance=balance,
        invoice_url=_lex_url(session, "Invoice", inv_id),
        warnings=warnings,
    )

    if balance <= 0:
        prompt.blocked_reason = "Invoice balance is zero — nothing to collect"
        return prompt

    if readiness["merchantAccountCount"] == 0:
        prompt.blocked_reason = (
            "No MerchantAccount in this org. Complete Salesforce Payments "
            "guided setup (Stripe/Adyen), set the Pay Now site URL, then retry."
        )
        return prompt

    order_rows = session.soql(
        f"SELECT AccountId, OrderNumber FROM Order WHERE Id = '{order_id}'"
    )
    account_id = (order_rows[0].get("AccountId") if order_rows else None) or ""
    order_number = (order_rows[0].get("OrderNumber") if order_rows else None) or order_id
    try:
        link = _create_payment_link(
            session,
            account_id=account_id,
            amount=balance,
            title=f"Pay invoice {prompt.invoice_number or ''} ({order_number})",
        )
    except Exception as exc:  # noqa: BLE001
        msg = str(exc)
        if "Pay Now site URL" in msg:
            prompt.blocked_reason = (
                "Enter the Pay Now site URL in Payments setup, then retry. "
                f"({msg[:300]})"
            )
        elif "Payment Method Set" in msg:
            prompt.blocked_reason = (
                "Payment Method Set missing — finish merchant setup in "
                f"Salesforce Payments. ({msg[:300]})"
            )
        else:
            prompt.blocked_reason = f"PaymentLink create failed: {msg[:500]}"
        return prompt

    url = link.get("PaymentUrl")
    prompt.payment_link_id = link.get("Id")
    prompt.payment_url = url
    prompt.ready = bool(url)
    if not url:
        prompt.blocked_reason = (
            "PaymentLink created but PaymentUrl is empty — check Pay Now site URL"
        )
    return prompt
