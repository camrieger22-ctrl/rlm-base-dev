"""Generate a Quote PDF via OmniStudio DocumentGenerationProcess (DGP).

Uses the Bamboo-branded ``RLM_Bamboo_QuoteProposal`` template by default
(same Extract/Transform ODTs as Foundations ``RLM_QuoteProposal``). Override with
``DOCGEN_TEMPLATE_NAME`` or the API ``templateName`` field. Secrets stay on the
BFF — the browser downloads through ``GET /api/docgen-pdf/<contentVersionId>``.
"""

from __future__ import annotations

import json
import re
import time
from dataclasses import dataclass
from typing import Any

from service import API, OrgSession

DEFAULT_TEMPLATE = "RLM_Bamboo_QuoteProposal"


@dataclass
class DocgenPdfResult:
    ok: bool
    quote_id: str
    template_id: str = ""
    template_name: str = DEFAULT_TEMPLATE
    dgp_id: str = ""
    status: str = ""
    content_version_id: str = ""
    content_document_id: str = ""
    title: str = ""
    file_extension: str = ""
    download_path: str = ""
    error: str = ""
    response_text: str = ""

    def as_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "quoteId": self.quote_id,
            "templateId": self.template_id,
            "templateName": self.template_name,
            "dgpId": self.dgp_id,
            "status": self.status,
            "contentVersionId": self.content_version_id,
            "contentDocumentId": self.content_document_id,
            "title": self.title,
            "fileExtension": self.file_extension,
            "downloadUrl": self.download_path,
            "error": self.error or None,
        }


def _soql_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace("'", "\\'")


def resolve_active_template(session: OrgSession, name: str) -> dict:
    safe = _soql_escape(name)
    rows = session.soql(
        "SELECT Id, Name, TokenMappingMethodType, VersionNumber, Status "
        f"FROM DocumentTemplate WHERE Name = '{safe}' AND Status = 'Active' "
        "ORDER BY VersionNumber DESC LIMIT 1"
    )
    if not rows:
        raise RuntimeError(f"No Active DocumentTemplate named '{name}'")
    return rows[0]


def resolve_template_content_version(session: OrgSession, template_name: str) -> str | None:
    """Latest ContentVersion for the template binary in the DocGen library."""
    safe = _soql_escape(template_name)
    libs = session.soql(
        "SELECT Id FROM ContentWorkspace "
        "WHERE DeveloperName = 'DocgenDocumentTemplateLibrary' LIMIT 1"
    )
    if not libs:
        return None
    library_id = libs[0]["Id"]
    docs = session.soql(
        "SELECT Id FROM ContentDocument "
        f"WHERE Title = '{safe}' "
        "AND Id IN (SELECT ContentDocumentId FROM ContentWorkspaceDoc "
        f"WHERE ContentWorkspaceId = '{library_id}') "
        "ORDER BY CreatedDate DESC LIMIT 1"
    )
    if not docs:
        return None
    versions = session.soql(
        "SELECT Id FROM ContentVersion "
        f"WHERE ContentDocumentId = '{docs[0]['Id']}' "
        "ORDER BY VersionNumber DESC LIMIT 1"
    )
    return versions[0]["Id"] if versions else None


def _parse_content_version_ids(response_text: str | None) -> list[str]:
    if not response_text:
        return []
    try:
        data = json.loads(response_text)
        if isinstance(data, dict):
            for key in ("contentVersionIds", "contentVersions", "ids"):
                if isinstance(data.get(key), list):
                    return [str(x) for x in data[key]]
            if data.get("id"):
                return [str(data["id"])]
        if isinstance(data, list):
            out: list[str] = []
            for item in data:
                if isinstance(item, str):
                    out.append(item)
                elif isinstance(item, dict) and item.get("id"):
                    out.append(str(item["id"]))
            return out
    except (json.JSONDecodeError, TypeError, ValueError):
        pass
    return [s.strip() for s in response_text.split(",") if s.strip()]


