"""Email a Pay Now paymentUrl via Salesforce Apex invocable.

Calls ``RLM_BambooPayNowEmail`` through the Actions API so the send is an org
email activity (Invoice / Account) — not BFF-side SMTP.
"""

from __future__ import annotations

import os
from typing import Any

from service import API, OrgSession


def _bff_public_base() -> str:
    """Public BFF base for licenses deep-links in the email body."""
    for key in ("BFF_PUBLIC_URL", "BAMBOO_BFF_PUBLIC_URL", "PUBLIC_BFF_URL"):
        raw = (os.environ.get(key) or "").strip().rstrip("/")
        if raw:
            return raw
    return ""


def licenses_return_url(account_id: str | None = None) -> str | None:
    base = _bff_public_base()
    if not base:
        return None
    q = "focus=invoices&paid=1"
    if account_id:
        q = f"accountId={account_id}&{q}"
    return f"{base}/account?{q}"


def send_payment_email(
    session: OrgSession,
    *,
    payment_url: str,
    invoice_id: str | None = None,
    account_id: str | None = None,
    to_address: str | None = None,
    invoice_number: str | None = None,
    amount_due: float | None = None,
    licenses_url: str | None = None,
) -> dict[str, Any]:
    """Invoke RLM_BambooPayNowEmail with a live Pay Now URL."""
    payment_url = (payment_url or "").strip()
    if not payment_url:
        raise ValueError("paymentUrl is required")

    inputs: dict[str, Any] = {"paymentUrl": payment_url}
    if invoice_id:
        inputs["invoiceId"] = invoice_id
    if account_id:
        inputs["accountId"] = account_id
    if to_address and str(to_address).strip():
        inputs["toAddress"] = str(to_address).strip()
    if invoice_number:
        inputs["invoiceNumber"] = str(invoice_number)
    if amount_due is not None:
        inputs["amountDue"] = float(amount_due)
    lic = licenses_url if licenses_url is not None else licenses_return_url(account_id)
    if lic:
        inputs["licensesUrl"] = lic

    path = f"/services/data/{API}/actions/custom/apex/RLM_BambooPayNowEmail"
    try:
        raw = session.post(path, {"inputs": [inputs]})
    except RuntimeError as exc:
        msg = str(exc)
        if "NOT_FOUND" in msg or "404" in msg:
            raise RuntimeError(
                "RLM_BambooPayNowEmail action not found — deploy "
                "unpackaged/post_bamboohr/classes/RLM_BambooPayNowEmail* "
                "and assign RLM_BambooHR"
            ) from exc
        raise

    action_row: dict[str, Any] | None = None
    if isinstance(raw, list) and raw:
        action_row = raw[0] if isinstance(raw[0], dict) else None
    elif isinstance(raw, dict):
        actions = raw.get("actions") or raw.get("results") or []
        if isinstance(actions, list) and actions:
            action_row = actions[0] if isinstance(actions[0], dict) else None
        else:
            action_row = raw

    if not action_row:
        return {
            "ok": False,
            "error": f"Unexpected Actions API response: {raw!r}"[:500],
        }

    if action_row.get("isSuccess") is False:
        errs = action_row.get("errors") or []
        err_msg = "; ".join(
            e.get("message", str(e)) if isinstance(e, dict) else str(e) for e in errs
        ) or "Apex action failed"
        return {"ok": False, "error": err_msg, "action": action_row}

    outputs = action_row.get("outputValues") or action_row
    success = outputs.get("success")
    if success is None:
        success = outputs.get("Success")
    message = outputs.get("message") or outputs.get("Message") or ""
    to_out = outputs.get("toAddress") or outputs.get("ToAddress") or to_address

    if isinstance(outputs.get("outputValues"), dict):
        inner = outputs["outputValues"]
        success = inner.get("success", success)
        message = inner.get("message") or message
        to_out = inner.get("toAddress") or to_out

    ok = bool(success) if success is not None else True
    if message and success is not None and not success:
        ok = False

    return {
        "ok": ok,
        "toAddress": to_out,
        "message": message or ("Email sent" if ok else "Email failed"),
        "invoiceId": invoice_id,
        "paymentUrl": payment_url,
        "licensesUrl": lic,
        "action": action_row,
    }
