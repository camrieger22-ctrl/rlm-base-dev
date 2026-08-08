"""Licenses & billing / Amendment Console — Account assets, orders, amends.

Demo unlock 5a: resolve Account by Id or company name (no EC login yet).
- Qty true-up: OOTB Asset amend → order → activate
- Add modules: OOTB Place Quote (addon lines only) → createOrderFromQuote → Activate
  (Asset amend API is quantity-only; new SKUs are a supplemental sale on the Account)
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from typing import Any

from checkout import (
    amend_assets_quantity,
    amend_preview_cfg,
    apply_amend_volume_pricing,
    asset_live_metrics,
    asset_quantity_at,
    checkout_quote,
    complete_amend_quote,
    discard_stale_amend_drafts,
    find_sticky_amend_draft,
    find_sticky_amend_mutable,
    find_sticky_module_draft,
    module_preview_cfg,
    reprice_quote_system,
    resolve_amend_start,
    resolve_volume_tier_percent,
    tag_amend_preview_quote,
    _current_asset_quantity,
)
import threading
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
    lightning_record_url,
    quote_related_ids,
    sync_quote_to_opportunity,
    volume_rate,
)
from subscription_timeline import list_account_periods

_ACCOUNT_LOCKS: dict[str, threading.Lock] = {}
_ACCOUNT_LOCKS_GUARD = threading.Lock()


def _account_lock(account_id: str) -> threading.Lock:
    aid = (account_id or "").strip() or "_none"
    with _ACCOUNT_LOCKS_GUARD:
        lock = _ACCOUNT_LOCKS.get(aid)
        if lock is None:
            lock = threading.Lock()
            _ACCOUNT_LOCKS[aid] = lock
        return lock


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
    """Seats in effect today (CurrentQuantity / ASP) — not lifetime TotalQuantity."""
    metrics = asset_live_metrics(session, asset_id)
    qty = metrics.get("quantity")
    return float(qty) if qty is not None else None


def _asset_mrr(session: OrgSession, asset_id: str) -> float | None:
    """Monthly recurring in effect today (CurrentMrr / ASP)."""
    metrics = asset_live_metrics(session, asset_id)
    mrr = metrics.get("mrr")
    return float(mrr) if mrr is not None else None


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
        "SELECT Id, Name, Quantity, CurrentQuantity, CurrentMrr, Status, "
        "LifecycleStartDate, LifecycleEndDate, "
        "CreatedDate, Product2.Id, Product2.Name, Product2.StockKeepingUnit "
        f"FROM Asset WHERE AccountId = '{aid}' "
        "ORDER BY CreatedDate DESC LIMIT 50"
    )
    assets: list[dict[str, Any]] = []
    recurring_monthly = 0.0
    recurring_complete = True
    for row in assets_raw:
        product = row.get("Product2") or {}
        sku = product.get("StockKeepingUnit") or ""
        live = asset_live_metrics(session, row["Id"])
        qty = live.get("quantity")
        mrr = live.get("mrr")
        if mrr is not None:
            recurring_monthly += float(mrr)
        else:
            recurring_complete = False
        assets.append(
            {
                "id": row["Id"],
                "name": row.get("Name") or product.get("Name") or sku,
                "sku": sku,
                "quantity": qty,
                "mrr": mrr,
                "mrrSource": live.get("source"),
                "status": row.get("Status"),
                "productName": product.get("Name"),
                "lifecycleStartDate": row.get("LifecycleStartDate"),
                "lifecycleEndDate": row.get("LifecycleEndDate"),
                "createdDate": row.get("CreatedDate"),
            }
        )

    orders_raw = session.soql(
        "SELECT Id, OrderNumber, Status, EffectiveDate, TotalAmount, "
        "CreatedDate, Type "
        f"FROM Order WHERE AccountId = '{aid}' "
        "ORDER BY CreatedDate DESC LIMIT 15"
    )
    base = (session._instance or "").rstrip("/")
    orders = [
        {
            "id": r["Id"],
            "orderNumber": r.get("OrderNumber"),
            "status": r.get("Status"),
            "type": r.get("Type"),
            "totalAmount": r.get("TotalAmount"),
            "effectiveDate": r.get("EffectiveDate"),
            "createdDate": r.get("CreatedDate"),
            "orderUrl": lightning_record_url(base, "Order", r["Id"]),
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
            "quoteUrl": lightning_record_url(base, "Quote", r["Id"]),
        }
        for r in quotes_raw
    ]

    catalog = hydrate_catalog(session, country)
    try:
        from payments import list_open_invoices

        invoices = list_open_invoices(session, aid)
    except Exception:  # noqa: BLE001
        invoices = []

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
    term_start = (primary or {}).get("lifecycleStartDate")
    term_end = (primary or {}).get("lifecycleEndDate")
    if not term_end and term_start:
        try:
            start_d = date.fromisoformat(str(term_start)[:10])
            term_end = (start_d + timedelta(days=365)).isoformat()
        except ValueError:
            term_end = None

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
            "termStartDate": str(term_start)[:10] if term_start else None,
            "termEndDate": str(term_end)[:10] if term_end else None,
            "recurringMonthly": round(recurring_monthly, 2) if assets else 0.0,
            "recurringComplete": recurring_complete,
            "recurringSource": "salesforceCurrentMrr",
            "timeline": list_account_periods(session, aid),
        },
        "recentOrders": orders,
        "recentQuotes": quotes,
        "invoices": invoices,
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
    asset_ids: list[str] = field(default_factory=list)
    amend_quote_id: str | None = None
    amend_order_id: str | None = None
    amend_order_number: str | None = None
    opportunity_id: str | None = None
    asset_quantity: float | None = None
    warnings: list[str] = field(default_factory=list)
    error: str | None = None

    def as_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "accountId": self.account_id,
            "assetId": self.asset_id,
            "assetIds": self.asset_ids or ([self.asset_id] if self.asset_id else []),
            "requestedQty": self.requested_qty,
            "amendQuoteId": self.amend_quote_id,
            "amendOrderId": self.amend_order_id,
            "amendOrderNumber": self.amend_order_number,
            "opportunityId": self.opportunity_id,
            "assetQuantity": self.asset_quantity,
            "warnings": self.warnings,
            "error": self.error,
        }


def _is_headcount_sku(sku: str) -> bool:
    """PEPM / seat-based SKUs share company headcount; flat monthly does not."""
    s = (sku or "").upper()
    if not s:
        return False
    if s == CORE_FLAT_SKU or "FLAT" in s:
        return False
    return True


def list_headcount_assets(
    session: OrgSession, account_id: str
) -> list[dict[str, Any]]:
    """Assets whose quantity should move with employee count."""
    rows = session.soql(
        "SELECT Id, Name, AccountId, Product2.StockKeepingUnit, Product2.Name "
        f"FROM Asset WHERE AccountId = '{_soql_escape(account_id)}' "
        "ORDER BY CreatedDate ASC LIMIT 100"
    )
    out: list[dict[str, Any]] = []
    for row in rows:
        sku = ((row.get("Product2") or {}).get("StockKeepingUnit") or "").upper()
        if not _is_headcount_sku(sku):
            continue
        live = asset_live_metrics(session, row["Id"])
        qty = live.get("quantity")
        if qty is None:
            continue
        out.append(
            {
                "id": row["Id"],
                "sku": sku,
                "name": row.get("Name")
                or (row.get("Product2") or {}).get("Name")
                or sku,
                "quantity": float(qty),
                "mrr": live.get("mrr"),
            }
        )
    return out


def _resolve_headcount_assets(
    session: OrgSession,
    account_id: str,
    asset_id: str | None,
) -> tuple[list[dict[str, Any]], str | None]:
    """Return (headcount assets, error)."""
    primary = asset_id or ""
    headcount_assets = list_headcount_assets(session, account_id)
    if not headcount_assets and primary:
        rows = session.soql(
            "SELECT Id, AccountId, Product2.StockKeepingUnit FROM Asset "
            f"WHERE Id = '{_soql_escape(primary)}' LIMIT 1"
        )
        if not rows:
            return [], "Asset not found"
        if rows[0].get("AccountId") != account_id:
            return [], "Asset does not belong to this Account"
        live = asset_live_metrics(session, primary)
        qty = live.get("quantity")
        if qty is None:
            return [], f"Could not resolve current quantity for asset {primary}"
        headcount_assets = [
            {
                "id": primary,
                "sku": ((rows[0].get("Product2") or {}).get("StockKeepingUnit") or ""),
                "name": primary,
                "quantity": float(qty),
                "mrr": live.get("mrr"),
            }
        ]
    if not headcount_assets:
        return [], "No per-employee assets found to amend"
    return headcount_assets, None


def _quote_pricing_snapshot(session: OrgSession, quote_id: str) -> dict[str, Any]:
    """Read Quote + QLI amounts after System / volume pricing."""
    qrows = session.soql(
        "SELECT Id, QuoteNumber, TotalPrice, CurrencyIsoCode, Status "
        f"FROM Quote WHERE Id = '{_soql_escape(quote_id)}' LIMIT 1"
    )
    if not qrows:
        raise RuntimeError(f"Quote not found: {quote_id}")
    q = qrows[0]
    lines_raw = session.soql(
        "SELECT Id, Quantity, UnitPrice, NetUnitPrice, TotalPrice, Discount, "
        "Product2.Name, Product2.StockKeepingUnit "
        f"FROM QuoteLineItem WHERE QuoteId = '{_soql_escape(quote_id)}'"
    )
    lines: list[dict[str, Any]] = []
    for row in lines_raw:
        product = row.get("Product2") or {}
        sku = (product.get("StockKeepingUnit") or "").upper()
        lines.append(
            {
                "id": row["Id"],
                "sku": sku,
                "name": product.get("Name") or sku,
                "quantity": float(row.get("Quantity") or 0),
                "unitPrice": float(row.get("UnitPrice") or 0),
                "netUnitPrice": float(
                    row.get("NetUnitPrice")
                    if row.get("NetUnitPrice") is not None
                    else (row.get("UnitPrice") or 0)
                ),
                "totalPrice": float(row.get("TotalPrice") or 0),
                "discount": float(row.get("Discount") or 0),
                "isFlat": (not _is_headcount_sku(sku)) if sku else False,
            }
        )
    return {
        "quoteId": quote_id,
        "quoteNumber": q.get("QuoteNumber"),
        "status": q.get("Status"),
        "currency": q.get("CurrencyIsoCode") or "USD",
        "totalPrice": float(q.get("TotalPrice") or 0),
        "lines": lines,
    }


def _net_pepm_from_schedule(
    session: OrgSession,
    *,
    sku: str,
    currency: str,
    headcount: int,
) -> dict[str, Any] | None:
    """List + net PEPM from Standard PBE and live Volume PAT (same as amend patch)."""
    sku = (sku or "").upper()
    if not sku or not _is_headcount_sku(sku):
        return None
    try:
        pbe = _pbe_for_sku(session, sku, currency)
    except Exception:
        return None
    list_p = float(pbe.get("UnitPrice") or 0)
    if list_p <= 0:
        return None
    product2_id = pbe.get("Product2Id") or ""
    psm = pbe.get("ProductSellingModelId")
    vol_pct, tier_id = resolve_volume_tier_percent(
        session,
        product2_id=product2_id,
        product_selling_model_id=psm,
        currency=currency,
        headcount=int(headcount),
    )
    net = round(list_p * (1.0 - vol_pct / 100.0), 2)
    return {
        "sku": sku,
        "listPepm": list_p,
        "netPepm": net,
        "volumePercent": vol_pct,
        "tierId": tier_id,
        "source": "priceAdjustmentTier",
    }


def _flat_monthly(session: OrgSession, sku: str, currency: str) -> float | None:
    try:
        pbe = _pbe_for_sku(session, sku, currency)
    except Exception:
        return None
    return float(pbe.get("UnitPrice") or 0) or None


def ensure_amend_opportunity(
    session: OrgSession,
    *,
    account_id: str,
    currency: str,
    name: str,
    preferred_opp_id: str | None = None,
    name_prefix: str = "Licenses amend",
) -> str:
    """Create or reuse a Prospecting Licenses Opportunity.

    Connect amend accepts ``opportunityId`` so the amendment Quote syncs to an
    Opp the same way Managed Asset viewer does when a sales Opp is selected.
    """
    if preferred_opp_id:
        rows = session.soql(
            "SELECT Id, StageName FROM Opportunity "
            f"WHERE Id = '{_soql_escape(preferred_opp_id)}' LIMIT 1"
        )
        if rows and (rows[0].get("StageName") or "") == "Prospecting":
            try:
                session.patch("Opportunity", preferred_opp_id, {"Name": name[:120]})
            except Exception:
                pass
            return preferred_opp_id

    prefix = (name_prefix or "Licenses amend").replace("'", "\\'")
    rows = session.soql(
        "SELECT Id FROM Opportunity "
        f"WHERE AccountId = '{_soql_escape(account_id)}' "
        "AND StageName = 'Prospecting' "
        f"AND Name LIKE '{prefix}%' "
        "ORDER BY CreatedDate DESC LIMIT 5"
    )
    if rows:
        opp_id = rows[0]["Id"]
        try:
            session.patch("Opportunity", opp_id, {"Name": name[:120]})
        except Exception:
            pass
        return opp_id

    pb = session.soql("SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1")[0]
    return session.create(
        "Opportunity",
        {
            "Name": name[:120],
            "AccountId": account_id,
            "StageName": "Prospecting",
            "CloseDate": "2026-12-31",
            "Pricebook2Id": pb["Id"],
            "CurrencyIsoCode": currency,
        },
    )


def create_qty_amend_drafts(
    session: OrgSession,
    *,
    account_id: str,
    asset_id: str | None,
    new_qty: int,
    start: datetime | None = None,
    preferred_drafts: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """Create or reuse sticky amendment Quotes, System-reprice — do not order.

    Returns ``{ ok, drafts: [{quoteId, assetIds, snapshot}], warnings, error }``.
    Prefers reusing Draft Quotes tagged ``[bamboohr-preview] amend …`` when the
    qty/start/asset fingerprint matches (live preview sticky path).
    """
    primary = asset_id or ""
    if new_qty < 1:
        return {
            "ok": False,
            "drafts": [],
            "warnings": [],
            "error": "newQty must be >= 1",
            "assetId": primary,
        }

    headcount_assets, err = _resolve_headcount_assets(session, account_id, asset_id)
    if err:
        return {
            "ok": False,
            "drafts": [],
            "warnings": [],
            "error": err,
            "assetId": primary,
        }

    warnings: list[str] = []
    preferred_by_assets: dict[str, str] = {}
    for d in preferred_drafts or []:
        qid = str(d.get("quoteId") or "").strip()
        ids = [str(a) for a in (d.get("assetIds") or []) if a]
        if qid and ids:
            preferred_by_assets["+".join(sorted(ids))] = qid

    # Deltas from ASP quantity on the effective amend start (not lifetime
    # TotalQuantity — that breaks decreases when future ASPs exist).
    by_delta: dict[float, list[dict[str, Any]]] = {}
    skipped: list[str] = []
    sample_ids = [a["id"] for a in headcount_assets]
    tomorrow = datetime.now(timezone.utc) + timedelta(days=1)
    requested_day = (start or tomorrow).date()
    eff_start = resolve_amend_start(session, sample_ids, start)
    if eff_start.date() > requested_day:
        warnings.append(
            f"Change start moved to {eff_start.date().isoformat()} so the "
            "amend lands on your latest quantity period (needed for decreases)."
        )
    for asset in headcount_assets:
        current = asset_quantity_at(session, asset["id"], as_of=eff_start)
        asset["quantity"] = current
        delta = float(new_qty) - current
        if abs(delta) < 1e-6:
            skipped.append(str(asset.get("sku") or asset["id"]))
            continue
        by_delta.setdefault(delta, []).append(asset)
    if skipped:
        warnings.append(
            "Already at target qty on "
            f"{eff_start.date().isoformat()} (skipped): " + ", ".join(skipped)
        )
    if not by_delta:
        return {
            "ok": True,
            "drafts": [],
            "warnings": warnings + ["Quantity unchanged — nothing to amend."],
            "assetId": primary or headcount_assets[0]["id"],
            "assetIds": [a["id"] for a in headcount_assets],
            "noop": True,
            "amendStartDate": eff_start.date().isoformat(),
        }

    start_iso = eff_start.date().isoformat()
    # Attempt sticky reuse / qty retarget (like Get Pricing) before Connect amend.
    reused: list[dict[str, Any]] = []
    missing_groups: list[tuple[float, list[dict[str, Any]]]] = []
    keep_ids: list[str] = []
    for delta, group in by_delta.items():
        ids = [a["id"] for a in group]
        assets_key = "+".join(sorted(ids))
        cfg = amend_preview_cfg(
            new_qty=new_qty,
            start_iso=start_iso,
            asset_ids=ids,
            quantity_change=delta,
        )
        preferred_qid = preferred_by_assets.get(assets_key)
        # 1) Exact cfg → snapshot only (no Salesforce reprice).
        sticky = find_sticky_amend_draft(
            session,
            account_id,
            cfg=cfg,
            preferred_quote_id=preferred_qid,
        )
        if sticky:
            qid = sticky["Id"]
            keep_ids.append(qid)
            snapshot = _quote_pricing_snapshot(session, qid)
            opp_id = sticky.get("OpportunityId")
            reused.append(
                {
                    "quoteId": qid,
                    "assetIds": ids,
                    "quantityChange": delta,
                    "skus": [str(a.get("sku") or "") for a in group],
                    "opportunityId": opp_id,
                    "snapshot": snapshot,
                    "sticky": True,
                    "fastPath": True,
                }
            )
            warnings.append(
                f"Sticky amend Quote unchanged (fast path) for {len(ids)} line(s)"
            )
            continue

        # 2) Same assets+start+direction → retarget delta Quantity via System
        #    place (mirrors initial-sale headcount-only sticky), skip Connect.
        mutable = find_sticky_amend_mutable(
            session,
            account_id,
            start_iso=start_iso,
            asset_ids=ids,
            quantity_change=delta,
            preferred_quote_id=preferred_qid,
        )
        if mutable:
            qid = mutable["Id"]
            keep_ids.append(qid)
            try:
                lines = session.soql(
                    "SELECT Id, Quantity, Product2.StockKeepingUnit "
                    f"FROM QuoteLineItem WHERE QuoteId = '{qid}'"
                )
                qty_by_sku: dict[str, int] = {}
                abs_delta = max(1, int(round(abs(float(delta)))))
                for line in lines:
                    sku = (
                        (line.get("Product2") or {}).get("StockKeepingUnit") or ""
                    ).upper()
                    if sku:
                        qty_by_sku[sku] = abs_delta
                if qty_by_sku:
                    _system_reprice_quote(
                        session, qid, quantity_by_sku=qty_by_sku
                    )
                apply_amend_volume_pricing(
                    session, qid, volume_headcount=int(new_qty)
                )
                tag_amend_preview_quote(session, qid, cfg=cfg, kind="amend")
                opp_id = mutable.get("OpportunityId")
                if opp_id:
                    sync_quote_to_opportunity(session, qid, opp_id)
                    try:
                        session.patch(
                            "Opportunity",
                            opp_id,
                            {"Name": f"Licenses amend — {new_qty} seats"[:120]},
                        )
                    except Exception:
                        pass
                snapshot = _quote_pricing_snapshot(session, qid)
                reused.append(
                    {
                        "quoteId": qid,
                        "assetIds": ids,
                        "quantityChange": delta,
                        "skus": [str(a.get("sku") or "") for a in group],
                        "opportunityId": opp_id,
                        "snapshot": snapshot,
                        "sticky": True,
                        "retargeted": True,
                    }
                )
                warnings.append(
                    f"Retargeted sticky amend Quote qty→{abs_delta} "
                    f"(delta {delta:+g}) — skipped Connect amend"
                )
                continue
            except Exception as exc:  # noqa: BLE001
                warnings.append(
                    f"Sticky amend retarget failed — recreating via Connect: {exc}"
                )
                keep_ids = [k for k in keep_ids if k != qid]
        missing_groups.append((delta, group))

    if not missing_groups and reused:
        discarded = discard_stale_amend_drafts(
            session, account_id, keep_quote_ids=keep_ids
        )
        if discarded:
            warnings.append(
                f"Discarded {len(discarded)} stale Draft amendment Quote(s)."
            )
        opportunity_id = next(
            (str(d["opportunityId"]) for d in reused if d.get("opportunityId")),
            None,
        )
        return {
            "ok": True,
            "drafts": reused,
            "warnings": warnings,
            "assetId": primary or (reused[0]["assetIds"][0] if reused else ""),
            "assetIds": [aid for d in reused for aid in d["assetIds"]],
            "opportunityId": opportunity_id,
            "noop": False,
            "amendStartDate": start_iso,
            "sticky": True,
        }

    # Drop leftover Draft amendment Quotes so ASP/locks don't block decreases.
    # Keep any sticky drafts we already refreshed in this request.
    discarded = discard_stale_amend_drafts(
        session, account_id, keep_quote_ids=keep_ids
    )
    if discarded:
        warnings.append(f"Discarded {len(discarded)} stale Draft amendment Quote(s).")

    drafts: list[dict[str, Any]] = list(reused)
    opportunity_id: str | None = next(
        (str(d["opportunityId"]) for d in reused if d.get("opportunityId")),
        None,
    )
    try:
        acct_rows = session.soql(
            "SELECT CurrencyIsoCode FROM Account "
            f"WHERE Id = '{_soql_escape(account_id)}' LIMIT 1"
        )
        currency = (acct_rows[0].get("CurrencyIsoCode") if acct_rows else None) or "USD"
        opportunity_id = ensure_amend_opportunity(
            session,
            account_id=account_id,
            currency=currency,
            name=f"Licenses amend — {new_qty} seats",
            preferred_opp_id=opportunity_id,
        )
        for delta, group in missing_groups:
            ids = [a["id"] for a in group]
            labels = ", ".join(str(a.get("sku") or a["id"]) for a in group)
            cfg = amend_preview_cfg(
                new_qty=new_qty,
                start_iso=start_iso,
                asset_ids=ids,
                quantity_change=delta,
            )
            amend_quote = amend_assets_quantity(
                session,
                ids,
                new_qty,
                start=eff_start,
                quantity_change=delta,
                opportunity_id=opportunity_id,
            )
            if not amend_quote:
                return {
                    "ok": False,
                    "drafts": drafts,
                    "warnings": warnings,
                    "error": f"Amend API returned no amendment quote id ({labels})",
                    "assetId": primary or ids[0],
                    "opportunityId": opportunity_id,
                }
            tag_amend_preview_quote(session, amend_quote, cfg=cfg, kind="amend")
            reprice_quote_system(session, amend_quote)
            apply_amend_volume_pricing(
                session, amend_quote, volume_headcount=int(new_qty)
            )
            sync_quote_to_opportunity(session, amend_quote, opportunity_id)
            snapshot = _quote_pricing_snapshot(session, amend_quote)
            drafts.append(
                {
                    "quoteId": amend_quote,
                    "assetIds": ids,
                    "quantityChange": delta,
                    "skus": [str(a.get("sku") or "") for a in group],
                    "opportunityId": opportunity_id,
                    "snapshot": snapshot,
                    "sticky": False,
                }
            )
            warnings.append(
                f"Priced amend draft for {len(ids)} line(s) by {delta:+g}: {labels}"
            )
        return {
            "ok": True,
            "drafts": drafts,
            "warnings": warnings,
            "assetId": primary or (drafts[0]["assetIds"][0] if drafts else ""),
            "assetIds": [aid for d in drafts for aid in d["assetIds"]],
            "opportunityId": opportunity_id,
            "noop": False,
            "amendStartDate": start_iso,
            "sticky": bool(reused) and not missing_groups,
        }
    except Exception as exc:  # noqa: BLE001
        # Preview failed mid-flight — drop any drafts we just created.
        for draft in drafts:
            if draft.get("sticky"):
                continue
            qid = str(draft.get("quoteId") or "")
            if qid:
                try:
                    session.delete("Quote", qid)
                except Exception:
                    try:
                        session.patch("Quote", qid, {"Status": "Denied"})
                    except Exception:
                        pass
        return {
            "ok": False,
            "drafts": [],
            "warnings": warnings,
            "error": str(exc),
            "assetId": primary,
            "opportunityId": opportunity_id,
            "amendStartDate": start_iso,
        }


def activate_qty_amend_drafts(
    session: OrgSession,
    *,
    account_id: str,
    new_qty: int,
    drafts: list[dict[str, Any]],
    primary_asset_id: str | None = None,
) -> AmendQtyResult:
    """Order + activate previously priced amendment Quotes."""
    primary = primary_asset_id or ""
    warnings: list[str] = []
    amended_ids: list[str] = []
    last_quote: str | None = None
    last_order: str | None = None
    last_order_number: str | None = None
    last_opp: str | None = None
    last_qty = float(new_qty)
    try:
        for draft in drafts:
            qid = str(draft.get("quoteId") or "")
            ids = [str(a) for a in (draft.get("assetIds") or []) if a]
            if not qid or not ids:
                continue
            if draft.get("opportunityId"):
                last_opp = str(draft["opportunityId"])
            # Keep Opportunity.SyncedQuoteId pointed at this amendment Quote
            # before native createOrderFromQuote / Activate.
            if last_opp:
                try:
                    sync_quote_to_opportunity(session, qid, last_opp)
                except Exception:
                    pass
            order_id, order_number, asset_qty = complete_amend_quote(
                session,
                qid,
                account_id,
                ids[0],
                target_qty=new_qty,
                asset_ids=ids,
            )
            # complete_amend_quote System-reprices again; volume patch runs inside
            # place_activate_order when volume_headcount is set.
            amended_ids.extend(ids)
            last_quote = qid
            last_order = order_id
            last_order_number = order_number
            last_qty = asset_qty
            warnings.append(f"Activated amend quote {qid} for {len(ids)} asset(s)")
        if not amended_ids:
            return AmendQtyResult(
                ok=False,
                account_id=account_id,
                asset_id=primary,
                requested_qty=new_qty,
                error="No amend quote drafts to activate",
            )
        if not last_opp and last_quote:
            related = quote_related_ids(session, last_quote)
            last_opp = related.get("opportunityId") or None
        # Hygiene must NOT delete Quotes we just ordered — createOrderFromQuote
        # often leaves the Amendment Quote in Draft, and wiping it makes SF look
        # like "no Quote was created" after Place order.
        keep_ids = [
            str(d.get("quoteId"))
            for d in drafts
            if d.get("quoteId")
        ]
        discarded = discard_stale_amend_drafts(
            session, account_id, keep_quote_ids=keep_ids
        )
        if discarded:
            warnings.append(
                f"Cleaned {len(discarded)} leftover Draft amendment Quote(s)."
            )
        return AmendQtyResult(
            ok=True,
            account_id=account_id,
            asset_id=primary or amended_ids[0],
            asset_ids=amended_ids,
            requested_qty=new_qty,
            amend_quote_id=last_quote,
            amend_order_id=last_order,
            amend_order_number=last_order_number,
            opportunity_id=last_opp,
            asset_quantity=last_qty,
            warnings=warnings,
        )
    except Exception as exc:  # noqa: BLE001
        return AmendQtyResult(
            ok=False,
            account_id=account_id,
            asset_id=primary or (amended_ids[0] if amended_ids else ""),
            asset_ids=amended_ids,
            requested_qty=new_qty,
            amend_quote_id=last_quote,
            amend_order_id=last_order,
            amend_order_number=last_order_number,
            opportunity_id=last_opp,
            error=str(exc),
            warnings=warnings,
        )


def place_qty_amend(
    session: OrgSession,
    *,
    account_id: str,
    asset_id: str | None,
    new_qty: int,
    start: datetime | None = None,
) -> AmendQtyResult:
    """Commit headcount true-up on **all** PEPM assets via OOTB amend."""
    draft = create_qty_amend_drafts(
        session,
        account_id=account_id,
        asset_id=asset_id,
        new_qty=new_qty,
        start=start,
    )
    if not draft.get("ok"):
        return AmendQtyResult(
            ok=False,
            account_id=account_id,
            asset_id=str(draft.get("assetId") or asset_id or ""),
            requested_qty=new_qty,
            error=draft.get("error") or "Amend draft failed",
            warnings=list(draft.get("warnings") or []),
        )
    if draft.get("noop"):
        return AmendQtyResult(
            ok=True,
            account_id=account_id,
            asset_id=str(draft.get("assetId") or ""),
            asset_ids=list(draft.get("assetIds") or []),
            requested_qty=new_qty,
            asset_quantity=float(new_qty),
            warnings=list(draft.get("warnings") or []),
        )
    return activate_qty_amend_drafts(
        session,
        account_id=account_id,
        new_qty=new_qty,
        drafts=list(draft.get("drafts") or []),
        primary_asset_id=str(draft.get("assetId") or asset_id or "") or None,
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
    preferred_quote_id: str | None = None,
) -> str:
    """Place or reuse a sticky add-module Quote on an existing Account.

    Native RC path: Opportunity + Quote via sales-transaction place, then
    System reprice. Sticky Draft Quotes are tagged ``[bamboohr-preview] module``.
    """
    skus = [s.upper() for s in addon_skus if s]
    if not skus:
        raise ValueError("addonSkus is required")
    if quantity < 1:
        raise ValueError("quantity must be >= 1")
    for sku in skus:
        if sku not in ADDON_LIST_USD:
            raise ValueError(f"Unknown add-on SKU: {sku}")

    cfg = module_preview_cfg(quantity=quantity, addon_skus=skus)
    sticky = find_sticky_module_draft(
        session,
        account_id,
        cfg=cfg,
        preferred_quote_id=preferred_quote_id,
    )
    if sticky:
        qid = sticky["Id"]
        # Keep line quantities aligned (native System update via place skip path:
        # patch Quantity then System reprice).
        try:
            lines = session.soql(
                "SELECT Id, Quantity, Product2.StockKeepingUnit "
                f"FROM QuoteLineItem WHERE QuoteId = '{qid}'"
            )
            for line in lines:
                sku = ((line.get("Product2") or {}).get("StockKeepingUnit") or "").upper()
                if sku in skus and int(line.get("Quantity") or 0) != int(quantity):
                    session.patch(
                        "QuoteLineItem", line["Id"], {"Quantity": int(quantity)}
                    )
            tag_amend_preview_quote(session, qid, cfg=cfg, kind="module")
            reprice_quote_system(session, qid)
            apply_amend_volume_pricing(
                session, qid, volume_headcount=int(quantity)
            )
            sync_quote_to_opportunity(session, qid, sticky.get("OpportunityId"))
            return qid
        except Exception:
            # Fall through to create a fresh sticky Quote.
            try:
                session.delete("Quote", qid)
            except Exception:
                pass

    # Discard other *module* sticky Drafts only — never wipe qty-amend Quotes.
    try:
        other = session.soql(
            "SELECT Id, Name, Description FROM Quote WHERE Status = 'Draft' "
            f"AND (QuoteAccountId = '{_soql_escape(account_id)}' "
            f"OR AccountId = '{_soql_escape(account_id)}') "
            "ORDER BY CreatedDate DESC LIMIT 40"
        )
        for row in other:
            desc = row.get("Description") or ""
            name = (row.get("Name") or "").lower()
            if "[bamboohr-preview] module" not in desc and not name.startswith(
                "add modules"
            ):
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

    pb = session.soql("SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1")[0]
    pbes = {sku: _pbe_for_sku(session, sku, currency) for sku in skus}
    opp_id = ensure_amend_opportunity(
        session,
        account_id=account_id,
        currency=currency,
        name=f"Licenses add-on {'+'.join(skus)} ×{quantity}"[:120],
        name_prefix="Licenses add-on",
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
    tag_amend_preview_quote(session, quote_id, cfg=cfg, kind="module")
    _system_reprice_quote(session, quote_id)
    apply_amend_volume_pricing(session, quote_id, volume_headcount=int(quantity))
    sync_quote_to_opportunity(session, quote_id, opp_id)
    return quote_id


def _txn_links(
    session: OrgSession,
    *,
    account_id: str,
    quote_id: str | None,
    order_id: str | None,
    asset_ids: list[str] | None = None,
    contact_id: str | None = None,
    opportunity_id: str | None = None,
) -> dict[str, Any]:
    base = (session._instance or "").rstrip("/")
    related = quote_related_ids(session, quote_id or "") if quote_id else {}
    opp_id = opportunity_id or related.get("opportunityId") or ""
    contact = contact_id or related.get("contactId") or ""
    if not contact:
        crow = session.soql(
            "SELECT Id FROM Contact "
            f"WHERE AccountId = '{_soql_escape(account_id)}' "
            "ORDER BY CreatedDate DESC LIMIT 1"
        )
        contact = crow[0]["Id"] if crow else ""
    assets = [a for a in (asset_ids or []) if a]
    return {
        "account": lightning_record_url(base, "Account", account_id),
        "contact": lightning_record_url(base, "Contact", contact),
        "opportunity": lightning_record_url(base, "Opportunity", opp_id),
        "quote": lightning_record_url(base, "Quote", quote_id),
        "order": lightning_record_url(base, "Order", order_id),
        "assets": [lightning_record_url(base, "Asset", aid) for aid in assets],
        "accountId": account_id,
        "contactId": contact,
        "opportunityId": opp_id,
        "quoteId": quote_id or "",
        "orderId": order_id or "",
        "assetIds": assets,
    }


def build_change_confirmation(
    session: OrgSession,
    *,
    account_id: str,
    account_name: str,
    qty_amend: dict[str, Any] | None,
    module_sale: dict[str, Any] | None,
    added_skus: list[str],
) -> dict[str, Any]:
    """Welcome-style confirmation payload with Lightning deep links."""
    transactions: list[dict[str, Any]] = []
    if qty_amend and qty_amend.get("ok"):
        asset_id = qty_amend.get("assetId") or ""
        asset_ids = list(qty_amend.get("assetIds") or [])
        if not asset_ids and asset_id:
            asset_ids = [asset_id]
        qid = qty_amend.get("amendQuoteId") or ""
        oid = qty_amend.get("amendOrderId") or ""
        links = _txn_links(
            session,
            account_id=account_id,
            quote_id=qid,
            order_id=oid,
            asset_ids=asset_ids,
            opportunity_id=qty_amend.get("opportunityId"),
        )
        n_assets = len(asset_ids)
        transactions.append(
            {
                "kind": "qtyAmend",
                "label": (
                    f"Quantity change ({n_assets} products)"
                    if n_assets > 1
                    else "Quantity change"
                ),
                "orderNumber": qty_amend.get("amendOrderNumber") or oid,
                "requestedQty": qty_amend.get("requestedQty"),
                "assetQuantity": qty_amend.get("assetQuantity"),
                "assetIds": asset_ids,
                **links,
                "links": {
                    "account": links["account"],
                    "contact": links["contact"],
                    "opportunity": links["opportunity"],
                    "quote": links["quote"],
                    "order": links["order"],
                    "assets": links["assets"],
                },
            }
        )
    if module_sale and module_sale.get("ok"):
        qid = module_sale.get("quoteId") or ""
        oid = module_sale.get("orderId") or ""
        asset_ids = list(module_sale.get("assetIds") or [])
        links = _txn_links(
            session,
            account_id=account_id,
            quote_id=qid,
            order_id=oid,
            asset_ids=asset_ids,
        )
        transactions.append(
            {
                "kind": "moduleSale",
                "label": "Add-on modules",
                "orderNumber": module_sale.get("orderNumber") or oid,
                "addedSkus": list(added_skus or []),
                **links,
                "links": {
                    "account": links["account"],
                    "contact": links["contact"],
                    "opportunity": links["opportunity"],
                    "quote": links["quote"],
                    "order": links["order"],
                    "assets": links["assets"],
                },
            }
        )

    kinds = {t["kind"] for t in transactions}
    if kinds == {"moduleSale"}:
        kind = "addon"
        title = f"Modules added for {account_name}"
        lede = (
            "Your add-on order is activated in Salesforce Revenue Cloud — "
            "Account, Opportunity, Quote, Order, and Assets are live."
        )
    elif kinds == {"qtyAmend"}:
        kind = "qty"
        title = f"Licenses updated for {account_name}"
        lede = (
            "Your quantity amend is activated in Salesforce Revenue Cloud — "
            "Account, Opportunity, Quote, Order, and Assets are live."
        )
    else:
        kind = "addon_and_qty"
        title = f"Changes complete for {account_name}"
        lede = (
            "Your quantity amend and add-on order are activated in Salesforce "
            "Revenue Cloud — open the records below beside this tab."
        )

    # Primary transaction for top-level links (prefer module sale, else qty).
    primary = next(
        (t for t in transactions if t["kind"] == "moduleSale"),
        transactions[0] if transactions else None,
    )
    primary_links = (primary or {}).get("links") or {}
    metrics: list[list[str]] = []
    for t in transactions:
        label = "Add-on order" if t["kind"] == "moduleSale" else "Amend order"
        metrics.append([label, str(t.get("orderNumber") or "—")])
    if added_skus:
        metrics.append(["Modules", ", ".join(added_skus)])
    asset_n = sum(len(t.get("assetIds") or []) for t in transactions)
    if asset_n:
        metrics.append(["Assets", str(asset_n)])

    return {
        "kind": kind,
        "title": title,
        "lede": lede,
        "accountName": account_name,
        "accountId": account_id,
        "metrics": [{"label": a, "value": b} for a, b in metrics],
        "links": primary_links,
        "transactions": transactions,
        "instanceUrl": (session._instance or "").rstrip("/"),
    }


@dataclass
class AccountChangeResult:
    ok: bool
    account_id: str
    qty_amend: dict[str, Any] | None = None
    module_sale: dict[str, Any] | None = None
    added_skus: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    error: str | None = None
    confirmation: dict[str, Any] | None = None
    account_name: str = ""
    payment: dict[str, Any] | None = None

    def as_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "accountId": self.account_id,
            "accountName": self.account_name,
            "qtyAmend": self.qty_amend,
            "moduleSale": self.module_sale,
            "addedSkus": self.added_skus,
            "warnings": self.warnings,
            "error": self.error,
            "confirmation": self.confirmation,
            "payment": self.payment,
            # Convenience aliases for qty-only clients
            "amendOrderId": (self.qty_amend or {}).get("amendOrderId")
            or (self.module_sale or {}).get("orderId"),
            "amendOrderNumber": (self.qty_amend or {}).get("amendOrderNumber")
            or (self.module_sale or {}).get("orderNumber"),
            "assetQuantity": (self.qty_amend or {}).get("assetQuantity"),
            "assetIds": (self.module_sale or {}).get("assetIds") or [],
            "links": (self.confirmation or {}).get("links") or {},
        }


def _owned_assets_detail(
    session: OrgSession, account_id: str
) -> list[dict[str, Any]]:
    rows = session.soql(
        "SELECT Id, Name, Product2.StockKeepingUnit, Product2.Name "
        f"FROM Asset WHERE AccountId = '{_soql_escape(account_id)}' "
        "ORDER BY CreatedDate ASC LIMIT 100"
    )
    out: list[dict[str, Any]] = []
    for row in rows:
        sku = ((row.get("Product2") or {}).get("StockKeepingUnit") or "").upper()
        if not sku:
            continue
        live = asset_live_metrics(session, row["Id"])
        if _is_headcount_sku(sku):
            qty = live.get("quantity")
        else:
            qty = 1.0
        out.append(
            {
                "id": row["Id"],
                "sku": sku,
                "name": row.get("Name")
                or (row.get("Product2") or {}).get("Name")
                or sku,
                "quantity": float(qty) if qty is not None else None,
                "mrr": live.get("mrr"),
                "isFlat": not _is_headcount_sku(sku),
            }
        )
    return out


def _line_monthly_from_schedule(
    session: OrgSession,
    *,
    sku: str,
    name: str,
    headcount: int,
    currency: str,
    is_flat: bool,
) -> dict[str, Any] | None:
    if is_flat:
        flat = _flat_monthly(session, sku, currency)
        if flat is None:
            return None
        return {
            "sku": sku,
            "name": name,
            "qty": 1,
            "netPepm": None,
            "listPepm": None,
            "monthly": round(flat, 2),
            "isFlat": True,
            "isPepm": False,
            "source": "pricebook",
        }
    priced = _net_pepm_from_schedule(
        session, sku=sku, currency=currency, headcount=headcount
    )
    if not priced:
        return None
    monthly = round(priced["netPepm"] * headcount, 2)
    return {
        "sku": sku,
        "name": name,
        "qty": headcount,
        "netPepm": priced["netPepm"],
        "listPepm": priced["listPepm"],
        "volumePercent": priced["volumePercent"],
        "monthly": monthly,
        "isFlat": False,
        "isPepm": True,
        "source": priced["source"],
    }


def preview_account_changes(
    session: OrgSession,
    *,
    account_id: str,
    asset_id: str | None = None,
    new_qty: int | None = None,
    addon_skus: list[str] | None = None,
    start_date: date | None = None,
    current_qty: int | None = None,
    preferred_amend_quotes: list[dict[str, Any]] | None = None,
    preferred_module_quote_id: str | None = None,
) -> dict[str, Any]:
    """Price change drafts in Revenue Cloud (no Activate).

    Creates or reuses sticky amendment Quote(s) and/or an add-module Quote,
    System-reprices (plus amend volume patch), and returns totals for the UI.
    """
    warnings: list[str] = []
    addon_skus = [s.upper() for s in (addon_skus or []) if s]
    acct = resolve_account_id(session, account_id=account_id)
    currency = acct.get("CurrencyIsoCode") or "USD"
    billing = (acct.get("BillingCountry") or "US").upper()
    country = "UK" if billing in ("GB", "UK") else ("CA" if billing == "CA" else "US")
    amend_start: datetime | None = None
    if start_date is not None:
        amend_start = datetime(
            start_date.year,
            start_date.month,
            start_date.day,
            12,
            0,
            0,
            tzinfo=timezone.utc,
        )

    owned_assets = _owned_assets_detail(session, account_id)
    headcount_assets = [a for a in owned_assets if not a["isFlat"] and a.get("quantity")]
    today_qty = 0
    if headcount_assets:
        today_qty = int(headcount_assets[0]["quantity"] or 0)
    elif current_qty is not None:
        today_qty = int(current_qty)

    # Connect amend quantityChange is vs ASP on amendmentStartDate — not today.
    sample_ids = [a["id"] for a in headcount_assets]
    if sample_ids:
        amend_start = resolve_amend_start(session, sample_ids, amend_start)
    baseline_qty = today_qty
    if sample_ids and amend_start is not None:
        try:
            baseline_qty = int(
                asset_quantity_at(session, sample_ids[0], as_of=amend_start)
            )
        except Exception:
            baseline_qty = today_qty

    if current_qty is None:
        current_qty = baseline_qty
    target_qty = int(new_qty) if new_qty is not None else int(baseline_qty)

    owned_skus = {a["sku"] for a in owned_assets}
    add_skus = [s for s in addon_skus if s not in owned_skus]
    for s in addon_skus:
        if s in owned_skus:
            warnings.append(f"{s} already owned — skipped.")
    if country in NON_US_COUNTRIES:
        blocked = [s for s in add_skus if s in US_ONLY_ADDONS]
        if blocked:
            return {
                "ok": False,
                "error": f"US-only add-ons not available in {country}: {', '.join(blocked)}",
                "warnings": warnings,
            }

    qty_changing = new_qty is not None and int(new_qty) != int(baseline_qty)
    if not qty_changing and not add_skus:
        return {
            "ok": False,
            "error": "Change employee count and/or select a module to preview.",
            "warnings": warnings,
        }

    # --- Recurring today: Salesforce CurrentMrr / ASP (not catalog re-price) ---
    before_lines: list[dict[str, Any]] = []
    for a in owned_assets:
        if a.get("quantity") is None and not a["isFlat"]:
            continue
        mrr = a.get("mrr")
        if mrr is not None:
            hc = 1 if a["isFlat"] else int(a.get("quantity") or today_qty or 0)
            before_lines.append(
                {
                    "sku": a["sku"],
                    "name": a["name"],
                    "qty": hc,
                    "netPepm": (
                        round(float(mrr) / hc, 6) if hc and not a["isFlat"] else None
                    ),
                    "listPepm": None,
                    "monthly": round(float(mrr), 2),
                    "isFlat": bool(a["isFlat"]),
                    "isPepm": not bool(a["isFlat"]),
                    "isNew": False,
                    "source": "salesforceCurrentMrr",
                }
            )
            continue
        # Fallback only when org has no CurrentMrr/ASP.Mrr yet
        hc = 1 if a["isFlat"] else int(today_qty or baseline_qty)
        line = _line_monthly_from_schedule(
            session,
            sku=a["sku"],
            name=a["name"],
            headcount=hc,
            currency=currency,
            is_flat=bool(a["isFlat"]),
        )
        if line:
            line["isNew"] = False
            before_lines.append(line)
    monthly_before = round(sum(l["monthly"] for l in before_lines), 2)

    # --- Draft qty amend quotes (RC) ---
    amend_drafts: list[dict[str, Any]] = []
    net_from_quote: dict[str, float] = {}
    due_parts: list[dict[str, Any]] = []
    amend_start_iso: str | None = (
        amend_start.date().isoformat() if amend_start is not None else None
    )
    qty_preview_sticky = False
    module_quote_id: str | None = None
    module_snapshot: dict[str, Any] | None = None
    with _account_lock(account_id):
        if qty_changing:
            if not asset_id and headcount_assets:
                asset_id = headcount_assets[0]["id"]
            created = create_qty_amend_drafts(
                session,
                account_id=account_id,
                asset_id=asset_id,
                new_qty=target_qty,
                start=amend_start,
                preferred_drafts=preferred_amend_quotes,
            )
            warnings.extend(created.get("warnings") or [])
            qty_preview_sticky = bool(created.get("sticky"))
            if created.get("amendStartDate"):
                amend_start_iso = str(created["amendStartDate"])
            if not created.get("ok"):
                return {
                    "ok": False,
                    "error": created.get("error") or "Amend preview failed",
                    "warnings": warnings,
                    "amendStartDate": amend_start_iso,
                }
            for d in created.get("drafts") or []:
                snap = d.get("snapshot") or {}
                amend_drafts.append(
                    {
                        "quoteId": d.get("quoteId"),
                        "assetIds": d.get("assetIds") or [],
                        "quantityChange": d.get("quantityChange"),
                        "skus": d.get("skus") or [],
                        "opportunityId": d.get("opportunityId")
                        or created.get("opportunityId"),
                        "quoteNumber": snap.get("quoteNumber"),
                        "totalPrice": snap.get("totalPrice"),
                        "sticky": bool(d.get("sticky")),
                    }
                )
                due_parts.append(
                    {
                        "kind": "qtyAmend",
                        "quoteId": d.get("quoteId"),
                        "quoteNumber": snap.get("quoteNumber"),
                        "totalPrice": float(snap.get("totalPrice") or 0),
                    }
                )
                for ql in snap.get("lines") or []:
                    sku = (ql.get("sku") or "").upper()
                    # Amend delta lines often have NetUnitPrice=0 (LastTransaction);
                    # skip so recurring-after falls back to the volume schedule.
                    net = float(ql.get("netUnitPrice") or 0)
                    if sku and _is_headcount_sku(sku) and net > 0:
                        net_from_quote[sku] = net

        # --- Draft add-module quote (RC) ---
        if add_skus:
            try:
                # _place_addon_quote already System-reprices + volume stamps.
                module_quote_id = _place_addon_quote(
                    session,
                    account_id=account_id,
                    addon_skus=add_skus,
                    quantity=target_qty,
                    currency=currency,
                    preferred_quote_id=preferred_module_quote_id,
                )
                sync_quote_to_opportunity(session, module_quote_id)
                module_snapshot = _quote_pricing_snapshot(session, module_quote_id)
                due_parts.append(
                    {
                        "kind": "moduleSale",
                        "quoteId": module_quote_id,
                        "quoteNumber": module_snapshot.get("quoteNumber"),
                        "totalPrice": float(module_snapshot.get("totalPrice") or 0),
                    }
                )
                for ql in module_snapshot.get("lines") or []:
                    sku = (ql.get("sku") or "").upper()
                    net = float(ql.get("netUnitPrice") or 0)
                    if sku and _is_headcount_sku(sku) and net > 0:
                        net_from_quote[sku] = net
            except Exception as exc:  # noqa: BLE001
                return {
                    "ok": False,
                    "error": f"Add-module preview failed: {exc}",
                    "warnings": warnings,
                    "amendQuotes": amend_drafts,
                }

    # --- Recurring after: prefer NetUnitPrice from priced quotes ---
    after_lines: list[dict[str, Any]] = []
    for a in owned_assets:
        if a["isFlat"]:
            line = _line_monthly_from_schedule(
                session,
                sku=a["sku"],
                name=a["name"],
                headcount=1,
                currency=currency,
                is_flat=True,
            )
        elif a["sku"] in net_from_quote and net_from_quote[a["sku"]] > 0:
            net = net_from_quote[a["sku"]]
            line = {
                "sku": a["sku"],
                "name": a["name"],
                "qty": target_qty,
                "netPepm": net,
                "monthly": round(net * target_qty, 2),
                "isFlat": False,
                "isPepm": True,
                "isNew": False,
                "source": "amendQuote",
            }
        else:
            line = _line_monthly_from_schedule(
                session,
                sku=a["sku"],
                name=a["name"],
                headcount=target_qty,
                currency=currency,
                is_flat=False,
            )
            if line:
                line["isNew"] = False
        if line:
            after_lines.append(line)

    for sku in add_skus:
        if sku in net_from_quote:
            net = net_from_quote[sku]
            after_lines.append(
                {
                    "sku": sku,
                    "name": ADDON_LABELS.get(sku, sku),
                    "qty": target_qty,
                    "netPepm": net,
                    "monthly": round(net * target_qty, 2),
                    "isFlat": False,
                    "isPepm": True,
                    "isNew": True,
                    "source": "moduleQuote",
                }
            )
        else:
            line = _line_monthly_from_schedule(
                session,
                sku=sku,
                name=ADDON_LABELS.get(sku, sku),
                headcount=target_qty,
                currency=currency,
                is_flat=False,
            )
            if line:
                line["isNew"] = True
                after_lines.append(line)

    monthly_after = round(sum(l["monthly"] for l in after_lines), 2)
    monthly_diff = round(monthly_after - monthly_before, 2)
    annual_before = round(monthly_before * 12, 2)
    annual_after = round(monthly_after * 12, 2)
    annual_diff = round(annual_after - annual_before, 2)
    due_today = round(
        sum(float(p.get("totalPrice") or 0) for p in due_parts),
        2,
    )
    for part in due_parts:
        part["totalPrice"] = round(float(part.get("totalPrice") or 0), 2)
    for draft in amend_drafts:
        if draft.get("totalPrice") is not None:
            draft["totalPrice"] = round(float(draft["totalPrice"]), 2)

    opportunity_id = None
    for d in amend_drafts:
        if d.get("opportunityId"):
            opportunity_id = d["opportunityId"]
            break
    if not opportunity_id and module_quote_id:
        opportunity_id = quote_related_ids(session, module_quote_id).get(
            "opportunityId"
        )

    return {
        "ok": True,
        "accountId": account_id,
        "accountName": acct.get("Name"),
        "currency": currency,
        "currentQty": int(today_qty),
        "baselineQty": int(baseline_qty),
        "quantityChange": (
            int(target_qty) - int(baseline_qty) if qty_changing else 0
        ),
        "newQty": target_qty,
        "amendStartDate": amend_start_iso,
        "opportunityId": opportunity_id,
        "pricingSource": "revenueCloud",
        "monthly": {
            "today": monthly_before,
            "after": monthly_after,
            "difference": monthly_diff,
        },
        "annual": {
            "today": annual_before,
            "after": annual_after,
            "difference": annual_diff,
        },
        "dueToday": due_today,
        "dueParts": due_parts,
        "lines": after_lines,
        "linesToday": before_lines,
        "amendQuotes": amend_drafts,
        "sticky": bool(
            qty_preview_sticky or any(d.get("sticky") for d in amend_drafts)
        ),
        "moduleQuoteId": module_quote_id,
        "moduleQuote": (
            {
                "quoteId": module_quote_id,
                "quoteNumber": (module_snapshot or {}).get("quoteNumber"),
                "totalPrice": (module_snapshot or {}).get("totalPrice"),
            }
            if module_quote_id
            else None
        ),
        "warnings": warnings,
        "note": (
            "Totals from Revenue Cloud amendment/add-on Quotes after System "
            "reprice (amend volume aligned to live Price Adjustment Tiers). "
            "Qty delta is vs seats in effect on amend start (AssetStatePeriod), "
            "matching Connect amend / Managed Asset viewer. "
            "Charged today is the Quote TotalPrice sum."
        ),
    }


def place_account_changes(
    session: OrgSession,
    *,
    account_id: str,
    asset_id: str | None = None,
    new_qty: int | None = None,
    addon_skus: list[str] | None = None,
    start_date: date | None = None,
    amend_quotes: list[dict[str, Any]] | None = None,
    module_quote_id: str | None = None,
) -> AccountChangeResult:
    """Apply qty amend and/or add-module sale for an Account.

    When ``amend_quotes`` / ``module_quote_id`` from a prior preview are passed,
    activates those Quotes instead of creating new ones.
    """
    warnings: list[str] = []
    addon_skus = [s.upper() for s in (addon_skus or []) if s]
    acct = resolve_account_id(session, account_id=account_id)
    currency = acct.get("CurrencyIsoCode") or "USD"
    billing = (acct.get("BillingCountry") or "US").upper()
    country = "UK" if billing in ("GB", "UK") else ("CA" if billing == "CA" else "US")
    amend_start: datetime | None = None
    if start_date is not None:
        # Org timezone can treat "today 00:00Z" as past — keep midday UTC.
        amend_start = datetime(
            start_date.year,
            start_date.month,
            start_date.day,
            12,
            0,
            0,
            tzinfo=timezone.utc,
        )

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
    reuse_amends = [
        d
        for d in (amend_quotes or [])
        if d.get("quoteId") and d.get("assetIds")
    ]
    if reuse_amends and new_qty is not None:
        qty_result = activate_qty_amend_drafts(
            session,
            account_id=account_id,
            new_qty=int(new_qty),
            drafts=reuse_amends,
            primary_asset_id=asset_id,
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
    elif new_qty is not None:
        headcount = list_headcount_assets(session, account_id)
        if not asset_id and headcount:
            asset_id = headcount[0]["id"]
        if not asset_id and not headcount:
            return AccountChangeResult(
                ok=False,
                account_id=account_id,
                error="No per-employee assets found to amend",
                warnings=warnings,
            )
        # Skip only when every headcount asset is already at target *on start date*
        # (ASP basis — same as Connect amend quantityChange).
        as_of = amend_start or datetime.now(timezone.utc)
        all_at_target = bool(headcount) and all(
            abs(
                float(asset_quantity_at(session, a["id"], as_of=as_of))
                - float(new_qty)
            )
            < 1e-6
            for a in headcount
        )
        if all_at_target:
            warnings.append("Quantity unchanged — skipped qty amend.")
        else:
            qty_result = place_qty_amend(
                session,
                account_id=account_id,
                asset_id=asset_id,
                new_qty=int(new_qty),
                start=amend_start,
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
    if module_quote_id and add_skus:
        try:
            co = checkout_quote(session, module_quote_id, poll_timeout=180)
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
    elif add_skus:
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

    confirmation = build_change_confirmation(
        session,
        account_id=account_id,
        account_name=str(acct.get("Name") or account_id),
        qty_amend=qty_payload,
        module_sale=module_payload,
        added_skus=add_skus,
    )

    # Pay Now for activated orders (module sale first, then qty amend).
    payment: dict[str, Any] | None = None
    order_ids: list[str] = []
    if module_payload and module_payload.get("ok") and module_payload.get("orderId"):
        order_ids.append(str(module_payload["orderId"]))
    if qty_payload and qty_payload.get("ok") and qty_payload.get("amendOrderId"):
        oid = str(qty_payload["amendOrderId"])
        if oid not in order_ids:
            order_ids.append(oid)
    if order_ids:
        from payments import build_payment_prompt

        for oid in order_ids:
            try:
                prompt = build_payment_prompt(
                    session, oid, collect=True, poll_timeout=90
                )
                payment = prompt.as_dict()
                if prompt.blocked_reason:
                    warnings.append(f"Payment: {prompt.blocked_reason}")
                warnings.extend(prompt.warnings or [])
                if prompt.ready or (
                    prompt.invoice_balance is not None and prompt.invoice_balance <= 0
                ):
                    break
            except Exception as pay_exc:  # noqa: BLE001
                warnings.append(f"Payment prompt failed: {pay_exc}")
                if payment is None:
                    payment = {
                        "ready": False,
                        "orderId": oid,
                        "blockedReason": str(pay_exc),
                    }

    return AccountChangeResult(
        ok=True,
        account_id=account_id,
        account_name=str(acct.get("Name") or ""),
        qty_amend=qty_payload,
        module_sale=module_payload,
        added_skus=add_skus,
        warnings=warnings,
        confirmation=confirmation,
        payment=payment,
    )
