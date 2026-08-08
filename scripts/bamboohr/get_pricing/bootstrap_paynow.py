#!/usr/bin/env python3
"""Bootstrap Pay Now guest access on a demo / scratch org (Phase 0).

Automates Data API–safe steps that otherwise break guest Pay Now after an
org rebuild:

  * ``WebStore.OptionsGuestBrowsingEnabled = true`` (Pay* stores)
  * Pay Now Profile ObjectPermissions **Read** on commerce objects

Does **not** flip Experience Preferences “Allow guest users to access public
APIs” (UI-only on many orgs) — see ``manualStillRequired`` in the output.

Examples::

  # Preview
  ~/.local/pipx/venvs/cumulusci/bin/python \\
    scripts/bamboohr/get_pricing/bootstrap_paynow.py --org master-demo

  # Apply
  ~/.local/pipx/venvs/cumulusci/bin/python \\
    scripts/bamboohr/get_pricing/bootstrap_paynow.py --org master-demo --execute

  # Apply + print readiness
  ~/.local/pipx/venvs/cumulusci/bin/python \\
    scripts/bamboohr/get_pricing/bootstrap_paynow.py --org master-demo \\
    --execute --check
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from payments import (  # noqa: E402
    bootstrap_paynow_guest_access,
    payments_readiness,
)
from service import OrgSession  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--org",
        required=True,
        help="SF CLI / CCI org alias (e.g. master-demo)",
    )
    parser.add_argument(
        "--execute",
        action="store_true",
        help="Apply changes (default is dry-run)",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="After bootstrap, print payments_readiness summary",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit full JSON (bootstrap + optional readiness)",
    )
    args = parser.parse_args()

    session = OrgSession(args.org)
    result = bootstrap_paynow_guest_access(session, dry_run=not args.execute)

    readiness = None
    if args.check:
        readiness = payments_readiness(session)

    if args.json:
        payload = {"bootstrap": result, "readiness": readiness}
        print(json.dumps(payload, indent=2, default=str))
        if readiness is not None and not readiness.get("readyForPayNow"):
            return 2
        return 0

    mode = "EXECUTE" if args.execute else "DRY-RUN"
    print(f"Pay Now guest bootstrap ({mode}) — org={args.org}")
    print()
    print("WebStores")
    for row in result.get("webStores") or []:
        flag = (
            "applied"
            if row.get("applied")
            else ("needed" if row.get("needed") else "ok")
        )
        print(f"  [{flag}] {row.get('name')} ({row.get('webStoreId')})")

    print()
    print("ObjectPermissions (Pay Now Profile)")
    for row in result.get("objectPermissions") or []:
        print(
            f"  [{row.get('status')}] {row.get('object')}"
            + (" (needed)" if row.get("needed") and row.get("status") == "pending" else "")
        )

    print()
    print("Still manual (UI / Payments setup)")
    for step in result.get("manualStillRequired") or []:
        print(f"  • {step}")

    if readiness is not None:
        print()
        ready = readiness.get("readyForPayNow")
        print(f"readyForPayNow: {ready}")
        blocking = readiness.get("blocking") or []
        if blocking:
            print(f"blocking: {', '.join(blocking)}")
        for step in readiness.get("manualSteps") or []:
            print(f"  → {step}")
        for check in readiness.get("checks") or []:
            mark = "✓" if check.get("ok") else ("·" if check.get("skipped") else "✗")
            print(f"  {mark} {check.get('id')}: {check.get('detail')}")
        if not ready:
            return 2

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
