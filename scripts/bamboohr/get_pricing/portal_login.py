"""Provision Customer Community logins for Get Pricing buyers.

Used by POST /api/create-login (checkout success) and the Northwind
CLI provisioner. Creates/reactivates a community User on the Contact,
assigns RLM_BambooEcBuyer, ensures Network membership, sets password,
and returns a short-lived ecToken for /account handoff.
"""

from __future__ import annotations

import os
import re
import secrets
import string
import time
from typing import Any
from urllib.parse import quote

from ec_handoff import mint_ec_token
from service import OrgSession

PREFERRED_PROFILE_NAMES = (
    "BambooHR Customer Login",
    "Customer Community Login User",
)
PERMSET_NAME = "RLM_BambooEcBuyer"
DEFAULT_NETWORK_ID = "0DBgL0000027pRFWAY"  # BambooHR Get Pricing
DEFAULT_LOGIN_URL = "https://trailsignup-b4759183862b2b.my.site.com/bamboohr/s/login/"
DEFAULT_SITE_HOME = "https://trailsignup-b4759183862b2b.my.site.com/bamboohr/s/"


def _soql_str(value: str) -> str:
    return str(value).replace("\\", "\\\\").replace("'", "\\'")


def network_id() -> str:
    return (os.environ.get("BAMBOO_EC_NETWORK_ID") or DEFAULT_NETWORK_ID).strip()


def login_url() -> str:
    return (os.environ.get("BAMBOO_EC_LOGIN_URL") or DEFAULT_LOGIN_URL).strip()


def site_home() -> str:
    return (os.environ.get("BAMBOO_EC_SITE_HOME") or DEFAULT_SITE_HOME).strip()


def validate_password(password: str) -> str | None:
    """Return an error message, or None if acceptable for Salesforce policies."""
    if len(password) < 8:
        return "Password must be at least 8 characters."
    if len(password) > 64:
        return "Password must be 64 characters or fewer."
    classes = sum(
        [
            bool(re.search(r"[A-Z]", password)),
            bool(re.search(r"[a-z]", password)),
            bool(re.search(r"\d", password)),
            bool(re.search(r"[^A-Za-z0-9]", password)),
        ]
    )
    if classes < 3:
        return (
            "Password needs at least 3 of: uppercase, lowercase, number, symbol."
        )
    return None


def validate_email(email: str) -> str | None:
    email = email.strip()
    if not email or "@" not in email or "." not in email.split("@")[-1]:
        return "Enter a valid email address."
    if len(email) > 80:
        return "Email is too long."
    return None


def random_password(length: int = 16) -> str:
    alphabet = string.ascii_letters + string.digits + "!@#$%"
    chars = [
        secrets.choice(string.ascii_uppercase),
        secrets.choice(string.ascii_lowercase),
        secrets.choice(string.digits),
        secrets.choice("!@#$%"),
    ]
    chars += [secrets.choice(alphabet) for _ in range(max(0, length - 4))]
    secrets.SystemRandom().shuffle(chars)
    return "".join(chars)


def _ensure_network_profile(session: OrgSession, net_id: str, profile_id: str) -> None:
    rows = session.soql(
        "SELECT Id FROM NetworkMemberGroup "
        f"WHERE NetworkId = '{_soql_str(net_id)}' AND ParentId = '{_soql_str(profile_id)}' "
        "LIMIT 1"
    )
    if rows:
        return
    try:
        session.create(
            "NetworkMemberGroup",
            {"NetworkId": net_id, "ParentId": profile_id},
        )
    except Exception:
        # Experience Builder → Members is the fallback; non-fatal.
        pass


def _assign_permset(session: OrgSession, user_id: str, permset_id: str) -> None:
    existing = session.soql(
        "SELECT Id FROM PermissionSetAssignment "
        f"WHERE AssigneeId = '{_soql_str(user_id)}' "
        f"AND PermissionSetId = '{_soql_str(permset_id)}' LIMIT 1"
    )
    if existing:
        return
    session.create(
        "PermissionSetAssignment",
        {"AssigneeId": user_id, "PermissionSetId": permset_id},
    )


