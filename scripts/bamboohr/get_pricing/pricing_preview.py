"""Sticky Get Pricing Draft Quote + System reprice (native configurator preview).

One Draft Quote per browser session (tagged ``[bamboohr-preview] get-pricing``).
Plan / headcount / add-on changes replace lines and System-reprice in place.
"""

from __future__ import annotations

import threading
import uuid
from datetime import date, timedelta
from typing import Any

from service import (
    ADDON_LABELS,
    ADDON_LIST_USD,
    API,
    BuyerInfo,
    CORE_FLAT_SKU,
    COUNTRY_ACCOUNT,
    COUNTRY_CURRENCY,
    NON_US_COUNTRIES,
    OrgSession,
    PLAN_LABELS,
    PLAN_LIST,
    PLAN_LIST_USD,
    TRIAL_DAYS,
    US_ONLY_ADDONS,
    _custom_price_quote,
    _pbe_for_sku,
    _soql_escape,
    _system_reprice_quote,
    addon_list_price,
    core_flat_price,
    expected_addon_net,
    expected_net,
    is_evergreen_term,
    line_item_dict,
    lightning_record_url,
    normalize_addons,
    plan_list_price,
    quote_line_term_fields,
    resolve_subscription_window,
    resolve_buyer_account,
    sync_quote_to_opportunity,
    uses_core_flat,
    volume_rate,
)

PREVIEW_MARKER = "[bamboohr-preview] get-pricing"

# Serialize preview mutations per Account so overlapping UI requests cannot
# DELETE each other's lines / create duplicate Opps+Quotes.
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


def _cfg_fingerprint(
    *,
    plan_sku: str,
    headcount: int,
    country: str,
    addon_skus: list[str],
    free_trial: bool,
) -> str:
    addons = ",".join(sorted(addon_skus))
    trial = "1" if free_trial else "0"
    return f"{plan_sku}|{headcount}|{country}|{addons}|trial={trial}"


def _description_for(cfg: str) -> str:
    return f"{PREVIEW_MARKER}\ncfg:{cfg}"


def _parse_cfg(description: str | None) -> str | None:
    for line in (description or "").splitlines():
        line = line.strip()
        if line.startswith("cfg:"):
            return line[4:].strip()
    return None


def _is_preview_quote(row: dict[str, Any]) -> bool:
    desc = row.get("Description") or ""
    return PREVIEW_MARKER in desc or "[bamboohr-preview]" in desc


def load_sticky_preview_quote(
    session: OrgSession, quote_id: str | None
) -> dict[str, Any] | None:
    """Return Draft preview Quote row or None if missing / not reusable."""
    qid = (quote_id or "").strip()
    if not qid:
        return None
    rows = session.soql(
        "SELECT Id, Name, Status, Description, QuoteAccountId, AccountId, "
        "OpportunityId, CurrencyIsoCode, QuoteNumber, "
        "RLM_Bamboo_FreeTrial__c, RLM_Bamboo_PathB_BundleSave__c "
        f"FROM Quote WHERE Id = '{_soql_escape(qid)}' LIMIT 1"
    )
    if not rows:
        return None
    row = rows[0]
    if (row.get("Status") or "") != "Draft":
        return None
    if not _is_preview_quote(row):
        return None
    return row


def find_sticky_preview_on_account(
    session: OrgSession,
    account_id: str,
    *,
    currency: str | None = None,
    keep_quote_id: str | None = None,
) -> dict[str, Any] | None:
    """Return the Account's single Draft preview Quote; discard extras.

    Server-side sticky — wins races when the browser fires overlapping previews
    without a quoteId yet.
    """
    if not account_id:
        return None
    rows = session.soql(
        "SELECT Id, Name, Status, Description, QuoteAccountId, AccountId, "
        "OpportunityId, CurrencyIsoCode, QuoteNumber, CreatedDate, "
        "RLM_Bamboo_FreeTrial__c, RLM_Bamboo_PathB_BundleSave__c "
        "FROM Quote WHERE Status = 'Draft' "
        f"AND (QuoteAccountId = '{_soql_escape(account_id)}' "
        f"OR AccountId = '{_soql_escape(account_id)}') "
        "ORDER BY CreatedDate DESC LIMIT 25"
    )
    previews = [r for r in rows if _is_preview_quote(r)]
    if currency:
        previews = [
            r
            for r in previews
            if (r.get("CurrencyIsoCode") or currency) == currency
        ]
    if not previews:
        return None
    keeper = None
    if keep_quote_id:
        keeper = next((r for r in previews if r["Id"] == keep_quote_id), None)
    if keeper is None:
        keeper = previews[0]
    for extra in previews:
        if extra["Id"] != keeper["Id"]:
            discard_preview_quote(session, extra["Id"])
    return keeper


