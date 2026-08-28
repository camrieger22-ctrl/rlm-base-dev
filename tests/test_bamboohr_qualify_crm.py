#!/usr/bin/env python3
"""Offline tests for BambooHR Slice 2 qualify CRM (Aug 12 workshop PDFs).

Workshop rules this pins:
- Dual-motion: open Quote in Salesforce → salesWorking (Fadi / N 219 ~02:14).
- Existing customer: Assets on the Account → sign in, not a new Quote.
- Self-serve Quotes (name contains SelfServe) do not trip dual-motion.
- No Quote / unmatched email → stay on self-serve (update Contact, never Lead).
- Abandoned wizard sessions persist server-side (not sessionStorage only).
- UTM/campaign stamps onto the qualify session (journey #0).

Run from repo root:

    python tests/test_bamboohr_qualify_crm.py
"""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GP = os.path.join(REPO_ROOT, "scripts", "bamboohr", "get_pricing")
sys.path.insert(0, GP)

import qualify_crm as qc  # noqa: E402

RESULTS: list[tuple[str, bool]] = []


def check(name: str, condition: bool) -> None:
    RESULTS.append((name, bool(condition)))
    print(f"  [{'PASS' if condition else 'FAIL'}] {name}")


class FakeSession:
    """SOQL stub — lookup_email must never insert a Lead."""

    def __init__(self, *, contacts=None, assets=None, quotes=None, tasks=None, leads=None):
        self.contacts = list(contacts or [])
        self.assets = list(assets or [])
        self.quotes = list(quotes or [])
        self.tasks = list(tasks or [])
        self.leads = list(leads or [])
        self.creates: list[tuple] = []
        self.patches: list[tuple] = []

    def soql(self, q: str):
        u = q.upper()
        if "FROM CONTACT" in u:
            return self.contacts
        if "FROM ACCOUNT" in u:
            # Resolve by Id from seeded contacts when present.
            for c in self.contacts:
                aid = c.get("AccountId")
                if aid and aid in q:
                    acct = c.get("Account") if isinstance(c.get("Account"), dict) else {}
                    return [
                        {
                            "Id": aid,
                            "Name": acct.get("Name") or "Acct",
                            "BillingCountry": acct.get("BillingCountry") or "US",
                            **{
                                k: acct[k]
                                for k in acct
                                if k.startswith("RLM_")
                            },
                        }
                    ]
            return []
        if "FROM ASSET" in u:
            return self.assets
        if "FROM QUOTE" in u:
            return self.quotes
        if "FROM TASK" in u:
            open_tasks = [
                t
                for t in self.tasks
                if not t.get("IsClosed")
                and str(t.get("Subject") or "").startswith(
                    qc.HANDOFF_TASK_SUBJECT_PREFIX
                )
            ]
            return open_tasks[:1]
        if "FROM LEAD" in u:
            return getattr(self, "leads", []) or []
        return []

    def create(self, sobject, fields):
        self.creates.append((sobject, dict(fields)))
        rid = f"{sobject[:3]}{len(self.creates):03d}"
        if sobject == "Task":
            self.tasks.append({**fields, "Id": rid, "IsClosed": False})
        return rid

    def patch(self, sobject, record_id, fields):
        self.patches.append((sobject, record_id, dict(fields)))
        if sobject == "Task":
            for t in self.tasks:
                if t.get("Id") == record_id:
                    t.update(fields)


