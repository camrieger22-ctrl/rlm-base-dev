"""Micro self-serve qualify CRM — workshop Slice 2.

Workshop (Aug 12 PDFs):
- Update existing Contact; never insert a Lead (quick notes: single SoT).
- Dual-motion: Account with a Quote in Salesforce, or sales-working path →
  bounce ("Sales is already working this") — Fadi / N 219 ~02:14.
- Existing customer (Assets) → sign in, not a second acquisition Quote.
- Stamp SelfServe + needs + employee count + decision role; suppress SDR.
- Abandoned wizard: persist the qualify session so drop-off is not lost.
"""

from __future__ import annotations

import json
import os
import re
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
SESSION_FILE = HERE / ".qualify_sessions.json"
_LOCK = threading.Lock()

STATUS_SELF_SERVE = "selfServe"
STATUS_SALES_WORKING = "salesWorking"
STATUS_EXISTING_CUSTOMER = "existingCustomer"

class DualMotionBlocked(ValueError):
    """Beat 5 / Get quote: sales-working or existing customer — no new Quote."""

    def __init__(self, lookup: dict[str, Any]) -> None:
        super().__init__(str(lookup.get("reason") or "Blocked"))
        self.lookup = lookup


class QualifyCommitRequired(ValueError):
    """Get Pricing Quote before beat-5 SelfServe stamp — agent/UI must commit first."""

    def __init__(self, lookup: dict[str, Any] | None = None) -> None:
        super().__init__(
            "Create your self-serve account before requesting a Quote."
        )
        self.lookup = lookup or {}


class QuoteReuseBlocked(ValueError):
    """previewQuoteId / quoteId cannot be updated in place — never delete it."""

    def __init__(self, message: str, quote_id: str | None = None) -> None:
        super().__init__(message)
        self.quote_id = quote_id


MICRO_MAX_HEADCOUNT = 24
MICRO_COUNTRIES = frozenset({"US", "CA"})
SALES_NEEDS = frozenset({"payroll", "elite", "benefits", "global"})


SALES_WORKING_COPY = (
    "Sales is already working this. We will not start a second self-serve Quote."
)
SALES_HANDOFF_COPY = (
    "You’re already connected with sales from your earlier request. "
    "We will not start a self-serve Quote."
)
EXISTING_CUSTOMER_COPY = (
    "You already have BambooHR — sign in to Licenses instead of creating a new Quote."
)
SELF_SERVE_COPY = "Stay on self-serve. We’ll update your Contact — not create a Lead."

HANDOFF_TASK_PREFIX = "Self-serve bounce:"
HANDOFF_TASK_SUBJECT_PREFIX = "Qualified to talk to a person"

# RLM Quote statuses that still mean “an AE is working this.”
_OPEN_QUOTE_STATUSES = {
    "Draft",
    "In Review",
    "Approved",
    "Presented",
    "Accepted",
    "Pending",
    "Needs Review",
}

_EMAIL_RE = re.compile(r"^[^\s@]+@[^\s@]+\.[^\s@]+$")


def _soql_escape(value: str) -> str:
    return (value or "").replace("\\", "\\\\").replace("'", "\\'")


def _now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def is_self_serve_name(*parts: str) -> bool:
    """True when Opp/Quote naming marks the unassisted path (not an AE deal)."""
    blob = " ".join(p or "" for p in parts).lower()
    compact = blob.replace(" ", "").replace("_", "").replace("-", "")
    return "selfserve" in compact or "self-serve" in blob or "self serve" in blob


def is_acquisition_draft_name(name: str) -> bool:
    """True for Get Pricing / SelfServe / trial Drafts the buyer agent may update."""
    n = (name or "").strip()
    if not n:
        return False
    if is_self_serve_name(n):
        return True
    low = n.lower()
    if low.startswith("get pricing"):
        return True
    return bool(re.search(r"\d+-day trial", low))


