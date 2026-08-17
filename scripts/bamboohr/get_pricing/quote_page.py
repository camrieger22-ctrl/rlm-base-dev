"""Rebuild branded /quote/{id} payload from Salesforce when BFF cache misses."""

from __future__ import annotations

from datetime import date
from typing import Any

from service import (
    ALLOWED_TERM_MONTHS,
    DEFAULT_TERM_MONTHS,
    OrgSession,
    add_calendar_months,
)


def _soql_str(value: str) -> str:
    return (value or "").replace("\\", "\\\\").replace("'", "\\'")


def _months_between(start: date, end: date) -> int | None:
    """Best-effort term length from QLI Start/End (calendar months)."""
    if end <= start:
        return None
    months = (end.year - start.year) * 12 + (end.month - start.month)
    # If end day is before start day, still count full months when End matches
    # add_calendar_months (same day-of-month).
    if months in ALLOWED_TERM_MONTHS:
        return months
    # Prefer nearest allowed term when close (e.g. 30-day trial → not a term).
    for candidate in ALLOWED_TERM_MONTHS:
        try:
            if add_calendar_months(start, candidate) == end:
                return candidate
        except Exception:
            continue
    return months if months > 0 else None


def load_quote_summary_from_org(
    session: OrgSession, quote_id: str
) -> dict[str, Any] | None:
    """Return a quote-page payload shaped like GetPricingResult.as_dict(), or None."""
    qid = (quote_id or "").strip()
    if not qid:
        return None
    rows = session.soql(
        "SELECT Id, Name, QuoteNumber, Status, TotalPrice, CurrencyIsoCode, "
        "Description, QuoteAccountId, Account.Name, Account.BillingCountry, "
        "RLM_Bamboo_FreeTrial__c "
        f"FROM Quote WHERE Id = '{_soql_str(qid)}' LIMIT 1"
    )
    if not rows:
        return None
    q = rows[0]
    acct = q.get("Account") if isinstance(q.get("Account"), dict) else {}
    account_id = q.get("QuoteAccountId") or ""
    account_name = str(acct.get("Name") or "").strip() or "Account"
    billing = str(acct.get("BillingCountry") or "US").upper()
    country = "UK" if billing in ("GB", "UK") else ("CA" if billing == "CA" else "US")
    currency = q.get("CurrencyIsoCode") or "USD"
    free_trial = bool(q.get("RLM_Bamboo_FreeTrial__c"))

    lines_raw = session.soql(
        "SELECT Id, Quantity, ListPrice, UnitPrice, NetUnitPrice, TotalPrice, "
        "StartDate, EndDate, Product2.Name, Product2.StockKeepingUnit "
        f"FROM QuoteLineItem WHERE QuoteId = '{_soql_str(qid)}' "
        "ORDER BY LineNumber ASC NULLS LAST, CreatedDate ASC"
    )
    line_items: list[dict[str, Any]] = []
    start_iso: str | None = None
    end_iso: str | None = None
    headcount = 0
    plan_name = q.get("Name") or "BambooHR"
    plan_sku = ""
    list_pepm = 0.0
    net_pepm = 0.0

    for row in lines_raw:
        product = row.get("Product2") or {}
        sku = product.get("StockKeepingUnit") or ""
        name = product.get("Name") or sku or "Line"
        qty = float(row.get("Quantity") or 0)
        list_p = float(row.get("ListPrice") or row.get("UnitPrice") or 0)
        net_p = float(
            row.get("NetUnitPrice")
            if row.get("NetUnitPrice") is not None
            else (row.get("UnitPrice") or 0)
        )
        monthly = float(row.get("TotalPrice") or (net_p * qty))
        s = str(row.get("StartDate") or "")[:10] or None
        e = str(row.get("EndDate") or "")[:10] or None
        if s and not start_iso:
            start_iso = s
        if e and not end_iso:
            end_iso = e
        line_items.append(
            {
                "sku": sku,
                "name": name,
                "qty": int(qty) if qty == int(qty) else qty,
                "listPepm": round(list_p, 2),
                "netPepm": round(net_p, 2),
                "monthly": round(monthly, 2),
                "startDate": s,
                "endDate": e,
            }
        )
        # Prefer Core/Pro/Elite as plan for header metrics.
        if sku.startswith("BAMBOO-") and "PAYROLL" not in sku and "TIME" not in sku:
            if not plan_sku or sku in {"BAMBOO-CORE", "BAMBOO-PRO", "BAMBOO-ELITE", "BAMBOO-CORE-FLAT-SM"}:
                plan_sku = sku
                plan_name = name
                list_pepm = list_p
                net_pepm = net_p
                headcount = int(qty) if qty else headcount

    if not plan_sku and line_items:
        plan_sku = line_items[0].get("sku") or ""
        plan_name = line_items[0].get("name") or plan_name
        list_pepm = float(line_items[0].get("listPepm") or 0)
        net_pepm = float(line_items[0].get("netPepm") or 0)
        headcount = int(line_items[0].get("qty") or 0)

    monthly_total = float(q.get("TotalPrice") or 0)
    if not monthly_total and line_items:
        monthly_total = round(sum(float(li.get("monthly") or 0) for li in line_items), 2)

    term_months = DEFAULT_TERM_MONTHS
    if start_iso and end_iso and not free_trial:
        try:
            s_d = date.fromisoformat(start_iso)
            e_d = date.fromisoformat(end_iso)
            guessed = _months_between(s_d, e_d)
            if guessed in ALLOWED_TERM_MONTHS:
                term_months = guessed
        except ValueError:
            pass

    # Contact email for create-login prefill when available.
    contact_id = None
    contact_name = ""
    contact_email = ""
    if account_id:
        contacts = session.soql(
            "SELECT Id, FirstName, LastName, Email FROM Contact "
            f"WHERE AccountId = '{_soql_str(account_id)}' "
            "ORDER BY CreatedDate DESC LIMIT 1"
        )
        if contacts:
            contact_id = contacts[0]["Id"]
            contact_name = (
                f"{contacts[0].get('FirstName') or ''} "
                f"{contacts[0].get('LastName') or ''}"
            ).strip()
            contact_email = contacts[0].get("Email") or ""

    return {
        "ok": True,
        "quoteId": qid,
        "quoteNumber": q.get("QuoteNumber"),
        "country": country,
        "currency": currency,
        "accountName": account_name,
        "accountId": account_id,
        "contactId": contact_id,
        "contactName": contact_name,
        "contactEmail": contact_email,
        "planSku": plan_sku,
        "planName": plan_name,
        "headcount": headcount or 0,
        "listPepm": round(list_pepm, 2),
        "volumePercent": 0,
        "netPepm": round(net_pepm, 2),
        "monthlyTotal": round(monthly_total, 2),
        "annualTotal": round(monthly_total * 12, 2),
        "lineItems": line_items,
        "pathBBundleSave": False,
        "freeTrial": free_trial,
        "trialDays": 30 if free_trial else 0,
        "startDate": start_iso,
        "endDate": end_iso,
        "termMonths": term_months,
        "warnings": [
            "Rebuilt from Salesforce after BFF restart — discounts / Path B detail may be simplified."
        ],
        "fromOrg": True,
    }
