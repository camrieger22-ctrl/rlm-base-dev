"""Amend summary view model — Phase A.

Assembles a customer-ready ``amendSummaryView`` from ``preview_account_changes``
output. Salesforce owns rates and Quote totals; this module only subtracts,
multiplies by 12 for yearly run-rate, and shapes the payload for the UI.

Do not invent PEPM here — after nets come from priced Quotes (or schedule
fallback already present on preview lines).
"""

from __future__ import annotations

from datetime import date, datetime, timezone
from typing import Any

from service import PATH_B_BUNDLE_SAVE, US_ONLY_ADDONS

HERO_LABEL_CHARGE = "Quoted now (remaining term)"
HERO_LABEL_CREDIT = "Quoted credit (remaining term)"

COMPARE_HINT = (
    "Quoted now is the Salesforce Quote total for the remaining term. "
    "Pay Now collects the first Billing invoice, which can be a shorter "
    "first slice — not this Quote total. Monthly is ongoing subscription; "
    "yearly is monthly × 12 for reference."
)


def _money_round(value: Any) -> float:
    return round(float(value or 0), 2)


def _yearly_run_rate(mrr: float) -> float:
    return _money_round(mrr * 12)


def _pepm(mrr: float | None, qty: float | None) -> float | None:
    if mrr is None or qty is None:
        return None
    q = float(qty)
    if q <= 0:
        return None
    return round(float(mrr) / q, 6)


def _after_waterfall(
    *,
    sku: str,
    list_pepm: float | None,
    net_pepm: float | None,
    volume_percent: float | None,
    path_b: bool,
) -> dict[str, Any]:
    sku_u = (sku or "").upper()
    bundle_pct = (
        PATH_B_BUNDLE_SAVE * 100.0
        if path_b and sku_u in US_ONLY_ADDONS
        else 0.0
    )
    after_bundle: float | None = None
    if list_pepm is not None:
        after_bundle = round(float(list_pepm) * (1.0 - bundle_pct / 100.0), 2)
    return {
        "listPepm": list_pepm,
        "bundleSavePercent": bundle_pct,
        "afterBundlePepm": after_bundle,
        "volumePercent": volume_percent,
        "netPepm": net_pepm,
    }


def _kind_label(kind: str) -> str:
    k = (kind or "").strip()
    if k == "qtyAmend":
        return "Seat change"
    if k == "moduleSale":
        return "Add module"
    return k or "Quote"


def _iso_day(value: Any) -> str | None:
    text = str(value or "").strip()
    return text[:10] or None


def _charge_line_from_qli(
    ql: dict[str, Any], *, path_b: bool, volume_percent: float | None
) -> dict[str, Any]:
    """Map Quote line snapshot → pricing-summary waterfall + line charge."""
    sku = str(ql.get("sku") or "").upper()
    list_pepm = ql.get("listPepm")
    if list_pepm is not None:
        list_pepm = float(list_pepm)
    net = float(ql.get("netUnitPrice") or 0)
    unit = float(ql.get("unitPrice") or 0)
    qty = float(ql.get("quantity") or 0)
    line_total = float(ql.get("totalPrice") or 0)
    bundle_pct = (
        PATH_B_BUNDLE_SAVE * 100.0
        if path_b and sku in US_ONLY_ADDONS
        else 0.0
    )
    after_bundle: float | None = None
    if list_pepm is not None:
        if bundle_pct > 0:
            # Prefer UnitPrice when it reflects post-bundle (Path B) before volume.
            after_bundle = (
                round(unit, 2)
                if unit > 0
                else round(list_pepm * (1.0 - bundle_pct / 100.0), 2)
            )
        else:
            after_bundle = round(list_pepm, 2)
    vol_pct = volume_percent
    if vol_pct is None and list_pepm and after_bundle and after_bundle > 0 and net > 0:
        # Derive volume % from after-bundle → net when not provided.
        try:
            vol_pct = round((1.0 - (net / after_bundle)) * 100.0, 4)
            if vol_pct < 0:
                vol_pct = 0.0
        except ZeroDivisionError:
            vol_pct = 0.0
    return {
        "sku": sku,
        "name": ql.get("name") or sku,
        "quantity": qty,
        "listPepm": list_pepm,
        "bundleSavePercent": bundle_pct,
        "afterBundlePepm": after_bundle,
        "volumePercent": vol_pct,
        "netPepm": net if net else None,
        "lineTotal": round(line_total, 2),
        "startDate": _iso_day(ql.get("startDate")),
        "endDate": _iso_day(ql.get("endDate")),
        "source": "quoteLineTotalPrice",
    }


