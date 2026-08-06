"""BambooHR dual-channel P3 — Quote → Order → Activate → Asset → Amend E2E."""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any

from service import API, OrgSession


@dataclass
class CheckoutResult:
    ok: bool
    quote_id: str
    order_id: str | None = None
    order_number: str | None = None
    asset_ids: list[str] = field(default_factory=list)
    asset_quantity: float | None = None
    amend_quote_id: str | None = None
    amend_order_id: str | None = None
    amend_order_number: str | None = None
    amend_requested_qty: int | None = None
    warnings: list[str] = field(default_factory=list)
    error: str | None = None

    def as_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "quoteId": self.quote_id,
            "orderId": self.order_id,
            "orderNumber": self.order_number,
            "assetIds": self.asset_ids,
            "assetQuantity": self.asset_quantity,
            "amendQuoteId": self.amend_quote_id,
            "amendOrderId": self.amend_order_id,
            "amendOrderNumber": self.amend_order_number,
            "amendRequestedQty": self.amend_requested_qty,
            # Back-compat alias used by earlier P3 smoke/UI.
            "amendTransactionId": self.amend_quote_id,
            "warnings": self.warnings,
            "error": self.error,
        }


def _patch(session: OrgSession, path: str, body: dict) -> None:
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        f"{session._instance}{path}",
        data=data,
        headers={
            "Authorization": f"Bearer {session._token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        method="PATCH",
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            resp.read()  # 204 empty is success
    except urllib.error.HTTPError as exc:
        err = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"PATCH {path} -> HTTP {exc.code}: {err[:2000]}") from exc


def reprice_quote_system(session: OrgSession, quote_id: str) -> None:
    """PST place with pricingPref=System so createOrderFromQuote accepts the quote.

    Get Pricing places with Skip + headless calculate for display; Order creation
    requires persisted UnitPrice/NetUnitPrice ("prices aren't updated" otherwise).
    """
    lines = session.soql(
        f"SELECT Id, Quantity FROM QuoteLineItem WHERE QuoteId = '{quote_id}'"
    )
    if not lines:
        raise RuntimeError(f"Quote {quote_id} has no line items to reprice")
    records: list[dict[str, Any]] = [
        {
            "referenceId": "refQuote",
            "record": {
                "attributes": {
                    "method": "PATCH",
                    "type": "Quote",
                    "id": quote_id,
                }
            },
        }
    ]
    for i, line in enumerate(lines):
        records.append(
            {
                "referenceId": f"refL{i}",
                "record": {
                    "attributes": {
                        "type": "QuoteLineItem",
                        "method": "PATCH",
                        "id": line["Id"],
                    },
                    "Quantity": str(int(line["Quantity"] or 1)),
                },
            }
        )
    placed = session.post(
        f"/services/data/{API}/connect/rev/sales-transaction/actions/place",
        {
            "pricingPref": "System",
            "catalogRatesPref": "Skip",
            "taxPref": "Skip",
            "configurationPref": {
                "configurationMethod": "Skip",
                "configurationOptions": {
                    "validateProductCatalog": True,
                    "validateAmendRenewCancel": True,
                    "executeConfigurationRules": False,
                    "addDefaultConfiguration": False,
                },
            },
            "graph": {
                "graphId": f"p3rp{uuid.uuid4().hex[:8]}",
                "records": records,
            },
        },
    )
    if isinstance(placed, list):
        placed = placed[0]
    if not placed.get("isSuccess"):
        raise RuntimeError(f"System reprice failed: {placed}")


def create_order_from_quote(session: OrgSession, quote_id: str) -> tuple[str, str | None]:
    result = session.post(
        f"/services/data/{API}/actions/standard/createOrderFromQuote",
        {"inputs": [{"quoteRecordId": quote_id}]},
    )
    entry = result[0] if isinstance(result, list) and result else None
    if not entry or not entry.get("isSuccess"):
        errs = entry.get("errors") if entry else result
        raise RuntimeError(f"createOrderFromQuote failed: {errs}")
    out = entry.get("outputValues") or {}
    order_id = out.get("orderId")
    if not order_id:
        raise RuntimeError(f"createOrderFromQuote missing orderId: {entry}")
    return order_id, out.get("orderNumber")


