# OmniStudio Document Generation

Use this skill when creating, modifying, or troubleshooting Salesforce OmniStudio
document templates (`.docx` and `.pptx`) and DocumentTemplate lifecycle operations.
For ODT mapper architecture and deep ODT troubleshooting, use
`../odt-authoring/SKILL.md`.

## Quick Rules

1. **Template needs two ODT names** — DocumentTemplate must reference one Extract
   and one Transform ODT by name.
2. **Token syntax** — use `{{FieldName}}` for scalars, `{{#Section}}...{{/Section}}`
   for repeating rows, and `{{IMG_name}}` for images.
3. **Use canonical template scripts** — `docgen_template_*` is the only public
   command surface for template build, token extraction, lifecycle, and generation.
4. **Deactivate before mutable edits** — set template to Draft before binary or
   metadata updates; reactivate only after changes are complete.
5. **Generate to verify behavior** — use `docgen_template_generate.py` for
   end-to-end smoke tests after template or mapper updates. Rendering is the only
   real proof; token inventory alone never catches layout defects.
6. **Keep template and mapper changes in sync** — if token structure changes,
   confirm Extract/Transform output alignment before reactivation.
7. **Route ODT deep work to ODT skill** — hierarchy design, mapper structure,
   filter semantics, and array-depth debugging live in `../odt-authoring/SKILL.md`.
8. **Dynamic image contract is strict** — `IMG_*:src` must resolve to
   ContentDocument (`069`) plus width/height; see `dynamic-images.md`.
9. **Deploy new templates through the Metadata API** — templates created via the
   REST API cannot generate documents at all (see DO NOT below).
10. **PowerPoint is fully supported** — `.pptx` renders scalars, repeating table
    rows, and conditional row removal exactly as `.docx` does. See
    **PowerPoint Templates** below for the one structural limit (no slide gating).
11. **Build templates from a committed layout spec** — author with
    `docgen_template_build.py` so the binary is reproducible and reviewable
    instead of a hand-edited blob. Repo examples live in `scripts/docgen/layouts/`.


## DO NOT

- **DO NOT** use dot notation in Extract `InputFieldName` — use colons
  (`Invoice:PaymentTerm:Name`, not `Invoice.PaymentTerm.Name`).
- **DO NOT** leave `OutputObjectName` null on any OmniDataTransformItem — this
  causes a runtime NPE that silently produces empty output.
- **DO NOT** create duplicate object query items — duplicates can cause the entire
  Extract to fail silently, producing no data.
- **DO NOT** pass a ContentVersion Id (`068`) or file Title to `IMG_token:src` —
  only ContentDocument Id (`069`) works; others crash the engine.
- **DO NOT** omit `width` or `height` from `IMG_` token objects — the image
  silently fails to render if either dimension is missing.
- **DO NOT** edit `TargetOutputFileName` or `MapperOmniDataTransformName` while the
  DocumentTemplate or ODT is Active — deactivate first.
- **DO NOT** use the SObject REST API to create/edit/delete ODTs in shared,
  production, or customer orgs — the official docs say these records are "for
  internal use only." Use Metadata API XML instead.
- **DO NOT** create a new DocumentTemplate through the REST API and expect it to
  generate. A REST-created template deploys and looks correct in the UI, but
  every generation attempt fails with a misleading
  `You must specify templateContentVersionId for your Request`. The error is not
  about PowerPoint, API version, `tokenList`, or library membership — it is the
  creation path itself. Ship new templates as `.dt` + `.dt-meta.xml` through
  `unpackaged/post_docgen/documentTemplates/`. REST is still fine for *updating*
  an existing template's binary (`docgen_template_manage.py replace`).
- **DO NOT** wrap a whole PowerPoint slide in a conditional section. DocGen
  removes gated *content* but cannot delete a slide, so a false gate leaves a
  blank slide. Put conditional material in the Word document instead.

---

## Entry Conditions

| Task | Use this skill? |
|------|-----------------|
| Create a new `.docx` invoice/quote/contract template | Yes |
| Create a `.pptx` presentation template | Yes — see **PowerPoint Templates** |
| Wire up Extract + Transform ODTs for a template | Use `../odt-authoring/SKILL.md` |
| Add fields/tokens to an existing template | Yes |
| Troubleshoot blank output or generation errors | Yes |
| Add dynamic images to a template | Yes — see `dynamic-images.md` |
| Create ODT items programmatically via API | Use `../odt-authoring/SKILL.md` |

---

## ODT Context for Template Authors

| Path | Use When | Supportability |
|------|----------|----------------|
| **Metadata API** (`.rpt-meta.xml`) | Committed assets, CI/CD, `prepare_docgen` | Fully supported — official metadata type since API v54.0 |
| **OmniStudio Designer UI** | Prototyping, visual editing | Fully supported |
| **SObject REST API** (`docgen_odt_*`) | Scratch-org repair, rapid iteration, debugging | **Internal use only** — not supported for production |

