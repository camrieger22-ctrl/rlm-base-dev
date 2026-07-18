#!/usr/bin/env python3
"""Generate datasets/sfdmu/kld/en-US/kld-pcm CSV content from the approved product map."""

from __future__ import annotations

import csv
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAN = ROOT / "datasets/sfdmu/kld/en-US/kld-pcm"


def write_csv(name: str, header: list[str], rows: list[list]) -> None:
    path = PLAN / name
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(header)
        writer.writerows(rows)


# --- Product definitions ---
# (sku, name, family, type, classification, uom, description)
PRODUCTS = [
    # Pathway shell — Nebula ECA → RelOne only (customer demo scope).
    ("KLD-PATH-NEB-R1", "Nebula ECA to RelOne", "Bundle", "Bundle", "PC-KLD-PATHWAY", "",
     "Matter pathway shell: Nebula ECA with promotion to RelativityOne Review, including staging, RelOne extenders, eDiscovery AI, professional services, and media."),
    # Setup / staging / hosting
    ("KLD-SETUP-MATTER-GB", "Transactional Matter Set Up Fee", "Services", "", "PC-KLD-SETUP", "GB",
     "Per-GB transactional matter setup fee applied at matter initiation."),
    ("KLD-STAGING", "Staging", "Services", "", "PC-KLD-HOST", "GB",
     "One-time per GB fee for project staging of source data prior to ECA/processing."),
    ("KLD-NEB-ECA-HOST", "Nebula ECA Hosting", "Software", "", "PC-KLD-HOST", "GB-MO",
     "Nebula Processing/Early Case Assessment repository hosting providing access to processed data for filtering before promotion to Review. Supports up to 10 concurrent users per repository; accommodates datasets up to 50 million documents; allows 10,000 unique document views per month."),
    ("KLD-R1-REVIEW", "RelOne Review", "Software", "", "PC-KLD-HOST", "GB-MO",
     "Includes promotion of identified files from the underlying Processing/ECA repository, hosting, and analytics for data promoted to active RelativityOne Review. User license and unlimited analytics are included."),
    ("KLD-R1-COLD", "Cold Storage - No Access", "Software", "", "PC-KLD-HOST", "GB-MO",
     "Long-term archival storage tier for inactive RelativityOne workspaces with no user access while data remains retained."),
    # Forensics & collection
    ("KLD-FOR-COLL", "Forensic Data Collection", "Services", "", "PC-KLD-FORENS", "h",
     "Time for onsite forensic collection of computers, servers, mobile devices, and external media."),
    ("KLD-FOR-RCOLL", "Remote Forensic Data Collection", "Services", "", "PC-KLD-FORENS", "h",
     "Lab-based remote forensic collection, including sources such as Microsoft 365, social media, and webmail."),
    ("KLD-FOR-DOWNTIME", "Forensic Data Collection - Downtime", "Services", "", "PC-KLD-FORENS", "h",
     "Onsite downtime caused by the client during forensic collection, billed at 50% of the applicable forensic hourly rate."),
    ("KLD-RMDC-HR", "RMDC - Remote Mobile Device Collection (Hourly)", "Services", "", "PC-KLD-FORENS", "h",
     "Remote mobile device collection billed hourly, including a 2-hour minimum."),
    ("KLD-RMDC-FLAT", "RMDC - Remote Mobile Device Collection (Flat)", "Services", "", "PC-KLD-FORENS", "EACH",
     "Flat-fee remote mobile device collection package including imaging, media, and shipping."),
    ("KLD-RCMGR-PC", "RCMgr Self Collection Computer", "Services", "", "PC-KLD-FORENS", "EACH",
     "RCMgr self-collection kit for computers, including drive image and shipping."),
    ("KLD-RCMGR-SRV", "RCMgr Self Collection Server", "Services", "", "PC-KLD-FORENS", "EACH",
     "RCMgr self-collection kit for servers, including drive image and shipping."),
    ("KLD-RCMGR-DECRYPT", "RCMgr Drive Decryption", "Services", "", "PC-KLD-FORENS", "EACH",
     "Decryption fee for native delivery of collected data. Fee is waived when data is processed by KLDiscovery."),
    ("KLD-FOR-ANALYSIS", "Forensic Analysis", "Services", "", "PC-KLD-FORENS", "h",
     "In-lab computer forensic analysis including preservation, recovery, listings, and related deliverables."),
    ("KLD-TRAVEL-TIME", "Travel Time", "Services", "", "PC-KLD-FORENS", "h",
     "Travel time billed at 50% of the applicable service hourly rate (capped at $1,000 per day)."),
    ("KLD-TRAVEL-EXP", "Travel Expense", "Services", "", "PC-KLD-FORENS", "USD",
     "Travel-related expenses (hotel, meals, etc.) billed at actual cost."),
    # eDiscovery AI
    ("KLD-AI-ECI-CORE", "eDiscovery AI - Early Case Insight (Core)", "Software", "", "PC-KLD-AI", "DOC-RUN",
     "Advanced analytics, AI, and GenAI for deep insight into target data sets during Early Case Assessment (ECA), supporting intelligent data reduction."),
    ("KLD-AI-ECI-ELEMENTS", "eDiscovery AI - Early Case Insight (Case Elements)", "Software", "", "PC-KLD-AI", "DOC-RUN",
     "Identifies Key People, Key Events, and Key Documents within the target data set. Prerequisite: ECI Core."),
    ("KLD-AI-CASEBOT", "eDiscovery AI - Early Case Bot (CaseBot)", "Software", "", "PC-KLD-AI", "DOC-QTR",
     "Natural-language chatbot for questioning ECI Core data. Billed per document every 3 months; includes unlimited queries against the ECI Core data set."),
    ("KLD-AI-RELEVANCE", "eDiscovery AI - Relevance", "Software", "", "PC-KLD-AI", "DOC-RUN",
     "Identifies highly relevant documents using advanced analytics and GenAI. Pricing includes up to 15 prompts per run."),
    ("KLD-AI-PRIVILEGE", "eDiscovery AI - Privilege", "Software", "", "PC-KLD-AI", "DOC-RUN",
     "Privilege detection with pre-built Attorney-Client and Work Product identifiers, plus up to two custom privilege identifiers."),
    ("KLD-AI-PII-DETECT", "eDiscovery AI - PII Detect", "Software", "", "PC-KLD-AI", "DOC",
     "Detects common personally identifiable information (PII) and protected health information (PHI) within the target data set."),
    ("KLD-AI-PII-EXTRACT", "eDiscovery AI - PII Extract", "Software", "", "PC-KLD-AI", "DOC",
     "Extracts identified PII/PHI from target data sets for downstream review or notification workflows."),
    ("KLD-AI-PII-REDACT", "eDiscovery AI - PII Redact", "Software", "", "PC-KLD-AI", "PAGE",
     "AI-driven redaction based on PII Detect results. One document unit is billed per page analyzed."),
    # RelativityOne Extenders (after Online Data Hosting on Nebula→RelOne / RelOne pathways)
    ("KLD-EXT-AIR-REVIEW", "RelativityOne - aiR for Review", "Software", "", "PC-KLD-EXTEND", "DOC",
     "Application of advanced analytics for identification of potentially relevant files. The per-document fee applies to the number of documents in the target data set per prompt."),
    ("KLD-EXT-AIR-PRIV", "RelativityOne - aiR for Privilege", "Software", "", "PC-KLD-EXTEND", "DOC",
     "Application of advanced analytics for identification of potentially privileged files and creation of preliminary privilege logs."),
    ("KLD-EXT-XLAT", "RelativityOne Translate", "Software", "", "PC-KLD-EXTEND", "DOC",
     "Cloud-based machine translation for review documents."),
    ("KLD-EXT-CONTRACTS", "Relativity Contracts", "Software", "", "PC-KLD-EXTEND", "DOC",
     "Relativity Contracts integrated contract review — transform executed agreements into structured, searchable data."),
    ("KLD-EXT-PI-DETECT", "Relativity PI Detect", "Software", "", "PC-KLD-EXTEND", "DOC-RUN",
     "AI-powered identification and redaction of personal information using pre-trained detectors."),
    ("KLD-EXT-BREACH", "Relativity Data Breach Response", "Software", "", "PC-KLD-EXTEND", "GB",
     "AI-powered solution to reduce time, cost, and risk when producing an entity notification list for data breach response."),
    ("KLD-EXT-CASE-STRAT", "Relativity aiR Case Strategy", "Software", "", "PC-KLD-EXTEND", "EACH",
     "AI-driven case strategy workspace to identify key facts, players, and issues. Includes up to 10,000 documents (burst rate $0.30/document over 10K), up to 150 GB of deposition video hosting, and unlimited memos."),
    # Professional services & delivery
    ("KLD-PS-PM", "Project Management", "Services", "", "PC-KLD-PS", "h",
     "Consultative and customized support including ESI analysis, customized processing solutions, document review workflow design, production query design, and quality control customization."),
    ("KLD-PS-TECH", "Technical Support", "Services", "", "PC-KLD-PS", "h",
     "Billable technical operations including processing/loading of third-party data, load-file customization, custom production templates, and review-platform support. Time rounded up to 6-minute (0.1 hour) increments; weekends and holidays billed at the standard flat rate."),
    ("KLD-PS-AA-CONSULT", "Advanced Analytics Consulting", "Services", "", "PC-KLD-PS", "h",
     "Consulting on optimal utilization of TAR, search term/ECA strategy, predictive coding, and review workflow design."),
    ("KLD-PS-CONSULT", "Consulting Services", "Services", "", "PC-KLD-PS", "h",
     "Consulting services including information governance, preservation and collections, discovery readiness, ESI stipulation, early data assessment, predictive coding, and review strategy."),
    ("KLD-PS-EXPERT", "Expert Testimony", "Services", "", "PC-KLD-PS", "h",
     "Expert testimony services including deposition and trial testimony and authoring of expert reports and affidavits."),
    ("KLD-MED-HDD", "Hard Drive", "Services", "", "PC-KLD-MEDIA", "EACH",
     "Hard drive media used for deliverables."),
    ("KLD-MED-FREIGHT", "Freight", "Services", "", "PC-KLD-MEDIA", "USD",
     "Shipping charges billed as incurred (postage, ground courier, FedEx, etc.)."),
]

