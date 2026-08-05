"""BambooHR Get Pricing BFF service (P2) — Discovery → price → place Quote."""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass
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

# Demo volume ladder (bh-pricing PAT) — keep in sync with RLM_BambooVolumeTiers.
VOLUME_BANDS = (
    (25, 75, 0.05),
    (76, 150, 0.10),
    (151, 300, 0.15),
    (301, 500, 0.20),
    (501, None, 0.25),
)


class OrgSession:
    def __init__(self, alias: str) -> None:
        from cumulusci.cli.runtime import CliRuntime

        runtime = CliRuntime(load_keychain=True)
        org = runtime.keychain.get_org(alias)
        if hasattr(org, "refresh_oauth_token"):
            try:
                org.refresh_oauth_token(runtime.keychain)
            except Exception:  # noqa: BLE001
                pass
        self.alias = alias
        self._token = org.access_token
        self._instance = str(org.instance_url).rstrip("/")

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

    def post(self, path: str, body: dict) -> Any:
        return self._http("POST", path, body)


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


@dataclass
class GetPricingRequest:
    headcount: int
    country: str
    plan_sku: str = "BAMBOO-PRO"
    place_quote: bool = True


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
    error: str | None = None

    def as_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "country": self.country,
            "accountName": self.account_name,
            "accountId": self.account_id,
            "planSku": self.plan_sku,
            "planName": self.plan_name,
            "headcount": self.headcount,
            "listPepm": self.list_pepm,
            "volumePercent": self.volume_percent,
            "netPepm": self.net_pepm,
            "monthlyTotal": self.monthly_total,
            "annualTotal": self.annual_total,
            "discoveredSkus": self.discovered_skus,
            "warnings": self.warnings,
            "quoteId": self.quote_id,
            "orgAlias": self.org_alias,
            "error": self.error,
            "currency": "USD",
        }


def _resolve_context(session: OrgSession) -> tuple[str, str]:
    ctx_payload = session._http(
        "GET",
        f"/services/data/{API}/connect/context-definitions/RLM_SalesTransactionContext",
    )
    ctx_def_id = ctx_payload["contextDefinitionId"]
    mapping_id = None
    for version in ctx_payload.get("contextDefinitionVersionList") or []:
        for mapping in version.get("contextMappings") or []:
            base = mapping.get("baseReference") or ""
            if base.endswith("/QuoteEntitiesMapping") or "QuoteEntitiesMapping" in base:
                mapping_id = mapping.get("contextMappingId")
                break
        if mapping_id:
            break
    if not mapping_id:
        raise RuntimeError("Could not resolve QuoteEntitiesMapping id")
    return ctx_def_id, mapping_id


