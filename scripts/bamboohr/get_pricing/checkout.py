"""BambooHR dual-channel P3 — Quote → Order → Activate → Asset → Amend E2E."""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from typing import Any

from service import (
    API,
    CATALOG_PLAN_SKUS,
    CORE_FLAT_SKU,
    COUNTRY_SHIPPING,
    OrgSession,
    PATH_B_BUNDLE_SAVE,
    US_ONLY_ADDONS,
    _pbe_for_sku,
    add_calendar_months,
    remaining_service_end,
    volume_rate,
)

# Path B a la carte — same plan set as RLM_BambooPathBBundleSave.cls
_PATH_B_PLAN_SKUS = frozenset({*CATALOG_PLAN_SKUS, CORE_FLAT_SKU})
_PATH_B_REQUIRED_ADDONS = frozenset({"BAMBOO-ADD-PAYROLL", "BAMBOO-ADD-BENEFITS"})


def path_b_skus_eligible(skus: set[str] | list[str] | tuple[str, ...]) -> bool:
    """True when stack is a la carte plan + Payroll + Benefits (no Workforce package)."""
    upper = {str(s or "").upper() for s in skus if s}
    if not upper:
        return False
    has_plan = bool(upper & _PATH_B_PLAN_SKUS)
    has_package = any(s.startswith("BAMBOO-PKG-") for s in upper)
    return has_plan and not has_package and _PATH_B_REQUIRED_ADDONS <= upper


def account_owned_skus(session: OrgSession, account_id: str) -> set[str]:
    """Asset SKUs on the Account (for Path B eligibility beyond Quote lines)."""
    aid = (account_id or "").replace("'", "\\'")
    if not aid:
        return set()
    rows = session.soql(
        "SELECT Product2.StockKeepingUnit FROM Asset "
        f"WHERE AccountId = '{aid}' "
        "AND Product2.StockKeepingUnit != null "
        "LIMIT 200"
    )
    return {
        ((r.get("Product2") or {}).get("StockKeepingUnit") or "").upper()
        for r in rows
        if (r.get("Product2") or {}).get("StockKeepingUnit")
    }


def resolve_path_b_for_quote(
    session: OrgSession,
    quote_id: str,
    *,
    account_id: str | None = None,
    extra_skus: list[str] | None = None,
) -> bool:
    """Path B if Quote lines ∪ Account assets ∪ extras form an eligible stack.

    Amend Quotes often lack the full SKU set on one Draft; module add-on Quotes
    may only carry Payroll/Benefits. Account Assets supply the rest.
    """
    qid = (quote_id or "").replace("'", "\\'")
    skus: set[str] = set()
    acct = (account_id or "").strip() or None
    if qid:
        qrows = session.soql(
            "SELECT QuoteAccountId, AccountId FROM Quote "
            f"WHERE Id = '{qid}' LIMIT 1"
        )
        if qrows and not acct:
            acct = qrows[0].get("QuoteAccountId") or qrows[0].get("AccountId")
        lines = session.soql(
            "SELECT Product2.StockKeepingUnit FROM QuoteLineItem "
            f"WHERE QuoteId = '{qid}'"
        )
        for line in lines:
            sku = ((line.get("Product2") or {}).get("StockKeepingUnit") or "").upper()
            if sku:
                skus.add(sku)
    if acct:
        skus |= account_owned_skus(session, acct)
    for s in extra_skus or []:
        if s:
            skus.add(str(s).upper())
    return path_b_skus_eligible(skus)


def expected_amend_net_pepm(
    list_pepm: float,
    *,
    sku: str,
    volume_percent: float,
    path_b: bool,
) -> float:
    """List → Path B Bundle & Save (Payroll/Benefits) → volume tier."""
    price = float(list_pepm)
    sku_u = (sku or "").upper()
    if path_b and sku_u in US_ONLY_ADDONS:
        price *= 1.0 - PATH_B_BUNDLE_SAVE
    if volume_percent:
        price *= 1.0 - float(volume_percent) / 100.0
    return round(price, 2)


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
    payment: dict[str, Any] | None = None
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
            "payment": self.payment,
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


def checkout_address_defaults(
    *,
    billing_country: str | None = None,
    currency: str | None = None,
) -> dict[str, str]:
    """Demo Account/Order address so Order Activate can succeed."""
    cc = (billing_country or "").upper()
    cur = (currency or "").upper()
    if cc in ("GB", "UK") or cur == "GBP":
        key = "UK"
    elif cc == "CA" or cur == "CAD":
        key = "CA"
    else:
        key = "US"
    return dict(COUNTRY_SHIPPING[key])


def ensure_account_checkout_address(session: OrgSession, account_id: str) -> None:
    """Fill missing Account billing/shipping from COUNTRY_SHIPPING defaults.

    Order Activate requires a billing address *on the Account* ("Enter the
    billing address associated with the account"). Proof/harness Accounts
    often have neither billing nor shipping.
    """
    aid = (account_id or "").strip()
    if not aid:
        return
    rows = session.soql(
        "SELECT BillingStreet, BillingCity, BillingState, BillingPostalCode, "
        "BillingCountry, ShippingStreet, ShippingCity, ShippingState, "
        "ShippingPostalCode, ShippingCountry, CurrencyIsoCode "
        f"FROM Account WHERE Id = '{_soql_escape_local(aid)}' LIMIT 1"
    )
    if not rows:
        return
    acct = rows[0]
    needs_billing = not (acct.get("BillingStreet") and acct.get("BillingCity"))
    needs_shipping = not (acct.get("ShippingStreet") and acct.get("ShippingCity"))
    if not needs_billing and not needs_shipping:
        return
    defaults = checkout_address_defaults(
        billing_country=acct.get("BillingCountry"),
        currency=acct.get("CurrencyIsoCode"),
    )
    patch: dict[str, Any] = {}
    if needs_billing:
        for key in (
            "BillingStreet",
            "BillingCity",
            "BillingState",
            "BillingPostalCode",
            "BillingCountry",
        ):
            if defaults.get(key):
                patch[key] = defaults[key]
    if needs_shipping:
        for key in (
            "ShippingStreet",
            "ShippingCity",
            "ShippingState",
            "ShippingPostalCode",
            "ShippingCountry",
        ):
            if defaults.get(key):
                patch[key] = defaults[key]
    if patch:
        session.patch("Account", aid, patch)


