"""BambooHR Get Pricing BFF service (P2/P3) — Discovery → price → place Quote."""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass, field
import calendar
from datetime import date, datetime, timedelta
from typing import Any

from qualify_crm import (
    DualMotionBlocked,
    STATUS_EXISTING_CUSTOMER,
    STATUS_SALES_WORKING,
    STATUS_SELF_SERVE,
    _safe_patch,
    campaign_from_utm,
    find_open_handoff_task,
    format_handoff_brief,
    lookup_email,
    mark_qualify_complete,
    self_serve_opportunity_name,
    self_serve_quote_name,
    stamp_sales_handoff,
    stamp_self_serve,
    update_existing_lead,
)

API = "v67.0"
CATALOG_NAME = "BambooHR"

# Buyer-selectable subscription terms on Get Pricing (calendar months).
# 1 = month-to-month; 12/24/36 = committed terms. All use Term Monthly PBEs (PEPM);
# Quote line StartDate/EndDate span the selected window.
ALLOWED_TERM_MONTHS = (1, 12, 24, 36)
DEFAULT_TERM_MONTHS = 1


def add_calendar_months(day: date, months: int) -> date:
    """Add whole calendar months, clamping day-of-month (e.g. Jan 31 → Feb 28)."""
    if months < 0:
        raise ValueError("months must be >= 0")
    year = day.year + (day.month - 1 + months) // 12
    month = (day.month - 1 + months) % 12 + 1
    last = calendar.monthrange(year, month)[1]
    return date(year, month, min(day.day, last))


def remaining_service_end(start: date, *ends: date | None) -> date:
    """Coterminous line end: latest remaining window, else +1 month — never +365.

    Missing LifecycleEndDate must not invent a year. If an annual window exists
    on another end (ASP, sibling asset), use that instead of +1 month.
    """
    later = [e for e in ends if isinstance(e, date) and e > start]
    if later:
        return max(later)
    return add_calendar_months(start, 1)


COUNTRY_ACCOUNT = {
    "US": "Acme",
    "CA": "Prestige Worldwide",
    "UK": "BambooHR UK Demo",
}

# Quote / account currency for each Get Pricing country (B5).
COUNTRY_CURRENCY = {
    "US": "USD",
    "CA": "CAD",
    "UK": "GBP",
}

# State/Country picklist values used by demo Accounts (category disqualification).
COUNTRY_BILLING = {
    "US": "US",
    "CA": "CA",
    "UK": "GB",
}

# Minimal shipping so createOrderFromQuote → Activate succeeds for new Accounts.
COUNTRY_SHIPPING = {
    "US": {
        "ShippingStreet": "1 Market Street",
        "ShippingCity": "New York",
        "ShippingState": "NY",
        "ShippingPostalCode": "10001",
        "ShippingCountry": "US",
        "BillingStreet": "1 Market Street",
        "BillingCity": "New York",
        "BillingState": "NY",
        "BillingPostalCode": "10001",
        "BillingCountry": "US",
    },
    "CA": {
        "ShippingStreet": "100 King St W",
        "ShippingCity": "Toronto",
        "ShippingState": "ON",
        "ShippingPostalCode": "M5X 1A9",
        "ShippingCountry": "CA",
        "BillingStreet": "100 King St W",
        "BillingCity": "Toronto",
        "BillingState": "ON",
        "BillingPostalCode": "M5X 1A9",
        "BillingCountry": "CA",
    },
    "UK": {
        "ShippingStreet": "1 Canada Square",
        "ShippingCity": "London",
        "ShippingPostalCode": "E14 5AB",
        "ShippingCountry": "GB",
        "BillingStreet": "1 Canada Square",
        "BillingCity": "London",
        "BillingPostalCode": "E14 5AB",
        "BillingCountry": "GB",
    },
}

# Demo list FX vs USD (bh-pricing PBEs). Keep in sync with PricebookEntry.csv.
CURRENCY_FX = {
    "USD": 1.0,
    "CAD": 1.35,
    "GBP": 0.79,
}

PLAN_LIST_USD = {
    "BAMBOO-CORE": 10.0,
    "BAMBOO-PRO": 17.0,
    "BAMBOO-ELITE": 25.0,
}

# Back-compat alias used by smokes / imports.
PLAN_LIST = PLAN_LIST_USD

PLAN_LABELS = {
    "BAMBOO-CORE": "BambooHR Core",
    "BAMBOO-PRO": "BambooHR Pro",
    "BAMBOO-ELITE": "BambooHR Elite",
}

# Legacy catalog SKU (still in PCM for SE / amend of old Assets). Micro self-serve
# acquisition no longer sells it — Core/Pro use standard list PEPM × headcount.
CORE_FLAT_SKU = "BAMBOO-CORE-FLAT-SM"
CORE_FLAT_PRICE_USD = 250.0
CORE_FLAT_PRICE = CORE_FLAT_PRICE_USD  # USD alias for smokes
SMALL_BIZ_MAX_HEADCOUNT = 25

ADDON_LIST_USD = {
    "BAMBOO-ADD-PAYROLL": 8.0,
    "BAMBOO-ADD-BENEFITS": 6.0,
    "BAMBOO-ADD-TIME": 4.0,
    "BAMBOO-ADD-GLOBAL": 12.0,
}

ADDON_LIST = ADDON_LIST_USD

ADDON_LABELS = {
    "BAMBOO-ADD-PAYROLL": "Payroll",
    "BAMBOO-ADD-BENEFITS": "Benefits Administration",
    "BAMBOO-ADD-TIME": "Time & Attendance",
    "BAMBOO-ADD-GLOBAL": "Global Employment",
}

# Category disqualification — not sellable outside US (CA + UK/GB demo Accounts).
US_ONLY_ADDONS = frozenset({"BAMBOO-ADD-PAYROLL", "BAMBOO-ADD-BENEFITS"})
NON_US_COUNTRIES = frozenset({"CA", "UK"})


def uses_core_flat(plan_sku: str, headcount: int) -> bool:
    """Former ≤25 Core → BAMBOO-CORE-FLAT-SM path.

    Self-serve now models Core and Pro at **standard list PEPM** (workshop
    acquisition). Keep the helper so call sites stay stable; always False.
    """
    return False


def _fx(currency: str) -> float:
    try:
        return CURRENCY_FX[currency]
    except KeyError as exc:
        raise ValueError(f"Unsupported currency {currency!r}") from exc


def plan_list_price(plan_sku: str, currency: str = "USD") -> float:
    return round(PLAN_LIST_USD[plan_sku] * _fx(currency), 2)


def core_flat_price(currency: str = "USD") -> float:
    return round(CORE_FLAT_PRICE_USD * _fx(currency), 2)


def addon_list_price(addon_sku: str, currency: str = "USD") -> float:
    return round(ADDON_LIST_USD[addon_sku] * _fx(currency), 2)


# Curated Get Pricing SKUs (UI cards). Hydrate list PEPM / names from org PBEs.
CATALOG_PLAN_SKUS = tuple(PLAN_LIST_USD.keys())
CATALOG_ADDON_SKUS = tuple(ADDON_LIST_USD.keys())
CATALOG_ALL_SKUS = (*CATALOG_PLAN_SKUS, *CATALOG_ADDON_SKUS, CORE_FLAT_SKU)


def _short_catalog_label(name: str | None, sku: str) -> str:
    if name:
        cleaned = name.replace("BambooHR ", "").strip()
        if cleaned:
            return cleaned
    if sku in PLAN_LABELS:
        return PLAN_LABELS[sku].replace("BambooHR ", "")
    return ADDON_LABELS.get(sku, sku)