PATHWAYS = {
    "KLD-PATH-NEB-R1": {
        "eca": "KLD-NEB-ECA-HOST",
        "review": "KLD-R1-REVIEW",
    },
}

AI_SKUS = [
    "KLD-AI-ECI-CORE",
    "KLD-AI-ECI-ELEMENTS",
    "KLD-AI-CASEBOT",
    "KLD-AI-RELEVANCE",
    "KLD-AI-PRIVILEGE",
    "KLD-AI-PII-DETECT",
    "KLD-AI-PII-EXTRACT",
    "KLD-AI-PII-REDACT",
]

FORENSIC_SKUS = [
    "KLD-FOR-COLL",
    "KLD-FOR-RCOLL",
    "KLD-FOR-DOWNTIME",
    "KLD-RMDC-HR",
    "KLD-RMDC-FLAT",
    "KLD-RCMGR-PC",
    "KLD-RCMGR-SRV",
    "KLD-RCMGR-DECRYPT",
    "KLD-FOR-ANALYSIS",
    "KLD-TRAVEL-TIME",
    "KLD-TRAVEL-EXP",
]

PS_SKUS = [
    "KLD-PS-PM",
    "KLD-PS-TECH",
    "KLD-PS-AA-CONSULT",
    "KLD-PS-CONSULT",
    "KLD-PS-EXPERT",
]
MEDIA_SKUS = ["KLD-MED-HDD", "KLD-MED-FREIGHT"]
# Online Data Hosting: RelOne Review + Cold Storage.
REVIEW_EXTRAS = {
    "KLD-PATH-NEB-R1": ["KLD-R1-COLD"],
}

# RelativityOne Extenders (PDF EXTENDERS section) — after Online Data Hosting.
EXTENDER_SKUS = [
    "KLD-EXT-AIR-REVIEW",
    "KLD-EXT-AIR-PRIV",
    "KLD-EXT-XLAT",
    "KLD-EXT-CONTRACTS",
    "KLD-EXT-PI-DETECT",
    "KLD-EXT-BREACH",
    "KLD-EXT-CASE-STRAT",
]

# Pathway component groups — all optional (min=0) so reps can build from blank.
# Sequence matches the Standard Average Estimate / Nebula→RelOne PDF order:
# Forensics → Staging → ECA → Online Data Hosting → Extenders →
# Advanced Analytics → Professional Services → Media.
PATHWAY_SUFFIX = {
    "KLD-PATH-NEB-R1": "NEBR1",
}

