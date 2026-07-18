#!/usr/bin/env python3
"""Generate datasets/constraints/kld/KLDPathway from scripts/cml/KLDPathway.cml."""

from __future__ import annotations

import csv
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CML_SRC = ROOT / "scripts/cml/KLDPathway.cml"
OUT = ROOT / "datasets/constraints/kld/KLDPathway"
BLOB = OUT / "blobs" / "ESDV_KLDPathway_V1.ffxblob"
REL = "Bundle to Bundle Component Relationship"

# Stable fake Ids for portable import resolution (prefix-significant only).
# Demo scope: Nebula ECA → RelOne only.
PRODUCTS = [
    ("01tKLD000000002AAA", "Nebula ECA to RelOne", "KLD_PATH_NEB_R1"),
    ("01tKLD000000010AAA", "Staging", "Staging"),
    ("01tKLD000000011AAA", "Nebula ECA Hosting", "Nebula_ECA_Hosting"),
    ("01tKLD000000014AAA", "RelOne Review", "RelOne_Review"),
    ("01tKLD000000020AAA", "Project Management", "Project_Management"),
    ("01tKLD000000021AAA", "Technical Support", "Technical_Support"),
]

# Ports: (fake PRC Id, parent Name, child Name, port tag, sequence)
# Sequences must match ProductRelatedComponent.Sequence in kld-pcm / the org.
PORTS = [
    ("0dSKLD000000201AAA", "Nebula ECA to RelOne", "Staging", "staging_nebr1", 120),
    ("0dSKLD000000202AAA", "Nebula ECA to RelOne", "Nebula ECA Hosting", "eca_nebr1", 130),
    ("0dSKLD000000203AAA", "Nebula ECA to RelOne", "RelOne Review", "review_nebr1", 140),
    ("0dSKLD000000204AAA", "Nebula ECA to RelOne", "Project Management", "pm_nebr1", 310),
    ("0dSKLD000000205AAA", "Nebula ECA to RelOne", "Technical Support", "tech_nebr1", 320),
]


def write_csv(path: Path, header: list[str], rows: list[list]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(header)
        w.writerows(rows)


def main() -> None:
    if not CML_SRC.is_file():
        raise SystemExit(f"Missing CML source: {CML_SRC}")

    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "blobs").mkdir(parents=True, exist_ok=True)
    shutil.copyfile(CML_SRC, BLOB)

    write_csv(
        OUT / "ExpressionSet.csv",
        ["ApiName", "Description", "ExpressionSetDefinitionId", "Id", "InterfaceSourceType", "Name", "ResourceInitializationType", "UsageType"],
        [["KLDPathway", "KLDiscovery Nebula ECA→RelOne estimate cascade", "", "", "Constraint", "KLDPathway", "Off", "Constraint"]],
    )
    write_csv(
        OUT / "ExpressionSetDefinitionVersion.csv",
        ["ConstraintModel", "DeveloperName", "ExpressionSetDefinition.DeveloperName", "ExpressionSetDefinitionId", "Id", "Language", "MasterLabel", "Status", "VersionNumber"],
        [["", "KLDPathway_V1", "KLDPathway", "", "", "en_US", "KLD Pathway V1", "Active", "1"]],
    )
    write_csv(
        OUT / "ExpressionSetDefinitionContextDefinition.csv",
        ["ContextDefinitionApiName", "ContextDefinitionId", "ExpressionSetApiName", "ExpressionSetDefinitionId"],
        [["RLM_SalesTransactionContext", "", "KLDPathway", ""]],
    )
    write_csv(
        OUT / "ProductClassification.csv",
        ["Id", "Name"],
        [],
    )

    write_csv(
        OUT / "Product2.csv",
        ["Id", "Name"],
        [[pid, name] for pid, name, _tag in PRODUCTS],
    )

    prc_rows = []
    for i, (prc_id, parent, child, _port, seq) in enumerate(PORTS, start=1):
        prc_rows.append([
            prc_id,
            f"PRC-KLD-{i:06d}",
            "",
            parent,
            "",
            child,
            "",
            "",
            "",
            REL,
            str(seq),
        ])
    write_csv(
        OUT / "ProductRelatedComponent.csv",
        [
            "Id", "Name", "ParentProductId", "ParentProduct.Name", "ChildProductId", "ChildProduct.Name",
            "ChildProductClassificationId", "ChildProductClassification.Name",
            "ProductRelationshipTypeId", "ProductRelationshipType.Name", "Sequence",
        ],
        prc_rows,
    )

    esc_rows = []
    n = 1
    for pid, _name, tag in PRODUCTS:
        esc_rows.append([f"ECO-KLD-{n:06d}", "", "KLDPathway", pid, tag, "Type"])
        n += 1
    for prc_id, _parent, _child, port, _seq in PORTS:
        esc_rows.append([f"ECO-KLD-{n:06d}", "", "KLDPathway", prc_id, port, "Port"])
        n += 1
    write_csv(
        OUT / "ExpressionSetConstraintObj.csv",
        ["Name", "ExpressionSetId", "ExpressionSet.ApiName", "ReferenceObjectId", "ConstraintModelTag", "ConstraintModelTagType"],
        esc_rows,
    )

    print(f"Generated {OUT} ({len(PRODUCTS)} types, {len(PORTS)} ports)")
    print(f"Blob copied from {CML_SRC.name}")


if __name__ == "__main__":
    main()
