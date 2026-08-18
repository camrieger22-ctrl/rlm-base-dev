"""Post-pay activation checklist — paid / licenses / login plus aha steps.

Aha steps persist on the Account. Employees added here are Contacts with
RLM_Bamboo_OnboardEmployee__c. System-of-record is Salesforce.
"""

from __future__ import annotations

import re
from datetime import date, datetime, timedelta
from typing import Any
from urllib.parse import quote

from service import OrgSession, lightning_record_url

TIME_OFF_POLICIES = (
    "Accrual — 10 days",
    "Accrual — 15 days",
    "Unlimited PTO",
)

ADMIN_TASK_SUBJECT = "Invited as BambooHR admin"
TIMEOFF_TASK_SUBJECT = "Set time-off policy"
SETUP_WINDOW_DAYS = 14

NEED_KEYS = ("hiring", "onboarding", "timeoff", "performance", "reporting")
NEED_LABELS = {
    "hiring": "Hiring",
    "onboarding": "Onboarding",
    "timeoff": "Time off",
    "performance": "Performance",
    "reporting": "Reporting",
}

_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

_ACCOUNT_FIELDS = (
    "Id",
    "Name",
    "CreatedDate",
    "RLM_Bamboo_EmployeeCountAtSignup__c",
    "RLM_Bamboo_PrimaryNeeds__c",
    "RLM_Bamboo_OnboardEmployees__c",
    "RLM_Bamboo_OnboardAdminEmail__c",
    "RLM_Bamboo_OnboardTimeOffPolicy__c",
    "RLM_Bamboo_OnboardComplete__c",
)


def _soql_str(value: str) -> str:
    return (value or "").replace("\\", "\\\\").replace("'", "\\'")


def _int_or_none(value: Any) -> int | None:
    if value is None or value == "":
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _load_account(
    session: OrgSession,
    *,
    account_id: str | None = None,
    company: str | None = None,
) -> dict[str, Any] | None:
    from account_console import resolve_account_id

    if not account_id and not company:
        return None
    resolved = resolve_account_id(session, account_id=account_id, company=company)
    aid = resolved["Id"]
    try:
        rows = session.soql(
            "SELECT "
            + ", ".join(_ACCOUNT_FIELDS)
            + f" FROM Account WHERE Id = '{_soql_str(aid)}' LIMIT 1"
        )
    except RuntimeError:
        return resolved
    return rows[0] if rows else resolved


def _seat_target(acct: dict[str, Any] | None, asset_qty: float) -> int:
    signup = _int_or_none((acct or {}).get("RLM_Bamboo_EmployeeCountAtSignup__c"))
    if signup and signup > 0:
        return signup
    if asset_qty and asset_qty > 0:
        return int(asset_qty)
    return 12


def _onboard_people(session: OrgSession, account_id: str) -> list[dict[str, Any]]:
    aid = _soql_str(account_id)
    try:
        rows = session.soql(
            "SELECT Id, FirstName, LastName, Name, Email "
            "FROM Contact WHERE AccountId = "
            f"'{aid}' AND RLM_Bamboo_OnboardEmployee__c = true "
            "ORDER BY CreatedDate ASC LIMIT 25"
        )
    except RuntimeError:
        return []
    base = (getattr(session, "_instance", None) or "").rstrip("/")
    people: list[dict[str, Any]] = []
    for row in rows:
        name = (
            " ".join(
                p for p in (row.get("FirstName"), row.get("LastName")) if p
            ).strip()
            or row.get("Name")
            or "Employee"
        )
        people.append(
            {
                "id": row["Id"],
                "name": name,
                "email": (row.get("Email") or "").strip() or None,
                "url": lightning_record_url(base, "Contact", row["Id"]),
            }
        )
    return people


