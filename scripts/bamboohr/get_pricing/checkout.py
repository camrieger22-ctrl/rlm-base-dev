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

from service import API, CORE_FLAT_SKU, OrgSession, volume_rate


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


def ensure_bill_to_contact(session: OrgSession, account_id: str) -> str:
    """Return a Contact Id on the account (create a demo contact if none)."""
    rows = session.soql(
        f"SELECT Id FROM Contact WHERE AccountId = '{account_id}' LIMIT 1"
    )
    if rows:
        return rows[0]["Id"]
    acct = session.soql(
        f"SELECT Name, CurrencyIsoCode FROM Account WHERE Id = '{account_id}'"
    )[0]
    fields: dict[str, Any] = {
        "AccountId": account_id,
        "FirstName": "Demo",
        "LastName": "Buyer",
        "Email": "demo.buyer@example.com",
    }
    cur = acct.get("CurrencyIsoCode")
    if cur:
        fields["CurrencyIsoCode"] = cur
    return session.create("Contact", fields)


def set_order_bill_to_contact(
    session: OrgSession, order_id: str, contact_id: str
) -> None:
    _patch(
        session,
        f"/services/data/{API}/sobjects/Order/{order_id}",
        {"BillToContactId": contact_id, "ShipToContactId": contact_id},
    )


def activate_order(session: OrgSession, order_id: str) -> None:
    _patch(
        session,
        f"/services/data/{API}/sobjects/Order/{order_id}",
        {"Status": "Activated"},
    )


def resolve_volume_tier_percent(
    session: OrgSession,
    *,
    product2_id: str,
    product_selling_model_id: str | None,
    currency: str,
    headcount: int,
) -> tuple[float, str | None]:
    """Look up Volume ``PriceAdjustmentTier.TierValue`` for post-amend headcount.

    Returns ``(percent, tier_id)``. Falls back to the demo ladder in
    ``volume_rate`` when no matching tier row exists (e.g. below lower bound).
    """
    hc = int(headcount)
    cur = (currency or "USD").upper()
    if hc < 1 or not product2_id:
        return 0.0, None

    pas_rows = session.soql(
        "SELECT Id FROM PriceAdjustmentSchedule "
        f"WHERE ScheduleType = 'Volume' AND CurrencyIsoCode = '{cur}' LIMIT 1"
    )
    if not pas_rows:
        return round(volume_rate(hc) * 100.0, 2), None

    pas_id = pas_rows[0]["Id"]
    psm_filter = ""
    if product_selling_model_id:
        psm_filter = f"AND ProductSellingModelId = '{product_selling_model_id}' "

    tiers = session.soql(
        "SELECT Id, LowerBound, UpperBound, TierValue, ProductSellingModelId "
        "FROM PriceAdjustmentTier "
        f"WHERE PriceAdjustmentScheduleId = '{pas_id}' "
        f"AND Product2Id = '{product2_id}' "
        f"AND CurrencyIsoCode = '{cur}' "
        f"{psm_filter}"
        f"AND LowerBound <= {hc} "
        f"AND (UpperBound = null OR UpperBound >= {hc}) "
        "ORDER BY LowerBound DESC LIMIT 5"
    )
    if not tiers and product_selling_model_id:
        # Retry without PSM in case amend line PSM differs from tier rows.
        tiers = session.soql(
            "SELECT Id, LowerBound, UpperBound, TierValue, ProductSellingModelId "
            "FROM PriceAdjustmentTier "
            f"WHERE PriceAdjustmentScheduleId = '{pas_id}' "
            f"AND Product2Id = '{product2_id}' "
            f"AND CurrencyIsoCode = '{cur}' "
            f"AND LowerBound <= {hc} "
            f"AND (UpperBound = null OR UpperBound >= {hc}) "
            "ORDER BY LowerBound DESC LIMIT 5"
        )
    if not tiers:
        return round(volume_rate(hc) * 100.0, 2), None

    tier = tiers[0]
    return float(tier.get("TierValue") or 0), tier.get("Id")