def set_order_shipping_from_account(session: OrgSession, order_id: str, account_id: str) -> None:
    acct = session.soql(
        "SELECT ShippingStreet, ShippingCity, ShippingState, ShippingPostalCode, "
        f"ShippingCountry FROM Account WHERE Id = '{account_id}'"
    )[0]
    payload = {
        "ShippingStreet": acct.get("ShippingStreet"),
        "ShippingCity": acct.get("ShippingCity"),
        "ShippingState": acct.get("ShippingState"),
        "ShippingPostalCode": acct.get("ShippingPostalCode"),
        "ShippingCountry": acct.get("ShippingCountry"),
    }
    if not payload.get("ShippingCity") and not payload.get("ShippingCountry"):
        raise RuntimeError(
            f"Account {account_id} has no shipping address — activation will fail"
        )
    _patch(session, f"/services/data/{API}/sobjects/Order/{order_id}", payload)


def activate_order(session: OrgSession, order_id: str) -> None:
    _patch(
        session,
        f"/services/data/{API}/sobjects/Order/{order_id}",
        {"Status": "Activated"},
    )


def place_activate_order(
    session: OrgSession, quote_id: str, account_id: str
) -> tuple[str, str | None]:
    """System reprice → createOrderFromQuote → copy shipping → Activate."""
    reprice_quote_system(session, quote_id)
    order_id, order_number = create_order_from_quote(session, quote_id)
    set_order_shipping_from_account(session, order_id, account_id)
    activate_order(session, order_id)
    return order_id, order_number


def poll_assets(session: OrgSession, order_id: str, *, timeout: int = 180) -> list[str]:
    """Poll AssetActionSource → Asset for Initial Sale on this order."""
    deadline = time.time() + timeout
    last: list[str] = []
    stable = 0
    while time.time() < deadline:
        q = (
            "SELECT AssetAction.AssetId FROM AssetActionSource "
            "WHERE ReferenceEntityItemId IN "
            f"(SELECT Id FROM OrderItem WHERE OrderId = '{order_id}') "
            "AND AssetAction.CategoryEnum = 'Initial Sale'"
        )
        try:
            rows = session.soql(q)
        except RuntimeError:
            rows = []
        ids = sorted(
            {
                r["AssetAction"]["AssetId"]
                for r in rows
                if r.get("AssetAction") and r["AssetAction"].get("AssetId")
            }
        )
        if ids and ids == last:
            stable += 1
            if stable >= 2:
                return ids
        else:
            stable = 0
            last = ids
        time.sleep(3)
    return last


def _current_asset_quantity(session: OrgSession, asset_id: str) -> float:
    """Sum AssetAction.QuantityChange (Asset.Quantity is often null for LMA)."""
    rows = session.soql(
        "SELECT QuantityChange FROM AssetAction "
        f"WHERE AssetId = '{asset_id}' AND QuantityChange != null"
    )
    total = sum(float(r.get("QuantityChange") or 0) for r in rows)
    if total == 0:
        raise RuntimeError(f"Could not resolve current quantity for asset {asset_id}")
    return total


def poll_asset_quantity(
    session: OrgSession,
    asset_id: str,
    *,
    min_qty: float,
    timeout: int = 180,
) -> float:
    """Wait until summed AssetAction qty reaches ``min_qty`` (Upsells lag activate)."""
    deadline = time.time() + timeout
    last = 0.0
    while time.time() < deadline:
        last = _current_asset_quantity(session, asset_id)
        if last >= min_qty - 1e-6:
            return last
        time.sleep(3)
    return last


def amend_asset_quantity(
    session: OrgSession,
    asset_id: str,
    new_qty: int,
    *,
    start: datetime | None = None,
) -> str | None:
    """Qty true-up via Connect amend; returns amendment quote id.

    R262 body uses ``assetIds`` + ``quantityChange`` (delta), not absolute qty.
    """
    current = _current_asset_quantity(session, asset_id)
    delta = float(new_qty) - current
    if delta == 0:
        raise RuntimeError(
            f"Amend no-op: asset {asset_id} already at quantity {current}"
        )
    # Org timezone can treat "today 00:00Z" as past — use tomorrow UTC.
    when = start or (datetime.now(timezone.utc) + timedelta(days=1))
    body = {
        "assetIds": [asset_id],
        "amendmentStartDate": when.strftime("%Y-%m-%dT00:00:00"),
        "outputRecordType": "Quote",
        "quantityChange": delta,
    }
    path = f"/services/data/{API}/connect/revenue-management/assets/actions/amend"
    try:
        result = session.post(path, body)
    except RuntimeError as exc:
        raise RuntimeError(f"Asset amend failed: {exc}") from exc
    if isinstance(result, list) and result:
        result = result[0]
    if not isinstance(result, dict):
        return None
    if result.get("success") is False:
        raise RuntimeError(f"Asset amend failed: {result.get('errors') or result}")
    return result.get("amendmentRecordId") or result.get("id")