def classify_from_rows(
    *,
    assets: list[dict[str, Any]],
    quotes: list[dict[str, Any]],
    sales_handoff: bool = False,
) -> tuple[str, str]:
    """Pure classifier — workshop dual-motion vs existing customer vs self-serve.

    ``sales_handoff`` covers Fadi’s Account-without-Quote case and wizard
    bounces (Payroll / ≥25 / geo) stamped on the Account.
    """
    if assets:
        return STATUS_EXISTING_CUSTOMER, EXISTING_CUSTOMER_COPY
    for q in quotes:
        status = str(q.get("Status") or "")
        if status and status not in _OPEN_QUOTE_STATUSES:
            continue
        name = str(q.get("Name") or "")
        opp = q.get("Opportunity") or {}
        opp_name = str(opp.get("Name") or "") if isinstance(opp, dict) else ""
        desc = str(q.get("Description") or "")
        if is_self_serve_name(name, opp_name, desc):
            continue
        return STATUS_SALES_WORKING, SALES_WORKING_COPY
    if sales_handoff:
        return STATUS_SALES_WORKING, SALES_HANDOFF_COPY
    return STATUS_SELF_SERVE, SELF_SERVE_COPY


def update_existing_lead(
    session: Any,
    *,
    email: str,
    company: str | None = None,
    first_name: str | None = None,
    last_name: str | None = None,
    campaign: str | None = None,
    description: str | None = None,
    status: str | None = None,
) -> tuple[str | None, list[str]]:
    """Update an existing unmatched Lead by email — never insert, never convert."""
    email = (email or "").strip()
    warnings: list[str] = []
    if not email:
        return None, warnings
    try:
        rows = session.soql(
            "SELECT Id, Company, FirstName, LastName, Status, Description "
            f"FROM Lead WHERE Email = '{_soql_escape(email)}' "
            "AND IsConverted = false "
            "ORDER BY CreatedDate DESC LIMIT 1"
        )
    except Exception as exc:  # noqa: BLE001
        warnings.append(f"Lead lookup skipped: {str(exc)[:200]}")
        return None, warnings
    if not rows:
        return None, warnings
    lead_id = rows[0]["Id"]
    fields: dict[str, Any] = {}
    if company and company != (rows[0].get("Company") or ""):
        fields["Company"] = company[:255]
    if first_name:
        fields["FirstName"] = first_name[:40]
    if last_name:
        fields["LastName"] = last_name[:80]
    if campaign:
        # Prefer custom Campaign when present; else fold into Description.
        fields["RLM_Bamboo_Campaign__c"] = campaign[:255]
    if description:
        prior = str(rows[0].get("Description") or "")
        merged = (description + ("\n\n" + prior if prior else ""))[:32000]
        fields["Description"] = merged
    if status:
        fields["Status"] = status
    if not fields:
        return lead_id, warnings
    # Drop unknown custom fields via soft patch loop.
    pending = dict(fields)
    while pending:
        try:
            session.patch("Lead", lead_id, pending)
            return lead_id, warnings
        except Exception as exc:  # noqa: BLE001
            msg = str(exc)
            dropped = False
            for key in list(pending):
                if key in msg or key.rstrip("__c") in msg:
                    pending.pop(key, None)
                    if key == "RLM_Bamboo_Campaign__c" and campaign:
                        # Fold campaign into description instead.
                        note = f"Campaign/UTM: {campaign}"
                        desc = pending.get("Description") or description or ""
                        pending["Description"] = (note + "\n" + desc)[:32000]
                    else:
                        warnings.append(f"Lead.{key} skipped — {msg[:120]}")
                    dropped = True
                    break
            if not dropped:
                warnings.append(f"Lead update skipped: {msg[:240]}")
                return lead_id, warnings
    return lead_id, warnings