def set_order_shipping_from_account(session: OrgSession, order_id: str, account_id: str) -> None:
    acct = session.soql(
        "SELECT ShippingStreet, ShippingCity, ShippingState, ShippingPostalCode, "
        "ShippingCountry, BillingStreet, BillingCity, BillingState, "
        f"BillingPostalCode, BillingCountry FROM Account WHERE Id = '{account_id}'"
    )[0]
    payload = {
        "ShippingStreet": acct.get("ShippingStreet"),
        "ShippingCity": acct.get("ShippingCity"),
        "ShippingState": acct.get("ShippingState"),
        "ShippingPostalCode": acct.get("ShippingPostalCode"),
        "ShippingCountry": acct.get("ShippingCountry"),
        "BillingStreet": acct.get("BillingStreet"),
        "BillingCity": acct.get("BillingCity"),
        "BillingState": acct.get("BillingState"),
        "BillingPostalCode": acct.get("BillingPostalCode"),
        "BillingCountry": acct.get("BillingCountry"),
    }
    if not payload.get("BillingCity") and not payload.get("BillingCountry"):
        raise RuntimeError(
            f"Account {account_id} has no billing address — activation will fail"
        )
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


def activate_order(
    session: OrgSession, order_id: str, *, account_id: str | None = None
) -> None:
    try:
        _patch(
            session,
            f"/services/data/{API}/sobjects/Order/{order_id}",
            {"Status": "Activated"},
        )
    except RuntimeError as exc:
        msg = str(exc)
        if account_id and "billing address" in msg.lower():
            ensure_account_checkout_address(session, account_id)
            set_order_shipping_from_account(session, order_id, account_id)
            _patch(
                session,
                f"/services/data/{API}/sobjects/Order/{order_id}",
                {"Status": "Activated"},
            )
            return
        raise


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
    path_b: bool | None = None,
    account_id: str | None = None,
    extra_skus: list[str] | None = None,
) -> None:
    """Stamp post-amend headcount and System-reprice for Volume on amends.

    Amend lines use ``ItemPricingSource = LastTransaction`` and delta
    ``Quantity``, so OOTB Volume skips them. The BambooHR overlay
    (``ApplyBambooHRAmendVolumeDiscount``) runs Volume Discount when
    ``RLM_Amend_Volume_Qty__c`` is set — BFF stamps that field to the
    absolute post-amend headcount, then System-reprices.

    Path B Bundle & Save is skipped by the pricing procedure on
    ``LastTransaction`` lines, and module Quotes may omit the plan SKU so
    Apex clears the Quote flag. This helper resolves Path B from Account
    Assets ∪ Quote lines, stamps the flag, and verifies **Bundle → volume**
    nets (Force + combined ``Discount`` fallback when System misses the stack).
    """
    from service import _system_reprice_quote  # local package

    qcur = session.soql(
        f"SELECT CurrencyIsoCode, QuoteAccountId, AccountId "
        f"FROM Quote WHERE Id = '{quote_id}'"
    )
    currency = (qcur[0].get("CurrencyIsoCode") if qcur else None) or "USD"
    acct = account_id or (
        (qcur[0].get("QuoteAccountId") or qcur[0].get("AccountId")) if qcur else None
    )

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

    if path_b is None:
        path_b = resolve_path_b_for_quote(
            session,
            quote_id,
            account_id=acct,
            extra_skus=extra_skus,
        )

    # REST stamp (Place Skip often strips custom fields on amend Quotes).
    quote_stamp: dict[str, Any] = {"RLM_Bamboo_Amend_Volume__c": True}
    if path_b:
        quote_stamp["RLM_Bamboo_PathB_BundleSave__c"] = True
    try:
        session.patch("Quote", quote_id, quote_stamp)
    except Exception as exc:  # noqa: BLE001
        if "RLM_Bamboo_PathB_BundleSave__c" in quote_stamp:
            try:
                session.patch(
                    "Quote",
                    quote_id,
                    {"RLM_Bamboo_Amend_Volume__c": True},
                )
            except Exception as exc2:  # noqa: BLE001
                raise RuntimeError(
                    f"Could not stamp Quote.RLM_Bamboo_Amend_Volume__c on {quote_id}: "
                    f"{exc2}. Deploy unpackaged/post_bamboohr and apply "
                    "apply_context_bamboohr_amend_volume."
                ) from exc2
        else:
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

    # Re-stamp Path B after QLI DML — Apex syncs from Quote lines only and may
    # clear the flag on module Quotes that omit the plan SKU.
    if path_b:
        try:
            session.patch(
                "Quote",
                quote_id,
                {"RLM_Bamboo_PathB_BundleSave__c": True},
            )
        except Exception:
            pass

    _system_reprice_quote(session, quote_id)

    # Verify Bundle→volume (or volume-only) landed; Discount fallback if not.
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
                },
                "RLM_Bamboo_Amend_Volume__c": True,
                "RLM_Bamboo_PathB_BundleSave__c": bool(path_b),
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
        expected_net = expected_amend_net_pepm(
            list_p,
            sku=sku,
            volume_percent=vol_pct,
            path_b=bool(path_b),
        )
        # Combined % off list so Force Discount reproduces Bundle → volume.
        factor = expected_net / list_p if list_p else 1.0
        discount_pct = round(max(0.0, (1.0 - factor) * 100.0), 4)
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
                    "Discount": discount_pct,
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
    ensure_account_checkout_address(session, account_id)
    try:
        order_id, order_number = create_order_from_quote(session, quote_id)
    except RuntimeError:
        existing = session.soql(
            "SELECT Id, OrderNumber, Status FROM Order "
            f"WHERE QuoteId = '{quote_id}' "
            "ORDER BY CreatedDate DESC LIMIT 5"
        )
        draft = next(
            (
                row
                for row in existing
                if (row.get("Status") or "") != "Activated"
            ),
            existing[0] if existing else None,
        )
        if not draft:
            raise
        order_id = draft["Id"]
        order_number = draft.get("OrderNumber")
        if (draft.get("Status") or "") == "Activated":
            return order_id, order_number
    set_order_shipping_from_account(session, order_id, account_id)
    contact_id = ensure_bill_to_contact(session, account_id)
    set_order_bill_to_contact(session, order_id, contact_id)
    activate_order(session, order_id, account_id=account_id)
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
    period = asset_state_period_at(session, asset_id, as_of=as_of)
    if period is not None and period.get("quantity") is not None:
        return float(period["quantity"])
    # No covering ASP that day = nothing in effect (not lifetime TotalQuantity).
    # After a future-dated upgrade, Core has no ASP on the Pro start date;
    # falling back to AssetAction.TotalQuantity would still look like 12 seats
    # and a +1-seat amend would charge Core and Pro.
    return 0.0


