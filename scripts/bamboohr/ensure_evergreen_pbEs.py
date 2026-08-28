#!/usr/bin/env python3
"""Ensure Bamboo Evergreen Monthly PSM / PSMO / PBEs (safe on a used org).

Does **not** re-run ``bh-pricing`` Insert. Creates only missing records:

1. ``Evergreen Monthly`` ProductSellingModel (if absent)
2. ProductSellingModelOption for each BAMBOO-* product that already has
   Term Monthly TermDefined (required before PBE)
3. Evergreen Monthly PricebookEntry clones of Term Monthly peers

Usage::

  ~/.local/pipx/venvs/cumulusci/bin/python \\
    scripts/bamboohr/ensure_evergreen_pbEs.py --org master-demo

Auth: uses the same JWT / CCI path as the Get Pricing BFF ``OrgSession``.
If CCI SFDMU fails with an expired access token, this script can still work
when JWT env / CCI keyring for the org is valid.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "get_pricing"))

from service import OrgSession  # noqa: E402


def _ensure_psm(session: OrgSession) -> str:
    rows = session.soql(
        "SELECT Id FROM ProductSellingModel "
        "WHERE Name = 'Evergreen Monthly' AND SellingModelType = 'Evergreen' "
        "LIMIT 1"
    )
    if rows:
        print(f"PSM Evergreen Monthly exists: {rows[0]['Id']}")
        return rows[0]["Id"]
    rid = session.create(
        "ProductSellingModel",
        {
            "Name": "Evergreen Monthly",
            "SellingModelType": "Evergreen",
            "PricingTerm": 1,
            "PricingTermUnit": "Months",
            "Status": "Active",
            "DoesAutoRenewAssetByDefault": False,
        },
    )
    print(f"created PSM Evergreen Monthly: {rid}")
    return rid


def _ensure_psmos(session: OrgSession, eg_psm_id: str) -> int:
    term_opts = session.soql(
        "SELECT Id, Product2Id, ProrationPolicyId, IsDefault, "
        "Product2.StockKeepingUnit, Product2.IsActive "
        "FROM ProductSellingModelOption "
        "WHERE ProductSellingModel.Name = 'Term Monthly' "
        "AND ProductSellingModel.SellingModelType = 'TermDefined' "
        "AND Product2.StockKeepingUnit LIKE 'BAMBOO-%' "
        "AND Product2.IsActive = true"
    )
    created = 0
    for row in term_opts:
        sku = (row.get("Product2") or {}).get("StockKeepingUnit") or ""
        pid = row.get("Product2Id")
        existing = session.soql(
            "SELECT Id FROM ProductSellingModelOption "
            f"WHERE Product2Id = '{pid}' "
            f"AND ProductSellingModelId = '{eg_psm_id}' "
            "LIMIT 1"
        )
        if existing:
            continue
        fields: dict = {
            "Product2Id": pid,
            "ProductSellingModelId": eg_psm_id,
            "IsDefault": False,
        }
        if row.get("ProrationPolicyId"):
            fields["ProrationPolicyId"] = row["ProrationPolicyId"]
        try:
            rid = session.create("ProductSellingModelOption", fields)
        except Exception as exc:  # noqa: BLE001
            print(f"  PSMO skip {sku}: {exc}")
            continue
        created += 1
        print(f"  PSMO {sku}: {rid}")
    print(f"PSMOs created={created} (of {len(term_opts)} active Term Monthly peers)")
    return created


def _ensure_pbes(session: OrgSession, eg_psm_id: str) -> tuple[int, int, int]:
    term_rows = session.soql(
        "SELECT Id, Product2Id, UnitPrice, CurrencyIsoCode, "
        "Product2.StockKeepingUnit, Product2.IsActive "
        "FROM PricebookEntry "
        "WHERE Pricebook2.IsStandard = true "
        "AND IsActive = true "
        "AND ProductSellingModel.Name = 'Term Monthly' "
        "AND ProductSellingModel.SellingModelType = 'TermDefined' "
        "AND Product2.StockKeepingUnit LIKE 'BAMBOO-%' "
        "AND Product2.IsActive = true"
    )
    pb = session.soql(
        "SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1"
    )[0]["Id"]
    created = 0
    skipped = 0
    failed = 0
    for row in term_rows:
        sku = (row.get("Product2") or {}).get("StockKeepingUnit") or ""
        cur = row.get("CurrencyIsoCode") or "USD"
        existing = session.soql(
            "SELECT Id FROM PricebookEntry "
            "WHERE Pricebook2.IsStandard = true "
            f"AND Product2.StockKeepingUnit = '{sku}' "
            f"AND CurrencyIsoCode = '{cur}' "
            "AND ProductSellingModel.Name = 'Evergreen Monthly' "
            "AND ProductSellingModel.SellingModelType = 'Evergreen' "
            "LIMIT 1"
        )
        if existing:
            skipped += 1
            continue
        try:
            session.create(
                "PricebookEntry",
                {
                    "Pricebook2Id": pb,
                    "Product2Id": row["Product2Id"],
                    "ProductSellingModelId": eg_psm_id,
                    "UnitPrice": row["UnitPrice"],
                    "CurrencyIsoCode": cur,
                    "IsActive": True,
                    "UseStandardPrice": False,
                },
            )
        except Exception as exc:  # noqa: BLE001
            failed += 1
            print(f"  PBE fail {sku} {cur}: {exc}")
            continue
        created += 1
        print(f"  PBE {sku} {cur}")
    return created, skipped, failed


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--org", default="master-demo")
    args = ap.parse_args()
    session = OrgSession(args.org)

    eg_psm_id = _ensure_psm(session)
    # Evergreen PSM must be Active for active PBEs.
    try:
        session.patch(
            "ProductSellingModel",
            eg_psm_id,
            {"Status": "Active"},
        )
    except Exception:  # noqa: BLE001
        pass
    _ensure_psmos(session, eg_psm_id)
    created, skipped, failed = _ensure_pbes(session, eg_psm_id)
    print(f"PBEs created={created} skipped={skipped} failed={failed}")

    # Self-serve critical SKUs
    need = ("BAMBOO-CORE", "BAMBOO-PRO", "BAMBOO-ADD-TIME", "BAMBOO-CORE-FLAT-SM")
    missing = []
    for sku in need:
        rows = session.soql(
            "SELECT Id FROM PricebookEntry "
            "WHERE Pricebook2.IsStandard = true "
            f"AND Product2.StockKeepingUnit = '{sku}' "
            "AND CurrencyIsoCode = 'USD' "
            "AND ProductSellingModel.Name = 'Evergreen Monthly' "
            "AND ProductSellingModel.SellingModelType = 'Evergreen' "
            "AND IsActive = true "
            "LIMIT 1"
        )
        if not rows:
            missing.append(sku)
    if missing:
        print(f"MISSING critical Evergreen USD PBEs: {', '.join(missing)}", file=sys.stderr)
        return 1
    print("critical self-serve Evergreen USD PBEs OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