# Category mapping: sku -> (catalog, category)
CATEGORY_MAP = {
    "KLD-PATH-NEB-R1": ("CAT-KLD-EDISC", "KLD-CAT-PATHWAY"),
    "KLD-SETUP-MATTER-GB": ("CAT-KLD-EDISC", "KLD-CAT-SETUP"),
    "KLD-STAGING": ("CAT-KLD-EDISC", "KLD-CAT-STAGING"),
    "KLD-NEB-ECA-HOST": ("CAT-KLD-EDISC", "KLD-CAT-ECA"),
    "KLD-R1-REVIEW": ("CAT-KLD-EDISC", "KLD-CAT-REVIEW"),
}
for sku in [
    "KLD-FOR-COLL", "KLD-FOR-RCOLL", "KLD-FOR-DOWNTIME", "KLD-RMDC-HR", "KLD-RMDC-FLAT",
    "KLD-RCMGR-PC", "KLD-RCMGR-SRV", "KLD-RCMGR-DECRYPT", "KLD-FOR-ANALYSIS",
    "KLD-TRAVEL-TIME", "KLD-TRAVEL-EXP",
]:
    CATEGORY_MAP[sku] = ("CAT-KLD-FORENS", "KLD-CAT-COLL" if sku != "KLD-FOR-ANALYSIS" and "TRAVEL" not in sku else (
        "KLD-CAT-ANALYSIS" if sku == "KLD-FOR-ANALYSIS" else "KLD-CAT-TRAVEL"
    ))
CATEGORY_MAP["KLD-FOR-ANALYSIS"] = ("CAT-KLD-FORENS", "KLD-CAT-ANALYSIS")
CATEGORY_MAP["KLD-TRAVEL-TIME"] = ("CAT-KLD-FORENS", "KLD-CAT-TRAVEL")
CATEGORY_MAP["KLD-TRAVEL-EXP"] = ("CAT-KLD-FORENS", "KLD-CAT-TRAVEL")
for sku in AI_SKUS:
    if "ECI" in sku or sku == "KLD-AI-CASEBOT":
        CATEGORY_MAP[sku] = ("CAT-KLD-AI", "KLD-CAT-ECI")
    elif "PII" in sku:
        CATEGORY_MAP[sku] = ("CAT-KLD-AI", "KLD-CAT-PII")
    else:
        CATEGORY_MAP[sku] = ("CAT-KLD-AI", "KLD-CAT-RELEVANCE")
for sku in EXTENDER_SKUS:
    CATEGORY_MAP[sku] = ("CAT-KLD-AI", "KLD-CAT-EXTEND")
CATEGORY_MAP["KLD-PS-PM"] = ("CAT-KLD-PS", "KLD-CAT-PS-CORE")
CATEGORY_MAP["KLD-PS-TECH"] = ("CAT-KLD-PS", "KLD-CAT-PS-CORE")
CATEGORY_MAP["KLD-PS-AA-CONSULT"] = ("CAT-KLD-PS", "KLD-CAT-PS-CORE")
CATEGORY_MAP["KLD-PS-CONSULT"] = ("CAT-KLD-PS", "KLD-CAT-PS-CORE")
CATEGORY_MAP["KLD-PS-EXPERT"] = ("CAT-KLD-PS", "KLD-CAT-PS-CORE")
CATEGORY_MAP["KLD-MED-HDD"] = ("CAT-KLD-MEDIA", "KLD-CAT-DELIVERY")
CATEGORY_MAP["KLD-MED-FREIGHT"] = ("CAT-KLD-MEDIA", "KLD-CAT-DELIVERY")
CATEGORY_MAP["KLD-R1-COLD"] = ("CAT-KLD-EDISC", "KLD-CAT-REVIEW")

HOSTING_SKUS = {
    "KLD-NEB-ECA-HOST", "KLD-R1-REVIEW", "KLD-R1-COLD",
}
ONE_TIME_GB = {"KLD-STAGING", "KLD-SETUP-MATTER-GB"}
CASEBOT = "KLD-AI-CASEBOT"


def product2_rows() -> list[list]:
    rows = []
    for sku, name, family, ptype, based_on, uom, desc in PRODUCTS:
        is_bundle = ptype == "Bundle"
        rows.append([
            based_on,
            "false",
            "Allowed" if is_bundle else "",
            desc,
            "",
            family,
            "true",
            "true",
            "false",
            name,
            sku,
            uom if uom in ("GB", "h") else "",
            "",
            sku,
            ptype,
            uom,
        ])
    return rows


def psmo_rows() -> list[list]:
    rows = []
    for sku, name, family, ptype, _cls, uom, _desc in PRODUCTS:
        if ptype == "Bundle":
            rows.append([f"{sku};One-Time;OneTime", "true", sku, "One-Time;OneTime", ""])
            continue
        if sku in HOSTING_SKUS:
            rows.append([f"{sku};Evergreen Monthly;Evergreen", "true", sku, "Evergreen Monthly;Evergreen", "Default Proration Policy"])
            rows.append([f"{sku};Term Monthly;TermDefined", "false", sku, "Term Monthly;TermDefined", "Default Proration Policy"])
        elif sku == CASEBOT:
            rows.append([f"{sku};Evergreen - Quarterly;Evergreen", "true", sku, "Evergreen - Quarterly;Evergreen", "Default Proration Policy"])
        else:
            rows.append([f"{sku};One-Time;OneTime", "true", sku, "One-Time;OneTime", ""])
    return rows


def component_groups() -> list[list]:
    rows = []
    for path_sku in PATHWAYS:
        sfx = PATHWAY_SUFFIX[path_sku]
        # (code, name, min, max, sequence) — all min=0 (optional sections)
        review_max = 1 + len(REVIEW_EXTRAS.get(path_sku, []))
        groups = [
            (f"KLD-CG-{sfx}-FORENS", "Forensic Collection & Analysis", 0, len(FORENSIC_SKUS), 1),
            (f"KLD-CG-{sfx}-STAGING", "Staging", 0, 1, 2),
            (f"KLD-CG-{sfx}-ECA", "ECA Hosting", 0, 1, 3),
            (f"KLD-CG-{sfx}-REVIEW", "Online Data Hosting", 0, review_max, 4),
            (f"KLD-CG-{sfx}-EXTEND", "Extenders", 0, len(EXTENDER_SKUS), 5),
            (f"KLD-CG-{sfx}-AI", "Advanced Analytics", 0, len(AI_SKUS), 6),
            (f"KLD-CG-{sfx}-PS", "Professional Services", 0, len(PS_SKUS), 7),
            (f"KLD-CG-{sfx}-MEDIA", "Media & Data Delivery", 0, len(MEDIA_SKUS), 8),
        ]
        for code, gname, mn, mx, order in groups:
            rows.append([
                f"{code};{path_sku}",
                code,
                "",
                mx,
                mn,
                gname,
                "",
                path_sku,
                order,
            ])
    return rows