def stamp_sales_handoff(
    session: Any,
    *,
    account_id: str,
    bounce_type: str | None,
    headcount: int | None = None,
    needs: list[str] | None = None,
    contact_id: str | None = None,
    dm_role: str | None = None,
    campaign: str | None = None,
) -> list[str]:
    """Mark Account as sales-owned after a wizard bounce — never SelfServe.

    Also stamps HC / needs / campaign so AEs can list-view filter; optional Contact DM role.
    """
    fields: dict[str, Any] = {
        "RLM_Bamboo_SalesHandoff__c": True,
        "RLM_Bamboo_SelfServe__c": False,
    }
    reason = (bounce_type or "").strip()[:80]
    if reason:
        fields["RLM_Bamboo_HandoffReason__c"] = reason
    if headcount is not None and int(headcount) > 0:
        fields["RLM_Bamboo_EmployeeCountAtSignup__c"] = int(headcount)
    if needs:
        fields["RLM_Bamboo_PrimaryNeeds__c"] = ", ".join(
            str(n) for n in needs if n
        )[:1000]
    if campaign:
        fields["RLM_Bamboo_Campaign__c"] = campaign[:255]
    warnings = _safe_patch(session, "Account", account_id, fields)
    if contact_id:
        c_fields: dict[str, Any] = {}
        role = (dm_role or "").strip().lower()
        if role in {"own", "influence", "research"}:
            c_fields["RLM_Bamboo_DecisionMaker__c"] = role
        if c_fields:
            warnings.extend(_safe_patch(session, "Contact", contact_id, c_fields))
    return warnings


def find_open_handoff_task(
    session: Any,
    *,
    contact_id: str | None,
    account_id: str | None,
) -> str | None:
    """Return Id of an open 'Qualified to talk…' Task for this buyer, if any."""
    clauses: list[str] = []
    if contact_id:
        clauses.append(f"WhoId = '{_soql_escape(contact_id)}'")
    if account_id:
        clauses.append(f"WhatId = '{_soql_escape(account_id)}'")
    if not clauses:
        return None
    who = " OR ".join(clauses)
    try:
        rows = session.soql(
            "SELECT Id FROM Task "
            f"WHERE ({who}) "
            f"AND Subject LIKE '{_soql_escape(HANDOFF_TASK_SUBJECT_PREFIX)}%' "
            "AND IsClosed = false "
            "ORDER BY CreatedDate DESC "
            "LIMIT 1"
        )
    except Exception:
        return None
    return (rows[0].get("Id") if rows else None) or None


def account_has_bounce_signal(
    session: Any,
    *,
    account_id: str,
    contact_id: str | None,
    contact_description: str | None,
) -> bool:
    """True when a pre-flag bounce left Task/Description breadcrumbs."""
    desc = contact_description or ""
    if HANDOFF_TASK_PREFIX in desc:
        return True
    return bool(
        find_open_handoff_task(
            session, contact_id=contact_id, account_id=account_id
        )
    )