def test_classifier() -> None:
    print("\nclassify_from_rows (PDF dual-motion)")
    st, reason = qc.classify_from_rows(assets=[{"Id": "02i"}], quotes=[])
    check("assets → existingCustomer", st == qc.STATUS_EXISTING_CUSTOMER)
    check("existing-customer copy mentions sign in", "sign in" in reason.lower())

    st, reason = qc.classify_from_rows(
        assets=[],
        quotes=[{"Name": "Acme Q1", "Status": "Draft", "Opportunity": {"Name": "Acme"}}],
    )
    check("open sales Quote → salesWorking", st == qc.STATUS_SALES_WORKING)
    check("sales-working copy", "already working" in reason.lower())

    st, _ = qc.classify_from_rows(
        assets=[],
        quotes=[
            {
                "Name": "SelfServe - Pro",
                "Status": "Draft",
                "Opportunity": {"Name": "SelfServe - Acme - Pro 12 US"},
            }
        ],
    )
    check("SelfServe-named Quote stays selfServe", st == qc.STATUS_SELF_SERVE)

    st, _ = qc.classify_from_rows(
        assets=[],
        quotes=[{"Name": "Closed deal", "Status": "Denied", "Opportunity": {}}],
    )
    check("non-open Quote status is not dual-motion", st == qc.STATUS_SELF_SERVE)

    st, _ = qc.classify_from_rows(assets=[], quotes=[])
    check("no Quote and no Asset → selfServe", st == qc.STATUS_SELF_SERVE)

    st, reason = qc.classify_from_rows(assets=[], quotes=[], sales_handoff=True)
    check("sales handoff flag → salesWorking", st == qc.STATUS_SALES_WORKING)
    check("handoff copy mentions earlier request", "earlier request" in reason.lower())

    st, _ = qc.classify_from_rows(
        assets=[],
        quotes=[
            {"Name": "SelfServe - Core", "Status": "Draft", "Opportunity": {}},
        ],
        sales_handoff=True,
    )
    check("SelfServe Quote + handoff flag → salesWorking", st == qc.STATUS_SALES_WORKING)

    st, _ = qc.classify_from_rows(
        assets=[],
        quotes=[
            {"Name": "SelfServe - Core", "Status": "Draft", "Opportunity": {}},
            {"Name": "AE working Acme", "Status": "Presented", "Opportunity": {"Name": "Acme"}},
        ],
    )
    check("self-serve Quote + open AE Quote → salesWorking", st == qc.STATUS_SALES_WORKING)


def test_self_serve_names() -> None:
    print("\nis_self_serve_name")
    check("SelfServe compact", qc.is_self_serve_name("SelfServe - Pro"))
    check("self-serve hyphen", qc.is_self_serve_name("self-serve checkout"))
    check("self serve spaces", qc.is_self_serve_name("self serve"))
    check("plain AE name is not self-serve", not qc.is_self_serve_name("Acme Q1 Renewal"))
    check(
        "Get Pricing name is acquisition draft",
        qc.is_acquisition_draft_name("Get Pricing — BambooHR Pro"),
    )
    check(
        "trial name is acquisition draft",
        qc.is_acquisition_draft_name("14-day trial — BambooHR Core"),
    )
    check("AE renewal is not acquisition draft", not qc.is_acquisition_draft_name("Acme Q1 Renewal"))


