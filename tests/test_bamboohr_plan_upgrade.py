#!/usr/bin/env python3
"""Offline tests: Core → Pro in-product expansion on Licenses."""

from __future__ import annotations

import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GP = os.path.join(REPO_ROOT, "scripts", "bamboohr", "get_pricing")
sys.path.insert(0, GP)

from datetime import date

import account_console as ac  # noqa: E402
import checkout as co  # noqa: E402
from service import remaining_service_end  # noqa: E402

RESULTS: list[tuple[str, bool]] = []


def check(name: str, condition: bool) -> None:
    RESULTS.append((name, bool(condition)))
    print(f"  [{'PASS' if condition else 'FAIL'}] {name}")


def test_offer_core_to_pro() -> None:
    print("\nexpansion offer")
    offer = ac.plan_expansion_offer(
        plan_sku="BAMBOO-CORE",
        seats=12,
        needs="hiring, performance",
    )
    check("available on Core", offer["available"] is True)
    check("to Pro", offer["toSku"] == "BAMBOO-PRO")
    check("Pro list 17", offer["listPepmTo"] == 17.0)
    check("delta 7", offer["deltaPepm"] == 7.0)
    check("performance copy", "performance" in offer["copy"].lower())


def test_offer_pro_is_current() -> None:
    print("\nalready on Pro")
    offer = ac.plan_expansion_offer(plan_sku="BAMBOO-PRO", seats=12)
    check("not available", offer["available"] is False)
    check("reason current", offer["reason"] == "current")
    check("elite is sales", "sales" in offer["copy"].lower() or "person" in offer["copy"].lower())


def test_current_plan_rank() -> None:
    print("\nplan from assets")
    assets = [
        {"sku": "BAMBOO-ADD-TIME", "quantity": 12, "id": "02iA"},
        {"sku": "BAMBOO-CORE", "quantity": 12, "id": "02iC"},
    ]
    plan = ac.current_plan_from_assets(assets)
    check("picks Core", (plan or {}).get("sku") == "BAMBOO-CORE")


def test_current_plan_ignores_future_pro() -> None:
    print("\nlive plan is today's ASP")
    mixed = [
        {"sku": "BAMBOO-CORE", "quantity": 12, "id": "02iC"},
        {"sku": "BAMBOO-PRO", "quantity": 0, "id": "02iP"},
    ]
    plan = ac.current_plan_from_assets(mixed)
    check("live Core while Pro qty 0", (plan or {}).get("sku") == "BAMBOO-CORE")
    upcoming = ac.upcoming_plan_from_assets(mixed)
    check("upcoming is Pro", (upcoming or {}).get("sku") == "BAMBOO-PRO")
    as_of = [
        {"sku": "BAMBOO-CORE", "quantity": 12, "quantityAsOf": 0, "id": "02iC"},
        {"sku": "BAMBOO-PRO", "quantity": 0, "quantityAsOf": 12, "id": "02iP"},
    ]
    later = ac.current_plan_from_assets(as_of, quantity_field="quantityAsOf")
    check("on Pro start date plan is Pro", (later or {}).get("sku") == "BAMBOO-PRO")
    future_core = [{"sku": "BAMBOO-CORE", "quantity": 0, "id": "02iC"}]
    check("no live plan before start", ac.current_plan_from_assets(future_core) is None)
    check(
        "upcoming Core before start",
        (ac.upcoming_plan_from_assets(future_core) or {}).get("sku") == "BAMBOO-CORE",
    )
    swapped = [
        {"sku": "BAMBOO-CORE", "quantity": 0, "id": "02iC"},
        {"sku": "BAMBOO-PRO", "quantity": 0, "id": "02iP"},
    ]
    check("no live plan after future swap", ac.current_plan_from_assets(swapped) is None)
    check(
        "upcoming after swap is Pro not Core",
        (ac.upcoming_plan_from_assets(swapped) or {}).get("sku") == "BAMBOO-PRO",
    )