def _headless_net(
    session: OrgSession,
    *,
    quote_id: str,
    line: dict,
    pricebook_id: str,
    quantity: int,
) -> float:
    today = date.today().isoformat()
    end = (date.today() + timedelta(days=365)).isoformat()
    ctx_def_id, mapping_id = _resolve_context(session)
    pricing_data = {
        "SalesTransaction": {
            "businessObjectType": "Quote",
            "id": quote_id,
            "Pricebook": pricebook_id,
            "CurrencyIsoCode": "USD",
            "SalesTransactionItem": [
                {
                    "businessObjectType": "QuoteLineItem",
                    "id": line["Id"],
                    "Product": line["Product2Id"],
                    "ProductSellingModel": line["ProductSellingModelId"],
                    "Quantity": quantity,
                    "SalesTransactionItemSource": "LINE_ITEM1",
                    "EffectiveFrom": f"{today}T00:00:00.000Z",
                    "EffectiveTo": f"{end}T00:00:00.000Z",
                }
            ],
        }
    }
    priced = session.post(
        f"/services/data/{API}/actions/standard/runSalesforceHeadlessPricing",
        {
            "inputs": [
                {
                    "contextDefinitionId": ctx_def_id,
                    "contextMappingId": mapping_id,
                    "pricingProcedureId": "RLM_DefaultPricingProcedure",
                    "skipDiscovery": True,
                    "displayContext": True,
                    "isSkipWaterfall": False,
                    "persistContext": True,
                    "useSessionScopedContext": False,
                    "taggedData": False,
                    "pricingData": json.dumps(pricing_data, separators=(",", ":")),
                }
            ]
        },
    )
    if isinstance(priced, list):
        priced = priced[0]
    outs = priced.get("outputValues") or {}
    if outs.get("pricingProcessStatus") != "Completed":
        raise RuntimeError(f"Headless pricing failed: {outs or priced}")
    wf = json.loads(json.loads(outs["pricingResult"])["PriceWaterFall"][0]["value"])
    return float(wf["output"]["NetUnitPrice"])


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

    account_name = COUNTRY_ACCOUNT[country]
    if country == "CA":
        warnings.append(
            "Canada: Payroll and Benefits are hidden via category disqualification. "
            "Plans and other add-ons remain available."
        )

    catalog = session.soql(
        f"SELECT Id FROM ProductCatalog WHERE Name = '{CATALOG_NAME}' LIMIT 1"
    )[0]
    acct = session.soql(
        f"SELECT Id, BillingCountry FROM Account WHERE Name = '{account_name}' LIMIT 1"
    )[0]
    pb = session.soql("SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1")[0]
    pbe = session.soql(
        "SELECT Id, Product2Id FROM PricebookEntry WHERE Pricebook2.IsStandard = true "
        f"AND Product2.StockKeepingUnit = '{plan_sku}' "
        "AND ProductSellingModel.SellingModelType = 'TermDefined' "
        "AND ProductSellingModel.PricingTermUnit = 'Months' LIMIT 1"
    )[0]

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
    if plan_sku not in discovered:
        warnings.append(f"{plan_sku} not in PCM search results — check search index.")

    list_pepm = PLAN_LIST[plan_sku]
    vol = volume_rate(req.headcount)
    expected = expected_net(plan_sku, req.headcount)
    quote_id: str | None = None
    net_pepm = expected

    if req.place_quote:
        opp_id = session.create(
            "Opportunity",
            {
                "Name": f"Get Pricing {plan_sku} {req.headcount} {country}",
                "AccountId": acct["Id"],
                "StageName": "Prospecting",
                "CloseDate": "2026-12-31",
                "Pricebook2Id": pb["Id"],
            },
        )
        today = date.today().isoformat()
        end = (date.today() + timedelta(days=365)).isoformat()
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
                    "records": [
                        {
                            "referenceId": "refQuote",
                            "record": {
                                "attributes": {"method": "POST", "type": "Quote"},
                                "Name": f"Get Pricing — {PLAN_LABELS[plan_sku]}",
                                "OpportunityId": opp_id,
                                "Pricebook2Id": pb["Id"],
                                "QuoteAccountId": acct["Id"],
                            },
                        },
                        {
                            "referenceId": "refL0",
                            "record": {
                                "attributes": {
                                    "type": "QuoteLineItem",
                                    "method": "POST",
                                },
                                "QuoteId": "@{refQuote.id}",
                                "Product2Id": pbe["Product2Id"],
                                "PricebookEntryId": pbe["Id"],
                                "Quantity": str(req.headcount),
                                "StartDate": today,
                                "EndDate": end,
                                "PeriodBoundary": "Anniversary",
                                "BillingFrequency": "Monthly",
                            },
                        },
                    ],
                },
            },
        )
        if isinstance(placed, list):
            placed = placed[0]
        if not placed.get("isSuccess"):
            raise RuntimeError(f"Place quote failed: {placed}")
        quote_id = placed["salesTransactionId"]
        line = session.soql(
            "SELECT Id, Product2Id, ProductSellingModelId "
            f"FROM QuoteLineItem WHERE QuoteId = '{quote_id}' LIMIT 1"
        )[0]
        net_pepm = _headless_net(
            session,
            quote_id=quote_id,
            line=line,
            pricebook_id=pb["Id"],
            quantity=req.headcount,
        )
        if abs(net_pepm - expected) > 0.08:
            warnings.append(
                f"Priced net ${net_pepm} differs from ladder expectation ${expected}."
            )

    monthly = round(net_pepm * req.headcount, 2)
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
        warnings=warnings,
        quote_id=quote_id,
        org_alias=session.alias,
    )