def test_lookup_email() -> None:
    print("\nlookup_email")
    none = qc.lookup_email(FakeSession(), "not-an-email")
    check("invalid email is not ok", none.get("ok") is False)

    unmatched = qc.lookup_email(FakeSession(contacts=[]), "new@example.com")
    check("unmatched Contact → selfServe", unmatched.get("status") == qc.STATUS_SELF_SERVE)
    check("unmatched is not matched", unmatched.get("matched") is False)

    sess = FakeSession(
        contacts=[
            {
                "Id": "003xx",
                "AccountId": "001xx",
                "FirstName": "Pat",
                "LastName": "Buyer",
                "Email": "pat@acme.com",
            }
        ],
        assets=[{"Id": "02ixx"}],
        quotes=[],
    )
    existing = qc.lookup_email(sess, "pat@acme.com")
    check("Asset on Account → existingCustomer", existing.get("status") == qc.STATUS_EXISTING_CUSTOMER)
    check("sign-in URL present", bool(existing.get("signInUrl")))
    check("lookup never created records", sess.creates == [])

    sales = FakeSession(
        contacts=[
            {
                "Id": "003yy",
                "AccountId": "001yy",
                "Email": "ae@acme.com",
                "Account": {
                    "Name": "Acme",
                    "Owner": {"Name": "Jordan AE", "Email": "jordan@bamboohr.com"},
                },
            }
        ],
        assets=[],
        quotes=[
            {
                "Name": "Acme Enterprise",
                "Status": "In Review",
                "Opportunity": {
                    "Name": "Acme Enterprise",
                    "Owner": {"Name": "Jordan AE", "Email": "jordan@bamboohr.com"},
                },
            }
        ],
    )
    blocked = qc.lookup_email(sales, "ae@acme.com")
    check("open Quote → salesWorking", blocked.get("status") == qc.STATUS_SALES_WORKING)
    check("ownerName from Opp Owner", blocked.get("ownerName") == "Jordan AE")
    check("reason names the AE", "Jordan AE" in (blocked.get("reason") or ""))

    owned = FakeSession(
        contacts=[
            {
                "Id": "003own",
                "AccountId": "001own",
                "Email": "size@acme.com",
                "Account": {
                    "Name": "Size Bounce Co",
                    "Owner": {"Name": "Sam Seller", "Email": "sam@bamboohr.com"},
                },
            }
        ],
        assets=[],
        quotes=[],
    )
    stay_owned = qc.lookup_email(owned, "size@acme.com")
    check(
        "selfServe still returns Account Owner for personalized bounce",
        stay_owned.get("status") == qc.STATUS_SELF_SERVE
        and stay_owned.get("ownerName") == "Sam Seller",
    )

    stay = FakeSession(
        contacts=[{"Id": "003zz", "AccountId": "001zz", "Email": "plg@acme.com"}],
        assets=[],
        quotes=[{"Name": "SelfServe - Core", "Status": "Draft", "Opportunity": {}}],
    )
    ok = qc.lookup_email(stay, "plg@acme.com")
    check("matched Contact + only SelfServe Quote → selfServe", ok.get("status") == qc.STATUS_SELF_SERVE)
    check("matched flag", ok.get("matched") is True)


def test_campaign_and_sessions() -> None:
    print("\ncampaign + abandoned sessions")
    check(
        "utm_campaign wins",
        qc.campaign_from_utm({"utm_campaign": "micro-plg", "utm_source": "google"})
        == "micro-plg",
    )
    check(
        "fallback utm_source",
        qc.campaign_from_utm({"utm_source": "linkedin"}) == "linkedin",
    )

    fd, path = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    os.unlink(path)
    old = qc.SESSION_FILE
    qc.SESSION_FILE = Path(path)
    try:
        rec = qc.upsert_qualify_session(
            {
                "headcount": 12,
                "country": "US",
                "needs": ["records", "hiring"],
                "step": 3,
                "utm": {"utm_campaign": "micro-plg"},
            }
        )
        sid = rec["sessionId"]
        check("session id assigned", bool(sid))
        rec2 = qc.upsert_qualify_session(
            {"sessionId": sid, "email": "pat@acme.com", "step": 5}
        )
        check("email merges onto same session", rec2.get("email") == "pat@acme.com")
        check("needs preserved", rec2.get("needs") == ["records", "hiring"])
        rec3 = qc.upsert_qualify_session(
            {"sessionId": sid, "step": 5, "needs": []}
        )
        check(
            "empty needs list does not wipe prior needs",
            rec3.get("needs") == ["records", "hiring"],
        )
        check("utm preserved", rec2.get("utm", {}).get("utm_campaign") == "micro-plg")
        incomplete = qc.list_qualify_sessions(incomplete_only=True)
        check("incomplete list includes it", any(r["sessionId"] == sid for r in incomplete))
        qc.mark_qualify_complete(sid)
        leftover = qc.list_qualify_sessions(incomplete_only=True)
        check("complete sessions drop from inbox", all(r["sessionId"] != sid for r in leftover))
    finally:
        qc.SESSION_FILE = old
        try:
            os.unlink(path)
        except OSError:
            pass


def test_opp_quote_names() -> None:
    print("\nself-serve Opp/Quote names")
    opp = qc.self_serve_opportunity_name("Acme", "Pro", 12, "US")
    check("opp name classified self-serve", qc.is_self_serve_name(opp))
    qn = qc.self_serve_quote_name("Core", 0)
    check("quote name classified self-serve", qc.is_self_serve_name(qn))