def test_resolve_upgrade() -> None:
    print("\nresolve upgrade")
    owned = [
        {"sku": "BAMBOO-CORE", "quantity": 12, "id": "02iCORE"},
        {"sku": "BAMBOO-ADD-TIME", "quantity": 12, "id": "02iT"},
    ]
    ok = ac.resolve_upgrade(owned, "BAMBOO-PRO")
    check("ok", ok["ok"] is True)
    check("replace Core", ok["replaceSkus"] == ["BAMBOO-CORE"])
    check("asset id", ok["replaceAssetIds"] == ["02iCORE"])
    bad = ac.resolve_upgrade(owned, "BAMBOO-ELITE")
    check("elite blocked", bad["ok"] is False)
    none = ac.resolve_upgrade(owned, None)
    check("no-op ok", none["ok"] is True and none["addSku"] is None)
    scheduled = ac.resolve_upgrade(
        [
            {"sku": "BAMBOO-CORE", "quantity": 12, "id": "02iCORE"},
            {"sku": "BAMBOO-PRO", "quantity": 0, "id": "02iPRO"},
        ],
        "BAMBOO-PRO",
    )
    check("scheduled Pro blocks upgrade", scheduled["ok"] is False)
    check("scheduled copy", "scheduled" in str(scheduled.get("error") or "").lower())
    swapped = ac.resolve_upgrade(
        [
            {"sku": "BAMBOO-CORE", "quantity": 0, "id": "02iCORE"},
            {"sku": "BAMBOO-PRO", "quantity": 0, "id": "02iPRO"},
        ],
        "BAMBOO-PRO",
    )
    check("future swap blocks upgrade", swapped["ok"] is False)
    check(
        "future swap is scheduled not you're on Pro",
        "scheduled" in str(swapped.get("error") or "").lower(),
    )
    future = ac.resolve_upgrade(
        [{"sku": "BAMBOO-CORE", "quantity": 0, "id": "02iCORE"}],
        "BAMBOO-PRO",
    )
    check("future-start Core can upgrade", future["ok"] is True)
    check("future-start replaces Core", future.get("replaceAssetIds") == ["02iCORE"])


def test_initiate_upgrade_body_omits_unit_price() -> None:
    print("\nInitiate Upgrade body")
    from datetime import date, datetime, timezone

    when = datetime(2026, 8, 17, tzinfo=timezone.utc)
    end = date(2027, 8, 17)
    body = co.build_initiate_upgrade_body(
        swap_start=when,
        asset_id="02iCORE",
        out_quantity=12,
        product2_id="01tPRO",
        pricebook_entry_id="01uPRO",
        in_quantity=12,
        line_start=when.date(),
        line_end=end,
        product_selling_model_id="0jPPSM",
    )
    record = body["swapGroups"]["groups"][0]["inGroup"]["records"][0]["record"]
    check("output is Quote", body["outputRecordType"] == "Quote")
    check("out asset", body["swapGroups"]["groups"][0]["outGroup"]["swapAssets"][0]["assetId"] == "02iCORE")
    check("out qty 12", body["swapGroups"]["groups"][0]["outGroup"]["swapAssets"][0]["quantity"] == 12)
    check("in qty 12", record["Quantity"] == "12")
    check("no UnitPrice", "UnitPrice" not in record)
    check("has Product2Id", record["Product2Id"] == "01tPRO")
    check("has PBE", record["PricebookEntryId"] == "01uPRO")
    check("has EndDate", record["EndDate"] == "2027-08-17")
    check("period Anniversary", record["PeriodBoundary"] == "Anniversary")
    check("billing Monthly", record["BillingFrequency"] == "Monthly")
    check("has PSM", record["ProductSellingModelId"] == "0jPPSM")
    folded = co.build_initiate_upgrade_body(
        swap_start=when,
        asset_id="02iCORE",
        out_quantity=12,
        product2_id="01tPRO",
        pricebook_entry_id="01uPRO",
        in_quantity=20,
        line_start=when.date(),
        line_end=end,
    )
    in_rec = folded["swapGroups"]["groups"][0]["inGroup"]["records"][0]["record"]
    check("folded seats on UpgradeTo", in_rec["Quantity"] == "20")
    cfg = co.upgrade_preview_cfg(
        to_sku="BAMBOO-PRO",
        quantity=20,
        start_iso="2026-08-17",
        asset_ids=["02iCORE"],
    )
    check("sticky cfg has to sku", "to=BAMBOO-PRO" in cfg)
    check("sticky cfg has qty", "qty=20" in cfg)
    m2m = co.build_initiate_upgrade_body(
        swap_start=when,
        asset_id="02iCORE",
        out_quantity=12,
        product2_id="01tPRO",
        pricebook_entry_id="01uPRO",
        in_quantity=12,
        line_start=when.date(),
        line_end=None,
    )
    m2m_rec = m2m["swapGroups"]["groups"][0]["inGroup"]["records"][0]["record"]
    check("missing end defaults to +1 month", m2m_rec["EndDate"] == "2026-09-17")