def _pick_pdf_version(session: OrgSession, version_ids: list[str]) -> dict | None:
    """Prefer a PDF ContentVersion; fall back to the last ID (convert order)."""
    pdf_candidate = None
    last = None
    for vid in version_ids:
        if not vid.startswith("068"):
            continue
        rows = session.soql(
            "SELECT Id, ContentDocumentId, Title, FileExtension, FileType "
            f"FROM ContentVersion WHERE Id = '{_soql_escape(vid)}' LIMIT 1"
        )
        if not rows:
            continue
        last = rows[0]
        ext = (rows[0].get("FileExtension") or "").lower()
        ftype = (rows[0].get("FileType") or "").lower()
        if ext == "pdf" or ftype == "pdf":
            pdf_candidate = rows[0]
    return pdf_candidate or last


def generate_quote_pdf(
    session: OrgSession,
    quote_id: str,
    *,
    template_name: str = DEFAULT_TEMPLATE,
    title: str | None = None,
    timeout: int = 180,
) -> DocgenPdfResult:
    quote_id = (quote_id or "").strip()
    if not quote_id.startswith("0Q0"):
        return DocgenPdfResult(
            ok=False, quote_id=quote_id, error="quoteId must be a Quote Id (0Q0…)"
        )

    try:
        template = resolve_active_template(session, template_name)
    except Exception as exc:  # noqa: BLE001
        return DocgenPdfResult(
            ok=False, quote_id=quote_id, template_name=template_name, error=str(exc)
        )

    template_id = template["Id"]
    mapping = template.get("TokenMappingMethodType") or "OmniDataTransform"
    # ASCII hyphen only — Unicode em-dash breaks latin-1 Content-Disposition.
    doc_title = title or f"BambooHR Pricing - {quote_id}"

    request_text: dict[str, Any] = {
        "keepIntermediate": True,
        "title": doc_title,
    }
    cv_template = resolve_template_content_version(session, template_name)
    if not cv_template:
        return DocgenPdfResult(
            ok=False,
            quote_id=quote_id,
            template_id=template_id,
            template_name=template_name,
            error=(
                f"No ContentVersion for template {template_name!r} in "
                "DocgenDocumentTemplateLibrary — upload the .docx binary first."
            ),
        )
    request_text["templateContentVersionId"] = cv_template

    body: dict[str, Any] = {
        "Type": "GenerateAndConvert",
        "ReferenceObject": quote_id,
        "DocumentTemplateId": template_id,
        "DocumentInputType": "DocumentTemplate",
        "RequestText": json.dumps(request_text, separators=(",", ":")),
    }
    if mapping == "ContextService":
        body["DocGenAdditionalInputType"] = "ContextService"
        body["DocGenAdditionalInput"] = json.dumps(
            {"inputData": {"Quote": {"id": quote_id}}}
        )
    else:
        body["DataRaptorInput"] = json.dumps({"Id": quote_id})

    try:
        created = session.post(
            f"/services/data/{API}/sobjects/DocumentGenerationProcess", body
        )
    except Exception as exc:  # noqa: BLE001
        return DocgenPdfResult(
            ok=False,
            quote_id=quote_id,
            template_id=template_id,
            template_name=template_name,
            error=f"Create DGP failed: {exc}",
        )

    dgp_id = created.get("id") if isinstance(created, dict) else None
    if not dgp_id:
        return DocgenPdfResult(
            ok=False,
            quote_id=quote_id,
            template_id=template_id,
            template_name=template_name,
            error=f"Create DGP returned no id: {created}",
        )

    deadline = time.time() + timeout
    status = ""
    response_text = ""
    while time.time() < deadline:
        rows = session.soql(
            "SELECT Id, Status, ResponseText FROM DocumentGenerationProcess "
            f"WHERE Id = '{_soql_escape(dgp_id)}'"
        )
        if not rows:
            time.sleep(2)
            continue
        status = rows[0].get("Status") or ""
        response_text = rows[0].get("ResponseText") or ""
        if status in ("Completed", "Success", "Failed", "Failure", "Error"):
            break
        time.sleep(2)
    else:
        return DocgenPdfResult(
            ok=False,
            quote_id=quote_id,
            template_id=template_id,
            template_name=template_name,
            dgp_id=dgp_id,
            status=status or "Timeout",
            error=f"Timed out after {timeout}s waiting for DGP",
            response_text=response_text,
        )

    if status not in ("Completed", "Success"):
        return DocgenPdfResult(
            ok=False,
            quote_id=quote_id,
            template_id=template_id,
            template_name=template_name,
            dgp_id=dgp_id,
            status=status,
            error=f"Document generation {status}: {response_text[:800]}",
            response_text=response_text,
        )

    version_ids = _parse_content_version_ids(response_text)
    picked = _pick_pdf_version(session, version_ids)
    if not picked:
        return DocgenPdfResult(
            ok=False,
            quote_id=quote_id,
            template_id=template_id,
            template_name=template_name,
            dgp_id=dgp_id,
            status=status,
            error=f"No ContentVersion in ResponseText: {response_text[:500]}",
            response_text=response_text,
        )

    cv_id = picked["Id"]
    return DocgenPdfResult(
        ok=True,
        quote_id=quote_id,
        template_id=template_id,
        template_name=template_name,
        dgp_id=dgp_id,
        status=status,
        content_version_id=cv_id,
        content_document_id=picked.get("ContentDocumentId") or "",
        title=picked.get("Title") or doc_title,
        file_extension=(picked.get("FileExtension") or "pdf").lower(),
        download_path=f"/api/docgen-pdf/{cv_id}",
        response_text=response_text,
    )


