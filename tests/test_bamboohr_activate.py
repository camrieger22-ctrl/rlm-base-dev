#!/usr/bin/env python3
"""Offline tests for BambooHR post-pay /activate aha steps."""

from __future__ import annotations

from datetime import date, datetime, timedelta, timezone

import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GP = os.path.join(REPO_ROOT, "scripts", "bamboohr", "get_pricing")
sys.path.insert(0, GP)

import activate as act  # noqa: E402

RESULTS: list[tuple[str, bool]] = []


def check(name: str, condition: bool) -> None:
    RESULTS.append((name, bool(condition)))
    print(f"  [{'PASS' if condition else 'FAIL'}] {name}")


class FakeSession:
    def __init__(self, account: dict):
        self.account = dict(account)
        self._instance = "https://example.my.salesforce.com"
        self.payments: list[dict] = []
        self.links: list[dict] = []
        self.assets: list[dict] = [{"Id": "02i000", "Quantity": 12}]
        self.contacts: list[dict] = [
            {"Id": "003BUYER", "FirstName": "Buyer", "LastName": "One", "Email": "buyer@aha.co"}
        ]
        self.users: list[dict] = [{"Id": "005000"}]
        self.tasks: list[dict] = []
        self.creates: list[tuple] = []
        self.patches: list[tuple] = []
        self._ids = 0

    def soql(self, q: str):
        u = q.upper()
        if "FROM ACCOUNT" in u:
            return [dict(self.account)]
        if "FROM PAYMENTLINK" in u:
            return list(self.links)
        if "FROM PAYMENT" in u:
            return list(self.payments)
        if "FROM ASSET" in u:
            return list(self.assets)
        if "FROM USER" in u:
            return list(self.users)
        if "FROM TASK" in u:
            rows = list(self.tasks)
            if "WHATID =" in u:
                what = q.split("WhatId =")[-1].strip().strip("'").split("'")[0]
                rows = [t for t in rows if t.get("WhatId") == what]
            if "WHOID =" in u:
                who = q.split("WhoId =")[-1].strip().strip("'").split("'")[0]
                rows = [t for t in rows if t.get("WhoId") == who]
            if "SUBJECT LIKE" in u:
                prefix = (
                    q.split("Subject LIKE")[-1]
                    .strip()
                    .strip("'")
                    .split("'")[0]
                    .rstrip("%")
                )
                rows = [t for t in rows if str(t.get("Subject") or "").startswith(prefix)]
            return rows
        if "FROM CONTACT" in u:
            rows = list(self.contacts)
            if "RLM_BAMBOO_ONBOARDEMPLOYEE__C = TRUE" in u:
                rows = [c for c in rows if c.get("RLM_Bamboo_OnboardEmployee__c")]
            elif "RLM_BAMBOO_ONBOARDEMPLOYEE__C != TRUE" in u:
                rows = [c for c in rows if not c.get("RLM_Bamboo_OnboardEmployee__c")]
            if "AND EMAIL =" in u:
                mail = q.split("Email =")[-1].strip().strip("'").split("'")[0]
                rows = [c for c in rows if (c.get("Email") or "") == mail]
            return rows
        return []

    def create(self, sobject: str, fields: dict) -> str:
        self._ids += 1
        prefix = {"Contact": "003", "Task": "00T"}.get(sobject, "001")
        rid = f"{prefix}NEW{self._ids:03d}"
        row = {
            "Id": rid,
            "Name": f"{fields.get('FirstName')} {fields.get('LastName')}".strip(),
            **fields,
        }
        self.creates.append((sobject, row))
        if sobject == "Contact":
            self.contacts.append(row)
        if sobject == "Task":
            self.tasks.append(row)
        return rid

    def patch(self, sobject: str, record_id: str, fields: dict) -> None:
        self.patches.append((sobject, record_id, dict(fields)))
        if sobject == "Account" and record_id == self.account.get("Id"):
            self.account.update(fields)
            emp = self.account.get("RLM_Bamboo_OnboardEmployees__c")
            email = self.account.get("RLM_Bamboo_OnboardAdminEmail__c")
            policy = self.account.get("RLM_Bamboo_OnboardTimeOffPolicy__c")
            self.account["RLM_Bamboo_OnboardComplete__c"] = bool(
                emp and int(emp) > 0 and email and policy
            )
        if sobject == "Contact":
            for c in self.contacts:
                if c.get("Id") == record_id:
                    c.update(fields)
        if sobject == "Task":
            for t in self.tasks:
                if t.get("Id") == record_id:
                    t.update(fields)


