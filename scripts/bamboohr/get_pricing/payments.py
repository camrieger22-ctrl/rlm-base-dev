"""Salesforce Payments / Pay Now after BambooHR checkout.

Platform path (invoice-centric):

  Order Activated
    → BillingSchedule (ReadyForInvoicing)
    → POST /commerce/invoicing/invoices/collection/actions/generate
    → Posted Invoice
    → PaymentLink (Pay Now) → PaymentUrl

``master-demo`` typically has billing schedules after activate, but Pay Now
requires a merchant account + Pay Now site URL in Payments setup. This module
always returns a structured prompt: either a live ``paymentUrl`` or a clear
``blockedReason`` plus Invoice Lightning link when an invoice exists.
"""

from __future__ import annotations

import time
import uuid
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from typing import Any

from service import API, OrgSession


@dataclass
class PaymentPrompt:
    ready: bool
    order_id: str = ""
    invoice_id: str | None = None
    invoice_number: str | None = None
    invoice_balance: float | None = None
    payment_link_id: str | None = None
    payment_url: str | None = None
    invoice_url: str | None = None
    blocked_reason: str | None = None
    warnings: list[str] = field(default_factory=list)

    def as_dict(self) -> dict[str, Any]:
        return {
            "ready": self.ready,
            "orderId": self.order_id or None,
            "invoiceId": self.invoice_id,
            "invoiceNumber": self.invoice_number,
            "invoiceBalance": self.invoice_balance,
            "paymentLinkId": self.payment_link_id,
            "paymentUrl": self.payment_url,
            "invoiceUrl": self.invoice_url,
            "blockedReason": self.blocked_reason,
            "warnings": self.warnings,
        }


def _soql_soft(session: OrgSession, query: str) -> list[dict]:
    """SOQL that returns [] on field/object errors (org shape varies)."""
    try:
        return session.soql(query)
    except Exception:  # noqa: BLE001
        return []