# Demo defaults for Source Data = 1000 GB worked example (Standard Average Estimate).
DEMO_SOURCE_GB = 1000
DEMO_DECOMP_PCT = 50
DEMO_STORAGE_EXP_PCT = 25
DEMO_ECA_PCT = 70
DEMO_REVIEW_PCT = 30
DEMO_DECOMP_GB = DEMO_SOURCE_GB * (100 + DEMO_DECOMP_PCT) // 100  # 1500
DEMO_STORAGE_EXP_GB = DEMO_DECOMP_GB * (100 + DEMO_STORAGE_EXP_PCT) // 100  # 1875
# ECA: round half-up so 1875×70% → 1313 (Standard Average Estimate).
# Review: truncate so 1875×30% → 562 and ECA+Review = Storage Expansion.
DEMO_ECA_GB = (DEMO_STORAGE_EXP_GB * DEMO_ECA_PCT + 50) // 100
DEMO_REVIEW_GB = DEMO_STORAGE_EXP_GB * DEMO_REVIEW_PCT // 100
DEMO_PM_HRS_MO = 11
DEMO_TECH_HRS_MO = 7
DEMO_TERM_MONTHS = 12

# Volume components: Quantity stays 1; Billable_GB / Billable_Hours carry volume (CML).
VOLUME_QTY_LOCKED = {
    "KLD-STAGING",
    "KLD-NEB-ECA-HOST",
    "KLD-R1-REVIEW",
    "KLD-R1-COLD",
    "KLD-PS-PM",
    "KLD-PS-TECH",
}


def related_components() -> list[list]:
    rel = "Bundle to Bundle Component Relationship"
    rows = []
    for path_sku, cfg in PATHWAYS.items():
        sfx = PATHWAY_SUFFIX[path_sku]
        # All children optional. Volume SKUs: qty locked at 1 (attr carries GB/hours).
        review_children = [cfg["review"]] + REVIEW_EXTRAS.get(path_sku, [])
        sections: list[tuple[str, list[str]]] = [
            (f"KLD-CG-{sfx}-FORENS", FORENSIC_SKUS),
            (f"KLD-CG-{sfx}-STAGING", ["KLD-STAGING"]),
            (f"KLD-CG-{sfx}-ECA", [cfg["eca"]]),
            (f"KLD-CG-{sfx}-REVIEW", review_children),
            (f"KLD-CG-{sfx}-EXTEND", EXTENDER_SKUS),
            (f"KLD-CG-{sfx}-AI", AI_SKUS),
            (f"KLD-CG-{sfx}-PS", PS_SKUS),
            (f"KLD-CG-{sfx}-MEDIA", MEDIA_SKUS),
        ]
        seq = 10
        for group, children in sections:
            for child in children:
                locked = child in VOLUME_QTY_LOCKED
                rows.append(prc_row(
                    path_sku, child, group, rel, False, 1, seq,
                    # Platform requires IsQuantityEditable=true to set Min/Max;
                    # Min=Max=1 still locks the line to quantity 1.
                    qty_editable=True,
                    min_qty=1 if locked else "",
                    max_qty=1 if locked else "",
                ))
                seq += 10
    return rows


def prc_row(parent, child, group, rel, required, qty, seq, qty_editable, min_qty="", max_qty=""):
    # Child/Parent selling models intentionally blank: configurable pathway
    # bundles reject ChildSellingModel ("unsupported for configurable product bundles").
    return [
        f";{child};{parent};{group};{rel}",
        child,
        "",
        "BundleComponent",
        "",
        "false",
        "true" if required else "false",
        "false",
        "true" if qty_editable else "false",
        str(max_qty) if max_qty != "" else "",
        str(min_qty) if min_qty != "" else ("1" if required else ""),
        parent,
        "Bundle",
        "",
        group,
        rel,
        str(qty),
        "",
        "Always",
        str(seq),
        "",
    ]


