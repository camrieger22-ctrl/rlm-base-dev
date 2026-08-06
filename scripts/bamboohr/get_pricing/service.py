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
class GetPricingRequest:
    headcount: int
    country: str
    plan_sku: str = "BAMBOO-PRO"
    addon_skus: list[str] = field(default_factory=list)
    place_quote: bool = True
    free_trial: bool = False


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

    def as_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "country": self.country,
            "accountName": self.account_name,
            "accountId": self.account_id,
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


def _pbe_for_sku(session: OrgSession, sku: str, currency: str = "USD") -> dict:
    rows = session.soql(
        "SELECT Id, Product2Id, UnitPrice, CurrencyIsoCode FROM PricebookEntry "
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

    account_name = COUNTRY_ACCOUNT[country]
    catalog = session.soql(
        f"SELECT Id FROM ProductCatalog WHERE Name = '{CATALOG_NAME}' LIMIT 1"
    )[0]
    acct = session.soql(
        f"SELECT Id, BillingCountry FROM Account WHERE Name = '{account_name}' LIMIT 1"
    )[0]
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
    )