def hydrate_catalog(session: OrgSession, country: str = "US") -> dict[str, Any]:
    """Load curated SKU list prices / names / availability from the org price book.

    Cards stay curated (fixed SKUs). List PEPM comes from Term Monthly PBEs on the
    standard price book for the country currency. Falls back to demo USD×FX tables
    when a PBE is missing so the UI still renders.
    """
    country = (country or "US").upper()
    if country not in COUNTRY_CURRENCY:
        raise ValueError(f"Unsupported country {country!r}")
    currency = COUNTRY_CURRENCY[country]
    non_us = country in NON_US_COUNTRIES

    sku_in = "', '".join(CATALOG_ALL_SKUS)
    rows = session.soql(
        "SELECT Id, UnitPrice, CurrencyIsoCode, IsActive, "
        "Product2.Id, Product2.Name, Product2.StockKeepingUnit, Product2.IsActive "
        "FROM PricebookEntry "
        "WHERE Pricebook2.IsStandard = true "
        f"AND Product2.StockKeepingUnit IN ('{sku_in}') "
        f"AND CurrencyIsoCode = '{currency}' "
        "AND ProductSellingModel.SellingModelType = 'TermDefined' "
        "AND ProductSellingModel.PricingTermUnit = 'Months'"
    )
    by_sku: dict[str, dict[str, Any]] = {}
    for row in rows:
        product = row.get("Product2") or {}
        sku = product.get("StockKeepingUnit")
        if not sku or sku in by_sku:
            continue
        by_sku[sku] = row

    warnings: list[str] = []
    hydrated = 0
    fallback = 0

    def _entry(sku: str, fallback_usd: float, *, us_only: bool = False) -> dict[str, Any]:
        nonlocal hydrated, fallback
        row = by_sku.get(sku)
        sellable = not (us_only and non_us)
        if row:
            product = row.get("Product2") or {}
            active = bool(row.get("IsActive", True)) and bool(
                product.get("IsActive", True)
            )
            hydrated += 1
            return {
                "sku": sku,
                "name": _short_catalog_label(product.get("Name"), sku),
                "listPepm": round(float(row["UnitPrice"]), 2),
                "currency": currency,
                "available": sellable and active,
                "usOnly": us_only,
                "source": "pricebook",
                "pricebookEntryId": row.get("Id"),
                "product2Id": product.get("Id"),
            }
        fallback += 1
        warnings.append(f"No {currency} Term Monthly PBE for {sku}; using demo list.")
        return {
            "sku": sku,
            "name": _short_catalog_label(None, sku),
            "listPepm": round(fallback_usd * _fx(currency), 2),
            "currency": currency,
            "available": sellable,
            "usOnly": us_only,
            "source": "fallback",
            "pricebookEntryId": None,
            "product2Id": None,
        }

    plans = [
        _entry(sku, PLAN_LIST_USD[sku]) for sku in CATALOG_PLAN_SKUS
    ]
    addons = [
        _entry(
            sku,
            ADDON_LIST_USD[sku],
            us_only=sku in US_ONLY_ADDONS,
        )
        for sku in CATALOG_ADDON_SKUS
    ]
    core_flat = _entry(CORE_FLAT_SKU, CORE_FLAT_PRICE_USD)

    catalog_rows = session.soql(
        f"SELECT Id, Name FROM ProductCatalog WHERE Name = '{CATALOG_NAME}' LIMIT 1"
    )
    catalog_id = catalog_rows[0]["Id"] if catalog_rows else None

    return {
        "ok": True,
        "country": country,
        "currency": currency,
        "catalogName": CATALOG_NAME,
        "catalogId": catalog_id,
        "source": "pricebook" if fallback == 0 else ("mixed" if hydrated else "fallback"),
        "hydratedCount": hydrated,
        "fallbackCount": fallback,
        "plans": plans,
        "addons": addons,
        "coreFlat": {
            "sku": core_flat["sku"],
            "name": core_flat["name"],
            "listPrice": core_flat["listPepm"],  # flat is monthly total, not PEPM
            "currency": currency,
            "available": core_flat["available"],
            "source": core_flat["source"],
            "pricebookEntryId": core_flat["pricebookEntryId"],
            "product2Id": core_flat["product2Id"],
            "maxHeadcount": SMALL_BIZ_MAX_HEADCOUNT,
        },
        "warnings": warnings,
    }


PATH_B_BUNDLE_SAVE = 0.15  # ManualDiscount on Payroll+Benefits when Path B

# Phase 2 B2 — convert-later free trial (all plans + add-ons trialed with plan).
TRIAL_DAYS = 30


def resolve_subscription_window(
    *,
    start_date: date | None = None,
    term_months: int | None = None,
    free_trial: bool = False,
) -> tuple[date, date, int]:
    """Return (start, end, term_months) for Quote lines / Pricing API windows.

    Free trial still uses a TRIAL_DAYS end date; term_months is retained for
    convert-later paid quotes. term_months=1 is month-to-month (Term Monthly PSM
    window); 12/24/36 are committed terms with the same PEPM PBEs.
    """
    start = start_date or date.today()
    months = int(term_months if term_months is not None else DEFAULT_TERM_MONTHS)
    if months not in ALLOWED_TERM_MONTHS:
        raise ValueError(
            f"termMonths must be one of {', '.join(str(m) for m in ALLOWED_TERM_MONTHS)}"
        )
    if free_trial:
        end = start + timedelta(days=TRIAL_DAYS)
    else:
        end = add_calendar_months(start, months)
    return start, end, months


def _as_iso_date(value: date | datetime | str | None) -> date | None:
    """First 10 chars of an ISO datetime, or a date/datetime value."""
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


def commercial_term_from_window(
    start: date | datetime | str | None,
    end: date | datetime | str | None,
) -> dict[str, Any]:
    """Classify month-to-month vs 12/24/36 from an Asset/Quote lifecycle window.

    Get Pricing uses the same Term Monthly PBEs for every option; ``termMonths=1``
    is a 1-month window (month-to-month) and 12/24/36 are committed terms.
    Do **not** use ``Asset.RenewalTerm`` — that is the billing cadence (always
    1 Month on this catalog), not the commercial commitment.
    """
    start_d = _as_iso_date(start)
    end_d = _as_iso_date(end)
    empty = {
        "termMonths": None,
        "termKind": "unknown",
        "termLabel": "Term unknown",
        "termExact": False,
    }
    if start_d is None or end_d is None or end_d <= start_d:
        return empty

    def _payload(months: int, *, exact: bool) -> dict[str, Any]:
        if months <= 1:
            return {
                "termMonths": 1,
                "termKind": "month_to_month",
                "termLabel": "Month-to-month",
                "termExact": exact,
            }
        return {
            "termMonths": months,
            "termKind": "committed",
            "termLabel": f"{months}-month term",
            "termExact": exact,
        }

    for months in ALLOWED_TERM_MONTHS:
        expected = add_calendar_months(start_d, months)
        if end_d in (expected, expected - timedelta(days=1)):
            return _payload(months, exact=True)

    days = (end_d - start_d).days
    bands = (
        (1, 20, 45),
        (12, 330, 400),
        (24, 690, 780),
        (36, 1050, 1150),
    )
    for months, lo, hi in bands:
        if lo <= days <= hi:
            return _payload(months, exact=False)

    approx = max(1, round(days / 30.437))
    if approx <= 2:
        return _payload(1, exact=False)
    return {
        "termMonths": approx,
        "termKind": "committed",
        "termLabel": "Committed term",
        "termExact": False,
    }

# Demo volume ladder (bh-pricing PAT) — keep in sync with RLM_BambooVolumeTiers.
VOLUME_BANDS = (
    (25, 75, 0.05),
    (76, 150, 0.10),
    (151, 300, 0.15),
    (301, 500, 0.20),
    (501, None, 0.25),
)


