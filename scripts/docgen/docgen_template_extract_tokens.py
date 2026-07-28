"""
Extract all mustache tokens from a .docx or .pptx template.

Parses paragraphs, tables, headers, and footers (Word) or shapes and
tables on every slide (PowerPoint) for:
  - {{field}} — simple value tokens
  - {{#Section}} / {{/Section}} — repeating block boundaries
  - {{IMG_name}} — dynamic image tokens

Outputs a structured report useful for validating alignment between
a template and its Transform ODT output keys.

`--token-list` emits the colon-scoped value for the DocumentTemplate
`<tokenList>` metadata field, where a token nested inside sections is
prefixed with its enclosing section names (e.g. `Line:CQL:ProductName`).
Scoping reflects *template* nesting, not payload nesting -- a token inside
a scalar gate such as `{{#IF_has_discount}}` is still scoped under it.

Usage:
  python scripts/docgen/docgen_template_extract_tokens.py /path/to/template.docx
  python scripts/docgen/docgen_template_extract_tokens.py /path/to/template.pptx --json
  python scripts/docgen/docgen_template_extract_tokens.py /path/to/template.docx --token-list
  python scripts/docgen/docgen_template_extract_tokens.py /path/to/template.docx --validate-transform RLMQuoteProposalTransform --org dev-scratch
"""
import argparse
import json
import re
import subprocess
import sys
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _soql import soql_escape


WORD_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
DRAWING_NS = "http://schemas.openxmlformats.org/drawingml/2006/main"
TOKEN_RE = re.compile(r"\{\{([^}]+)\}\}")


def extract_text_from_xml(xml_content):
    root = ET.fromstring(xml_content)
    texts = []
    for elem in root.iter(f"{{{WORD_NS}}}t"):
        if elem.text:
            texts.append(elem.text)
    return "".join(texts)


def extract_paragraphs_from_xml(xml_content, ns=WORD_NS):
    """Join runs within each paragraph so tokens split across runs rejoin."""
    root = ET.fromstring(xml_content)
    paragraphs = []
    for para in root.iter(f"{{{ns}}}p"):
        runs = []
        for t in para.iter(f"{{{ns}}}t"):
            if t.text:
                runs.append(t.text)
        if runs:
            paragraphs.append("".join(runs))
    return paragraphs


def _slide_sort_key(name):
    m = re.search(r"(\d+)", Path(name).stem)
    return (int(m.group(1)) if m else 0, name)


def _template_parts(z):
    """Return (namespace, ordered part names) for a Word or PowerPoint package."""
    names = z.namelist()
    if "word/document.xml" in names:
        parts = [
            n for n in names
            if n.endswith(".xml")
            and n.startswith("word/")
            and ("document" in n or "header" in n or "footer" in n)
        ]
        return WORD_NS, sorted(parts, key=lambda n: (0 if "document" in n else 1, n))
    if any(n.startswith("ppt/slides/slide") for n in names):
        parts = [
            n for n in names
            if n.startswith("ppt/slides/slide") and n.endswith(".xml")
        ]
        return DRAWING_NS, sorted(parts, key=_slide_sort_key)
    return None, []


def extract_tokens(template_path):
    """Extract tokens from a .docx or .pptx template, preserving document order."""
    tokens = {
        "fields": [],
        "sections_open": [],
        "sections_close": [],
        "images": [],
        "all": [],
        "token_list": [],
    }

    try:
        with zipfile.ZipFile(template_path, "r") as z:
            ns, parts = _template_parts(z)
            if not parts:
                print(
                    f"ERROR: '{template_path}' has no Word document or PowerPoint "
                    f"slide parts -- is it a valid .docx/.pptx?",
                    file=sys.stderr,
                )
                sys.exit(1)

            all_text = ""
            for part in parts:
                paragraphs = extract_paragraphs_from_xml(z.read(part), ns)
                all_text += "\n".join(paragraphs) + "\n"

    except zipfile.BadZipFile:
        print(
            f"ERROR: '{template_path}' is not a valid OOXML (.docx/.pptx) file",
            file=sys.stderr,
        )
        sys.exit(1)
    except FileNotFoundError:
        print(f"ERROR: File not found: '{template_path}'", file=sys.stderr)
        sys.exit(1)

    seen = set()
    stack = []
    scoped_seen = set()
    for match in TOKEN_RE.finditer(all_text):
        token = match.group(1).strip()

        # Scoped paths must be built from every occurrence, in order, before
        # the de-duplication below drops repeats.
        if token.startswith("#"):
            stack.append(token[1:].strip())
        elif token.startswith("/"):
            closing = token[1:].strip()
            if closing in stack:
                del stack[stack.index(closing):]
        else:
            path = ":".join(stack + [token])
            if path not in scoped_seen:
                scoped_seen.add(path)
                tokens["token_list"].append(path)

        if token in seen:
            continue
        seen.add(token)
        tokens["all"].append(token)

        if token.startswith("#"):
            tokens["sections_open"].append(token[1:].strip())
        elif token.startswith("/"):
            tokens["sections_close"].append(token[1:].strip())
        elif token.startswith("IMG_"):
            tokens["images"].append(token)
        else:
            tokens["fields"].append(token)

    return tokens