def test_handoff_brief() -> None:
    print("\nhandoff brief (qualified to talk to a person)")
    brief = qc.format_handoff_brief(
        bounce_reason="Payroll isn’t on the unassisted path.",
        bounce_type="payroll",
        headcount=24,
        country="US",
        needs=["records", "payroll"],
        dm_role="own",
        company="Acme",
        email="pat@acme.com",
    )
    check("brief is a bounce", brief.startswith(qc.HANDOFF_TASK_PREFIX))
    check("brief keeps payroll reason", "Payroll" in brief)
    check("brief keeps headcount", "24" in brief)


def test_micro_qualify_gates_and_quote_commit() -> None:
    print("\nmicro qualify gates + Quote requires SelfServe stamp")
    import service as svc

    try:
        qc.assert_micro_qualify(headcount=40, country="US", needs=["hiring"])
        check("40 employees rejected", False)
    except ValueError as exc:
        check("40 employees rejected", "24" in str(exc))
    try:
        qc.assert_micro_qualify(headcount=12, country="UK", needs=["hiring"])
        check("UK rejected", False)
    except ValueError as exc:
        check("UK rejected", "Canada" in str(exc))
    try:
        qc.assert_micro_qualify(headcount=12, country="US", needs=["hiring", "payroll"])
        check("payroll needs rejected", False)
    except ValueError as exc:
        check("payroll needs rejected", "Payroll" in str(exc))

    buyer = svc.BuyerInfo(
        company="Sales Path Co",
        email="sales-path@example.com",
        needs=["payroll"],
    )
    try:
        svc.commit_qualify_identity(
            FakeSession(), buyer=buyer, headcount=12, country="US"
        )
        check("commit payroll needs fails", False)
    except ValueError:
        check("commit payroll needs fails", True)

    try:
        qc.require_self_serve_commit(FakeSession(), "new-uncommitted@example.com")
        check("uncommitted email blocks Quote", False)
    except qc.QualifyCommitRequired:
        check("uncommitted email blocks Quote", True)

    stamped = FakeSession(
        contacts=[
            {
                "Id": "003x",
                "AccountId": "001x",
                "Email": "committed@example.com",
                "Account": {
                    "Name": "Committed Co",
                    "RLM_Bamboo_SelfServe__c": True,
                },
            }
        ]
    )
    looked = qc.require_self_serve_commit(stamped, "committed@example.com")
    check("stamped SelfServe allows Quote", looked.get("selfServeStamped") is True)

    existing = FakeSession(
        contacts=[
            {
                "Id": "003e",
                "AccountId": "001e",
                "Email": "has-assets@example.com",
                "Account": {"Name": "Cust", "RLM_Bamboo_SelfServe__c": False},
            }
        ],
        assets=[{"Id": "02i"}],
    )
    try:
        qc.require_self_serve_commit(existing, "has-assets@example.com")
        check("existing customer still DualMotion", False)
    except qc.DualMotionBlocked:
        check("existing customer still DualMotion", True)