def apply_amend_volume_pricing(
    session: OrgSession,
    quote_id: str,
    *,
    volume_headcount: int,
) -> None:
    """Stamp post-amend headcount and System-reprice for Volume on amends.

    Amend lines use ``ItemPricingSource = LastTransaction`` and delta
    ``Quantity``, so OOTB Volume skips them. The BambooHR overlay
    (``ApplyBambooHRAmendVolumeDiscount``) runs Volume Discount when
    ``RLM_Amend_Volume_Qty__c`` is set — BFF stamps that field to the
    absolute post-amend headcount, then System-reprices.

    If Net still misses the schedule tier (overlay not applied / context
    missing), falls back to Force + QLI ``Discount`` so demos stay correct.
    """
    from service import _system_reprice_quote  # local package

    qcur = session.soql(
        f"SELECT CurrencyIsoCode FROM Quote WHERE Id = '{quote_id}'"
    )
    currency = (qcur[0].get("CurrencyIsoCode") if qcur else None) or "USD"

    lines = session.soql(
        "SELECT Id, Quantity, UnitPrice, NetUnitPrice, Discount, Product2Id, "
        "ProductSellingModelId, Product2.StockKeepingUnit, "
        "PricebookEntry.UnitPrice, RLM_Amend_Volume_Qty__c "
        f"FROM QuoteLineItem WHERE QuoteId = '{quote_id}'"
    )
    if not lines:
        raise RuntimeError(f"Quote {quote_id} has no lines for amend volume")

    headcount = int(volume_headcount)
    pepm_lines: list[dict[str, Any]] = []
    for line in lines:
        sku = (line.get("Product2") or {}).get("StockKeepingUnit") or ""
        if not sku or sku == CORE_FLAT_SKU or "FLAT" in sku.upper():
            continue
        list_p = float((line.get("PricebookEntry") or {}).get("UnitPrice") or 0)
        if list_p <= 0:
            continue
        pepm_lines.append(line)

    if not pepm_lines:
        return

    # REST stamp (Place Skip often strips custom fields on amend Quotes).
    try:
        session.patch(
            "Quote",
            quote_id,
            {"RLM_Bamboo_Amend_Volume__c": True},
        )
    except Exception as exc:  # noqa: BLE001
        raise RuntimeError(
            f"Could not stamp Quote.RLM_Bamboo_Amend_Volume__c on {quote_id}: "
            f"{exc}. Deploy unpackaged/post_bamboohr and apply "
            "apply_context_bamboohr_amend_volume."
        ) from exc
    for line in pepm_lines:
        try:
            session.patch(
                "QuoteLineItem",
                line["Id"],
                {"RLM_Amend_Volume_Qty__c": headcount, "Discount": 0},
            )
        except Exception as exc:  # noqa: BLE001
            raise RuntimeError(
                f"Could not stamp RLM_Amend_Volume_Qty__c on {line['Id']}: "
                f"{exc}. Deploy unpackaged/post_bamboohr and apply "
                "apply_context_bamboohr_amend_volume."
            ) from exc

    _system_reprice_quote(session, quote_id)

    # Verify Volume landed; Discount fallback if overlay missing.
    lines_after = session.soql(
        "SELECT Id, Quantity, NetUnitPrice, Discount, Product2Id, "
        "ProductSellingModelId, Product2.StockKeepingUnit, "
        "PricebookEntry.UnitPrice "
        f"FROM QuoteLineItem WHERE QuoteId = '{quote_id}'"
    )
    fallback_records: list[dict[str, Any]] = [
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
    patched = 0
    for i, line in enumerate(lines_after):
        sku = (line.get("Product2") or {}).get("StockKeepingUnit") or ""
        if not sku or sku == CORE_FLAT_SKU or "FLAT" in sku.upper():
            continue
        list_p = float((line.get("PricebookEntry") or {}).get("UnitPrice") or 0)
        if list_p <= 0:
            continue
        vol_pct, _tier_id = resolve_volume_tier_percent(
            session,
            product2_id=line.get("Product2Id") or "",
            product_selling_model_id=line.get("ProductSellingModelId"),
            currency=currency,
            headcount=headcount,
        )
        expected_net = round(list_p * (1.0 - vol_pct / 100.0), 2)
        net = float(line.get("NetUnitPrice") or line.get("UnitPrice") or 0)
        if abs(net - expected_net) < 0.02:
            continue
        fallback_records.append(
            {
                "referenceId": f"refL{i}",
                "record": {
                    "attributes": {
                        "type": "QuoteLineItem",
                        "method": "PATCH",
                        "id": line["Id"],
                    },
                    "Quantity": str(int(float(line.get("Quantity") or 1))),
                    "UnitPrice": list_p,
                    "Discount": vol_pct,
                    "RLM_Amend_Volume_Qty__c": headcount,
                },
            }
        )
        patched += 1

    if patched == 0:
        return

    placed = session.post(
        f"/services/data/{API}/connect/rev/sales-transaction/actions/place",
        {
            "pricingPref": "Force",
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
                "graphId": f"p3av{uuid.uuid4().hex[:8]}",
                "records": fallback_records,
            },
        },
    )
    if isinstance(placed, list):
        placed = placed[0]
    if not placed.get("isSuccess"):
        raise RuntimeError(f"Amend volume Force fallback failed: {placed}")