def asset_state_period_at(
    session: OrgSession,
    asset_id: str,
    *,
    as_of: datetime | None = None,
) -> dict[str, Any] | None:
    """AssetStatePeriod covering ``as_of`` → ``{quantity, mrr, start, end}``."""
    when = as_of or datetime.now(timezone.utc)
    day = when.strftime("%Y-%m-%d")
    periods = session.soql(
        "SELECT Quantity, Mrr, StartDate, EndDate FROM AssetStatePeriod "
        f"WHERE AssetId = '{asset_id}' ORDER BY StartDate ASC LIMIT 200"
    )
    for period in periods:
        start = str(period.get("StartDate") or "")[:10]
        end = str(period.get("EndDate") or "9999-12-31")[:10]
        if start and start <= day <= end:
            qty = period.get("Quantity")
            mrr = period.get("Mrr")
            return {
                "quantity": float(qty) if qty is not None else None,
                "mrr": float(mrr) if mrr is not None else None,
                "start": start,
                "end": end,
            }
    return None


def asset_live_metrics(
    session: OrgSession,
    asset_id: str,
    *,
    as_of: datetime | None = None,
) -> dict[str, Any]:
    """Seat count + MRR for Licenses UI — prefer Asset current fields, else ASP.

    Do **not** use AssetAction.TotalQuantity here: that is the latest lifetime
    total and drifts ahead of "today" when future quantity periods exist.
    """
    rows = session.soql(
        "SELECT Id, CurrentQuantity, CurrentMrr FROM Asset "
        f"WHERE Id = '{asset_id}' LIMIT 1"
    )
    qty: float | None = None
    mrr: float | None = None
    source = "none"
    if rows:
        if rows[0].get("CurrentQuantity") is not None:
            qty = float(rows[0]["CurrentQuantity"])
            source = "assetCurrentQuantity"
        if rows[0].get("CurrentMrr") is not None:
            mrr = float(rows[0]["CurrentMrr"])
            if source == "none":
                source = "assetCurrentMrr"
            elif source == "assetCurrentQuantity":
                source = "assetCurrent"

    period = asset_state_period_at(session, asset_id, as_of=as_of)
    if period:
        if qty is None and period.get("quantity") is not None:
            qty = float(period["quantity"])
            source = "assetStatePeriod"
        if mrr is None and period.get("mrr") is not None:
            mrr = float(period["mrr"])
            source = (
                "assetStatePeriod"
                if source in ("none", "assetCurrentQuantity")
                else source
            )

    if qty is None:
        try:
            qty = _current_asset_quantity(session, asset_id)
            if source == "none":
                source = "assetActionTotalQuantity"
        except RuntimeError:
            qty = None

    return {
        "quantity": qty,
        "mrr": mrr,
        "source": source,
    }


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
    """Delete or cancel leftover preview Draft Quotes (amend / upgrade / module)."""
    return discard_stale_preview_drafts(
        session, account_id, keep_quote_ids=keep_quote_ids
    )


def _is_preview_leftover_draft(name: str, description: str) -> bool:
    tagged = PREVIEW_MARKER in (description or "")
    lowered = (name or "").lower()
    named = (
        "amendment" in lowered
        or lowered.startswith("upgrade")
        or lowered.startswith("add modules")
    )
    return tagged or named