def lookup_email(session: Any, email: str) -> dict[str, Any]:
    """Contact by email → Account. Never inserts a Lead.

    Returns status: selfServe | salesWorking | existingCustomer.
    """
    email = (email or "").strip()
    if not email or not _EMAIL_RE.match(email):
        return {
            "ok": False,
            "error": "Enter a valid work email.",
            "status": None,
        }
    rows = session.soql(
        "SELECT Id, AccountId, FirstName, LastName, Email, LeadSource, Description, "
        "Account.Name, Account.RLM_Bamboo_SalesHandoff__c, "
        "Account.RLM_Bamboo_SelfServe__c, "
        "Account.Owner.Name, Account.Owner.Email, "
        "Account.Owner.UserRole.Name, Account.Owner.IsActive "
        "FROM Contact "
        f"WHERE Email = '{_soql_escape(email)}' "
        "LIMIT 1"
    )
    if not rows or not rows[0].get("AccountId"):
        return {
            "ok": True,
            "status": STATUS_SELF_SERVE,
            "reason": SELF_SERVE_COPY,
            "matched": False,
            "accountId": None,
            "contactId": None,
            "signInUrl": None,
            "ownerName": None,
            "ownerEmail": None,
            "selfServeStamped": False,
        }
    c = rows[0]
    aid = c["AccountId"]
    acct = c.get("Account") if isinstance(c.get("Account"), dict) else {}
    acct_owner = acct.get("Owner") if isinstance(acct.get("Owner"), dict) else {}
    owner_name = str(acct_owner.get("Name") or "").strip() or None
    owner_email = str(acct_owner.get("Email") or "").strip() or None
    sales_handoff = bool(acct.get("RLM_Bamboo_SalesHandoff__c"))
    # Lazy backfill: pre-flag bounces left Task/Description only.
    if not sales_handoff and account_has_bounce_signal(
        session,
        account_id=aid,
        contact_id=c.get("Id"),
        contact_description=c.get("Description"),
    ):
        stamp_sales_handoff(
            session,
            account_id=aid,
            bounce_type="legacy",
            contact_id=c.get("Id"),
        )
        sales_handoff = True
    assets: list[dict[str, Any]] = []
    quotes: list[dict[str, Any]] = []
    try:
        assets = session.soql(
            "SELECT Id FROM Asset "
            f"WHERE AccountId = '{_soql_escape(aid)}' "
            "LIMIT 1"
        )
    except Exception:
        assets = []
    try:
        quotes = session.soql(
            "SELECT Id, Name, Status, Description, Opportunity.Name, "
            "Opportunity.Owner.Name, Opportunity.Owner.Email "
            "FROM Quote "
            f"WHERE (QuoteAccountId = '{_soql_escape(aid)}' "
            f"OR AccountId = '{_soql_escape(aid)}') "
            "ORDER BY CreatedDate DESC "
            "LIMIT 20"
        )
    except Exception:
        quotes = []
    status, reason = classify_from_rows(
        assets=assets, quotes=quotes, sales_handoff=sales_handoff
    )
    # Prefer the AE working the open Quote/Opp — that's "so and so" for dual-motion.
    if status == STATUS_SALES_WORKING:
        for q in quotes:
            status_q = str(q.get("Status") or "")
            if status_q and status_q not in _OPEN_QUOTE_STATUSES:
                continue
            name = str(q.get("Name") or "")
            opp = q.get("Opportunity") or {}
            opp_name = str(opp.get("Name") or "") if isinstance(opp, dict) else ""
            desc = str(q.get("Description") or "")
            if is_self_serve_name(name, opp_name, desc):
                continue
            opp_owner = (
                opp.get("Owner") if isinstance(opp, dict) else None
            ) or {}
            if isinstance(opp_owner, dict):
                on = str(opp_owner.get("Name") or "").strip()
                oe = str(opp_owner.get("Email") or "").strip()
                if on:
                    owner_name = on
                    owner_email = oe or owner_email
                    reason = (
                        f"You’re already working with {on}. "
                        "We’ll reconnect you — no second self-serve Quote."
                    )
                    break
    sign_in = None
    if status == STATUS_EXISTING_CUSTOMER:
        sign_in = f"/account?accountId={aid}"
        ec = os.environ.get("BAMBOO_EC_LOGIN_URL", "").strip()
        if ec:
            sign_in = ec
    return {
        "ok": True,
        "status": status,
        "reason": reason,
        "matched": True,
        "accountId": aid,
        "contactId": c.get("Id"),
        "contactName": (
            f"{c.get('FirstName') or ''} {c.get('LastName') or ''}"
        ).strip(),
        "accountName": str(acct.get("Name") or "").strip() or None,
        "ownerName": owner_name,
        "ownerEmail": owner_email,
        "signInUrl": sign_in,
        "selfServeStamped": bool(acct.get("RLM_Bamboo_SelfServe__c")),
    }