def build_amend_summary_view(preview: dict[str, Any]) -> dict[str, Any]:
    """Map preview_account_changes (or compatible) dict → amendSummaryView."""
    if not preview or not preview.get("ok"):
        return {
            "ok": False,
            "error": (preview or {}).get("error") or "Preview required",
        }

    path_b = bool(preview.get("pathBBundleSave"))
    currency = preview.get("currency") or "USD"
    seats_today = int(preview.get("currentQty") or 0)
    seats_baseline = int(preview.get("baselineQty") or seats_today)
    seats_after = int(preview.get("newQty") or seats_baseline)
    seats_delta = seats_after - seats_baseline

    # Volume % from after subscription lines (same band for charge waterfall).
    volume_pct_hint: float | None = None
    for line in preview.get("lines") or []:
        if line.get("volumePercent") is not None and not line.get("isFlat"):
            volume_pct_hint = float(line["volumePercent"])
            break

    today_by_sku: dict[str, dict[str, Any]] = {}
    for line in preview.get("linesToday") or []:
        sku = str(line.get("sku") or "").upper()
        if not sku:
            continue
        today_by_sku[sku] = line

    products: list[dict[str, Any]] = []
    for line in preview.get("lines") or []:
        sku = str(line.get("sku") or "").upper()
        if not sku:
            continue
        before = today_by_sku.get(sku) or {}
        is_flat = bool(line.get("isFlat") or before.get("isFlat"))
        is_new = bool(line.get("isNew"))

        qty_today = before.get("qty")
        qty_after = line.get("qty")
        if qty_today is not None:
            qty_today = int(qty_today) if not is_flat else 1
        if qty_after is not None:
            qty_after = int(qty_after) if not is_flat else 1

        mrr_today = _money_round(before.get("monthly")) if before else 0.0
        mrr_after = _money_round(line.get("monthly"))
        if not before:
            mrr_today = 0.0
            qty_today = 0 if not is_flat else None

        mrr_delta = _money_round(mrr_after - mrr_today)
        qty_delta = None
        if qty_today is not None and qty_after is not None:
            qty_delta = int(qty_after) - int(qty_today)
        elif is_new and qty_after is not None:
            qty_delta = int(qty_after)

        pepm_today = None
        if before and not is_flat:
            pepm_today = (
                float(before["netPepm"])
                if before.get("netPepm") is not None
                else _pepm(mrr_today, qty_today)
            )
        pepm_after = None
        if not is_flat:
            pepm_after = (
                float(line["netPepm"])
                if line.get("netPepm") is not None
                else _pepm(mrr_after, qty_after)
            )

        list_pepm = line.get("listPepm")
        if list_pepm is not None:
            list_pepm = float(list_pepm)
        vol_pct = line.get("volumePercent")
        if vol_pct is not None:
            vol_pct = float(vol_pct)

        waterfall = _after_waterfall(
            sku=sku,
            list_pepm=list_pepm,
            net_pepm=pepm_after,
            volume_percent=vol_pct,
            path_b=path_b,
        )

        today_source = before.get("source") or "assetCurrentMrr"
        after_source = line.get("source") or "amendQuote"
        if after_source in ("moduleQuote", "amendQuote", "pricingApi"):
            pass
        elif is_new:
            after_source = "moduleQuote"
        else:
            after_source = "amendQuote"

        products.append(
            {
                "sku": sku,
                "name": line.get("name") or before.get("name") or sku,
                "isNew": is_new,
                "isFlat": is_flat,
                "isPepm": not is_flat,
                "today": {
                    "qty": qty_today,
                    "mrr": mrr_today,
                    "yearlyRunRate": _yearly_run_rate(mrr_today),
                    "pepm": pepm_today,
                    "source": today_source,
                },
                "after": {
                    "qty": qty_after,
                    "mrr": mrr_after,
                    "yearlyRunRate": _yearly_run_rate(mrr_after),
                    "pepm": pepm_after,
                    "source": after_source,
                    **waterfall,
                },
                "delta": {
                    "qty": qty_delta,
                    "mrr": mrr_delta,
                    "yearlyRunRate": _yearly_run_rate(mrr_delta),
                },
            }
        )

    mrr_today_total = _money_round(
        (preview.get("monthly") or {}).get("today")
        if (preview.get("monthly") or {}).get("today") is not None
        else sum(p["today"]["mrr"] for p in products)
    )
    mrr_after_total = _money_round(
        (preview.get("monthly") or {}).get("after")
        if (preview.get("monthly") or {}).get("after") is not None
        else sum(p["after"]["mrr"] for p in products)
    )
    mrr_delta_total = _money_round(mrr_after_total - mrr_today_total)

    due_parts_raw = list(preview.get("dueParts") or [])
    quote_parts: list[dict[str, Any]] = []
    charge_lines: list[dict[str, Any]] = []
    for part in due_parts_raw:
        kind = str(part.get("kind") or "")
        amount = _money_round(part.get("totalPrice"))
        quote_parts.append(
            {
                "kind": kind,
                "kindLabel": _kind_label(kind),
                "quoteId": part.get("quoteId"),
                "quoteNumber": part.get("quoteNumber"),
                "totalPrice": amount,
                "source": "quoteTotalPrice",
            }
        )
        for ql in part.get("lines") or []:
            charge_lines.append(
                _charge_line_from_qli(
                    ql, path_b=path_b, volume_percent=volume_pct_hint
                )
            )

    module = preview.get("moduleQuote") or {}
    if module.get("quoteId") and not any(
        p.get("quoteId") == module.get("quoteId") for p in quote_parts
    ):
        quote_parts.append(
            {
                "kind": "moduleSale",
                "kindLabel": _kind_label("moduleSale"),
                "quoteId": module.get("quoteId"),
                "quoteNumber": module.get("quoteNumber"),
                "totalPrice": _money_round(module.get("totalPrice")),
                "source": "quoteTotalPrice",
            }
        )

    for draft in preview.get("amendQuotes") or []:
        qid = draft.get("quoteId")
        if not qid:
            continue
        if not any(p.get("quoteId") == qid for p in quote_parts):
            quote_parts.append(
                {
                    "kind": "qtyAmend",
                    "kindLabel": _kind_label("qtyAmend"),
                    "quoteId": qid,
                    "quoteNumber": draft.get("quoteNumber"),
                    "totalPrice": _money_round(draft.get("totalPrice")),
                    "source": "quoteTotalPrice",
                }
            )
        if not charge_lines:
            for ql in draft.get("lines") or []:
                charge_lines.append(
                    _charge_line_from_qli(
                        ql, path_b=path_b, volume_percent=volume_pct_hint
                    )
                )

    due_amount = preview.get("dueToday")
    if due_amount is None:
        due_amount = sum(p["totalPrice"] for p in quote_parts)
    due_amount = _money_round(due_amount)
    charge_lines_total = _money_round(sum(c["lineTotal"] for c in charge_lines))

    show_parts = len(quote_parts) > 1
    hero_label = HERO_LABEL_CREDIT if due_amount < 0 else HERO_LABEL_CHARGE

    volume_pct = volume_pct_hint
    for p in products:
        if p.get("isPepm") and p["after"].get("volumePercent") is not None:
            volume_pct = p["after"]["volumePercent"]
            break

    priced_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    cash_due = None
    start_s = str(preview.get("amendStartDate") or "")[:10]
    try:
        if start_s and date.fromisoformat(start_s) > date.today():
            cash_due = start_s
    except ValueError:
        cash_due = None

    return {
        "ok": True,
        "schema": "amendSummaryView/v1",
        "pricedAt": priced_at,
        "accountId": preview.get("accountId"),
        "accountName": preview.get("accountName"),
        "currency": currency,
        "country": preview.get("country"),
        "opportunityId": preview.get("opportunityId"),
        "amendStartDate": preview.get("amendStartDate"),
        "cashDueDate": cash_due,
        "cashDueHint": (
            f"First bill is due {cash_due}, not today."
            if cash_due
            else None
        ),
        "pathBBundleSave": path_b,
        "volumePercentAfter": volume_pct,
        "seats": {
            "today": seats_today,
            "baselineOnStart": seats_baseline,
            "after": seats_after,
            "delta": seats_delta,
        },
        "hero": {
            "label": hero_label,
            "amount": due_amount,
            "isCredit": due_amount < 0,
            "source": "quoteTotalPrice",
            "showPerQuoteParts": show_parts,
        },
        "dueForChange": {
            "amount": due_amount,
            "source": "quoteTotalPrice",
            "label": hero_label,
            "parts": quote_parts,
            "showParts": show_parts,
            # Pricing-summary style rows that sum to the prorated charge.
            "lines": charge_lines,
            "linesTotal": charge_lines_total,
        },
        "totals": {
            "mrr": {
                "today": mrr_today_total,
                "delta": mrr_delta_total,
                "after": mrr_after_total,
            },
            "yearlyRunRate": {
                "today": _yearly_run_rate(mrr_today_total),
                "delta": _yearly_run_rate(mrr_delta_total),
                "after": _yearly_run_rate(mrr_after_total),
                "basis": "mrrTimes12",
            },
        },
        "products": products,
        "quotes": quote_parts,
        "amendQuotes": preview.get("amendQuotes") or [],
        "moduleQuoteId": preview.get("moduleQuoteId"),
        "moduleQuote": preview.get("moduleQuote"),
        "cancelQuoteId": preview.get("cancelQuoteId"),
        "upgradeQuoteId": preview.get("upgradeQuoteId"),
        "upgradeQuote": preview.get("upgradeQuote"),
        "upgradeSku": preview.get("upgradeSku"),
        "warnings": list(preview.get("warnings") or []),
        "compareHint": COMPARE_HINT,
        "labels": {
            "proratedCharge": HERO_LABEL_CHARGE,
            "proratedCredit": HERO_LABEL_CREDIT,
            "monthly": "Monthly",
            "yearlyRunRate": "Yearly (monthly × 12)",
            "todayColumn": "Today (Current MRR)",
            "changeColumn": "This change",
            "afterColumn": "After (quoted)",
            "chargeLinesLede": (
                "List → Bundle & Save (if eligible) → volume → quoted remaining "
                "term. Qty is seats/modules on the amend Quote. Dates are "
                "that line's service window. Line totals sum to Quoted now "
                "above — Pay Now may bill a shorter first slice."
            ),
        },
    }


def attach_amend_summary_view(preview: dict[str, Any]) -> dict[str, Any]:
    """Return preview dict with ``amendSummaryView`` attached (mutates copy)."""
    out = dict(preview)
    if not out.get("ok"):
        return out
    out["amendSummaryView"] = build_amend_summary_view(out)
    return out