def _opp_has_other_quotes(
    session: OrgSession, opportunity_id: str, exclude_quote_id: str | None = None
) -> bool:
    if not opportunity_id:
        return False
    rows = session.soql(
        "SELECT Id FROM Quote "
        f"WHERE OpportunityId = '{_soql_escape(opportunity_id)}' LIMIT 10"
    )
    for row in rows:
        if exclude_quote_id and row["Id"] == exclude_quote_id:
            continue
        return True
    return False


def discard_preview_quote(session: OrgSession, quote_id: str | None) -> bool:
    """Delete a sticky preview Quote and its orphan Get Pricing Opportunity.

    Never deletes a normal Get Pricing / SelfServe Draft — those Ids are reused
    in place by ``get_pricing``, not discarded.
    """
    qid = (quote_id or "").strip()
    if not qid:
        return False
    rows: list[dict[str, Any]] = []
    try:
        rows = session.soql(
            "SELECT Id, OpportunityId, Name, Description FROM Quote "
            f"WHERE Id = '{_soql_escape(qid)}' LIMIT 1"
        )
    except Exception:
        return False
    if not rows or not _is_preview_quote(rows[0]):
        return False
    opp_id = rows[0].get("OpportunityId")
    try:
        session.delete("Quote", qid)
        deleted = True
    except Exception:
        try:
            session.patch("Quote", qid, {"Status": "Denied"})
            deleted = True
        except Exception:
            return False
    if deleted and opp_id and not _opp_has_other_quotes(session, opp_id, qid):
        try:
            session.delete("Opportunity", opp_id)
        except Exception:
            try:
                session.patch(
                    "Opportunity",
                    opp_id,
                    {"StageName": "Closed Lost", "Name": "Get Pricing (discarded)"},
                )
            except Exception:
                pass
    return deleted


def ensure_preview_opportunity(
    session: OrgSession,
    *,
    account_id: str,
    currency: str,
    preferred_opp_id: str | None = None,
) -> str:
    """One Prospecting Get Pricing Opp per Account (reuse across cart edits)."""
    if preferred_opp_id:
        rows = session.soql(
            "SELECT Id, StageName FROM Opportunity "
            f"WHERE Id = '{_soql_escape(preferred_opp_id)}' LIMIT 1"
        )
        if rows and (rows[0].get("StageName") or "") == "Prospecting":
            return preferred_opp_id

    rows = session.soql(
        "SELECT Id, Name, StageName FROM Opportunity "
        f"WHERE AccountId = '{_soql_escape(account_id)}' "
        "AND StageName = 'Prospecting' "
        "AND (Name LIKE 'Get Pricing%' OR Name LIKE 'Get Pricing preview%') "
        "ORDER BY CreatedDate DESC LIMIT 15"
    )
    if rows:
        keeper = rows[0]["Id"]
        for extra in rows[1:]:
            # Only remove empty preview Opps (no quotes).
            if not _opp_has_other_quotes(session, extra["Id"]):
                try:
                    session.delete("Opportunity", extra["Id"])
                except Exception:
                    pass
        return keeper

    pb = session.soql("SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1")[0]
    return session.create(
        "Opportunity",
        {
            "Name": "Get Pricing",
            "AccountId": account_id,
            "StageName": "Prospecting",
            "CloseDate": "2026-12-31",
            "Pricebook2Id": pb["Id"],
            "CurrencyIsoCode": currency,
        },
    )


def collapse_preview_opportunities(
    session: OrgSession, account_id: str, *, keep_opp_id: str | None = None
) -> int:
    """Remove empty Prospecting Get Pricing Opps; keep at most one."""
    rows = session.soql(
        "SELECT Id FROM Opportunity "
        f"WHERE AccountId = '{_soql_escape(account_id)}' "
        "AND StageName = 'Prospecting' "
        "AND (Name LIKE 'Get Pricing%' OR Name LIKE 'Get Pricing preview%') "
        "ORDER BY CreatedDate DESC LIMIT 25"
    )
    removed = 0
    kept = keep_opp_id
    for row in rows:
        oid = row["Id"]
        if kept and oid == kept:
            continue
        if _opp_has_other_quotes(session, oid):
            if not kept:
                kept = oid
            continue
        try:
            session.delete("Opportunity", oid)
            removed += 1
        except Exception:
            continue
    return removed