def discard_stale_preview_drafts(
    session: OrgSession,
    account_id: str,
    *,
    keep_quote_ids: list[str] | None = None,
) -> list[str]:
    """Delete or cancel Draft preview Quotes for an Account (post-Place hygiene).

    Covers Amendment, Upgrade, and Add-modules leftovers tagged
    ``[bamboohr-preview]`` or named as preview Quotes. Keeps ``keep_quote_ids``.
    Self-serve acquisition Drafts (un-tagged) are left alone.
    """
    keep = {k for k in (keep_quote_ids or []) if k}
    rows = session.soql(
        "SELECT Id, Name, QuoteNumber, Description FROM Quote "
        f"WHERE Status = 'Draft' "
        f"AND (QuoteAccountId = '{account_id}' OR AccountId = '{account_id}') "
        "ORDER BY CreatedDate DESC LIMIT 100"
    )
    deleted: list[str] = []
    tag = "[bamboohr-preview] stale preview draft — auto-cleanup"
    for row in rows:
        qid = row["Id"]
        if qid in keep:
            continue
        name = row.get("Name") or ""
        desc = (row.get("Description") or "").strip()
        if not _is_preview_leftover_draft(name, desc):
            continue
        if PREVIEW_MARKER not in desc:
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


PREVIEW_MARKER = "[bamboohr-preview]"


def amend_preview_cfg(
    *,
    new_qty: int,
    start_iso: str,
    asset_ids: list[str],
    quantity_change: float,
) -> str:
    """Stable fingerprint for sticky amend Draft Quotes."""
    assets = "+".join(sorted(a for a in asset_ids if a))
    delta = f"{float(quantity_change):g}"
    return f"qty={int(new_qty)};start={start_iso[:10]};assets={assets};delta={delta}"


def module_preview_cfg(*, quantity: int, addon_skus: list[str]) -> str:
    skus = "+".join(sorted(s.upper() for s in addon_skus if s))
    return f"qty={int(quantity)};skus={skus}"


def upgrade_preview_cfg(
    *,
    to_sku: str,
    quantity: int,
    start_iso: str,
    asset_ids: list[str],
) -> str:
    """Stable fingerprint for sticky Initiate Upgrade Draft Quotes."""
    assets = "+".join(sorted(a for a in asset_ids if a))
    return (
        f"to={str(to_sku or '').upper()};qty={int(quantity)};"
        f"start={start_iso[:10]};assets={assets}"
    )


def _iso_day(value: datetime | date | str | None) -> date | None:
    if value is None:
        return None
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    text = str(value).strip()
    if not text:
        return None
    try:
        return date.fromisoformat(text[:10])
    except ValueError:
        return None