def _set_password(session: OrgSession, user_id: str, password: str) -> None:
    """Set community User password with retries (new Users race the password API)."""
    last_exc: Exception | None = None
    for attempt in range(4):
        try:
            # Clear soft lockouts when present (field may be unavailable).
            try:
                session.patch(
                    "User",
                    user_id,
                    {"IsPasswordLocked": False, "NumberOfFailedLogins": 0},
                )
            except Exception:
                pass
            session._http(
                "POST",
                f"/services/data/v67.0/sobjects/User/{user_id}/password",
                {"NewPassword": password},
            )
            return
        except Exception as exc:  # noqa: BLE001
            last_exc = exc
            msg = str(exc).lower()
            # Policy / reuse failures won't recover with sleep.
            if "password" in msg and (
                "policy" in msg or "previously" in msg or "history" in msg
            ):
                break
            time.sleep(1.5 * (attempt + 1))
    assert last_exc is not None
    raise last_exc


def _verify_password_set(session: OrgSession, user_id: str) -> bool:
    """Best-effort: User still active and not password-locked after set."""
    try:
        rows = session.soql(
            "SELECT Id, IsActive, IsPasswordLocked FROM User "
            f"WHERE Id = '{_soql_str(user_id)}' LIMIT 1"
        )
    except Exception:
        return True  # field unavailable — assume OK
    if not rows:
        return False
    row = rows[0]
    if not row.get("IsActive"):
        return False
    if row.get("IsPasswordLocked"):
        return False
    return True


def _resolve_profile(session: OrgSession) -> dict[str, str]:
    for pname in PREFERRED_PROFILE_NAMES:
        rows = session.soql(
            f"SELECT Id, Name FROM Profile WHERE Name = '{_soql_str(pname)}' LIMIT 1"
        )
        if rows:
            return {"id": rows[0]["Id"], "name": rows[0]["Name"]}
    raise ValueError(
        "No usable community profile found. Deploy "
        "unpackaged/post_bamboohr/profiles (BambooHR Customer Login) "
        "or enable standard external profiles in Digital Experiences Settings."
    )


def _unique_username(session: OrgSession, desired: str, contact_id: str) -> str:
    """Return a Username that is free or already owned by this Contact."""
    base = desired.strip()
    if not base:
        raise ValueError("Username is required.")
    rows = session.soql(
        f"SELECT Id, ContactId FROM User WHERE Username = '{_soql_str(base)}' LIMIT 1"
    )
    if not rows:
        return base
    if rows[0].get("ContactId") == contact_id:
        return base
    # Collision with another user — derive a unique variant.
    local, _, domain = base.partition("@")
    for _ in range(8):
        candidate = f"{local}+{secrets.token_hex(2)}@{domain}" if domain else f"{base}.{secrets.token_hex(2)}"
        hit = session.soql(
            f"SELECT Id FROM User WHERE Username = '{_soql_str(candidate)}' LIMIT 1"
        )
        if not hit:
            return candidate
    raise ValueError(f"Username {base!r} is already taken. Try another email.")