def _add_employee(
    session: OrgSession,
    *,
    account_id: str,
    first_name: str,
    last_name: str,
    email: str,
    seat_target: int,
    existing: list[dict[str, Any]],
) -> None:
    first = first_name.strip()
    last = last_name.strip()
    mail = email.strip()
    if not first or not last:
        raise ValueError("firstName and lastName are required")
    if not _EMAIL_RE.match(mail) or len(mail) > 80:
        raise ValueError("email must be a valid work email")
    if len(existing) >= seat_target:
        raise ValueError(f"All {seat_target} seats are filled")
    if any((p.get("email") or "").lower() == mail.lower() for p in existing):
        raise ValueError(f"{mail} is already on this team")

    aid = _soql_str(account_id)
    dupes = session.soql(
        "SELECT Id, RLM_Bamboo_OnboardEmployee__c FROM Contact "
        f"WHERE AccountId = '{aid}' AND Email = '{_soql_str(mail)}' LIMIT 1"
    )
    if dupes:
        if dupes[0].get("RLM_Bamboo_OnboardEmployee__c"):
            raise ValueError(f"{mail} is already on this team")
        session.patch(
            "Contact",
            dupes[0]["Id"],
            {"RLM_Bamboo_OnboardEmployee__c": True},
        )
        return
    session.create(
        "Contact",
        {
            "AccountId": account_id,
            "FirstName": first[:40],
            "LastName": last[:80],
            "Email": mail,
            "LeadSource": "SelfServe_Onboard",
            "RLM_Bamboo_OnboardEmployee__c": True,
        },
    )


def _display_name(row: dict[str, Any], *, fallback: str = "Teammate") -> str:
    return (
        " ".join(
            p for p in (row.get("FirstName"), row.get("LastName")) if p
        ).strip()
        or row.get("Name")
        or fallback
    )


def _name_from_email(email: str) -> tuple[str, str]:
    local, _, domain = (email or "").partition("@")
    token = (local.split("+")[0] or "Admin").replace(".", " ").replace("_", " ")
    parts = [p for p in token.split() if p]
    first = (parts[0] if parts else "Admin")[:40]
    if len(parts) >= 2:
        last = " ".join(parts[1:])[:80]
    else:
        host = (domain.split(".")[0] if domain else "Admin").title()
        last = (host or "Admin")[:80]
    return first, last


def _find_task(
    session: OrgSession,
    *,
    account_id: str,
    subject_prefix: str,
    contact_id: str | None = None,
) -> str | None:
    clauses = [f"WhatId = '{_soql_str(account_id)}'"]
    if contact_id:
        clauses.append(f"WhoId = '{_soql_str(contact_id)}'")
    where = " AND ".join(clauses)
    try:
        rows = session.soql(
            "SELECT Id FROM Task "
            f"WHERE {where} "
            f"AND Subject LIKE '{_soql_str(subject_prefix)}%' "
            "ORDER BY CreatedDate DESC LIMIT 1"
        )
    except RuntimeError:
        return None
    return (rows[0].get("Id") if rows else None) or None


def _find_admin_task(
    session: OrgSession, *, account_id: str, contact_id: str | None
) -> str | None:
    return _find_task(
        session,
        account_id=account_id,
        subject_prefix=ADMIN_TASK_SUBJECT,
        contact_id=contact_id,
    )


def _invite_admin(
    session: OrgSession, *, account_id: str, email: str, company_name: str | None
) -> dict[str, str]:
    """Upsert admin Contact + invite Task. Does not send email."""
    aid = _soql_str(account_id)
    mail = email.strip()
    rows = session.soql(
        "SELECT Id, FirstName, LastName, Name, Email, "
        "RLM_Bamboo_OnboardAdmin__c FROM Contact "
        f"WHERE AccountId = '{aid}' AND Email = '{_soql_str(mail)}' LIMIT 1"
    )
    if rows:
        contact_id = rows[0]["Id"]
        if not rows[0].get("RLM_Bamboo_OnboardAdmin__c"):
            try:
                session.patch(
                    "Contact",
                    contact_id,
                    {"RLM_Bamboo_OnboardAdmin__c": True},
                )
            except RuntimeError:
                pass
    else:
        first, last = _name_from_email(mail)
        payload = {
            "AccountId": account_id,
            "FirstName": first,
            "LastName": last,
            "Email": mail,
            "LeadSource": "SelfServe_Onboard",
            "RLM_Bamboo_OnboardAdmin__c": True,
        }
        try:
            contact_id = session.create("Contact", payload)
        except RuntimeError:
            payload.pop("RLM_Bamboo_OnboardAdmin__c", None)
            contact_id = session.create("Contact", payload)

    desc = (
        f"Self-serve Activate: invited as BambooHR admin for "
        f"{company_name or 'this company'}.\n"
        f"Email: {mail}\n"
        "No product email is sent in this demo — this Task is the CRM proof."
    )[:32000]
    fields: dict[str, Any] = {
        "Subject": ADMIN_TASK_SUBJECT,
        "Description": desc,
        "Status": "Completed",
        "Priority": "Normal",
        "ActivityDate": date.today().isoformat(),
        "WhatId": account_id,
        "WhoId": contact_id,
    }
    existing = _find_admin_task(
        session, account_id=account_id, contact_id=contact_id
    )
    if existing:
        session.patch(
            "Task",
            existing,
            {
                "Subject": ADMIN_TASK_SUBJECT,
                "Description": desc,
                "Status": "Completed",
                "WhoId": contact_id,
            },
        )
        task_id = existing
    else:
        task_id = session.create("Task", fields)
    return {"contactId": contact_id, "taskId": task_id}