# Backwards-compatible alias for the pre-PPTX entry point.
extract_tokens_from_docx = extract_tokens


def validate_against_transform(tokens, odt_name, org):
    escaped_name = soql_escape(odt_name)
    query = f"SELECT Id FROM OmniDataTransform WHERE Name = '{escaped_name}'"
    result = subprocess.run(
        ["sf", "data", "query", "-q", query, "--target-org", org, "--json"],
        capture_output=True, text=True,
    )
    try:
        data = json.loads(result.stdout)
        records = data["result"]["records"]
    except (json.JSONDecodeError, KeyError):
        print(f"ERROR: Could not find Transform ODT '{odt_name}'", file=sys.stderr)
        return None

    if not records:
        print(f"ERROR: Transform ODT '{odt_name}' not found", file=sys.stderr)
        return None

    odt_id = records[0]["Id"]
    escaped_id = soql_escape(odt_id)
    query = (
        f"SELECT OutputFieldName, OutputObjectName, FormulaExpression "
        f"FROM OmniDataTransformItem WHERE OmniDataTransformationId = '{escaped_id}'"
    )
    result = subprocess.run(
        ["sf", "data", "query", "-q", query, "--target-org", org, "--json"],
        capture_output=True, text=True,
    )
    try:
        data = json.loads(result.stdout)
        items = data["result"]["records"]
    except (json.JSONDecodeError, KeyError):
        print(f"ERROR: Could not query Transform items", file=sys.stderr)
        return None

    transform_outputs = set()
    for item in items:
        out = item.get("OutputFieldName")
        if out and out != "Formula":
            transform_outputs.add(out)
            if ":" in out:
                transform_outputs.add(out.split(":")[0])
        obj = item.get("OutputObjectName")
        if obj and obj not in ("json", "Formula"):
            transform_outputs.add(obj)

    template_expects = set(tokens["fields"] + tokens["images"])
    for section in tokens["sections_open"]:
        template_expects.add(section)

    missing = template_expects - transform_outputs
    extra = transform_outputs - template_expects

    return {
        "missing_in_transform": sorted(missing),
        "extra_in_transform": sorted(extra),
        "aligned": sorted(template_expects & transform_outputs),
    }


def main():
    parser = argparse.ArgumentParser(
        description="Extract mustache tokens from a .docx or .pptx template"
    )
    parser.add_argument("docx", help="Path to .docx or .pptx template file")
    parser.add_argument(
        "--json", action="store_true", dest="json_output", help="Output as JSON"
    )
    parser.add_argument(
        "--token-list",
        action="store_true",
        help="Print the colon-scoped <tokenList> value for the .dt-meta.xml",
    )
    parser.add_argument(
        "--validate-transform",
        metavar="ODT_NAME",
        help="Compare tokens against a Transform ODT's output keys",
    )
    parser.add_argument("--org", help="SF CLI target org (required with --validate-transform)")
    args = parser.parse_args()

    tokens = extract_tokens(args.docx)

    if args.json_output:
        print(json.dumps(tokens, indent=2))
        return

    if args.token_list:
        print(",".join(tokens["token_list"]))
        return

    print(f"Template: {args.docx}")
    print(f"Total unique tokens: {len(tokens['all'])}")

    if tokens["fields"]:
        print(f"\nField tokens ({len(tokens['fields'])}):")
        for t in sorted(tokens["fields"]):
            print(f"  {{{{ {t} }}}}")

    if tokens["sections_open"]:
        print(f"\nSection blocks ({len(tokens['sections_open'])}):")
        for t in sorted(tokens["sections_open"]):
            matched = t in tokens["sections_close"]
            status = "✓ closed" if matched else "✗ UNCLOSED"
            print(f"  {{{{#{t}}}}} ... {{{{/{t}}}}}  [{status}]")

    unclosed = set(tokens["sections_open"]) - set(tokens["sections_close"])
    unopened = set(tokens["sections_close"]) - set(tokens["sections_open"])
    if unclosed:
        print(f"\n⚠ Unclosed sections: {sorted(unclosed)}")
    if unopened:
        print(f"\n⚠ Close without open: {sorted(unopened)}")

    if tokens["images"]:
        print(f"\nImage tokens ({len(tokens['images'])}):")
        for t in sorted(tokens["images"]):
            print(f"  {{{{ {t} }}}}")

    if args.validate_transform:
        if not args.org:
            print("\nERROR: --org required with --validate-transform", file=sys.stderr)
            sys.exit(1)

        print(f"\n--- Validating against Transform: {args.validate_transform} ---")
        result = validate_against_transform(tokens, args.validate_transform, args.org)
        if result:
            if result["aligned"]:
                print(f"  ✓ Aligned ({len(result['aligned'])}): {result['aligned']}")
            if result["missing_in_transform"]:
                print(
                    f"  ✗ Template expects but Transform doesn't provide "
                    f"({len(result['missing_in_transform'])}): "
                    f"{result['missing_in_transform']}"
                )
            if result["extra_in_transform"]:
                print(
                    f"  ℹ Transform provides but template doesn't use "
                    f"({len(result['extra_in_transform'])}): "
                    f"{result['extra_in_transform']}"
                )


if __name__ == "__main__":
    main()