def _safe_patch(session: Any, sobject: str, record_id: str, fields: dict[str, Any]) -> list[str]:
    """Patch; drop unknown custom fields (org may not have Slice 2 metadata yet)."""
    warnings: list[str] = []
    pending = dict(fields)
    while pending:
        try:
            session.patch(sobject, record_id, pending)
            return warnings
        except Exception as exc:  # noqa: BLE001
            msg = str(exc)
            dropped = False
            for key in list(pending):
                if key in msg or key.rstrip("__c") in msg:
                    pending.pop(key, None)
                    warnings.append(f"{sobject}.{key} not in org yet — skipped stamp")
                    dropped = True
                    break
            if not dropped:
                warnings.append(f"{sobject} stamp skipped: {msg[:240]}")
                return warnings
    return warnings


def assert_micro_qualify(
    *,
    headcount: int | None,
    country: str | None,
    needs: list[str] | None,
) -> None:
    """Reject beat-5 SelfServe stamp for sales-path size / geo / needs."""
    hc = int(headcount or 0)
    if hc > MICRO_MAX_HEADCOUNT:
        raise ValueError(
            f"Micro self-serve supports at most {MICRO_MAX_HEADCOUNT} employees "
            "(talk to sales for larger teams)."
        )
    geo = (country or "US").upper().strip()
    if geo and geo not in MICRO_COUNTRIES:
        raise ValueError("Micro self-serve is US and Canada only.")
    sales = [n for n in (needs or []) if str(n).strip().lower() in SALES_NEEDS]
    if sales:
        raise ValueError(
            "Payroll, Elite, Benefits, and Global Payroll stay with a person — "
            "use sales handoff, not a self-serve account."
        )


def require_self_serve_commit(session: Any, email: str) -> dict[str, Any]:
    """Block Quote create until beat-5 SelfServe stamp (or dual-motion bounce)."""
    looked = lookup_email(session, email)
    if not looked.get("ok"):
        raise ValueError(looked.get("error") or "Enter a valid work email.")
    if looked.get("status") in (STATUS_SALES_WORKING, STATUS_EXISTING_CUSTOMER):
        raise DualMotionBlocked(looked)
    if not looked.get("selfServeStamped"):
        raise QualifyCommitRequired(looked)
    return looked


def stamp_self_serve(
    session: Any,
    *,
    account_id: str,
    contact_id: str | None,
    headcount: int | None,
    needs: list[str] | None,
    dm_role: str | None,
    campaign: str | None,
) -> list[str]:
    """Write workshop discovery onto Account/Contact. Never inserts a Lead."""
    warnings: list[str] = []
    acct_fields: dict[str, Any] = {
        "RLM_Bamboo_SelfServe__c": True,
        "AccountSource": "SelfServe_Micro",
    }
    if headcount is not None and headcount > 0:
        acct_fields["RLM_Bamboo_EmployeeCountAtSignup__c"] = int(headcount)
    if needs:
        acct_fields["RLM_Bamboo_PrimaryNeeds__c"] = ", ".join(needs)[:1000]
    if campaign:
        acct_fields["RLM_Bamboo_Campaign__c"] = campaign[:255]
    warnings.extend(_safe_patch(session, "Account", account_id, acct_fields))
    if contact_id:
        c_fields: dict[str, Any] = {
            "LeadSource": "SelfServe_Micro",
            # Jeff ~01:59: mark it so sales don't touch. Custom checkbox —
            # some demo orgs lack standard Contact.DoNotCall (master-demo).
            "RLM_Bamboo_DoNotCall__c": True,
        }
        role = (dm_role or "").strip().lower()
        if role in {"own", "influence", "research"}:
            c_fields["RLM_Bamboo_DecisionMaker__c"] = role
        warnings.extend(_safe_patch(session, "Contact", contact_id, c_fields))
    return warnings


SDR_TASK_SUBJECT = "SDR: qualify inbound"


