#!/usr/bin/env python3
"""Provision a Customer Community Login user for BambooHR Get Pricing (5b).

Default: Northwind Robotics Contact on master-demo → community user +
RLM_BambooEcBuyer permission set + Network membership.

  set -a; source scripts/bamboohr/get_pricing/.env; set +a
  ~/.local/pipx/venvs/cumulusci/bin/python \\
    scripts/bamboohr/get_pricing/provision_ec_demo_user.py --org master-demo

Login URL (site):
  https://trailsignup-b4759183862b2b.my.site.com/bamboohr/s/login/
"""

from __future__ import annotations

import argparse
import json
import secrets
import string
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from service import OrgSession  # noqa: E402

DEFAULT_CONTACT_ID = "003gL000011wu3xQAA"  # Casey Nguyen @ Northwind Robotics 170200
DEFAULT_NETWORK_ID = "0DBgL0000027pRFWAY"  # BambooHR Get Pricing
# Prefer custom profile (API-creatable without Digital Experiences "allow
# standard external profiles" toggle). Fall back to the standard profile.
PREFERRED_PROFILE_NAMES = (
    "BambooHR Customer Login",
    "Customer Community Login User",
)
PERMSET_NAME = "RLM_BambooEcBuyer"


def _password(length: int = 16) -> str:
    alphabet = string.ascii_letters + string.digits + "!@#$%"
    # Salesforce password policies: mix of classes
    chars = [
        secrets.choice(string.ascii_uppercase),
        secrets.choice(string.ascii_lowercase),
        secrets.choice(string.digits),
        secrets.choice("!@#$%"),
    ]
    chars += [secrets.choice(alphabet) for _ in range(max(0, length - 4))]
    secrets.SystemRandom().shuffle(chars)
    return "".join(chars)


def _ensure_network_profile(session: OrgSession, network_id: str, profile_id: str) -> None:
    rows = session.soql(
        "SELECT Id, ParentId FROM NetworkMemberGroup "
        f"WHERE NetworkId = '{network_id}' AND ParentId = '{profile_id}' LIMIT 1"
    )
    if rows:
        print(f"Network already allows profile {profile_id}")
        return
    try:
        session.create(
            "NetworkMemberGroup",
            {"NetworkId": network_id, "ParentId": profile_id},
        )
        print(f"Added profile {profile_id} to NetworkMemberGroup")
    except Exception as exc:  # noqa: BLE001
        print(
            f"WARN: could not add NetworkMemberGroup (add profile in Experience "
            f"Builder → Administration → Members): {exc}"
        )


