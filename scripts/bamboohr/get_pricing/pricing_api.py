"""Ephemeral Salesforce Pricing (headless) for Get Pricing rail estimates.

Phase 1 middle ground: price the configurator without creating Opportunity/Quote.
Generate quote still uses PST place + System reprice (``service.get_pricing``).
"""

from __future__ import annotations

import json
import threading
import uuid
from datetime import date
from typing import Any

from service import (
    ADDON_LABELS,
    API,
    CORE_FLAT_SKU,
    COUNTRY_CURRENCY,
    NON_US_COUNTRIES,
    OrgSession,
    PATH_B_BUNDLE_SAVE,
    PLAN_LABELS,
    PLAN_LIST_USD,
    TRIAL_DAYS,
    US_ONLY_ADDONS,
    _pbe_for_sku,
    addon_list_price,
    core_flat_price,
    expected_addon_net,
    expected_net,
    line_item_dict,
    normalize_addons,
    plan_list_price,
    resolve_subscription_window,
    uses_core_flat,
    volume_rate,
)

PATH_B_TARGETS = frozenset({"BAMBOO-ADD-PAYROLL", "BAMBOO-ADD-BENEFITS"})

_ctx_lock = threading.Lock()
_ctx_cache: dict[str, tuple[str, str]] = {}


def _ctx_ids(session: OrgSession) -> tuple[str, str]:
    key = session.alias or "default"
    with _ctx_lock:
        if key in _ctx_cache:
            return _ctx_cache[key]
    ctx = session._http(
        "GET",
        f"/services/data/{API}/connect/context-definitions/RLM_SalesTransactionContext",
    )
    ctx_def_id = ctx["contextDefinitionId"]
    mapping_id = None
    for version in ctx.get("contextDefinitionVersionList") or []:
        for mapping in version.get("contextMappings") or []:
            base = mapping.get("baseReference") or ""
            if base.endswith("/QuoteEntitiesMapping") or "QuoteEntitiesMapping" in base:
                mapping_id = mapping.get("contextMappingId")
                break
        if mapping_id:
            break
    if not mapping_id:
        raise RuntimeError("Could not resolve QuoteEntitiesMapping id")
    with _ctx_lock:
        _ctx_cache[key] = (ctx_def_id, mapping_id)
    return ctx_def_id, mapping_id


def _waterfall_rows(priced: dict) -> list[dict[str, Any]]:
    if isinstance(priced, list):
        priced = priced[0]
    if priced.get("isSuccess") is False:
        raise RuntimeError(f"Headless pricing failed: {priced}")
    outs = priced.get("outputValues") or {}
    if outs.get("pricingProcessStatus") != "Completed":
        raise RuntimeError(f"Headless pricing not Completed: {outs or priced}")
    result = json.loads(outs["pricingResult"])
    rows_out: list[dict[str, Any]] = []
    for row in result.get("PriceWaterFall") or []:
        wf = json.loads(row["value"]) if isinstance(row.get("value"), str) else row.get("value")
        if not isinstance(wf, dict):
            continue
        output = wf.get("output") or {}
        steps = []
        for step in wf.get("waterfall") or []:
            pe = step.get("pricingElement") or {}
            name = pe.get("name") or pe.get("label") or ""
            if name:
                steps.append(name)
        rows_out.append(
            {
                "list": float(output.get("ListPrice") or 0),
                "net": float(output.get("NetUnitPrice") or 0),
                "steps": steps,
            }
        )
    return rows_out


def _match_nets_to_skus(
    rows: list[dict[str, Any]], catalog_lines: list[dict[str, Any]]
) -> dict[str, float]:
    by_list: dict[float, str] = {}
    for line in catalog_lines:
        by_list[round(float(line.get("list") or 0), 4)] = line["sku"]
    matched: dict[str, float] = {}
    for info in rows:
        sku = by_list.get(round(float(info["list"]), 4))
        if sku:
            matched[sku] = float(info["net"])
    return matched


