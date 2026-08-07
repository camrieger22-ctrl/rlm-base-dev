"""Email a Quote (+ optional DocGen PDF) via Salesforce Apex invocable.

Calls ``RLM_BambooQuoteEmail`` through the Actions API so the send is an org
email activity on the Quote — not a BFF-side SMTP integration.
"""

from __future__ import annotations

from typing import Any

from docgen import DEFAULT_TEMPLATE, generate_quote_pdf
from service import API, OrgSession


def send_quote_email(
    session: OrgSession,
    quote_id: str,
    *,
    to_address: str | None = None,
    content_version_id: str | None = None,
    attach_pdf: bool = True,
    template_name: str | None = None,
    timeout: int = 180,
) -> dict[str, Any]:
    """Generate PDF (optional) and invoke RLM_BambooQuoteEmail."""
    quote_id = (quote_id or "").strip()
    if not quote_id:
        raise ValueError("quoteId is required")

    cv_id = (content_version_id or "").strip() or None
    docgen_payload: dict[str, Any] | None = None
    if attach_pdf and not cv_id:
        pdf = generate_quote_pdf(
            session,
            quote_id,
            template_name=(template_name or DEFAULT_TEMPLATE),
            timeout=timeout,
        )
        docgen_payload = pdf.as_dict()
        if not pdf.ok or not pdf.content_version_id:
            return {
                "ok": False,
                "quoteId": quote_id,
                "error": pdf.error or "DocGen PDF failed before email",
                "docgen": docgen_payload,
            }
        cv_id = pdf.content_version_id

    inputs: dict[str, Any] = {"quoteId": quote_id}
    if cv_id:
        inputs["contentVersionId"] = cv_id
    if to_address and str(to_address).strip():
        inputs["toAddress"] = str(to_address).strip()

    path = f"/services/data/{API}/actions/custom/apex/RLM_BambooQuoteEmail"
    try:
        raw = session.post(path, {"inputs": [inputs]})
    except RuntimeError as exc:
        msg = str(exc)
        if "NOT_FOUND" in msg or "404" in msg:
            raise RuntimeError(
                "RLM_BambooQuoteEmail action not found — deploy "
                "unpackaged/post_bamboohr/classes/RLM_BambooQuoteEmail* "
                "and assign RLM_BambooHR"
            ) from exc
        raise

    # Actions API returns { "actions": [ { "isSuccess", "outputValues", "errors" } ] }
    # or a list — normalize.
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
            "quoteId": quote_id,
            "error": f"Unexpected Actions API response: {raw!r}"[:500],
            "docgen": docgen_payload,
        }

    if action_row.get("isSuccess") is False:
        errs = action_row.get("errors") or []
        err_msg = "; ".join(
            e.get("message", str(e)) if isinstance(e, dict) else str(e) for e in errs
        ) or "Apex action failed"
        return {
            "ok": False,
            "quoteId": quote_id,
            "error": err_msg,
            "docgen": docgen_payload,
            "action": action_row,
        }

    outputs = action_row.get("outputValues") or action_row
    # Invocable outputs may be nested under outputValues with typed keys
    success = outputs.get("success")
    if success is None:
        success = outputs.get("Success")
    message = outputs.get("message") or outputs.get("Message") or ""
    to_out = outputs.get("toAddress") or outputs.get("ToAddress") or to_address

    # Some API shapes wrap invocable List<Result> differently
    if isinstance(outputs.get("outputValues"), dict):
        inner = outputs["outputValues"]
        success = inner.get("success", success)
        message = inner.get("message") or message
        to_out = inner.get("toAddress") or to_out

    ok = bool(success) if success is not None else True
    if message and not success and success is not None:
        ok = False

    return {
        "ok": ok,
        "quoteId": quote_id,
        "toAddress": to_out,
        "message": message or ("Email sent" if ok else "Email failed"),
        "contentVersionId": cv_id,
        "docgen": docgen_payload,
        "action": action_row,
    }
