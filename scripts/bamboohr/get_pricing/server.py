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
from urllib.parse import urlparse

HERE = Path(__file__).resolve().parent
STATIC = HERE / "static"
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from checkout import checkout_quote  # noqa: E402
from docgen import (  # noqa: E402
    DEFAULT_TEMPLATE,
    download_content_version,
    generate_quote_pdf,
)
from service import GetPricingRequest, OrgSession, get_pricing  # noqa: E402

# In-memory quote summaries for /quote/{id} branded page (demo only).
QUOTE_CACHE: dict[str, dict] = {}
ORG_ALIAS = "master-demo"
SESSION: OrgSession | None = None
CORS_ORIGIN = ""  # empty = omit CORS headers; "*" or origin for hosted demos
DOCGEN_TEMPLATE = os.environ.get("DOCGEN_TEMPLATE_NAME") or DEFAULT_TEMPLATE


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
        if "Path B Bundle" not in str(w) and "Bundle & Save" not in str(w)
    ]
    if not shown:
        return ""
    return "<ul>" + "".join(f"<li>{w}</li>" for w in shown) + "</ul>"


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
                self._json(
                    200,
                    {
                        "ok": True,
                        "service": "bamboohr-get-pricing",
                        "authMode": sess.auth_mode,
                        "org": sess.alias,
                    },
                )
            except Exception as exc:  # noqa: BLE001
                self._json(503, {"ok": False, "error": str(exc)})
            return
        if path in ("/", "/index.html"):
            self._send(
                200,
                (STATIC / "index.html").read_bytes(),
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

        if path.startswith("/quote/"):
            qid = path.split("/quote/", 1)[1].strip("/")
            data = QUOTE_CACHE.get(qid)
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
                "{{quoteId}}": data["quoteId"] or "",
                "{{accountName}}": data["accountName"],
                "{{lineItems}}": line_html,
                "{{pricingLogic}}": pricing_logic,
                "{{discountStack}}": discount_stack,
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

        if path == "/api/get-pricing":
            try:
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
                )
                result = get_pricing(_session(), req)
                payload = result.as_dict()
                if result.quote_id:
                    QUOTE_CACHE[result.quote_id] = payload
                    payload["quoteUrl"] = f"/quote/{result.quote_id}"
                self._json(200, payload)
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
                req = GetPricingRequest(
                    headcount=int(cached.get("headcount") or 0),
                    country=str(cached.get("country") or "US"),
                    plan_sku=str(cached.get("planSku") or "BAMBOO-PRO"),
                    addon_skus=list(cached.get("addonSkus") or []),
                    place_quote=True,
                    free_trial=False,
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

        if path == "/api/checkout":
            quote_id = str(body.get("quoteId") or "").strip()
            if not quote_id:
                self._json(400, {"ok": False, "error": "quoteId is required"})
                return
            amend_raw = body.get("amendQty")
            amend_qty = int(amend_raw) if amend_raw not in (None, "") else None
            try:
                result = checkout_quote(
                    _session(),
                    quote_id,
                    amend_qty=amend_qty,
                    poll_timeout=int(body.get("pollTimeout") or 180),
                )
                payload = result.as_dict()
                cached = QUOTE_CACHE.get(quote_id)
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
    args = parser.parse_args()
    ORG_ALIAS = args.org
    CORS_ORIGIN = args.cors_origin
    SESSION = None
    print(f"BambooHR Get Pricing BFF → org={args.org}")
    print(f"Listening on http://{args.host}:{args.port}/")
    sess = _session()
    print(f"Auth ready: mode={sess.auth_mode} label={sess.alias}")
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