class OrgSession:
    def __init__(self, alias: str | None = None) -> None:
        from auth import resolve_creds  # local package (server puts HERE on path)

        creds = resolve_creds(alias)
        self.alias = creds.label
        self.auth_mode = creds.mode
        self._token = creds.access_token
        self._instance = creds.instance_url

    def _http(
        self,
        method: str,
        path: str,
        body: dict | None = None,
        *,
        extra_headers: dict[str, str] | None = None,
    ) -> Any:
        data = json.dumps(body).encode() if body is not None else None
        headers = {
            "Authorization": f"Bearer {self._token}",
            "Accept": "application/json",
        }
        if body is not None:
            headers["Content-Type"] = "application/json"
        if extra_headers:
            headers.update(extra_headers)
        req = urllib.request.Request(
            f"{self._instance}{path}", data=data, headers=headers, method=method
        )
        try:
            with urllib.request.urlopen(req, timeout=180) as resp:
                raw = resp.read().decode()
        except urllib.error.HTTPError as exc:
            err = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"{method} {path} -> HTTP {exc.code}: {err[:2500]}") from exc
        return json.loads(raw) if raw.strip() else {}

    def soql(self, query: str) -> list[dict]:
        q = urllib.parse.quote(query)
        return self._http("GET", f"/services/data/{API}/query?q={q}").get("records") or []

    def create(self, sobject: str, fields: dict) -> str:
        # Demo orgs often have Standard_* Duplicate Rules with allowSave=true.
        # Without the header, REST create returns DUPLICATES_DETECTED even for
        # intentionally unique self-serve buyers (fuzzy name match).
        result = self._http(
            "POST",
            f"/services/data/{API}/sobjects/{sobject}",
            fields,
            extra_headers={"Sforce-Duplicate-Rule-Header": "allowSave=true"},
        )
        rid = result.get("id")
        if not rid:
            raise RuntimeError(f"Create {sobject} failed: {result}")
        return rid

    def patch(self, sobject: str, record_id: str, fields: dict) -> None:
        self._http(
            "PATCH", f"/services/data/{API}/sobjects/{sobject}/{record_id}", fields
        )

    def delete(self, sobject: str, record_id: str) -> None:
        self._http("DELETE", f"/services/data/{API}/sobjects/{sobject}/{record_id}")

    def post(self, path: str, body: dict) -> Any:
        return self._http("POST", path, body)

    def get_bytes(self, path: str) -> bytes:
        """GET a binary resource (e.g. ContentVersion VersionData)."""
        req = urllib.request.Request(
            f"{self._instance}{path}",
            headers={
                "Authorization": f"Bearer {self._token}",
                "Accept": "*/*",
            },
            method="GET",
        )
        try:
            with urllib.request.urlopen(req, timeout=180) as resp:
                return resp.read()
        except urllib.error.HTTPError as exc:
            err = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"GET {path} -> HTTP {exc.code}: {err[:2500]}") from exc


def volume_rate(headcount: int) -> float:
    if headcount < 25:
        return 0.0
    for lower, upper, rate in VOLUME_BANDS:
        if headcount >= lower and (upper is None or headcount <= upper):
            return rate
    return 0.0


def expected_net(plan_sku: str, headcount: int, currency: str = "USD") -> float:
    list_price = plan_list_price(plan_sku, currency)
    return round(list_price * (1.0 - volume_rate(headcount)), 2)


def expected_addon_net(
    addon_sku: str,
    *,
    path_b: bool,
    currency: str = "USD",
    headcount: int = 0,
) -> float:
    """Path B Bundle & Save (if eligible) on ListPrice, then volume by headcount."""
    list_price = addon_list_price(addon_sku, currency)
    price = list_price
    if path_b and addon_sku in US_ONLY_ADDONS:
        price *= 1.0 - PATH_B_BUNDLE_SAVE
    if headcount:
        price *= 1.0 - volume_rate(headcount)
    return round(price, 2)


def line_item_dict(
    *,
    sku: str,
    name: str,
    quantity: int,
    list_pepm: float | None,
    net_pepm: float,
    monthly: float,
    is_plan: bool,
    path_b: bool,
    volume_percent: float,
) -> dict[str, Any]:
    """Line with explicit list → Bundle & Save → volume → net waterfall fields."""
    bundle_pct = (
        PATH_B_BUNDLE_SAVE * 100.0
        if path_b and not is_plan and sku in US_ONLY_ADDONS
        else 0.0
    )
    after_bundle: float | None = None
    if list_pepm is not None:
        after_bundle = round(list_pepm * (1.0 - bundle_pct / 100.0), 2)
    return {
        "sku": sku,
        "name": name,
        "quantity": quantity,
        "listPepm": list_pepm,
        "bundleSavePercent": bundle_pct,
        "afterBundlePepm": after_bundle,
        "volumePercent": volume_percent,
        "netPepm": net_pepm,
        "monthly": monthly,
        "isPlan": is_plan,
    }


def normalize_addons(raw: list[str] | None) -> list[str]:
    out: list[str] = []
    for sku in raw or []:
        s = str(sku or "").upper().strip()
        if not s:
            continue
        if s not in ADDON_LIST:
            raise ValueError(f"Unsupported add-on {s!r}")
        if s not in out:
            out.append(s)
    return out


@dataclass
class BuyerInfo:
    """Self-serve buyer from the Get Pricing qualify wizard + rail."""

    company: str = ""
    first_name: str = ""
    last_name: str = ""
    email: str = ""
    phone: str = ""
    job_title: str = ""
    needs: list[str] = field(default_factory=list)
    dm_role: str = ""
    campaign: str = ""
    session_id: str = ""

    @classmethod
    def from_mapping(cls, raw: dict[str, Any] | None) -> "BuyerInfo":
        raw = raw or {}
        needs = raw.get("needs") or []
        if isinstance(needs, str):
            needs = [s.strip() for s in needs.split(",") if s.strip()]
        utm = raw.get("utm") if isinstance(raw.get("utm"), dict) else {}
        campaign = str(raw.get("campaign") or campaign_from_utm(utm) or "").strip()
        return cls(
            company=str(raw.get("company") or raw.get("accountName") or "").strip(),
            first_name=str(raw.get("firstName") or raw.get("first_name") or "").strip(),
            last_name=str(raw.get("lastName") or raw.get("last_name") or "").strip(),
            email=str(raw.get("email") or "").strip(),
            phone=str(raw.get("phone") or "").strip(),
            job_title=str(
                raw.get("jobTitle") or raw.get("job_title") or ""
            ).strip(),
            needs=[str(n) for n in needs if n],
            dm_role=str(raw.get("dmRole") or raw.get("decisionMakerRole") or "").strip(),
            campaign=campaign,
            session_id=str(raw.get("sessionId") or raw.get("qualifySessionId") or "").strip(),
        )

    @classmethod
    def from_request(cls, body: dict[str, Any] | None) -> "BuyerInfo":
        """Merge top-level wizard fields into ``buyer`` (UI nests; API often doesn't)."""
        body = body if isinstance(body, dict) else {}
        buyer_raw = (
            dict(body["buyer"]) if isinstance(body.get("buyer"), dict) else {}
        )
        for key in (
            "needs",
            "dmRole",
            "decisionMakerRole",
            "utm",
            "campaign",
            "sessionId",
            "qualifySessionId",
            "email",
            "company",
            "accountName",
            "firstName",
            "lastName",
            "first_name",
            "last_name",
            "phone",
            "jobTitle",
            "job_title",
        ):
            if buyer_raw.get(key) in (None, "", []):
                top = body.get(key)
                if top not in (None, "", []):
                    buyer_raw[key] = top
        if not buyer_raw:
            buyer_raw = dict(body)
        return cls.from_mapping(buyer_raw)

    @property
    def has_new_customer(self) -> bool:
        return bool(self.company and self.email)


@dataclass
class GetPricingRequest:
    headcount: int
    country: str
    plan_sku: str = "BAMBOO-PRO"
    addon_skus: list[str] = field(default_factory=list)
    place_quote: bool = True
    free_trial: bool = False
    buyer: BuyerInfo | None = None
    # Pin an existing Account (convert-later / returning flows).
    account_id: str | None = None
    # Sticky Draft from /api/get-pricing-preview — promote when config matches.
    preview_quote_id: str | None = None
    # Buyer-selected commercial term (defaults: start=today, month-to-month).
    start_date: date | None = None
    term_months: int = DEFAULT_TERM_MONTHS