def _acct(**extra):
    row = {
        "Id": "001000000000001AAA",
        "Name": "Aha Co",
        "RLM_Bamboo_EmployeeCountAtSignup__c": 12,
        "RLM_Bamboo_OnboardEmployees__c": None,
        "RLM_Bamboo_OnboardAdminEmail__c": None,
        "RLM_Bamboo_OnboardTimeOffPolicy__c": None,
        "RLM_Bamboo_OnboardComplete__c": False,
    }
    row.update(extra)
    return row


def test_empty_checklist_without_account() -> None:
    print("\nempty account")
    session = FakeSession(_acct())
    data = act.build_activate_checklist(session)
    check("ok", data["ok"] is True)
    check("not stub", data["stub"] is False)
    check("aha incomplete", data["ahaComplete"] is False)
    ids = [s["id"] for s in data["steps"]]
    check("has aha steps", ids[-4:] == ["employees", "invite", "timeoff", "licenses"])
    check(
        "aha group",
        [s["id"] for s in data["ahaSteps"]]
        == ["employees", "invite", "timeoff", "licenses"],
    )
    check(
        "customer proof",
        [s["id"] for s in data["customerSteps"]] == ["paid", "assets", "login"],
    )
    check("employees open", data["steps"][3]["done"] is False)
    check("employees action", data["steps"][3]["action"] == "employees")
    check("team payload present", data["team"]["seatsFilled"] == 0)
    check("team cannot add without account", data["team"]["canAdd"] is False)
    check("cadence owner", data["cadence"]["owner"] == "Marketing")
    check("cadence not due without clock", data["cadence"]["due"] is False)


def test_add_named_employees() -> None:
    print("\nnamed employees as Contacts")
    session = FakeSession(_acct())
    session.payments = [{"Id": "0aQ", "Amount": 120, "Status": "Processed"}]

    out = act.complete_activate_steps(
        session,
        account_id="001000000000001AAA",
        first_name="Alex",
        last_name="Rivera",
        email="alex@aha.co",
    )
    created = [c for s, c in session.creates if s == "Contact"]
    check("created one Contact", len(created) == 1)
    check("flagged onboard employee", created[0].get("RLM_Bamboo_OnboardEmployee__c") is True)
    emp_step = next(s for s in out["steps"] if s["id"] == "employees")
    check("employees done after one person", emp_step["done"] is True)
    check("1 of 12 seats", "1 of 12" in emp_step["detail"])
    check("person listed", emp_step["people"][0]["name"] == "Alex Rivera")
    check("contact url", "Contact/003NEW001" in (emp_step["people"][0]["url"] or ""))
    check("count stamped on Account", session.account["RLM_Bamboo_OnboardEmployees__c"] == 1)
    check("form still open", emp_step["action"] == "employees")

    try:
        act.complete_activate_steps(
            session,
            account_id="001000000000001AAA",
            first_name="Alex",
            last_name="Rivera",
            email="alex@aha.co",
        )
        check("duplicate email raises", False)
    except ValueError as exc:
        check("duplicate email raises", "already" in str(exc))

    out = act.complete_activate_steps(
        session,
        account_id="001000000000001AAA",
        first_name="Priya",
        last_name="Shah",
        email="priya@aha.co",
    )
    emp_step = next(s for s in out["steps"] if s["id"] == "employees")
    check("two people", len(emp_step["people"]) == 2)
    check("2 of 12", "2 of 12" in emp_step["detail"])
    check("team snapshot filled", out["team"]["seatsFilled"] == 2)
    check("team can still add", out["team"]["canAdd"] is True)
    check("team setup url", "accountId=" in out["team"]["setupUrl"])


def test_team_snapshot_uses_licensed_seats() -> None:
    print("\nteam snapshot licensed seats")
    session = FakeSession(_acct())
    session.contacts.append(
        {
            "Id": "003EMP1",
            "FirstName": "Alex",
            "LastName": "Rivera",
            "Email": "alex@aha.co",
            "RLM_Bamboo_OnboardEmployee__c": True,
        }
    )
    snap = act.team_snapshot(
        session, account_id="001000000000001AAA", licensed_seats=12
    )
    check("12 licensed", snap["seatTarget"] == 12)
    check("1 filled", snap["seatsFilled"] == 1)
    check("not over", snap["overSeats"] is False)
    tight = act.team_snapshot(
        session, account_id="001000000000001AAA", licensed_seats=1
    )
    check("full seats cannot add", tight["canAdd"] is False)
    check("over when 1 seat", tight["overSeats"] is False)
    over = act.team_snapshot(
        session, account_id="001000000000001AAA", licensed_seats=0
    )
    check("zero seats falls back", over["seatTarget"] >= 1)


