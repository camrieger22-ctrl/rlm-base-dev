#!/usr/bin/env python3
"""Clean Get Pricing / Licenses demo transaction junk from an org.

Deletes **Quotes → Orders → Assets → Opportunities** for selected Accounts.
Does **not** touch BambooHR catalog / pricing data (use
``cci task run delete_bamboohr_pricing_data`` for that).

Default is **dry-run**. Pass ``--execute`` to apply.

Examples::

  # Preview Northwind Robotics clutter
  ~/.local/pipx/venvs/cumulusci/bin/python \\
    scripts/bamboohr/get_pricing/cleanup_demo_data.py --org master-demo \\
    --preset northwind

  # Wipe seeded country demo Accounts (Acme / Prestige / BambooHR UK Demo)
  ~/.local/pipx/venvs/cumulusci/bin/python \\
    scripts/bamboohr/get_pricing/cleanup_demo_data.py --org master-demo \\
    --preset seeded --execute

  # One Account by Id
  ~/.local/pipx/venvs/cumulusci/bin/python \\
    scripts/bamboohr/get_pricing/cleanup_demo_data.py --org master-demo \\
    --account-id 001gL00001enzlyQAA --execute
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from service import COUNTRY_ACCOUNT, OrgSession  # noqa: E402

SEEDED_NAMES = tuple(COUNTRY_ACCOUNT.values())


@dataclass
class Plan:
    accounts: list[dict[str, str]] = field(default_factory=list)
    assets: list[dict[str, str]] = field(default_factory=list)
    orders: list[dict[str, str]] = field(default_factory=list)
    quotes: list[dict[str, str]] = field(default_factory=list)
    opportunities: list[dict[str, str]] = field(default_factory=list)


@dataclass
class Result:
    deleted: list[str] = field(default_factory=list)
    skipped: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)


def _soql_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace("'", "\\'")


def resolve_accounts(
    session: OrgSession,
    *,
    account_ids: list[str],
    companies: list[str],
    preset: str | None,
) -> list[dict[str, str]]:
    found: dict[str, dict[str, str]] = {}

    def add_rows(rows: list[dict]) -> None:
        for r in rows:
            found[r["Id"]] = {"Id": r["Id"], "Name": r.get("Name") or r["Id"]}

    for aid in account_ids:
        aid = aid.strip()
        if not aid:
            continue
        rows = session.soql(
            f"SELECT Id, Name FROM Account WHERE Id = '{_soql_escape(aid)}' LIMIT 1"
        )
        if not rows:
            raise SystemExit(f"Account not found: {aid}")
        add_rows(rows)

    for name in companies:
        name = name.strip()
        if not name:
            continue
        rows = session.soql(
            "SELECT Id, Name FROM Account WHERE Name = "
            f"'{_soql_escape(name)}' LIMIT 5"
        )
        if not rows:
            raise SystemExit(f"Account not found by name: {name}")
        add_rows(rows)

    if preset == "northwind":
        add_rows(
            session.soql(
                "SELECT Id, Name FROM Account WHERE Name LIKE 'Northwind%' "
                "ORDER BY CreatedDate DESC LIMIT 50"
            )
        )
    elif preset == "seeded":
        for n in SEEDED_NAMES:
            add_rows(
                session.soql(
                    "SELECT Id, Name FROM Account WHERE Name = "
                    f"'{_soql_escape(n)}' LIMIT 1"
                )
            )
    elif preset == "get-pricing":
        # Northwind-style + seeded country demo Accounts
        add_rows(
            session.soql(
                "SELECT Id, Name FROM Account WHERE Name LIKE 'Northwind%' "
                "ORDER BY CreatedDate DESC LIMIT 50"
            )
        )
        for n in SEEDED_NAMES:
            add_rows(
                session.soql(
                    "SELECT Id, Name FROM Account WHERE Name = "
                    f"'{_soql_escape(n)}' LIMIT 1"
                )
            )
    elif preset:
        raise SystemExit(
            f"Unknown preset {preset!r}. Use northwind | seeded | get-pricing"
        )

    if not found:
        raise SystemExit(
            "No Accounts selected. Pass --account-id, --company, and/or --preset."
        )
    return list(found.values())


def build_plan(session: OrgSession, accounts: list[dict[str, str]]) -> Plan:
    plan = Plan(accounts=accounts)
    for acct in accounts:
        aid = acct["Id"]
        plan.assets.extend(
            {
                "Id": r["Id"],
                "Name": r.get("Name") or r["Id"],
                "AccountId": aid,
            }
            for r in session.soql(
                "SELECT Id, Name FROM Asset "
                f"WHERE AccountId = '{aid}' ORDER BY CreatedDate DESC LIMIT 500"
            )
        )
        plan.orders.extend(
            {
                "Id": r["Id"],
                "Name": r.get("OrderNumber") or r["Id"],
                "Status": r.get("Status") or "",
                "AccountId": aid,
            }
            for r in session.soql(
                "SELECT Id, OrderNumber, Status FROM Order "
                f"WHERE AccountId = '{aid}' ORDER BY CreatedDate DESC LIMIT 500"
            )
        )
        plan.quotes.extend(
            {
                "Id": r["Id"],
                "Name": r.get("QuoteNumber") or r.get("Name") or r["Id"],
                "Status": r.get("Status") or "",
                "AccountId": aid,
            }
            for r in session.soql(
                "SELECT Id, Name, QuoteNumber, Status FROM Quote "
                f"WHERE AccountId = '{aid}' ORDER BY CreatedDate DESC LIMIT 500"
            )
        )
        plan.opportunities.extend(
            {
                "Id": r["Id"],
                "Name": r.get("Name") or r["Id"],
                "AccountId": aid,
            }
            for r in session.soql(
                "SELECT Id, Name FROM Opportunity "
                f"WHERE AccountId = '{aid}' ORDER BY CreatedDate DESC LIMIT 500"
            )
        )
    return plan


def print_plan(plan: Plan) -> None:
    print("Accounts:")
    for a in plan.accounts:
        print(f"  {a['Id']}  {a['Name']}")
    print(f"\nWill target (child → parent):")
    print(f"  Assets:        {len(plan.assets)}")
    print(f"  Orders:        {len(plan.orders)}")
    print(f"  Quotes:        {len(plan.quotes)}")
    print(f"  Opportunities: {len(plan.opportunities)}")
    if plan.orders:
        print("\nOrders:")
        for o in plan.orders[:25]:
            print(f"  {o['Id']}  {o['Name']}  [{o.get('Status')}]")
        if len(plan.orders) > 25:
            print(f"  … +{len(plan.orders) - 25} more")
    if plan.assets:
        print("\nAssets (sample):")
        for a in plan.assets[:15]:
            print(f"  {a['Id']}  {a['Name']}")
        if len(plan.assets) > 15:
            print(f"  … +{len(plan.assets) - 15} more")
    print(
        "\nNote: Posted invoices / billing schedules are platform-managed and "
        "are not deleted. Catalog/pricing (BAMBOO-*) is untouched."
    )


def _try_delete(session: OrgSession, sobject: str, record_id: str, label: str, result: Result) -> None:
    try:
        session.delete(sobject, record_id)
        result.deleted.append(f"{sobject} {record_id} ({label})")
    except Exception as exc:  # noqa: BLE001
        result.errors.append(f"{sobject} {record_id} ({label}): {exc}")


def execute_plan(session: OrgSession, plan: Plan, *, delete_opps: bool) -> Result:
    result = Result()

    # Assets first (block order delete less often when orphaned)
    for a in plan.assets:
        _try_delete(session, "Asset", a["Id"], a["Name"], result)

    for o in plan.orders:
        oid, label, status = o["Id"], o["Name"], (o.get("Status") or "").lower()
        if status == "activated":
            try:
                session.patch("Order", oid, {"Status": "Draft"})
            except Exception as exc:  # noqa: BLE001
                result.errors.append(
                    f"Order {oid} ({label}): cannot draft activated order: {exc}"
                )
                continue
        _try_delete(session, "Order", oid, label, result)

    for q in plan.quotes:
        _try_delete(session, "Quote", q["Id"], q["Name"], result)

    if delete_opps:
        for opp in plan.opportunities:
            _try_delete(session, "Opportunity", opp["Id"], opp["Name"], result)
    else:
        for opp in plan.opportunities:
            result.skipped.append(
                f"Opportunity {opp['Id']} ({opp['Name']}) — pass --delete-opps to remove"
            )

    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--org", default="master-demo")
    parser.add_argument(
        "--account-id",
        action="append",
        default=[],
        help="Account Id (repeatable)",
    )
    parser.add_argument(
        "--company",
        action="append",
        default=[],
        help="Exact Account Name (repeatable)",
    )
    parser.add_argument(
        "--preset",
        choices=("northwind", "seeded", "get-pricing"),
        help="northwind | seeded (Acme/Prestige/UK) | get-pricing (both)",
    )
    parser.add_argument(
        "--execute",
        action="store_true",
        help="Apply deletes (default is dry-run)",
    )
    parser.add_argument(
        "--delete-opps",
        action="store_true",
        help="Also delete Opportunities under the Account(s)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print machine-readable plan/result JSON",
    )
    args = parser.parse_args()

    session = OrgSession(args.org)
    accounts = resolve_accounts(
        session,
        account_ids=list(args.account_id or []),
        companies=list(args.company or []),
        preset=args.preset,
    )
    plan = build_plan(session, accounts)

    if args.json and not args.execute:
        print(
            json.dumps(
                {
                    "dryRun": True,
                    "accounts": plan.accounts,
                    "counts": {
                        "assets": len(plan.assets),
                        "orders": len(plan.orders),
                        "quotes": len(plan.quotes),
                        "opportunities": len(plan.opportunities),
                    },
                    "assets": plan.assets,
                    "orders": plan.orders,
                    "quotes": plan.quotes,
                    "opportunities": plan.opportunities,
                },
                indent=2,
            )
        )
        return 0

    print_plan(plan)
    if not args.execute:
        print("\nDry-run only. Re-run with --execute to delete.")
        return 0

    print("\nExecuting deletes…")
    result = execute_plan(session, plan, delete_opps=args.delete_opps)
    print(f"\nDeleted: {len(result.deleted)}")
    for line in result.deleted:
        print(f"  ✓ {line}")
    if result.skipped:
        print(f"Skipped: {len(result.skipped)}")
        for line in result.skipped[:30]:
            print(f"  · {line}")
    if result.errors:
        print(f"Errors: {len(result.errors)}")
        for line in result.errors:
            print(f"  ✗ {line}")
    if args.json:
        print(
            json.dumps(
                {
                    "dryRun": False,
                    "deleted": result.deleted,
                    "skipped": result.skipped,
                    "errors": result.errors,
                },
                indent=2,
            )
        )
    return 1 if result.errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