def _invite_state(
    session: OrgSession, *, account_id: str | None, admin_email: str | None
) -> dict[str, Any] | None:
    if not account_id or not admin_email:
        return None
    aid = _soql_str(account_id)
    mail = admin_email.strip()
    contact: dict[str, Any] | None = None
    try:
        rows = session.soql(
            "SELECT Id, FirstName, LastName, Name, Email "
            "FROM Contact WHERE AccountId = "
            f"'{aid}' AND Email = '{_soql_str(mail)}' LIMIT 1"
        )
        contact = rows[0] if rows else None
    except RuntimeError:
        contact = None
    contact_id = (contact or {}).get("Id")
    task_id = _find_admin_task(
        session, account_id=account_id, contact_id=contact_id
    )
    if not task_id:
        task_id = _find_admin_task(
            session, account_id=account_id, contact_id=None
        )
    base = (getattr(session, "_instance", None) or "").rstrip("/")
    return {
        "email": mail,
        "name": _display_name(contact, fallback=mail) if contact else mail,
        "contactId": contact_id,
        "contactUrl": lightning_record_url(base, "Contact", contact_id),
        "taskId": task_id,
        "taskUrl": lightning_record_url(base, "Task", task_id),
    }


def _as_date(value: Any) -> date | None:
    if value is None or value == "":
        return None
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    text = str(value).strip()
    if not text:
        return None
    try:
        return date.fromisoformat(text[:10])
    except ValueError:
        return None


def setup_clock(
    *,
    paid: bool,
    payment: dict[str, Any] | None,
    acct: dict[str, Any] | None,
    aha_complete: bool,
    today: date | None = None,
) -> dict[str, Any] | None:
    """Day N of 14 from Pay Now (else Account CreatedDate)."""
    if not paid and not (acct or {}).get("CreatedDate"):
        return None
    start = _as_date((payment or {}).get("createdDate")) or _as_date(
        (acct or {}).get("CreatedDate")
    )
    if not start:
        return None
    today = today or date.today()
    deadline = start + timedelta(days=SETUP_WINDOW_DAYS)
    day_n = (today - start).days + 1
    if day_n < 1:
        day_n = 1
    overdue = (not aha_complete) and today > deadline
    remaining = max(0, (deadline - today).days)
    shown = day_n if overdue else min(day_n, SETUP_WINDOW_DAYS)
    return {
        "startDate": start.isoformat(),
        "deadline": deadline.isoformat(),
        "day": shown,
        "totalDays": SETUP_WINDOW_DAYS,
        "overdue": overdue,
        "remainingDays": remaining,
        "label": (
            f"Past the {SETUP_WINDOW_DAYS}-day setup window"
            if overdue
            else f"Day {shown} of {SETUP_WINDOW_DAYS}"
        ),
        "deadlineLabel": f"{deadline.strftime('%b')} {deadline.day}",
    }


def parse_needs(raw: Any) -> list[str]:
    text = str(raw or "").lower()
    found: list[str] = []
    aliases = {
        "hiring": ("hiring",),
        "onboarding": ("onboarding",),
        "timeoff": ("timeoff", "time off", "time-off"),
        "performance": ("performance",),
        "reporting": ("reporting",),
    }
    for key in NEED_KEYS:
        if any(alias in text for alias in aliases[key]):
            found.append(key)
    return found