def place_activate_order(
    session: OrgSession,
    quote_id: str,
    account_id: str,
    *,
    volume_headcount: int | None = None,
) -> tuple[str, str | None]:
    """System reprice → createOrderFromQuote → copy shipping → Activate.

    Pass ``volume_headcount`` for amendment quotes (post-amend absolute qty) so
    ``RLM_Amend_Volume_Qty__c`` is stamped and System Volume runs (Discount
    fallback only if the amend Volume overlay is missing).
    """
    from service import _custom_price_quote  # local package

    qcur = session.soql(
        f"SELECT CurrencyIsoCode FROM Quote WHERE Id = '{quote_id}'"
    )
    currency = (qcur[0].get("CurrencyIsoCode") if qcur else None) or "USD"
    reprice_quote_system(session, quote_id)
    if volume_headcount is not None:
        apply_amend_volume_pricing(
            session, quote_id, volume_headcount=int(volume_headcount)
        )
    elif currency != "USD":
        # Same corporate-USD bleed as Get Pricing — restamp native currency.
        lines = session.soql(
            "SELECT Id, Quantity, Product2.StockKeepingUnit, "
            "PricebookEntry.UnitPrice, PricebookEntry.Product2.StockKeepingUnit "
            f"FROM QuoteLineItem WHERE QuoteId = '{quote_id}'"
        )
        by_sku: dict[str, tuple[int, float, float]] = {}
        for line in lines:
            sku = (line.get("Product2") or {}).get("StockKeepingUnit") or ""
            pbe = line.get("PricebookEntry") or {}
            list_p = float(pbe.get("UnitPrice") or 0)
            qty = int(line.get("Quantity") or 1)
            # PEPM plans/add-ons: volume on qty; flat SKU qty 1 → no volume.
            vol = 0.0 if qty == 1 and "FLAT" in sku else volume_rate(qty)
            net = round(list_p * (1.0 - vol), 2)
            by_sku[sku] = (qty, list_p, net)
        if by_sku:
            _custom_price_quote(session, quote_id, by_sku)
    order_id, order_number = create_order_from_quote(session, quote_id)
    set_order_shipping_from_account(session, order_id, account_id)
    contact_id = ensure_bill_to_contact(session, account_id)
    set_order_bill_to_contact(session, order_id, contact_id)
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
    """Latest contracted qty from AssetAction.TotalQuantity (fallback: sum changes)."""
    rows = session.soql(
        "SELECT QuantityChange, TotalQuantity FROM AssetAction "
        f"WHERE AssetId = '{asset_id}' AND QuantityChange != null "
        "ORDER BY CreatedDate DESC LIMIT 1"
    )
    if rows and rows[0].get("TotalQuantity") is not None:
        total = float(rows[0]["TotalQuantity"])
        if total != 0:
            return total
    rows = session.soql(
        "SELECT QuantityChange FROM AssetAction "
        f"WHERE AssetId = '{asset_id}' AND QuantityChange != null"
    )
    total = sum(float(r.get("QuantityChange") or 0) for r in rows)
    if total == 0:
        raise RuntimeError(f"Could not resolve current quantity for asset {asset_id}")
    return total


def asset_quantity_at(
    session: OrgSession,
    asset_id: str,
    *,
    as_of: datetime | None = None,
) -> float:
    """Quantity covering ``as_of`` from AssetStatePeriod (amend delta basis).

    Connect amend validates quantityChange against the ASP in effect on
    ``amendmentStartDate``, not lifetime TotalQuantity. Using the wrong basis
    makes decreases look like over-reductions ("less than zero").
    """
    when = as_of or datetime.now(timezone.utc)
    # Compare as date strings; ASP datetimes are org/GMT ISO.
    day = when.strftime("%Y-%m-%d")
    periods = session.soql(
        "SELECT Quantity, StartDate, EndDate FROM AssetStatePeriod "
        f"WHERE AssetId = '{asset_id}' ORDER BY StartDate ASC LIMIT 200"
    )
    for period in periods:
        start = str(period.get("StartDate") or "")[:10]
        end = str(period.get("EndDate") or "9999-12-31")[:10]
        if start and start <= day <= end:
            qty = period.get("Quantity")
            if qty is not None:
                return float(qty)
    # No ASP for that day — fall back to latest TotalQuantity.
    return _current_asset_quantity(session, asset_id)