def test_change_lines_credit_replaced_plan() -> None:
    print("\nproration credits Core")
    before = [
        {
            "sku": "BAMBOO-CORE",
            "name": "Core",
            "qty": 12,
            "netPepm": 10.0,
            "monthly": 120.0,
            "isFlat": False,
        }
    ]
    after = [
        {
            "sku": "BAMBOO-PRO",
            "name": "Pro",
            "qty": 12,
            "netPepm": 17.0,
            "monthly": 204.0,
            "isFlat": False,
            "isNew": True,
        }
    ]
    lines, due = ac._change_lines_with_proration(
        before_lines=before,
        after_lines=after,
        baseline_qty=12,
        target_qty=12,
        months=1.0,
    )
    by = {l["sku"]: l for l in lines}
    check("has Core credit", "BAMBOO-CORE" in by)
    check("Core qty after 0", by["BAMBOO-CORE"]["qtyAfter"] == 0)
    check("Core charge negative", by["BAMBOO-CORE"]["chargeMonthly"] < 0)
    check("has Pro", "BAMBOO-PRO" in by)
    check("Pro is new", by["BAMBOO-PRO"]["isNew"] is True)
    check("net is +7 PEPM × 12", round(due, 2) == 84.0)
    lines_yr, due_yr = ac._change_lines_with_proration(
        before_lines=before,
        after_lines=after,
        baseline_qty=12,
        target_qty=12,
        months=11.0,
    )
    by_yr = {l["sku"]: l for l in lines_yr}
    check("annual remaining is 11 months of +$7×12", round(due_yr, 2) == 924.0)
    check("annual charge >> month-to-month", due_yr > due * 5)
    check("annual still credits Core", by_yr["BAMBOO-CORE"]["chargeMonthly"] < 0)
    check("annual still adds Pro", by_yr["BAMBOO-PRO"]["isNew"] is True)


def test_proration_months_follows_asset_window() -> None:
    print("\nproration window is remaining Core term")
    from datetime import date, datetime, timezone

    start = datetime(2026, 8, 19, tzinfo=timezone.utc)
    m2m, d_m2m = ac._proration_months(
        amend_start=start, term_end=date(2026, 9, 19)
    )
    annual, d_yr = ac._proration_months(
        amend_start=start, term_end=date(2027, 8, 17)
    )
    missing, _ = ac._proration_months(amend_start=start, term_end=None)
    check("missing end does not invent a year", missing is None)
    check("month-to-month ~1 month", m2m is not None and 0.9 <= m2m <= 1.15)
    check("annual remaining > 10 months", annual is not None and annual >= 10)
    check("annual days >> month-to-month days", (d_yr or 0) > (d_m2m or 0) * 6)


def test_seat_amend_after_scheduled_upgrade() -> None:
    print("\nseat amend after scheduled Pro")
    as_of = [
        {
            "sku": "BAMBOO-CORE",
            "quantity": 12,
            "quantityAsOf": 0,
            "id": "02iC",
            "isFlat": False,
        },
        {
            "sku": "BAMBOO-PRO",
            "quantity": 0,
            "quantityAsOf": 12,
            "id": "02iP",
            "isFlat": False,
        },
        {
            "sku": "BAMBOO-ADD-TIME",
            "quantity": 12,
            "quantityAsOf": 12,
            "id": "02iT",
            "isFlat": False,
        },
    ]
    in_effect = ac._plan_in_effect_from_assets(as_of)
    check("in-effect plan is Pro", (in_effect or {}).get("sku") == "BAMBOO-PRO")
    check(
        "baseline is Pro seats not Core 0",
        int(ac._asset_qty(in_effect or {}, field="quantityAsOf")) == 12,
    )
    targets = [
        a
        for a in as_of
        if not a.get("isFlat") and ac._asset_qty(a, field="quantityAsOf") > 0
    ]
    skus = {a["sku"] for a in targets}
    check("does not add seats to Core at 0", "BAMBOO-CORE" not in skus)
    check("amends Pro", "BAMBOO-PRO" in skus)
    check("keeps Time Tracking", "BAMBOO-ADD-TIME" in skus)


def test_asset_quantity_at_no_asp_is_zero() -> None:
    print("\nASP as-of with no covering period")
    from datetime import datetime, timezone

    class _Fake:
        def soql(self, q: str):
            if "AssetStatePeriod" in q:
                return [
                    {
                        "Quantity": 12,
                        "Mrr": 120,
                        "StartDate": "2026-08-01",
                        "EndDate": "2026-08-18",
                    }
                ]
            return [{"QuantityChange": 12, "TotalQuantity": 12}]

    covering = co.asset_quantity_at(
        _Fake(), "02iCORE", as_of=datetime(2026, 8, 18, tzinfo=timezone.utc)
    )
    after = co.asset_quantity_at(
        _Fake(), "02iCORE", as_of=datetime(2026, 8, 19, tzinfo=timezone.utc)
    )
    check("covering ASP is 12", covering == 12.0)
    check("no ASP is 0 not TotalQuantity 12", after == 0.0)


