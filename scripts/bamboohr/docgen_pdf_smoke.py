#!/usr/bin/env python3
"""Smoke: generate Bamboo-branded quote PDF for a Get Pricing quote.

Usage:
  ~/.local/pipx/venvs/cumulusci/bin/python \\
    scripts/bamboohr/docgen_pdf_smoke.py --target-org master-demo
  ~/.local/pipx/venvs/cumulusci/bin/python \\
    scripts/bamboohr/docgen_pdf_smoke.py --target-org master-demo \\
    --quote-id 0Q0… --out /tmp/bamboo-quote.pdf
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent / "get_pricing"
sys.path.insert(0, str(HERE))

from docgen import (  # noqa: E402
    DEFAULT_TEMPLATE,
    download_content_version,
    generate_quote_pdf,
)
from service import GetPricingRequest, OrgSession, get_pricing  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target-org", default="master-demo")
    parser.add_argument("--quote-id", default="")
    parser.add_argument("--template", default=DEFAULT_TEMPLATE)
    parser.add_argument("--out", default="")
    args = parser.parse_args()

    session = OrgSession(args.target_org)
    quote_id = args.quote_id.strip()
    if not quote_id:
        print("Placing a small Get Pricing quote for DocGen…")
        result = get_pricing(
            session,
            GetPricingRequest(
                headcount=25,
                country="US",
                plan_sku="BAMBOO-PRO",
                addon_skus=["BAMBOO-ADD-PAYROLL", "BAMBOO-ADD-BENEFITS"],
                place_quote=True,
            ),
        )
        quote_id = result.quote_id or ""
        if not quote_id:
            raise SystemExit("get_pricing did not return a quoteId")
        print(f"  quote={quote_id}")

    print(f"Generating PDF via {args.template}…")
    pdf = generate_quote_pdf(
        session, quote_id, template_name=args.template, timeout=180
    )
    if not pdf.ok:
        print(f"FAIL: {pdf.error}", file=sys.stderr)
        print(f"  status={pdf.status} dgp={pdf.dgp_id}", file=sys.stderr)
        return 1

    print(
        f"  PASS dgp={pdf.dgp_id} cv={pdf.content_version_id} "
        f"ext={pdf.file_extension} download={pdf.download_path}"
    )
    if pdf.file_extension != "pdf":
        print(
            f"WARN: expected pdf, got {pdf.file_extension}",
            file=sys.stderr,
        )

    if args.out:
        raw, filename, _ctype = download_content_version(
            session, pdf.content_version_id
        )
        out = Path(args.out)
        out.write_bytes(raw)
        print(f"  Wrote {out} ({len(raw)} bytes, name={filename})")
        if not raw.startswith(b"%PDF"):
            print("WARN: file does not start with %PDF", file=sys.stderr)
            return 1

    print("DocGen PDF smoke PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
