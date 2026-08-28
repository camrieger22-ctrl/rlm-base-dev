#!/usr/bin/env python3
"""BambooHR Get Pricing BFF + static form (local or hosted).

Local (CCI keychain):
  ~/.local/pipx/venvs/cumulusci/bin/python \\
    scripts/bamboohr/get_pricing/server.py --org master-demo --port 8765

Hosted (public bind + tunnel or JWT — see HOSTED.md):
  ~/.local/pipx/venvs/cumulusci/bin/python \\
    scripts/bamboohr/get_pricing/server.py --host 0.0.0.0 --port 8765
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HERE = Path(__file__).resolve().parent
STATIC = HERE / "static"
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))


def _load_dotenv(path: Path) -> None:
    """Load KEY=VALUE from .env into os.environ (do not override existing)."""
    if not path.is_file():
        return
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError:
        return
    for line in raw.splitlines():
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        key, _, val = s.partition("=")
        key = key.strip()
        if not key or key in os.environ:
            continue
        val = val.strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
            val = val[1:-1]
        os.environ[key] = val


_load_dotenv(HERE / ".env")

from account_console import (  # noqa: E402
    SELF_SERVE_ADDON_SKUS,
    estimate_account_amend,
    filter_self_serve_addons,
    load_account_console,
    place_account_changes,
    preview_account_changes,
    preview_qty_delta,
)
from amend_summary import attach_amend_summary_view  # noqa: E402
from ec_handoff import EcHandoffError, verify_ec_token  # noqa: E402
from checkout import (  # noqa: E402
    checkout_quote,
    checkout_quote_or_recover,
    place_status_for_quotes,
)
from portal_login import create_buyer_login  # noqa: E402
from docgen import (  # noqa: E402
    DEFAULT_TEMPLATE,
    download_content_version,
    generate_quote_pdf,
)
from quote_email import send_quote_email  # noqa: E402
from payment_email import send_payment_email  # noqa: E402
from pricing_api import estimate_get_pricing  # noqa: E402
from pricing_preview import preview_get_pricing  # noqa: E402
from service import (  # noqa: E402
    ALLOWED_TERM_MONTHS,
    BuyerInfo,
    DEFAULT_TERM_MONTHS,
    GetPricingRequest,
    OrgSession,
    commit_qualify_identity,
    get_pricing,
    handoff_qualify_to_sales,
    hydrate_catalog,
    quote_related_ids,
)
from qualify_crm import (  # noqa: E402
    DualMotionBlocked,
    QualifyCommitRequired,
    QuoteReuseBlocked,
    get_qualify_session,
    list_qualify_sessions,
    lookup_email,
    mark_qualify_cadence_sent,
    require_self_serve_commit,
    upsert_qualify_session,
)

# Micro self-serve (<25) is the default acquisition path. Set BAMBOO_MICRO_SELF_SERVE=0
# or open the UI with ?fullCatalog=1 to restore Elite / add-ons / UK for SE demos.
MICRO_SELF_SERVE = os.environ.get("BAMBOO_MICRO_SELF_SERVE", "1").strip() not in (
    "0",
    "false",
    "False",
    "no",
)
MICRO_MAX_HEADCOUNT = 24
MICRO_PLANS = frozenset({"BAMBOO-CORE", "BAMBOO-PRO"})
MICRO_COUNTRIES = frozenset({"US", "CA"})


def _upgrade_sku_from_body(body: dict) -> str | None:
    raw = str(body.get("upgradeSku") or body.get("upgradePlan") or "").strip().upper()
    return raw or None


SALES_HANDOFF_URL = os.environ.get(
    "BAMBOO_SALES_HANDOFF_URL",
    "mailto:sales@example.com?subject=BambooHR%20self-serve%20handoff",
)


def _assert_micro_cart(body: dict) -> None:
    """Reject acquisition carts outside the workshop MVP scope."""
    if not MICRO_SELF_SERVE:
        return
    # Opt-out per request for SE demos / Licenses tooling that posts freely.
    if body.get("fullCatalog") or body.get("bypassMicro"):
        return
    hc = int(body.get("headcount") or 0)
    country = str(body.get("country") or "").upper()
    plan = str(body.get("planSku") or "")
    addons = [str(a) for a in (body.get("addonSkus") or []) if a]
    if hc > MICRO_MAX_HEADCOUNT:
        raise ValueError(
            f"Micro self-serve supports at most {MICRO_MAX_HEADCOUNT} employees "
            "(talk to sales for larger teams)."
        )
    if country and country not in MICRO_COUNTRIES:
        raise ValueError("Micro self-serve is US and Canada only.")
    if plan and plan not in MICRO_PLANS:
        raise ValueError("Micro self-serve quotes are Core or Pro only.")
    if addons:
        raise ValueError(
            "Add-ons (including Payroll) are not on the unassisted micro path."
        )
    if body.get("freeTrial"):
        raise ValueError("Micro self-serve bills immediately — free trial is off.")


def _parse_start_date(raw: object):
    from datetime import date as date_cls

    text = str(raw or "").strip()
    if not text:
        return None
    return date_cls.fromisoformat(text[:10])


def _parse_term_months(raw: object) -> int:
    if raw is None or raw == "":
        return DEFAULT_TERM_MONTHS
    months = int(raw)
    if months not in ALLOWED_TERM_MONTHS:
        raise ValueError(
            f"termMonths must be one of {', '.join(str(m) for m in ALLOWED_TERM_MONTHS)}"
        )
    return months

# In-memory quote summaries for /quote/{id} branded page (demo only).
QUOTE_CACHE: dict[str, dict] = {}
# Amend summaries for /amend-quote/{id} (demo only — sticky preview payload).
AMEND_CACHE: dict[str, dict] = {}
ORG_ALIAS = "master-demo"
SESSION: OrgSession | None = None
CORS_ORIGIN = ""  # empty = omit CORS headers; "*" or origin for hosted demos
DOCGEN_TEMPLATE = os.environ.get("DOCGEN_TEMPLATE_NAME") or DEFAULT_TEMPLATE


def _cache_amend_summary(summary: dict) -> dict:
    """Store amend preview for /amend-quote/{id}; return cache metadata.

    Called from POST /api/account-amend-cache and automatically after a
    successful /api/account-amend-preview so Agentforce Apex only needs one
    callout (avoids a second round-trip against the 120s Apex limit).
    """
    if summary.get("ok") and not (
        isinstance(summary.get("amendSummaryView"), dict)
        and summary["amendSummaryView"].get("ok")
    ):
        summary = attach_amend_summary_view(summary)
    cache_id = ""
    view = summary.get("amendSummaryView") or {}
    for q in summary.get("amendQuotes") or view.get("amendQuotes") or []:
        if isinstance(q, dict) and q.get("quoteId"):
            cache_id = str(q["quoteId"])
            break
    if not cache_id:
        cache_id = str(
            summary.get("moduleQuoteId") or view.get("moduleQuoteId") or ""
        ).strip()
    if not cache_id:
        cache_id = f"amend-{summary['accountId']}"
    AMEND_CACHE[cache_id] = dict(summary)
    AMEND_CACHE[cache_id]["ok"] = True
    return {
        "ok": True,
        "id": cache_id,
        "amendQuoteUrl": f"/amend-quote/{cache_id}",
        "hasAmendSummaryView": bool(
            (AMEND_CACHE[cache_id].get("amendSummaryView") or {}).get("ok")
        ),
    }


def _agent_config_payload() -> dict:
    """Public Messaging / Agentforce embed config (no secrets).

    AGENT_CHAT_ENABLED=1 + deployment fields → load Salesforce MIAW.
    AGENT_CHAT_PREVIEW=1 → Phase 1 launcher shell until Messaging is ready.
    """
    enabled = os.environ.get("AGENT_CHAT_ENABLED", "").strip().lower() in (
        "1",
        "true",
        "yes",
        "on",
    )
    preview = os.environ.get("AGENT_CHAT_PREVIEW", "").strip().lower() in (
        "1",
        "true",
        "yes",
        "on",
    )
    # Default preview on for local demos so the launcher is visible before Phase 0.
    if not enabled and "AGENT_CHAT_PREVIEW" not in os.environ:
        preview = True
    return {
        "ok": True,
        "enabled": enabled,
        "preview": preview and not enabled,
        "orgId": os.environ.get("AGENT_CHAT_ORG_ID", "").strip() or None,
        "deploymentName": (
            os.environ.get("AGENT_CHAT_DEPLOYMENT_NAME", "").strip() or None
        ),
        "messagingUrl": (
            os.environ.get("AGENT_CHAT_MESSAGING_URL", "").strip() or None
        ),
        "scrtUrl": os.environ.get("AGENT_CHAT_SCRT_URL", "").strip() or None,
        "language": os.environ.get("AGENT_CHAT_LANGUAGE", "en_US").strip()
        or "en_US",
        "orgLabel": ORG_ALIAS,
        "placeOrderViaChat": False,
        "notes": [
            "Guest chat may estimate; Quote create needs company + work email.",
            "Place order stays on the summary CTA (MVP).",
            "Use a named Cloudflare tunnel for Messaging allow-lists.",
        ],
    }


def _session() -> OrgSession:
    global SESSION
    if SESSION is None:
        SESSION = OrgSession(ORG_ALIAS)
    return SESSION


def _money(value: float | None) -> str:
    if value is None:
        return "—"
    return f"${float(value):,.2f}"


def _warnings_html(warnings: list) -> str:
    """Hide Path B chatter already covered by the discount stack / table."""
    shown = [
        w
        for w in warnings
        if "Path B Bundle" not in str(w)
        and "Bundle & Save" not in str(w)
        and "Created new Account" not in str(w)
        and "Created Contact" not in str(w)
        and "Using seeded demo Account" not in str(w)
    ]
    if not shown:
        return ""
    return "<ul>" + "".join(f"<li>{w}</li>" for w in shown) + "</ul>"


def _buyer_card_html(data: dict) -> str:
    account = data.get("accountName") or "—"
    account_id = data.get("accountId") or ""
    contact = data.get("contactName") or ""
    email = data.get("contactEmail") or ""
    created = bool(data.get("accountCreated"))
    badge = (
        "<span class='line-badge'>New customer</span>"
        if created
        else (
            "<span class='line-badge'>Demo account</span>"
            if account in ("Acme", "Prestige Worldwide", "BambooHR UK Demo")
            and not data.get("contactId")
            else ""
        )
    )
    contact_line = ""
    if contact or email:
        who = contact or "Buyer"
        contact_line = (
            f"<p class='buyer-contact'>{who}"
            + (f" · {email}" if email else "")
            + "</p>"
        )
    id_bit = f"<code>{account_id}</code>" if account_id else ""
    return (
        "<section class='buyer-card'>"
        f"<p class='buyer-kicker'>Customer in Salesforce {badge}</p>"
        f"<h3 class='buyer-account'>{account}</h3>"
        f"{contact_line}"
        f"<p class='buyer-ids'>Account {id_bit}</p>"
        "</section>"
    )


_PATH_B_SKUS = frozenset({"BAMBOO-ADD-PAYROLL", "BAMBOO-ADD-BENEFITS"})


def _enrich_line_for_display(li: dict, *, path_b: bool, volume_percent: float) -> dict:
    """Fill waterfall fields for older cache entries that only have list/net."""
    out = dict(li)
    sku = str(out.get("sku") or "")
    is_plan = bool(out.get("isPlan"))
    list_p = out.get("listPepm")
    bundle_pct = float(out.get("bundleSavePercent") or 0)
    if "bundleSavePercent" not in out:
        bundle_pct = 15.0 if path_b and not is_plan and sku in _PATH_B_SKUS else 0.0
        out["bundleSavePercent"] = bundle_pct
    if out.get("afterBundlePepm") is None and list_p is not None:
        out["afterBundlePepm"] = round(float(list_p) * (1.0 - bundle_pct / 100.0), 2)
    if "volumePercent" not in out:
        out["volumePercent"] = volume_percent
    return out


def _line_sort_key(li: dict) -> tuple:
    sku = str(li.get("sku") or "")
    if li.get("isPlan"):
        return (0, sku)
    if sku == "BAMBOO-ADD-PAYROLL":
        return (1, sku)
    if sku == "BAMBOO-ADD-BENEFITS":
        return (2, sku)
    return (3, sku)


def _line_waterfall_row(li: dict) -> str:
    """One table row: list → Bundle & Save → volume → monthly."""
    name = li.get("name") or li.get("sku") or ""
    qty = li.get("quantity") or ""
    list_p = li.get("listPepm")
    after_bundle = li.get("afterBundlePepm")
    bundle_pct = float(li.get("bundleSavePercent") or 0)
    vol_pct = float(li.get("volumePercent") or 0)
    net = float(li.get("netPepm") or 0)
    monthly = float(li.get("monthly") or 0)
    row_cls = " class='has-bundle'" if bundle_pct > 0 else ""

    if bundle_pct > 0:
        bundle_cell = (
            f"<td class='num' title='List {_money(list_p)} − "
            f"{bundle_pct:.0f}% Bundle &amp; Save'>"
            f"<span class='step-inner'>"
            f"<span class='now'>{_money(after_bundle)}</span>"
            f"<span class='chip'>−{bundle_pct:.0f}%</span>"
            f"</span></td>"
        )
    else:
        bundle_cell = "<td class='num muted-cell'>—</td>"

    if vol_pct > 0:
        base = after_bundle if bundle_pct > 0 else list_p
        volume_cell = (
            f"<td class='num' title='{_money(base)} − "
            f"{vol_pct:g}% volume'>"
            f"<span class='step-inner'>"
            f"<span class='now'>{_money(net)}</span>"
            f"<span class='chip'>−{vol_pct:g}%</span>"
            f"</span></td>"
        )
    else:
        volume_cell = (
            f"<td class='num' title='No volume band'>{_money(net)}</td>"
        )

    return (
        f"<tr{row_cls}>"
        f"<td class='prod'>{name}</td>"
        f"<td class='num'>{qty}</td>"
        f"<td class='num'>{_money(list_p)}</td>"
        f"{bundle_cell}"
        f"{volume_cell}"
        f"<td class='num amt'>{_money(monthly)}</td>"
        "</tr>"
    )


def _lines_table(
    lines: list[dict],
    *,
    path_b: bool = False,
    volume_percent: float = 0.0,
) -> str:
    if not lines:
        return "<p class='muted'>No line detail.</p>"
    enriched = sorted(
        (
            _enrich_line_for_display(li, path_b=path_b, volume_percent=volume_percent)
            for li in lines
        ),
        key=_line_sort_key,
    )
    rows = "".join(_line_waterfall_row(li) for li in enriched)
    return (
        "<div class='lines-wrap'><table class='lines lines-waterfall'><thead><tr>"
        "<th>Product</th>"
        "<th>Qty</th>"
        "<th>List</th>"
        "<th>Bundle</th>"
        "<th>Volume</th>"
        "<th>Monthly</th>"
        "</tr></thead><tbody>"
        + rows
        + "</tbody></table></div>"
    )


def _metric_bubble(
    label: str,
    value: str,
    *,
    accent: bool = False,
    hint: str | None = None,
) -> str:
    hint_html = f"<span class='q-hint'>{hint}</span>" if hint else ""
    accent_cls = " accent" if accent else ""
    return (
        f"<div class='q-metric'>"
        f"<span class='q-label'>{label}</span>"
        f"<span class='q-value{accent_cls}'>{value}</span>"
        f"{hint_html}"
        f"</div>"
    )


def _logic_arrow() -> str:
    return "<span class='logic-arrow' aria-hidden='true'>→</span>"


def _product_logic_panel(li: dict, *, volume_percent: float) -> str:
    name = li.get("name") or li.get("sku") or "Product"
    list_p = li.get("listPepm")
    after_bundle = li.get("afterBundlePepm")
    bundle_pct = float(li.get("bundleSavePercent") or 0)
    vol_pct = float(li.get("volumePercent") if li.get("volumePercent") is not None else volume_percent)
    net = float(li.get("netPepm") or 0)
    is_plan = bool(li.get("isPlan"))
    kind = "Plan" if is_plan else "Add-on"
    badge = (
        "<span class='line-badge'>Bundle &amp; Save</span>"
        if bundle_pct > 0
        else ""
    )
    bubbles: list[str] = [
        _metric_bubble("List PEPM", _money(list_p if list_p is not None else None))
    ]
    if bundle_pct > 0:
        bubbles.append(_logic_arrow())
        bubbles.append(
            _metric_bubble(
                "After Bundle",
                _money(after_bundle),
                hint=f"−{bundle_pct:.0f}% Bundle &amp; Save",
            )
        )
    bubbles.append(_logic_arrow())
    if vol_pct > 0:
        bubbles.append(
            _metric_bubble(
                "Volume",
                f"−{vol_pct:g}%",
                hint="Applied after Bundle when present",
            )
        )
    else:
        bubbles.append(_metric_bubble("Volume", "0%", hint="Under volume band"))
    bubbles.append(_logic_arrow())
    bubbles.append(_metric_bubble("Net PEPM", _money(net), accent=True))

    return (
        f"<article class='price-logic{' is-bundle' if bundle_pct > 0 else ''}'>"
        f"<header class='price-logic-head'>"
        f"<p class='price-logic-kicker'>{kind}</p>"
        f"<h3 class='price-logic-title'>{name}{badge}</h3>"
        f"</header>"
        f"<div class='logic-bubbles'>{''.join(bubbles)}</div>"
        f"</article>"
    )


def _pricing_logic_html(data: dict) -> str:
    """Headcount + per-product bubble rows for plan / Payroll / Benefits (+ other add-ons)."""
    path_b = bool(data.get("pathBBundleSave"))
    vol_pct = float(data.get("volumePercent") or 0)
    hc = data.get("headcount")
    # Free trial nets are $0 — narrate paid waterfall when available.
    raw_lines = data.get("lineItems") or []
    if data.get("freeTrial") and data.get("paidLineItems"):
        raw_lines = data["paidLineItems"]
    lines = [
        _enrich_line_for_display(li, path_b=path_b, volume_percent=vol_pct)
        for li in raw_lines
    ]
    by_sku = {str(li.get("sku") or ""): li for li in lines}
    plan = next((li for li in lines if li.get("isPlan")), None)
    if plan is None and data.get("planName"):
        plan = _enrich_line_for_display(
            {
                "sku": data.get("planSku") or "",
                "name": data["planName"],
                "listPepm": data.get("listPepm"),
                "netPepm": data.get("netPepm"),
                "isPlan": True,
                "volumePercent": vol_pct,
            },
            path_b=False,
            volume_percent=vol_pct,
        )

    context = (
        "<div class='quote-metrics quote-context-metrics'>"
        + _metric_bubble("Headcount", str(hc))
        + _metric_bubble(
            "Volume band",
            f"{vol_pct:g}%",
            hint="Applies to every PEPM line after Bundle",
            accent=vol_pct > 0,
        )
        + "</div>"
    )

    panels: list[str] = []
    if plan:
        panels.append(_product_logic_panel(plan, volume_percent=vol_pct))
    for sku in ("BAMBOO-ADD-PAYROLL", "BAMBOO-ADD-BENEFITS"):
        if sku in by_sku:
            panels.append(_product_logic_panel(by_sku[sku], volume_percent=vol_pct))
    # Other add-ons (Time / Global) get the same treatment when present.
    for li in lines:
        sku = str(li.get("sku") or "")
        if li.get("isPlan") or sku in _PATH_B_SKUS:
            continue
        panels.append(_product_logic_panel(li, volume_percent=vol_pct))

    if not panels:
        return context

    return (
        f"{context}"
        "<div class='price-logic-panels'>"
        "<p class='price-logic-lede'>How each product gets to net PEPM</p>"
        f"{''.join(panels)}"
        "</div>"
    )


def _discount_stack_html(data: dict) -> str:
    path_b = bool(data.get("pathBBundleSave"))
    vol = data.get("volumePercent") or 0
    hc = data.get("headcount")
    step2_cls = "is-on" if path_b else "is-off"
    step2_badge = (
        '<span class="step-badge on">Applied on Payroll + Benefits</span>'
        if path_b
        else '<span class="step-badge off">Not on this quote</span>'
    )
    step3_badge = (
        f'<span class="step-badge on">−{vol}% at {hc} employees</span>'
        if float(vol) > 0
        else '<span class="step-badge off">No volume band (under 25)</span>'
    )
    bundle_callout = (
        "<p class='callout callout-save'>"
        "<strong>Bundle &amp; Save: 15% off Payroll + Benefits.</strong> "
        "Because you selected both add-ons with your plan, step ② cuts those "
        "list rates by 15% before volume discount is applied."
        "</p>"
        if path_b and not data.get("freeTrial")
        else ""
    )
    return (
        "<section class='discount-stack' aria-label='Discount order'>"
        "<h3>How discounts apply</h3>"
        "<p class='discount-stack-lede'>Every line moves from list to net in this order:</p>"
        "<ol class='discount-steps'>"
        "<li class='is-on'>"
        "<span class='step-num'>1</span>"
        "<div><strong>List PEPM</strong> — catalog rate before discounts.</div>"
        "</li>"
        f"<li class='{step2_cls}'>"
        "<span class='step-num'>2</span>"
        "<div><strong>Bundle &amp; Save 15%</strong> — Payroll + Benefits only, "
        f"when both are on the quote. {step2_badge}</div>"
        "</li>"
        "<li class='is-on'>"
        "<span class='step-num'>3</span>"
        "<div><strong>Volume discount</strong> — headcount band on the "
        f"post-bundle amount. {step3_badge}</div>"
        "</li>"
        "<li class='is-result'>"
        "<span class='step-num'>=</span>"
        "<div><strong>Net PEPM</strong> — what you pay per employee × qty.</div>"
        "</li>"
        "</ol>"
        "<p class='discount-stack-note'>Plans, Time, and Global skip step ② "
        "(no Bundle &amp; Save) and go List → Volume → Net.</p>"
        f"{bundle_callout}"
        "</section>"
    )


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _cors(self) -> None:
        if not CORS_ORIGIN:
            return
        self.send_header("Access-Control-Allow-Origin", CORS_ORIGIN)
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def _send(self, code: int, body: bytes, content_type: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self._cors()
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code: int, payload: dict) -> None:
        raw = json.dumps(payload, indent=2).encode()
        self._send(code, raw, "application/json; charset=utf-8")

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path == "/api/health":
            try:
                sess = _session()
                base = (sess._instance or "").rstrip("/")
                agent = _agent_config_payload()
                self._json(
                    200,
                    {
                        "ok": True,
                        "service": "bamboohr-get-pricing",
                        "authMode": sess.auth_mode,
                        "org": sess.alias,
                        "instanceUrl": base,
                        "agentChat": {
                            "enabled": agent.get("enabled"),
                            "preview": agent.get("preview"),
                        },
                        "microSelfServe": MICRO_SELF_SERVE,
                        "salesHandoffUrl": SALES_HANDOFF_URL,
                        "links": {
                            "home": f"{base}/lightning/page/home" if base else "",
                            "accounts": (
                                f"{base}/lightning/o/Account/home" if base else ""
                            ),
                            "selfServeList": (
                                f"{base}/lightning/o/Account/list"
                                "?filterName=RLM_Bamboo_SelfServe_DoNotCall"
                                if base
                                else ""
                            ),
                            "selfServeContacts": (
                                f"{base}/lightning/o/Contact/list"
                                "?filterName=RLM_Bamboo_SelfServe_DoNotCall"
                                if base
                                else ""
                            ),
                            "orders": f"{base}/lightning/o/Order/home" if base else "",
                            "assets": f"{base}/lightning/o/Asset/home" if base else "",
                            "qualifyInbox": "/qualify-inbox",
                        },
                    },
                )
            except Exception as exc:  # noqa: BLE001
                self._json(503, {"ok": False, "error": str(exc)})
            return
        if path == "/api/agent-config":
            self._json(200, _agent_config_payload())
            return
        if path == "/api/qualify-sessions":
            qs = parse_qs(urlparse(self.path).query)
            incomplete = (qs.get("incomplete") or ["1"])[0] != "0"
            sid = (qs.get("sessionId") or [""])[0].strip()
            if sid:
                rec = get_qualify_session(sid)
                self._json(200 if rec else 404, {"ok": bool(rec), "session": rec})
                return
            self._json(
                200,
                {
                    "ok": True,
                    "sessions": list_qualify_sessions(incomplete_only=incomplete),
                },
            )
            return
        if path in ("/qualify-inbox", "/qualify-inbox.html"):
            self._send(
                200,
                (STATIC / "qualify-inbox.html").read_bytes(),
                "text/html; charset=utf-8",
            )
            return
        if path == "/api/catalog":
            try:
                qs = parse_qs(urlparse(self.path).query)
                country = (qs.get("country") or ["US"])[0]
                full = (qs.get("fullCatalog") or ["0"])[0].strip().lower() in (
                    "1",
                    "true",
                    "yes",
                )
                catalog = hydrate_catalog(_session(), country)
                if MICRO_SELF_SERVE and not full:
                    plans = [
                        p
                        for p in (catalog.get("plans") or [])
                        if (p.get("sku") or "") in MICRO_PLANS
                    ]
                    catalog = filter_self_serve_addons(
                        {
                            **catalog,
                            "plans": plans,
                        }
                    )
                    catalog["microFiltered"] = True
                    catalog["microPlans"] = sorted(MICRO_PLANS)
                    catalog["microAddons"] = sorted(SELF_SERVE_ADDON_SKUS)
                else:
                    catalog = {**catalog, "microFiltered": False}
                self._json(200, catalog)
            except ValueError as exc:
                self._json(400, {"ok": False, "error": str(exc)})
            except Exception as exc:  # noqa: BLE001
                self._json(503, {"ok": False, "error": str(exc)})
            return
        if path == "/api/payments-readiness":
            try:
                from payments import payments_readiness

                ready = payments_readiness(_session())
                ready_ok = bool(ready.get("readyForPayNow"))
                steps = ready.get("manualSteps") or []
                if ready_ok:
                    hint = "readyForPayNow — guest Pay Now path looks healthy."
                elif steps:
                    hint = steps[0]
                elif ready.get("merchantAccountCount", 0) == 0:
                    hint = (
                        "Complete Salesforce Payments merchant setup + Pay Now "
                        "site URL before checkout can return paymentUrl."
                    )
                else:
                    hint = (
                        "Merchant present but guest/store checks failed — "
                        "see blocking / run bootstrap_paynow.py."
                    )
                self._json(
                    200,
                    {
                        "ok": True,
                        **ready,
                        "payNowLikely": ready_ok
                        or (
                            ready.get("merchantAccountCount", 0) > 0
                            and ready.get("paymentsWebhookLive")
                        ),
                        "hint": hint,
                    },
                )
            except Exception as exc:  # noqa: BLE001
                self._json(503, {"ok": False, "error": str(exc)})
            return
        if path == "/api/ec-handoff":
            try:
                qs = parse_qs(urlparse(self.path).query)
                token = (qs.get("token") or [None])[0]
                claims = verify_ec_token(token or "")
                self._json(
                    200,
                    {
                        "ok": True,
                        "accountId": claims["accountId"],
                        "contactId": claims["contactId"],
                        "exp": claims["exp"],
                    },
                )
            except EcHandoffError as exc:
                self._json(401, {"ok": False, "error": str(exc)})
            except Exception as exc:  # noqa: BLE001
                self._json(503, {"ok": False, "error": str(exc)})
            return
        if path == "/api/account-console":
            try:
                qs = parse_qs(urlparse(self.path).query)
                account_id = (qs.get("accountId") or [None])[0]
                company = (qs.get("company") or [None])[0]
                ec_token = (qs.get("ecToken") or [None])[0]
                if ec_token:
                    claims = verify_ec_token(ec_token)
                    account_id = claims["accountId"]
                    company = None
                self._json(
                    200,
                    load_account_console(
                        _session(),
                        account_id=account_id,
                        company=company,
                    ),
                )
            except EcHandoffError as exc:
                self._json(401, {"ok": False, "error": str(exc)})
            except ValueError as exc:
                self._json(400, {"ok": False, "error": str(exc)})
            except Exception as exc:  # noqa: BLE001
                self._json(503, {"ok": False, "error": str(exc)})
            return
        if path == "/api/account-invoices":
            try:
                qs = parse_qs(urlparse(self.path).query)
                account_id = (qs.get("accountId") or [None])[0]
                company = (qs.get("company") or [None])[0]
                ec_token = (qs.get("ecToken") or [None])[0]
                if ec_token:
                    claims = verify_ec_token(ec_token)
                    account_id = claims["accountId"]
                    company = None
                from account_console import resolve_account_id
                from payments import (
                    annotate_invoices_paid_applying,
                    bucket_open_invoices,
                    list_activated_orders,
                    list_open_invoices,
                    payment_received_signal,
                )

                acct = resolve_account_id(
                    _session(), account_id=account_id, company=company
                )
                invoices = list_open_invoices(_session(), acct["Id"])
                pay_sig = payment_received_signal(
                    _session(),
                    acct["Id"],
                    open_invoice_count=len(invoices),
                )
                invoices = annotate_invoices_paid_applying(invoices, pay_sig)
                invoices = bucket_open_invoices(
                    invoices,
                    orders=list_activated_orders(_session(), acct["Id"]),
                )
                self._json(
                    200,
                    {
                        "ok": True,
                        "accountId": acct["Id"],
                        "accountName": acct.get("Name"),
                        "invoices": invoices,
                        **pay_sig,
                    },
                )
            except EcHandoffError as exc:
                self._json(401, {"ok": False, "error": str(exc)})
            except ValueError as exc:
                self._json(400, {"ok": False, "error": str(exc)})
            except Exception as exc:  # noqa: BLE001
                self._json(503, {"ok": False, "error": str(exc)})
            return
        if path == "/api/activate":
            try:
                qs = parse_qs(urlparse(self.path).query)
                account_id = (qs.get("accountId") or [None])[0]
                company = (qs.get("company") or [None])[0]
                ec_token = (qs.get("ecToken") or [None])[0]
                if ec_token:
                    claims = verify_ec_token(ec_token)
                    account_id = claims["accountId"]
                    company = None
                from activate import build_activate_checklist

                self._json(
                    200,
                    build_activate_checklist(
                        _session(),
                        account_id=account_id,
                        company=company,
                    ),
                )
            except EcHandoffError as exc:
                self._json(401, {"ok": False, "error": str(exc)})
            except ValueError as exc:
                self._json(400, {"ok": False, "error": str(exc)})
            except Exception as exc:  # noqa: BLE001
                self._json(503, {"ok": False, "error": str(exc)})
            return
        if path == "/api/account-amend-place-status":
            try:
                qs = parse_qs(urlparse(self.path).query)
                account_id = (qs.get("accountId") or [None])[0]
                raw_ids = (qs.get("quoteIds") or [""])[0]
                quote_ids = [
                    part.strip()
                    for part in str(raw_ids).split(",")
                    if part.strip()
                ]
                if not quote_ids:
                    self._json(
                        400,
                        {"ok": False, "error": "quoteIds is required"},
                    )
                    return
                payload = place_status_for_quotes(_session(), quote_ids)
                if account_id and payload.get("accountId") and payload.get(
                    "accountId"
                ) != account_id:
                    self._json(
                        200,
                        {"ok": False, "found": False},
                    )
                    return
                self._json(200, payload)
            except Exception as exc:  # noqa: BLE001
                self._json(503, {"ok": False, "error": str(exc)})
            return
        if path.startswith("/api/account-amend-summary/"):
            cache_id = path.split("/api/account-amend-summary/", 1)[1].strip("/")
            summary = AMEND_CACHE.get(cache_id)
            if not summary:
                self._json(
                    404,
                    {
                        "ok": False,
                        "error": (
                            "Amend summary not in this server session — "
                            "generate quote again."
                        ),
                    },
                )
                return
            if summary.get("ok") and not (
                isinstance(summary.get("amendSummaryView"), dict)
                and summary["amendSummaryView"].get("ok")
            ):
                summary = attach_amend_summary_view(summary)
                AMEND_CACHE[cache_id] = summary
            self._json(200, {"ok": True, "id": cache_id, "summary": summary})
            return
        if path in ("/", "/index.html"):
            html = (STATIC / "index.html").read_text(encoding="utf-8")
            html = html.replace(
                "<body class=\"config-page\">",
                f'<body class="config-page" data-sales-handoff-url="{SALES_HANDOFF_URL}">',
                1,
            )
            self._send(
                200,
                html.encode("utf-8"),
                "text/html; charset=utf-8",
            )
            return
        if path.startswith("/static/"):
            rel = path[len("/static/") :]
            file_path = (STATIC / rel).resolve()
            if not str(file_path).startswith(str(STATIC.resolve())) or not file_path.is_file():
                self._send(404, b"Not found", "text/plain")
                return
            ctype = mimetypes.guess_type(str(file_path))[0] or "application/octet-stream"
            self._send(200, file_path.read_bytes(), ctype)
            return
        if path.startswith("/api/docgen-pdf/"):
            cv_id = path.split("/api/docgen-pdf/", 1)[1].strip("/")
            try:
                # Fetch before send_response — a mid-header failure used to leave
                # a half-written 200 and then a 404 on the same socket (browser
                # PDF error / curl "Header without colon").
                raw, filename, ctype = download_content_version(_session(), cv_id)
            except Exception as exc:  # noqa: BLE001
                self._json(404, {"ok": False, "error": str(exc)})
                return
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(raw)))
            self.send_header(
                "Content-Disposition", f'attachment; filename="{filename}"'
            )
            self.send_header("Cache-Control", "no-store")
            self._cors()
            self.end_headers()
            self.wfile.write(raw)
            return

        if path in ("/account", "/account.html", "/licenses"):
            self._send(
                200,
                (STATIC / "account.html").read_bytes(),
                "text/html; charset=utf-8",
            )
            return
        if path in ("/activate", "/activate.html"):
            self._send(
                200,
                (STATIC / "activate.html").read_bytes(),
                "text/html; charset=utf-8",
            )
            return
        if path.startswith("/amend-quote/"):
            self._send(
                200,
                (STATIC / "amend-quote.html").read_bytes(),
                "text/html; charset=utf-8",
            )
            return
        if path.startswith("/quote/"):
            qid = path.split("/quote/", 1)[1].strip("/")
            data = QUOTE_CACHE.get(qid)
            if not data:
                try:
                    from quote_page import load_quote_summary_from_org

                    data = load_quote_summary_from_org(_session(), qid)
                    if data:
                        QUOTE_CACHE[qid] = data
                except Exception as exc:  # noqa: BLE001
                    self._send(
                        503,
                        f"Quote cache miss and org reload failed: {exc}".encode(),
                        "text/plain",
                    )
                    return
            if not data:
                self._send(404, b"Quote summary not in this server session", "text/plain")
                return
            html = (STATIC / "quote.html").read_text(encoding="utf-8")
            lines = data.get("lineItems") or []
            path_b = bool(data.get("pathBBundleSave"))
            vol_pct = float(data.get("volumePercent") or 0)
            line_html = _lines_table(lines, path_b=path_b, volume_percent=vol_pct)
            pricing_logic = _pricing_logic_html(data)
            discount_stack = _discount_stack_html(data)
            buyer_card = _buyer_card_html(data)
            trial_note = ""
            convert_section = ""
            convert_btn = ""
            if data.get("freeTrial"):
                paid = data.get("paidMonthlyEstimate")
                paid_txt = f"${paid:,.2f}/mo" if paid is not None else "paid rates"
                paid_annual = (
                    f"${round(float(paid) * 12, 2):,.2f}" if paid is not None else "—"
                )
                days = int(data.get("trialDays") or 30)
                hc = data.get("headcount")
                trial_note = (
                    f"<p class='callout callout-trial'><strong>{days}-day free trial</strong> "
                    f"(convert later). Quote totals are $0 now. "
                    "Checkout creates $0 trial assets; use Convert to paid for a "
                    "new paid quote.</p>"
                )
                paid_lines = data.get("paidLineItems") or []
                paid_table = (
                    _lines_table(paid_lines, path_b=path_b, volume_percent=vol_pct)
                    if paid_lines
                    else ""
                )
                path_b_bit = (
                    " Includes Bundle &amp; Save 15% on Payroll + Benefits "
                    "(applied before volume)."
                    if data.get("pathBBundleSave")
                    else ""
                )
                convert_section = (
                    "<div class='convert-preview'>"
                    "<h3>If converted — your cost</h3>"
                    f"<p>At <strong>{hc} employees</strong>, these modules would "
                    f"cost about <strong>{paid_txt}</strong> "
                    f"(~{paid_annual}/yr) after the free trial."
                    f"{path_b_bit}</p>"
                    f"{paid_table}"
                    "</div>"
                )
                convert_btn = (
                    '<button type="button" id="convertTrialBtn" class="secondary">'
                    "Convert to paid pricing</button>"
                )
            start_iso = str(data.get("startDate") or "")[:10]
            end_iso = str(data.get("endDate") or "")[:10]
            term_months = int(data.get("termMonths") or DEFAULT_TERM_MONTHS)
            if data.get("freeTrial"):
                days = int(data.get("trialDays") or 30)
                subscription_meta = (
                    f"Starts {start_iso or '—'} · {days}-day free trial"
                    + (f" · ends {end_iso}" if end_iso else "")
                )
            else:
                subscription_meta = (
                    f"Starts {start_iso or '—'} · {term_months}-month term"
                    + (f" · ends {end_iso}" if end_iso else "")
                )
            for key, val in {
                "{{planName}}": data["planName"],
                "{{headcount}}": str(data["headcount"]),
                "{{country}}": data["country"],
                "{{currency}}": data.get("currency") or "USD",
                "{{listPepm}}": f"{data['listPepm']:.2f}",
                "{{volumePercent}}": str(data["volumePercent"]),
                "{{netPepm}}": f"{data['netPepm']:.2f}",
                "{{monthlyTotal}}": f"{data['monthlyTotal']:,.2f}",
                "{{annualTotal}}": f"{data['annualTotal']:,.2f}",
                "{{subscriptionMeta}}": subscription_meta,
                "{{quoteId}}": data["quoteId"] or "",
                "{{accountName}}": data["accountName"],
                "{{lineItems}}": line_html,
                "{{pricingLogic}}": pricing_logic,
                "{{discountStack}}": discount_stack,
                "{{buyerCard}}": buyer_card,
                "{{trialNote}}": trial_note,
                "{{convertPreview}}": convert_section,
                "{{convertTrialButton}}": convert_btn,
                "{{warnings}}": _warnings_html(data.get("warnings") or []),
            }.items():
                html = html.replace(key, val)
            self._send(200, html.encode(), "text/html; charset=utf-8")
            return
        self._send(404, b"Not found", "text/plain")

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length).decode() or "{}")
        except json.JSONDecodeError:
            self._json(400, {"ok": False, "error": "Invalid JSON"})
            return

        if path == "/api/qualify-session":
            try:
                rec = upsert_qualify_session(body if isinstance(body, dict) else {})
                self._json(200, {"ok": True, "session": rec})
            except Exception as exc:  # noqa: BLE001
                self._json(400, {"ok": False, "error": str(exc)})
            return

        if path == "/api/qualify-cadence":
            # Demo inbox: mark 1-day / 1-week abandoned-wizard follow-up as sent.
            try:
                sid = str(body.get("sessionId") or "").strip()
                which = str(body.get("which") or body.get("cadence") or "").strip()
                rec = mark_qualify_cadence_sent(
                    sid, which, crm_session=_session()
                )
                if not rec:
                    self._json(404, {"ok": False, "error": "Session not found"})
                    return
                self._json(200, {"ok": True, "session": rec})
            except ValueError as exc:
                self._json(400, {"ok": False, "error": str(exc)})
            except Exception as exc:  # noqa: BLE001
                self._json(400, {"ok": False, "error": str(exc)})
            return

        if path == "/api/qualify-lookup":
            try:
                email = str(body.get("email") or "").strip()
                result = lookup_email(_session(), email)
                code = 200 if result.get("ok") else 400
                self._json(code, result)
            except Exception as exc:  # noqa: BLE001
                self._json(400, {"ok": False, "error": str(exc)})
            return

        if path == "/api/qualify-commit":
            # Beat 5: Account/Contact must exist so we can mark sales don't touch
            # (Jeff ~01:59) — before Get your quote.
            try:
                result = commit_qualify_identity(
                    _session(),
                    buyer=BuyerInfo.from_request(body if isinstance(body, dict) else {}),
                    headcount=int(body.get("headcount") or 0),
                    country=str(body.get("country") or "US"),
                )
                self._json(200 if result.get("ok") else 400, result)
            except DualMotionBlocked as exc:
                looked = exc.lookup or {}
                self._json(
                    409,
                    {
                        "ok": False,
                        "error": str(exc),
                        "status": looked.get("status"),
                        "reason": looked.get("reason"),
                        "signInUrl": looked.get("signInUrl"),
                        "accountId": looked.get("accountId"),
                    },
                )
            except Exception as exc:  # noqa: BLE001
                self._json(400, {"ok": False, "error": str(exc)})
            return

        if path == "/api/qualify-handoff":
            # Live bounce: still capture them for sales (N 219 ~00:39).
            try:
                result = handoff_qualify_to_sales(
                    _session(),
                    buyer=BuyerInfo.from_request(body if isinstance(body, dict) else {}),
                    headcount=int(body.get("headcount") or 0) or None,
                    country=str(body.get("country") or "US"),
                    bounce_reason=str(body.get("bounceReason") or body.get("reason") or ""),
                    bounce_type=str(body.get("bounceType") or ""),
                )
                code = 200 if result.get("ok") else 400
                if result.get("status") == "existingCustomer":
                    code = 409
                self._json(code, result)
            except Exception as exc:  # noqa: BLE001
                self._json(400, {"ok": False, "error": str(exc)})
            return

        if path == "/api/get-pricing-estimate":
            # Phase 1 rail: Salesforce Pricing API only — no Opp/Quote.
            try:
                _assert_micro_cart(body)
                raw_addons = body.get("addonSkus") or body.get("addons") or []
                if isinstance(raw_addons, str):
                    raw_addons = [s.strip() for s in raw_addons.split(",") if s.strip()]
                result = estimate_get_pricing(
                    _session(),
                    headcount=int(body.get("headcount") or 0),
                    country=str(body.get("country") or "US"),
                    plan_sku=str(body.get("planSku") or "BAMBOO-PRO"),
                    addon_skus=list(raw_addons),
                    free_trial=bool(
                        body.get("freeTrial") or body.get("free_trial")
                    ),
                    start_date=_parse_start_date(body.get("startDate")),
                    term_months=_parse_term_months(body.get("termMonths")),
                )
                self._json(200 if result.get("ok") else 400, result)
            except Exception as exc:  # noqa: BLE001
                self._json(400, {"ok": False, "error": str(exc)})
            return

        if path == "/api/get-pricing-preview":
            # Kept for rollback / Licenses-adjacent experiments — Get Pricing UI
            # uses /api/get-pricing-estimate (Pricing API) instead.
            try:
                raw_addons = body.get("addonSkus") or body.get("addons") or []
                if isinstance(raw_addons, str):
                    raw_addons = [s.strip() for s in raw_addons.split(",") if s.strip()]
                result = preview_get_pricing(
                    _session(),
                    headcount=int(body.get("headcount") or 0),
                    country=str(body.get("country") or "US"),
                    plan_sku=str(body.get("planSku") or "BAMBOO-PRO"),
                    addon_skus=list(raw_addons),
                    free_trial=bool(
                        body.get("freeTrial") or body.get("free_trial")
                    ),
                    quote_id=str(body.get("quoteId") or body.get("previewQuoteId") or "")
                    or None,
                    buyer=BuyerInfo.from_request(
                        body if isinstance(body, dict) else {}
                    ),
                    account_id=str(body.get("accountId") or "") or None,
                    start_date=_parse_start_date(body.get("startDate")),
                    term_months=_parse_term_months(body.get("termMonths")),
                )
                if result.get("ok") and result.get("quoteId"):
                    # Seed cache early so /quote/{id} works after promote/submit.
                    QUOTE_CACHE[result["quoteId"]] = {
                        **result,
                        "quoteUrl": f"/quote/{result['quoteId']}",
                    }
                self._json(200 if result.get("ok") else 400, result)
            except Exception as exc:  # noqa: BLE001
                self._json(400, {"ok": False, "error": str(exc)})
            return

        if path == "/api/get-pricing":
            try:
                _assert_micro_cart(body)
                buyer = BuyerInfo.from_request(
                    body if isinstance(body, dict) else {}
                )
                if buyer.email and not (
                    body.get("fullCatalog") or body.get("bypassMicro")
                ):
                    require_self_serve_commit(_session(), buyer.email)
                raw_addons = body.get("addonSkus") or body.get("addons") or []
                if isinstance(raw_addons, str):
                    raw_addons = [s.strip() for s in raw_addons.split(",") if s.strip()]
                req = GetPricingRequest(
                    headcount=int(body.get("headcount") or 0),
                    country=str(body.get("country") or "US"),
                    plan_sku=str(body.get("planSku") or "BAMBOO-PRO"),
                    addon_skus=list(raw_addons),
                    place_quote=bool(body.get("placeQuote", True)),
                    free_trial=bool(
                        body.get("freeTrial") or body.get("free_trial")
                    ),
                    buyer=buyer,
                    preview_quote_id=str(
                        body.get("previewQuoteId") or body.get("quoteId") or ""
                    )
                    or None,
                    start_date=_parse_start_date(body.get("startDate")),
                    term_months=_parse_term_months(body.get("termMonths")),
                )
                result = get_pricing(_session(), req)
                payload = result.as_dict()
                if result.quote_id:
                    QUOTE_CACHE[result.quote_id] = payload
                    payload["quoteUrl"] = f"/quote/{result.quote_id}"
                self._json(200, payload)
            except QualifyCommitRequired as exc:
                looked = exc.lookup or {}
                self._json(
                    409,
                    {
                        "ok": False,
                        "error": str(exc),
                        "status": "commitRequired",
                        "reason": str(exc),
                        "accountId": looked.get("accountId"),
                    },
                )
            except DualMotionBlocked as exc:
                looked = exc.lookup or {}
                self._json(
                    409,
                    {
                        "ok": False,
                        "error": str(exc),
                        "status": looked.get("status"),
                        "reason": looked.get("reason"),
                        "signInUrl": looked.get("signInUrl"),
                        "accountId": looked.get("accountId"),
                    },
                )
            except QuoteReuseBlocked as exc:
                self._json(
                    409,
                    {
                        "ok": False,
                        "error": str(exc),
                        "status": "quoteReuseBlocked",
                        "quoteId": exc.quote_id,
                    },
                )
            except Exception as exc:  # noqa: BLE001
                self._json(400, {"ok": False, "error": str(exc)})
            return

        if path == "/api/convert-trial":
            # Convert-later: place a paid quote from a trial quote's cached config.
            trial_quote_id = str(body.get("quoteId") or "").strip()
            cached = QUOTE_CACHE.get(trial_quote_id) if trial_quote_id else None
            if not cached or not cached.get("freeTrial"):
                self._json(
                    400,
                    {
                        "ok": False,
                        "error": (
                            "quoteId must be a free-trial quote from this "
                            "server session"
                        ),
                    },
                )
                return
            try:
                name_parts = str(cached.get("contactName") or "").split()
                req = GetPricingRequest(
                    headcount=int(cached.get("headcount") or 0),
                    country=str(cached.get("country") or "US"),
                    plan_sku=str(cached.get("planSku") or "BAMBOO-PRO"),
                    addon_skus=list(cached.get("addonSkus") or []),
                    place_quote=True,
                    free_trial=False,
                    account_id=str(cached.get("accountId") or "") or None,
                    buyer=BuyerInfo.from_mapping(
                        {
                            "company": cached.get("accountName"),
                            "email": cached.get("contactEmail"),
                            "firstName": name_parts[0] if name_parts else "",
                            "lastName": " ".join(name_parts[1:]),
                        }
                    ),
                    start_date=_parse_start_date(cached.get("startDate")),
                    term_months=_parse_term_months(cached.get("termMonths")),
                )
                result = get_pricing(_session(), req)
                payload = result.as_dict()
                payload["convertedFromQuoteId"] = trial_quote_id
                if result.quote_id:
                    QUOTE_CACHE[result.quote_id] = payload
                    payload["quoteUrl"] = f"/quote/{result.quote_id}"
                self._json(200, payload)
            except Exception as exc:  # noqa: BLE001
                self._json(400, {"ok": False, "error": str(exc)})
            return

        if path == "/api/activate":
            try:
                account_id = str(body.get("accountId") or "").strip() or None
                company = str(body.get("company") or "").strip() or None
                ec_token = str(body.get("ecToken") or "").strip()
                if ec_token:
                    claims = verify_ec_token(ec_token)
                    account_id = claims["accountId"]
                    company = None
                from activate import complete_activate_steps

                self._json(
                    200,
                    complete_activate_steps(
                        _session(),
                        account_id=account_id,
                        company=company,
                        first_name=body.get("firstName"),
                        last_name=body.get("lastName"),
                        email=body.get("email"),
                        admin_email=body.get("adminEmail"),
                        time_off_policy=body.get("timeOffPolicy"),
                    ),
                )
            except EcHandoffError as exc:
                self._json(401, {"ok": False, "error": str(exc)})
            except ValueError as exc:
                self._json(400, {"ok": False, "error": str(exc)})
            except Exception as exc:  # noqa: BLE001
                self._json(503, {"ok": False, "error": str(exc)})
            return

        if path == "/api/activate-cadence":
            try:
                account_id = str(body.get("accountId") or "").strip() or None
                company = str(body.get("company") or "").strip() or None
                ec_token = str(body.get("ecToken") or "").strip()
                if ec_token:
                    claims = verify_ec_token(ec_token)
                    account_id = claims["accountId"]
                    company = None
                which = str(body.get("which") or body.get("cadence") or "").strip()
                from activate import mark_aha_cadence_sent

                self._json(
                    200,
                    mark_aha_cadence_sent(
                        _session(),
                        account_id=account_id,
                        company=company,
                        which=which,
                    ),
                )
            except EcHandoffError as exc:
                self._json(401, {"ok": False, "error": str(exc)})
            except ValueError as exc:
                self._json(400, {"ok": False, "error": str(exc)})
            except Exception as exc:  # noqa: BLE001
                self._json(503, {"ok": False, "error": str(exc)})
            return

        if path == "/api/create-login":
            account_id = str(body.get("accountId") or "").strip()
            contact_id = str(body.get("contactId") or "").strip()
            email = str(body.get("email") or "").strip()
            password = str(body.get("password") or "")
            username = str(body.get("username") or "").strip() or None
            first_name = str(body.get("firstName") or "").strip() or None
            last_name = str(body.get("lastName") or "").strip() or None
            if not account_id:
                self._json(400, {"ok": False, "error": "accountId is required"})
                return
            if not email or not password:
                self._json(
                    400,
                    {"ok": False, "error": "email and password are required"},
                )
                return
            try:
                sess = _session()
                if not contact_id:
                    # Prefer Contact from a recent quote cache, else newest on Account.
                    for cached in QUOTE_CACHE.values():
                        if cached.get("accountId") == account_id and cached.get(
                            "contactId"
                        ):
                            contact_id = str(cached["contactId"])
                            break
                if not contact_id:
                    aid = account_id.replace("\\", "\\\\").replace("'", "\\'")
                    rows = sess.soql(
                        "SELECT Id FROM Contact "
                        f"WHERE AccountId = '{aid}' "
                        "ORDER BY CreatedDate DESC LIMIT 1"
                    )
                    if rows:
                        contact_id = rows[0]["Id"]
                if not contact_id:
                    self._json(
                        400,
                        {
                            "ok": False,
                            "error": "No Contact on this Account — complete Get Pricing first.",
                        },
                    )
                    return
                result = create_buyer_login(
                    sess,
                    account_id=account_id,
                    contact_id=contact_id,
                    email=email,
                    password=password,
                    username=username,
                    first_name=first_name,
                    last_name=last_name,
                )
                self._json(200, result)
            except EcHandoffError as exc:
                self._json(
                    503,
                    {
                        "ok": False,
                        "error": f"Login created but handoff failed: {exc}",
                    },
                )
            except ValueError as exc:
                self._json(400, {"ok": False, "error": str(exc)})
            except Exception as exc:  # noqa: BLE001
                self._json(400, {"ok": False, "error": str(exc)})
            return

        if path == "/api/account-amend":
            account_id = str(body.get("accountId") or "").strip()
            asset_id = str(body.get("assetId") or "").strip() or None
            raw_addons = body.get("addonSkus") or body.get("addons") or []
            if not isinstance(raw_addons, list):
                raw_addons = []
            addon_skus = [str(s).strip() for s in raw_addons if str(s).strip()]
            upgrade_sku = _upgrade_sku_from_body(body)
            new_qty: int | None
            if body.get("newQty") in (None, ""):
                new_qty = None
            else:
                try:
                    new_qty = int(body.get("newQty"))
                except (TypeError, ValueError):
                    self._json(400, {"ok": False, "error": "newQty must be an integer"})
                    return
            if not account_id:
                self._json(400, {"ok": False, "error": "accountId is required"})
                return
            if new_qty is None and not addon_skus and not upgrade_sku:
                self._json(
                    400,
                    {
                        "ok": False,
                        "error": "Provide newQty, upgradeSku, and/or addonSkus to place a change",
                    },
                )
                return
            start_date = None
            start_raw = str(body.get("startDate") or "").strip()
            if start_raw:
                try:
                    from datetime import date as _date

                    start_date = _date.fromisoformat(start_raw[:10])
                except ValueError:
                    self._json(
                        400,
                        {"ok": False, "error": "startDate must be YYYY-MM-DD"},
                    )
                    return
            amend_quotes_raw = body.get("amendQuotes") or []
            if not isinstance(amend_quotes_raw, list):
                amend_quotes_raw = []
            amend_quotes = [
                {
                    "quoteId": str(d.get("quoteId") or "").strip(),
                    "assetIds": [
                        str(a) for a in (d.get("assetIds") or []) if a
                    ],
                    "opportunityId": str(d.get("opportunityId") or "").strip()
                    or None,
                }
                for d in amend_quotes_raw
                if isinstance(d, dict) and d.get("quoteId")
            ]
            module_quote_id = str(body.get("moduleQuoteId") or "").strip() or None
            upgrade_quote_id = str(body.get("upgradeQuoteId") or "").strip() or None
            cancel_quote_id = str(body.get("cancelQuoteId") or "").strip() or None
            try:
                result = place_account_changes(
                    _session(),
                    account_id=account_id,
                    asset_id=asset_id,
                    new_qty=new_qty,
                    addon_skus=addon_skus,
                    upgrade_sku=upgrade_sku,
                    start_date=start_date,
                    amend_quotes=amend_quotes or None,
                    module_quote_id=module_quote_id,
                    upgrade_quote_id=upgrade_quote_id,
                    cancel_quote_id=cancel_quote_id,
                )
                self._json(200 if result.ok else 400, result.as_dict())
            except Exception as exc:  # noqa: BLE001
                self._json(400, {"ok": False, "error": str(exc)})
            return

        if path == "/api/account-amend-estimate":
            # Phase 2 rail: Core→Pro uses sticky Upgrade Quote (exact TotalPrice);
            # seat/module-only stays Pricing API provisional until Generate quote.
            account_id = str(body.get("accountId") or "").strip()
            raw_addons = body.get("addonSkus") or body.get("addons") or []
            if not isinstance(raw_addons, list):
                raw_addons = []
            addon_skus = [str(s).strip() for s in raw_addons if str(s).strip()]
            upgrade_sku = _upgrade_sku_from_body(body)
            new_qty: int | None
            if body.get("newQty") in (None, ""):
                new_qty = None
            else:
                try:
                    new_qty = int(body.get("newQty"))
                except (TypeError, ValueError):
                    self._json(400, {"ok": False, "error": "newQty must be an integer"})
                    return
            if not account_id:
                self._json(400, {"ok": False, "error": "accountId is required"})
                return
            start_date = None
            start_raw = str(body.get("startDate") or "").strip()
            if start_raw:
                try:
                    from datetime import date as _date

                    start_date = _date.fromisoformat(start_raw[:10])
                except ValueError:
                    self._json(
                        400,
                        {"ok": False, "error": "startDate must be YYYY-MM-DD"},
                    )
                    return
            preferred_upgrade = (
                str(body.get("upgradeQuoteId") or "").strip() or None
            )
            try:
                result = estimate_account_amend(
                    _session(),
                    account_id=account_id,
                    new_qty=new_qty,
                    addon_skus=addon_skus,
                    upgrade_sku=upgrade_sku,
                    start_date=start_date,
                    preferred_upgrade_quote_id=preferred_upgrade,
                )
                self._json(200 if result.get("ok") else 400, result)
            except Exception as exc:  # noqa: BLE001
                self._json(400, {"ok": False, "error": str(exc)})
            return

        if path == "/api/account-amend-preview":
            # Generate quote — sticky Draft Quotes + System reprice (due today).
            account_id = str(body.get("accountId") or "").strip()
            asset_id = str(body.get("assetId") or "").strip() or None
            raw_addons = body.get("addonSkus") or body.get("addons") or []
            if not isinstance(raw_addons, list):
                raw_addons = []
            addon_skus = [str(s).strip() for s in raw_addons if str(s).strip()]
            upgrade_sku = _upgrade_sku_from_body(body)
            new_qty: int | None
            if body.get("newQty") in (None, ""):
                new_qty = None
            else:
                try:
                    new_qty = int(body.get("newQty"))
                except (TypeError, ValueError):
                    self._json(400, {"ok": False, "error": "newQty must be an integer"})
                    return
            if not account_id:
                self._json(400, {"ok": False, "error": "accountId is required"})
                return
            start_date = None
            start_raw = str(body.get("startDate") or "").strip()
            if start_raw:
                try:
                    from datetime import date as _date

                    start_date = _date.fromisoformat(start_raw[:10])
                except ValueError:
                    self._json(
                        400,
                        {"ok": False, "error": "startDate must be YYYY-MM-DD"},
                    )
                    return
            try:
                preferred_amends = []
                raw_pref = body.get("amendQuotes") or []
                if isinstance(raw_pref, list):
                    preferred_amends = [
                        {
                            "quoteId": str(d.get("quoteId") or "").strip(),
                            "assetIds": [
                                str(a)
                                for a in (d.get("assetIds") or [])
                                if a
                            ],
                        }
                        for d in raw_pref
                        if isinstance(d, dict) and d.get("quoteId")
                    ]
                preferred_module = (
                    str(body.get("moduleQuoteId") or "").strip() or None
                )
                preferred_upgrade = (
                    str(body.get("upgradeQuoteId") or "").strip() or None
                )
                preferred_cancel = (
                    str(body.get("cancelQuoteId") or "").strip() or None
                )
                result = preview_account_changes(
                    _session(),
                    account_id=account_id,
                    asset_id=asset_id,
                    new_qty=new_qty,
                    addon_skus=addon_skus,
                    upgrade_sku=upgrade_sku,
                    start_date=start_date,
                    preferred_amend_quotes=preferred_amends or None,
                    preferred_module_quote_id=preferred_module,
                    preferred_upgrade_quote_id=preferred_upgrade,
                    preferred_cancel_quote_id=preferred_cancel,
                )
                # Auto-cache so /amend-quote/{id} works without a second callout.
                if result.get("ok") and result.get("accountId"):
                    cached = _cache_amend_summary(result)
                    result = dict(result)
                    result["amendQuoteUrl"] = cached.get("amendQuoteUrl")
                    result["amendCacheId"] = cached.get("id")
                self._json(200 if result.get("ok") else 400, result)
            except Exception as exc:  # noqa: BLE001
                self._json(400, {"ok": False, "error": str(exc)})
            return

        if path == "/api/account-amend-cache":
            summary = body.get("summary") if isinstance(body.get("summary"), dict) else body
            if not isinstance(summary, dict) or not summary.get("accountId"):
                self._json(400, {"ok": False, "error": "summary with accountId is required"})
                return
            self._json(200, _cache_amend_summary(summary))
            return

        if path == "/api/account-preview":
            # Legacy single-SKU estimate (kept for older callers).
            try:
                list_pepm = float(body.get("listPepm") or 0)
                current_qty = int(body.get("currentQty") or 0)
                new_qty = int(body.get("newQty") or 0)
                self._json(
                    200,
                    {
                        "ok": True,
                        **preview_qty_delta(
                            list_pepm=list_pepm,
                            current_qty=current_qty,
                            new_qty=new_qty,
                        ),
                    },
                )
            except Exception as exc:  # noqa: BLE001
                self._json(400, {"ok": False, "error": str(exc)})
            return

        if path == "/api/collect-payment":
            order_id = str(body.get("orderId") or "").strip()
            invoice_id = str(body.get("invoiceId") or "").strip()
            if not order_id and not invoice_id:
                self._json(
                    400,
                    {"ok": False, "error": "orderId or invoiceId is required"},
                )
                return
            try:
                from payments import (
                    build_payment_prompt,
                    build_payment_prompt_for_invoice,
                )

                sess = _session()
                if invoice_id:
                    prompt = build_payment_prompt_for_invoice(sess, invoice_id)
                else:
                    target_date = None
                    target_raw = str(body.get("targetDate") or "").strip()
                    if target_raw:
                        try:
                            from datetime import date as _date

                            target_date = _date.fromisoformat(target_raw[:10])
                        except ValueError:
                            self._json(
                                400,
                                {
                                    "ok": False,
                                    "error": "targetDate must be YYYY-MM-DD",
                                },
                            )
                            return
                    prompt = build_payment_prompt(
                        sess,
                        order_id,
                        collect=True,
                        poll_timeout=int(body.get("pollTimeout") or 90),
                        target_date=target_date,
                    )
                payload = {
                    "ok": bool(prompt.invoice_id or prompt.ready),
                    **prompt.as_dict(),
                }
                want_email = bool(body.get("emailPayment")) or bool(
                    str(body.get("toEmail") or "").strip()
                )
                if want_email and prompt.ready and prompt.payment_url:
                    try:
                        payload["paymentEmail"] = send_payment_email(
                            sess,
                            payment_url=prompt.payment_url,
                            invoice_id=prompt.invoice_id,
                            to_address=str(body.get("toEmail") or "").strip()
                            or None,
                            invoice_number=prompt.invoice_number,
                            amount_due=prompt.invoice_balance,
                        )
                    except Exception as exc:  # noqa: BLE001
                        payload["paymentEmail"] = {
                            "ok": False,
                            "error": str(exc)[:500],
                        }
                self._json(200 if prompt.invoice_id else 400, payload)
            except Exception as exc:  # noqa: BLE001
                self._json(400, {"ok": False, "error": str(exc)})
            return

        if path == "/api/payment-email":
            payment_url = str(body.get("paymentUrl") or "").strip()
            invoice_id = str(body.get("invoiceId") or "").strip()
            order_id = str(body.get("orderId") or "").strip()
            try:
                sess = _session()
                if not payment_url:
                    from payments import (
                        build_payment_prompt,
                        build_payment_prompt_for_invoice,
                    )

                    if invoice_id:
                        prompt = build_payment_prompt_for_invoice(sess, invoice_id)
                    elif order_id:
                        prompt = build_payment_prompt(
                            sess, order_id, collect=True, poll_timeout=90
                        )
                    else:
                        self._json(
                            400,
                            {
                                "ok": False,
                                "error": "paymentUrl or invoiceId/orderId is required",
                            },
                        )
                        return
                    if not prompt.payment_url:
                        self._json(
                            400,
                            {
                                "ok": False,
                                "error": prompt.blocked_reason
                                or "No paymentUrl available",
                                **prompt.as_dict(),
                            },
                        )
                        return
                    payment_url = prompt.payment_url
                    invoice_id = prompt.invoice_id or invoice_id
                    result = send_payment_email(
                        sess,
                        payment_url=payment_url,
                        invoice_id=invoice_id,
                        to_address=str(body.get("toEmail") or "").strip() or None,
                        invoice_number=prompt.invoice_number
                        or str(body.get("invoiceNumber") or "").strip()
                        or None,
                        amount_due=prompt.invoice_balance,
                        account_id=str(body.get("accountId") or "").strip() or None,
                    )
                else:
                    result = send_payment_email(
                        sess,
                        payment_url=payment_url,
                        invoice_id=invoice_id or None,
                        account_id=str(body.get("accountId") or "").strip() or None,
                        to_address=str(body.get("toEmail") or "").strip() or None,
                        invoice_number=str(body.get("invoiceNumber") or "").strip()
                        or None,
                        amount_due=(
                            float(body["amountDue"])
                            if body.get("amountDue") not in (None, "")
                            else None
                        ),
                    )
                self._json(200 if result.get("ok") else 400, result)
            except Exception as exc:  # noqa: BLE001
                self._json(400, {"ok": False, "error": str(exc)})
            return

        if path == "/api/checkout":
            quote_id = str(body.get("quoteId") or "").strip()
            if not quote_id:
                self._json(400, {"ok": False, "error": "quoteId is required"})
                return
            amend_raw = body.get("amendQty")
            amend_qty = int(amend_raw) if amend_raw not in (None, "") else None
            try:
                sess = _session()
                collect_raw = body.get("collectPayment")
                collect_payment = True if collect_raw is None else bool(collect_raw)
                chat_fast = bool(body.get("chatFast"))
                poll_timeout = int(body.get("pollTimeout") or (20 if chat_fast else 180))
                if chat_fast:
                    poll_timeout = min(poll_timeout, 20)
                result = checkout_quote_or_recover(
                    sess,
                    quote_id,
                    amend_qty=amend_qty,
                    poll_timeout=poll_timeout,
                    collect_payment=collect_payment,
                    chat_fast=chat_fast,
                )
                payload = result.as_dict()
                cached = QUOTE_CACHE.get(quote_id) or {}
                base = (sess._instance or "").rstrip("/")
                account_id = cached.get("accountId") or ""
                contact_id = cached.get("contactId") or ""
                order_id = payload.get("orderId") or ""
                asset_ids = payload.get("assetIds") or []
                related = quote_related_ids(sess, quote_id)
                opportunity_id = related.get("opportunityId") or ""
                if not account_id:
                    account_id = related.get("accountId") or ""
                    if account_id:
                        cached["accountId"] = account_id
                if not contact_id and account_id:
                    # Prefer cached contact; else first Contact on the Account.
                    try:
                        crow = sess.soql(
                            "SELECT Id, Name, Email FROM Contact "
                            f"WHERE AccountId = '{account_id}' "
                            "ORDER BY CreatedDate DESC LIMIT 1"
                        )
                        if crow:
                            contact_id = crow[0].get("Id") or ""
                            cached.setdefault("contactId", contact_id)
                            cached.setdefault(
                                "contactName", crow[0].get("Name") or ""
                            )
                            cached.setdefault(
                                "contactEmail", crow[0].get("Email") or ""
                            )
                    except Exception:  # noqa: BLE001
                        pass
                payment = payload.get("payment") or {}

                def _lex(entity: str, rid: str) -> str:
                    return f"{base}/lightning/r/{entity}/{rid}/view" if rid else ""

                links = {
                    "account": _lex("Account", account_id),
                    "contact": _lex("Contact", contact_id),
                    "opportunity": _lex("Opportunity", opportunity_id),
                    "quote": _lex("Quote", quote_id),
                    "order": _lex("Order", order_id),
                    "assets": [_lex("Asset", aid) for aid in asset_ids if aid],
                }
                if payment.get("invoiceUrl"):
                    links["invoice"] = payment["invoiceUrl"]
                if payment.get("paymentUrl"):
                    links["payNow"] = payment["paymentUrl"]

                # Demo handoff so Licenses & billing auto-opens without Create login.
                account_url = (
                    f"/account?accountId={account_id}&focus=invoices"
                    if account_id
                    else "/account"
                )
                ec_token = None
                if account_id and contact_id:
                    try:
                        from ec_handoff import mint_ec_token

                        ec_token = mint_ec_token(account_id, contact_id)
                        from urllib.parse import quote as _uq

                        account_url = (
                            f"/account?accountId={_uq(account_id, safe='')}"
                            f"&ecToken={_uq(ec_token, safe='')}"
                            f"&focus=invoices"
                        )
                    except Exception:  # noqa: BLE001
                        ec_token = None

                payload.update(
                    {
                        "instanceUrl": base,
                        "accountId": account_id,
                        "accountName": cached.get("accountName") or "",
                        "accountCreated": bool(cached.get("accountCreated")),
                        "contactId": contact_id,
                        "contactName": cached.get("contactName") or "",
                        "contactEmail": cached.get("contactEmail") or "",
                        "opportunityId": opportunity_id,
                        "planName": cached.get("planName") or "",
                        "monthlyTotal": cached.get("monthlyTotal"),
                        "links": links,
                        "ecToken": ec_token,
                        "accountUrl": account_url,
                    }
                )
                want_email = bool(body.get("emailPayment")) or bool(
                    str(body.get("toEmail") or "").strip()
                )
                if (
                    want_email
                    and payment.get("ready")
                    and payment.get("paymentUrl")
                ):
                    try:
                        payload["paymentEmail"] = send_payment_email(
                            sess,
                            payment_url=payment["paymentUrl"],
                            invoice_id=payment.get("invoiceId"),
                            account_id=account_id or None,
                            to_address=str(body.get("toEmail") or "").strip()
                            or cached.get("contactEmail")
                            or None,
                            invoice_number=payment.get("invoiceNumber"),
                            amount_due=payment.get("invoiceBalance"),
                        )
                    except Exception as exc:  # noqa: BLE001
                        payload["paymentEmail"] = {
                            "ok": False,
                            "error": str(exc)[:500],
                        }
                if cached is not None:
                    cached["checkout"] = payload
                self._json(200 if result.ok else 400, payload)
            except Exception as exc:  # noqa: BLE001
                self._json(400, {"ok": False, "error": str(exc)})
            return

        if path == "/api/docgen-pdf":
            quote_id = str(body.get("quoteId") or "").strip()
            if not quote_id:
                self._json(400, {"ok": False, "error": "quoteId is required"})
                return
            template_name = str(body.get("templateName") or DOCGEN_TEMPLATE).strip()
            try:
                result = generate_quote_pdf(
                    _session(),
                    quote_id,
                    template_name=template_name,
                    title=body.get("title"),
                    timeout=int(body.get("timeout") or 180),
                )
                payload = result.as_dict()
                cached = QUOTE_CACHE.get(quote_id)
                if cached is not None and result.ok:
                    cached["docgen"] = payload
                self._json(200 if result.ok else 400, payload)
            except Exception as exc:  # noqa: BLE001
                self._json(400, {"ok": False, "error": str(exc)})
            return

        if path == "/api/quote-email":
            quote_id = str(body.get("quoteId") or "").strip()
            if not quote_id:
                self._json(400, {"ok": False, "error": "quoteId is required"})
                return
            to_address = str(body.get("toEmail") or body.get("toAddress") or "").strip() or None
            cv_id = str(body.get("contentVersionId") or "").strip() or None
            attach = body.get("attachPdf")
            if attach is None:
                attach_pdf = True
            else:
                attach_pdf = bool(attach)
            try:
                payload = send_quote_email(
                    _session(),
                    quote_id,
                    to_address=to_address,
                    content_version_id=cv_id,
                    attach_pdf=attach_pdf,
                    template_name=str(body.get("templateName") or DOCGEN_TEMPLATE).strip()
                    or None,
                    timeout=int(body.get("timeout") or 180),
                )
                cached = QUOTE_CACHE.get(quote_id)
                if cached is not None and payload.get("ok"):
                    cached["quoteEmail"] = payload
                self._json(200 if payload.get("ok") else 400, payload)
            except Exception as exc:  # noqa: BLE001
                self._json(400, {"ok": False, "error": str(exc)})
            return

        self._send(404, b"Not found", "text/plain")


def main() -> int:
    global ORG_ALIAS, SESSION, CORS_ORIGIN
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--org",
        default=os.environ.get("SF_ORG_ALIAS") or "master-demo",
        help="CCI org alias when not using SF_* env auth",
    )
    parser.add_argument("--port", type=int, default=int(os.environ.get("PORT") or 8765))
    parser.add_argument(
        "--host",
        default=os.environ.get("BFF_HOST") or "127.0.0.1",
        help="Bind address; use 0.0.0.0 for tunnels / containers",
    )
    parser.add_argument(
        "--cors-origin",
        default=os.environ.get("BFF_CORS_ORIGIN") or "",
        help='Optional CORS Allow-Origin (e.g. "*" for demos)',
    )
    parser.add_argument(
        "--ssl-cert",
        default=os.environ.get("BFF_SSL_CERT") or "",
        help="PEM cert path for HTTPS (pair with --ssl-key)",
    )
    parser.add_argument(
        "--ssl-key",
        default=os.environ.get("BFF_SSL_KEY") or "",
        help="PEM private key path for HTTPS",
    )
    args = parser.parse_args()
    ORG_ALIAS = args.org
    CORS_ORIGIN = args.cors_origin
    SESSION = None
    scheme = "https" if (args.ssl_cert and args.ssl_key) else "http"
    print(f"BambooHR Get Pricing BFF → org={args.org}")
    print(f"Listening on {scheme}://{args.host}:{args.port}/")
    sess = _session()
    print(f"Auth ready: mode={sess.auth_mode} label={sess.alias}")
    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    if args.ssl_cert and args.ssl_key:
        import ssl

        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(args.ssl_cert, args.ssl_key)
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    httpd.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