@dataclass
class GetPricingResult:
    ok: bool
    country: str
    account_name: str
    account_id: str
    plan_sku: str
    plan_name: str
    headcount: int
    list_pepm: float
    volume_percent: float
    net_pepm: float
    monthly_total: float
    annual_total: float
    discovered_skus: list[str]
    warnings: list[str]
    quote_id: str | None
    org_alias: str
    addon_skus: list[str] = field(default_factory=list)
    line_items: list[dict[str, Any]] = field(default_factory=list)
    path_b_bundle_save: bool = False
    small_biz_flat: bool = False
    sell_plan_sku: str = ""
    free_trial: bool = False
    trial_days: int = 0
    paid_monthly_estimate: float | None = None
    paid_line_items: list[dict[str, Any]] = field(default_factory=list)
    currency: str = "USD"
    error: str | None = None
    contact_id: str | None = None
    contact_name: str = ""
    contact_email: str = ""
    account_created: bool = False
    contact_created: bool = False
    start_date: str | None = None
    end_date: str | None = None
    term_months: int = DEFAULT_TERM_MONTHS
    term_total: float | None = None

    def as_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "country": self.country,
            "accountName": self.account_name,
            "accountId": self.account_id,
            "accountCreated": self.account_created,
            "contactId": self.contact_id,
            "contactName": self.contact_name,
            "contactEmail": self.contact_email,
            "contactCreated": self.contact_created,
            "planSku": self.plan_sku,
            "planName": self.plan_name,
            "sellPlanSku": self.sell_plan_sku or self.plan_sku,
            "smallBizFlat": self.small_biz_flat,
            "freeTrial": self.free_trial,
            "trialDays": self.trial_days,
            "paidMonthlyEstimate": self.paid_monthly_estimate,
            "paidLineItems": self.paid_line_items,
            "headcount": self.headcount,
            "listPepm": self.list_pepm,
            "volumePercent": self.volume_percent,
            "netPepm": self.net_pepm,
            "monthlyTotal": self.monthly_total,
            "annualTotal": self.annual_total,
            "startDate": self.start_date,
            "endDate": self.end_date,
            "termMonths": self.term_months,
            "termTotal": self.term_total,
            "discoveredSkus": self.discovered_skus,
            "addonSkus": self.addon_skus,
            "lineItems": self.line_items,
            "pathBBundleSave": self.path_b_bundle_save,
            "warnings": self.warnings,
            "quoteId": self.quote_id,
            "orgAlias": self.org_alias,
            "error": self.error,
            "currency": self.currency,
        }


def _soql_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace("'", "\\'")


def lightning_record_url(instance_url: str, entity: str, record_id: str | None) -> str:
    """Lightning record deep link (empty string when id missing)."""
    base = (instance_url or "").rstrip("/")
    rid = (record_id or "").strip()
    if not base or not rid:
        return ""
    return f"{base}/lightning/r/{entity}/{rid}/view"


def quote_related_ids(session: OrgSession, quote_id: str) -> dict[str, str]:
    """Return OpportunityId / QuoteAccountId for a Quote when present."""
    qid = (quote_id or "").strip()
    if not qid:
        return {}
    rows = session.soql(
        "SELECT Id, OpportunityId, QuoteAccountId "
        f"FROM Quote WHERE Id = '{_soql_escape(qid)}' LIMIT 1"
    )
    if not rows:
        return {}
    r = rows[0]
    out: dict[str, str] = {}
    if r.get("OpportunityId"):
        out["opportunityId"] = r["OpportunityId"]
    if r.get("QuoteAccountId"):
        out["accountId"] = r["QuoteAccountId"]
    return out


def resolve_buyer_account(
    session: OrgSession,
    country: str,
    buyer: BuyerInfo | None,
    *,
    currency: str,
    account_id: str | None = None,
    self_serve: bool = False,
    contact_description: str | None = None,
) -> tuple[dict[str, Any], str | None, dict[str, Any]]:
    """Return (account, contact_id, meta) for quote placement.

    Workshop: match Contact by email and **update** — never insert a Lead.
    New Account/Contact only when there is no match.

    ``self_serve=True`` stamps SelfServe on Account **insert** (before Contact
    create) so ``RLM_Bamboo_SelfServe_Contact_Gate`` sees it and skips the
    SDR Task. Jeff ~01:59: the record has to exist so we can mark sales
    don't touch — that is beat 5, not Get your quote.
    """
    meta = {
        "accountCreated": False,
        "contactCreated": False,
        "contactUpdated": False,
        "contactName": "",
        "contactEmail": "",
        "usedDemoAccount": False,
    }
    buyer = buyer or BuyerInfo()

    if account_id:
        acct_rows = session.soql(
            "SELECT Id, Name, BillingCountry FROM Account "
            f"WHERE Id = '{_soql_escape(account_id)}' LIMIT 1"
        )
        if not acct_rows:
            raise ValueError(f"Account {account_id} not found")
        acct = acct_rows[0]
        contact_id = None
        if buyer.email:
            crows = session.soql(
                "SELECT Id, FirstName, LastName, Email FROM Contact "
                f"WHERE AccountId = '{acct['Id']}' AND Email = "
                f"'{_soql_escape(buyer.email)}' LIMIT 1"
            )
            if crows:
                contact_id = crows[0]["Id"]
                meta["contactName"] = (
                    f"{crows[0].get('FirstName') or ''} "
                    f"{crows[0].get('LastName') or ''}"
                ).strip()
                meta["contactEmail"] = crows[0].get("Email") or buyer.email
        if not contact_id:
            any_c = session.soql(
                "SELECT Id, FirstName, LastName, Email FROM Contact "
                f"WHERE AccountId = '{acct['Id']}' LIMIT 1"
            )
            if any_c:
                contact_id = any_c[0]["Id"]
                meta["contactName"] = (
                    f"{any_c[0].get('FirstName') or ''} "
                    f"{any_c[0].get('LastName') or ''}"
                ).strip()
                meta["contactEmail"] = any_c[0].get("Email") or ""
        return acct, contact_id, meta

    if not buyer.has_new_customer:
        demo_name = COUNTRY_ACCOUNT[country]
        acct = session.soql(
            "SELECT Id, Name, BillingCountry FROM Account "
            f"WHERE Name = '{_soql_escape(demo_name)}' LIMIT 1"
        )[0]
        meta["usedDemoAccount"] = True
        meta["contactEmail"] = buyer.email
        return acct, None, meta

    billing = COUNTRY_BILLING[country]
    ship = dict(COUNTRY_SHIPPING[country])
    contact_id: str | None = None

    # Prefer existing Contact by email (returning buyer without portal login).
    if buyer.email:
        existing = session.soql(
            "SELECT Id, AccountId, FirstName, LastName, Email FROM Contact "
            f"WHERE Email = '{_soql_escape(buyer.email)}' LIMIT 1"
        )
        if existing and existing[0].get("AccountId"):
            c = existing[0]
            acct = session.soql(
                "SELECT Id, Name, BillingCountry FROM Account "
                f"WHERE Id = '{c['AccountId']}' LIMIT 1"
            )[0]
            contact_id = c["Id"]
            meta["contactName"] = (
                f"{c.get('FirstName') or ''} {c.get('LastName') or ''}".strip()
            )
            meta["contactEmail"] = c.get("Email") or buyer.email
            patch_c: dict[str, Any] = {}
            if buyer.first_name:
                patch_c["FirstName"] = buyer.first_name[:40]
            if buyer.last_name:
                patch_c["LastName"] = buyer.last_name[:80]
            meta["contactUpdated"] = True
            if patch_c:
                session.patch("Contact", contact_id, patch_c)
                meta["contactName"] = (
                    f"{buyer.first_name or c.get('FirstName') or ''} "
                    f"{buyer.last_name or c.get('LastName') or ''}"
                ).strip()
            # Keep shipping usable for checkout if account was incomplete.
            if not session.soql(
                "SELECT ShippingCity FROM Account "
                f"WHERE Id = '{acct['Id']}' AND ShippingCity != null LIMIT 1"
            ):
                session.patch("Account", acct["Id"], ship)
            return acct, contact_id, meta

    # Reuse Account with same Name when present; else create.
    by_name = session.soql(
        "SELECT Id, Name, BillingCountry FROM Account "
        f"WHERE Name = '{_soql_escape(buyer.company)}' LIMIT 1"
    )
    if by_name:
        acct = by_name[0]
    else:
        acct_fields: dict[str, Any] = {
            "Name": buyer.company[:255],
            "CurrencyIsoCode": currency,
            # Marker for cleanup_demo_data.py --preset ephemeral (age-gated).
            "Description": "[bamboohr-ephemeral] Created by Get Pricing self-service",
            **ship,
        }
        # BillingCountry already in ship; ensure country code matches selector.
        acct_fields["BillingCountry"] = billing
        acct_fields["ShippingCountry"] = billing if country != "UK" else "GB"
        if self_serve:
            # Stamp on insert so the Contact-gate Flow sees SelfServe=true
            # and does not create an SDR Task (workshop suppress).
            acct_fields["RLM_Bamboo_SelfServe__c"] = True
            acct_fields["AccountSource"] = "SelfServe_Micro"
        try:
            acct_id = session.create("Account", acct_fields)
        except Exception:
            acct_fields.pop("RLM_Bamboo_SelfServe__c", None)
            acct_id = session.create("Account", acct_fields)
        acct = {"Id": acct_id, "Name": buyer.company, "BillingCountry": billing}
        meta["accountCreated"] = True

    last = buyer.last_name or buyer.company or "Buyer"
    first = buyer.first_name or "New"
    c_fields: dict[str, Any] = {
        "AccountId": acct["Id"],
        "FirstName": first[:40],
        "LastName": last[:80],
        "Email": buyer.email,
        "CurrencyIsoCode": currency,
    }
    if buyer.phone:
        c_fields["Phone"] = buyer.phone[:40]
    if buyer.job_title:
        c_fields["Title"] = buyer.job_title[:128]
    if contact_description:
        c_fields["Description"] = contact_description[:32000]
    if self_serve:
        c_fields["LeadSource"] = "SelfServe_Micro"
        # Custom Do Not Call — standard Contact.DoNotCall is missing on some demo orgs.
        c_fields["RLM_Bamboo_DoNotCall__c"] = True
    try:
        contact_id = session.create("Contact", c_fields)
    except Exception:
        c_fields.pop("RLM_Bamboo_DoNotCall__c", None)
        contact_id = session.create("Contact", c_fields)
    meta["contactCreated"] = True
    meta["contactName"] = f"{first} {last}".strip()
    meta["contactEmail"] = buyer.email
    return acct, contact_id, meta