def latest_asp_start(session: OrgSession, asset_id: str) -> datetime | None:
    """StartDate of the newest AssetStatePeriod (UTC date at 12:00)."""
    rows = session.soql(
        "SELECT StartDate FROM AssetStatePeriod "
        f"WHERE AssetId = '{asset_id}' ORDER BY StartDate DESC LIMIT 1"
    )
    if not rows or not rows[0].get("StartDate"):
        return None
    day = str(rows[0]["StartDate"])[:10]
    try:
        y, m, d = (int(x) for x in day.split("-"))
        return datetime(y, m, d, 12, 0, 0, tzinfo=timezone.utc)
    except ValueError:
        return None


def resolve_amend_start(
    session: OrgSession,
    asset_ids: list[str],
    requested: datetime | None,
) -> datetime:
    """Pick an amendment start that lands on the latest ASP for reliable decreases.

    Prior upsells often create future ASPs. Amending \"tomorrow\" while the
    high seat count only exists on a later ASP makes Salesforce reject
    decreases as over-reductions. Bump start forward to the newest ASP start
    (never earlier than tomorrow UTC).
    """
    tomorrow = datetime.now(timezone.utc) + timedelta(days=1)
    tomorrow = datetime(
        tomorrow.year, tomorrow.month, tomorrow.day, 12, 0, 0, tzinfo=timezone.utc
    )
    when = requested or tomorrow
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    when = datetime(when.year, when.month, when.day, 12, 0, 0, tzinfo=timezone.utc)
    if when < tomorrow:
        when = tomorrow
    floor = when
    for aid in asset_ids:
        latest = latest_asp_start(session, aid)
        if latest and latest > floor:
            floor = latest
    return floor


def discard_stale_amend_drafts(
    session: OrgSession,
    account_id: str,
    *,
    keep_quote_ids: list[str] | None = None,
) -> list[str]:
    """Delete or cancel Draft Amendment Quotes for an Account (preview hygiene).

    Tags Description with a cleanup marker before delete/cancel so org audits
    can tell preview leftovers from intentional drafts. Returns handled Quote
    ids. Keeps any ids in ``keep_quote_ids``.
    """
    keep = {k for k in (keep_quote_ids or []) if k}
    # QuoteAccountId is the RLM account FK; also match classic AccountId.
    # Description is not filterable in SOQL — select it and match in Python.
    rows = session.soql(
        "SELECT Id, Name, QuoteNumber, Description FROM Quote "
        f"WHERE Status = 'Draft' "
        f"AND (QuoteAccountId = '{account_id}' OR AccountId = '{account_id}') "
        "AND (Name LIKE 'Amendment%' OR Name LIKE '%Amendment%') "
        "ORDER BY CreatedDate DESC LIMIT 100"
    )
    deleted: list[str] = []
    tag = "[bamboohr-preview] stale amend draft — auto-cleanup"
    for row in rows:
        qid = row["Id"]
        if qid in keep:
            continue
        name = (row.get("Name") or "").lower()
        desc = (row.get("Description") or "").strip()
        if (
            "amendment" not in name
            and "[bamboohr-preview]" not in desc
        ):
            continue
        if "[bamboohr-preview]" not in desc:
            try:
                session.patch(
                    "Quote",
                    qid,
                    {"Description": (desc + "\n" + tag).strip() if desc else tag},
                )
            except Exception:
                pass
        try:
            session.delete("Quote", qid)
            deleted.append(qid)
            continue
        except Exception:
            pass
        for status in ("Denied", "Rejected", "Cancelled"):
            try:
                session.patch("Quote", qid, {"Status": status})
                deleted.append(qid)
                break
            except Exception:
                continue
    return deleted


def tag_amend_preview_quote(session: OrgSession, quote_id: str) -> None:
    """Mark a freshly created amend draft so hygiene can find it later."""
    if not quote_id:
        return
    try:
        rows = session.soql(
            f"SELECT Description FROM Quote WHERE Id = '{quote_id}' LIMIT 1"
        )
        desc = ((rows[0].get("Description") if rows else None) or "").strip()
        marker = "[bamboohr-preview]"
        if marker in desc:
            return
        session.patch(
            "Quote",
            quote_id,
            {
                "Description": (
                    (desc + "\n" + marker).strip() if desc else marker
                )
            },
        )
    except Exception:
        pass