def payments_readiness(session: OrgSession) -> dict[str, Any]:
    """Org probe for Pay Now — merchants, method set, guest store, guest APIs."""
    gateways = _soql_soft(
        session,
        "SELECT Id, PaymentGatewayName, Status FROM PaymentGateway LIMIT 5",
    )
    merchants = _soql_soft(
        session,
        "SELECT Id, Name, Status, PaymentStatus, PayoutStatus "
        "FROM MerchantAccount LIMIT 5",
    )
    if not merchants:
        merchants = _soql_soft(
            session, "SELECT Id, Name FROM MerchantAccount LIMIT 5"
        )
    method_sets = _soql_soft(
        session,
        "SELECT Id, DeveloperName, MerchantAccountId "
        "FROM MerchAccPaymentMethodSet ORDER BY CreatedDate ASC LIMIT 10",
    )
    webhook = _soql_soft(
        session,
        "SELECT Id, Name, Status, UrlPathPrefix FROM Network "
        "WHERE Name LIKE '%Payment%' OR Name LIKE '%Pay Now%' "
        "ORDER BY Name LIMIT 10",
    )
    pay_now_networks = [
        n
        for n in webhook
        if "pay now" in (n.get("Name") or "").lower()
        or (n.get("UrlPathPrefix") or "").lower().startswith("paynow")
    ]
    stores = _soql_soft(
        session,
        "SELECT Id, Name, OptionsGuestBrowsingEnabled FROM WebStore "
        "WHERE Name LIKE '%Pay%' OR Name LIKE '%pay%' LIMIT 10",
    )
    # Prefer store named Pay Now
    pay_store = next(
        (s for s in stores if (s.get("Name") or "").strip().lower() == "pay now"),
        stores[0] if stores else None,
    )

    guest_user = _soql_soft(
        session,
        "SELECT Id, Name, ProfileId, Profile.Name FROM User "
        "WHERE Profile.Name = 'Pay Now Profile' AND IsActive = true LIMIT 1",
    )
    guest_profile_id = (guest_user[0].get("ProfileId") if guest_user else None) or ""
    guest_ps_id = ""
    webstore_read = False
    if guest_profile_id:
        ps_rows = _soql_soft(
            session,
            f"SELECT Id FROM PermissionSet WHERE ProfileId = '{guest_profile_id}' LIMIT 1",
        )
        guest_ps_id = ps_rows[0]["Id"] if ps_rows else ""
        if guest_ps_id:
            op = _soql_soft(
                session,
                "SELECT Id, PermissionsRead FROM ObjectPermissions "
                f"WHERE ParentId = '{guest_ps_id}' AND SobjectType = 'WebStore' LIMIT 1",
            )
            webstore_read = bool(op and op[0].get("PermissionsRead"))

    sites = _soql_soft(
        session,
        "SELECT Id, Name, UrlPathPrefix, OptionsAllowGuestPaymentsApi, Status "
        "FROM Site WHERE Name LIKE 'Pay%' OR UrlPathPrefix LIKE 'paynow%' LIMIT 10",
    )
    if not sites:
        sites = _soql_soft(
            session,
            "SELECT Id, Name, UrlPathPrefix, Status FROM Site "
            "WHERE Name LIKE 'Pay%' OR UrlPathPrefix LIKE 'paynow%' LIMIT 10",
        )
    vanity = next(
        (
            s
            for s in sites
            if (s.get("UrlPathPrefix") or "").lower() == "paynow"
        ),
        None,
    )

    instance = (session._instance or "").rstrip("/")
    # Force.com → my.site.com for Experience
    site_host = instance.replace(".my.salesforce.com", ".my.site.com").replace(
        ".salesforce.com", ".my.site.com"
    )
    paynow_base = f"{site_host}/paynow" if site_host else ""

    guest_session_ok: bool | None = None
    guest_session_error: str | None = None
    guest_link_ok: bool | None = None
    guest_link_error: str | None = None
    if pay_store and paynow_base:
        ws_id = pay_store["Id"]
        try:
            code, body = _http_get_json(
                f"{paynow_base}/webruntime/api/services/data/v67.0/"
                f"commerce/webstores/{ws_id}/session-context"
                "?language=en-US&asGuest=true&htmlEncode=false"
            )
            guest_session_ok = code == 200
            if code != 200:
                guest_session_error = _guest_err_msg(body) or f"HTTP {code}"
        except Exception as exc:  # noqa: BLE001
            guest_session_ok = False
            guest_session_error = str(exc)[:300]

        # Optional: probe payment-link-configs with any Active link
        links = session.soql(
            "SELECT Id FROM PaymentLink WHERE Status = 'Active' "
            "ORDER BY CreatedDate DESC LIMIT 1"
        )
        if links:
            pl15 = links[0]["Id"][:15]
            try:
                code, body = _http_get_json(
                    f"{paynow_base}/webruntime/api/services/data/v67.0/"
                    f"payments/payment-link-configs/{pl15}?asGuest=true"
                )
                guest_link_ok = code == 200
                if code != 200:
                    guest_link_error = _guest_err_msg(body) or f"HTTP {code}"
            except Exception as exc:  # noqa: BLE001
                guest_link_ok = False
                guest_link_error = str(exc)[:300]

    merchant_ok = len(merchants) > 0
    method_set_ok = len(method_sets) > 0
    store_ok = bool(pay_store)
    browsing_ok = bool(pay_store and pay_store.get("OptionsGuestBrowsingEnabled"))
    webhook_live = any(
        (n.get("Status") or "").lower() == "live" for n in webhook
    )
    pay_now_live = any(
        (n.get("Status") or "").lower() == "live" for n in pay_now_networks
    ) or any(
        (s.get("Status") or "").lower() in ("active", "published")
        for s in sites
        if "pay" in (s.get("Name") or "").lower()
    )

    checks: list[dict[str, Any]] = [
        {"id": "merchant", "ok": merchant_ok, "detail": f"{len(merchants)} MerchantAccount(s)"},
        {
            "id": "paymentMethodSet",
            "ok": method_set_ok,
            "detail": (
                ", ".join(m.get("DeveloperName") or m["Id"] for m in method_sets)
                if method_sets
                else "none"
            ),
        },
        {
            "id": "payNowNetworkOrSite",
            "ok": bool(pay_now_networks or sites),
            "detail": (
                f"networks={len(pay_now_networks)} sites={len(sites)} "
                f"liveish={pay_now_live or webhook_live}"
            ),
        },
        {
            "id": "webStore",
            "ok": store_ok,
            "detail": (pay_store or {}).get("Name") or "none",
        },
        {
            "id": "guestBrowsing",
            "ok": browsing_ok,
            "detail": (
                f"OptionsGuestBrowsingEnabled={bool(browsing_ok)}"
                if pay_store
                else "no Pay Now WebStore"
            ),
        },
        {
            "id": "guestWebStoreRead",
            "ok": webstore_read,
            "detail": (
                f"Pay Now Profile ObjectPermissions Read WebStore={webstore_read}"
            ),
        },
        {
            "id": "guestSessionContext",
            "ok": guest_session_ok is True,
            "detail": (
                "skipped (no store/site)"
                if guest_session_ok is None
                else ("200" if guest_session_ok else guest_session_error)
            ),
            "skipped": guest_session_ok is None,
        },
        {
            "id": "guestPaymentLinkConfigs",
            "ok": guest_link_ok is True or guest_link_ok is None,
            "detail": (
                "skipped (no Active PaymentLink)"
                if guest_link_ok is None
                else ("200" if guest_link_ok else guest_link_error)
            ),
            "skipped": guest_link_ok is None,
        },
    ]

    # Guest public APIs: Site field may lag; runtime guest probes are authoritative.
    if vanity is not None:
        checks.append(
            {
                "id": "siteAllowGuestPaymentsApiField",
                "ok": bool(vanity.get("OptionsAllowGuestPaymentsApi")),
                "detail": (
                    "Site.OptionsAllowGuestPaymentsApi="
                    f"{vanity.get('OptionsAllowGuestPaymentsApi')} "
                    "(prefer guestPaymentLinkConfigs probe; field can lag)"
                ),
                "informational": True,
            }
        )

    blocking = [
        c
        for c in checks
        if not c.get("ok") and not c.get("skipped") and not c.get("informational")
    ]
    ready = len(blocking) == 0 and merchant_ok and method_set_ok and browsing_ok

    manual_steps: list[str] = []
    if not merchant_ok:
        manual_steps.append(
            "Salesforce Payments → create/activate Stripe Test MerchantAccount"
        )
    if not method_set_ok:
        manual_steps.append("Add MerchAccPaymentMethodSet with Card on the merchant")
    if not pay_now_networks and not sites:
        manual_steps.append(
            "Create/publish Pay Now Experience site and set Pay Now site URL in Payments setup"
        )
    if guest_session_ok is False and guest_session_error and "public" in (
        guest_session_error or ""
    ).lower():
        manual_steps.append(
            "Pay Now Workspaces → Administration → Preferences → "
            "Allow guest users to access public APIs"
        )
    elif guest_link_ok is False and guest_link_error and (
        "not currently enabled" in (guest_link_error or "").lower()
        or "insufficient" in (guest_link_error or "").lower()
    ):
        manual_steps.append(
            "Pay Now Workspaces → Administration → Preferences → "
            "Allow guest users to access public APIs (then Publish)"
        )
    if not browsing_ok or not webstore_read:
        manual_steps.append(
            "Run: python scripts/bamboohr/get_pricing/bootstrap_paynow.py --org <alias>"
        )

    return {
        "paymentGatewayCount": len(gateways),
        "merchantAccountCount": len(merchants),
        "paymentMethodSetCount": len(method_sets),
        "paymentsWebhookLive": webhook_live,
        "payNowSiteUrl": paynow_base or None,
        "readyForPayNow": ready,
        "checks": checks,
        "blocking": [c["id"] for c in blocking],
        "manualSteps": manual_steps,
        "gateways": [
            {
                "id": g.get("Id"),
                "name": g.get("PaymentGatewayName"),
                "status": g.get("Status"),
            }
            for g in gateways
        ],
        "merchants": [
            {
                "id": m.get("Id"),
                "name": m.get("Name"),
                "status": m.get("Status"),
                "paymentStatus": m.get("PaymentStatus"),
            }
            for m in merchants
        ],
        "webStores": [
            {
                "id": s.get("Id"),
                "name": s.get("Name"),
                "guestBrowsing": s.get("OptionsGuestBrowsingEnabled"),
            }
            for s in stores
        ],
        "guestProfile": (
            {
                "userId": guest_user[0]["Id"],
                "profileId": guest_profile_id,
                "permissionSetId": guest_ps_id or None,
                "webStoreRead": webstore_read,
            }
            if guest_user
            else None
        ),
    }


