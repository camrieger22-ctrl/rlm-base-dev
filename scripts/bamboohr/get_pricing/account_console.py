"""Licenses & billing / Amendment Console — Account assets, orders, amends.

Demo unlock 5a: resolve Account by Id or company name (no EC login yet).
- Qty true-up: OOTB Asset amend → order → activate
- Add modules: OOTB Place Quote (addon lines only) → createOrderFromQuote → Activate
  (Asset amend API is quantity-only; new SKUs are a supplemental sale on the Account)
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import date, timedelta
from typing import Any

from checkout import (
    amend_asset_quantity,
    checkout_quote,
    complete_amend_quote,
    _current_asset_quantity,
)
from service import (
    ADDON_LABELS,
    ADDON_LIST_USD,
    CATALOG_PLAN_SKUS,
    CORE_FLAT_SKU,
    NON_US_COUNTRIES,
    US_ONLY_ADDONS,
    OrgSession,
    _pbe_for_sku,
    _system_reprice_quote,
    hydrate_catalog,
    volume_rate,
)


def _soql_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace("'", "\\'")


def resolve_account_id(
    session: OrgSession,
    *,
    account_id: str | None = None,
    company: str | None = None,
) -> dict[str, Any]:
    """Return Account row for Id or exact Name match."""
    if account_id:
        safe = _soql_escape(account_id.strip())
        rows = session.soql(
            "SELECT Id, Name, BillingCountry, CurrencyIsoCode "
            f"FROM Account WHERE Id = '{safe}' LIMIT 1"
        )
        if not rows:
            raise ValueError(f"Account not found: {account_id}")
        return rows[0]
    if company:
        safe = _soql_escape(company.strip())
        rows = session.soql(
            "SELECT Id, Name, BillingCountry, CurrencyIsoCode "
            f"FROM Account WHERE Name = '{safe}' "
            "ORDER BY CreatedDate DESC LIMIT 1"
        )
        if not rows:
            raise ValueError(f"No Account named {company!r}")
        return rows[0]
    raise ValueError("accountId or company is required")


def _asset_quantity(session: OrgSession, asset_id: str) -> float | None:
    try:
        return _current_asset_quantity(session, asset_id)
    except RuntimeError:
        rows = session.soql(
            f"SELECT Quantity FROM Asset WHERE Id = '{asset_id}' LIMIT 1"
        )
        if rows and rows[0].get("Quantity") is not None:
            return float(rows[0]["Quantity"])
        return None


def load_account_console(
    session: OrgSession,
    *,
    account_id: str | None = None,
    company: str | None = None,
) -> dict[str, Any]:
    """Subscription (assets), recent orders/quotes, catalog for add-module UI."""
    acct = resolve_account_id(session, account_id=account_id, company=company)
    aid = acct["Id"]
    currency = acct.get("CurrencyIsoCode") or "USD"
    billing = (acct.get("BillingCountry") or "US").upper()
    country = "UK" if billing in ("GB", "UK") else ("CA" if billing == "CA" else "US")

    assets_raw = session.soql(
        "SELECT Id, Name, Quantity, Status, LifecycleStartDate, CreatedDate, "
        "Product2.Id, Product2.Name, Product2.StockKeepingUnit "
        f"FROM Asset WHERE AccountId = '{aid}' "
        "ORDER BY CreatedDate DESC LIMIT 50"
    )
    assets: list[dict[str, Any]] = []
    for row in assets_raw:
        product = row.get("Product2") or {}
        sku = product.get("StockKeepingUnit") or ""
        qty = _asset_quantity(session, row["Id"])
        assets.append(
            {
                "id": row["Id"],
                "name": row.get("Name") or product.get("Name") or sku,
                "sku": sku,
                "quantity": qty,
                "status": row.get("Status"),
                "productName": product.get("Name"),
                "lifecycleStartDate": row.get("LifecycleStartDate"),
                "createdDate": row.get("CreatedDate"),
            }
        )

    orders_raw = session.soql(
        "SELECT Id, OrderNumber, Status, EffectiveDate, TotalAmount, "
        "CreatedDate, Type "
        f"FROM Order WHERE AccountId = '{aid}' "
        "ORDER BY CreatedDate DESC LIMIT 15"
    )
    orders = [
        {
            "id": r["Id"],
            "orderNumber": r.get("OrderNumber"),
            "status": r.get("Status"),
            "type": r.get("Type"),
            "totalAmount": r.get("TotalAmount"),
            "effectiveDate": r.get("EffectiveDate"),
            "createdDate": r.get("CreatedDate"),
        }
        for r in orders_raw
    ]

    quotes_raw = session.soql(
        "SELECT Id, QuoteNumber, Status, TotalPrice, CreatedDate, Name "
        f"FROM Quote WHERE QuoteAccountId = '{aid}' "
        "ORDER BY CreatedDate DESC LIMIT 10"
    )
    quotes = [
        {
            "id": r["Id"],
            "quoteNumber": r.get("QuoteNumber"),
            "name": r.get("Name"),
            "status": r.get("Status"),
            "grandTotal": r.get("TotalPrice"),
            "createdDate": r.get("CreatedDate"),
        }
        for r in quotes_raw
    ]

    catalog = hydrate_catalog(session, country)
    base = (session._instance or "").rstrip("/")

    plan_skus = set(CATALOG_PLAN_SKUS) | {CORE_FLAT_SKU}
    primary = next(
        (
            a
            for a in assets
            if a.get("sku") in plan_skus and a.get("quantity") is not None
        ),
        None,
    )
    if primary is None:
        primary = next(
            (a for a in assets if a.get("quantity") is not None),
            assets[0] if assets else None,
        )
    current_qty = (
        int(primary["quantity"]) if primary and primary.get("quantity") is not None else 0
    )

    return {
        "ok": True,
        "account": {
            "id": aid,
            "name": acct.get("Name"),
            "billingCountry": billing,
            "currency": currency,
            "country": country,
        },
        "subscription": {
            "assets": assets,
            "primaryAssetId": primary["id"] if primary else None,
            "currentQuantity": current_qty,
            "recurringEstimate": None,  # filled client-side from catalog + qty
        },
        "recentOrders": orders,
        "recentQuotes": quotes,
        "catalog": catalog,
        "volumeBands": [
            {"lo": 25, "hi": 75, "rate": 0.05},
            {"lo": 76, "hi": 150, "rate": 0.10},
            {"lo": 151, "hi": 300, "rate": 0.15},
            {"lo": 301, "hi": 500, "rate": 0.20},
            {"lo": 501, "hi": None, "rate": 0.25},
        ],
        "links": {
            "account": f"{base}/lightning/r/Account/{aid}/view" if base else "",
            "home": f"{base}/lightning/page/home" if base else "",
        },
        "demoMode": True,
        "identityNote": (
            "Demo pin — Continuity via Account Id / company name. "
            "Experience Cloud login replaces this later."
        ),
    }


@dataclass
class AmendQtyResult:
    ok: bool
    account_id: str
    asset_id: str
    requested_qty: int
    amend_quote_id: str | None = None
    amend_order_id: str | None = None
    amend_order_number: str | None = None
    asset_quantity: float | None = None
    warnings: list[str] = field(default_factory=list)
    error: str | None = None

    def as_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "accountId": self.account_id,
            "assetId": self.asset_id,
            "requestedQty": self.requested_qty,
            "amendQuoteId": self.amend_quote_id,
            "amendOrderId": self.amend_order_id,
            "amendOrderNumber": self.amend_order_number,
            "assetQuantity": self.asset_quantity,
            "warnings": self.warnings,
            "error": self.error,
        }


def place_qty_amend(
    session: OrgSession,
    *,
    account_id: str,
    asset_id: str,
    new_qty: int,
) -> AmendQtyResult:
    """Commit headcount true-up via OOTB amend → order → activate."""
    if new_qty < 1:
        return AmendQtyResult(
            ok=False,
            account_id=account_id,
            asset_id=asset_id,
            requested_qty=new_qty,
            error="newQty must be >= 1",
        )
    # Ensure asset belongs to account.
    rows = session.soql(
        f"SELECT Id, AccountId FROM Asset WHERE Id = '{_soql_escape(asset_id)}' LIMIT 1"
    )
    if not rows:
        return AmendQtyResult(
            ok=False,
            account_id=account_id,
            asset_id=asset_id,
            requested_qty=new_qty,
            error="Asset not found",
        )
    if rows[0].get("AccountId") != account_id:
        return AmendQtyResult(
            ok=False,
            account_id=account_id,
            asset_id=asset_id,
            requested_qty=new_qty,
            error="Asset does not belong to this Account",
        )

    warnings: list[str] = []
    try:
        amend_quote = amend_asset_quantity(session, asset_id, new_qty)
        if not amend_quote:
            return AmendQtyResult(
                ok=False,
                account_id=account_id,
                asset_id=asset_id,
                requested_qty=new_qty,
                error="Amend API returned no amendment quote id",
            )
        order_id, order_number, asset_qty = complete_amend_quote(
            session,
            amend_quote,
            account_id,
            asset_id,
            target_qty=new_qty,
        )
        return AmendQtyResult(
            ok=True,
            account_id=account_id,
            asset_id=asset_id,
            requested_qty=new_qty,
            amend_quote_id=amend_quote,
            amend_order_id=order_id,
            amend_order_number=order_number,
            asset_quantity=asset_qty,
            warnings=warnings,
        )
    except Exception as exc:  # noqa: BLE001
        return AmendQtyResult(
            ok=False,
            account_id=account_id,
            asset_id=asset_id,
            requested_qty=new_qty,
            error=str(exc),
            warnings=warnings,
        )


def preview_qty_delta(
    *,
    list_pepm: float,
    current_qty: int,
    new_qty: int,
) -> dict[str, Any]:
    """Client-aligned estimate: list × (1 − volume) × qty for before/after."""
    def _net(qty: int) -> float:
        if qty <= 0:
            return 0.0
        vol = volume_rate(qty)
        return round(list_pepm * (1.0 - vol) * qty, 2)

    before = _net(current_qty)
    after = _net(new_qty)
    return {
        "currentMonthly": before,
        "afterMonthly": after,
        "difference": round(after - before, 2),
        "volumeRateCurrent": volume_rate(current_qty),
        "volumeRateAfter": volume_rate(new_qty),
    }


def _place_addon_quote(
    session: OrgSession,
    *,
    account_id: str,
    addon_skus: list[str],
    quantity: int,
    currency: str,
) -> str:
    """Place a Quote with only add-on lines on an existing Account."""
    skus = [s.upper() for s in addon_skus if s]
    if not skus:
        raise ValueError("addonSkus is required")
    if quantity < 1:
        raise ValueError("quantity must be >= 1")
    for sku in skus:
        if sku not in ADDON_LIST_USD:
            raise ValueError(f"Unknown add-on SKU: {sku}")

    pb = session.soql("SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1")[0]
    pbes = {sku: _pbe_for_sku(session, sku, currency) for sku in skus}
    opp_id = session.create(
        "Opportunity",
        {
            "Name": (
                f"Licenses add-on {'+'.join(skus)} ×{quantity}"
            )[:120],
            "AccountId": account_id,
            "StageName": "Prospecting",
            "CloseDate": "2026-12-31",
            "Pricebook2Id": pb["Id"],
            "CurrencyIsoCode": currency,
        },
    )
    today = date.today().isoformat()
    end = (date.today() + timedelta(days=365)).isoformat()
    names = ", ".join(ADDON_LABELS.get(s, s) for s in skus)
    records: list[dict[str, Any]] = [
        {
            "referenceId": "refQuote",
            "record": {
                "attributes": {"method": "POST", "type": "Quote"},
                "Name": f"Add modules — {names}"[:120],
                "OpportunityId": opp_id,
                "Pricebook2Id": pb["Id"],
                "QuoteAccountId": account_id,
                "CurrencyIsoCode": currency,
            },
        }
    ]
    for i, sku in enumerate(skus):
        pbe = pbes[sku]
        records.append(
            {
                "referenceId": f"refL{i}",
                "record": {
                    "attributes": {"type": "QuoteLineItem", "method": "POST"},
                    "QuoteId": "@{refQuote.id}",
                    "Product2Id": pbe["Product2Id"],
                    "PricebookEntryId": pbe["Id"],
                    "Quantity": str(quantity),
                    "StartDate": today,
                    "EndDate": end,
                    "PeriodBoundary": "Anniversary",
                    "BillingFrequency": "Monthly",
                },
            }
        )
    from service import API  # local import avoids circular noise at module load

    placed = session.post(
        f"/services/data/{API}/connect/rev/sales-transaction/actions/place",
        {
            "pricingPref": "Skip",
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
                "graphId": f"mod{uuid.uuid4().hex[:8]}",
                "records": records,
            },
        },
    )
    if isinstance(placed, list):
        placed = placed[0]
    if not placed.get("isSuccess"):
        raise RuntimeError(f"Place add-on quote failed: {placed}")
    quote_id = placed["salesTransactionId"]
    _system_reprice_quote(session, quote_id)
    return quote_id


@dataclass
class AccountChangeResult:
    ok: bool
    account_id: str
    qty_amend: dict[str, Any] | None = None
    module_sale: dict[str, Any] | None = None
    added_skus: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    error: str | None = None

    def as_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "accountId": self.account_id,
            "qtyAmend": self.qty_amend,
            "moduleSale": self.module_sale,
            "addedSkus": self.added_skus,
            "warnings": self.warnings,
            "error": self.error,
            # Convenience aliases for qty-only clients
            "amendOrderId": (self.qty_amend or {}).get("amendOrderId")
            or (self.module_sale or {}).get("orderId"),
            "amendOrderNumber": (self.qty_amend or {}).get("amendOrderNumber")
            or (self.module_sale or {}).get("orderNumber"),
            "assetQuantity": (self.qty_amend or {}).get("assetQuantity"),
            "assetIds": (self.module_sale or {}).get("assetIds") or [],
        }


def place_account_changes(
    session: OrgSession,
    *,
    account_id: str,
    asset_id: str | None = None,
    new_qty: int | None = None,
    addon_skus: list[str] | None = None,
) -> AccountChangeResult:
    """Apply qty amend and/or add-module sale for an Account."""
    warnings: list[str] = []
    addon_skus = [s.upper() for s in (addon_skus or []) if s]
    acct = resolve_account_id(session, account_id=account_id)
    currency = acct.get("CurrencyIsoCode") or "USD"
    billing = (acct.get("BillingCountry") or "US").upper()
    country = "UK" if billing in ("GB", "UK") else ("CA" if billing == "CA" else "US")

    owned = {
        (r.get("Product2") or {}).get("StockKeepingUnit")
        for r in session.soql(
            "SELECT Product2.StockKeepingUnit FROM Asset "
            f"WHERE AccountId = '{account_id}'"
        )
        if (r.get("Product2") or {}).get("StockKeepingUnit")
    }
    add_skus = [s for s in addon_skus if s not in owned]
    for s in addon_skus:
        if s in owned:
            warnings.append(f"{s} already owned — skipped.")
    if country in NON_US_COUNTRIES:
        blocked = [s for s in add_skus if s in US_ONLY_ADDONS]
        if blocked:
            return AccountChangeResult(
                ok=False,
                account_id=account_id,
                error=f"US-only add-ons not available in {country}: {', '.join(blocked)}",
                warnings=warnings,
            )

    qty_payload: dict[str, Any] | None = None
    if new_qty is not None:
        if not asset_id:
            return AccountChangeResult(
                ok=False,
                account_id=account_id,
                error="assetId is required when newQty is set",
                warnings=warnings,
            )
        try:
            current = int(_current_asset_quantity(session, asset_id))
        except RuntimeError:
            current = -1
        if current >= 0 and int(new_qty) == current:
            warnings.append("Quantity unchanged — skipped qty amend.")
        else:
            qty_result = place_qty_amend(
                session,
                account_id=account_id,
                asset_id=asset_id,
                new_qty=int(new_qty),
            )
            qty_payload = qty_result.as_dict()
            if not qty_result.ok:
                return AccountChangeResult(
                    ok=False,
                    account_id=account_id,
                    qty_amend=qty_payload,
                    error=qty_result.error,
                    warnings=warnings + qty_result.warnings,
                )
            warnings.extend(qty_result.warnings)

    module_payload: dict[str, Any] | None = None
    if add_skus:
        # Seat count for new modules: requested qty, else primary asset qty.
        qty = int(new_qty) if new_qty is not None else 0
        if qty < 1 and asset_id:
            try:
                qty = int(_current_asset_quantity(session, asset_id))
            except RuntimeError:
                qty = 0
        if qty < 1:
            return AccountChangeResult(
                ok=False,
                account_id=account_id,
                qty_amend=qty_payload,
                error="Could not resolve employee quantity for add-on sale",
                warnings=warnings,
            )
        try:
            quote_id = _place_addon_quote(
                session,
                account_id=account_id,
                addon_skus=add_skus,
                quantity=qty,
                currency=currency,
            )
            co = checkout_quote(session, quote_id, poll_timeout=180)
            module_payload = co.as_dict()
            if not co.ok:
                return AccountChangeResult(
                    ok=False,
                    account_id=account_id,
                    qty_amend=qty_payload,
                    module_sale=module_payload,
                    added_skus=add_skus,
                    error=co.error or "Add-module checkout failed",
                    warnings=warnings + list(co.warnings or []),
                )
            warnings.extend(co.warnings or [])
        except Exception as exc:  # noqa: BLE001
            return AccountChangeResult(
                ok=False,
                account_id=account_id,
                qty_amend=qty_payload,
                added_skus=add_skus,
                error=str(exc),
                warnings=warnings,
            )

    if qty_payload is None and module_payload is None:
        return AccountChangeResult(
            ok=False,
            account_id=account_id,
            error="Nothing to change — set newQty and/or addonSkus",
            warnings=warnings,
        )

    return AccountChangeResult(
        ok=True,
        account_id=account_id,
        qty_amend=qty_payload,
        module_sale=module_payload,
        added_skus=add_skus,
        warnings=warnings,
    )