def test_complete_remaining_steps() -> None:
    print("\ninvite + timeoff after people")
    session = FakeSession(_acct())
    act.complete_activate_steps(
        session,
        account_id="001000000000001AAA",
        first_name="Alex",
        last_name="Rivera",
        email="alex@aha.co",
    )
    out = act.complete_activate_steps(
        session, account_id="001000000000001AAA", admin_email="pat@aha.co"
    )
    invite_step = next(s for s in out["steps"] if s["id"] == "invite")
    check("invite done", invite_step["done"])
    admin_contacts = [
        c for s, c in session.creates if s == "Contact" and c.get("Email") == "pat@aha.co"
    ]
    check("admin Contact created", len(admin_contacts) == 1)
    check("admin flag", admin_contacts[0].get("RLM_Bamboo_OnboardAdmin__c") is True)
    tasks = [c for s, c in session.creates if s == "Task"]
    check("invite Task created", len(tasks) == 1)
    check("task subject", tasks[0].get("Subject") == act.ADMIN_TASK_SUBJECT)
    check("task on account", tasks[0].get("WhatId") == "001000000000001AAA")
    check("task on contact", tasks[0].get("WhoId") == admin_contacts[0]["Id"])
    inv = invite_step.get("invite") or {}
    check("contact url", "Contact/" in (inv.get("contactUrl") or ""))
    check("task url", "Task/" in (inv.get("taskUrl") or ""))
    act.complete_activate_steps(
        session, account_id="001000000000001AAA", admin_email="pat@aha.co"
    )
    check(
        "second invite reuses Task",
        len([c for s, c in session.creates if s == "Task"]) == 1,
    )
    out = act.complete_activate_steps(
        session,
        account_id="001000000000001AAA",
        time_off_policy="Unlimited PTO",
    )
    timeoff_tasks = [
        c
        for s, c in session.creates
        if s == "Task" and c.get("Subject") == act.TIMEOFF_TASK_SUBJECT
    ]
    check("timeoff Task created", len(timeoff_tasks) == 1)
    check("aha complete", out["ahaComplete"] is True)
    check("cadence complete after aha", out["cadence"]["complete"] is True)
    check("cadence not due after aha", out["cadence"]["due"] is False)
    check("spreadsheet finish", "spreadsheet" in (out["message"] or "").lower())
    check("licenses mentions seats", "seats filled" in next(
        s for s in out["steps"] if s["id"] == "licenses"
    )["detail"])
    check("aha progress is 4", out["progress"]["total"] == 4)
    check("customer chips", len(out["customerSteps"]) == 3)


def test_invite_reuses_teammate_contact() -> None:
    print("\ninvite existing teammate")
    session = FakeSession(_acct())
    act.complete_activate_steps(
        session,
        account_id="001000000000001AAA",
        first_name="Alex",
        last_name="Rivera",
        email="alex@aha.co",
    )
    n_contacts = len([c for s, c in session.creates if s == "Contact"])
    out = act.complete_activate_steps(
        session, account_id="001000000000001AAA", admin_email="alex@aha.co"
    )
    check(
        "no extra Contact",
        len([c for s, c in session.creates if s == "Contact"]) == n_contacts,
    )
    alex = next(c for c in session.contacts if c.get("Email") == "alex@aha.co")
    check("teammate flagged admin", alex.get("RLM_Bamboo_OnboardAdmin__c") is True)
    check("task still created", any(s == "Task" for s, _ in session.creates))
    inv = next(s for s in out["steps"] if s["id"] == "invite").get("invite") or {}
    check("invite name is Alex", "Alex" in (inv.get("name") or ""))


