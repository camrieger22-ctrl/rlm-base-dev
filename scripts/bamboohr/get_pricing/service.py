"""BambooHR Get Pricing BFF service (P2/P3) — Discovery → price → place Quote."""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass, field
from datetime import date, timedelta
from typing import Any

API = "v67.0"
CATALOG_NAME = "BambooHR"

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

# Phase 2 Approach B — separate flat SKU for Core when headcount ≤ 25.
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
    return plan_sku == "BAMBOO-CORE" and headcount <= SMALL_BIZ_MAX_HEADCOUNT


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

    def _http(self, method: str, path: str, body: dict | None = None) -> Any:
        data = json.dumps(body).encode() if body is not None else None
        headers = {
            "Authorization": f"Bearer {self._token}",
            "Accept": "application/json",
        }
        if body is not None:
            headers["Content-Type"] = "application/json"
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
        result = self._http("POST", f"/services/data/{API}/sobjects/{sobject}", fields)
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
    """Self-serve buyer from the Get Pricing hero form."""

    company: str = ""
    first_name: str = ""
    last_name: str = ""
    email: str = ""
    phone: str = ""
    job_title: str = ""

    @classmethod
    def from_mapping(cls, raw: dict[str, Any] | None) -> "BuyerInfo":
        raw = raw or {}
        return cls(
            company=str(raw.get("company") or raw.get("accountName") or "").strip(),
            first_name=str(raw.get("firstName") or raw.get("first_name") or "").strip(),
            last_name=str(raw.get("lastName") or raw.get("last_name") or "").strip(),
            email=str(raw.get("email") or "").strip(),
            phone=str(raw.get("phone") or "").strip(),
            job_title=str(
                raw.get("jobTitle") or raw.get("job_title") or ""
            ).strip(),
        )

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
) -> tuple[dict[str, Any], str | None, dict[str, Any]]:
    """Return (account, contact_id, meta) for quote placement.

    New customer (company + email): create Account + Contact (or reuse Contact
    email / Account name match). Otherwise use the seeded country demo Account.
    """
    meta = {
        "accountCreated": False,
        "contactCreated": False,
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
    contact_id = session.create("Contact", c_fields)
    meta["contactCreated"] = True
    meta["contactName"] = f"{first} {last}".strip()
    meta["contactEmail"] = buyer.email
    return acct, contact_id, meta


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


def _system_reprice_quote(session: OrgSession, quote_id: str) -> None:
    """PST System reprice so volume + Path B ManualDiscount persist on lines."""
    lines = session.soql(
        f"SELECT Id, Quantity FROM QuoteLineItem WHERE QuoteId = '{quote_id}'"
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
    acct, contact_id, buyer_meta = resolve_buyer_account(
        session,
        country,
        req.buyer,
        currency=currency,
        account_id=req.account_id,
    )
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

    if req.place_quote:
        trial_tag = " trial" if free_trial else ""
        opp_id = session.create(
            "Opportunity",
            {
                "Name": (
                    f"Get Pricing{trial_tag} {plan_sku} "
                    f"{'+'.join(addon_skus) if addon_skus else 'plan'} "
                    f"{req.headcount} {country}"
                )[:120],
                "AccountId": acct["Id"],
                "StageName": "Prospecting",
                "CloseDate": "2026-12-31",
                "Pricebook2Id": pb["Id"],
                "CurrencyIsoCode": currency,
            },
        )
        today = date.today().isoformat()
        term_days = TRIAL_DAYS if free_trial else 365
        end = (date.today() + timedelta(days=term_days)).isoformat()
        quote_name = (
            f"Get Pricing — {PLAN_LABELS[plan_sku]}"
            + (f" + {len(addon_skus)} add-on(s)" if addon_skus else "")
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
                        "StartDate": today,
                        "EndDate": end,
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
