"""Discard safety + acquisition-draft name helpers (no live org)."""

from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "scripts", "bamboohr", "get_pricing"))

import pricing_preview as pp  # noqa: E402
import qualify_crm as qc  # noqa: E402

RESULTS: list[tuple[str, bool]] = []


def check(name: str, cond: bool) -> None:
    RESULTS.append((name, bool(cond)))
    print(("  OK  " if cond else " FAIL ") + name)


class QuoteSession:
    def __init__(self, row: dict):
        self.row = row
        self.deletes: list[tuple[str, str]] = []
        self.patches: list[tuple] = []

    def soql(self, q: str):
        u = q.upper()
        if "FROM QUOTE" in u and "QUOTELINEITEM" not in u:
            return [self.row]
        if "FROM QUOTE" in u and "OPPORTUNITYID" in u:
            return []
        return []

    def delete(self, sobject, record_id):
        self.deletes.append((sobject, record_id))

    def patch(self, sobject, record_id, fields):
        self.patches.append((sobject, record_id, dict(fields)))


def test_discard_preview_only() -> None:
    print("\ndiscard_preview_quote")
    preview = QuoteSession(
        {
            "Id": "0Q0PREVIEW0000001",
            "OpportunityId": "006OPP0000000001",
            "Name": "Get Pricing preview",
            "Description": f"{pp.PREVIEW_MARKER}\ncfg:abc",
        }
    )
    deleted = pp.discard_preview_quote(preview, "0Q0PREVIEW0000001")
    check("preview is deleted", deleted is True)
    check("preview delete called", ("Quote", "0Q0PREVIEW0000001") in preview.deletes)

    real = QuoteSession(
        {
            "Id": "0Q0REAL0000000001",
            "OpportunityId": "006OPP0000000002",
            "Name": "Get Pricing — BambooHR Pro",
            "Description": None,
        }
    )
    kept = pp.discard_preview_quote(real, "0Q0REAL0000000001")
    check("real Draft is not deleted", kept is False)
    check("real Draft delete not called", not real.deletes)


def test_reuse_block() -> None:
    print("\nQuoteReuseBlocked")
    err = qc.QuoteReuseBlocked("nope", "0Q0X")
    check("carries quote id", err.quote_id == "0Q0X")
    check("message", str(err) == "nope")


def test_iso_day() -> None:
    import checkout as co

    print("\niso_day / quote_start_date")
    check("iso_day date", co.iso_day("2026-09-01") == "2026-09-01")
    check("iso_day datetime", co.iso_day("2026-09-01T00:00:00.000+0000") == "2026-09-01")
    check("iso_day empty", co.iso_day(None) is None)

    class Fake:
        def soql(self, _q: str) -> list[dict]:
            return [{"StartDate": "2026-08-19T00:00:00.000+0000"}]

    check(
        "line fallback",
        co.quote_start_date(Fake(), "0Q0x", None) == "2026-08-19",
    )
    check("header wins", co.quote_start_date(Fake(), "0Q0x", "2026-10-01") == "2026-10-01")


def test_stamp_quote_start() -> None:
    import service as svc

    print("\nstamp_quote_start_date")
    sess = QuoteSession({"Id": "0Q0X"})
    svc.stamp_quote_start_date(sess, "0Q0X", "2026-08-19T00:00:00.000Z")
    check("patches StartDate day", ("Quote", "0Q0X", {"StartDate": "2026-08-19"}) in sess.patches)
    svc.stamp_quote_start_date(sess, "", "2026-08-19")
    check("blank quote skipped", len(sess.patches) == 1)


def test_checkout_reuse_skips_collect() -> None:
    import checkout as co

    print("\ncheckout reuse / chat_fast collect")
    collect_calls = {"n": 0}

    class Sess:
        def soql(self, q: str):
            if "FROM Quote" in q or "FROM QUOTE" in q:
                return [
                    {
                        "Id": "0Q0A",
                        "QuoteAccountId": "001A",
                        "Status": "Draft",
                        "Name": "SelfServe - Core",
                        "TotalPrice": 120,
                        "StartDate": "2026-08-19",
                    }
                ]
            return []

    orig_find = co.find_activated_order_for_quotes
    orig_place = co.place_activate_order
    orig_poll = co.poll_assets

    def fake_find(*_a, **_k):
        return {"Id": "801EXIST", "OrderNumber": "00000260"}

    def boom_place(*_a, **_k):
        raise AssertionError("should not place")

    import payments

    orig_pay = payments.build_payment_prompt

    def boom_pay(*_a, **_k):
        collect_calls["n"] += 1
        raise AssertionError("should not collect")

    co.find_activated_order_for_quotes = fake_find
    payments.build_payment_prompt = boom_pay
    try:
        r = co.checkout_quote(Sess(), "0Q0A", collect_payment=True)
        check("reuse ok", r.ok is True)
        check("reuse same order", r.order_id == "801EXIST")
        check("reuse did not collect", collect_calls["n"] == 0)
        check("reuse payment empty", r.payment is None)
    finally:
        co.find_activated_order_for_quotes = orig_find
        payments.build_payment_prompt = orig_pay

    collect_calls["n"] = 0

    def none_find(*_a, **_k):
        return None

    def fake_place(*_a, **_k):
        return ("801NEW", "00000261")

    def fake_poll(*_a, **_k):
        return []

    co.find_activated_order_for_quotes = none_find
    co.place_activate_order = fake_place
    co.poll_assets = fake_poll
    payments.build_payment_prompt = boom_pay
    try:
        r = co.checkout_quote(Sess(), "0Q0A", collect_payment=True, chat_fast=True)
        check("chat_fast ok", r.ok is True)
        check("chat_fast placed", r.order_id == "801NEW")
        check("chat_fast skipped collect", collect_calls["n"] == 0)
    finally:
        co.find_activated_order_for_quotes = orig_find
        co.place_activate_order = orig_place
        co.poll_assets = orig_poll
        payments.build_payment_prompt = orig_pay


def main() -> int:
    print("BambooHR quote reuse / discard guard")
    test_discard_preview_only()
    test_reuse_block()
    test_iso_day()
    test_stamp_quote_start()
    test_checkout_reuse_skips_collect()
    failed = [n for n, ok in RESULTS if not ok]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} passed")
    if failed:
        print("FAILED:", ", ".join(failed))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