def _set_timeoff_policy(
    session: OrgSession,
    *,
    account_id: str,
    policy: str,
    company_name: str | None,
    who_id: str | None,
) -> str:
    desc = (
        f"Self-serve Activate: starting time-off policy for "
        f"{company_name or 'this company'}.\n"
        f"Policy: {policy}\n"
        "This Task is the CRM proof — no PTO engine is started."
    )[:32000]
    fields: dict[str, Any] = {
        "Subject": TIMEOFF_TASK_SUBJECT,
        "Description": desc,
        "Status": "Completed",
        "Priority": "Normal",
        "ActivityDate": date.today().isoformat(),
        "WhatId": account_id,
    }
    if who_id:
        fields["WhoId"] = who_id
    existing = _find_task(
        session,
        account_id=account_id,
        subject_prefix=TIMEOFF_TASK_SUBJECT,
    )
    if existing:
        session.patch(
            "Task",
            existing,
            {
                "Subject": TIMEOFF_TASK_SUBJECT,
                "Description": desc,
                "Status": "Completed",
            },
        )
        return existing
    return session.create("Task", fields)


def _timeoff_state(
    session: OrgSession,
    *,
    account_id: str | None,
    policy: str | None,
) -> dict[str, Any] | None:
    if not account_id:
        return None
    task_id = _find_task(
        session, account_id=account_id, subject_prefix=TIMEOFF_TASK_SUBJECT
    )
    base = (getattr(session, "_instance", None) or "").rstrip("/")
    return {
        "policy": policy,
        "taskId": task_id,
        "taskUrl": lightning_record_url(base, "Task", task_id),
    }


def team_snapshot(
    session: OrgSession,
    *,
    account_id: str | None = None,
    acct: dict[str, Any] | None = None,
    people: list[dict[str, Any]] | None = None,
    asset_qty: float | None = None,
    licensed_seats: int | None = None,
) -> dict[str, Any]:
    """Named onboard Contacts vs licensed seats. Does not change Asset quantity."""
    aid = (account_id or (acct or {}).get("Id") or "").strip() or None
    if not acct and aid:
        acct = _load_account(session, account_id=aid)
        aid = (acct or {}).get("Id") or aid
    if people is None:
        people = _onboard_people(session, aid) if aid else []
    if licensed_seats is None:
        qty = 0.0 if asset_qty is None else float(asset_qty)
        if asset_qty is None and aid:
            try:
                rows = session.soql(
                    "SELECT Quantity FROM Asset "
                    f"WHERE AccountId = '{_soql_str(aid)}' LIMIT 50"
                )
                qty = sum(float(a.get("Quantity") or 0) for a in rows)
            except (RuntimeError, TypeError, ValueError):
                qty = 0.0
        licensed_seats = _seat_target(acct, qty)
    try:
        licensed_seats = max(1, int(licensed_seats or 12))
    except (TypeError, ValueError):
        licensed_seats = 12
    filled = len(people)
    remaining = max(0, licensed_seats - filled)
    admin_email = ((acct or {}).get("RLM_Bamboo_OnboardAdminEmail__c") or "").strip()
    time_off = ((acct or {}).get("RLM_Bamboo_OnboardTimeOffPolicy__c") or "").strip()
    aha_complete = bool((acct or {}).get("RLM_Bamboo_OnboardComplete__c"))
    if not aha_complete:
        aha_complete = bool(filled > 0 and admin_email and time_off)
    aid_q = quote(aid or "", safe="")
    return {
        "people": people,
        "seatTarget": licensed_seats,
        "seatsFilled": filled,
        "seatsRemaining": remaining,
        "canAdd": bool(aid) and remaining > 0,
        "overSeats": filled > licensed_seats,
        "ahaComplete": aha_complete,
        "setupUrl": f"/activate?accountId={aid_q}" if aid else "/activate",
        "adminInvited": bool(admin_email),
        "timeOffSet": bool(time_off),
    }