def _quote_line_rows(session: OrgSession, quote_id: str) -> list[dict[str, Any]]:
    return session.soql(
        "SELECT Id, Product2.StockKeepingUnit FROM QuoteLineItem "
        f"WHERE QuoteId = '{_soql_escape(quote_id)}'"
    )


def _quote_line_skus(session: OrgSession, quote_id: str) -> list[str]:
    out: list[str] = []
    for row in _quote_line_rows(session, quote_id):
        sku = ((row.get("Product2") or {}).get("StockKeepingUnit") or "").upper()
        if sku:
            out.append(sku)
    return out


def _quote_name(plan_sku: str, addon_skus: list[str], free_trial: bool) -> str:
    if free_trial:
        return f"{TRIAL_DAYS}-day trial — {PLAN_LABELS[plan_sku]}" + (
            f" + {len(addon_skus)} add-on(s)" if addon_skus else ""
        )
    return f"Get Pricing — {PLAN_LABELS[plan_sku]}" + (
        f" + {len(addon_skus)} add-on(s)" if addon_skus else ""
    )


def _replace_sticky_lines_via_pst(
    session: OrgSession,
    *,
    quote_id: str,
    quote_name: str,
    cfg: str,
    skus_needed: list[str],
    pbes: dict[str, dict[str, Any]],
    sell_plan_sku: str,
    plan_qty: int,
    headcount: int,
    start: str,
    end: str | None,
    stamp_preview_description: bool = True,
) -> None:
    """Best-practice cart update: DELETE old QLIs + POST new ones in one place graph.

    Matches Salesforce Place Quote / PST examples (method DELETE on QuoteLineItem).
    Pass ``stamp_preview_description=False`` when updating a real SelfServe Draft
    so the Quote is not tagged as a sticky preview.
    """
    existing = _quote_line_rows(session, quote_id)
    quote_record: dict[str, Any] = {
        "attributes": {
            "method": "PATCH",
            "type": "Quote",
            "id": quote_id,
        },
        "Name": quote_name,
        "StartDate": start,
    }
    if stamp_preview_description:
        quote_record["Description"] = _description_for(cfg)
    records: list[dict[str, Any]] = [
        {
            "referenceId": "refQuote",
            "record": quote_record,
        }
    ]
    for i, row in enumerate(existing):
        records.append(
            {
                "referenceId": f"refDel{i}",
                "record": {
                    "attributes": {
                        "type": "QuoteLineItem",
                        "method": "DELETE",
                        "id": row["Id"],
                    }
                },
            }
        )
    for i, sku in enumerate(skus_needed):
        pbe = pbes[sku]
        line_qty = plan_qty if sku == sell_plan_sku else headcount
        records.append(
            {
                "referenceId": f"refL{i}",
                "record": {
                    "attributes": {
                        "type": "QuoteLineItem",
                        "method": "POST",
                    },
                    "QuoteId": quote_id,
                    "Product2Id": pbe["Product2Id"],
                    "PricebookEntryId": pbe["Id"],
                    "Quantity": str(line_qty),
                    **quote_line_term_fields(start, end),
                },
            }
        )

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
                "graphId": f"gprpl{uuid.uuid4().hex[:8]}",
                "records": records,
            },
        },
    )
    if isinstance(placed, list):
        placed = placed[0]
    if not placed.get("isSuccess"):
        raise RuntimeError(f"PST line replace failed: {placed}")

    after = _quote_line_skus(session, quote_id)
    if len(after) != len(set(after)):
        raise RuntimeError(
            f"PST line replace left duplicate SKUs on {quote_id}: {after}"
        )
    if sorted(after) != sorted(skus_needed):
        raise RuntimeError(
            f"PST line replace SKU mismatch on {quote_id}: got {after}, "
            f"expected {skus_needed}"
        )


