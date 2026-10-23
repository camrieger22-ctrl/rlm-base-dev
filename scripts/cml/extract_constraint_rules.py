#!/usr/bin/env python3
"""Extract Server2 (or any CML blob) run-time constraint messages.

Reads constraint / require / message(..., \"Error\") calls and writes a JSON
index used by Apex coach cards. Regenerating after a CML edit is part of the
constraint-model workflow:

    python scripts/cml/extract_constraint_rules.py
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_BLOB = (
    REPO_ROOT
    / "datasets"
    / "constraints"
    / "qb"
    / "Server2"
    / "blobs"
    / "ESDV_Server2_V1.ffxblob"
)
DEFAULT_OUT = (
    REPO_ROOT / "datasets" / "constraints" / "qb" / "Server2" / "rule-index.json"
)

ATTR_RE = re.compile(r"\b([A-Z][A-Za-z0-9]+)\b")
TYPE_RE = re.compile(r"\[([A-Za-z_][A-Za-z0-9_]*)\]")
REL_RE = re.compile(r"\b([a-z][A-Za-z0-9]*)\[")
STRING_LIT_RE = re.compile(r'"((?:\\.|[^"\\])*)"')

SKIP_ATTR = {
    "Error",
    "Warning",
    "Info",
    "N",
    "A",
    "Dual",
    "Single",
    "General",
    "High",
    "Availability",
    "Drives",
    "Standard",
    "Performance",
    "Accelerated",
    "Entry",
}

DEFAULT_APEX = (
    REPO_ROOT
    / "unpackaged"
    / "post_ramp_ux"
    / "classes"
    / "RLM_ConstraintRuleIndex.cls"
)
APEX_JSON_BEGIN = "    // BEGIN RULES_JSON"
APEX_JSON_END = "    // END RULES_JSON"


def split_top_args(inner: str) -> list[str]:
    args: list[str] = []
    buf: list[str] = []
    depth = 0
    in_str = False
    escape = False
    for ch in inner:
        if in_str:
            buf.append(ch)
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
            buf.append(ch)
            continue
        if ch == "(":
            depth += 1
            buf.append(ch)
            continue
        if ch == ")":
            depth -= 1
            buf.append(ch)
            continue
        if ch == "," and depth == 0:
            args.append("".join(buf).strip())
            buf = []
            continue
        buf.append(ch)
    if buf:
        args.append("".join(buf).strip())
    return args


def extract_calls(source: str, name: str) -> list[list[str]]:
    calls: list[list[str]] = []
    needle = name + "("
    start = 0
    while True:
        idx = source.find(needle, start)
        if idx < 0:
            return calls
        # skip if this is a longer identifier (e.g. messageType)
        if idx > 0 and (source[idx - 1].isalnum() or source[idx - 1] == "_"):
            start = idx + len(name)
            continue
        open_at = idx + len(name)
        depth = 0
        in_str = False
        escape = False
        end = None
        for i in range(open_at, len(source)):
            ch = source[i]
            if in_str:
                if escape:
                    escape = False
                elif ch == "\\":
                    escape = True
                elif ch == '"':
                    in_str = False
                continue
            if ch == '"':
                in_str = True
                continue
            if ch == "(":
                depth += 1
                continue
            if ch == ")":
                depth -= 1
                if depth == 0:
                    end = i
                    break
        if end is None:
            return calls
        inner = source[open_at + 1 : end]
        calls.append(split_top_args(inner))
        start = end + 1


def unquote(raw: str) -> str:
    raw = raw.strip()
    if len(raw) >= 2 and raw[0] == '"' and raw[-1] == '"':
        return bytes(raw[1:-1], "utf-8").decode("unicode_escape")
    return raw


def tokens(pred: str) -> tuple[list[str], list[str], list[str]]:
    types = sorted(set(TYPE_RE.findall(pred)))
    relations = sorted(set(REL_RE.findall(pred)))
    attrs = []
    for token in ATTR_RE.findall(pred):
        if token in SKIP_ATTR or token in types:
            continue
        if token[0].isupper() and len(token) > 2:
            attrs.append(token)
    # keep unique, stable
    seen = set()
    unique_attrs = []
    for attr in attrs:
        if attr not in seen:
            seen.add(attr)
            unique_attrs.append(attr)
    return unique_attrs, relations, types


def infer_flips(rule_text: str, pred: str) -> list[str]:
    text = rule_text.lower()
    flips: list[str] = []
    if "platinum" in text:
        flips.append("platinum")
    if re.search(r"socket(?: configuration)?(?: back)? to single", text) or (
        "switch socket to single" in text
    ):
        flips.append("socketSingle")
    if re.search(r"socket(?: configuration)? back to dual", text) or (
        "switch socket back to dual" in text
    ):
        flips.append("socketDual")
    if "performance tier to entry" in text:
        flips.append("tierEntry")
    if "workload ai" in text or "high performance computing" in text:
        flips.append("workloadAiHpc")
    if "workload to general" in text or "general workload needs a single" in text:
        flips.append("workloadGeneral")
        flips.append("socketSingle")
    if "dual sockets need workload" in text:
        flips.append("socketSingle")
        flips.append("socketDual")
    if "raid to n/a" in text:
        flips.append("raidNa")
    if "raid 500" in text or "add it" in text and "raid" in text:
        flips.append("raidCard")
    if "two liquid coolers" in text or (
        "add them" in text and "liquidcooler" in pred.lower()
    ):
        flips.append("liquidQty2")
    if "dimm type to lrdimm" in text:
        flips.append("dimmLrdimm")
    if "dimm type to rdimm" in text:
        flips.append("dimmRdimm")
    if "redundancy to basic" in text:
        flips.append("redundancyBasic")
    if "front storage to 12x3.5" in text:
        flips.append("frontStorage35")
    # unique preserve order
    out = []
    for flip in flips:
        if flip not in out:
            out.append(flip)
    return out


def infer_match(kind: str, pred: str, rule_text: str, types: list[str]) -> str | None:
    if "Gold CPU" in rule_text or any(t.startswith("Gold_") for t in types):
        return "dualGold"
    if "Dual sockets need Workload" in rule_text:
        return "dualWorkload"
    if "two liquid coolers" in rule_text:
        return "dualLiquid"
    if "x16 Lanes" in rule_text:
        return "x16Lanes"
    if "RAID 500" in rule_text:
        return "raidCard"
    return None


def infer_violating(match: str | None, rule_text: str) -> str | None:
    if match == "dualGold":
        return "Dual requires Gold quantity 0."
    if match == "dualWorkload":
        return "Socket and Workload must stay paired (Dual with AI/HPC, Single with General)."
    if match == "dualLiquid":
        return "Dual requires two liquid coolers."
    if match == "x16Lanes":
        return "Dual with this Performance Tier adds a GPU; x16 Lanes is read-only."
    if match == "raidCard":
        return "RAID requires a RAID 500 card."
    return None


def collect_rules(source: str) -> list[dict]:
    rules: list[dict] = []
    seen_text: set[str] = set()

    def add(kind: str, pred: str, rule_text: str) -> None:
        if not rule_text or rule_text in seen_text:
            return
        seen_text.add(rule_text)
        attrs, relations, types = tokens(pred)
        match = infer_match(kind, pred, rule_text, types)
        rules.append(
            {
                "kind": kind,
                "ruleText": rule_text,
                "attributes": attrs,
                "relations": relations,
                "types": types,
                "match": match,
                "flips": infer_flips(rule_text, pred),
                "violating": infer_violating(match, rule_text),
            }
        )

    for args in extract_calls(source, "constraint"):
        if len(args) < 2:
            continue
        add("constraint", args[0], unquote(args[-1]))
    for args in extract_calls(source, "require"):
        if len(args) < 3:
            continue
        pred = args[0] + " && " + args[1]
        add("require", pred, unquote(args[-1]))
    for args in extract_calls(source, "message"):
        if len(args) < 3:
            continue
        severity = unquote(args[-1])
        if severity.lower() != "error":
            continue
        add("message", args[0], unquote(args[1]))
    return rules


def apex_string_literal(value: str, indent: str = "        ") -> str:
    escaped = value.replace("\\", "\\\\").replace("'", "\\'")
    chunks = [escaped[i : i + 200] for i in range(0, len(escaped), 200)]
    if not chunks:
        return indent + "''"
    lines = []
    for i, chunk in enumerate(chunks):
        suffix = "" if i == len(chunks) - 1 else " +"
        lines.append(f"{indent}'{chunk}'{suffix}")
    return "\n".join(lines)


def write_apex_json(apex_path: Path, payload: dict) -> None:
    compact = json.dumps(payload, separators=(",", ":"))
    block = (
        f"{APEX_JSON_BEGIN}\n"
        f"    @TestVisible\n"
        f"    static final String RULES_JSON =\n"
        f"{apex_string_literal(compact)};\n"
        f"{APEX_JSON_END}"
    )
    text = apex_path.read_text(encoding="utf-8")
    start = text.find(APEX_JSON_BEGIN)
    end = text.find(APEX_JSON_END)
    if start < 0 or end < 0:
        raise SystemExit(f"{apex_path} is missing {APEX_JSON_BEGIN} markers")
    end += len(APEX_JSON_END)
    apex_path.write_text(text[:start] + block + text[end:], encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--blob", type=Path, default=DEFAULT_BLOB)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--apex", type=Path, default=DEFAULT_APEX)
    parser.add_argument("--skip-apex", action="store_true")
    args = parser.parse_args()
    source = args.blob.read_text(encoding="utf-8")
    payload = {
        "model": "Server2",
        "source": str(args.blob.relative_to(REPO_ROOT)),
        "rules": collect_rules(source),
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {len(payload['rules'])} rules to {args.out}")
    if not args.skip_apex:
        write_apex_json(args.apex, payload)
        print(f"Updated RULES_JSON in {args.apex}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