def create_buyer_login(
    session: OrgSession,
    *,
    account_id: str,
    contact_id: str,
    email: str,
    password: str,
    username: str | None = None,
    first_name: str | None = None,
    last_name: str | None = None,
    ttl_seconds: int = 3600,
) -> dict[str, Any]:
    """Create or refresh a community login and return handoff details."""
    account_id = (account_id or "").strip()
    contact_id = (contact_id or "").strip()
    email = (email or "").strip()
    password = password or ""

    if not account_id or not contact_id:
        raise ValueError("accountId and contactId are required.")
    email_err = validate_email(email)
    if email_err:
        raise ValueError(email_err)
    pw_err = validate_password(password)
    if pw_err:
        raise ValueError(pw_err)

    contacts = session.soql(
        "SELECT Id, Email, FirstName, LastName, AccountId, Account.Name "
        f"FROM Contact WHERE Id = '{_soql_str(contact_id)}' LIMIT 1"
    )
    if not contacts:
        raise ValueError(f"Contact not found: {contact_id}")
    contact = contacts[0]
    if contact.get("AccountId") != account_id:
        raise ValueError("Contact does not belong to this Account.")

    patch: dict[str, Any] = {}
    if email and email != (contact.get("Email") or ""):
        patch["Email"] = email
    if first_name and first_name != (contact.get("FirstName") or ""):
        patch["FirstName"] = first_name
    if last_name and last_name != (contact.get("LastName") or ""):
        patch["LastName"] = last_name
    if patch:
        session.patch("Contact", contact_id, patch)
        contact.update(patch)

    desired_username = (username or email).strip()
    username_final = _unique_username(session, desired_username, contact_id)

    existing = session.soql(
        "SELECT Id, Username, IsActive FROM User "
        f"WHERE ContactId = '{_soql_str(contact_id)}' LIMIT 1"
    )
    created = False
    if existing:
        user_id = existing[0]["Id"]
        username_final = existing[0]["Username"] or username_final
        if not existing[0].get("IsActive"):
            session.patch("User", user_id, {"IsActive": True})
        # Keep email in sync on the User when possible.
        try:
            session.patch("User", user_id, {"Email": email})
        except Exception:
            pass
    else:
        profile = _resolve_profile(session)
        net_id = network_id()
        _ensure_network_profile(session, net_id, profile["id"])

        fn = (first_name or contact.get("FirstName") or "Buyer").strip() or "Buyer"
        ln = (last_name or contact.get("LastName") or "User").strip() or "User"
        alias = ((fn[:1] + ln[:4]).lower() + "xx")[:8]
        nickname = f"bh_{secrets.token_hex(4)}"

        user_id = session.create(
            "User",
            {
                "Username": username_final,
                "Email": email,
                "FirstName": fn,
                "LastName": ln,
                "Alias": alias,
                "TimeZoneSidKey": "America/Denver",
                "LocaleSidKey": "en_US",
                "EmailEncodingKey": "UTF-8",
                "LanguageLocaleKey": "en_US",
                "ProfileId": profile["id"],
                "ContactId": contact_id,
                "CommunityNickname": nickname,
            },
        )
        created = True
        # New community Users briefly reject password sets — give insert a beat.
        time.sleep(2.0)

    try:
        _set_password(session, user_id, password)
        if not _verify_password_set(session, user_id):
            # One more hard retry after unlock.
            time.sleep(1.0)
            _set_password(session, user_id, password)
    except Exception as exc:  # noqa: BLE001
        raise ValueError(
            "Could not set password (check Salesforce password policies — "
            "try a new password that is not one of your last few, with upper, "
            f"lower, number, and symbol): {exc}"
        ) from exc

    permsets = session.soql(
        f"SELECT Id FROM PermissionSet WHERE Name = '{_soql_str(PERMSET_NAME)}' LIMIT 1"
    )
    if permsets:
        _assign_permset(session, user_id, permsets[0]["Id"])

    net_id = network_id()
    members = session.soql(
        "SELECT Id FROM NetworkMember "
        f"WHERE NetworkId = '{_soql_str(net_id)}' AND MemberId = '{_soql_str(user_id)}' "
        "LIMIT 1"
    )
    if not members:
        try:
            session.create(
                "NetworkMember",
                {"NetworkId": net_id, "MemberId": user_id},
            )
        except Exception:
            pass

    token = mint_ec_token(
        account_id,
        contact_id,
        ttl_seconds=ttl_seconds,
    )
    account_name = ""
    acct = contact.get("Account") or {}
    if isinstance(acct, dict):
        account_name = acct.get("Name") or ""

    return {
        "ok": True,
        "created": created,
        "userId": user_id,
        "username": username_final,
        "email": email,
        "accountId": account_id,
        "accountName": account_name,
        "contactId": contact_id,
        "ecToken": token,
        "accountUrl": f"/account?ecToken={quote(token, safe='')}",
        "loginUrl": login_url(),
        "siteHome": site_home(),
        "message": (
            "Login created. You can open Licenses & billing now, and sign in later "
            f"at the BambooHR site with {username_final}."
            if created
            else f"Login updated for {username_final}. Opening Licenses & billing."
        ),
    }