def complete_amend_quote(
    session: OrgSession,
    amend_quote_id: str,
    account_id: str,
    asset_id: str,
    *,
    target_qty: int,
    poll_timeout: int = 180,
) -> tuple[str, str | None, float]:
    """Order + activate amendment quote; return (order_id, order_number, asset_qty)."""
    # Amend quotes often already have QuoteAccountId; fall back to caller account.
    rows = session.soql(
        f"SELECT QuoteAccountId FROM Quote WHERE Id = '{amend_quote_id}'"
    )
    acct = (rows[0].get("QuoteAccountId") if rows else None) or account_id
    order_id, order_number = place_activate_order(session, amend_quote_id, acct)
    qty = poll_asset_quantity(
        session, asset_id, min_qty=float(target_qty), timeout=poll_timeout
    )
    if qty + 1e-6 < target_qty:
        raise RuntimeError(
            f"Amend activated but asset {asset_id} qty={qty} "
            f"(expected >= {target_qty})"
        )
    return order_id, order_number, qty


def checkout_quote(
    session: OrgSession,
    quote_id: str,
    *,
    amend_qty: int | None = None,
    poll_timeout: int = 180,
) -> CheckoutResult:
    """Place order from quote, activate (assetize), optional qty amend E2E."""
    warnings: list[str] = []
    order_id: str | None = None
    order_number: str | None = None
    assets: list[str] = []
    asset_qty: float | None = None
    amend_quote: str | None = None
    amend_order: str | None = None
    amend_order_number: str | None = None

    q = session.soql(
        f"SELECT Id, QuoteAccountId, Status FROM Quote WHERE Id = '{quote_id}'"
    )
    if not q:
        return CheckoutResult(ok=False, quote_id=quote_id, error="Quote not found")
    account_id = q[0].get("QuoteAccountId")
    if not account_id:
        return CheckoutResult(
            ok=False,
            quote_id=quote_id,
            error="Quote missing QuoteAccountId — required for createOrderFromQuote",
        )

    try:
        order_id, order_number = place_activate_order(session, quote_id, account_id)
        assets = poll_assets(session, order_id, timeout=poll_timeout)
        if not assets:
            warnings.append(
                "No Initial Sale assets found within poll window — "
                "activation may still be processing."
            )
        else:
            asset_qty = _current_asset_quantity(session, assets[0])

        if amend_qty is not None and assets:
            amend_quote = amend_asset_quantity(session, assets[0], amend_qty)
            if not amend_quote:
                warnings.append(
                    "Amend API accepted but returned no amendmentRecordId — "
                    "check org for amendment quote/order."
                )
            else:
                amend_order, amend_order_number, asset_qty = complete_amend_quote(
                    session,
                    amend_quote,
                    account_id,
                    assets[0],
                    target_qty=amend_qty,
                    poll_timeout=poll_timeout,
                )
        elif amend_qty is not None and not assets:
            warnings.append("Skipped amend — no asset id available yet.")

        return CheckoutResult(
            ok=True,
            quote_id=quote_id,
            order_id=order_id,
            order_number=order_number,
            asset_ids=assets,
            asset_quantity=asset_qty,
            amend_quote_id=amend_quote,
            amend_order_id=amend_order,
            amend_order_number=amend_order_number,
            amend_requested_qty=amend_qty,
            warnings=warnings,
        )
    except Exception as exc:  # noqa: BLE001
        return CheckoutResult(
            ok=False,
            quote_id=quote_id,
            order_id=order_id,
            order_number=order_number,
            asset_ids=assets,
            asset_quantity=asset_qty,
            amend_quote_id=amend_quote,
            amend_order_id=amend_order,
            amend_order_number=amend_order_number,
            amend_requested_qty=amend_qty,
            error=str(exc),
            warnings=warnings,
        )