def format_handoff_brief(
    *,
    bounce_reason: str,
    bounce_type: str,
    headcount: int | None,
    country: str,
    needs: list[str] | None,
    dm_role: str,
    company: str,
    email: str,
) -> str:
    """AE brief on the sales Task — wizard answers, not a discarded bounce.

    Rationale (N 219 ~00:39): a 24-person company that needs Payroll is
    *qualified to talk to a person*. SDRs stop collecting data and take
    complex leads. Losing them at the panel would fight that.
    """
    need_s = ", ".join(needs or []) or "—"
    lines = [
        HANDOFF_TASK_PREFIX,
        f"Reason: {bounce_reason}",
        f"Gate: {bounce_type or '—'}",
        f"Company: {company}",
        f"Email: {email}",
        f"Employees: {headcount if headcount else '—'}",
        f"Geo: {country or '—'}",
        f"Needs: {need_s}",
        f"Decision role: {dm_role or '—'}",
        "Do not put this Account on the self-serve / do-not-call path.",
    ]
    return "\n".join(lines)[:32000]


def self_serve_opportunity_name(company: str, plan_label: str, headcount: int, country: str) -> str:
    """Opp name the lookup classifier treats as self-serve (not sales-working)."""
    return f"SelfServe - {company} - {plan_label} {headcount} {country}"[:120]


def self_serve_quote_name(plan_label: str, addon_count: int = 0) -> str:
    extra = f" + {addon_count} add-on(s)" if addon_count else ""
    return f"SelfServe - {plan_label}{extra}"[:120]


# —— Abandoned wizard sessions (server-side; sessionStorage is not enough) ——