def commit_qualify_identity(
    session: OrgSession,
    *,
    buyer: BuyerInfo,
    headcount: int,
    country: str,
) -> dict[str, Any]:
    """Create/update Account+Contact at beat 5 — no Quote yet.

    Rationale (Jeff Cullimore ~01:59, N 219 ~00:39): *it has to exist so we
    can mark it sales don't touch.* Create-account is the moment they stayed
    on self-serve, not Get your quote. Abandoned-after-recommend must still
    appear on the do-not-call list.
    """
    if not buyer.has_new_customer:
        return {
            "ok": False,
            "error": "Company and work email are required to create your account.",
        }
    country = (country or "US").upper().strip()
    if country not in COUNTRY_ACCOUNT:
        country = "US"
    currency = COUNTRY_CURRENCY[country]
    looked = lookup_email(session, buyer.email)
    if looked.get("status") in (STATUS_SALES_WORKING, STATUS_EXISTING_CUSTOMER):
        raise DualMotionBlocked(looked)
    acct, contact_id, meta = resolve_buyer_account(
        session,
        country,
        buyer,
        currency=currency,
        self_serve=True,
    )
    warnings: list[str] = []
    if acct.get("Id"):
        warnings.extend(
            stamp_self_serve(
                session,
                account_id=acct["Id"],
                contact_id=contact_id,
                headcount=headcount,
                needs=buyer.needs,
                dm_role=buyer.dm_role,
                campaign=buyer.campaign,
            )
        )
    # Lead-only email match: update existing Lead — never insert / never convert.
    lead_id, lead_warn = update_existing_lead(
        session,
        email=buyer.email,
        company=buyer.company,
        first_name=buyer.first_name,
        last_name=buyer.last_name,
        campaign=buyer.campaign,
        description=(
            "Self-serve qualify commit — buyer stayed on micro path. "
            f"HC={headcount} needs={', '.join(buyer.needs or []) or '—'}."
        ),
        status="Working",
    )
    warnings.extend(lead_warn)
    return {
        "ok": True,
        "status": STATUS_SELF_SERVE,
        "reason": "Account created in Salesforce. Sales will not call — you're on self-serve.",
        "accountId": acct.get("Id"),
        "contactId": contact_id,
        "accountCreated": bool(meta.get("accountCreated")),
        "contactCreated": bool(meta.get("contactCreated")),
        "contactUpdated": bool(meta.get("contactUpdated")),
        "leadId": lead_id,
        "warnings": warnings,
    }


def handoff_qualify_to_sales(
    session: OrgSession,
    *,
    buyer: BuyerInfo,
    headcount: int | None,
    country: str,
    bounce_reason: str,
    bounce_type: str,
) -> dict[str, Any]:
    """Upsert Contact/Account for a wizard bounce — never SelfServe.

    Rationale (N 219 ~00:39): Payroll / ≥25 / non-US-CA means *qualified to
    talk to a person*, not discarded. SDRs take complex leads. Existing
    customers still sign in; sales-working Accounts stay with the AE.
    """
    if not buyer.email or not buyer.company:
        return {
            "ok": False,
            "needsEmail": True,
            "error": "Work email and company let us connect you with a person.",
        }
    country_key = (country or "US").upper().strip()
    if country_key not in COUNTRY_ACCOUNT:
        country_key = "US"
    currency = COUNTRY_CURRENCY[country_key]
    looked = lookup_email(session, buyer.email)
    if looked.get("status") == STATUS_EXISTING_CUSTOMER:
        return {**looked, "handoff": False}
    already_working = looked.get("status") == STATUS_SALES_WORKING
    brief = format_handoff_brief(
        bounce_reason=bounce_reason or "Qualified to talk to a person.",
        bounce_type=bounce_type or "",
        headcount=headcount,
        country=country or country_key,
        needs=buyer.needs,
        dm_role=buyer.dm_role,
        company=buyer.company,
        email=buyer.email,
    )
    acct, contact_id, meta = resolve_buyer_account(
        session,
        country_key,
        buyer,
        currency=currency,
        self_serve=False,
        contact_description=brief,
    )
    warnings: list[str] = []
    if acct.get("Id"):
        # Durable dual-motion: bounced Accounts are sales-working even with
        # no open Quote (Fadi Account-without-Quote + Payroll/size/geo gates).
        warnings.extend(
            stamp_sales_handoff(
                session,
                account_id=acct["Id"],
                bounce_type=bounce_type,
                headcount=headcount,
                needs=buyer.needs,
                contact_id=contact_id,
                dm_role=buyer.dm_role,
                campaign=buyer.campaign,
            )
        )
    if contact_id and not meta.get("contactCreated"):
        warnings.extend(
            _safe_patch(session, "Contact", contact_id, {"Description": brief[:32000]})
        )
    lead_id, lead_warn = update_existing_lead(
        session,
        email=buyer.email,
        company=buyer.company,
        first_name=buyer.first_name,
        last_name=buyer.last_name,
        campaign=buyer.campaign,
        description=brief,
        status="Working",
    )
    warnings.extend(lead_warn)
    task_id = None
    if acct.get("Id"):
        subject = f"Qualified to talk to a person ({bounce_type or 'handoff'})"[:80]
        task_fields: dict[str, Any] = {
            "Subject": subject,
            "Description": brief,
            "Status": "Not Started",
            "Priority": "Normal",
            "WhatId": acct["Id"],
        }
        if contact_id:
            task_fields["WhoId"] = contact_id
        existing = find_open_handoff_task(
            session, contact_id=contact_id, account_id=acct["Id"]
        )
        try:
            if existing:
                # Refresh brief on the open Task — do not create a duplicate.
                session.patch(
                    "Task",
                    existing,
                    {
                        "Subject": subject,
                        "Description": brief,
                        "Status": "Not Started",
                    },
                )
                task_id = existing
            else:
                task_id = session.create("Task", task_fields)
        except Exception as exc:  # noqa: BLE001
            warnings.append(f"Sales Task skipped: {str(exc)[:240]}")
    return {
        "ok": True,
        "handoff": True,
        "status": STATUS_SALES_WORKING,
        "alreadyWorking": already_working,
        "accountId": acct.get("Id"),
        "contactId": contact_id,
        "leadId": lead_id,
        "taskId": task_id,
        "accountCreated": bool(meta.get("accountCreated")),
        "contactCreated": bool(meta.get("contactCreated")),
        "warnings": warnings,
        "reason": bounce_reason or "Qualified to talk to a person.",
    }