def test_addon_line_window_remaining_term() -> None:
    print("\nadd-module remaining window")
    start, end = ac.addon_line_window(
        amend_start=date(2026, 8, 19),
        plan_start=date(2026, 8, 19),
        plan_end=date(2027, 8, 17),
        today=date(2026, 8, 18),
    )
    check("start is plan start", start == date(2026, 8, 19))
    check("end is remaining Core not +365", end == date(2027, 8, 17))
    m2m_s, m2m_e = ac.addon_line_window(
        amend_start=date(2026, 8, 17),
        plan_start=None,
        plan_end=None,
        today=date(2026, 8, 17),
    )
    check("missing end is +1 month", m2m_e == date(2026, 9, 17))
    check("missing end start stays", m2m_s == date(2026, 8, 17))
    fut_s, fut_e = ac.addon_line_window(
        amend_start=date(2026, 8, 18),
        plan_start=date(2026, 9, 1),
        plan_end=date(2026, 10, 1),
        today=date(2026, 8, 18),
    )
    check("future Core start", fut_s == date(2026, 9, 1))
    check("future Core end", fut_e == date(2026, 10, 1))
    asp = remaining_service_end(date(2026, 8, 19), None, date(2027, 8, 17))
    check("annual ASP end wins over +1 month", asp == date(2027, 8, 17))
    missing = remaining_service_end(date(2026, 8, 19), None, None)
    check("no window is +1 month", missing == date(2026, 9, 19))


def test_fill_missing_lifecycle_ends_from_asp() -> None:
    print("\nASP fills blank Asset lifecycle end")

    class _Fake:
        def soql(self, q: str):
            assert "AssetStatePeriod" in q
            return [
                {"AssetId": "02iA", "EndDate": "2027-08-17"},
                {"AssetId": "02iA", "EndDate": "2026-09-01"},
            ]

    blank = [{"id": "02iA", "lifecycleEndDate": None}]
    ac._fill_missing_lifecycle_ends(_Fake(), blank)
    check("latest ASP end applied", str(blank[0]["lifecycleEndDate"])[:10] == "2027-08-17")
    kept = [{"id": "02iB", "lifecycleEndDate": "2026-10-01"}]
    ac._fill_missing_lifecycle_ends(_Fake(), kept)
    check("existing end kept", kept[0]["lifecycleEndDate"] == "2026-10-01")


def test_account_js_term_end_does_not_invent_year() -> None:
    print("\nLicenses rail does not invent +365")
    path = os.path.join(GP, "static", "account.js")
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    start = text.find("const termEndDate = () =>")
    check("termEndDate helper present", start > 0)
    chunk = text[start : start + 280]
    check("no +1 year fallback", "getUTCFullYear() + 1" not in chunk)
    check("withholds when missing", "|| null" in chunk)


def test_checkout_address_defaults() -> None:
    print("\ncheckout address defaults")
    us = co.checkout_address_defaults(billing_country="US")
    check("US billing street", us["BillingStreet"] == "1 Market Street")
    check("US billing city", us["BillingCity"] == "New York")
    check("US shipping mirrors billing city", us["ShippingCity"] == "New York")
    uk = co.checkout_address_defaults(billing_country="GB")
    check("UK country GB", uk["BillingCountry"] == "GB")
    cad = co.checkout_address_defaults(currency="CAD")
    check("CAD city Toronto", cad["BillingCity"] == "Toronto")


def main() -> int:
    test_offer_core_to_pro()
    test_offer_pro_is_current()
    test_current_plan_rank()
    test_current_plan_ignores_future_pro()
    test_resolve_upgrade()
    test_seat_amend_after_scheduled_upgrade()
    test_asset_quantity_at_no_asp_is_zero()
    test_change_lines_credit_replaced_plan()
    test_proration_months_follows_asset_window()
    test_initiate_upgrade_body_omits_unit_price()
    test_addon_line_window_remaining_term()
    test_fill_missing_lifecycle_ends_from_asp()
    test_account_js_term_end_does_not_invent_year()
    test_checkout_address_defaults()
    passed = sum(1 for _, ok in RESULTS if ok)
    print(f"\n{passed}/{len(RESULTS)} passed")
    return 0 if passed == len(RESULTS) else 1


if __name__ == "__main__":
    raise SystemExit(main())