def test_email_stamp_without_task_is_not_done() -> None:
    print("\ninvite requires Task")
    session = FakeSession(
        _acct(RLM_Bamboo_OnboardAdminEmail__c="cam.rieger22@gmail.com")
    )
    data = act.build_activate_checklist(
        session, account_id="001000000000001AAA"
    )
    inv = next(s for s in data["steps"] if s["id"] == "invite")
    check("not done without Task", inv["done"] is False)
    check("form still offered", inv["action"] == "invite")
    check("email prefilled", inv["value"] == "cam.rieger22@gmail.com")
    check("aha not complete", data["ahaComplete"] is False)


def test_timeoff_stamp_without_task_is_not_done() -> None:
    print("\ntimeoff requires Task")
    session = FakeSession(
        _acct(RLM_Bamboo_OnboardTimeOffPolicy__c="Unlimited PTO")
    )
    data = act.build_activate_checklist(
        session, account_id="001000000000001AAA"
    )
    step = next(s for s in data["steps"] if s["id"] == "timeoff")
    check("not done without Task", step["done"] is False)


def test_needs_put_timeoff_before_invite() -> None:
    print("\nneeds personalize order")
    session = FakeSession(
        _acct(RLM_Bamboo_PrimaryNeeds__c="hiring, timeoff")
    )
    data = act.build_activate_checklist(
        session, account_id="001000000000001AAA"
    )
    ids = [s["id"] for s in data["ahaSteps"]]
    check("timeoff before invite", ids == ["employees", "timeoff", "invite", "licenses"])
    check("hiring label", "hired" in data["ahaSteps"][0]["label"].lower())
    check("needs label", "Time off" in (data["needsLabel"] or ""))


def test_setup_clock_from_payment() -> None:
    print("\n14-day clock")
    clock = act.setup_clock(
        paid=True,
        payment={"createdDate": "2026-08-10T12:00:00.000+0000"},
        acct=None,
        aha_complete=False,
        today=date(2026, 8, 17),
    )
    check("day 8 of 14", clock["day"] == 8)
    check("not overdue", clock["overdue"] is False)
    check("deadline Aug 24", clock["deadline"] == "2026-08-24")


def test_aha_cadence_sequence() -> None:
    print("\nMarketing cadence")
    waiting = act.aha_cadence(clock={"day": 2}, sent={}, aha_complete=False)
    check("day 2 not due", waiting["due"] is False)
    check("waiting on day 3", "day 3" in (waiting.get("label") or "").lower())
    day3 = act.aha_cadence(clock={"day": 3}, sent={}, aha_complete=False)
    check("day 3 due", day3["due"] is True and day3["which"] == "day3")
    still_first = act.aha_cadence(clock={"day": 8}, sent={}, aha_complete=False)
    check("day 8 still owes day3 first", still_first["which"] == "day3")
    day7 = act.aha_cadence(
        clock={"day": 8}, sent={"day3": "00T1"}, aha_complete=False
    )
    check("after day3, day7 is due", day7["which"] == "day7")
    waiting = act.aha_cadence(
        clock={"day": 5}, sent={"day3": "00T1"}, aha_complete=False
    )
    check("waiting after mark is sent", waiting["due"] is False and waiting["sent"] is True)
    day14 = act.aha_cadence(
        clock={"day": 14},
        sent={"day3": "00T1", "day7": "00T2"},
        aha_complete=False,
    )
    check("day 14 due", day14["which"] == "day14")
    done = act.aha_cadence(clock={"day": 8}, sent={}, aha_complete=True)
    check("aha complete stops due", done["due"] is False and done["complete"] is True)


def test_mark_aha_cadence_creates_task() -> None:
    print("\nmark cadence sent")
    session = FakeSession(_acct())
    start = datetime.now(timezone.utc) - timedelta(days=2)
    session.payments = [
        {
            "Id": "0aQ",
            "Amount": 120,
            "Status": "Processed",
            "CreatedDate": start.strftime("%Y-%m-%dT12:00:00.000+0000"),
        }
    ]
    out = act.mark_aha_cadence_sent(
        session, account_id="001000000000001AAA", which="day3"
    )
    tasks = [c for s, c in session.creates if s == "Task"]
    check("created cadence Task", len(tasks) == 1)
    check(
        "marketing subject",
        "Day 3" in tasks[0]["Subject"] and "Marketing" in tasks[0]["Subject"],
    )
    check("completed Task", tasks[0]["Status"] == "Completed")
    check("on Account", tasks[0]["WhatId"] == "001000000000001AAA")
    check("day3 no longer due", (out.get("cadence") or {}).get("which") != "day3")
    act.mark_aha_cadence_sent(
        session, account_id="001000000000001AAA", which="day3"
    )
    check(
        "idempotent",
        len([c for s, c in session.creates if s == "Task"]) == 1,
    )
    try:
        act.mark_aha_cadence_sent(
            session, account_id="001000000000001AAA", which="day99"
        )
        check("bad which raises", False)
    except ValueError as exc:
        check("bad which raises", "day3" in str(exc))