def _pbe_for_sku(session: OrgSession, sku: str, currency: str = "USD") -> dict:
    rows = session.soql(
        "SELECT Id, Product2Id, UnitPrice, CurrencyIsoCode, ProductSellingModelId "
        "FROM PricebookEntry "
        "WHERE Pricebook2.IsStandard = true "
        f"AND Product2.StockKeepingUnit = '{sku}' "
        f"AND CurrencyIsoCode = '{currency}' "
        "AND ProductSellingModel.SellingModelType = 'TermDefined' "
        "AND ProductSellingModel.PricingTermUnit = 'Months' LIMIT 1"
    )
    if not rows:
        raise RuntimeError(f"No Term Monthly {currency} PBE for {sku}")
    return rows[0]


def sync_quote_to_opportunity(
    session: OrgSession,
    quote_id: str,
    opportunity_id: str | None = None,
) -> bool:
    """Start Quote→Opportunity sync (same effect as UI **Start Sync**).

    Sets ``Opportunity.SyncedQuoteId`` so Opportunity Amount / products stay
    aligned with the Quote after place + reprice. When Amount is still blank
    after sync (seen with some term-defined-only carts), copies
    ``Quote.TotalPrice`` onto ``Opportunity.Amount`` as a display fallback.
    """
    qid = (quote_id or "").strip()
    if not qid:
        return False
    opp_id = (opportunity_id or "").strip() or None
    if not opp_id:
        rows = session.soql(
            "SELECT OpportunityId FROM Quote "
            f"WHERE Id = '{_soql_escape(qid)}' LIMIT 1"
        )
        opp_id = (rows[0].get("OpportunityId") if rows else None) or None
    if not opp_id:
        return False

    synced = False
    try:
        opp_rows = session.soql(
            "SELECT Id, Amount, SyncedQuoteId FROM Opportunity "
            f"WHERE Id = '{_soql_escape(opp_id)}' LIMIT 1"
        )
        current = (opp_rows[0].get("SyncedQuoteId") if opp_rows else None) or None
        if current != qid:
            session.patch("Opportunity", opp_id, {"SyncedQuoteId": qid})
        synced = True
    except Exception:
        synced = False

    try:
        qrows = session.soql(
            "SELECT TotalPrice, GrandTotal FROM Quote "
            f"WHERE Id = '{_soql_escape(qid)}' LIMIT 1"
        )
        total = None
        if qrows:
            raw = qrows[0].get("GrandTotal")
            if raw is None:
                raw = qrows[0].get("TotalPrice")
            if raw is not None:
                total = float(raw)
        if total is None:
            return synced
        opp_rows = session.soql(
            "SELECT Amount FROM Opportunity "
            f"WHERE Id = '{_soql_escape(opp_id)}' LIMIT 1"
        )
        amount = opp_rows[0].get("Amount") if opp_rows else None
        if amount is None:
            try:
                session.patch("Opportunity", opp_id, {"Amount": round(total, 2)})
            except Exception:
                pass
    except Exception:
        pass
    return synced


def _system_reprice_quote(
    session: OrgSession,
    quote_id: str,
    *,
    quantity_by_sku: dict[str, int] | None = None,
) -> None:
    """PST System reprice so volume + Path B ManualDiscount persist on lines.

    Optional ``quantity_by_sku`` patches Quantity in the same place graph —
    used by sticky preview for headcount-only changes (avoids a separate
    DELETE+POST Skip place).
    """
    lines = session.soql(
        "SELECT Id, Quantity, Product2.StockKeepingUnit "
        f"FROM QuoteLineItem WHERE QuoteId = '{quote_id}'"
    )
    if not lines:
        raise RuntimeError(f"Quote {quote_id} has no lines to reprice")
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
        sku = ((line.get("Product2") or {}).get("StockKeepingUnit") or "").upper()
        qty = line.get("Quantity") or 1
        if quantity_by_sku and sku in quantity_by_sku:
            qty = quantity_by_sku[sku]
        records.append(
            {
                "referenceId": f"refL{i}",
                "record": {
                    "attributes": {
                        "type": "QuoteLineItem",
                        "method": "PATCH",
                        "id": line["Id"],
                    },
                    "Quantity": str(int(qty)),
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
                "graphId": f"gprp{uuid.uuid4().hex[:8]}",
                "records": records,
            },
        },
    )
    if isinstance(placed, list):
        placed = placed[0]
    if not placed.get("isSuccess"):
        raise RuntimeError(f"System reprice failed: {placed}")


def _custom_price_quote(
    session: OrgSession,
    quote_id: str,
    by_sku: dict[str, tuple[int, float, float]],
) -> None:
    """Persist native-currency UnitPrice/NetUnitPrice via PST Force.

    System reprice on non-USD quotes can write corporate-USD amounts onto
    CAD/GBP lines after volume (PBE stays correct; UnitPrice becomes USD).
    Force place stamps the local-currency list/net we already computed.
    """
    lines = session.soql(
        "SELECT Id, Quantity, Product2.StockKeepingUnit "
        f"FROM QuoteLineItem WHERE QuoteId = '{quote_id}'"
    )
    if not lines:
        raise RuntimeError(f"Quote {quote_id} has no lines for custom price")
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
        sku = (line.get("Product2") or {}).get("StockKeepingUnit") or ""
        if sku not in by_sku:
            continue
        qty, list_price, _net_price = by_sku[sku]
        records.append(
            {
                "referenceId": f"refL{i}",
                "record": {
                    "attributes": {
                        "type": "QuoteLineItem",
                        "method": "PATCH",
                        "id": line["Id"],
                    },
                    "Quantity": str(qty),
                    # NetUnitPrice is not API-writable. Stamp native list;
                    # Force re-applies volume in quote currency → correct net.
                    "UnitPrice": list_price,
                },
            }
        )
    if len(records) < 2:
        raise RuntimeError(f"No matching lines to custom-price on {quote_id}")
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
                "graphId": f"gpfc{uuid.uuid4().hex[:8]}",
                "records": records,
            },
        },
    )
    if isinstance(placed, list):
        placed = placed[0]
    if not placed.get("isSuccess"):
        raise RuntimeError(f"Force currency reprice failed: {placed}")


