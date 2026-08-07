"""Verify Experience Cloud → BFF HMAC handoff tokens (Phase 5b).

Token format (Apex RLM_BambooEcIdentity.buildHandoffToken):
  base64(json).base64(hmac_sha256(secret, payload_b64))

JSON payload keys: aid (Account Id), cid (Contact Id), exp (unix seconds), n (nonce).
Secret: env EC_HANDOFF_SECRET must match Custom Label RLM_Bamboo_Ec_Handoff_Secret.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import time
from typing import Any


class EcHandoffError(ValueError):
    """Invalid or expired EC handoff token."""


def handoff_secret() -> str:
    secret = (os.environ.get("EC_HANDOFF_SECRET") or "").strip()
    if not secret:
        raise EcHandoffError(
            "EC_HANDOFF_SECRET is not set. Copy the value of Custom Label "
            "RLM_Bamboo_Ec_Handoff_Secret into scripts/bamboohr/get_pricing/.env"
        )
    return secret


def _b64_decode(raw: str) -> bytes:
    pad = "=" * (-len(raw) % 4)
    return base64.b64decode(raw + pad)


def verify_ec_token(token: str, *, secret: str | None = None, now: float | None = None) -> dict[str, Any]:
    """Return {accountId, contactId, exp} or raise EcHandoffError."""
    if not token or "." not in token:
        raise EcHandoffError("Malformed EC handoff token")
    payload_b64, sig_b64 = token.split(".", 1)
    key = (secret if secret is not None else handoff_secret()).encode("utf-8")
    expected = base64.b64encode(
        hmac.new(key, payload_b64.encode("utf-8"), hashlib.sha256).digest()
    ).decode("ascii")
    if not hmac.compare_digest(expected, sig_b64):
        raise EcHandoffError("Invalid EC handoff signature")

    try:
        payload = json.loads(_b64_decode(payload_b64).decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        raise EcHandoffError("Invalid EC handoff payload") from exc

    account_id = payload.get("aid")
    contact_id = payload.get("cid")
    exp = payload.get("exp")
    if not account_id or not contact_id or exp is None:
        raise EcHandoffError("EC handoff payload missing aid/cid/exp")

    try:
        exp_ts = float(exp)
    except (TypeError, ValueError) as exc:
        raise EcHandoffError("EC handoff exp is not a number") from exc

    if (now if now is not None else time.time()) > exp_ts:
        raise EcHandoffError("EC handoff token expired — open Licenses again from the site")

    return {
        "accountId": str(account_id),
        "contactId": str(contact_id),
        "exp": int(exp_ts),
    }