def test_parse_needs_timetracking() -> None:
    print("\nneeds include time tracking")
    check(
        "time tracking alias",
        act.parse_needs("hiring, time tracking") == ["hiring", "timetracking"],
    )
    check("label", act.NEED_LABELS["timetracking"] == "Time tracking")


def test_auto_cadence_creates_due_tasks() -> None:
    print("\nauto cadence Tasks on GET")
    session = FakeSession(_acct())
    start = datetime.now(timezone.utc) - timedelta(days=7)
    session.payments = [
        {
            "Id": "0aQ",
            "Amount": 120,
            "Status": "Processed",
            "CreatedDate": start.strftime("%Y-%m-%dT12:00:00.000+0000"),
        }
    ]
    data = act.build_activate_checklist(
        session, account_id="001000000000001AAA"
    )
    subjects = [t.get("Subject") or "" for t in session.tasks]
    check("day3 auto-created", any("Day 3" in s for s in subjects))
    check("day7 auto-created", any("Day 7" in s for s in subjects))
    check("not due after auto", data["cadence"]["due"] is False)
    check("sent after auto", data["cadence"]["sent"] is True)
    n = len(session.tasks)
    act.build_activate_checklist(session, account_id="001000000000001AAA")
    check("GET is idempotent", len(session.tasks) == n)
    empty = FakeSession(_acct())
    empty.payments = list(session.payments)
    act.build_activate_checklist(empty)
    check("no Tasks without accountId", len(empty.tasks) == 0)


def test_pass3_activate_ui_hooks() -> None:
    print("\nActivate cadence UI")
    html = open(os.path.join(GP, "static", "activate.html"), encoding="utf-8").read()
    js = open(os.path.join(GP, "static", "activate.js"), encoding="utf-8").read()
    check("cadence card", 'id="activateCadence"' in html)
    check("mark sent button", 'id="cadenceMarkBtn"' in html)
    check("posts activate-cadence", "/api/activate-cadence" in js)
    check("Salesforce Account copy", "Salesforce Account" in html)
    check("cache wizard40", "wizard40" in html)


def test_rejects_bad_input() -> None:
    print("\nvalidation")
    session = FakeSession(_acct())
    try:
        act.complete_activate_steps(
            session, account_id="001000000000001AAA", first_name="A", last_name="B"
        )
        check("missing email raises", False)
    except ValueError as exc:
        check("missing email raises", "email" in str(exc).lower())
    try:
        act.complete_activate_steps(
            session, account_id="001000000000001AAA", admin_email="not-an-email"
        )
        check("bad email raises", False)
    except ValueError as exc:
        check("bad email raises", "adminEmail" in str(exc))
    try:
        act.complete_activate_steps(
            session, account_id="001000000000001AAA", time_off_policy="Nap time"
        )
        check("bad policy raises", False)
    except ValueError as exc:
        check("bad policy raises", "timeOffPolicy" in str(exc))
    try:
        act.complete_activate_steps(session, account_id="001000000000001AAA")
        check("empty patch raises", False)
    except ValueError as exc:
        check("empty patch raises", "Provide" in str(exc))


def main() -> int:
    test_empty_checklist_without_account()
    test_add_named_employees()
    test_team_snapshot_uses_licensed_seats()
    test_complete_remaining_steps()
    test_invite_reuses_teammate_contact()
    test_email_stamp_without_task_is_not_done()
    test_timeoff_stamp_without_task_is_not_done()
    test_needs_put_timeoff_before_invite()
    test_setup_clock_from_payment()
    test_aha_cadence_sequence()
    test_parse_needs_timetracking()
    test_auto_cadence_creates_due_tasks()
    test_mark_aha_cadence_creates_task()
    test_pass3_activate_ui_hooks()
    test_rejects_bad_input()
    passed = sum(1 for _, ok in RESULTS if ok)
    print(f"\n{passed}/{len(RESULTS)} passed")
    return 0 if passed == len(RESULTS) else 1


if __name__ == "__main__":
    raise SystemExit(main())