def _create_sticky_quote(
    session: OrgSession,
    *,
    acct: dict[str, Any],
    currency: str,
    plan_sku: str,
    addon_skus: list[str],
    headcount: int,
    country: str,
    free_trial: bool,
    sell_plan_sku: str,
    plan_qty: int,
    skus_needed: list[str],
    pbes: dict[str, dict[str, Any]],
    cfg: str,
    opportunity_id: str | None = None,
    start_iso: str | None = None,
    end_iso: str | None = None,
) -> tuple[str, str]:
    """Create the Account's sticky Draft Quote on one reused Opportunity.

    Returns ``(quote_id, opportunity_id)``.
    """
    pb = session.soql("SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1")[0]
    opp_id = ensure_preview_opportunity(
        session,
        account_id=acct["Id"],
        currency=currency,
        preferred_opp_id=opportunity_id,
    )
    try:
        session.patch(
            "Opportunity",
            opp_id,
            {
                "Name": (
                    f"Get Pricing — {PLAN_LABELS.get(plan_sku, plan_sku)}"
                    + (f" + {len(addon_skus)} add-on(s)" if addon_skus else "")
                )[:120],
            },
        )
    except Exception:
        pass
    start = start_iso or date.today().isoformat()
    end = end_iso
    if free_trial and not end:
        end = (date.today() + timedelta(days=TRIAL_DAYS)).isoformat()
    quote_name = _quote_name(plan_sku, addon_skus, free_trial)
    records: list[dict[str, Any]] = [
        {
            "referenceId": "refQuote",
            "record": {
                "attributes": {"method": "POST", "type": "Quote"},
                "Name": quote_name,
                "OpportunityId": opp_id,
                "Pricebook2Id": pb["Id"],
                "QuoteAccountId": acct["Id"],
                "CurrencyIsoCode": currency,
                "Description": _description_for(cfg),
                "StartDate": start,
            },
        }
    ]
    for i, sku in enumerate(skus_needed):
        pbe = pbes[sku]
        line_qty = plan_qty if sku == sell_plan_sku else headcount
        records.append(
            {
                "referenceId": f"refL{i}",
                "record": {
                    "attributes": {
                        "type": "QuoteLineItem",
                        "method": "POST",
                    },
                    "QuoteId": "@{refQuote.id}",
                    "Product2Id": pbe["Product2Id"],
                    "PricebookEntryId": pbe["Id"],
                    "Quantity": str(line_qty),
                    **quote_line_term_fields(start, end),
                },
            }
        )
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
                "graphId": f"gpn{uuid.uuid4().hex[:8]}",
                "records": records,
            },
        },
    )
    if isinstance(placed, list):
        placed = placed[0]
    if not placed.get("isSuccess"):
        raise RuntimeError(f"Preview create quote failed: {placed}")
    quote_id = placed["salesTransactionId"]
    # Ensure marker + cfg even if Description was dropped on place.
    session.patch("Quote", quote_id, {"Description": _description_for(cfg)})
    # Mirror amend hygiene marker so discard helpers recognize the Draft.
    try:
        rows = session.soql(
            f"SELECT Description FROM Quote WHERE Id = '{_soql_escape(quote_id)}' LIMIT 1"
        )
        desc = ((rows[0].get("Description") if rows else None) or "").strip()
        if "[bamboohr-preview]" not in desc:
            session.patch(
                "Quote",
                quote_id,
                {"Description": (desc + "\n[bamboohr-preview]").strip()},
            )
    except Exception:
        pass
    return quote_id, opp_id


def _read_priced_lines(
    session: OrgSession,
    *,
    quote_id: str,
    headcount: int,
    currency: str,
    use_flat: bool,
    path_b: bool,
    vol_pct: float,
    flat_list: float,
    sell_plan_sku: str,
) -> tuple[list[dict[str, Any]], float, float]:
    priced_lines = session.soql(
        "SELECT Id, Quantity, UnitPrice, NetUnitPrice, TotalPrice, "
        "Product2.StockKeepingUnit, Product2.Name "
        f"FROM QuoteLineItem WHERE QuoteId = '{_soql_escape(quote_id)}'"
    )
    line_items: list[dict[str, Any]] = []
    monthly = 0.0
    net_pepm = 0.0
    for pl in priced_lines:
        sku = (pl.get("Product2") or {}).get("StockKeepingUnit") or ""
        name = (pl.get("Product2") or {}).get("Name") or sku
        qty = float(pl.get("Quantity") or headcount)
        net = float(pl.get("NetUnitPrice") or pl.get("UnitPrice") or 0)
        line_total = round(net * qty, 2)
        monthly += line_total
        if sku == CORE_FLAT_SKU:
            list_unit = flat_list
        elif sku in PLAN_LIST_USD:
            list_unit = plan_list_price(sku, currency)
        elif sku in ADDON_LIST_USD:
            list_unit = addon_list_price(sku, currency)
        else:
            list_unit = None
        is_plan_line = sku in PLAN_LIST or sku == CORE_FLAT_SKU
        line_vol = 0.0 if (is_plan_line and use_flat) else vol_pct
        line_items.append(
            line_item_dict(
                sku=sku,
                name=name,
                quantity=int(qty),
                list_pepm=list_unit,
                net_pepm=net,
                monthly=line_total,
                is_plan=is_plan_line,
                path_b=path_b,
                volume_percent=line_vol,
            )
        )
        if sku == sell_plan_sku:
            net_pepm = net
    return line_items, round(monthly, 2), float(net_pepm)