def complete_activate_steps(
    session: OrgSession,
    *,
    account_id: str | None = None,
    company: str | None = None,
    first_name: str | None = None,
    last_name: str | None = None,
    email: str | None = None,
    admin_email: str | None = None,
    time_off_policy: str | None = None,
) -> dict[str, Any]:
    """Create an onboard Contact and/or PATCH aha fields, then refresh."""
    acct = _load_account(session, account_id=account_id, company=company)
    if not acct:
        raise ValueError("accountId or company is required")

    adding_person = any(
        v is not None and str(v).strip() for v in (first_name, last_name, email)
    )
    if adding_person:
        if not first_name or not last_name or not email:
            raise ValueError(
                "firstName, lastName, and email are required to add an employee"
            )
        people = _onboard_people(session, acct["Id"])
        asset_qty = 0.0
        try:
            assets = session.soql(
                "SELECT Quantity FROM Asset "
                f"WHERE AccountId = '{_soql_str(acct['Id'])}' LIMIT 50"
            )
            asset_qty = sum(float(a.get("Quantity") or 0) for a in assets)
        except (RuntimeError, TypeError, ValueError):
            pass
        _add_employee(
            session,
            account_id=acct["Id"],
            first_name=first_name,
            last_name=last_name,
            email=email,
            seat_target=_seat_target(acct, asset_qty),
            existing=people,
        )
        count = len(_onboard_people(session, acct["Id"]))
        session.patch(
            "Account",
            acct["Id"],
            {"RLM_Bamboo_OnboardEmployees__c": count},
        )

    patch: dict[str, Any] = {}
    if admin_email is not None:
        mail = str(admin_email).strip()
        if not _EMAIL_RE.match(mail) or len(mail) > 80:
            raise ValueError("adminEmail must be a valid work email")
        _invite_admin(
            session,
            account_id=acct["Id"],
            email=mail,
            company_name=acct.get("Name"),
        )
        patch["RLM_Bamboo_OnboardAdminEmail__c"] = mail
    if time_off_policy is not None:
        policy = str(time_off_policy).strip()
        if policy not in TIME_OFF_POLICIES:
            raise ValueError(
                "timeOffPolicy must be one of: " + ", ".join(TIME_OFF_POLICIES)
            )
        who_id = None
        prior_admin = (
            str(admin_email or "").strip()
            or (acct.get("RLM_Bamboo_OnboardAdminEmail__c") or "")
        ).strip() or None
        if prior_admin:
            st = _invite_state(
                session, account_id=acct["Id"], admin_email=prior_admin
            )
            who_id = (st or {}).get("contactId")
        _set_timeoff_policy(
            session,
            account_id=acct["Id"],
            policy=policy,
            company_name=acct.get("Name"),
            who_id=who_id,
        )
        patch["RLM_Bamboo_OnboardTimeOffPolicy__c"] = policy
    if patch:
        session.patch("Account", acct["Id"], patch)
    if not adding_person and not patch:
        raise ValueError(
            "Provide firstName/lastName/email, adminEmail, and/or timeOffPolicy"
        )

    return build_activate_checklist(session, account_id=acct["Id"])