def _load_sessions() -> dict[str, Any]:
    if not SESSION_FILE.is_file():
        return {}
    try:
        return json.loads(SESSION_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def _save_sessions(data: dict[str, Any]) -> None:
    SESSION_FILE.write_text(json.dumps(data, indent=2), encoding="utf-8")


def upsert_qualify_session(payload: dict[str, Any]) -> dict[str, Any]:
    """Persist size/geo/needs/role (+ email/UTM when present)."""
    sid = str(payload.get("sessionId") or "").strip() or str(uuid.uuid4())
    now = _now_iso()
    with _LOCK:
        store = _load_sessions()
        prior = store.get(sid) or {}
        rec = {
            **prior,
            "sessionId": sid,
            "updatedAt": now,
            "createdAt": prior.get("createdAt") or now,
            "step": payload.get("step") if payload.get("step") is not None else prior.get("step"),
            "headcount": payload.get("headcount", prior.get("headcount")),
            "country": payload.get("country", prior.get("country")),
            "needs": (
                payload["needs"]
                if payload.get("needs")
                else (prior.get("needs") or [])
            ),
            "dmRole": payload.get("dmRole", prior.get("dmRole")),
            "email": payload.get("email", prior.get("email")) or "",
            "company": payload.get("company", prior.get("company")) or "",
            "firstName": payload.get("firstName", prior.get("firstName")) or "",
            "lastName": payload.get("lastName", prior.get("lastName")) or "",
            "utm": payload.get("utm", prior.get("utm")) or {},
            "bounceReason": payload.get("bounceReason", prior.get("bounceReason")) or "",
            "bounceType": payload.get("bounceType", prior.get("bounceType")) or "",
            "complete": bool(payload.get("complete", prior.get("complete"))),
        }
        store[sid] = rec
        _save_sessions(store)
    return rec


def get_qualify_session(session_id: str) -> dict[str, Any] | None:
    with _LOCK:
        rec = _load_sessions().get(session_id)
    if not rec:
        return None
    return enrich_qualify_session_cadence(rec)


def list_qualify_sessions(*, incomplete_only: bool = True) -> list[dict[str, Any]]:
    with _LOCK:
        rows = list(_load_sessions().values())
    if incomplete_only:
        rows = [r for r in rows if not r.get("complete")]
    rows.sort(key=lambda r: r.get("updatedAt") or "", reverse=True)
    return [enrich_qualify_session_cadence(r) for r in rows[:100]]


def mark_qualify_complete(session_id: str) -> None:
    if not session_id:
        return
    with _LOCK:
        store = _load_sessions()
        rec = store.get(session_id)
        if not rec:
            return
        rec["complete"] = True
        rec["updatedAt"] = _now_iso()
        store[session_id] = rec
        _save_sessions(store)


# Workshop abandoned-wizard cadence (N 219 / Stage A): 1-day and 1-week nudges.
CADENCE_DAY1_HOURS = 24
CADENCE_WEEK1_HOURS = 24 * 7


def _parse_iso(ts: str | None) -> datetime | None:
    if not ts:
        return None
    try:
        return datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
    except ValueError:
        return None


def _age_hours(rec: dict[str, Any], *, now: datetime | None = None) -> float:
    """Age from first abandon (createdAt), not last wizard touch."""
    now = now or datetime.now(timezone.utc)
    created = _parse_iso(rec.get("createdAt")) or _parse_iso(rec.get("updatedAt"))
    if not created:
        return 0.0
    if created.tzinfo is None:
        created = created.replace(tzinfo=timezone.utc)
    return max(0.0, (now - created).total_seconds() / 3600.0)


def cadence_email_copy(rec: dict[str, Any], *, which: str) -> dict[str, str]:
    """Demo email copy — workshop 'we didn’t lose them' follow-up."""
    first = (rec.get("firstName") or "").strip() or "there"
    company = (rec.get("company") or "").strip() or "your company"
    hc = rec.get("headcount") or "—"
    needs = ", ".join(rec.get("needs") or []) or "HR basics"
    step = rec.get("step") or "—"
    resume = f"/?resume={rec.get('sessionId') or ''}"
    if which == "week1":
        subject = f"Still thinking about BambooHR for {company}?"
        body = (
            f"Hi {first},\n\n"
            f"It's been about a week since you started a BambooHR self-serve signup "
            f"({hc} employees · {needs}). We saved your progress at step {step} — "
            f"no need to start over.\n\n"
            f"Resume: {{origin}}{resume}\n\n"
            f"Questions? Reply and a specialist will help.\n\n"
            f"— BambooHR"
        )
    else:
        subject = f"Your BambooHR signup is ready to finish ({company})"
        body = (
            f"Hi {first},\n\n"
            f"You started a BambooHR self-serve path yesterday "
            f"({hc} employees · {needs}) and we didn’t lose your answers. "
            f"Pick up at step {step}:\n\n"
            f"Resume: {{origin}}{resume}\n\n"
            f"If Payroll, Elite, or 25+ employees is a better fit, reply and "
            f"we’ll connect you with a person.\n\n"
            f"— BambooHR"
        )
    return {"subject": subject, "body": body, "resumePath": resume}


def enrich_qualify_session_cadence(
    rec: dict[str, Any], *, now: datetime | None = None
) -> dict[str, Any]:
    """Attach cadence stage + suggested email for the demo inbox."""
    out = dict(rec)
    age = _age_hours(rec, now=now)
    out["ageHours"] = round(age, 1)
    day1_sent = bool(rec.get("cadenceDay1SentAt"))
    week1_sent = bool(rec.get("cadenceWeek1SentAt"))
    if week1_sent and day1_sent:
        stage = "done"
    elif age >= CADENCE_WEEK1_HOURS and not week1_sent:
        stage = "week1_due"
    elif age >= CADENCE_DAY1_HOURS and not day1_sent:
        stage = "day1_due"
    elif day1_sent and age < CADENCE_WEEK1_HOURS:
        stage = "day1_sent"
    else:
        stage = "waiting"
    out["cadenceStage"] = stage
    which = "week1" if stage == "week1_due" else "day1"
    copy = cadence_email_copy(rec, which=which)
    out["cadenceEmail"] = copy
    out["cadenceLabel"] = {
        "waiting": "Waiting (<24h)",
        "day1_due": "1-day follow-up due",
        "day1_sent": "1-day sent · wait for week",
        "week1_due": "1-week follow-up due",
        "done": "Cadence complete",
    }.get(stage, stage)
    return out


def mark_qualify_cadence_sent(
    session_id: str,
    which: str,
    *,
    crm_session: Any | None = None,
) -> dict[str, Any] | None:
    """Mark day1 or week1 cadence as sent; optionally create a CRM Task."""
    which = (which or "").strip().lower()
    if which not in {"day1", "week1"}:
        raise ValueError("which must be day1 or week1")
    if not session_id:
        return None
    field = "cadenceDay1SentAt" if which == "day1" else "cadenceWeek1SentAt"
    with _LOCK:
        store = _load_sessions()
        rec = store.get(session_id)
        if not rec:
            return None
        rec[field] = _now_iso()
        # Do not bump updatedAt for cadence marks — age stays tied to createdAt.
        store[session_id] = rec
        _save_sessions(store)
        enriched = enrich_qualify_session_cadence(rec)

    task_id = None
    warnings: list[str] = []
    if crm_session is not None:
        try:
            task_id = _create_cadence_task(crm_session, enriched, which=which)
            if task_id:
                with _LOCK:
                    store = _load_sessions()
                    row = store.get(session_id)
                    if row is not None:
                        key = (
                            "cadenceDay1TaskId"
                            if which == "day1"
                            else "cadenceWeek1TaskId"
                        )
                        row[key] = task_id
                        store[session_id] = row
                        _save_sessions(store)
                        enriched = enrich_qualify_session_cadence(row)
        except Exception as exc:  # noqa: BLE001
            warnings.append(f"Cadence Task skipped: {str(exc)[:240]}")
    if warnings:
        enriched = dict(enriched)
        enriched["warnings"] = warnings
    if task_id:
        enriched = dict(enriched)
        enriched["taskId"] = task_id
    return enriched


def _create_cadence_task(
    session: Any, rec: dict[str, Any], *, which: str
) -> str | None:
    """Log the nurture send on the matched Contact/Account (demo inbox)."""
    email = str(rec.get("email") or "").strip()
    company = str(rec.get("company") or "").strip()
    contact_id = None
    account_id = None
    if email:
        rows = session.soql(
            "SELECT Id, AccountId FROM Contact "
            f"WHERE Email = '{_soql_escape(email)}' LIMIT 1"
        )
        if rows:
            contact_id = rows[0].get("Id")
            account_id = rows[0].get("AccountId")
    if not account_id and company:
        rows = session.soql(
            "SELECT Id FROM Account "
            f"WHERE Name = '{_soql_escape(company)}' "
            "ORDER BY CreatedDate DESC LIMIT 1"
        )
        if rows:
            account_id = rows[0]["Id"]
    if not account_id and not contact_id:
        return None
    label = "1-day" if which == "day1" else "1-week"
    subject = f"BambooHR self-serve cadence ({label})"[:80]
    copy = cadence_email_copy(rec, which=which)
    desc = (
        f"Abandoned-wizard {label} follow-up marked sent from qualify inbox.\n"
        f"To: {email or '—'}\n"
        f"Subject: {copy.get('subject')}\n"
        f"Session: {rec.get('sessionId')}\n"
        f"Resume: {copy.get('resumePath')}\n"
    )[:32000]
    fields: dict[str, Any] = {
        "Subject": subject,
        "Description": desc,
        "Status": "Completed",
        "Priority": "Normal",
        "ActivityDate": datetime.now(timezone.utc).date().isoformat(),
    }
    if account_id:
        fields["WhatId"] = account_id
    if contact_id:
        fields["WhoId"] = contact_id
    return session.create("Task", fields)


def campaign_from_utm(utm: dict[str, Any] | None) -> str:
    utm = utm or {}
    return str(
        utm.get("utm_campaign")
        or utm.get("campaign")
        or utm.get("utm_source")
        or ""
    ).strip()