def preview_get_pricing(
    session: OrgSession,
    *,
    headcount: int,
    country: str,
    plan_sku: str = "BAMBOO-PRO",
    addon_skus: list[str] | None = None,
    free_trial: bool = False,
    quote_id: str | None = None,
    buyer: BuyerInfo | None = None,
    account_id: str | None = None,
    start_date: date | None = None,
    term_months: int | None = None,
) -> dict[str, Any]:
    """Create or refresh one sticky Draft Quote; return System-reprice totals."""
    warnings: list[str] = []
    country = (country or "US").upper().strip()
    if country not in COUNTRY_ACCOUNT:
        return {"ok": False, "error": f"Unsupported country {country!r}"}
    currency = COUNTRY_CURRENCY[country]
    plan_sku = (plan_sku or "BAMBOO-PRO").upper()
    if plan_sku not in PLAN_LIST:
        return {"ok": False, "error": f"Unsupported plan {plan_sku!r}"}
    if headcount < 1 or headcount > 100000:
        return {"ok": False, "error": "headcount must be between 1 and 100000"}

    try:
        start_day, end_day, months = resolve_subscription_window(
            start_date=start_date,
            term_months=term_months,
            free_trial=bool(free_trial),
        )
    except ValueError as exc:
        return {"ok": False, "error": str(exc)}
    start_iso = start_day.isoformat()
    end_iso = end_day.isoformat() if end_day else None
    evergreen = is_evergreen_term(months, free_trial=bool(free_trial))
    pbe_smt = "Evergreen" if evergreen else "TermDefined"

    try:
        addon_skus = normalize_addons(addon_skus)
    except ValueError as exc:
        return {"ok": False, "error": str(exc)}

    if country in NON_US_COUNTRIES:
        blocked = [s for s in addon_skus if s in US_ONLY_ADDONS]
        if blocked:
            warnings.append(
                f"Removed US-only add-ons for {country}: "
                + ", ".join(ADDON_LABELS[s] for s in blocked)
            )
            addon_skus = [s for s in addon_skus if s not in US_ONLY_ADDONS]

    path_b = (
        "BAMBOO-ADD-PAYROLL" in addon_skus and "BAMBOO-ADD-BENEFITS" in addon_skus
    )
    use_flat = uses_core_flat(plan_sku, headcount)
    sell_plan_sku = CORE_FLAT_SKU if use_flat else plan_sku
    plan_qty = 1 if use_flat else headcount
    flat_list = core_flat_price(currency)
    vol = 0.0 if use_flat else volume_rate(headcount)
    vol_pct = round(vol * 100, 1)
    cfg = _cfg_fingerprint(
        plan_sku=plan_sku,
        headcount=headcount,
        country=country,
        addon_skus=addon_skus,
        free_trial=free_trial,
    )

    acct, contact_id, buyer_meta = resolve_buyer_account(
        session,
        country,
        buyer,
        currency=currency,
        account_id=account_id,
    )
    if buyer_meta.get("usedDemoAccount"):
        warnings.append(
            "Preview on seeded demo Account — submit Get Pricing with company + "
            "email to attach the final Quote to your customer Account."
        )

    skus_needed = [sell_plan_sku, *addon_skus]
    pbes = {
        sku: _pbe_for_sku(session, sku, currency, selling_model_type=pbe_smt)
        for sku in skus_needed
    }
    if evergreen:
        warnings.append(
            "Month-to-month preview: Evergreen Monthly (no commitment end date)."
        )

    with _account_lock(acct["Id"]):

        # Prefer client quoteId, else the Account's existing Draft preview (race-safe).
        sticky = load_sticky_preview_quote(session, quote_id)
        if not sticky:
            sticky = find_sticky_preview_on_account(
                session, acct["Id"], currency=currency
            )
        elif not quote_id:
            # Client had no id — collapse extras once. When quoteId is known,
            # skip the extra SOQL/delete pass on every keystroke.
            find_sticky_preview_on_account(
                session,
                acct["Id"],
                currency=currency,
                keep_quote_id=sticky["Id"],
            )

        prior_cfg = _parse_cfg(sticky.get("Description")) if sticky else None
        can_reuse = False
        lines_replaced = False
        qty_only_update = False
        today = start_iso
        end = end_iso
        q_name = _quote_name(plan_sku, addon_skus, free_trial)
        preferred_opp_id = (sticky or {}).get("OpportunityId")

        if sticky:
            sticky_currency = sticky.get("CurrencyIsoCode") or currency
            sticky_account = sticky.get("QuoteAccountId") or sticky.get("AccountId")
            if sticky_currency != currency or sticky_account != acct["Id"]:
                discard_preview_quote(session, sticky["Id"])
                sticky = None
                prior_cfg = None
                preferred_opp_id = None
            else:
                existing = _quote_line_skus(session, sticky["Id"])
                healthy = len(existing) == len(set(existing)) and sorted(existing) == sorted(
                    skus_needed
                )
                if prior_cfg == cfg and healthy:
                    can_reuse = True
                elif healthy and sorted(existing) == sorted(skus_needed):
                    # Same products, new qty/trial/dates — one System place
                    # with Quantity patches (skip DELETE+POST Skip place).
                    try:
                        session.patch(
                            "Quote",
                            sticky["Id"],
                            {
                                "Description": _description_for(cfg),
                                "Name": q_name,
                                "RLM_Bamboo_FreeTrial__c": bool(free_trial),
                            },
                        )
                        qty_by_sku = {
                            sell_plan_sku: plan_qty,
                            **{sku: headcount for sku in addon_skus},
                        }
                        _system_reprice_quote(
                            session, sticky["Id"], quantity_by_sku=qty_by_sku
                        )
                        can_reuse = True
                        lines_replaced = True
                        qty_only_update = True
                    except Exception as exc:  # noqa: BLE001
                        warnings.append(
                            f"Qty System update failed — full line replace ({exc})."
                        )
                if not can_reuse and sticky:
                    try:
                        _replace_sticky_lines_via_pst(
                            session,
                            quote_id=sticky["Id"],
                            quote_name=q_name,
                            cfg=cfg,
                            skus_needed=skus_needed,
                            pbes=pbes,
                            sell_plan_sku=sell_plan_sku,
                            plan_qty=plan_qty,
                            headcount=headcount,
                            start=today,
                            end=end,
                        )
                        can_reuse = True
                        lines_replaced = True
                    except Exception as exc:  # noqa: BLE001
                        warnings.append(
                            f"PST line replace failed — recreating Draft Quote ({exc})."
                        )
                        preferred_opp_id = sticky.get("OpportunityId")
                        discard_preview_quote(session, sticky["Id"])
                        sticky = None
                        prior_cfg = None

        created_new = False
        opportunity_id_out: str | None = preferred_opp_id
        if can_reuse and sticky:
            quote_id_out = sticky["Id"]
            opportunity_id_out = sticky.get("OpportunityId") or preferred_opp_id
            if not lines_replaced:
                session.patch(
                    "Quote",
                    quote_id_out,
                    {"Description": _description_for(cfg), "Name": q_name},
                )
            if opportunity_id_out and (created_new or lines_replaced):
                try:
                    session.patch(
                        "Opportunity",
                        opportunity_id_out,
                        {"Name": q_name[:120]},
                    )
                except Exception:
                    pass
        else:
            quote_id_out, opportunity_id_out = _create_sticky_quote(
                session,
                acct=acct,
                currency=currency,
                plan_sku=plan_sku,
                addon_skus=addon_skus,
                headcount=headcount,
                country=country,
                free_trial=free_trial,
                sell_plan_sku=sell_plan_sku,
                plan_qty=plan_qty,
                skus_needed=skus_needed,
                pbes=pbes,
                cfg=cfg,
                opportunity_id=preferred_opp_id,
                start_iso=start_iso,
                end_iso=end_iso,
            )
            created_new = True

        # Hygiene only when creating / recovering — not every keystroke.
        if created_new or not quote_id:
            find_sticky_preview_on_account(
                session,
                acct["Id"],
                currency=currency,
                keep_quote_id=quote_id_out,
            )
            collapse_preview_opportunities(
                session, acct["Id"], keep_opp_id=opportunity_id_out
            )

        # Fast path: unchanged cart — return last System prices (no RC round-trip).
        if can_reuse and sticky and prior_cfg == cfg and not lines_replaced:
            list_pepm = flat_list if use_flat else plan_list_price(plan_sku, currency)
            # fall through to paid_line_items + _read_priced_lines below without reprice
            needs_reprice = False
        else:
            needs_reprice = not qty_only_update
            # Trial flag before System reprice (qty_only already System-priced).
            try:
                session.patch(
                    "Quote",
                    quote_id_out,
                    {"RLM_Bamboo_FreeTrial__c": bool(free_trial)},
                )
            except Exception:
                if free_trial:
                    warnings.append("Could not set free-trial flag before reprice.")

            if needs_reprice:
                _system_reprice_quote(session, quote_id_out)

        list_pepm = flat_list if use_flat else plan_list_price(plan_sku, currency)
        expected_plan_paid = (
            flat_list if use_flat else expected_net(plan_sku, headcount, currency)
        )
        paid_line_items: list[dict[str, Any]] = [
            line_item_dict(
                sku=sell_plan_sku,
                name=(
                    "BambooHR Core Small Business Flat"
                    if use_flat
                    else PLAN_LABELS[plan_sku]
                ),
                quantity=plan_qty,
                list_pepm=list_pepm,
                net_pepm=expected_plan_paid,
                monthly=round(expected_plan_paid * plan_qty, 2),
                is_plan=True,
                path_b=path_b,
                volume_percent=0.0 if use_flat else vol_pct,
            )
        ]
        paid_monthly = paid_line_items[0]["monthly"]
        for sku in addon_skus:
            addon_net = expected_addon_net(
                sku, path_b=path_b, currency=currency, headcount=headcount
            )
            addon_monthly = round(addon_net * headcount, 2)
            paid_monthly = round(paid_monthly + addon_monthly, 2)
            paid_line_items.append(
                line_item_dict(
                    sku=sku,
                    name=ADDON_LABELS[sku],
                    quantity=headcount,
                    list_pepm=addon_list_price(sku, currency),
                    net_pepm=addon_net,
                    monthly=addon_monthly,
                    is_plan=False,
                    path_b=path_b,
                    volume_percent=vol_pct,
                )
            )

        if currency != "USD" and not free_trial:
            by_sku = {
                li["sku"]: (
                    int(li["quantity"]),
                    float(li["listPepm"]),
                    float(li["netPepm"]),
                )
                for li in paid_line_items
            }
            try:
                _custom_price_quote(session, quote_id_out, by_sku)
                warnings.append(
                    f"Native {currency} line prices applied after System reprice."
                )
            except Exception as exc:  # noqa: BLE001
                warnings.append(f"Native currency Force reprice skipped: {exc}")

        # Same as Quote page Start Sync — only on create (preview ticks skip;
        # promote / place refresh Amount). Avoids ~1s per keystroke.
        if opportunity_id_out and created_new:
            sync_quote_to_opportunity(session, quote_id_out, opportunity_id_out)

        qrows = session.soql(
            "SELECT QuoteNumber, RLM_Bamboo_PathB_BundleSave__c, "
            "RLM_Bamboo_FreeTrial__c, Description "
            f"FROM Quote WHERE Id = '{_soql_escape(quote_id_out)}' LIMIT 1"
        )
        qrow = qrows[0] if qrows else {}
        path_b_flag = bool(qrow.get("RLM_Bamboo_PathB_BundleSave__c"))
        trial_flag = bool(qrow.get("RLM_Bamboo_FreeTrial__c"))

        line_items, monthly, net_pepm = _read_priced_lines(
            session,
            quote_id=quote_id_out,
            headcount=headcount,
            currency=currency,
            use_flat=use_flat,
            path_b=path_b,
            vol_pct=vol_pct,
            flat_list=flat_list,
            sell_plan_sku=sell_plan_sku,
        )
        if free_trial:
            net_pepm = 0.0

        base = (session._instance or "").rstrip("/")
        return {
            "ok": True,
            "pricingSource": "revenueCloud",
            "sticky": True,
            "createdNew": created_new,
            "linesReplaced": lines_replaced,
            "country": country,
            "currency": currency,
            "accountName": acct.get("Name") or COUNTRY_ACCOUNT[country],
            "accountId": acct["Id"],
            "accountCreated": bool(buyer_meta.get("accountCreated")),
            "contactId": contact_id,
            "contactName": str(buyer_meta.get("contactName") or ""),
            "contactEmail": str(buyer_meta.get("contactEmail") or ""),
            "usedDemoAccount": bool(buyer_meta.get("usedDemoAccount")),
            "planSku": plan_sku,
            "planName": PLAN_LABELS[plan_sku],
            "sellPlanSku": sell_plan_sku,
            "smallBizFlat": use_flat,
            "freeTrial": free_trial,
            "trialDays": TRIAL_DAYS if free_trial else 0,
            "headcount": headcount,
            "listPepm": list_pepm,
            "volumePercent": vol_pct,
            "netPepm": net_pepm,
            "monthlyTotal": monthly,
            "annualTotal": round(monthly * 12, 2),
            "addonSkus": addon_skus,
            "lineItems": line_items,
            "paidMonthlyEstimate": paid_monthly if free_trial else None,
            "paidLineItems": paid_line_items if free_trial else [],
            "pathBBundleSave": path_b_flag,
            "trialFlag": trial_flag,
            "warnings": warnings,
            "quoteId": quote_id_out,
            "opportunityId": opportunity_id_out,
            "quoteNumber": qrow.get("QuoteNumber"),
            "quoteUrl": lightning_record_url(base, "Quote", quote_id_out),
            "cfg": cfg,
            "orgAlias": session.alias,
        }


