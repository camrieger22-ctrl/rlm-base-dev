"""Account subscription timeline from AssetStatePeriod (Licenses & billing).

Committed seat/MRR schedule — not draft Place-order math. Group ASPs by
date range so the customer sees account-level upcoming changes.
"""

from __future__ import annotations

from collections import defaultdict
from datetime import date, datetime, timezone
from typing import Any

from service import OrgSession


def _day(value: Any) -> str:
    return str(value or "")[:10]


def _soql_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace("'", "\\'")


def list_account_periods(
    session: OrgSession,
    account_id: str,
    *,
    as_of: date | datetime | None = None,
) -> dict[str, Any]:
    """Build account-level timeline from AssetStatePeriod rows.

    Returns ``{ source, asOf, periods[], warnings[] }``. Soft-fails to empty
    periods on query errors so account-console still loads.
    """
    aid = (account_id or "").strip()
    if not aid:
        return {
            "source": "assetStatePeriod",
            "asOf": date.today().isoformat(),
            "periods": [],
            "warnings": ["accountId required"],
        }

    if isinstance(as_of, datetime):
        as_of_day = as_of.astimezone(timezone.utc).date()
    elif isinstance(as_of, date):
        as_of_day = as_of
    else:
        as_of_day = datetime.now(timezone.utc).date()
    as_of_s = as_of_day.isoformat()

    warnings: list[str] = []
    try:
        rows = session.soql(
            "SELECT Id, AssetId, Quantity, Mrr, StartDate, EndDate, "
            "Asset.Name, Asset.Product2.StockKeepingUnit, Asset.Product2.Name "
            f"FROM AssetStatePeriod WHERE Asset.AccountId = '{_soql_escape(aid)}' "
            "ORDER BY StartDate ASC, Asset.Product2.StockKeepingUnit ASC "
            "LIMIT 500"
        )
    except Exception as exc:  # noqa: BLE001
        return {
            "source": "assetStatePeriod",
            "asOf": as_of_s,
            "periods": [],
            "warnings": [f"AssetStatePeriod query failed: {exc}"[:300]],
        }

    buckets: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        start = _day(row.get("StartDate"))
        end = _day(row.get("EndDate")) or "9999-12-31"
        if not start:
            continue
        asset = row.get("Asset") or {}
        product = asset.get("Product2") or {}
        sku = (product.get("StockKeepingUnit") or "").upper()
        name = (
            asset.get("Name")
            or product.get("Name")
            or sku
            or row.get("AssetId")
        )
        qty = row.get("Quantity")
        mrr = row.get("Mrr")
        buckets[(start, end)].append(
            {
                "assetId": row.get("AssetId"),
                "periodId": row.get("Id"),
                "sku": sku,
                "name": name,
                "quantity": float(qty) if qty is not None else None,
                "mrr": float(mrr) if mrr is not None else None,
            }
        )

    periods: list[dict[str, Any]] = []
    for (start, end) in sorted(buckets.keys(), key=lambda k: k[0]):
        lines = buckets[(start, end)]
        qtys = [
            float(l["quantity"])
            for l in lines
            if l.get("quantity") is not None and not _looks_flat(l.get("sku") or "")
        ]
        if not qtys:
            qtys = [
                float(l["quantity"])
                for l in lines
                if l.get("quantity") is not None
            ]
        quantity = None
        if qtys:
            # Prefer the modal qty; fall back to max when mixed.
            quantity = max(set(qtys), key=qtys.count)
            if len(set(qtys)) > 1:
                warnings.append(
                    f"Mixed quantities in period {start}→{end}: {sorted(set(qtys))}"
                )
        mrrs = [float(l["mrr"]) for l in lines if l.get("mrr") is not None]
        recurring = round(sum(mrrs), 2) if mrrs else 0.0
        if len(mrrs) < len(lines):
            warnings.append(f"Some lines missing Mrr in period {start}→{end}")

        is_current = bool(start <= as_of_s <= end)
        periods.append(
            {
                "startDate": start,
                "endDate": end,
                "isCurrent": is_current,
                "quantity": quantity,
                "recurringMonthly": recurring,
                "deltaQuantity": None,
                "deltaRecurringMonthly": None,
                "lines": lines,
            }
        )

    for i, period in enumerate(periods):
        if i == 0:
            continue
        prev = periods[i - 1]
        if period.get("quantity") is not None and prev.get("quantity") is not None:
            period["deltaQuantity"] = float(period["quantity"]) - float(prev["quantity"])
        period["deltaRecurringMonthly"] = round(
            float(period["recurringMonthly"]) - float(prev["recurringMonthly"]),
            2,
        )

    return {
        "source": "assetStatePeriod",
        "asOf": as_of_s,
        "periods": periods,
        "warnings": warnings,
    }


def _looks_flat(sku: str) -> bool:
    u = (sku or "").upper()
    return "FLAT" in u