def _assign_permset(session: OrgSession, user_id: str, permset_id: str) -> None:
    existing = session.soql(
        "SELECT Id FROM PermissionSetAssignment "
        f"WHERE AssigneeId = '{user_id}' AND PermissionSetId = '{permset_id}' LIMIT 1"
    )
    if existing:
        print("Permission set already assigned")
        return
    session.create(
        "PermissionSetAssignment",
        {"AssigneeId": user_id, "PermissionSetId": permset_id},
    )
    print(f"Assigned {PERMSET_NAME}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--org", default="master-demo")
    parser.add_argument("--contact-id", default=DEFAULT_CONTACT_ID)
    parser.add_argument("--network-id", default=DEFAULT_NETWORK_ID)
    parser.add_argument("--username", default="")
    parser.add_argument("--password", default="")
    args = parser.parse_args()

    session = OrgSession(args.org)
    contact_rows = session.soql(
        "SELECT Id, Email, FirstName, LastName, AccountId, Account.Name "
        f"FROM Contact WHERE Id = '{args.contact_id}' LIMIT 1"
    )
    if not contact_rows:
        print(f"Contact not found: {args.contact_id}", file=sys.stderr)
        return 1
    contact = contact_rows[0]
    print(
        f"Contact: {contact.get('FirstName')} {contact.get('LastName')} "
        f"· {contact.get('Account', {}).get('Name')} · {contact.get('Email')}"
    )

    existing_user = session.soql(
        f"SELECT Id, Username, IsActive FROM User WHERE ContactId = '{args.contact_id}' LIMIT 1"
    )
    password = args.password or _password()
    username = args.username or "casey.nguyen.nw170200@bamboohr.demo"
    if existing_user:
        user_id = existing_user[0]["Id"]
        username = existing_user[0]["Username"]
        print(f"Reusing User {user_id} ({username})")
        if not existing_user[0].get("IsActive"):
            session.patch("User", user_id, {"IsActive": True})
            print("Reactivated user")
    else:
        profiles = []
        for pname in PREFERRED_PROFILE_NAMES:
            profiles = session.soql(
                f"SELECT Id, Name FROM Profile WHERE Name = '{pname}' LIMIT 1"
            )
            if profiles:
                break
        if not profiles:
            print(
                "No usable community profile found. Deploy "
                "unpackaged/post_bamboohr/profiles/BambooHR Customer Login "
                "or enable standard external profiles in Digital Experiences Settings.",
                file=sys.stderr,
            )
            return 1
        profile_id = profiles[0]["Id"]
        print(f"Using profile: {profiles[0]['Name']} ({profile_id})")
        _ensure_network_profile(session, args.network_id, profile_id)

        email = contact.get("Email") or "casey.nguyen+nw170200@northwind.example"
        nickname = f"casey_nw{secrets.token_hex(3)}"
        alias = (contact.get("FirstName") or "c")[:1] + (contact.get("LastName") or "user")[:4]
        alias = (alias.lower() + "xx")[:8]

        payload = {
            "Username": username,
            "Email": email,
            "FirstName": contact.get("FirstName") or "Casey",
            "LastName": contact.get("LastName") or "Nguyen",
            "Alias": alias,
            "TimeZoneSidKey": "America/Denver",
            "LocaleSidKey": "en_US",
            "EmailEncodingKey": "UTF-8",
            "LanguageLocaleKey": "en_US",
            "ProfileId": profile_id,
            "ContactId": args.contact_id,
            "CommunityNickname": nickname,
        }
        print("Creating User…")
        user_id = session.create("User", payload)
        print(f"Created User {user_id} ({username})")

    # Set / reset password
    try:
        session._http(
            "POST",
            f"/services/data/v67.0/sobjects/User/{user_id}/password",
            {"NewPassword": password},
        )
        print("Password set")
    except Exception as exc:  # noqa: BLE001
        print(f"WARN: password set failed ({exc}). Set manually in Setup.")

    permsets = session.soql(
        f"SELECT Id FROM PermissionSet WHERE Name = '{PERMSET_NAME}' LIMIT 1"
    )
    if not permsets:
        print(
            f"WARN: Permission Set {PERMSET_NAME} not found — deploy_post_bamboohr first"
        )
    else:
        _assign_permset(session, user_id, permsets[0]["Id"])

    # Ensure NetworkMember
    members = session.soql(
        "SELECT Id FROM NetworkMember "
        f"WHERE NetworkId = '{args.network_id}' AND MemberId = '{user_id}' LIMIT 1"
    )
    if not members:
        try:
            session.create(
                "NetworkMember",
                {"NetworkId": args.network_id, "MemberId": user_id},
            )
            print("Added NetworkMember")
        except Exception as exc:  # noqa: BLE001
            print(
                f"WARN: NetworkMember create failed (often auto-added after profile "
                f"is allowed on the Network): {exc}"
            )
    else:
        print("Already a NetworkMember")

    out = {
        "userId": user_id,
        "username": username,
        "password": password,
        "contactId": args.contact_id,
        "accountId": contact.get("AccountId"),
        "loginUrl": "https://trailsignup-b4759183862b2b.my.site.com/bamboohr/s/login/",
        "siteHome": "https://trailsignup-b4759183862b2b.my.site.com/bamboohr/s/",
    }

    print("\n=== EC demo login ===")
    print(json.dumps(out, indent=2))
    print(
        "\nAfter sign-in: home → Manage licenses & billing "
        "(requires BFF + EC_HANDOFF_SECRET matching the Custom Label)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