def promote_preview_quote(
    session: OrgSession,
    quote_id: str,
    *,
    headcount: int,
    country: str,
    plan_sku: str,
    addon_skus: list[str],
    free_trial: bool,
    account_id: str,
) -> dict[str, Any] | None:
    """If sticky Draft matches config + Account, untag and return snapshot.

    Returns None when the caller should create a fresh buyer Quote instead.
    """
    sticky = load_sticky_preview_quote(session, quote_id)
    if not sticky:
        return None
    sticky_account = sticky.get("QuoteAccountId") or sticky.get("AccountId")
    if sticky_account != account_id:
        return None
    cfg = _cfg_fingerprint(
        plan_sku=plan_sku,
        headcount=headcount,
        country=country,
        addon_skus=addon_skus,
        free_trial=free_trial,
    )
    if _parse_cfg(sticky.get("Description")) != cfg:
        return None

    # Promote: strip preview marker so hygiene won't delete it.
    desc = (sticky.get("Description") or "").strip()
    cleaned = "\n".join(
        line
        for line in desc.splitlines()
        if PREVIEW_MARKER not in line and "[bamboohr-preview]" not in line
    ).strip()
    name = (
        f"Get Pricing — {PLAN_LABELS.get(plan_sku, plan_sku)}"
        + (f" + {len(addon_skus)} add-on(s)" if addon_skus else "")
    )
    if free_trial:
        name = f"{TRIAL_DAYS}-day trial — {PLAN_LABELS.get(plan_sku, plan_sku)}" + (
            f" + {len(addon_skus)} add-on(s)" if addon_skus else ""
        )
    try:
        session.patch(
            "Quote",
            quote_id,
            {"Description": cleaned, "Name": name},
        )
    except Exception:
        session.patch("Quote", quote_id, {"Name": name})

    opp_id = sticky.get("OpportunityId")
    if opp_id:
        try:
            session.patch("Opportunity", opp_id, {"Name": name[:120]})
        except Exception:
            pass
        sync_quote_to_opportunity(session, quote_id, opp_id)
        collapse_preview_opportunities(
            session, account_id, keep_opp_id=opp_id
        )
    find_sticky_preview_on_account(
        session, account_id, keep_quote_id=quote_id
    )

    use_flat = uses_core_flat(plan_sku, headcount)
    sell_plan_sku = CORE_FLAT_SKU if use_flat else plan_sku
    currency = COUNTRY_CURRENCY[(country or "US").upper()]
    flat_list = core_flat_price(currency)
    vol_pct = 0.0 if use_flat else round(volume_rate(headcount) * 100, 1)
    path_b = (
        "BAMBOO-ADD-PAYROLL" in addon_skus and "BAMBOO-ADD-BENEFITS" in addon_skus
    )
    line_items, monthly, net_pepm = _read_priced_lines(
        session,
        quote_id=quote_id,
        headcount=headcount,
        currency=currency,
        use_flat=use_flat,
        path_b=path_b,
        vol_pct=vol_pct,
        flat_list=flat_list,
        sell_plan_sku=sell_plan_sku,
    )
    qrows = session.soql(
        "SELECT QuoteNumber, RLM_Bamboo_PathB_BundleSave__c, "
        "RLM_Bamboo_FreeTrial__c "
        f"FROM Quote WHERE Id = '{_soql_escape(quote_id)}' LIMIT 1"
    )
    qrow = qrows[0] if qrows else {}
    return {
        "quoteId": quote_id,
        "quoteNumber": qrow.get("QuoteNumber"),
        "lineItems": line_items,
        "monthlyTotal": monthly,
        "netPepm": 0.0 if free_trial else net_pepm,
        "pathBBundleSave": bool(qrow.get("RLM_Bamboo_PathB_BundleSave__c")),
        "freeTrial": bool(qrow.get("RLM_Bamboo_FreeTrial__c")),
        "listPepm": flat_list if use_flat else plan_list_price(plan_sku, currency),
        "volumePercent": vol_pct,
        "sellPlanSku": sell_plan_sku,
        "smallBizFlat": use_flat,
    }
