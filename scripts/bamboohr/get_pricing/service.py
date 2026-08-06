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
}

PLAN_LIST = {
    "BAMBOO-CORE": 10.0,
    "BAMBOO-PRO": 17.0,
    "BAMBOO-ELITE": 25.0,
}

PLAN_LABELS = {
    "BAMBOO-CORE": "BambooHR Core",
    "BAMBOO-PRO": "BambooHR Pro",
    "BAMBOO-ELITE": "BambooHR Elite",
}

# Phase 2 Approach B — separate flat SKU for Core when headcount ≤ 25.
CORE_FLAT_SKU = "BAMBOO-CORE-FLAT-SM"
CORE_FLAT_PRICE = 250.0
SMALL_BIZ_MAX_HEADCOUNT = 25


def uses_core_flat(plan_sku: str, headcount: int) -> bool:
    return plan_sku == "BAMBOO-CORE" and headcount <= SMALL_BIZ_MAX_HEADCOUNT

ADDON_LIST = {
    "BAMBOO-ADD-PAYROLL": 8.0,
    "BAMBOO-ADD-BENEFITS": 6.0,
    "BAMBOO-ADD-TIME": 4.0,
    "BAMBOO-ADD-GLOBAL": 12.0,
}

ADDON_LABELS = {
    "BAMBOO-ADD-PAYROLL": "Payroll",
    "BAMBOO-ADD-BENEFITS": "Benefits Administration",
    "BAMBOO-ADD-TIME": "Time & Attendance",
    "BAMBOO-ADD-GLOBAL": "Global Employment",
}

# Category disqualification — not sellable on CA demo Account.
US_ONLY_ADDONS = frozenset({"BAMBOO-ADD-PAYROLL", "BAMBOO-ADD-BENEFITS"})

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


def expected_net(plan_sku: str, headcount: int) -> float:
    list_price = PLAN_LIST[plan_sku]
    return round(list_price * (1.0 - volume_rate(headcount)), 2)


def expected_addon_net(addon_sku: str, *, path_b: bool) -> float:
    list_price = ADDON_LIST[addon_sku]
    if path_b and addon_sku in US_ONLY_ADDONS:
        return round(list_price * (1.0 - PATH_B_BUNDLE_SAVE), 2)
    return list_price


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
            "currency": "USD",
        }


def _pbe_for_sku(session: OrgSession, sku: str) -> dict:
    rows = session.soql(
        "SELECT Id, Product2Id FROM PricebookEntry WHERE Pricebook2.IsStandard = true "
        f"AND Product2.StockKeepingUnit = '{sku}' "
        "AND ProductSellingModel.SellingModelType = 'TermDefined' "
        "AND ProductSellingModel.PricingTermUnit = 'Months' LIMIT 1"
    )
    if not rows:
        raise RuntimeError(f"No Term Monthly PBE for {sku}")
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


def get_pricing(session: OrgSession, req: GetPricingRequest) -> GetPricingResult:
    warnings: list[str] = []
    country = (req.country or "US").upper().strip()
    if country not in COUNTRY_ACCOUNT:
        raise ValueError(f"Unsupported country {country!r}; use US or CA")
    plan_sku = (req.plan_sku or "BAMBOO-PRO").upper()
    if plan_sku not in PLAN_LIST:
        raise ValueError(f"Unsupported plan {plan_sku!r}")
    if req.headcount < 1 or req.headcount > 100000:
        raise ValueError("headcount must be between 1 and 100000")

    addon_skus = normalize_addons(req.addon_skus)
    if country == "CA":
        warnings.append(
            "Canada: Payroll and Benefits are hidden via category disqualification. "
            "Plans and other add-ons remain available."
        )
        blocked = [s for s in addon_skus if s in US_ONLY_ADDONS]
        if blocked:
            warnings.append(
                "Removed US-only add-ons for Canada: "
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
    if use_flat:
        warnings.append(
            f"Small-business flat: Core @ ≤{SMALL_BIZ_MAX_HEADCOUNT} employees uses "
            f"{CORE_FLAT_SKU} at ${CORE_FLAT_PRICE:.0f}/mo (qty 1), not PEPM×headcount."
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
    pbes = {sku: _pbe_for_sku(session, sku) for sku in skus_needed}

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

    list_pepm = CORE_FLAT_PRICE if use_flat else PLAN_LIST[plan_sku]
    vol = 0.0 if use_flat else volume_rate(req.headcount)
    expected_plan_paid = (
        CORE_FLAT_PRICE if use_flat else expected_net(plan_sku, req.headcount)
    )
    # Paid estimate (what convert-later charges) — always computed for UI.
    plan_name_paid = (
        "BambooHR Core Small Business Flat" if use_flat else PLAN_LABELS[plan_sku]
    )
    paid_line_items: list[dict[str, Any]] = [
        {
            "sku": sell_plan_sku,
            "name": plan_name_paid,
            "quantity": plan_qty,
            "listPepm": list_pepm,
            "netPepm": expected_plan_paid,
            "monthly": round(expected_plan_paid * plan_qty, 2),
            "isPlan": True,
        }
    ]
    paid_monthly = paid_line_items[0]["monthly"]
    for sku in addon_skus:
        addon_net = expected_addon_net(sku, path_b=path_b)
        addon_monthly = round(addon_net * req.headcount, 2)
        paid_monthly = round(paid_monthly + addon_monthly, 2)
        paid_line_items.append(
            {
                "sku": sku,
                "name": ADDON_LABELS[sku],
                "quantity": req.headcount,
                "listPepm": ADDON_LIST[sku],
                "netPepm": addon_net,
                "monthly": addon_monthly,
                "isPlan": False,
            }
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
            list_unit = (
                CORE_FLAT_PRICE
                if sku == CORE_FLAT_SKU
                else (PLAN_LIST.get(sku) or ADDON_LIST.get(sku))
            )
            line_items.append(
                {
                    "sku": sku,
                    "name": name,
                    "quantity": int(qty),
                    "listPepm": list_unit,
                    "netPepm": net,
                    "monthly": line_total,
                    "isPlan": sku in PLAN_LIST or sku == CORE_FLAT_SKU,
                }
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
                list_p = ADDON_LIST[sku]
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
            {
                "sku": sell_plan_sku,
                "name": plan_name_est,
                "quantity": plan_qty,
                "listPepm": list_pepm,
                "netPepm": plan_net,
                "monthly": round(plan_net * plan_qty, 2),
                "isPlan": True,
            }
        ]
        monthly = line_items[0]["monthly"]
        for sku in addon_skus:
            net = 0.0 if free_trial else expected_addon_net(sku, path_b=path_b)
            # Add-ons stay PEPM × headcount even on small-biz flat Core.
            line_total = round(net * req.headcount, 2)
            monthly += line_total
            line_items.append(
                {
                    "sku": sku,
                    "name": ADDON_LABELS[sku],
                    "quantity": req.headcount,
                    "listPepm": ADDON_LIST[sku],
                    "netPepm": net,
                    "monthly": line_total,
                    "isPlan": False,
                }
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
        warnings=warnings,
        quote_id=quote_id,
        org_alias=session.alias,
    )