def headless_price_cart(
    session: OrgSession,
    *,
    currency: str,
    lines: list[dict[str, Any]],
    quantity: int,
    path_b: bool,
    free_trial: bool = False,
    start_date: date | None = None,
    term_months: int | None = None,
) -> dict[str, float]:
    """Price many lines in one headless call. Returns {sku: netPepm}."""
    if not lines:
        return {}
    ctx_def_id, mapping_id = _ctx_ids(session)
    pb = session.soql("SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1")[0]["Id"]
    start_day, end_day, _months = resolve_subscription_window(
        start_date=start_date,
        term_months=term_months,
        free_trial=free_trial,
    )
    today = start_day.isoformat()
    end = end_day.isoformat()
    synth_quote = f"0Q0EST{uuid.uuid4().hex[:12].upper()}"
    items = []
    for i, line in enumerate(lines):
        qty = int(line.get("quantity") or quantity)
        items.append(
            {
                "businessObjectType": "QuoteLineItem",
                "id": line.get("id") or f"synth_{line['sku']}_{i}",
                "Product": line["product2Id"],
                "ProductSellingModel": line["productSellingModelId"],
                "Quantity": qty,
                "SalesTransactionItemSource": f"LINE_ITEM{i + 1}",
                "EffectiveFrom": f"{today}T00:00:00.000Z",
                "EffectiveTo": f"{end}T00:00:00.000Z",
                "RLM_Bamboo_BundleSave_Target__c": line["sku"] in PATH_B_TARGETS,
            }
        )
    pricing_data = {
        "SalesTransaction": {
            "businessObjectType": "Quote",
            "id": synth_quote,
            "Pricebook": pb,
            "CurrencyIsoCode": currency,
            "RLM_Bamboo_PathB_BundleSave__c": bool(path_b),
            "RLM_Bamboo_FreeTrial__c": bool(free_trial),
            "SalesTransactionItem": items,
        }
    }
    body = {
        "inputs": [
            {
                "contextDefinitionId": ctx_def_id,
                "contextMappingId": mapping_id,
                "pricingProcedureId": "RLM_DefaultPricingProcedure",
                "skipDiscovery": True,
                "displayContext": True,
                "isSkipWaterfall": False,
                "persistContext": False,
                "useSessionScopedContext": False,
                "taggedData": False,
                "pricingData": json.dumps(pricing_data, separators=(",", ":")),
            }
        ]
    }
    priced = session.post(
        f"/services/data/{API}/actions/standard/runSalesforceHeadlessPricing",
        body,
    )
    rows = _waterfall_rows(priced if isinstance(priced, dict) else priced[0])
    return _match_nets_to_skus(rows, lines)