def test_commit_and_handoff() -> None:
    print("\nbeat 5 commit + sales handoff")
    import service as svc

    buyer = svc.BuyerInfo(
        company="New Co",
        first_name="Pat",
        last_name="Buyer",
        email="pat-new@example.com",
        needs=["records", "hiring"],
        dm_role="own",
        campaign="micro-plg",
    )
    sess = FakeSession()
    out = svc.commit_qualify_identity(
        sess, buyer=buyer, headcount=12, country="US"
    )
    check("commit ok", out.get("ok") is True)
    created_objects = [s for s, _ in sess.creates]
    check("commit never inserts Lead", "Lead" not in created_objects)
    check("commit creates Account", "Account" in created_objects)
    check("commit creates Contact", "Contact" in created_objects)
    acct_fields = next(f for s, f in sess.creates if s == "Account")
    check(
        "Account stamped SelfServe on insert (Jeff: sales don’t touch)",
        acct_fields.get("RLM_Bamboo_SelfServe__c") is True,
    )

    bounce = FakeSession()
    handed = svc.handoff_qualify_to_sales(
        bounce,
        buyer=buyer,
        headcount=24,
        country="US",
        bounce_reason="You’re qualified to talk to a person.",
        bounce_type="payroll",
    )
    check("handoff ok", handed.get("ok") is True)
    check("handoff status is salesWorking", handed.get("status") == qc.STATUS_SALES_WORKING)
    check("fresh bounce alreadyWorking=false", handed.get("alreadyWorking") is False)
    bounce_acct = next(f for s, f in bounce.creates if s == "Account")
    check(
        "handoff Account is NOT SelfServe on create",
        bounce_acct.get("RLM_Bamboo_SelfServe__c") is not True,
    )
    handoff_patch = next((p for p in bounce.patches if p[0] == "Account"), None)
    check("handoff stamps Account SalesHandoff", handoff_patch is not None)
    if handoff_patch:
        check(
            "SalesHandoff flag true",
            handoff_patch[2].get("RLM_Bamboo_SalesHandoff__c") is True,
        )
        check(
            "HandoffReason=payroll",
            handoff_patch[2].get("RLM_Bamboo_HandoffReason__c") == "payroll",
        )
        check(
            "handoff stamps EmployeeCount",
            handoff_patch[2].get("RLM_Bamboo_EmployeeCountAtSignup__c") == 24,
        )
        check(
            "handoff stamps PrimaryNeeds",
            "records" in (handoff_patch[2].get("RLM_Bamboo_PrimaryNeeds__c") or ""),
        )
        check(
            "handoff stamps Campaign/UTM",
            handoff_patch[2].get("RLM_Bamboo_Campaign__c") == "micro-plg",
        )
    check("handoff creates sales Task", "Task" in [s for s, _ in bounce.creates])
    task = next(f for s, f in bounce.creates if s == "Task")
    check("Task subject is qualified-to-talk", "qualified to talk" in task["Subject"].lower())
    check("Task brief has payroll gate", "payroll" in (task.get("Description") or "").lower())

    aid = cid = tid = None
    for i, (s, _f) in enumerate(bounce.creates, start=1):
        rid = f"{s[:3]}{i:03d}"
        if s == "Account":
            aid = rid
        elif s == "Contact":
            cid = rid
        elif s == "Task":
            tid = rid
    bounce.contacts = [
        {
            "Id": cid,
            "AccountId": aid,
            "Email": buyer.email,
            "Description": qc.HANDOFF_TASK_PREFIX + "\nGate: payroll",
            "Account": {
                "Name": buyer.company,
                "RLM_Bamboo_SalesHandoff__c": True,
                "Owner": {},
            },
        }
    ]
    bounce.creates.clear()
    handed2 = svc.handoff_qualify_to_sales(
        bounce,
        buyer=buyer,
        headcount=24,
        country="US",
        bounce_reason="Second attempt",
        bounce_type="payroll",
    )
    check("repeat handoff ok", handed2.get("ok") is True)
    check("repeat alreadyWorking", handed2.get("alreadyWorking") is True)
    check("repeat reuses taskId", handed2.get("taskId") == tid)
    check(
        "repeat does not create second Task",
        not any(s == "Task" for s, _ in bounce.creates),
    )
    check(
        "repeat patches existing Task",
        any(p[0] == "Task" and p[1] == tid for p in bounce.patches),
    )


def test_lookup_backfills_legacy_bounce() -> None:
    print("\nlookup lazy-backfills pre-flag bounce Accounts")
    sess = FakeSession(
        contacts=[
            {
                "Id": "003LEGACY",
                "AccountId": "001LEGACY",
                "Email": "legacy@example.com",
                "Description": qc.HANDOFF_TASK_PREFIX + "\nGate: payroll",
                "Account": {
                    "Name": "Legacy Bounce Co",
                    "RLM_Bamboo_SalesHandoff__c": False,
                    "Owner": {"Name": "AE Pat", "Email": "ae@example.com"},
                },
            }
        ]
    )
    out = qc.lookup_email(sess, "legacy@example.com")
    check("legacy bounce → salesWorking", out.get("status") == qc.STATUS_SALES_WORKING)
    check(
        "lookup stamped SalesHandoff",
        any(
            p[0] == "Account"
            and p[1] == "001LEGACY"
            and p[2].get("RLM_Bamboo_SalesHandoff__c") is True
            for p in sess.patches
        ),
    )