def get_pricing(session: OrgSession, req: GetPricingRequest) -> GetPricingResult:
    warnings: list[str] = []
    country = (req.country or "US").upper().strip()
    if country not in COUNTRY_ACCOUNT:
        raise ValueError(f"Unsupported country {country!r}; use US, CA, or UK")
    currency = COUNTRY_CURRENCY[country]
    plan_sku = (req.plan_sku or "BAMBOO-PRO").upper()
    if plan_sku not in PLAN_LIST:
        raise ValueError(f"Unsupported plan {plan_sku!r}")
    if req.headcount < 1 or req.headcount > 100000:
        raise ValueError("headcount must be between 1 and 100000")

    start_day, end_day, term_months = resolve_subscription_window(
        start_date=req.start_date,
        term_months=req.term_months,
        free_trial=bool(req.free_trial),
    )
    start_iso = start_day.isoformat()
    end_iso = end_day.isoformat()

    addon_skus = normalize_addons(req.addon_skus)
    if country in NON_US_COUNTRIES:
        label = "Canada" if country == "CA" else "United Kingdom"
        warnings.append(
            f"{label}: Payroll and Benefits are hidden via category disqualification. "
            "Plans and other add-ons remain available."
        )
        blocked = [s for s in addon_skus if s in US_ONLY_ADDONS]
        if blocked:
            warnings.append(
                f"Removed US-only add-ons for {label}: "
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

    use_flat = uses_core_flat(plan_sku, req.headcount)
    sell_plan_sku = CORE_FLAT_SKU if use_flat else plan_sku
    plan_qty = 1 if use_flat else req.headcount
    flat_list = core_flat_price(currency)
    if use_flat:
        warnings.append(
            f"Small-business flat: Core @ ≤{SMALL_BIZ_MAX_HEADCOUNT} employees uses "
            f"{CORE_FLAT_SKU} at {currency} {flat_list:.2f}/mo (qty 1), not PEPM×headcount."
        )
    if currency != "USD":
        warnings.append(
            f"Multi-currency: quoting in {currency} (demo FX vs USD: "
            f"×{CURRENCY_FX[currency]:.2f})."
        )

    free_trial = bool(req.free_trial)
    if free_trial:
        warnings.append(
            f"Free trial (convert later): {TRIAL_DAYS}-day term at $0 for plan + "
            "selected add-ons. Convert later by placing a paid quote (same config, "
            "trial off)."
        )

    catalog = session.soql(
        f"SELECT Id FROM ProductCatalog WHERE Name = '{CATALOG_NAME}' LIMIT 1"
    )[0]
    buyer = req.buyer or BuyerInfo()
    if buyer.email:
        looked = lookup_email(session, buyer.email)
        if looked.get("status") in (STATUS_SALES_WORKING, STATUS_EXISTING_CUSTOMER):
            raise DualMotionBlocked(looked)
    acct, contact_id, buyer_meta = resolve_buyer_account(
        session,
        country,
        req.buyer,
        currency=currency,
        account_id=req.account_id,
        self_serve=bool(buyer.has_new_customer),
    )
    if buyer.has_new_customer and acct.get("Id"):
        stamp_warn = stamp_self_serve(
            session,
            account_id=acct["Id"],
            contact_id=contact_id,
            headcount=req.headcount,
            needs=buyer.needs,
            dm_role=buyer.dm_role,
            campaign=buyer.campaign,
        )
        warnings.extend(stamp_warn)
        if buyer.session_id:
            mark_qualify_complete(buyer.session_id)
    account_name = acct.get("Name") or COUNTRY_ACCOUNT[country]
    if buyer_meta.get("usedDemoAccount"):
        warnings.append(
            "Using seeded demo Account "
            f"({account_name}). Submit company + work email on Get Pricing "
            "to create a new customer Account and Contact in Salesforce."
        )
    elif buyer_meta.get("accountCreated"):
        warnings.append(
            f"Created new Account “{account_name}” in Salesforce for this quote."
        )
    if buyer_meta.get("contactCreated"):
        warnings.append(
            f"Created Contact {buyer_meta.get('contactName') or ''} "
            f"<{buyer_meta.get('contactEmail')}> on that Account."
        )
    elif buyer_meta.get("contactUpdated"):
        warnings.append(
            f"Updated existing Contact {buyer_meta.get('contactName') or ''} "
            f"<{buyer_meta.get('contactEmail')}> — no Lead created."
        )
    pb = session.soql("SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1")[0]

    skus_needed = [sell_plan_sku, *addon_skus]
    pbes = {sku: _pbe_for_sku(session, sku, currency) for sku in skus_needed}

    # Discover
    payload = session.post(
        f"/services/data/{API}/connect/pcm/products",
        {"catalogIds": [catalog["Id"]], "searchTerm": "Bamboo", "pageSize": 50},
    )
    products = payload.get("products") or payload.get("records") or []
    discovered: list[str] = []
    for p in products:
        sku = (
            p.get("stockKeepingUnit")
            or p.get("productCode")
            or (p.get("product") or {}).get("stockKeepingUnit")
        )
        if sku:
            discovered.append(sku)
    if sell_plan_sku not in discovered and plan_sku not in discovered:
        warnings.append(
            f"{sell_plan_sku} / {plan_sku} not in PCM search results — check search index."
        )

    list_pepm = flat_list if use_flat else plan_list_price(plan_sku, currency)
    vol = 0.0 if use_flat else volume_rate(req.headcount)
    expected_plan_paid = (
        flat_list if use_flat else expected_net(plan_sku, req.headcount, currency)
    )
    # Paid estimate (what convert-later charges) — always computed for UI.
    plan_name_paid = (
        "BambooHR Core Small Business Flat" if use_flat else PLAN_LABELS[plan_sku]
    )
    vol_pct = round(vol * 100, 1)
    paid_line_items: list[dict[str, Any]] = [
        line_item_dict(
            sku=sell_plan_sku,
            name=plan_name_paid,
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
            sku, path_b=path_b, currency=currency, headcount=req.headcount
        )
        addon_monthly = round(addon_net * req.headcount, 2)
        paid_monthly = round(paid_monthly + addon_monthly, 2)
        paid_line_items.append(
            line_item_dict(
                sku=sku,
                name=ADDON_LABELS[sku],
                quantity=req.headcount,
                list_pepm=addon_list_price(sku, currency),
                net_pepm=addon_net,
                monthly=addon_monthly,
                is_plan=False,
                path_b=path_b,
                volume_percent=vol_pct,
            )
        )

    expected_plan = 0.0 if free_trial else expected_plan_paid
    quote_id: str | None = None
    net_pepm = expected_plan
    line_items: list[dict[str, Any]] = []
    path_b_flag = False
    trial_flag = False
    monthly = 0.0 if free_trial else round(expected_plan_paid * plan_qty, 2)

    # Phase 3: promote sticky preview Quote when Account + config match.
    if req.place_quote and req.preview_quote_id:
        try:
            from pricing_preview import discard_preview_quote, promote_preview_quote

            promoted = promote_preview_quote(
                session,
                req.preview_quote_id,
                headcount=req.headcount,
                country=country,
                plan_sku=plan_sku,
                addon_skus=addon_skus,
                free_trial=free_trial,
                account_id=acct["Id"],
            )
            if promoted:
                quote_id = promoted["quoteId"]
                line_items = list(promoted.get("lineItems") or [])
                monthly = float(promoted.get("monthlyTotal") or 0)
                net_pepm = float(promoted.get("netPepm") or 0)
                path_b_flag = bool(promoted.get("pathBBundleSave"))
                trial_flag = bool(promoted.get("freeTrial"))
                use_flat = bool(promoted.get("smallBizFlat"))
                sell_plan_sku = promoted.get("sellPlanSku") or sell_plan_sku
                list_pepm = float(promoted.get("listPepm") or list_pepm)
                vol_pct = float(promoted.get("volumePercent") or vol_pct)
                vol = vol_pct / 100.0
                warnings.append(
                    "Promoted sticky Revenue Cloud preview Quote (no second Quote created)."
                )
                return GetPricingResult(
                    ok=True,
                    country=country,
                    account_name=account_name,
                    account_id=acct["Id"],
                    plan_sku=plan_sku,
                    plan_name=PLAN_LABELS[plan_sku],
                    headcount=req.headcount,
                    list_pepm=list_pepm,
                    volume_percent=round(vol * 100, 1),
                    net_pepm=net_pepm,
                    monthly_total=monthly,
                    annual_total=round(monthly * 12, 2),
                    start_date=start_iso,
                    end_date=end_iso,
                    term_months=term_months,
                    term_total=round(monthly * term_months, 2),
                    discovered_skus=sorted(set(discovered)),
                    addon_skus=addon_skus,
                    line_items=line_items,
                    path_b_bundle_save=path_b_flag,
                    small_biz_flat=use_flat,
                    sell_plan_sku=sell_plan_sku,
                    free_trial=free_trial,
                    trial_days=TRIAL_DAYS if free_trial else 0,
                    paid_monthly_estimate=paid_monthly if free_trial else None,
                    paid_line_items=paid_line_items if free_trial else [],
                    currency=currency,
                    warnings=warnings,
                    quote_id=quote_id,
                    org_alias=session.alias,
                    contact_id=contact_id,
                    contact_name=str(buyer_meta.get("contactName") or ""),
                    contact_email=str(buyer_meta.get("contactEmail") or ""),
                    account_created=bool(buyer_meta.get("accountCreated")),
                    contact_created=bool(buyer_meta.get("contactCreated")),
                )
            # Preview was on a different Account (usually demo) — discard and place fresh.
            discard_preview_quote(session, req.preview_quote_id)
            warnings.append(
                "Preview Quote was on a different Account — created the buyer Quote fresh."
            )
        except Exception as exc:  # noqa: BLE001
            warnings.append(f"Preview promote skipped: {exc}")

    if req.place_quote:
        trial_tag = " trial" if free_trial else ""
        opp_id = session.create(
            "Opportunity",
            {
                "Name": (
                    self_serve_opportunity_name(
                        account_name,
                        PLAN_LABELS[plan_sku],
                        req.headcount,
                        country,
                    )
                    if (req.buyer and req.buyer.has_new_customer)
                    else (
                        f"Get Pricing{trial_tag} {plan_sku} "
                        f"{'+'.join(addon_skus) if addon_skus else 'plan'} "
                        f"{req.headcount} {country}"
                    )
                )[:120],
                "AccountId": acct["Id"],
                "StageName": "Prospecting",
                "CloseDate": (start_day + timedelta(days=30)).isoformat(),
                "Pricebook2Id": pb["Id"],
                "CurrencyIsoCode": currency,
            },
        )
        quote_name = (
            self_serve_quote_name(PLAN_LABELS[plan_sku], len(addon_skus))
            if (req.buyer and req.buyer.has_new_customer)
            else (
                f"Get Pricing — {PLAN_LABELS[plan_sku]}"
                + (f" + {len(addon_skus)} add-on(s)" if addon_skus else "")
            )
        )
        if free_trial:
            quote_name = f"{TRIAL_DAYS}-day trial — {PLAN_LABELS[plan_sku]}" + (
                f" + {len(addon_skus)} add-on(s)" if addon_skus else ""
            )
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
                },
            }
        ]
        for i, sku in enumerate(skus_needed):
            pbe = pbes[sku]
            line_qty = plan_qty if sku == sell_plan_sku else req.headcount
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
                        "StartDate": start_iso,
                        "EndDate": end_iso,
                        "PeriodBoundary": "Anniversary",
                        "BillingFrequency": "Monthly",
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
                    "graphId": f"gp{uuid.uuid4().hex[:8]}",
                    "records": records,
                },
            },
        )
        if isinstance(placed, list):
            placed = placed[0]
        if not placed.get("isSuccess"):
            raise RuntimeError(f"Place quote failed: {placed}")
        quote_id = placed["salesTransactionId"]

        # Ensure trial flag is persisted before System reprice (place graph may
        # ignore unknown custom fields on some orgs; PATCH is authoritative).
        if free_trial:
            session.patch(
                "Quote", quote_id, {"RLM_Bamboo_FreeTrial__c": True}
            )

        # Apex Path B flag stamps on line DML; System reprice applies volume +
        # Path B / free-trial ManualDiscount.
        _system_reprice_quote(session, quote_id)

        # Non-USD: System volume can stamp corporate-USD UnitPrice/Net on lines
        # (PBE stays local). Re-stamp native currency amounts via Custom.
        # Free trial stays on System ($0 ManualDiscount) — skip Custom.
        if currency != "USD" and not free_trial:
            by_sku = {
                li["sku"]: (
                    int(li["quantity"]),
                    float(li["listPepm"]),
                    float(li["netPepm"]),
                )
                for li in paid_line_items
            }
            _custom_price_quote(session, quote_id, by_sku)
            warnings.append(
                f"Native {currency} line prices applied after System reprice "
                "(Force; multi-currency volume workaround)."
            )

        # Same as Quote page Start Sync — populate Opportunity Amount.
        sync_quote_to_opportunity(session, quote_id, opp_id)

        qrows = session.soql(
            "SELECT RLM_Bamboo_PathB_BundleSave__c, RLM_Bamboo_FreeTrial__c "
            f"FROM Quote WHERE Id = '{quote_id}'"
        )
        path_b_flag = bool(qrows and qrows[0].get("RLM_Bamboo_PathB_BundleSave__c"))
        trial_flag = bool(qrows and qrows[0].get("RLM_Bamboo_FreeTrial__c"))
        if path_b and not path_b_flag and not free_trial:
            warnings.append(
                "Expected Path B Bundle & Save quote flag — check Apex trigger."
            )
        if free_trial and not trial_flag:
            warnings.append(
                "Expected Free Trial quote flag — check field deploy + BFF PATCH."
            )

        priced_lines = session.soql(
            "SELECT Id, Quantity, UnitPrice, NetUnitPrice, TotalPrice, "
            "Product2.StockKeepingUnit, Product2.Name "
            f"FROM QuoteLineItem WHERE QuoteId = '{quote_id}'"
        )
        monthly = 0.0
        for pl in priced_lines:
            sku = (pl.get("Product2") or {}).get("StockKeepingUnit") or ""
            name = (pl.get("Product2") or {}).get("Name") or sku
            qty = float(pl.get("Quantity") or req.headcount)
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
        monthly = round(monthly, 2)

        if free_trial:
            if monthly > 0.08:
                warnings.append(
                    f"Free trial monthly ${monthly} expected ~$0 — check "
                    "apply_bamboohr_free_trial_overlay + context mapping."
                )
            net_pepm = 0.0
        elif abs(net_pepm - expected_plan) > 0.08:
            warnings.append(
                f"Plan net ${net_pepm} differs from expectation ${expected_plan}."
            )
        if path_b_flag and not free_trial:
            for sku in ("BAMBOO-ADD-PAYROLL", "BAMBOO-ADD-BENEFITS"):
                list_p = addon_list_price(sku, currency)
                actual = next(
                    (li["netPepm"] for li in line_items if li["sku"] == sku), None
                )
                if actual is not None and actual >= list_p - 0.01:
                    warnings.append(
                        f"{sku} net ${actual} did not drop below list ${list_p} "
                        "(Path B Bundle & Save expected)."
                    )

    elif addon_skus or use_flat or free_trial:
        # Estimate-only (no quote): ladder / flat + Path B math for display.
        plan_name_est = (
            "BambooHR Core Small Business Flat"
            if use_flat
            else PLAN_LABELS[plan_sku]
        )
        plan_net = 0.0 if free_trial else expected_plan_paid
        line_items = [
            line_item_dict(
                sku=sell_plan_sku,
                name=plan_name_est,
                quantity=plan_qty,
                list_pepm=list_pepm,
                net_pepm=plan_net,
                monthly=round(plan_net * plan_qty, 2),
                is_plan=True,
                path_b=path_b,
                volume_percent=0.0 if use_flat else vol_pct,
            )
        ]
        monthly = line_items[0]["monthly"]
        for sku in addon_skus:
            net = (
                0.0
                if free_trial
                else expected_addon_net(
                    sku,
                    path_b=path_b,
                    currency=currency,
                    headcount=req.headcount,
                )
            )
            # Add-ons stay PEPM × headcount even on small-biz flat Core.
            line_total = round(net * req.headcount, 2)
            monthly += line_total
            line_items.append(
                line_item_dict(
                    sku=sku,
                    name=ADDON_LABELS[sku],
                    quantity=req.headcount,
                    list_pepm=addon_list_price(sku, currency),
                    net_pepm=net,
                    monthly=line_total,
                    is_plan=False,
                    path_b=path_b,
                    volume_percent=vol_pct,
                )
            )
        monthly = round(monthly, 2)
        path_b_flag = path_b
        trial_flag = free_trial
        net_pepm = plan_net

    return GetPricingResult(
        ok=True,
        country=country,
        account_name=account_name,
        account_id=acct["Id"],
        plan_sku=plan_sku,
        plan_name=PLAN_LABELS[plan_sku],
        headcount=req.headcount,
        list_pepm=list_pepm,
        volume_percent=round(vol * 100, 1),
        net_pepm=net_pepm,
        monthly_total=monthly,
        annual_total=round(monthly * 12, 2),
        start_date=start_iso,
        end_date=end_iso,
        term_months=term_months,
        term_total=round(monthly * term_months, 2),
        discovered_skus=sorted(set(discovered)),
        addon_skus=addon_skus,
        line_items=line_items,
        path_b_bundle_save=path_b_flag,
        small_biz_flat=use_flat,
        sell_plan_sku=sell_plan_sku,
        free_trial=free_trial,
        trial_days=TRIAL_DAYS if free_trial else 0,
        paid_monthly_estimate=paid_monthly if free_trial else None,
        paid_line_items=paid_line_items if free_trial else [],
        currency=currency,
        warnings=warnings,
        quote_id=quote_id,
        org_alias=session.alias,
        contact_id=contact_id,
        contact_name=str(buyer_meta.get("contactName") or ""),
        contact_email=str(buyer_meta.get("contactEmail") or ""),
        account_created=bool(buyer_meta.get("accountCreated")),
        contact_created=bool(buyer_meta.get("contactCreated")),
    )