def _safe_download_filename(title: str, ext: str) -> str:
    """ASCII-only filename for Content-Disposition (latin-1 HTTP headers).

    DocGen titles often include Unicode (e.g. em-dash). BaseHTTPRequestHandler
    encodes headers as latin-1; a UnicodeEncodeError mid-response corrupts the
    download into a broken 200/404 mix the browser surfaces as a PDF error.
    """
    base = (title or "document").strip()
    if base.lower().endswith(f".{ext}"):
        base = base[: -(len(ext) + 1)]
    # Common typography → ASCII, then strip anything else non-ASCII.
    for src, dst in (
        ("\u2014", "-"),  # —
        ("\u2013", "-"),  # –
        ("\u2018", "'"),
        ("\u2019", "'"),
        ("\u201c", '"'),
        ("\u201d", '"'),
    ):
        base = base.replace(src, dst)
    base = base.encode("ascii", "replace").decode("ascii").replace("?", "")
    base = re.sub(r'[\\/:*?"<>|\r\n]+', "-", base)
    base = re.sub(r"\s+", " ", base).strip(" .-_") or "document"
    return f"{base}.{ext}"


def download_content_version(session: OrgSession, content_version_id: str) -> tuple[bytes, str, str]:
    """Return (bytes, filename, content_type) for a ContentVersion Id."""
    cv_id = (content_version_id or "").strip()
    if not cv_id.startswith("068"):
        raise ValueError("contentVersionId must be a ContentVersion Id (068…)")
    meta = session.soql(
        "SELECT Id, Title, FileExtension FROM ContentVersion "
        f"WHERE Id = '{_soql_escape(cv_id)}' LIMIT 1"
    )
    if not meta:
        raise RuntimeError(f"ContentVersion {cv_id} not found")
    title = meta[0].get("Title") or "document"
    ext = (meta[0].get("FileExtension") or "bin").lower()
    raw = session.get_bytes(
        f"/services/data/{API}/sobjects/ContentVersion/{cv_id}/VersionData"
    )
    ctype = "application/pdf" if ext == "pdf" else "application/octet-stream"
    filename = _safe_download_filename(title, ext)
    return raw, filename, ctype