def test_buyer_from_request_merges_top_level() -> None:
    print("\nbuyer.from_request (API top-level needs/utm)")
    import service as svc

    b = svc.BuyerInfo.from_request(
        {
            "buyer": {
                "email": "a@example.com",
                "company": "Acme",
                "firstName": "A",
                "lastName": "B",
            },
            "needs": ["records", "performance"],
            "dmRole": "own",
            "utm": {"utm_campaign": "micro-plg"},
        }
    )
    check("merges needs from top level", b.needs == ["records", "performance"])
    check("merges dmRole from top level", b.dm_role == "own")
    check("merges campaign from utm", b.campaign == "micro-plg")
    check("keeps nested email", b.email == "a@example.com")

    nested_wins = svc.BuyerInfo.from_request(
        {
            "buyer": {"email": "a@example.com", "company": "Acme", "needs": ["hiring"]},
            "needs": ["records"],
        }
    )
    check("buyer.needs wins when present", nested_wins.needs == ["hiring"])


def test_abandoned_cadence() -> None:
    print("\nabandoned wizard cadence (1-day / 1-week)")
    from datetime import datetime, timedelta, timezone

    fd, path = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    os.unlink(path)
    old = qc.SESSION_FILE
    qc.SESSION_FILE = Path(path)
    try:
        now = datetime(2026, 8, 13, 18, 0, tzinfo=timezone.utc)
        rec = qc.upsert_qualify_session(
            {
                "headcount": 18,
                "country": "US",
                "needs": ["records"],
                "step": 3,
                "email": "abandon@example.com",
                "firstName": "Pat",
                "company": "Acme",
            }
        )
        sid = rec["sessionId"]
        # Force age via createdAt (first abandon) so cadence stages are deterministic.
        with qc._LOCK:
            store = qc._load_sessions()
            store[sid]["createdAt"] = (now - timedelta(hours=2)).isoformat()
            store[sid]["updatedAt"] = now.isoformat()
            qc._save_sessions(store)

        fresh = qc.enrich_qualify_session_cadence(
            qc.list_qualify_sessions(incomplete_only=True)[0], now=now
        )
        # list already enriches; re-enrich with fixed now for waiting stage
        with qc._LOCK:
            store = qc._load_sessions()
            raw = store[sid]
        waiting = qc.enrich_qualify_session_cadence(raw, now=now)
        check("age <24h → waiting", waiting.get("cadenceStage") == "waiting")

        raw["createdAt"] = (now - timedelta(hours=30)).isoformat()
        day1 = qc.enrich_qualify_session_cadence(raw, now=now)
        check("age ≥24h → day1_due", day1.get("cadenceStage") == "day1_due")
        check("day1 subject mentions finish", "finish" in day1["cadenceEmail"]["subject"].lower()
              or "ready" in day1["cadenceEmail"]["subject"].lower())
        check("day1 body has resume path", "/?resume=" in day1["cadenceEmail"]["body"])

        marked = qc.mark_qualify_cadence_sent(sid, "day1")
        check("mark day1 → day1_sent or waiting bridge", marked is not None)
        # Age still ~30h after mark — stage should be day1_sent until week due.
        with qc._LOCK:
            store = qc._load_sessions()
            store[sid]["createdAt"] = (now - timedelta(hours=30)).isoformat()
            store[sid]["cadenceDay1SentAt"] = marked["cadenceDay1SentAt"]
            qc._save_sessions(store)
            raw2 = store[sid]
        mid = qc.enrich_qualify_session_cadence(raw2, now=now)
        check("after day1 mark → day1_sent", mid.get("cadenceStage") == "day1_sent")

        raw2["createdAt"] = (now - timedelta(hours=200)).isoformat()
        week = qc.enrich_qualify_session_cadence(raw2, now=now)
        check("age ≥168h → week1_due", week.get("cadenceStage") == "week1_due")
        check("week1 subject mentions still thinking", "still" in week["cadenceEmail"]["subject"].lower())

        done = qc.mark_qualify_cadence_sent(sid, "week1")
        check("mark week1 ok", done is not None)
        with qc._LOCK:
            raw3 = qc._load_sessions()[sid]
        finished = qc.enrich_qualify_session_cadence(raw3, now=now)
        check("both sent → done", finished.get("cadenceStage") == "done")

        try:
            qc.mark_qualify_cadence_sent(sid, "nope")
            check("invalid which raises", False)
        except ValueError:
            check("invalid which raises", True)
        check("missing session → None", qc.mark_qualify_cadence_sent("missing", "day1") is None)

        # Cadence mark-sent creates a CRM Task when Contact matches.
        with_contact = FakeSession(
            contacts=[
                {
                    "Id": "003CAD",
                    "AccountId": "001CAD",
                    "Email": "abandon@example.com",
                    "Account": {"Name": "Acme"},
                }
            ]
        )
        tasked = qc.mark_qualify_cadence_sent(sid, "day1", crm_session=with_contact)
        # day1 already marked — still creates Task on re-mark path; force week1
        tasked = qc.mark_qualify_cadence_sent(sid, "week1", crm_session=with_contact)
        check("cadence Task created", "Task" in [s for s, _ in with_contact.creates])
        check("cadence returns taskId", bool(tasked and tasked.get("taskId")))
        _ = fresh  # list path exercised
    finally:
        qc.SESSION_FILE = old
        try:
            os.unlink(path)
        except OSError:
            pass