### Metadata API (Primary)

ODTs are source-controlled as XML in `unpackaged/post_docgen/omniDataTransforms/`:
```
unpackaged/post_docgen/omniDataTransforms/
  RLMQuoteExtractBasic_1.rpt-meta.xml
  RLMQuoteTransformBasic_1.rpt-meta.xml
  BillingDocumentGenerationGetInvoiceDetails_1.rpt-meta.xml
  ...
```

Deploy via `cci flow run prepare_docgen --org dev-scratch`. See
`docs/guides/docgen-setup.md` for the full 10-step deployment sequence
(formula field pre-deploy, ODT seed workaround, binary fix).

### SObject REST API (ODT Experimentation Only)

> **Salesforce official warning** (from [SObject API reference](https://developer.salesforce.com/docs/atlas.en-us.industries_reference.meta/industries_reference/sforce_api_objects_omnidatatransform.htm)):
> *"This object and associated records are only for internal use. Don't perform
> any create, edit, or delete operations on this object. Modifying or deleting
> this object's records may result in errors with your implementation."*

The ODT helper scripts (`docgen_odt_*`) use this API for rapid scratch-org
iteration. They are appropriate for:
- Debugging blank output (inspecting/fixing items quickly)
- Cloning an ODT to experiment with variations
- Validating item structure before committing as Metadata API XML
- **Executing Extracts/Transforms** for automated testing (`docgen_odt_execute.py`)
- **Full document generation** end-to-end (`docgen_template_generate.py`)

They are **NOT** appropriate for production deployment.

### Template Lifecycle Management

The `docgen_template_manage.py` script manages the full DocumentTemplate
lifecycle: list, inspect, activate/deactivate, upload/replace binary,
create new templates, and download source or generated files.

```bash
# List all templates in an org
python scripts/docgen/docgen_template_manage.py list --org dev-scratch

# Show detail for a specific template
python scripts/docgen/docgen_template_manage.py status RLM_QuoteProposal --org dev-scratch

# Full replace lifecycle (deactivate → upload → reactivate)
python scripts/docgen/docgen_template_manage.py replace RLM_QuoteProposal template.docx --org dev-scratch

# Download template source .docx
python scripts/docgen/docgen_template_manage.py download --template RLM_QuoteProposal --org dev-scratch -o out.docx

# Download generated output by ContentVersion ID (from DGP ResponseText)
python scripts/docgen/docgen_template_manage.py download --version-id 068XXXXXXXXXXXXAAA --org dev-scratch -o out.pdf

# Create new template with ODT wiring
python scripts/docgen/docgen_template_manage.py create RLM_NewProposal template.docx --org dev-scratch \
  --extract-odt RLMQuoteProposalExtract --transform-odt RLMQuoteProposalTransform \
  --usage-type Revenue_Lifecycle_Management --activate
```

Use `--template-id <2dt...>` or `--content-doc-id <069...>` on mutating
commands when disambiguation is needed.

**Key behaviors:**
- DGP `ResponseText` returns 15-char ContentVersion IDs (e.g., `068xxxxxxxxxxxx`);
  the download command accepts both 15- and 18-char IDs.
- Generated `.docx` output is inspectable with `python-docx` (tables, paragraphs,
  token fill values). PDF output is compressed and requires `poppler` for text
  extraction — prefer downloading the `.docx` intermediate for verification.
- To get both `.docx` and `.pdf` from a single DGP run, set
  `"keepIntermediate": true` in `RequestText`.
- `RequestText` must include `templateContentVersionId` (the 068 ID of the
  template binary). Without it, DGP returns `INVALID_INPUT`.

### OmniStudio REST API (Execution & Testing)

The OmniStudio REST endpoint executes ODTs with standard OAuth (no
Lightning session needed). Works for both Extracts and Transforms:

```bash
# Execute an Extract against a record
python scripts/docgen/docgen_odt_execute.py RLMQuoteProposalExtract --record-id 0Q0XXXXXXXXXXXXAAA --org dev-scratch

# Execute a Transform (pass Extract output as input)
python scripts/docgen/docgen_odt_execute.py RLMQuoteProposalTransform --input extract_output.json --org dev-scratch

# Pipeline: Extract → Transform (--json pipes output)
python scripts/docgen/docgen_odt_execute.py RLMQuoteProposalExtract --record-id 0Q0XXXXXXXXXXXXAAA --org dev-scratch --json > /tmp/e.json
python scripts/docgen/docgen_odt_execute.py RLMQuoteProposalTransform --input /tmp/e.json --org dev-scratch

# Full end-to-end document generation (DGP: Extract → Transform → .docx → PDF)
python scripts/docgen/docgen_template_generate.py \
  --record-id 0Q0XXXXXXXXXXXXAAA --template-id 2dtXXXXXXXXXXXXAAA --org dev-scratch
```

Use this for:
- Automated validation of Extract output (entry counts, field presence)
- Phantom-entry detection (compare expected vs actual entry count)
- Transform output verification before wiring to a template
- End-to-end template smoke tests (DGP script triggers generation + polls)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    DocumentTemplate                          │
│  Name: "RLM_InvoiceTemplate_v2"                             │
│  Type: MicrosoftWord                                        │
│  ExtractOmniDataTransformName: "RLMInvoiceGetDetails"       │
│  MapperOmniDataTransformName: "RLMInvoiceTransformDetails"  │
│  TokenMappingMethodType: "OmniDataTransform"                │
│  UsageType: "Invoice"                                       │
└──────────────┬──────────────────────────┬───────────────────┘
               │                          │
    ┌──────────▼──────────┐    ┌──────────▼──────────┐
    │   Extract ODT       │    │   Transform ODT     │
    │   Type: "Extract"   │    │   Type: "Transform" │
    │   InputType: "JSON" │    │   InputType: "JSON" │
    │   OutputType: "JSON"│    │   OutputType: "JSON" │
    └──────────┬──────────┘    └──────────┬──────────┘
               │                          │
    ┌──────────▼──────────┐    ┌──────────▼──────────┐
    │  OmniDataTransform  │    │  OmniDataTransform  │
    │  Items (2 types):   │    │  Items (3 types):   │
    │  • Object Queries   │    │  • Pass-through     │
    │  • Field Mappings   │    │  • Formula          │
    └─────────────────────┘    │  • Image objects    │
                               └─────────────────────┘
```

**Data flow (live-verified via REST API):**

```
1. TRIGGER: DocumentGenerationProcess record inserted
   Input: {"Id": "<recordId>"}
   (DGP reads DocumentTemplate → resolves Extract + Transform names)

2. EXTRACT: POST /omnistudio/dataraptor/<ExtractName>
   - Receives: {"Id": "<recordId>"}
   - Executes object queries (SOQL) per sequence number
   - Applies filters (FilterValue + FilterOperator + FilterGroup)
   - Maps InputFieldName → OutputFieldName on field mapping items
   - Returns: raw data JSON (nested arrays/objects reflecting hierarchy)

3. TRANSFORM: POST /omnistudio/dataraptor/<TransformName>
   - Receives: Extract output JSON (entire response, as-is)
   - Applies: pass-through renames, formula computations (LIST, IF, CONCAT),
     object builders (IMG_, HYP_), Boolean casts (IF_ conditions)
   - Returns: template-ready JSON (keys = exact token names in the template)

4. RENDER: Engine merges Transform output with the .docx or .pptx template
   - Scalar tokens: {{TokenName}} → replaced with string value
   - Repeating sections: {{#Array}}...{{/Array}} → one row per array element
   - Conditional sections: {{#IF_x}}...{{/IF_x}} → rendered/hidden by Boolean
   - Dynamic content: IMG_, HYP_, RTB_ → rendered per their contract
   - Output: .docx or .pptx (intermediate)

5. CONVERT (optional): .docx → .pdf via Microsoft 365 service
   - Only when DGP.Type = "GenerateAndConvert"
   - Output: two ContentVersions (068 IDs) — .docx + .pdf

6. COMPLETE: DGP.Status → "Success", ResponseText = comma-separated 068 IDs
```

**Testable at each stage:**
- Stage 2: `python scripts/docgen/docgen_odt_execute.py RLMQuoteProposalExtract --record-id 0Q0XXXXXXXXXXXXAAA --org dev-scratch`
- Stage 3: `sf api request rest --method POST --body @extract_output.json /services/data/v67.0/omnistudio/dataraptor/RLMQuoteProposalTransform --target-org dev-scratch`
- Full pipeline: `python scripts/docgen/docgen_template_generate.py --record-id 0Q0XXXXXXXXXXXXAAA --template-id 2dtXXXXXXXXXXXXAAA --org dev-scratch`

---

## Token Reference

| Token Type | Syntax | Example | Transform Output |
|-----------|--------|---------|-----------------|
| Scalar | `{{Name}}` | `{{InvoiceNumber}}` | `"InvoiceNumber": "INV-001"` |
| Repeating section | `{{#List}}...{{/List}}` | `{{#InvoiceLines}}{{ProductName}}{{/InvoiceLines}}` | `"InvoiceLines": [{...}, ...]` |
| Truthy gate | `{{#Field}}...{{/Field}}` | `{{#GrantType}}row content{{/GrantType}}` | Renders when field is non-empty string/object; skips when absent/null/empty |
| Condition (boolean) | `{{#IF_x}}...{{/IF_x}}` | `{{#IF_has_discount}}...{{/IF_has_discount}}` | `"IF_has_discount": true` (Boolean only) |
| Inverse condition | `{{^IF_x}}...{{/IF_x}}` | `{{^IF_no_discount}}...{{/IF_no_discount}}` | Shows when value is `false`; hidden when `true` |
| Image | `{{IMG_name}}` | `{{IMG_CompanyLogo}}` | `{"src": "069...", "width": "200", "height": "80"}` (see `dynamic-images.md`) |
| Hyperlink | `{{HYP_name}}` | `{{HYP_PaymentLink}}` | `{"url": "https://...", "text": "label"}` |
| Rich text | `{{RTB_name}}` | `{{RTB_TermsContent}}` | HTML string: `"<b>Bold</b> <a href='...'>link</a>"` |

### Dynamic Content Token Notes

**RTB_ (Rich Text)** — **Confirmed working.** Pass an HTML string directly.
Supports `<b>`, `<i>`, `<ul>/<li>`, `<a href>` (renders clickable links),
and inline images. Best option for hyperlinks (renders with formatting).
- **Limitation:** RTB tokens must NOT be placed within a paragraph (causes
  generation failure). Place them as standalone blocks.
- **Limitation:** Bullets in template surrounding RTB tokens are not supported.

**IMG_ (Dynamic Images)** — **Confirmed working** with specific requirements:
- `src`: ContentDocument ID (`069` prefix) — **required**
- `width`: pixel string — **required**
- `height`: pixel string — **required**
- Image must be in a Content Library accessible to the Integration User
- See `dynamic-images.md` for full verified contract

**HYP_ (Hyperlinks)** — **Confirmed working.** Requires:
- Field name must be `"url"` (NOT `"src"`) — using `src` causes the "URL is invalid" error
- Template token must be **plain text** — do NOT format as a Word hyperlink (Cmd+K / Ctrl+K)
- `"text"` is optional — if omitted, the URL itself is displayed as the link text
- Alternative: RTB_ with `<a>` tags also works and offers richer formatting control

**IF_ (Conditions)** — Must receive **Boolean values only** (`true`/`false`).
Strings and numbers always evaluate as `true`, causing unexpected rendering.
Use `IF(expression, true, false)` formula in the Transform.

### Page Break and Token Spacing Guidelines

- **DO NOT** place page breaks directly before `{{#IF_` or `{{#Section}}` start
  tokens — creates blank pages when condition is false or section is empty.
- **DO NOT** place page breaks directly after `{{/IF_` or `{{/Section}}` end
  tokens — same blank page issue.
- **DO** place page breaks **between** sections, not adjacent to token markers.
- **DO** put the break that *ends* a conditional page **inside** the gated region,
  immediately before the closing token. Breaks within a section are removed along
  with its content, so the page disappears cleanly when the gate is false. A break
  placed after the closing token survives, lands next to the following section's
  break, and yields a blank page. Verified: moving one break inside a gate took a
  standard quote from 6 pages to 5.
- **Remove empty lines between adjacent conditional tokens** — the engine
  interprets whitespace between tokens as content, creating blank pages.

### Repeating Sections in Tables

Place `{{#SectionName}}` in the first cell of the data row and
`{{/SectionName}}` in the last cell. The engine duplicates the entire row for
each array element:

```
| Product                         | Qty          | Amount                        |
| {{#InvoiceLines}}{{ProductName}}| {{Quantity}} | {{Subtotal}}{{/InvoiceLines}} |
```

To nest bundle children, add one row per level and stack every closing tag in the
final cell of the last row (the pattern `RLM_Sales_Proposal_Document` uses):

```
| {{#Line}}{{ProductName}} | {{Quantity}} | {{NetTotalPrice}}                    |
| {{#CQL}}{{ProductName}}  | {{Quantity}} | {{NetTotalPrice}}                    |
| {{#CQL2}}{{ProductName}} | {{Quantity}} | {{NetTotalPrice}}{{/CQL2}}{{/CQL}}{{/Line}} |
```

Rows whose section is empty collapse, so a quote with no bundle children renders
only the `{{#Line}}` row.

**Conditional rows.** To make an entire row disappear, open the gate in the first
cell and close it in the last: `{{#IF_has_discount}}Discount` … `{{QDiscount}}%{{/IF_has_discount}}`.
Verified in both Word and PowerPoint.

---

## PowerPoint Templates

Server-side generation supports `.pptx` with `type: MicrosoftPowerpoint` and
`fileExtension: pptx`. Confirmed working on Release 262 for scalar tokens,
`{{#Section}}` repeating table rows, and conditional row removal — the mustache
contract is identical to Word.

Two differences matter when authoring:

| Concern | Word | PowerPoint |
|---------|------|------------|
| Conditional *content* | Collapses | Collapses |
| Conditional *container* | Page break inside gate removes the page | **A slide cannot be removed** — a false gate leaves it blank |
| Layout | Reflows | Fixed; every shape is absolutely positioned and does not reflow when text grows |

Because slides cannot be deleted, keep decks to content that renders for every
record and put record-dependent sections in the Word document. Since slides do not
reflow, leave vertical room for repeating tables to grow.

Build decks from a slide layout spec (`"format": "pptx"`), which keeps the binary
reproducible:

```bash
python scripts/docgen/docgen_template_build.py --example-pptx > deck.json
python scripts/docgen/docgen_template_build.py create deck.json -o template.pptx
```

Reference implementation: `scripts/docgen/layouts/quantumbit-sales-deck.layout.json`
→ `RLM_QuantumBit_Deck`, sharing one ODT pair with
`quantumbit-sales-proposal.layout.json` → `RLM_QuantumBit_Proposal`.

---

## Extract ODT — Item Types

### Object Query Items

Define which SObjects to query and how to join them:

| Field | Purpose | Example |
|-------|---------|---------|
| `InputObjectName` | SObject to query | `Invoice` |
| `InputFieldName` | Field on this object to match against FilterValue (see below) | `Id`, `InvoiceId` |
| `OutputFieldName` | Internal hierarchy path (join scope) | `Invoice`, `Invoice:Account` |
| `OutputObjectName` | Always `json` | `json` |
| `InputObjectQuerySequence` | Execution order (1, 2, 3...) | `1` |
| `FilterOperator` | Match operator | `=` |
| `FilterValue` | Value or path to match | `Id` (for root), `Invoice:BillingAccountId` (for FK lookup) |
| `FilterGroup` | Required grouping | `0` |

**InputFieldName semantics (critical — generates the WHERE clause):**
```
WHERE <InputFieldName> = <resolved FilterValue>
```

Two join patterns:

| Pattern | InputFieldName | FilterValue | Meaning |
|---------|---------------|-------------|---------|
| **Root** (input param) | `Id` | `Id` | Match input `Id` param → this object's `Id` |
| **FK lookup** (many:1) | `Id` | `Parent:FKField` | Match parent's FK → target's `Id` (1 result per parent) |
| **Child-of** (1:many) | Child's FK field | `Parent:Id` | Match parent's Id → child's FK (0..N per parent) |

**Examples:**
```
Seq 1: Invoice,     InputFieldName="Id",        FilterValue="Id"                        ← root
Seq 4: Account,     InputFieldName="Id",        FilterValue="Invoice:BillingAccountId"  ← FK lookup (safe)
Seq 5: InvoiceLine, InputFieldName="InvoiceId", FilterValue="Invoice:Id"                ← child-of (1:many)
```

**Multi-filter objects** (e.g., InvoiceLine with type filter):
```
Seq 3: InvoiceLine, InputFieldName=InvoiceId, FilterValue="Invoice:Id"
Seq 3: InvoiceLine, InputFieldName=Type,      FilterValue="\"Charge\""
```
Note: literal string filters use embedded quotes: `"\"Charge\""`.

### Field Mapping Items

Extract specific fields from queried objects:

| Field | Purpose | Example |
|-------|---------|---------|
| `InputFieldName` | Source path (colon-separated) | `Invoice:Account:BillingCity` |
| `OutputFieldName` | Key in Extract output | `BillingCity` |
| `OutputObjectName` | Always `json` | `json` |
| `OutputCreationSequence` | Usually `1` | `1` |

---

## Transform ODT — Item Types

### Pass-through Mappings

Simple field rename from Extract output to template token:

| Field | Purpose | Example |
|-------|---------|---------|
| `InputFieldName` | Key from Extract output | `BillingCity` |
| `OutputFieldName` | Template token name | `BillingCity` |
| `OutputObjectName` | Always `json` | `json` |
| `OutputCreationSequence` | `1` for simple mappings | `1` |

### Formula Items (Repeating Sections)

Build arrays for `{{#Section}}` tokens:

| Field | Purpose | Example |
|-------|---------|---------|
| `OutputFieldName` | `Formula` | `Formula` |
| `OutputObjectName` | `Formula` | `Formula` |
| `FormulaExpression` | Function call | `FUNCTION('invoice_docgen.InvoiceDocumentGeneration', 'InvoiceLineCustom', ...)` |
| `FormulaConverted` | RPN form (auto-generated on save — UI and API) | `\| ... FUNCTION` |
| `FormulaResultPath` | Output key name | `InvoiceLines` |
| `FormulaSequence` | Execution order | `1` |
| `OutputCreationSequence` | `0` (runs before mappings) | `0` |

### Object Output Items (Array Pass-through)

After a formula builds an array, map it to the template:

| Field | Purpose | Example |
|-------|---------|---------|
| `InputFieldName` | Formula result key | `InvoiceLines` |
| `OutputFieldName` | Template section name | `InvoiceLines` |
| `OutputObjectName` | `json` | `json` |
| `OutputFieldFormat` | `Object` (for arrays/objects) | `Object` |
| `OutputCreationSequence` | `1` | `1` |

---

## DocumentTemplate Record

| Field | Value | Notes |
|-------|-------|-------|
| `Name` | Template name | No underscores in API Name |
| `Type` | `MicrosoftWord` / `MicrosoftPowerpoint` | Must match the binary; `docgen_template_manage.py` sniffs the OOXML package rather than trusting the extension |
| `fileExtension` | `docx` / `pptx` | Keep aligned with `Type` |
| `TokenMappingType` | `JSON` | Always JSON for ODT approach |
| `TokenMappingMethodType` | `OmniDataTransform` | Links to ODT framework |
| `ExtractOmniDataTransformName` | Extract ODT name | Must match exactly |
| `MapperOmniDataTransformName` | Transform ODT name | Must match exactly |
| `UsageType` | `Invoice`, `Quote`, etc. | Object context |
| `Status` | `Active` / `Draft` | Must be Draft to edit; templates always **deploy** as Draft regardless of this value |
| `IsActive` | `true` / `false` | Must be false to edit |
| `tokenList` | Colon-scoped token paths | See below |

### tokenList scoping

`tokenList` reflects **template nesting, not payload nesting**. A token inside one
or more sections is prefixed with the enclosing section names, even when the value
is flat in the JSON — which is why the working Sales Proposal lists
`IF_has_discount:QDiscount` for a top-level `QDiscount`:

```
QuoteNumber,AccountName,IF_has_discount:QDiscount,Line:ProductName,Line:CQL:ProductName
```

Generate it rather than hand-maintaining it:

```bash
python scripts/docgen/docgen_template_extract_tokens.py template.docx --token-list
```

---

## Validation Checks

### Before generation

1. Both ODTs are Active (`IsActive: true`)
2. DocumentTemplate references correct ODT names (exact match, case-sensitive)
3. No items with null `OutputObjectName`:
   ```sql
   SELECT Id, OutputFieldName FROM OmniDataTransformItem
   WHERE OmniDataTransformationId = '<id>' AND OutputObjectName = null
   ```
4. No duplicate object query items (same Seq + OutputFieldName + FilterValue)
5. All object queries have `InputFieldName` and `FilterGroup` set
6. Field mapping paths use colons, not dots

### Common Extract Architecture Pitfalls

| Pitfall | Symptom | Root Cause | Fix |
|---------|---------|------------|-----|
| Cartesian product | N×M rows instead of N+M | Two multi-record sequences at the same nesting level | Nest child under parent via hierarchical OutputFieldName |
| FilterGroup cartesian | Records × groups explosion | Multiple FilterGroups on a nested child sequence | Use separate independent hierarchy instead of OR filters |
| Missing children | Only top-level records' children appear | Parent sequence has restrictive filter (e.g., ParentId = null) | Create separate root query without the restriction |
| Singleton instead of array | One object instead of array | Root-level OutputFieldName or all records collapse to same context | Nest under a parent (e.g., `Quote:MyArray` not just `MyArray`) |
| Null field values | Field silently blank | Relationship traversal without explicit join sequence | Use direct field or add join sequence for intermediate object |
| Output path confusion | Data in wrong JSON location | Using internal hierarchy paths for output field mappings | Use separate top-level output path (e.g., `Line:*` not `Quote:QuoteLineItem:*`) |
| Mixed-depth leakage | Parent + child count entries (e.g., 7+5=10 instead of 5) | Field mappings for same output array read from different hierarchy depths | All mappings must read from same depth — use redundant join for parent fields |
| Grantless parents in array | Empty rows for records without children | No subquery filtering; parent-level mapping includes all parents | Use child-first hierarchy with redundant parent join at child level |

### Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| All tokens blank | Extract failing (duplicates, NPE) | Check for duplicate object queries, null OutputObjectName |
| `getOutputObjectName() is null` | Item missing OutputObjectName | Set `OutputObjectName: "json"` on all items |
| "mandatory details missing" in UI | Same as above, or missing InputFieldName on object queries | Add required fields |
| `[object Object]` for images | Org below Release 256 (DocGen 1.0) | Upgrade org; or use RTB_ with HTML `<img>` as fallback |
| IMG_ token consumed, no image | Missing `width`/`height`, or Integration User can't access file | Add both dimensions + add Integration User to Content Library |
| Engine crash: `Cannot read properties of undefined (reading '0')` | `src` has ContentVersion ID (`068`) or file Title | Use ContentDocument ID (`069`) only |
| HYP_ shows red "URL is invalid" error | Wrong field name (`src` instead of `url`) or token formatted as Word hyperlink | Use `"url"` field (not `"src"`); ensure token is plain text in template |
| Template locked for edits | Active status | Deactivate (`IsActive: false, Status: Draft`) first |
| `You must specify templateContentVersionId for your Request` | Template was created through the REST API | Recreate it as `.dt` + `.dt-meta.xml` and deploy via Metadata API. Not a PowerPoint, API-version, `tokenList`, or library issue |
| Template deploys as Draft despite `<isActive>true</isActive>` | DocumentTemplates always deploy inactive | Run `cci task run activate_docgen_templates` (or `scripts/apex/activateDocgenTemplates.apex`) |
| Blank page where a conditional section was | Page break sits outside the gate, adjacent to the next section's break | Move the break inside the gated region, before the closing token |
| Blank slide in a generated deck | A conditional section wraps slide content | Slides cannot be deleted — move conditional content into the Word template |
| First data row styled as a header (PowerPoint) | PowerPoint emphasises row 0 by default | Build headerless tables with `emphasise_first_row: false` |
| Specific token blank | Field not in Extract or Transform | Trace: is field queried? Is it mapped through both ODTs? |
| Repeating section empty | Formula item missing or wrong ResultPath | Check formula at `OutputCreationSequence: 0` |
| Formula produces no output | Unsupported function (FormulaConverted is null) | Check `FormulaConverted` field — if null, the function isn't supported. See Formula Function Catalog below |
| ODT Name rejected on create | Contains underscores or spaces | Use camelCase only — alphanumeric, no special chars |
| More array entries than expected | Field mappings at mixed hierarchy depths | Run `docgen_odt_inspect_hierarchy.py` — all mappings for same output array must be at uniform depth |
| Array is singleton (object, not list) | OutputFieldName at root level | Nest under parent: use `Root:ArrayName` not just `ArrayName` |
| Missing child records in output | Parent sequence has restrictive filter | Child sequences inherit parent scope — create independent hierarchy with broader filter |
| N×M×G explosion in child results | Multiple FilterGroups on nested sequence | Each parent × each FilterGroup evaluated independently — use single FilterGroup or separate hierarchy |

---

## Platform Behavior Reference

> Full detail: **[`extract-engine-reference.md`](extract-engine-reference.md)**
> (formula catalog, filter mechanics, hierarchy semantics, array patterns, Preview API)

Verified on Release 262, API v67.0. Key concepts summarized below;
read the sub-file when designing or debugging complex Extracts.

### Critical Rules (quick reference)

| Rule | Detail |
|------|--------|
| **Internal ≠ Output paths** | Object query `OutputFieldName` (join scope) is decoupled from field mapping `OutputFieldName` (JSON shape). They share colon syntax but are independent namespaces. |
| **Depth uniformity** | ALL field mappings for the same output array must read from the same internal hierarchy depth. Mixed depths → parent entries leak into child array. |
| **Redundant join for parent fields** | To get a parent's field at child level without leaking grantless parents, re-join the parent object at the child level (Seq N filtering by child FK). |
| **Section-as-conditional** | `{{#FieldName}}...{{/FieldName}}` acts as truthy/falsy gate — renders when non-empty string/array/object; skips when absent, null, false, or empty. |
| **Self-referential gates work** | A nullable scalar can gate itself: `{{#ExpirationDate}}Valid through {{ExpirationDate}}{{/ExpirationDate}}` renders the value when present and removes the surrounding label when null. Resolution falls back to the parent context frame. This avoids adding an `IF_` formula per nullable field, at the cost of odd-looking `Name:Name` entries in `tokenList`. |
| **Never gate on an array** | Gating a page or block on an array token repeats the whole block once per element. Gate on a scalar that exists only in the intended case. |
| **Single-element collections are objects** | One child record serialises as an object, not a one-element array. `{{#Section}}` iterates it once, so templates are unaffected — but payload-shape assertions that test `isinstance(list)` will wrongly report the data missing. |
| **FilterGroup = OR** | Multiple FilterGroups are UNION ALL — on nested sequences this causes N×M×G cartesian explosion. Use only on root queries. |
| **Literals must be quoted** | `FilterValue: "'Active'"` not `FilterValue: "Active"`. Unquoted literals generate no WHERE clause. |
| **No subqueries** | Cannot filter "only parents with children." Use child-first hierarchy + redundant join pattern. |
| **Transform formulas are scalar** | `FormulaResultPath` cannot target per-array-element paths. Use section-as-conditional instead. |

### Formula Quick Reference

Supported: `IF`, `ISBLANK`, `CONCAT`, `SUBSTRING`, `LIST`, `FUNCTION`,
arithmetic, comparisons, `AND`/`OR`/`NOT`, `ABS`/`ROUND`/`FLOOR`/`CEILING`/`MAX`/`MIN`.

**Not supported** (saves silently, produces no output): `CASE`, `LEN`,
`UPPER`/`LOWER`, `TEXT`, `FORMAT`, `VALUE`, `MOD`, `POWER`.

### ODT Naming

Alphanumeric only (no underscores/spaces). Use camelCase: `RLMQuoteExtractBasic`.

---

## Examples

### Creating a complete template pipeline

See `data-mapper-authoring.md` for the programmatic API approach to creating
Extract + Transform ODTs with all items.

### Adding a new field to an existing template

1. **Template**: Add `{{NewField}}` token in the `.docx`
2. **Extract**: Add field mapping item — `InputFieldName: "Object:FieldApiName"`,
   `OutputFieldName: "NewField"`, `OutputObjectName: "json"`
3. **Transform**: Add pass-through — `InputFieldName: "NewField"`,
   `OutputFieldName: "NewField"`, `OutputObjectName: "json"`
4. **If field is on a new object**: Add object query item first (with proper
   Seq, InputFieldName, FilterValue, FilterGroup)
5. **Re-toggle** both ODTs (`IsActive` false → true)
6. **Upload** new `.docx` (deactivate template → replace file → reactivate)

---

## Helper Scripts

Scripts in `scripts/docgen/` support document generation workflows.
Install deps first: `pip install -r scripts/docgen/requirements.txt`

```bash
# ODT workflows are covered by ../odt-authoring/SKILL.md (docgen_odt_* commands).

# Extract all mustache tokens from a .docx or .pptx template (also reads .dt binaries)
python scripts/docgen/docgen_template_extract_tokens.py template.docx
python scripts/docgen/docgen_template_extract_tokens.py deck.pptx
python scripts/docgen/docgen_template_extract_tokens.py template.docx --validate-transform RLMQuoteProposalTransform --org dev-scratch

# Emit the colon-scoped <tokenList> value for the .dt-meta.xml
python scripts/docgen/docgen_template_extract_tokens.py template.docx --token-list

# Build templates programmatically (requires python-docx; python-pptx for decks)
# NOTE: replace/audit operate on body + tables only — headers/footers NOT searched.
# Use docgen_template_extract_tokens.py for full-template token inventory (includes headers/footers).
python scripts/docgen/docgen_template_build.py create layout.json --output template.docx
python scripts/docgen/docgen_template_build.py create deck.json --output template.pptx   # "format": "pptx"
python scripts/docgen/docgen_template_build.py replace template.docx --tokens '{"Old": "New"}'
python scripts/docgen/docgen_template_build.py audit template.docx
python scripts/docgen/docgen_template_build.py --example > layout.json        # Word layout spec
python scripts/docgen/docgen_template_build.py --example-pptx > deck.json     # PowerPoint slide spec

# Full document generation (DGP): Extract → Transform → .docx → PDF
python scripts/docgen/docgen_template_generate.py --record-id 0Q0XXXXXXXXXXXXAAA --template-id 2dtXXXXXXXXXXXXAAA --org dev-scratch
python scripts/docgen/docgen_template_generate.py --record-id 0Q0XXXXXXXXXXXXAAA --template-id 2dtXXXXXXXXXXXXAAA --org dev-scratch --no-convert  # .docx only
python scripts/docgen/docgen_template_generate.py --record-id 0Q0XXXXXXXXXXXXAAA --template-id 2dtXXXXXXXXXXXXAAA --org dev-scratch --title "Custom Name"
```

---

## Deployment & Repo Integration

For the full deployment guide, see **`docs/guides/docgen-setup.md`**.

### Key points:

- **Metadata path**: `unpackaged/post_docgen/omniDataTransforms/*.rpt-meta.xml`
- **Template path**: `unpackaged/post_docgen/documentTemplates/<Name>_1.dt` plus a
  matching `.dt-meta.xml`. This is the **only** path that yields a template capable
  of generating — do not create templates via REST.
- **Template sources**: layout specs in `scripts/docgen/layouts/*.layout.json` are
  the reviewable source for repo templates; rebuild the `.dt` from them rather than
  editing binaries.
- **Deploy flow**: `cci flow run prepare_docgen --org dev-scratch` (10 steps)
- **Fresh-org bug**: ODT INSERT fails when formula fields referenced in
  `inputFieldName` don't exist yet. Steps 3–5 of `prepare_docgen` pre-deploy
  formula fields and seed stub ODT records as a workaround.
- **Binary fix**: `fix_document_template_binaries` uploads correct `.docx` binary
  after metadata deploy (Metadata API drops binary content on deploy).
- **Feature gate**: All steps gated by `project_config.project__custom__docgen`.
- **Context Service alternative**: `RLM_QuoteProposal_CS` uses Context Service
  instead of ODTs — see the setup guide for that path.

### Retrieve an ODT from a scratch org:

```bash
sf project retrieve start --metadata OmniDataTransform:RLMInvoiceGetDetails --target-org dev-scratch
```

Then move the retrieved `.rpt-meta.xml` to `unpackaged/post_docgen/omniDataTransforms/`.

---

## Related Skills

- `../odt-authoring/SKILL.md` — ODT architecture, mapper design, and execution patterns
- `expression-sets/SKILL.md` — Expression Set authoring (pricing procedures use
  similar Connect/Metadata API patterns)
- `repo-integration/SKILL.md` — Where to place template metadata in the repo
- `sfdmu-data-plans/SKILL.md` — Loading template/ODT records via data plans
- `docs/guides/docgen-setup.md` — Full deployment sequence, bug workarounds, Context Service
