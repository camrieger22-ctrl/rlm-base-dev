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
            if lines:
                rows = "".join(
                    (
                        "<tr>"
                        f"<td>{li.get('name') or li.get('sku')}</td>"
                        f"<td>{li.get('quantity')}</td>"
                        f"<td>${float(li.get('netPepm') or 0):.2f}</td>"
                        f"<td>${float(li.get('monthly') or 0):,.2f}</td>"
                        "</tr>"
                    )
                    for li in lines
                )
                line_html = (
                    "<table class='lines'><thead><tr>"
                    "<th>Product</th><th>Qty</th><th>Net PEPM</th><th>Monthly</th>"
                    "</tr></thead><tbody>"
                    + rows
                    + "</tbody></table>"
                )
            else:
                line_html = "<p class='muted'>No line detail.</p>"
            bundle_note = (
                "<p class='bundle-note'>Path B Bundle &amp; Save applied "
                "(15% on Payroll + Benefits).</p>"
                if data.get("pathBBundleSave") and not data.get("freeTrial")
                else ""
            )
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
                    f"<p class='trial-note'><strong>{days}-day free trial</strong> "
                    f"(convert later). Quote totals are $0 now. "
                    "Checkout creates $0 trial assets; use Convert to paid for a "
                    "new paid quote.</p>"
                )
                paid_lines = data.get("paidLineItems") or []
                if paid_lines:
                    paid_rows = "".join(
                        (
                            "<tr>"
                            f"<td>{li.get('name') or li.get('sku')}</td>"
                            f"<td>{li.get('quantity')}</td>"
                            f"<td>${float(li.get('netPepm') or 0):.2f}</td>"
                            f"<td>${float(li.get('monthly') or 0):,.2f}</td>"
                            "</tr>"
                        )
                        for li in paid_lines
                    )
                    paid_table = (
                        "<table class='lines'><thead><tr>"
                        "<th>Product</th><th>Qty</th><th>Net PEPM</th><th>Monthly</th>"
                        "</tr></thead><tbody>"
                        + paid_rows
                        + "</tbody></table>"
                    )
                else:
                    paid_table = ""
                path_b_bit = (
                    " Includes Path B Bundle &amp; Save (15% on Payroll + Benefits)."
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
                "{{bundleSaveNote}}": bundle_note,
                "{{trialNote}}": trial_note,
                "{{convertPreview}}": convert_section,
                "{{convertTrialButton}}": convert_btn,
                "{{warnings}}": (
                    "<ul>"
                    + "".join(f"<li>{w}</li>" for w in data.get("warnings") or [])
                    + "</ul>"
                    if data.get("warnings")
                    else "<p class='muted'>No channel warnings.</p>"
                ),
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