def test_update_existing_lead() -> None:
    print("\nupdate existing Lead (never insert / never convert)")
    sess = FakeSession(
        leads=[
            {
                "Id": "00QLEAD",
                "Company": "Old Co",
                "FirstName": "Pat",
                "LastName": "Lead",
                "Status": "Open",
                "Description": "",
            }
        ]
    )
    lead_id, warns = qc.update_existing_lead(
        sess,
        email="pat@example.com",
        company="New Co",
        campaign="utm-test",
        description="Self-serve note",
        status="Working",
    )
    check("updates existing Lead id", lead_id == "00QLEAD")
    check("no Lead insert", "Lead" not in [s for s, _ in sess.creates])
    patch = next(p for p in sess.patches if p[0] == "Lead")
    check("Lead company updated", patch[2].get("Company") == "New Co")
    check("Lead campaign stamped", patch[2].get("RLM_Bamboo_Campaign__c") == "utm-test")
    check("Lead status Working", patch[2].get("Status") == "Working")
    empty = FakeSession()
    miss, _ = qc.update_existing_lead(empty, email="nobody@example.com", company="X")
    check("no Lead → None", miss is None)
    _ = warns


def test_stamp_uses_custom_do_not_call() -> None:
    print("\nstamp_self_serve (custom Do Not Call)")
    sess = FakeSession()
    warns = qc.stamp_self_serve(
        sess,
        account_id="001AAA",
        contact_id="003BBB",
        headcount=18,
        needs=["records", "performance"],
        dm_role="own",
        campaign="happy-path-test",
    )
    check("no warnings when FakeSession accepts patches", warns == [])
    acct = next(p for p in sess.patches if p[0] == "Account")[2]
    contact = next(p for p in sess.patches if p[0] == "Contact")[2]
    check("Account needs stamped", "records" in (acct.get("RLM_Bamboo_PrimaryNeeds__c") or ""))
    check("Account campaign stamped", acct.get("RLM_Bamboo_Campaign__c") == "happy-path-test")
    check(
        "Contact uses custom DoNotCall",
        contact.get("RLM_Bamboo_DoNotCall__c") is True,
    )
    check("Contact dm role stamped", contact.get("RLM_Bamboo_DecisionMaker__c") == "own")
    check("standard DoNotCall not required", "DoNotCall" not in contact)


def main() -> int:
    print("BambooHR qualify CRM (workshop Slice 2)")
    test_classifier()
    test_self_serve_names()
    test_lookup_email()
    test_campaign_and_sessions()
    test_opp_quote_names()
    test_handoff_brief()
    test_micro_qualify_gates_and_quote_commit()
    test_commit_and_handoff()
    test_lookup_backfills_legacy_bounce()
    test_buyer_from_request_merges_top_level()
    test_abandoned_cadence()
    test_update_existing_lead()
    test_stamp_uses_custom_do_not_call()
    failed = [n for n, ok in RESULTS if not ok]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} passed")
    if failed:
        print("FAILED:", ", ".join(failed))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