def main() -> None:
    write_csv(
        "UnitOfMeasureClass.csv",
        ["BaseUnitOfMeasure.UnitCode", "Code", "DefaultUnitOfMeasure.UnitCode", "Description", "Name", "Status", "Type"],
        [
            ["EACH", "KLD-COUNT", "EACH", "Count-based units", "KLD Count", "Active", "Usage"],
            ["USD", "CURRENCY", "USD", "", "Currency", "Active", "Currency"],
            ["GB", "DATAVOL", "GB", "Data volume", "Data Volume", "Active", "Usage"],
            ["h", "TIME", "h", "Time-based units", "Time", "Active", "Usage"],
        ],
    )

    write_csv(
        "UnitOfMeasure.csv",
        ["ConversionFactor", "Description", "Name", "RoundingMethod", "Scale", "Sequence", "Status", "Type", "UnitCode", "UnitOfMeasureClass.Code"],
        [
            ["1", "Gigabyte", "Gigabyte", "", "", "1", "Active", "Data", "GB", "DATAVOL"],
            ["1", "Gigabyte per month", "Gigabyte Month", "", "", "2", "Active", "Data", "GB-MO", "DATAVOL"],
            ["1", "Hour", "Hour", "", "", "1", "Active", "Time", "h", "TIME"],
            ["1", "Each", "Each", "", "", "1", "Active", "Count", "EACH", "KLD-COUNT"],
            ["1", "Document", "Document", "", "", "2", "Active", "Count", "DOC", "KLD-COUNT"],
            ["1", "Document per run", "Document Run", "", "", "3", "Active", "Count", "DOC-RUN", "KLD-COUNT"],
            ["1", "Document per quarter", "Document Quarter", "", "", "4", "Active", "Count", "DOC-QTR", "KLD-COUNT"],
            ["1", "Page", "Page", "", "", "5", "Active", "Count", "PAGE", "KLD-COUNT"],
            ["1", "Million characters", "Million Characters", "", "", "6", "Active", "Count", "MCHARS", "KLD-COUNT"],
            ["1", "Transcription hour", "Automated Transcription Hour", "", "", "7", "Active", "Time", "ATRANS-HR", "TIME"],
            ["1", "US Dollar pass-through", "USD", "", "", "1", "Active", "Cost", "USD", "CURRENCY"],
        ],
    )

    classifications = [
        ("PC-KLD-PATHWAY", "KLD Pathway", "Active"),
        ("PC-KLD-HOST", "KLD Hosting", "Active"),
        ("PC-KLD-SETUP", "KLD Setup", "Active"),
        ("PC-KLD-FORENS", "KLD Forensics", "Active"),
        ("PC-KLD-AI", "KLD eDiscovery AI", "Active"),
        ("PC-KLD-EXTEND", "KLD Relativity Extenders", "Active"),
        ("PC-KLD-PS", "KLD Professional Services", "Active"),
        ("PC-KLD-MEDIA", "KLD Media & Delivery", "Active"),
    ]
    write_csv(
        "ProductClassification.csv",
        ["Code", "Name", "ParentProductClassification.Code", "Status"],
        [[c, n, "", s] for c, n, s in classifications],
    )

    write_csv(
        "Product2.csv",
        ["BasedOn.Code", "CanRamp", "ConfigureDuringSale", "Description", "DisplayUrl", "Family", "IsActive", "IsAssetizable", "IsSoldOnlyWithOtherProds", "Name", "ProductCode", "QuantityUnitOfMeasure", "SpecificationType", "StockKeepingUnit", "Type", "UnitOfMeasure.UnitCode"],
        product2_rows(),
    )

    write_csv(
        "ProductSellingModel.csv",
        ["$$Name$SellingModelType", "DoesAutoRenewAssetByDefault", "Name", "PricingTerm", "PricingTermUnit", "SellingModelType", "Status"],
        [
            ["Evergreen - Quarterly;Evergreen", "false", "Evergreen - Quarterly", "1", "Quarterly", "Evergreen", "Active"],
            ["Evergreen Monthly;Evergreen", "false", "Evergreen Monthly", "1", "Months", "Evergreen", "Active"],
            ["One-Time;OneTime", "false", "One-Time", "", "", "OneTime", "Active"],
            ["Term Monthly;TermDefined", "false", "Term Monthly", "1", "Months", "TermDefined", "Active"],
        ],
    )

    write_csv(
        "ProrationPolicy.csv",
        ["ArePartialPeriodsAllowed", "Name", "ProrationPolicyType", "RemainderStrategy"],
        [["true", "Default Proration Policy", "StandardTimePeriods", "AddToLast"]],
    )

    write_csv(
        "ProductSellingModelOption.csv",
        ["$$Product2.StockKeepingUnit$ProductSellingModel.Name$ProductSellingModel.SellingModelType", "IsDefault", "Product2.StockKeepingUnit", "ProductSellingModel.$$Name$SellingModelType", "ProrationPolicy.Name"],
        psmo_rows(),
    )

    write_csv(
        "ProductRelationshipType.csv",
        ["AssociatedProductRoleCat", "MainProductRoleCat", "Name"],
        [["BundleComponent", "Bundle", "Bundle to Bundle Component Relationship"]],
    )

    write_csv(
        "ProductComponentGroup.csv",
        ["$$Code$ParentProduct.StockKeepingUnit", "Code", "Description", "MaxBundleComponents", "MinBundleComponents", "Name", "ParentGroup.Code", "ParentProduct.StockKeepingUnit", "Sequence"],
        component_groups(),
    )

    prc_header = [
        "$$ChildProductClassification.Code$ChildProduct.StockKeepingUnit$ParentProduct.StockKeepingUnit$ProductComponentGroup.Code$ProductRelationshipType.Name",
        "ChildProduct.StockKeepingUnit", "ChildProductClassification.Code", "ChildProductRole",
        "ChildSellingModel.$$Name$SellingModelType", "DoesBundlePriceIncludeChild", "IsComponentRequired",
        "IsDefaultComponent", "IsQuantityEditable", "MaxQuantity", "MinQuantity", "ParentProduct.StockKeepingUnit",
        "ParentProductRole", "ParentSellingModel.$$Name$SellingModelType", "ProductComponentGroup.Code",
        "ProductRelationshipType.Name", "Quantity", "QuantityScaleMethod", "QuoteVisibility", "Sequence",
        "UnitOfMeasure.UnitCode",
    ]
    write_csv("ProductRelatedComponent.csv", prc_header, related_components())

    write_csv(
        "ProductCatalog.csv",
        ["CatalogType", "Code", "Description", "EffectiveEndDate", "EffectiveStartDate", "Name"],
        [
            ["Sales", "CAT-KLD-EDISC", "KLDiscovery eDiscovery hosting and pathways", "", "", "KLDiscovery eDiscovery"],
            ["Sales", "CAT-KLD-AI", "KLDiscovery eDiscovery AI and analytics", "", "", "KLDiscovery AI & Analytics"],
            ["Sales", "CAT-KLD-FORENS", "KLDiscovery forensics and collection", "", "", "KLDiscovery Forensics"],
            ["Sales", "CAT-KLD-PS", "KLDiscovery professional services", "", "", "KLDiscovery Professional Services"],
            ["Sales", "CAT-KLD-MEDIA", "KLDiscovery media and delivery", "", "", "KLDiscovery Media & Delivery"],
        ],
    )

    categories = [
        ("CAT-KLD-EDISC", "KLD-CAT-STAGING", "Staging", "true", 10),
        ("CAT-KLD-EDISC", "KLD-CAT-ECA", "ECA Hosting", "true", 20),
        ("CAT-KLD-EDISC", "KLD-CAT-REVIEW", "Online Data Hosting", "true", 30),
        ("CAT-KLD-EDISC", "KLD-CAT-SETUP", "Matter Setup", "true", 40),
        ("CAT-KLD-EDISC", "KLD-CAT-PATHWAY", "Matter Pathways", "true", 50),
        ("CAT-KLD-AI", "KLD-CAT-ECI", "Early Case Insight", "true", 10),
        ("CAT-KLD-AI", "KLD-CAT-RELEVANCE", "Relevance & Privilege", "true", 20),
        ("CAT-KLD-AI", "KLD-CAT-PII", "PII Services", "true", 30),
        ("CAT-KLD-AI", "KLD-CAT-EXTEND", "Extenders", "true", 40),
        ("CAT-KLD-FORENS", "KLD-CAT-COLL", "Collection", "true", 10),
        ("CAT-KLD-FORENS", "KLD-CAT-ANALYSIS", "Forensic Analysis", "true", 20),
        ("CAT-KLD-FORENS", "KLD-CAT-TRAVEL", "Travel", "true", 30),
        ("CAT-KLD-PS", "KLD-CAT-PS-CORE", "Professional Services", "true", 10),
        ("CAT-KLD-MEDIA", "KLD-CAT-DELIVERY", "Media & Delivery", "true", 10),
    ]
    write_csv(
        "ProductCategory.csv",
        ["Catalog.Code", "Code", "Description", "IsNavigational", "Name", "ParentCategory.Code", "SortOrder"],
        [[c, code, "", nav, name, "", sort] for c, code, name, nav, sort in categories],
    )

    cat_prod_rows = []
    for sku in [p[0] for p in PRODUCTS]:
        cat, cat_code = CATEGORY_MAP[sku]
        cat_prod_rows.append([f"{cat_code};{sku}", cat, "true", sku, cat_code])
    write_csv(
        "ProductCategoryProduct.csv",
        ["$$ProductCategory.Code$Product.StockKeepingUnit", "Catalog.Code", "IsPrimaryCategory", "Product.StockKeepingUnit", "ProductCategory.Code"],
        cat_prod_rows,
    )

    write_csv(
        "ProductQualification.csv",
        ["EffectiveFromDate", "EffectiveToDate", "IsQualified", "Name", "ParentProduct.StockKeepingUnit", "Product.StockKeepingUnit"],
        [],
    )

    # Matter estimate assumptions (Standard Average Estimate template).
    # Editable % rates + Source/Term drive the cascade; derived GB/hours are
    # read-only. Volume components use Billable_GB / Billable_Hours (Quantity
    # locked at 1) — see KLDPathway CML.
    write_csv("AttributePicklist.csv", ["Code", "DataType", "Description", "Name", "Status", "UnitOfMeasureId"], [])
    write_csv("AttributePicklistValue.csv", ["Code", "DisplayValue", "IsDefault", "Name", "Picklist.Name", "Sequence", "Status", "Value"], [])
    write_csv(
        "AttributeDefinition.csv",
        ["Code", "DataType", "DefaultHelpText", "DefaultValue", "Description", "DeveloperName", "IsActive", "IsRequired", "Label", "Name", "Picklist.Name", "SourceSystemIdentifier", "UnitOfMeasure.UnitCode", "ValueDescription"],
        [
            ["ATTR-KLD-SOURCE-GB", "Number", "Driver for Billable_GB on Staging and downstream cascade.", str(DEMO_SOURCE_GB), "Source data volume in GB", "Source_Data_GB", "true", "false", "Source Data", "Source Data", "", "", "GB", ""],
            ["ATTR-KLD-DECOMP-PCT", "Number", "Decompression assumption (%). Decompression GB = Source × (1 + rate/100).", str(DEMO_DECOMP_PCT), "Decompression rate percent used in the matter estimate cascade", "Decompression_Rate_Pct", "true", "false", "Decompression Rate (%)", "Decompression Rate (%)", "", "", "", ""],
            ["ATTR-KLD-STORAGE-EXP-PCT", "Number", "Storage expansion assumption (%). Storage Expansion GB = Decompression × (1 + rate/100).", str(DEMO_STORAGE_EXP_PCT), "Storage expansion rate percent used in the matter estimate cascade", "Storage_Expansion_Rate_Pct", "true", "false", "Storage Expansion Rate (%)", "Storage Expansion Rate (%)", "", "", "", ""],
            ["ATTR-KLD-ECA-PCT", "Number", "Share of Storage Expansion assigned to ECA hosting (%).", str(DEMO_ECA_PCT), "ECA data percent of storage expansion", "ECA_Pct", "true", "false", "ECA Data (%)", "ECA Data (%)", "", "", "", ""],
            ["ATTR-KLD-REVIEW-PCT", "Number", "Share of Storage Expansion assigned to active review hosting (%).", str(DEMO_REVIEW_PCT), "Active review percent of storage expansion", "Active_Review_Pct", "true", "false", "Active Review (%)", "Active Review (%)", "", "", "", ""],
            ["ATTR-KLD-DECOMP-GB", "Number", "Derived: Source Data × (1 + Decompression Rate %).", str(DEMO_DECOMP_GB), "Decompressed volume after applying decompression rate", "Decompression_GB", "true", "false", "Decompression GB", "Decompression GB", "", "", "GB", ""],
            ["ATTR-KLD-STORAGE-EXP-GB", "Number", "Derived: Decompression GB × (1 + Storage Expansion Rate %).", str(DEMO_STORAGE_EXP_GB), "Expanded storage volume after applying storage expansion rate", "Storage_Expansion_GB", "true", "false", "Storage Expansion GB", "Storage Expansion GB", "", "", "GB", ""],
            ["ATTR-KLD-ECA-GB", "Number", "Derived: Storage Expansion × ECA %. Synced to ECA Hosting Billable_GB.", str(DEMO_ECA_GB), "ECA hosting volume estimate", "ECA_Data_GB", "true", "false", "ECA Data GB", "ECA Data GB", "", "", "GB", ""],
            ["ATTR-KLD-REVIEW-GB", "Number", "Derived: Storage Expansion × Active Review %. Synced to Review Billable_GB.", str(DEMO_REVIEW_GB), "Active review volume estimate", "Active_Review_GB", "true", "false", "Active Review GB", "Active Review GB", "", "", "GB", ""],
            ["ATTR-KLD-PM-HRS-MO", "Number", "From PM/Tech hours matrix. Billable_Hours = rate × Term Months.", str(DEMO_PM_HRS_MO), "PM hours per month for professional services estimate", "PM_Hours_Per_Month", "true", "false", "PM Hours Per Month", "PM Hours Per Month", "", "", "h", ""],
            ["ATTR-KLD-TECH-HRS-MO", "Number", "From PM/Tech hours matrix. Billable_Hours = rate × Term Months.", str(DEMO_TECH_HRS_MO), "Tech hours per month for professional services estimate", "Tech_Hours_Per_Month", "true", "false", "Tech Hours Per Month", "Tech Hours Per Month", "", "", "h", ""],
            ["ATTR-KLD-TERM-MONTHS", "Number", "Contract term used in estimate (hours/month × months).", str(DEMO_TERM_MONTHS), "Estimate contract term in months", "Term_Months", "true", "false", "Term Months", "Term Months", "", "", "", ""],
            ["ATTR-KLD-BILLABLE-GB", "Number", "Billable volume in GB. Line Quantity stays 1; use this for pricing.", str(DEMO_SOURCE_GB), "Billable gigabytes for hosting/staging components", "Billable_GB", "true", "false", "Billable GB", "Billable GB", "", "", "GB", ""],
            ["ATTR-KLD-BILLABLE-HRS", "Number", "Billable hours (hrs/month × term). Line Quantity stays 1; use this for pricing.", str(DEMO_PM_HRS_MO * DEMO_TERM_MONTHS), "Billable hours for professional services components", "Billable_Hours", "true", "false", "Billable Hours", "Billable Hours", "", "", "h", ""],
        ],
    )
    write_csv("AttributeCategory.csv", ["Code", "Description", "Name"], [
        ["AC-KLD-MATTER", "", "Matter Estimate"],
        ["AC-KLD-VOLUME", "", "Billable Volume"],
    ])
    write_csv(
        "AttributeCategoryAttribute.csv",
        ["$$AttributeCategory.Code$AttributeDefinition.Code", "AttributeCategory.Code", "AttributeDefinition.Code"],
        [
            ["AC-KLD-MATTER;ATTR-KLD-SOURCE-GB", "AC-KLD-MATTER", "ATTR-KLD-SOURCE-GB"],
            ["AC-KLD-MATTER;ATTR-KLD-DECOMP-PCT", "AC-KLD-MATTER", "ATTR-KLD-DECOMP-PCT"],
            ["AC-KLD-MATTER;ATTR-KLD-STORAGE-EXP-PCT", "AC-KLD-MATTER", "ATTR-KLD-STORAGE-EXP-PCT"],
            ["AC-KLD-MATTER;ATTR-KLD-ECA-PCT", "AC-KLD-MATTER", "ATTR-KLD-ECA-PCT"],
            ["AC-KLD-MATTER;ATTR-KLD-REVIEW-PCT", "AC-KLD-MATTER", "ATTR-KLD-REVIEW-PCT"],
            ["AC-KLD-MATTER;ATTR-KLD-DECOMP-GB", "AC-KLD-MATTER", "ATTR-KLD-DECOMP-GB"],
            ["AC-KLD-MATTER;ATTR-KLD-STORAGE-EXP-GB", "AC-KLD-MATTER", "ATTR-KLD-STORAGE-EXP-GB"],
            ["AC-KLD-MATTER;ATTR-KLD-ECA-GB", "AC-KLD-MATTER", "ATTR-KLD-ECA-GB"],
            ["AC-KLD-MATTER;ATTR-KLD-REVIEW-GB", "AC-KLD-MATTER", "ATTR-KLD-REVIEW-GB"],
            ["AC-KLD-MATTER;ATTR-KLD-PM-HRS-MO", "AC-KLD-MATTER", "ATTR-KLD-PM-HRS-MO"],
            ["AC-KLD-MATTER;ATTR-KLD-TECH-HRS-MO", "AC-KLD-MATTER", "ATTR-KLD-TECH-HRS-MO"],
            ["AC-KLD-MATTER;ATTR-KLD-TERM-MONTHS", "AC-KLD-MATTER", "ATTR-KLD-TERM-MONTHS"],
            ["AC-KLD-VOLUME;ATTR-KLD-BILLABLE-GB", "AC-KLD-VOLUME", "ATTR-KLD-BILLABLE-GB"],
            ["AC-KLD-VOLUME;ATTR-KLD-BILLABLE-HRS", "AC-KLD-VOLUME", "ATTR-KLD-BILLABLE-HRS"],
        ],
    )
    # Pathway: Source + % rates + Term editable; derived GB/hours read-only.
    # Hosting/PS: Billable_* read-only (CML syncs when selected).
    # IsPriceImpacting stays false until a pricing-procedure overlay maps
    # Billable_* → LineItemQuantity / ListPrice (true + missing PAD → productDetails NPE).
    write_csv("ProductClassificationAttr.csv", ["AttributeCategory.Code", "AttributeDefinition.Code", "AttributeNameOverride", "DefaultValue", "Description", "DisplayType", "HelpText", "IsHidden", "IsPriceImpacting", "IsReadOnly", "IsRequired", "MaximumCharacterCount", "MaximumValue", "MinimumCharacterCount", "MinimumValue", "Name", "ProductClassification.Code", "Sequence", "Status", "StepValue", "UnitOfMeasure.UnitCode", "ValueDescription"], [
        ["AC-KLD-MATTER", "ATTR-KLD-SOURCE-GB", "", str(DEMO_SOURCE_GB), "", "", "", "false", "false", "false", "false", "", "", "", "", "KLD Pathway Source Data", "PC-KLD-PATHWAY", "1", "Active", "", "GB", ""],
        ["AC-KLD-MATTER", "ATTR-KLD-DECOMP-PCT", "", str(DEMO_DECOMP_PCT), "", "", "", "false", "false", "false", "false", "", "100", "", "0", "KLD Pathway Decompression Rate Pct", "PC-KLD-PATHWAY", "2", "Active", "", "", ""],
        ["AC-KLD-MATTER", "ATTR-KLD-STORAGE-EXP-PCT", "", str(DEMO_STORAGE_EXP_PCT), "", "", "", "false", "false", "false", "false", "", "100", "", "0", "KLD Pathway Storage Expansion Rate Pct", "PC-KLD-PATHWAY", "3", "Active", "", "", ""],
        ["AC-KLD-MATTER", "ATTR-KLD-ECA-PCT", "", str(DEMO_ECA_PCT), "", "", "", "false", "false", "false", "false", "", "100", "", "0", "KLD Pathway ECA Pct", "PC-KLD-PATHWAY", "4", "Active", "", "", ""],
        ["AC-KLD-MATTER", "ATTR-KLD-REVIEW-PCT", "", str(DEMO_REVIEW_PCT), "", "", "", "false", "false", "false", "false", "", "100", "", "0", "KLD Pathway Active Review Pct", "PC-KLD-PATHWAY", "5", "Active", "", "", ""],
        ["AC-KLD-MATTER", "ATTR-KLD-DECOMP-GB", "", str(DEMO_DECOMP_GB), "", "", "", "false", "false", "true", "false", "", "", "", "", "KLD Pathway Decompression GB", "PC-KLD-PATHWAY", "6", "Active", "", "GB", ""],
        ["AC-KLD-MATTER", "ATTR-KLD-STORAGE-EXP-GB", "", str(DEMO_STORAGE_EXP_GB), "", "", "", "false", "false", "true", "false", "", "", "", "", "KLD Pathway Storage Expansion GB", "PC-KLD-PATHWAY", "7", "Active", "", "GB", ""],
        ["AC-KLD-MATTER", "ATTR-KLD-ECA-GB", "", str(DEMO_ECA_GB), "", "", "", "false", "false", "true", "false", "", "", "", "", "KLD Pathway ECA Data GB", "PC-KLD-PATHWAY", "8", "Active", "", "GB", ""],
        ["AC-KLD-MATTER", "ATTR-KLD-REVIEW-GB", "", str(DEMO_REVIEW_GB), "", "", "", "false", "false", "true", "false", "", "", "", "", "KLD Pathway Active Review GB", "PC-KLD-PATHWAY", "9", "Active", "", "GB", ""],
        ["AC-KLD-MATTER", "ATTR-KLD-PM-HRS-MO", "", str(DEMO_PM_HRS_MO), "", "", "", "false", "false", "true", "false", "", "", "", "", "KLD Pathway PM Hours Per Month", "PC-KLD-PATHWAY", "10", "Active", "", "h", ""],
        ["AC-KLD-MATTER", "ATTR-KLD-TECH-HRS-MO", "", str(DEMO_TECH_HRS_MO), "", "", "", "false", "false", "true", "false", "", "", "", "", "KLD Pathway Tech Hours Per Month", "PC-KLD-PATHWAY", "11", "Active", "", "h", ""],
        ["AC-KLD-MATTER", "ATTR-KLD-TERM-MONTHS", "", str(DEMO_TERM_MONTHS), "", "", "", "false", "false", "false", "false", "", "", "", "", "KLD Pathway Term Months", "PC-KLD-PATHWAY", "12", "Active", "", "", ""],
        # IsPriceImpacting=false until pricing-procedure maps Billable_* (true
        # triggers Instant Pricing; without PADs/overlay → productDetails NPE).
        ["AC-KLD-VOLUME", "ATTR-KLD-BILLABLE-GB", "", str(DEMO_SOURCE_GB), "", "", "", "false", "false", "true", "false", "", "", "", "", "KLD Hosting Billable GB", "PC-KLD-HOST", "1", "Active", "", "GB", ""],
        ["AC-KLD-VOLUME", "ATTR-KLD-BILLABLE-HRS", "", str(DEMO_PM_HRS_MO * DEMO_TERM_MONTHS), "", "", "", "false", "false", "true", "false", "", "", "", "", "KLD PS Billable Hours", "PC-KLD-PS", "1", "Active", "", "h", ""],
    ])
    # Explicit PADs are required: classification attrs alone do not materialize
    # ProductAttributeDefinition. Missing PADs + IsPriceImpacting=true causes
    # Instant Pricing NPE: productDetails is null when selecting Staging/etc.
    host_skus = sorted({"KLD-STAGING"} | HOSTING_SKUS)
    pad_header = [
        "$$AttributeDefinition.Code$Product2.StockKeepingUnit",
        "AttributeCategory.Code", "AttributeDefinition.Code", "AttributeNameOverride",
        "DefaultValue", "Description", "DisplayType", "HelpText", "IsHidden",
        "IsPriceImpacting", "IsReadOnly", "IsRequired", "MaximumCharacterCount",
        "MaximumValue", "MinimumCharacterCount", "MinimumValue", "Name",
        "OverriddenProductAttributeDefinition.$$AttributeDefinition.Code$Product2.StockKeepingUnit",
        "Product2.StockKeepingUnit", "ProductClassificationAttribute.Name",
        "Sequence", "Status", "StepValue", "UnitOfMeasure.UnitCode", "ValueDescription",
    ]
    pad_rows: list[list] = []
    for sku in host_skus:
        pad_rows.append([
            f"ATTR-KLD-BILLABLE-GB;{sku}", "AC-KLD-VOLUME", "ATTR-KLD-BILLABLE-GB",
            "", str(DEMO_SOURCE_GB), "", "", "", "false",
            # Keep false until pricing-procedure maps Billable_* → qty/price;
            # true triggers Instant Pricing and NPEs without productDetails/overlay.
            "false", "true", "false", "", "", "", "", "Billable GB",
            "", sku, "KLD Hosting Billable GB", "1", "Active", "", "GB", "",
        ])
    # Billable_Hours only on estimate-driven PS (PM/Tech), not consult/expert lines.
    for sku in ("KLD-PS-PM", "KLD-PS-TECH"):
        pad_rows.append([
            f"ATTR-KLD-BILLABLE-HRS;{sku}", "AC-KLD-VOLUME", "ATTR-KLD-BILLABLE-HRS",
            "", str(DEMO_PM_HRS_MO * DEMO_TERM_MONTHS), "", "", "", "false",
            "false", "true", "false", "", "", "", "", "Billable Hours",
            "", sku, "KLD PS Billable Hours", "1", "Active", "", "h", "",
        ])
    write_csv("ProductAttributeDefinition.csv", pad_header, pad_rows)

    write_csv("ProductRampSegment.csv", ["DurationType", "Name", "Product.StockKeepingUnit", "ProductSellingModel.SellingModelType", "SegmentType", "TrialDuration"], [])
    write_csv("ProductDisqualification.csv", ["EffectiveFromDate", "EffectiveToDate", "IsDisqualified", "Name", "ParentProductId", "ProductId", "Reason", "RootProductId"], [])
    write_csv("ProductCategoryDisqual.csv", ["CategoryId", "EffectiveFromDate", "EffectiveToDate", "IsDisqualified", "Name", "Reason"], [])
    write_csv("ProductCategoryQualification.csv", ["CategoryId", "EffectiveFromDate", "EffectiveToDate", "IsQualified", "Name"], [])
    write_csv("ProdtAttrScope.csv", ["Name", "Scope", "UsageType"], [])

    print(f"Generated kld-pcm with {len(PRODUCTS)} products")


if __name__ == "__main__":
    main()