def poll_asset_quantity(
    session: OrgSession,
    asset_id: str,
    *,
    min_qty: float | None = None,
    target_qty: float | None = None,
    timeout: int = 180,
) -> float:
    """Wait until asset qty reaches target (increase or decrease).

    Prefer ``target_qty`` (equality). ``min_qty`` kept for older callers
    (treat as target for increases).
    """
    goal = target_qty if target_qty is not None else min_qty
    if goal is None:
        raise ValueError("target_qty or min_qty is required")
    deadline = time.time() + timeout
    last = 0.0
    while time.time() < deadline:
        last = _current_asset_quantity(session, asset_id)
        if abs(last - float(goal)) < 0.51:
            return last
        # Upsell lag: accept at-or-above when increasing.
        if min_qty is not None and target_qty is None and last >= min_qty - 1e-6:
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
    """Qty true-up for one asset via Connect amend; returns amendment quote id."""
    return amend_assets_quantity(session, [asset_id], new_qty, start=start)


def amend_assets_quantity(
    session: OrgSession,
    asset_ids: list[str],
    new_qty: int,
    *,
    start: datetime | None = None,
    quantity_change: float | None = None,
) -> str | None:
    """Qty true-up via Connect amend for one or more assets; returns quote id.

    R262 body uses ``assetIds`` + ``quantityChange`` (delta), not absolute qty.
    Delta is computed from **ASP quantity on amendmentStartDate** unless
    ``quantity_change`` is passed explicitly.
    """
    ids = [a for a in asset_ids if a]
    if not ids:
        raise RuntimeError("assetIds is required for amend")
    when = resolve_amend_start(session, ids, start)

    if quantity_change is None:
        current = asset_quantity_at(session, ids[0], as_of=when)
        quantity_change = float(new_qty) - current
    if abs(float(quantity_change)) < 1e-9:
        raise RuntimeError(
            f"Amend no-op: asset(s) already at target quantity ({new_qty}) "
            f"on {when.date().isoformat()}"
        )
    if float(new_qty) < 1:
        raise RuntimeError("newQty must be >= 1")
    # Guard over-reduction against ASP-at-start for clearer errors.
    for aid in ids:
        at_start = asset_quantity_at(session, aid, as_of=when)
        if float(quantity_change) < 0 and at_start + float(quantity_change) < -1e-9:
            raise RuntimeError(
                f"Cannot decrease asset {aid}: quantity on "
                f"{when.date().isoformat()} is {at_start:g}; "
                f"requested change {quantity_change:+g} would go below zero. "
                f"Pick a later start date (after future upsells) or a higher seat count."
            )

    body = {
        "assetIds": ids,
        "amendmentStartDate": when.strftime("%Y-%m-%dT00:00:00.000Z"),
        "outputRecordType": "Quote",
        "quantityChange": float(quantity_change),
    }
    path = f"/services/data/{API}/connect/revenue-management/assets/actions/amend"
    try:
        result = session.post(path, body)
    except RuntimeError as exc:
        msg = str(exc)
        if "less than zero" in msg.lower() or "INVALID_API_INPUT" in msg:
            raise RuntimeError(
                f"Asset amend failed (decrease/start-date conflict): {msg}. "
                "Tip: set Change starts after pending future quantity changes, "
                "or discard stale Draft amendment Quotes first."
            ) from exc
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
    asset_ids: list[str] | None = None,
) -> tuple[str, str | None, float]:
    """Order + activate amendment quote; return (order_id, order_number, asset_qty)."""
    # Amend quotes often already have QuoteAccountId; fall back to caller account.
    rows = session.soql(
        f"SELECT QuoteAccountId FROM Quote WHERE Id = '{amend_quote_id}'"
    )
    acct = (rows[0].get("QuoteAccountId") if rows else None) or account_id
    # Volume bands must use post-amend headcount, not the delta Quantity on the line.
    order_id, order_number = place_activate_order(
        session,
        amend_quote_id,
        acct,
        volume_headcount=int(target_qty),
    )
    poll_ids = [a for a in (asset_ids or [asset_id]) if a]
    last_qty = 0.0
    for aid in poll_ids:
        qty = poll_asset_quantity(
            session, aid, target_qty=float(target_qty), timeout=poll_timeout
        )
        last_qty = qty
        if abs(qty - float(target_qty)) > 0.51:
            raise RuntimeError(
                f"Amend activated but asset {aid} qty={qty} "
                f"(expected {target_qty})"
            )
    return order_id, order_number, last_qty


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