def estimate_get_pricing(
    session: OrgSession,
    *,
    headcount: int,
    country: str = "US",
    plan_sku: str = "BAMBOO-PRO",
    addon_skus: list[str] | None = None,
    free_trial: bool = False,
    start_date: date | None = None,
    term_months: int | None = None,
) -> dict[str, Any]:
    """Rail estimate via Pricing API — no Opportunity / Quote created."""
    warnings: list[str] = []
    country = (country or "US").upper()
    if country not in COUNTRY_CURRENCY:
        return {"ok": False, "error": f"Unsupported country {country!r}"}
    currency = COUNTRY_CURRENCY[country]
    plan_sku = (plan_sku or "BAMBOO-PRO").upper()
    if plan_sku not in PLAN_LIST_USD:
        return {"ok": False, "error": f"Unknown planSku {plan_sku}"}
    if headcount < 1:
        return {"ok": False, "error": "headcount must be >= 1"}

    try:
        start_day, end_day, months = resolve_subscription_window(
            start_date=start_date,
            term_months=term_months,
            free_trial=bool(free_trial),
        )
    except ValueError as exc:
        return {"ok": False, "error": str(exc)}

    addon_skus = normalize_addons(addon_skus)
    if country in NON_US_COUNTRIES:
        blocked = [s for s in addon_skus if s in US_ONLY_ADDONS]
        if blocked:
            warnings.append(
                "Removed US-only add-ons for "
                f"{'Canada' if country == 'CA' else 'United Kingdom'}: "
                + ", ".join(ADDON_LABELS[s] for s in blocked)
            )
            addon_skus = [s for s in addon_skus if s not in US_ONLY_ADDONS]

    path_b = (
        "BAMBOO-ADD-PAYROLL" in addon_skus and "BAMBOO-ADD-BENEFITS" in addon_skus
    )
    if path_b:
        warnings.append(
            "Path B Bundle & Save: 15% on Payroll + Benefits (a la carte with a plan)."
        )

    use_flat = uses_core_flat(plan_sku, headcount)
    sell_plan_sku = CORE_FLAT_SKU if use_flat else plan_sku
    plan_qty = 1 if use_flat else headcount
    flat_list = core_flat_price(currency)
    if use_flat:
        warnings.append(
            f"Small-business flat: Core uses {CORE_FLAT_SKU} at "
            f"{currency} {flat_list:.2f}/mo (qty 1)."
        )

    free_trial = bool(free_trial)
    if free_trial:
        warnings.append(
            f"Free trial (convert later): {TRIAL_DAYS}-day term at $0 for plan + add-ons."
        )

    skus_needed = [sell_plan_sku, *addon_skus]
    catalog_lines: list[dict[str, Any]] = []
    for sku in skus_needed:
        pbe = _pbe_for_sku(session, sku, currency)
        catalog_lines.append(
            {
                "sku": sku,
                "id": f"synth_{sku}_{uuid.uuid4().hex[:6]}",
                "product2Id": pbe["Product2Id"],
                "productSellingModelId": pbe["ProductSellingModelId"],
                "list": float(pbe["UnitPrice"]),
                "quantity": plan_qty if sku == sell_plan_sku else headcount,
            }
        )

    try:
        nets = headless_price_cart(
            session,
            currency=currency,
            lines=catalog_lines,
            quantity=headcount,
            path_b=path_b,
            free_trial=free_trial,
            start_date=start_day,
            term_months=months,
        )
        pricing_source = "pricingApi"
    except Exception as exc:  # noqa: BLE001
        warnings.append(f"Pricing API unavailable — local estimate. ({exc})")
        nets = {}
        pricing_source = "localFallback"
        if use_flat:
            nets[sell_plan_sku] = flat_list
        else:
            nets[sell_plan_sku] = expected_net(plan_sku, headcount, currency)
        for sku in addon_skus:
            nets[sku] = expected_addon_net(
                sku, path_b=path_b, currency=currency, headcount=headcount
            )

    # Free trial: show $0 on the rail even if headless didn't zero lines.
    if free_trial:
        nets = {k: 0.0 for k in nets}

    vol = 0.0 if use_flat else volume_rate(headcount)
    vol_pct = round(vol * 100, 1)
    line_items: list[dict[str, Any]] = []
    monthly_total = 0.0

    plan_net = float(nets.get(sell_plan_sku) or 0)
    if use_flat:
        plan_monthly = round(plan_net, 2)
        line_items.append(
            line_item_dict(
                sku=sell_plan_sku,
                name=f"{PLAN_LABELS.get(plan_sku, plan_sku)} (flat)",
                quantity=1,
                list_pepm=flat_list,
                net_pepm=plan_net,
                monthly=plan_monthly,
                is_plan=True,
                path_b=False,
                volume_percent=0.0,
            )
        )
    else:
        list_p = plan_list_price(plan_sku, currency)
        plan_monthly = round(plan_net * headcount, 2)
        line_items.append(
            line_item_dict(
                sku=plan_sku,
                name=PLAN_LABELS.get(plan_sku, plan_sku),
                quantity=headcount,
                list_pepm=list_p,
                net_pepm=plan_net,
                monthly=plan_monthly,
                is_plan=True,
                path_b=False,
                volume_percent=vol_pct,
            )
        )
    monthly_total = round(monthly_total + plan_monthly, 2)

    for sku in addon_skus:
        net = float(nets.get(sku) or 0)
        list_p = addon_list_price(sku, currency)
        monthly = round(net * headcount, 2)
        monthly_total = round(monthly_total + monthly, 2)
        line_items.append(
            line_item_dict(
                sku=sku,
                name=ADDON_LABELS.get(sku, sku),
                quantity=headcount,
                list_pepm=list_p,
                net_pepm=net,
                monthly=monthly,
                is_plan=False,
                path_b=path_b,
                volume_percent=vol_pct,
            )
        )

    pepm_blended = (
        round(monthly_total / headcount, 2) if headcount and not free_trial else 0.0
    )
    return {
        "ok": True,
        "pricingSource": pricing_source,
        "headcount": headcount,
        "country": country,
        "currency": currency,
        "planSku": plan_sku,
        "addonSkus": addon_skus,
        "freeTrial": free_trial,
        "smallBizFlat": use_flat,
        "pathBBundleSave": path_b,
        "volumePercent": vol_pct,
        "bundleSavePercent": PATH_B_BUNDLE_SAVE * 100.0 if path_b else 0.0,
        "netPepm": pepm_blended if not use_flat else plan_net,
        "listPepm": (
            flat_list if use_flat else plan_list_price(plan_sku, currency)
        ),
        "monthlyTotal": monthly_total,
        "annualTotal": round(monthly_total * 12, 2),
        "startDate": start_day.isoformat(),
        "endDate": end_day.isoformat(),
        "termMonths": months,
        "termTotal": round(monthly_total * months, 2),
        "lineItems": line_items,
        "warnings": warnings,
        # Explicit: no transaction created for rail estimates.
        "quoteId": None,
        "opportunityId": None,
    }