def _guest_err_msg(body: Any) -> str:
    if isinstance(body, list) and body:
        return str(body[0].get("message") or body[0])[:300]
    if isinstance(body, dict):
        return str(body.get("message") or body)[:300]
    return str(body)[:300]


def _http_get_json(url: str, timeout: int = 20) -> tuple[int, Any]:
    import json
    import urllib.error
    import urllib.request

    req = urllib.request.Request(
        url,
        headers={"Accept": "application/json", "User-Agent": "BambooHR-BFF-PayNow/1.0"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", "replace")
            try:
                return resp.status, json.loads(raw) if raw else None
            except json.JSONDecodeError:
                return resp.status, raw
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        try:
            return exc.code, json.loads(raw) if raw else None
        except json.JSONDecodeError:
            return exc.code, raw


# Object Reads the Pay Now guest profile needs for session-context (Phase 0).
PAYNOW_GUEST_OBJECT_READS = (
    "WebStore",
    "ProductCatalog",
    "ProductCategory",
    "Product2",
    "ProductCategoryProduct",
    "ElectronicMediaGroup",
    "Location",
    "WebStoreCatalog",
)


def bootstrap_paynow_guest_access(
    session: OrgSession,
    *,
    dry_run: bool = False,
) -> dict[str, Any]:
    """Enable Guest Browsing + guest profile commerce Reads (Data API safe).

    Does **not** flip Experience Preferences “Allow guest users to access public
    APIs” (UI-only on many orgs).
    """
    actions: list[dict[str, Any]] = []
    stores = session.soql(
        "SELECT Id, Name, OptionsGuestBrowsingEnabled FROM WebStore "
        "WHERE Name LIKE '%Pay%' LIMIT 20"
    )
    targets = [
        s
        for s in stores
        if "pay" in (s.get("Name") or "").lower()
    ] or stores
    for store in targets:
        needed = not bool(store.get("OptionsGuestBrowsingEnabled"))
        actions.append(
            {
                "action": "enableGuestBrowsing",
                "webStoreId": store["Id"],
                "name": store.get("Name"),
                "needed": needed,
                "applied": False,
            }
        )
        if needed and not dry_run:
            session.patch(
                "WebStore",
                store["Id"],
                {"OptionsGuestBrowsingEnabled": True},
            )
            actions[-1]["applied"] = True

    guest_user = session.soql(
        "SELECT Id, ProfileId FROM User "
        "WHERE Profile.Name = 'Pay Now Profile' AND IsActive = true LIMIT 1"
    )
    perm_results: list[dict[str, Any]] = []
    if guest_user:
        profile_id = guest_user[0]["ProfileId"]
        ps_rows = session.soql(
            f"SELECT Id FROM PermissionSet WHERE ProfileId = '{profile_id}' LIMIT 1"
        )
        if ps_rows:
            ps_id = ps_rows[0]["Id"]
            existing = {
                r["SobjectType"]: r
                for r in session.soql(
                    "SELECT Id, SobjectType, PermissionsRead FROM ObjectPermissions "
                    f"WHERE ParentId = '{ps_id}' AND SobjectType IN ("
                    + ",".join(f"'{o}'" for o in PAYNOW_GUEST_OBJECT_READS)
                    + ")"
                )
            }
            for obj in PAYNOW_GUEST_OBJECT_READS:
                row = existing.get(obj)
                if row and row.get("PermissionsRead"):
                    perm_results.append(
                        {"object": obj, "needed": False, "applied": False, "status": "ok"}
                    )
                    continue
                entry: dict[str, Any] = {
                    "object": obj,
                    "needed": True,
                    "applied": False,
                    "status": "pending",
                }
                if not dry_run:
                    try:
                        session.create(
                            "ObjectPermissions",
                            {
                                "ParentId": ps_id,
                                "SobjectType": obj,
                                "PermissionsRead": True,
                                "PermissionsCreate": False,
                                "PermissionsEdit": False,
                                "PermissionsDelete": False,
                                "PermissionsViewAllRecords": False,
                                "PermissionsModifyAllRecords": False,
                            },
                        )
                        entry["applied"] = True
                        entry["status"] = "created"
                    except Exception as exc:  # noqa: BLE001
                        entry["status"] = f"error: {exc}"[:240]
                perm_results.append(entry)
        else:
            perm_results.append(
                {
                    "object": "*",
                    "needed": True,
                    "applied": False,
                    "status": "Pay Now Profile PermissionSet not found",
                }
            )
    else:
        perm_results.append(
            {
                "object": "*",
                "needed": True,
                "applied": False,
                "status": "Pay Now Profile guest user not found",
            }
        )

    return {
        "dryRun": dry_run,
        "webStores": actions,
        "objectPermissions": perm_results,
        "manualStillRequired": [
            "Experience Builder / Workspaces → Pay Now → Administration → Preferences → "
            "Allow guest users to access public APIs → Save (Publish if prompted)",
            "Payments setup → Pay Now site URL points at /paynow (not the webhook site)",
            "Stripe Test merchant Complete + Card Payment Method Set",
        ],
    }


def _lex_url(session: OrgSession, entity: str, record_id: str) -> str:
    base = (session._instance or "").rstrip("/")
    return f"{base}/lightning/r/{entity}/{record_id}/view" if record_id else ""


def _billing_schedules_for_order(
    session: OrgSession, order_id: str
) -> list[dict[str, Any]]:
    return session.soql(
        "SELECT Id, Status, NextBillingDate FROM BillingSchedule "
        f"WHERE ReferenceEntityId = '{order_id}' "
        "ORDER BY NextBillingDate ASC NULLS LAST"
    )


def _earliest_next_billing_date(schedules: list[dict[str, Any]]) -> date | None:
    dates: list[date] = []
    for row in schedules:
        raw = row.get("NextBillingDate")
        if not raw:
            continue
        if isinstance(raw, str):
            dates.append(date.fromisoformat(raw[:10]))
        elif isinstance(raw, date):
            dates.append(raw)
    return min(dates) if dates else None


def _find_invoice_for_account(
    session: OrgSession,
    account_id: str,
    *,
    since: datetime | None = None,
) -> dict[str, Any] | None:
    """Best-effort invoice lookup (ReferenceEntityId is often null after generate)."""
    clause = f"BillingAccountId = '{account_id}' AND Status = 'Posted' AND Balance > 0"
    if since is not None:
        stamp = since.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000+0000")
        clause += f" AND CreatedDate >= {stamp}"
    rows = session.soql(
        "SELECT Id, InvoiceNumber, Status, Balance, TotalAmountWithTax, "
        "BillingAccountId, CreatedDate "
        f"FROM Invoice WHERE {clause} "
        "ORDER BY CreatedDate DESC LIMIT 5"
    )
    return rows[0] if rows else None


def generate_invoice_for_order(
    session: OrgSession,
    order_id: str,
    *,
    action: str = "Posted",
    poll_timeout: int = 90,
) -> dict[str, Any] | None:
    """Invoice the order via Billing Business API; poll for a Posted invoice.

    Uses ``targetDate`` = max(today, earliest NextBillingDate) so future-dated
    BambooHR amend starts still invoice when schedules exist.
    """
    order_rows = session.soql(
        f"SELECT Id, AccountId FROM Order WHERE Id = '{order_id}'"
    )
    if not order_rows:
        raise RuntimeError(f"Order {order_id} not found")
    account_id = order_rows[0].get("AccountId")
    if not account_id:
        raise RuntimeError(f"Order {order_id} has no AccountId")

    schedules = _billing_schedules_for_order(session, order_id)
    if not schedules:
        # Activation → BSG can lag a few seconds
        deadline = time.time() + 30
        while time.time() < deadline and not schedules:
            time.sleep(2)
            schedules = _billing_schedules_for_order(session, order_id)
    if not schedules:
        raise RuntimeError(
            f"Order {order_id} has no BillingSchedule records — "
            "Billing may not be configured for these products"
        )

    today = date.today()
    next_bill = _earliest_next_billing_date(schedules) or today
    target = max(today, next_bill)
    target_s = target.isoformat()
    started = datetime.now(timezone.utc) - timedelta(seconds=5)

    body = {
        "billingTransactionId": order_id,
        "action": action,
        "invoiceDate": target_s,
        "targetDate": target_s,
        "correlationId": f"bh-pay-{uuid.uuid4().hex[:12]}",
    }
    result = session.post(
        f"/services/data/{API}/commerce/invoicing/invoices/collection/actions/generate",
        body,
    )
    if isinstance(result, list):
        # Error array shape
        err = result[0] if result else {}
        raise RuntimeError(
            f"Invoice generate failed: {err.get('message') or err}"
        )
    if isinstance(result, dict) and result.get("success") is False:
        raise RuntimeError(f"Invoice generate failed: {result.get('errors')}")

    deadline = time.time() + poll_timeout
    while time.time() < deadline:
        inv = _find_invoice_for_account(session, account_id, since=started)
        if inv:
            return inv
        time.sleep(2)
    # Last chance without CreatedDate filter (async lag)
    return _find_invoice_for_account(session, account_id)


def _default_payment_method_set_id(session: OrgSession) -> str | None:
    """First MerchAccPaymentMethodSet on an enabled Test/Complete merchant."""
    rows = session.soql(
        "SELECT Id, MerchantAccountId, DeveloperName "
        "FROM MerchAccPaymentMethodSet "
        "ORDER BY CreatedDate ASC LIMIT 5"
    )
    return rows[0]["Id"] if rows else None


def _find_active_payment_link(
    session: OrgSession,
    *,
    account_id: str,
    amount: float,
    title_hint: str | None = None,
) -> dict[str, Any] | None:
    """Reuse an Active SingleUse link for the same account + amount when present."""
    amt = round(float(amount), 2)
    rows = session.soql(
        "SELECT Id, PaymentLinkNumber, PaymentUrl, Status, Amount, Title "
        "FROM PaymentLink "
        f"WHERE AccountId = '{account_id}' AND Status = 'Active' "
        f"AND Amount = {amt} "
        "ORDER BY CreatedDate DESC LIMIT 10"
    )
    if not rows:
        return None
    if title_hint:
        hint = title_hint[:40]
        for row in rows:
            if hint and hint in (row.get("Title") or ""):
                return row
    return rows[0]


def _create_payment_link(
    session: OrgSession,
    *,
    account_id: str,
    amount: float,
    title: str,
    reuse_active: bool = True,
) -> dict[str, Any]:
    """Create a PredefinedAmount Pay Now link; raises with Setup guidance on failure."""
    if reuse_active:
        existing = _find_active_payment_link(
            session,
            account_id=account_id,
            amount=amount,
            title_hint=title,
        )
        if existing and existing.get("PaymentUrl"):
            return existing

    expiry = (datetime.now(timezone.utc) + timedelta(days=7)).strftime(
        "%Y-%m-%dT%H:%M:%S.000Z"
    )
    method_set_id = _default_payment_method_set_id(session)
    if not method_set_id:
        raise RuntimeError(
            "No MerchAccPaymentMethodSet found — add a Card payment method "
            "set on the Stripe merchant account in Payments Setup"
        )
    fields: dict[str, Any] = {
        "Amount": round(float(amount), 2),
        "AccountId": account_id,
        "Status": "Active",
        "Type": "PredefinedAmount",
        "UsageType": "SingleUse",
        "IsBusinessAccountPayment": True,
        "Title": title[:80],
        "ExpiryTime": expiry,
        "Description": "BambooHR Get Pricing checkout",
        "PaymentMethodSetId": method_set_id,
    }
    link_id = session.create("PaymentLink", fields)
    rows = session.soql(
        f"SELECT Id, PaymentLinkNumber, PaymentUrl, Status, Amount "
        f"FROM PaymentLink WHERE Id = '{link_id}'"
    )
    if not rows:
        raise RuntimeError(f"PaymentLink {link_id} created but not readable")
    return rows[0]


def list_open_invoices(
    session: OrgSession,
    account_id: str,
    *,
    limit: int = 20,
) -> list[dict[str, Any]]:
    """Posted invoices with remaining balance for an Account (buyer Licenses UI)."""
    if not account_id:
        return []
    lim = max(1, min(int(limit), 50))
    rows = session.soql(
        "SELECT Id, InvoiceNumber, DocumentNumber, Status, Balance, "
        "TotalAmountWithTax, BillingAccountId, ReferenceEntityId, CreatedDate "
        f"FROM Invoice WHERE BillingAccountId = '{account_id}' "
        "AND Status = 'Posted' AND Balance > 0 "
        f"ORDER BY CreatedDate DESC LIMIT {lim}"
    )
    out: list[dict[str, Any]] = []
    for row in rows:
        inv_id = row["Id"]
        number = row.get("InvoiceNumber") or row.get("DocumentNumber") or inv_id
        balance = float(row.get("Balance") or 0)
        active = _find_active_payment_link(
            session,
            account_id=account_id,
            amount=balance,
            title_hint=f"Pay invoice {number}",
        )
        out.append(
            {
                "id": inv_id,
                "invoiceNumber": number,
                "documentNumber": row.get("DocumentNumber"),
                "status": row.get("Status"),
                "balance": balance,
                "totalAmountWithTax": row.get("TotalAmountWithTax"),
                "referenceEntityId": row.get("ReferenceEntityId"),
                "createdDate": row.get("CreatedDate"),
                "invoiceUrl": _lex_url(session, "Invoice", inv_id),
                "paymentLinkId": (active or {}).get("Id"),
                "paymentUrl": (active or {}).get("PaymentUrl"),
            }
        )
    return out


def build_payment_prompt_for_invoice(
    session: OrgSession,
    invoice_id: str,
) -> PaymentPrompt:
    """Create/reuse a Pay Now link for an existing Posted invoice."""
    warnings: list[str] = []
    inv_id = (invoice_id or "").strip()
    if not inv_id:
        return PaymentPrompt(
            ready=False,
            blocked_reason="invoiceId is required",
        )

    rows = session.soql(
        "SELECT Id, InvoiceNumber, DocumentNumber, Status, Balance, "
        "BillingAccountId, ReferenceEntityId "
        f"FROM Invoice WHERE Id = '{inv_id}' LIMIT 1"
    )
    if not rows:
        return PaymentPrompt(
            ready=False,
            blocked_reason=f"Invoice {inv_id} not found",
        )
    invoice = rows[0]
    account_id = invoice.get("BillingAccountId") or ""
    number = invoice.get("InvoiceNumber") or invoice.get("DocumentNumber") or inv_id
    balance = float(invoice.get("Balance") or 0)
    ref = invoice.get("ReferenceEntityId") or ""
    order_id = ref if str(ref).startswith("801") else ""

    prompt = PaymentPrompt(
        ready=False,
        order_id=order_id,
        invoice_id=inv_id,
        invoice_number=number,
        invoice_balance=balance,
        invoice_url=_lex_url(session, "Invoice", inv_id),
        warnings=warnings,
    )

    if (invoice.get("Status") or "") != "Posted":
        prompt.blocked_reason = (
            f"Invoice status is {invoice.get('Status')!r} — only Posted invoices "
            "can be collected via Pay Now"
        )
        return prompt
    if balance <= 0:
        prompt.blocked_reason = "Invoice balance is zero — nothing to collect"
        return prompt
    if not account_id:
        prompt.blocked_reason = "Invoice has no BillingAccountId"
        return prompt

    readiness = payments_readiness(session)
    if not readiness["paymentsWebhookLive"]:
        warnings.append("Payments Webhook Experience Cloud site is not Live")
        prompt.warnings = warnings
    if readiness["merchantAccountCount"] == 0:
        prompt.blocked_reason = (
            "No MerchantAccount in this org. Complete Salesforce Payments "
            "guided setup (Stripe/Adyen), set the Pay Now site URL, then retry."
        )
        return prompt

    try:
        link = _create_payment_link(
            session,
            account_id=account_id,
            amount=balance,
            title=f"Pay invoice {number}",
        )
    except Exception as exc:  # noqa: BLE001
        msg = str(exc)
        if "Pay Now site URL" in msg:
            prompt.blocked_reason = (
                "Enter the Pay Now site URL in Payments setup, then retry. "
                f"({msg[:300]})"
            )
        elif "Payment Method Set" in msg:
            prompt.blocked_reason = (
                "Payment Method Set missing — finish merchant setup in "
                f"Salesforce Payments. ({msg[:300]})"
            )
        else:
            prompt.blocked_reason = f"PaymentLink create failed: {msg[:500]}"
        return prompt

    url = link.get("PaymentUrl")
    prompt.payment_link_id = link.get("Id")
    prompt.payment_url = url
    prompt.ready = bool(url)
    if not url:
        prompt.blocked_reason = (
            "PaymentLink created but PaymentUrl is empty — check Pay Now site URL"
        )
    return prompt


def build_payment_prompt(
    session: OrgSession,
    order_id: str,
    *,
    collect: bool = True,
    poll_timeout: int = 90,
) -> PaymentPrompt:
    """After order activate: invoice + Pay Now URL when org is configured."""
    warnings: list[str] = []
    if not collect:
        return PaymentPrompt(
            ready=False,
            order_id=order_id,
            blocked_reason="collectPayment disabled for this checkout",
        )

    readiness = payments_readiness(session)
    if not readiness["paymentsWebhookLive"]:
        warnings.append("Payments Webhook Experience Cloud site is not Live")

    try:
        invoice = generate_invoice_for_order(
            session, order_id, poll_timeout=poll_timeout
        )
    except Exception as exc:  # noqa: BLE001
        return PaymentPrompt(
            ready=False,
            order_id=order_id,
            blocked_reason=f"Could not generate invoice: {exc}",
            warnings=warnings,
        )

    if not invoice:
        return PaymentPrompt(
            ready=False,
            order_id=order_id,
            blocked_reason=(
                "Invoice generate accepted but no Posted Invoice appeared "
                "within the poll window"
            ),
            warnings=warnings,
        )

    inv_id = invoice["Id"]
    balance = float(invoice.get("Balance") or 0)
    prompt = PaymentPrompt(
        ready=False,
        order_id=order_id,
        invoice_id=inv_id,
        invoice_number=invoice.get("InvoiceNumber"),
        invoice_balance=balance,
        invoice_url=_lex_url(session, "Invoice", inv_id),
        warnings=warnings,
    )

    if balance <= 0:
        prompt.blocked_reason = "Invoice balance is zero — nothing to collect"
        return prompt

    if readiness["merchantAccountCount"] == 0:
        prompt.blocked_reason = (
            "No MerchantAccount in this org. Complete Salesforce Payments "
            "guided setup (Stripe/Adyen), set the Pay Now site URL, then retry."
        )
        return prompt

    order_rows = session.soql(
        f"SELECT AccountId, OrderNumber FROM Order WHERE Id = '{order_id}'"
    )
    account_id = (order_rows[0].get("AccountId") if order_rows else None) or ""
    order_number = (order_rows[0].get("OrderNumber") if order_rows else None) or order_id
    try:
        link = _create_payment_link(
            session,
            account_id=account_id,
            amount=balance,
            title=f"Pay invoice {prompt.invoice_number or ''} ({order_number})",
        )
    except Exception as exc:  # noqa: BLE001
        msg = str(exc)
        if "Pay Now site URL" in msg:
            prompt.blocked_reason = (
                "Enter the Pay Now site URL in Payments setup, then retry. "
                f"({msg[:300]})"
            )
        elif "Payment Method Set" in msg:
            prompt.blocked_reason = (
                "Payment Method Set missing — finish merchant setup in "
                f"Salesforce Payments. ({msg[:300]})"
            )
        else:
            prompt.blocked_reason = f"PaymentLink create failed: {msg[:500]}"
        return prompt

    url = link.get("PaymentUrl")
    prompt.payment_link_id = link.get("Id")
    prompt.payment_url = url
    prompt.ready = bool(url)
    if not url:
        prompt.blocked_reason = (
            "PaymentLink created but PaymentUrl is empty — check Pay Now site URL"
        )
    return prompt