def build_initiate_upgrade_body(
    *,
    swap_start: datetime | str,
    asset_id: str,
    out_quantity: int,
    product2_id: str,
    pricebook_entry_id: str,
    in_quantity: int,
    line_start: date | str,
    line_end: date | str | None = None,
    product_selling_model_id: str | None = None,
    reference_id: str = "UPGRADE-001",
    opportunity_id: str | None = None,
    extra_out_assets: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """Connect Initiate Upgrade body. Do not stamp UnitPrice — System reprice owns net.

    Term-defined UpgradeTo lines must carry EndDate + PeriodBoundary +
    BillingFrequency. Without them the platform prices an incomplete line and
    fails with ``Waterfall tag is not in the line item hierarchy``.
    """
    if isinstance(swap_start, datetime):
        start_iso = swap_start.strftime("%Y-%m-%dT00:00:00.000Z")
    else:
        start_iso = str(swap_start)
    start_d = _iso_day(line_start)
    if start_d is None:
        raise ValueError("line_start is required")
    line_start_s = start_d.isoformat()
    # Missing end must not invent a 12-month commitment. Get Pricing default
    # is month-to-month (1-month Term Monthly window); annual upgrades pass
    # the remaining Core LifecycleEndDate explicitly.
    end_d = _iso_day(line_end) or add_calendar_months(start_d, 1)
    if end_d <= start_d:
        end_d = add_calendar_months(start_d, 1)
    swap_assets: list[dict[str, Any]] = [
        {"assetId": asset_id, "quantity": int(out_quantity)}
    ]
    for extra in extra_out_assets or []:
        aid = str(extra.get("assetId") or extra.get("id") or "").strip()
        if not aid or aid == asset_id:
            continue
        qty = extra.get("quantity", out_quantity)
        swap_assets.append({"assetId": aid, "quantity": int(qty)})
    record: dict[str, Any] = {
        "attributes": {
            "type": "QuoteLineItem",
            "method": "POST",
        },
        "Product2Id": product2_id,
        "PricebookEntryId": pricebook_entry_id,
        "Quantity": str(int(in_quantity)),
        "StartDate": line_start_s,
        "EndDate": end_d.isoformat(),
        "PeriodBoundary": "Anniversary",
        "BillingFrequency": "Monthly",
    }
    if product_selling_model_id:
        record["ProductSellingModelId"] = product_selling_model_id
    body: dict[str, Any] = {
        "swapStartDate": start_iso,
        "outputRecordType": "Quote",
        "swapGroups": {
            "groups": [
                {
                    "referenceId": reference_id,
                    "outGroup": {"swapAssets": swap_assets},
                    "inGroup": {
                        "graphId": "upgradeRequest",
                        "records": [
                            {
                                "referenceId": "refQuoteLine0",
                                "record": record,
                            }
                        ],
                    },
                }
            ]
        },
    }
    if opportunity_id:
        body["opportunityId"] = opportunity_id
    return body


def _soql_escape_local(value: str) -> str:
    return (value or "").replace("\\", "\\\\").replace("'", "\\'")


def parse_preview_cfg(description: str | None, kind: str) -> str | None:
    """Return cfg string after ``[bamboohr-preview] {kind} `` or None."""
    desc = description or ""
    needle = f"{PREVIEW_MARKER} {kind} "
    idx = desc.find(needle)
    if idx < 0:
        return None
    rest = desc[idx + len(needle) :].strip()
    # cfg is one token / one line
    return rest.split()[0].split("\n")[0].strip() if rest else None


def tag_amend_preview_quote(
    session: OrgSession,
    quote_id: str,
    *,
    cfg: str | None = None,
    kind: str = "amend",
) -> None:
    """Mark a Draft Quote for sticky preview reuse + hygiene cleanup."""
    if not quote_id:
        return
    try:
        rows = session.soql(
            f"SELECT Description FROM Quote WHERE Id = '{quote_id}' LIMIT 1"
        )
        desc = ((rows[0].get("Description") if rows else None) or "").strip()
        # Drop prior preview marker lines, then stamp current cfg.
        lines = [
            ln
            for ln in desc.splitlines()
            if PREVIEW_MARKER not in ln and ln.strip()
        ]
        stamp = (
            f"{PREVIEW_MARKER} {kind} {cfg}"
            if cfg
            else f"{PREVIEW_MARKER} {kind}"
        )
        lines.append(stamp)
        session.patch("Quote", quote_id, {"Description": "\n".join(lines)})
    except Exception:
        pass


def parse_amend_cfg_parts(cfg: str | None) -> dict[str, str]:
    """Parse ``qty=…;start=…;assets=…;delta=…`` into a dict."""
    out: dict[str, str] = {}
    for part in (cfg or "").split(";"):
        if "=" not in part:
            continue
        key, val = part.split("=", 1)
        out[key.strip()] = val.strip()
    return out


def find_sticky_amend_draft(
    session: OrgSession,
    account_id: str,
    *,
    cfg: str,
    preferred_quote_id: str | None = None,
) -> dict[str, Any] | None:
    """Return Draft Amendment Quote matching sticky cfg, if still reusable."""
    if not account_id or not cfg:
        return None
    preferred = (preferred_quote_id or "").strip()
    if preferred:
        rows = session.soql(
            "SELECT Id, Name, Status, Description, OpportunityId, QuoteNumber "
            f"FROM Quote WHERE Id = '{_soql_escape_local(preferred)}' LIMIT 1"
        )
        if rows:
            row = rows[0]
            if (row.get("Status") or "") == "Draft":
                parsed = parse_preview_cfg(row.get("Description"), "amend")
                if parsed == cfg:
                    return row
    rows = session.soql(
        "SELECT Id, Name, Status, Description, OpportunityId, QuoteNumber, "
        "CreatedDate FROM Quote WHERE Status = 'Draft' "
        f"AND (QuoteAccountId = '{_soql_escape_local(account_id)}' "
        f"OR AccountId = '{_soql_escape_local(account_id)}') "
        "AND (Name LIKE 'Amendment%' OR Name LIKE '%Amendment%') "
        "ORDER BY CreatedDate DESC LIMIT 40"
    )
    for row in rows:
        parsed = parse_preview_cfg(row.get("Description"), "amend")
        if parsed == cfg:
            return row
    return None


def find_sticky_amend_mutable(
    session: OrgSession,
    account_id: str,
    *,
    start_iso: str,
    asset_ids: list[str],
    quantity_change: float,
    preferred_quote_id: str | None = None,
) -> dict[str, Any] | None:
    """Find a Draft amend Quote for the same assets+start (qty may differ).

    Same sign of ``quantity_change`` required so we can retarget delta Quantity
    via System place (initial-sale style) instead of Connect amend again.
    """
    if not account_id or not asset_ids:
        return None
    assets_key = "+".join(sorted(a for a in asset_ids if a))
    start_key = (start_iso or "")[:10]
    want_sign = 0 if abs(float(quantity_change)) < 1e-9 else (
        1 if float(quantity_change) > 0 else -1
    )

    def _matches(row: dict[str, Any]) -> bool:
        if (row.get("Status") or "") != "Draft":
            return False
        parts = parse_amend_cfg_parts(
            parse_preview_cfg(row.get("Description"), "amend")
        )
        if parts.get("assets") != assets_key:
            return False
        if parts.get("start") != start_key:
            return False
        try:
            old_delta = float(parts.get("delta") or 0)
        except ValueError:
            return False
        old_sign = 0 if abs(old_delta) < 1e-9 else (1 if old_delta > 0 else -1)
        return old_sign == want_sign

    preferred = (preferred_quote_id or "").strip()
    if preferred:
        rows = session.soql(
            "SELECT Id, Name, Status, Description, OpportunityId, QuoteNumber "
            f"FROM Quote WHERE Id = '{_soql_escape_local(preferred)}' LIMIT 1"
        )
        if rows and (rows[0].get("Status") or "") == "Draft":
            # Buyer's open self-serve Draft — always prefer retargeting this
            # Quote (same record) over creating another amend Draft.
            return rows[0]

    rows = session.soql(
        "SELECT Id, Name, Status, Description, OpportunityId, QuoteNumber, "
        "CreatedDate FROM Quote WHERE Status = 'Draft' "
        f"AND (QuoteAccountId = '{_soql_escape_local(account_id)}' "
        f"OR AccountId = '{_soql_escape_local(account_id)}') "
        "AND (Name LIKE 'Amendment%' OR Name LIKE '%Amendment%') "
        "ORDER BY CreatedDate DESC LIMIT 40"
    )
    for row in rows:
        if _matches(row):
            return row
    return None


def find_sticky_tagged_draft(
    session: OrgSession,
    account_id: str,
    *,
    kind: str,
    cfg: str,
    preferred_quote_id: str | None = None,
) -> dict[str, Any] | None:
    """Return Draft preview Quote matching ``[bamboohr-preview] {kind} {cfg}``."""
    if not account_id or not cfg or not kind:
        return None
    preferred = (preferred_quote_id or "").strip()
    if preferred:
        rows = session.soql(
            "SELECT Id, Name, Status, Description, OpportunityId, QuoteNumber "
            f"FROM Quote WHERE Id = '{_soql_escape_local(preferred)}' LIMIT 1"
        )
        if rows:
            row = rows[0]
            if (row.get("Status") or "") == "Draft":
                parsed = parse_preview_cfg(row.get("Description"), kind)
                if parsed == cfg:
                    return row
    rows = session.soql(
        "SELECT Id, Name, Status, Description, OpportunityId, QuoteNumber, "
        "CreatedDate FROM Quote WHERE Status = 'Draft' "
        f"AND (QuoteAccountId = '{_soql_escape_local(account_id)}' "
        f"OR AccountId = '{_soql_escape_local(account_id)}') "
        "ORDER BY CreatedDate DESC LIMIT 40"
    )
    for row in rows:
        parsed = parse_preview_cfg(row.get("Description"), kind)
        if parsed == cfg:
            return row
    return None


def find_sticky_module_draft(
    session: OrgSession,
    account_id: str,
    *,
    cfg: str,
    preferred_quote_id: str | None = None,
) -> dict[str, Any] | None:
    """Return Draft add-module preview Quote matching sticky cfg."""
    return find_sticky_tagged_draft(
        session,
        account_id,
        kind="module",
        cfg=cfg,
        preferred_quote_id=preferred_quote_id,
    )


def find_sticky_upgrade_draft(
    session: OrgSession,
    account_id: str,
    *,
    cfg: str,
    preferred_quote_id: str | None = None,
) -> dict[str, Any] | None:
    """Return Draft Initiate Upgrade preview Quote matching sticky cfg."""
    return find_sticky_tagged_draft(
        session,
        account_id,
        kind="upgrade",
        cfg=cfg,
        preferred_quote_id=preferred_quote_id,
    )


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
    opportunity_id: str | None = None,
) -> str | None:
    """Qty true-up via Connect amend for one or more assets; returns quote id.

    R262 body uses ``assetIds`` + ``quantityChange`` (delta), not absolute qty.
    Delta is computed from **ASP quantity on amendmentStartDate** unless
    ``quantity_change`` is passed explicitly.

    Pass ``opportunity_id`` to sync the amendment Quote to an Opportunity
    (same as Managed Asset viewer / ``opportunityId`` on the Connect API).
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

    body: dict[str, Any] = {
        "assetIds": ids,
        "amendmentStartDate": when.strftime("%Y-%m-%dT00:00:00.000Z"),
        "outputRecordType": "Quote",
        "quantityChange": float(quantity_change),
    }
    if opportunity_id:
        body["opportunityId"] = opportunity_id
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


def cancel_assets_to_quote(
    session: OrgSession,
    asset_ids: list[str],
    *,
    start: datetime | None = None,
    opportunity_id: str | None = None,
    preferred_quote_id: str | None = None,
) -> str | None:
    """Cancel assets via Connect API; returns a Draft cancellation Quote Id."""
    ids = [a for a in asset_ids if a]
    if not ids:
        raise RuntimeError("assetIds is required for cancel")
    when = resolve_amend_start(session, ids, start)
    start_iso = when.date().isoformat()
    cfg = f"start={start_iso};assets={'+'.join(sorted(ids))}"
    preferred = (preferred_quote_id or "").strip()
    if preferred:
        rows = session.soql(
            "SELECT Id, Status, Description FROM Quote "
            f"WHERE Id = '{_soql_escape_local(preferred)}' LIMIT 1"
        )
        if rows and (rows[0].get("Status") or "") == "Draft":
            parsed = parse_preview_cfg(rows[0].get("Description"), "cancel")
            if parsed == cfg:
                return preferred
    body: dict[str, Any] = {
        "assetIds": ids,
        "cancellationDate": when.strftime("%Y-%m-%dT00:00:00.000Z"),
        "outputRecordType": "Quote",
    }
    if opportunity_id:
        body["opportunityId"] = opportunity_id
    path = f"/services/data/{API}/connect/revenue-management/assets/actions/cancel"
    try:
        result = session.post(path, body)
    except RuntimeError as exc:
        raise RuntimeError(f"Asset cancel failed: {exc}") from exc
    if isinstance(result, list) and result:
        result = result[0]
    if not isinstance(result, dict):
        return None
    if result.get("success") is False:
        raise RuntimeError(f"Asset cancel failed: {result.get('errors') or result}")
    quote_id = (
        result.get("cancellationRecordId")
        or result.get("amendmentRecordId")
        or result.get("id")
    )
    if quote_id:
        tag_amend_preview_quote(session, quote_id, cfg=cfg, kind="cancel")
    return quote_id


def upgrade_assets_to_quote(
    session: OrgSession,
    *,
    account_id: str,
    asset_ids: list[str],
    to_sku: str,
    out_quantity: int,
    in_quantity: int,
    start: datetime | None = None,
    currency: str = "USD",
    preferred_quote_id: str | None = None,
    opportunity_id: str | None = None,
) -> str:
    """Core→Pro via OOTB Initiate Upgrade; returns a Draft amendment Quote Id.

    Does not stamp UnitPrice. UpgradeTo EndDate is the remaining Core
    lifecycle window (month-to-month stays ~1 month; 12/24/36 stay
    coterminous). After the API returns a Quote, System reprice plus amend
    volume overlay own net. Sticky Drafts are tagged
    ``[bamboohr-preview] upgrade``.
    """
    ids = [a for a in asset_ids if a]
    if not ids:
        raise RuntimeError("assetIds is required for upgrade")
    wanted = (to_sku or "").strip().upper()
    if not wanted:
        raise RuntimeError("to_sku is required for upgrade")
    if int(out_quantity) < 1 or int(in_quantity) < 1:
        raise RuntimeError("upgrade quantities must be >= 1")
    when = resolve_amend_start(session, ids, start)
    start_iso = when.date().isoformat()
    cfg = upgrade_preview_cfg(
        to_sku=wanted,
        quantity=int(in_quantity),
        start_iso=start_iso,
        asset_ids=ids,
    )
    sticky = find_sticky_upgrade_draft(
        session,
        account_id,
        cfg=cfg,
        preferred_quote_id=preferred_quote_id,
    )
    if sticky:
        qid = str(sticky["Id"])
        try:
            reprice_quote_system(session, qid)
            apply_amend_volume_pricing(
                session,
                qid,
                volume_headcount=int(in_quantity),
                account_id=account_id,
                extra_skus=[wanted],
            )
            tag_amend_preview_quote(session, qid, cfg=cfg, kind="upgrade")
            return qid
        except Exception:
            try:
                session.delete("Quote", qid)
            except Exception:
                pass

    try:
        other = session.soql(
            "SELECT Id, Description FROM Quote WHERE Status = 'Draft' "
            f"AND (QuoteAccountId = '{_soql_escape_local(account_id)}' "
            f"OR AccountId = '{_soql_escape_local(account_id)}') "
            "ORDER BY CreatedDate DESC LIMIT 40"
        )
        for row in other:
            parsed = parse_preview_cfg(row.get("Description"), "upgrade")
            if parsed is None:
                continue
            try:
                session.delete("Quote", row["Id"])
            except Exception:
                try:
                    session.patch("Quote", row["Id"], {"Status": "Denied"})
                except Exception:
                    pass
    except Exception:
        pass

    pbe = _pbe_for_sku(session, wanted, currency)
    extra = [{"assetId": aid, "quantity": int(out_quantity)} for aid in ids[1:]]
    end_rows = session.soql(
        "SELECT LifecycleEndDate FROM Asset "
        f"WHERE Id = '{_soql_escape_local(ids[0])}' LIMIT 1"
    )
    line_end = _iso_day((end_rows[0] or {}).get("LifecycleEndDate")) if end_rows else None
    asp_end = None
    try:
        asp = session.soql(
            "SELECT EndDate FROM AssetStatePeriod "
            f"WHERE AssetId = '{_soql_escape_local(ids[0])}' "
            "AND EndDate != null ORDER BY EndDate DESC LIMIT 1"
        )
        if asp:
            asp_end = _iso_day(asp[0].get("EndDate"))
    except Exception:  # noqa: BLE001
        asp_end = None
    line_end = remaining_service_end(when.date(), line_end, asp_end)
    body = build_initiate_upgrade_body(
        swap_start=when,
        asset_id=ids[0],
        out_quantity=int(out_quantity),
        product2_id=str(pbe["Product2Id"]),
        pricebook_entry_id=str(pbe["Id"]),
        in_quantity=int(in_quantity),
        line_start=when.date(),
        line_end=line_end,
        product_selling_model_id=str(pbe.get("ProductSellingModelId") or "") or None,
        opportunity_id=opportunity_id,
        extra_out_assets=extra,
    )
    path = (
        f"/services/data/{API}/revenue/transaction-management/assets/actions/upgrade"
    )
    try:
        result = session.post(path, body)
    except RuntimeError as exc:
        raise RuntimeError(f"Asset upgrade failed: {exc}") from exc
    if isinstance(result, list) and result:
        result = result[0]
    if not isinstance(result, dict):
        raise RuntimeError(f"Asset upgrade failed: unexpected response {result!r}")
    if result.get("success") is False:
        raise RuntimeError(f"Asset upgrade failed: {result.get('errors') or result}")
    quote_id = (
        result.get("salesTransactionId")
        or result.get("amendmentRecordId")
        or result.get("id")
    )
    if not quote_id:
        raise RuntimeError(f"Asset upgrade returned no Quote Id: {result}")
    try:
        reprice_quote_system(session, quote_id)
        apply_amend_volume_pricing(
            session,
            quote_id,
            volume_headcount=int(in_quantity),
            account_id=account_id,
            extra_skus=[wanted],
        )
    except Exception as exc:  # noqa: BLE001
        raise RuntimeError(
            f"Upgrade Quote {quote_id} created but System reprice failed: {exc}"
        ) from exc
    tag_amend_preview_quote(session, quote_id, cfg=cfg, kind="upgrade")
    return quote_id


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
    collect_payment: bool = True,
) -> CheckoutResult:
    """Place order from quote, activate (assetize), optional qty amend + Pay Now."""
    warnings: list[str] = []
    order_id: str | None = None
    order_number: str | None = None
    assets: list[str] = []
    asset_qty: float | None = None
    amend_quote: str | None = None
    amend_order: str | None = None
    amend_order_number: str | None = None
    payment: dict[str, Any] | None = None

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

        pay_order = amend_order or order_id
        if collect_payment and pay_order:
            from payments import build_payment_prompt

            try:
                prompt = build_payment_prompt(
                    session,
                    pay_order,
                    collect=True,
                    poll_timeout=min(90, poll_timeout),
                )
                payment = prompt.as_dict()
                if prompt.blocked_reason:
                    warnings.append(f"Payment: {prompt.blocked_reason}")
                warnings.extend(prompt.warnings)
            except Exception as pay_exc:  # noqa: BLE001
                warnings.append(f"Payment prompt failed: {pay_exc}")
                payment = {
                    "ready": False,
                    "orderId": pay_order,
                    "blockedReason": str(pay_exc),
                }

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
            payment=payment,
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
            payment=payment,
            error=str(exc),
            warnings=warnings,
        )


def pick_activated_order_for_quotes(
    orders: list[dict[str, Any]],
    quote_ids: list[str],
) -> dict[str, Any] | None:
    """Newest Activated order whose QuoteId is in the Place payload."""
    wanted = {str(qid).strip() for qid in quote_ids if str(qid).strip()}
    if not wanted:
        return None
    matches: list[dict[str, Any]] = []
    for row in orders:
        status = row.get("Status") or row.get("status") or ""
        qid = str(row.get("QuoteId") or row.get("quoteId") or "").strip()
        if status == "Activated" and qid in wanted:
            matches.append(row)
    if not matches:
        return None
    matches.sort(
        key=lambda r: str(r.get("CreatedDate") or r.get("createdDate") or ""),
        reverse=True,
    )
    return matches[0]


def find_activated_order_for_quotes(
    session: OrgSession,
    quote_ids: list[str],
) -> dict[str, Any] | None:
    ids = [str(qid).strip() for qid in quote_ids if str(qid).strip()]
    if not ids:
        return None
    in_list = ",".join(f"'{_soql_escape_local(i)}'" for i in ids)
    rows = session.soql(
        "SELECT Id, OrderNumber, Status, QuoteId, AccountId, CreatedDate "
        "FROM Order "
        f"WHERE QuoteId IN ({in_list}) AND Status = 'Activated' "
        "ORDER BY CreatedDate DESC LIMIT 10"
    )
    return pick_activated_order_for_quotes(rows, ids)


def place_status_for_quotes(
    session: OrgSession,
    quote_ids: list[str],
) -> dict[str, Any]:
    """Buyer recover payload when Place HTTP timed out but RC activated."""
    row = find_activated_order_for_quotes(session, quote_ids)
    if not row:
        return {"ok": False, "found": False}
    base = (getattr(session, "_instance", None) or "").rstrip("/")

    def _lex(entity: str, rid: str | None) -> str:
        return f"{base}/lightning/r/{entity}/{rid}/view" if rid and base else ""

    oid = str(row.get("Id") or "")
    qid = str(row.get("QuoteId") or "") or None
    aid = str(row.get("AccountId") or "") or None
    opp = str(row.get("OpportunityId") or "") or None
    if not opp and qid:
        try:
            qrows = session.soql(
                "SELECT OpportunityId FROM Quote "
                f"WHERE Id = '{_soql_escape_local(qid)}' LIMIT 1"
            )
            opp = (qrows[0].get("OpportunityId") if qrows else None) or None
        except Exception:  # noqa: BLE001
            opp = None
    number = row.get("OrderNumber") or oid
    return {
        "ok": True,
        "found": True,
        "recovered": True,
        "orderId": oid,
        "orderNumber": number,
        "quoteId": qid,
        "accountId": aid,
        "opportunityId": opp,
        "confirmation": {
            "title": "Changes complete",
            "lede": (
                "Your change is activated in Salesforce Revenue Cloud — "
                "the order was already placed."
            ),
            "metrics": [{"label": "Order", "value": number}],
            "links": {
                "account": _lex("Account", aid),
                "opportunity": _lex("Opportunity", opp),
                "quote": _lex("Quote", qid),
                "order": _lex("Order", oid),
            },
        },
        "payment": {
            "ready": False,
            "orderId": oid,
            "collectPending": True,
        },
    }


def checkout_quote_or_recover(
    session: OrgSession,
    quote_id: str,
    **kwargs: Any,
) -> CheckoutResult:
    """Place/activate, treating an already-Activated order as success.

    Place must not look failed when createOrderFromQuote + Activate finished
    but a later poll (assets / invoice) raised. Invoice collect stays off
    the Place path — licenses POSTs collect-payment after success.
    """
    kwargs.setdefault("collect_payment", False)
    result = checkout_quote(session, quote_id, **kwargs)
    if result.ok:
        return result
    recovered: dict[str, Any] | None = None
    if result.order_id:
        try:
            rows = session.soql(
                "SELECT Id, OrderNumber, Status, QuoteId, AccountId, CreatedDate "
                "FROM Order "
                f"WHERE Id = '{_soql_escape_local(result.order_id)}' LIMIT 1"
            )
        except Exception:  # noqa: BLE001
            rows = []
        if rows and (rows[0].get("Status") or "") == "Activated":
            recovered = rows[0]
    if recovered is None:
        try:
            recovered = find_activated_order_for_quotes(session, [quote_id])
        except Exception:  # noqa: BLE001
            recovered = None
    if recovered is None:
        return result
    result.ok = True
    result.error = None
    result.order_id = recovered.get("Id") or result.order_id
    result.order_number = recovered.get("OrderNumber") or result.order_number
    result.warnings = list(result.warnings or [])
    result.warnings.append(
        "Order already Activated — treating Place as success."
    )
    return result

