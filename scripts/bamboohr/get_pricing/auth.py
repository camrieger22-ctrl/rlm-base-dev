"""Salesforce auth for the BambooHR Get Pricing BFF (hosted + local).

Resolution order (first match wins):

1. ``SF_ACCESS_TOKEN`` + ``SF_INSTANCE_URL`` — explicit bearer (CI / tunnel bootstrap)
2. JWT Connected App — ``SF_CLIENT_ID`` + ``SF_USERNAME`` + private key
   (``SF_PRIVATE_KEY`` PEM text or ``SF_PRIVATE_KEY_PATH``)
3. CumulusCI keychain org alias (local laptop default)

Never commit private keys or Connected App secrets. See ``HOSTED.md``.
"""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class SalesforceCreds:
    access_token: str
    instance_url: str
    mode: str  # token | jwt | cci
    label: str  # alias or username


def _env(name: str) -> str:
    return (os.environ.get(name) or "").strip()


def _token_from_env() -> SalesforceCreds | None:
    token = _env("SF_ACCESS_TOKEN")
    instance = _env("SF_INSTANCE_URL").rstrip("/")
    if token and instance:
        return SalesforceCreds(token, instance, "token", "env")
    return None


def _load_private_key() -> str | None:
    pem = _env("SF_PRIVATE_KEY")
    if pem:
        return pem.replace("\\n", "\n")
    path = _env("SF_PRIVATE_KEY_PATH")
    if path:
        return Path(path).expanduser().read_text(encoding="utf-8")
    return None


def _jwt_assertion(client_id: str, username: str, audience: str, private_key_pem: str) -> str:
    try:
        import jwt  # PyJWT (present in CumulusCI pipx venv)
    except ModuleNotFoundError as exc:
        raise SystemExit(
            "JWT auth requires PyJWT. Use the CumulusCI pipx Python, or "
            "`pip install PyJWT cryptography`."
        ) from exc

    now = int(time.time())
    payload = {
        "iss": client_id,
        "sub": username,
        "aud": audience,
        "exp": now + 180,
    }
    return jwt.encode(payload, private_key_pem, algorithm="RS256")


def _token_from_jwt() -> SalesforceCreds | None:
    client_id = _env("SF_CLIENT_ID")
    username = _env("SF_USERNAME")
    key = _load_private_key()
    if not (client_id and username and key):
        return None

    # My Domain login host preferred; fallback login.salesforce.com / test.
    audience = _env("SF_LOGIN_URL") or _env("SF_AUDIENCE") or "https://login.salesforce.com"
    audience = audience.rstrip("/")
    assertion = _jwt_assertion(client_id, username, audience, key)
    token_url = f"{audience}/services/oauth2/token"
    body = urllib.parse.urlencode(
        {
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": assertion,
        }
    ).encode()
    req = urllib.request.Request(
        token_url,
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        err = exc.read().decode("utf-8", errors="replace")
        raise SystemExit(
            f"JWT token request failed HTTP {exc.code}: {err[:1500]}\n"
            "Check Connected App consumer key, pre-authorized user, cert, "
            "and SF_LOGIN_URL (My Domain)."
        ) from exc

    token = data.get("access_token")
    instance = (data.get("instance_url") or "").rstrip("/")
    if not token or not instance:
        raise SystemExit(f"JWT response missing token/instance: {data}")
    return SalesforceCreds(token, instance, "jwt", username)


def _token_from_cci(alias: str) -> SalesforceCreds:
    try:
        from cumulusci.cli.runtime import CliRuntime
    except ModuleNotFoundError as exc:
        raise SystemExit(
            "No SF_* env auth and cumulusci is not installed in this Python.\n"
            "Hosted: set SF_ACCESS_TOKEN+SF_INSTANCE_URL or JWT "
            "(SF_CLIENT_ID/SF_USERNAME/SF_PRIVATE_KEY_PATH).\n"
            "Local: use ~/.local/pipx/venvs/cumulusci/bin/python … --org <alias>"
        ) from exc

    runtime = CliRuntime(load_keychain=True)
    org = runtime.keychain.get_org(alias)
    if hasattr(org, "refresh_oauth_token"):
        try:
            org.refresh_oauth_token(runtime.keychain)
        except Exception:  # noqa: BLE001
            pass
    return SalesforceCreds(
        org.access_token,
        str(org.instance_url).rstrip("/"),
        "cci",
        alias,
    )


def resolve_creds(org_alias: str | None = None) -> SalesforceCreds:
    """Resolve Salesforce credentials for the BFF / smoke scripts."""
    creds = _token_from_env()
    if creds:
        return creds
    creds = _token_from_jwt()
    if creds:
        return creds
    alias = (org_alias or _env("SF_ORG_ALIAS") or "master-demo").strip()
    return _token_from_cci(alias)