def build_activate_checklist(
    session: OrgSession,
    *,
    account_id: str | None = None,
    company: str | None = None,
) -> dict[str, Any]:
    """Return activation checklist for an Account (or empty when unknown)."""
    account_id = (account_id or "").strip() or None
    company = (company or "").strip() or None

    acct: dict[str, Any] | None = None
    if account_id or company:
        acct = _load_account(session, account_id=account_id, company=company)
        account_id = acct["Id"]

    paid = False
    payment: dict[str, Any] | None = None
    login_ready = False
    asset_count = 0
    asset_qty = 0.0
    contact_id: str | None = None
    people: list[dict[str, Any]] = []

    if account_id:
        aid = _soql_str(account_id)
        pays = session.soql(
            "SELECT Id, Amount, Status, CreatedDate "
            f"FROM Payment WHERE AccountId = '{aid}' AND Status = 'Processed' "
            "ORDER BY CreatedDate DESC LIMIT 3"
        )
        if pays:
            paid = True
            payment = {
                "id": pays[0]["Id"],
                "amount": pays[0].get("Amount"),
                "status": pays[0].get("Status"),
                "createdDate": pays[0].get("CreatedDate"),
            }
        else:
            links = session.soql(
                "SELECT Id, Status, Amount FROM PaymentLink "
                f"WHERE AccountId = '{aid}' AND Status = 'Disabled' "
                "ORDER BY CreatedDate DESC LIMIT 1"
            )
            if links:
                paid = True
                payment = {
                    "paymentLinkId": links[0]["Id"],
                    "amount": links[0].get("Amount"),
                    "status": "link_disabled",
                }

        try:
            asset_rows = session.soql(
                f"SELECT Id, Quantity FROM Asset WHERE AccountId = '{aid}' LIMIT 50"
            )
        except RuntimeError:
            asset_rows = session.soql(
                f"SELECT Id FROM Asset WHERE AccountId = '{aid}' LIMIT 50"
            )
        asset_count = len(asset_rows)
        asset_qty = sum(float(a.get("Quantity") or 0) for a in asset_rows)

        users = session.soql(
            "SELECT Id FROM User WHERE IsActive = true "
            f"AND Contact.AccountId = '{aid}' LIMIT 1"
        )
        login_ready = bool(users)
        try:
            buyer = session.soql(
                f"SELECT Id FROM Contact WHERE AccountId = '{aid}' "
                "AND RLM_Bamboo_OnboardEmployee__c != true "
                "ORDER BY CreatedDate ASC LIMIT 1"
            )
        except RuntimeError:
            buyer = session.soql(
                f"SELECT Id FROM Contact WHERE AccountId = '{aid}' "
                "ORDER BY CreatedDate ASC LIMIT 1"
            )
        if buyer:
            contact_id = buyer[0]["Id"]

        people = _onboard_people(session, account_id)

    name = (acct or {}).get("Name") or "your company"
    signup_hc = _int_or_none((acct or {}).get("RLM_Bamboo_EmployeeCountAtSignup__c"))
    seat_target = _seat_target(acct, asset_qty)
    employees_loaded = len(people)
    admin_email = ((acct or {}).get("RLM_Bamboo_OnboardAdminEmail__c") or "").strip() or None
    time_off = ((acct or {}).get("RLM_Bamboo_OnboardTimeOffPolicy__c") or "").strip() or None

    aid_q = quote(account_id or "", safe="")
    licenses_href = f"/account?accountId={aid_q}" if account_id else "/account"
    seats_left = max(0, seat_target - employees_loaded)
    employees_done = employees_loaded > 0
    invite = (
        _invite_state(session, account_id=account_id, admin_email=admin_email)
        if account_id
        else None
    )
    invite_done = bool(invite and invite.get("taskId"))
    timeoff = (
        _timeoff_state(session, account_id=account_id, policy=time_off)
        if account_id
        else None
    )
    timeoff_done = bool(timeoff and timeoff.get("taskId"))
    aha_complete = bool(employees_loaded > 0 and invite_done and timeoff_done)
    needs = parse_needs((acct or {}).get("RLM_Bamboo_PrimaryNeeds__c"))
    clock = setup_clock(
        paid=paid, payment=payment, acct=acct, aha_complete=aha_complete
    )

    if "hiring" in needs or "onboarding" in needs:
        emp_label = "Add the people you hired"
        emp_empty = (
            f"Get them out of the spreadsheet — add 2–3 by name. "
            f"You have {seat_target} seats"
            + (f" (signed up at {signup_hc})" if signup_hc else "")
            + "."
        )
    else:
        emp_label = "Add your first employees"
        emp_empty = (
            f"Add 2–3 people by name. You have {seat_target} seats"
            + (f" (signed up at {signup_hc})" if signup_hc else "")
            + "."
        )
    if employees_loaded:
        emp_detail = f"{employees_loaded} of {seat_target} seats filled"
        if seats_left:
            emp_detail += " — add another teammate"
    else:
        emp_detail = emp_empty

    timeoff_focus = "timeoff" in needs
    if timeoff_focus:
        timeoff_label = "Set the time-off policy you came for"
        timeoff_open = "You said time off matters — pick a starting policy"
    else:
        timeoff_label = "Set up time off policies"
        timeoff_open = "Pick a starting policy — you can change it later"
    invite_open = (
        "Invite someone who can help run reviews and BambooHR"
        if "performance" in needs
        else "Send an invite to someone who can help run BambooHR"
    )

    people_n = employees_loaded
    if aha_complete:
        finish = (
            f"{people_n} people in, admin invited, time off set — "
            f"{name}'s HR is out of the spreadsheet."
        )
    elif clock:
        finish = (
            f"Welcome to BambooHR, {name} — get value by {clock['deadlineLabel']} "
            f"({clock['label']})."
        )
    elif account_id:
        finish = (
            f"Welcome to BambooHR, {name} — add people, invite an admin, "
            "and pick a time-off policy to get value this week."
        )
    else:
        finish = "Pay your invoice, create a login, then return here to activate."

    customer_steps = [
        {
            "id": "paid",
            "label": "Paid",
            "done": paid,
            "action": None,
            "detail": (
                f"${float(payment['amount']):,.2f}"
                if payment and payment.get("amount") is not None
                else ("Card authorized" if paid else "Pay Now first")
            ),
        },
        {
            "id": "assets",
            "label": "Licensed",
            "done": asset_count > 0,
            "action": None,
            "detail": f"{asset_count} asset(s)" if asset_count else "Waiting on assets",
        },
        {
            "id": "login",
            "label": "Signed in",
            "done": login_ready,
            "action": None,
            "detail": "Community user ready" if login_ready else "Create login on your quote",
        },
    ]
    employees_step = {
        "id": "employees",
        "group": "aha",
        "label": emp_label,
        "done": employees_done,
        "action": "employees" if seats_left else None,
        "seatTarget": seat_target,
        "seatsRemaining": seats_left,
        "people": people,
        "detail": emp_detail,
    }
    invite_step = {
        "id": "invite",
        "group": "aha",
        "label": "Invite an admin teammate",
        "done": invite_done,
        "action": "invite",
        "value": admin_email,
        "invite": invite,
        "detail": (
            f"Invited {invite['name'] if invite else admin_email} — Contact and Task in Salesforce"
            if invite_done
            else invite_open
        ),
    }
    timeoff_step = {
        "id": "timeoff",
        "group": "aha",
        "label": timeoff_label,
        "done": timeoff_done,
        "action": "timeoff",
        "options": list(TIME_OFF_POLICIES),
        "value": time_off,
        "timeoff": timeoff,
        "detail": (
            f"{time_off} — Task in Salesforce"
            if timeoff_done
            else timeoff_open
        ),
    }
    licenses_step = {
        "id": "licenses",
        "group": "aha",
        "label": "Your company, not a spreadsheet",
        "done": aha_complete,
        "href": licenses_href,
        "detail": (
            f"{employees_loaded} of {seat_target} seats filled — open Licenses & billing"
            if aha_complete
            else "Finish setup, then manage seats and modules as home"
        ),
    }
    aha_mid = (
        [timeoff_step, invite_step] if timeoff_focus else [invite_step, timeoff_step]
    )
    aha_steps = [employees_step, *aha_mid, licenses_step]
    steps = customer_steps + aha_steps
    aha_done = sum(1 for s in aha_steps if s.get("done"))

    return {
        "ok": True,
        "accountId": account_id,
        "accountName": name if acct else None,
        "contactId": contact_id,
        "paid": paid,
        "payment": payment,
        "assetCount": asset_count,
        "loginReady": login_ready,
        "ahaComplete": aha_complete,
        "licensesUrl": licenses_href,
        "customerSteps": customer_steps,
        "ahaSteps": aha_steps,
        "steps": steps,
        "needs": needs,
        "needsLabel": ", ".join(NEED_LABELS[k] for k in needs if k in NEED_LABELS),
        "setup": clock,
        "progress": {
            "done": aha_done,
            "total": len(aha_steps),
            "customerDone": sum(1 for s in customer_steps if s.get("done")),
            "customerTotal": len(customer_steps),
        },
        "team": team_snapshot(
            session,
            account_id=account_id,
            acct=acct,
            people=people,
            asset_qty=asset_qty,
        ),
        "message": finish,
        "stub": False,
    }

