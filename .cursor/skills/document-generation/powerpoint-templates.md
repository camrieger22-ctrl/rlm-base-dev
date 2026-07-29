# PowerPoint DocGen Templates (Revenue Cloud)

Use this sub-file when creating or iterating on a **Microsoft PowerPoint**
DocumentTemplate for Revenue Cloud / OmniStudio DocGen. Parent skill:
[`SKILL.md`](./SKILL.md). For Extract/Transform item design, use
[`../odt-authoring/SKILL.md`](../odt-authoring/SKILL.md).

Canonical reference decks in this repo:

| Layout (source of truth) | Template name | ODT pair |
|--------------------------|---------------|----------|
| `scripts/docgen/layouts/chicago-bears-partnership-deck.layout.json` | `RLM_Bears_Partnership_Deck` | `RLMQuoteExtractBasic` + `RLMQuoteTransformBasic` |
| `scripts/docgen/layouts/quantumbit-sales-deck.layout.json` | `RLM_QuantumBit_Deck` | same pair (or QB-specific) |

Prefer one ODT pair shared with the matching Word proposal so tokens stay aligned.

---

## When to use this

| Task | Read this? |
|------|------------|
| New customer / partner PowerPoint proposal deck | Yes |
| Restyle colors, fonts, logos, table chrome on an existing deck | Yes |
| Wire Quote / amend commercial numbers into slides | Yes |
| Word `.docx` only | No — parent `SKILL.md` is enough |
| Deep ODT hierarchy / formula debugging | No — use `odt-authoring` |

---

## Quick Rules

1. **Author the layout JSON, not the binary by hand** — edit
   `scripts/docgen/layouts/<name>.layout.json`, then build `.dt` with
   `docgen_template_build.py`.
2. **Ship new templates via Metadata API** — `.dt` + `.dt-meta.xml` under
   `unpackaged/post_docgen/documentTemplates/`. REST `create` looks fine in UI
   but generation fails (`templateContentVersionId` error).
3. **REST is fine for binary updates** — `docgen_template_manage.py replace`
   on an existing template Id (`2dt…`).
4. **Never gate a whole slide** — DocGen can hide content, not delete slides.
   Gate amendment blocks with a scalar that is only present on amendments
   (e.g. `{{#AmendCurrentARR}}…{{/AmendCurrentARR}}`).
5. **Keep ODTs and `tokenList` in sync** — if you add `{{Line:StartDate}}` to
   the deck, add Extract + Transform items and update `.dt-meta.xml` `tokenList`.
6. **Generate to verify** — `docgen_template_generate.py` against a real Quote
   Id is the only proof. Token lists alone miss layout/color/font issues.
7. **Set a theme font** — layout `theme.font` (e.g. `Trebuchet MS`) applies
   deck-wide via the builder. Default Calibri reads as generic AI type.
8. **Transparent logos** — PNGs with opaque white backgrounds show boxes on
   navy/ice/orange cards. Knock out the background to alpha before embedding.

---

## DO NOT

- **DO NOT** create the DocumentTemplate with REST and expect generation to work.
- **DO NOT** wrap an entire slide in `{{#IF_…}}` / `{{#Amend…}}` expecting the
  slide to disappear on non-matching records.
- **DO NOT** edit `unpackaged/post_ux/` or hand-edit assembled XML for decks —
  decks are DocGen binaries, not UX assembly.
- **DO NOT** put `omniDataTransformItem` blocks after `</omniDataTransformItem>`
  clusters incorrectly (items must stay contiguous before `<outputType>` in
  `.rpt-meta.xml`).
- **DO NOT** use bare `Date` format on Extract date fields — use
  `Date(MM/dd/yyyy)` or values blank out.
- **DO NOT** pass CCI org aliases to `sf` / docgen `--org` interchangeably
  without knowing which registry you are in (`master-demo` vs `rlm-base__…`).
- **DO NOT** assume Opportunity edits appear in the deck until they are on the
  Quote (and amend breakdown fields are re-stamped when using Amend* tokens).

---

## End-to-end workflow

### 1. Layout JSON

```json
{
  "format": "pptx",
  "slide_size": { "width_inches": 13.333, "height_inches": 7.5 },
  "theme": {
    "navy": "#0B162A",
    "orange": "#C83803",
    "font": "Trebuchet MS",
    "ice": "#E8EEF5",
    "warm": "#FFF1EB",
    "white": "#FFFFFF",
    "muted": "#6B7685",
    "body": "#3A4555",
    "this_add_fill": "#FFF1EB",
    "current_fill": "#E8EEF5"
  },
  "slides": [ /* absolutely positioned elements */ ]
}
```

Element types the builder supports (PPTX path):

| `type` | Notes |
|--------|--------|
| `textbox` | `lines[]` with `text`, `size_pt`, `bold`, `color` (`@theme` or `#hex`), `align`, spacing |
| `shape` | `rect` / `rounded_rect` / `oval`; `fill`, `line`, `line_width_pt`, optional `lines` |
| `table` | `header`, `rows`, `col_widths`, `header_fill`, `body_fill`, `border`, `border_width_pt`, `text_color` |
| `image` | local path relative to repo root; prefer transparent PNG |

Colors: prefer `@themeKey` so rebrands are one edit.

Scaffold:

```bash
python scripts/docgen/docgen_template_build.py --example-pptx > scripts/docgen/layouts/my-deck.layout.json
```

### 2. Build the binary

```bash
python scripts/docgen/docgen_template_build.py create \
  scripts/docgen/layouts/my-deck.layout.json \
  -o unpackaged/post_docgen/documentTemplates/RLM_My_Deck_1.dt
```

The builder writes/updates sibling `.dt-meta.xml`. Confirm `tokenList` includes
every live token (including nested `AmendCurrentARR:AmendThisAddProrated` style
scopes when content sits inside a gate).

### 3. First-time ship (Metadata API)

Place `.dt` + `.dt-meta.xml` under `unpackaged/post_docgen/documentTemplates/`,
wire Type `MicrosoftPowerpoint`, `fileExtension` `pptx`, Extract/Transform ODT
names, `usageType` `Revenue_Lifecycle_Management`, then deploy
(`cci flow run prepare_docgen` or `sf project deploy start` for the package path
your org uses).

### 4. Iterate binary on an existing template

```bash
python scripts/docgen/docgen_template_manage.py status RLM_My_Deck --org <alias>
# note Id 2dt…

python scripts/docgen/docgen_template_manage.py replace \
  RLM_My_Deck \
  unpackaged/post_docgen/documentTemplates/RLM_My_Deck_1.dt \
  --org <alias> --template-id 2dt…
```

### 5. Generate and download

```bash
python scripts/docgen/docgen_template_generate.py \
  --record-id 0Q0… \
  --template-id 2dt… \
  --org <alias>

# From generate output / ContentVersion query:
DOCGEN_FORCE_OVERWRITE=1 python scripts/docgen/docgen_template_manage.py download \
  --version-id 068… --org <alias> -o ~/Desktop/My_Deck.pdf
```

---

## Token design for Revenue Cloud quotes

### Always-live commercial slides

Typical Quote payload (same as Word proposal):

- Scalars: `AccountName`, `ContactFirstName`, `QuoteNumber`, `QuoteStartDate`,
  `ExpirationDate`, `SalesRep`, `SellerEmail`, `SellerPhone`, `PaymentTerms`,
  `GrandTotal`
- Lines: `{{#Line}}…{{ProductName}}…{{StartDate}}…{{EndDate}}…{{TermMonths}}…{{/Line}}`

`TermMonths` is often a Transform formula (`ROUND(PricingTermCount * 12, 4)`),
not a raw QLI field. `StartDate` / `EndDate` need explicit Extract mappings with
`outputFieldFormat` `Date(MM/dd/yyyy)`.

### Amendment slides (Current / This add / Finalized)

Gate on a scalar that only exists when amend data is stamped, e.g.
`{{#AmendCurrentARR}}…{{/AmendCurrentARR}}` — content collapses on standard
quotes; the **slide shell remains**.

| Concern | Tokens |
|---------|--------|
| Summary cards | `AmendCurrentARR/MRR/Qty`, `AmendNetIncrease*`, `AmendProposed*`, `AmendThisAddProrated` |
| Per-product tables | `AmendProductCurrentAmending`, `AmendAddProduct`, `AmendProductAmending` (+ nested fields) |
| Arrow IF_ flags | Transform formulas (`IF_AmendNetIncreaseARRUp`, `IF_QtyUp`, …) |

These values come from **custom** Quote / `RLM_Amend_Breakdown__c` fields stamped
by Apex (`RLM_AmendDifferenceService`), not OOTB Opportunity fields. After quote
line changes, **re-stamp** before regenerating or slides 6–7 can lag.

### Static vs live

Narrative slides (why partner, program packaging, timeline, legalese) are often
**static template copy**. Only identity + commercial numbers need Salesforce.
Document that split in the layout `_comment` and any admin notes slide.

---

## Visual / branding checklist

| Topic | Guidance |
|-------|----------|
| Theme | Navy + one accent (Bears: `#0B162A` / `#C83803`); ice/warm fills for cards |
| Font | Set `theme.font` (e.g. `Trebuchet MS`); avoid default Calibri/Inter look |
| Tables | Match section semantics: e.g. This-add = orange header + `@this_add_fill` body + orange borders |
| Borders | Thin (`line_width_pt` ~1.0). Navy-on-navy or orange-on-orange borders vanish — use contrasting border colors (white on navy finalized tables) |
| Logos | Transparent PNG; keep a `*-with-white-bg.png` backup if you knock out alpha |
| Absolute layout | Leave vertical room for repeating table rows; PPT does not reflow |

---

## ODT change pattern (dates example)

When a slide token is blank:

1. Confirm the field exists on the Quote Line (or breakdown object) in the org.
2. Add Extract item: `Quote:QuoteLineItem:StartDate` → `Line:StartDate`,
   format `Date(MM/dd/yyyy)`.
3. Add Transform pass-through: `Line:StartDate` → `Line:StartDate`.
4. Keep new `<omniDataTransformItem>` nodes **contiguous** with other items,
   **before** `<outputType>`.
5. Mirror into both `unpackaged/post_docgen/` and `unpackaged/pre_docgen/` when
   both trees are used.
6. Deploy ODTs, then regenerate (template binary change not required if tokens
   already exist in the deck).

---

## Validation Checks

```bash
# Layout builds
python scripts/docgen/docgen_template_build.py create \
  scripts/docgen/layouts/<deck>.layout.json -o /tmp/check.dt

# Fonts actually applied
python3 - <<'PY'
from zipfile import ZipFile
from collections import Counter
import re
z = ZipFile("/tmp/check.dt")
c = Counter()
for n in z.namelist():
    if n.startswith("ppt/slides/") and n.endswith(".xml"):
        c.update(re.findall(r'typeface="([^"]+)"', z.read(n).decode()))
print(c)
PY

# Tokens present
python scripts/docgen/docgen_template_extract_tokens.py /tmp/check.dt

# Org lifecycle
python scripts/docgen/docgen_template_manage.py status <TemplateName> --org <alias>
python scripts/docgen/docgen_template_generate.py \
  --record-id <0Q0…> --template-id <2dt…> --org <alias>
```

Pass criteria:

- [ ] Generate Status = Success
- [ ] PDF/PPTX shows expected live numbers (not blank Start/End, not stale amend)
- [ ] Non-amend quote: amend slides collapse content without looking “broken”
- [ ] Logos have no white box on colored cards
- [ ] `tokenList` includes every token used inside gates

---

## Troubleshooting (PPTX-specific)

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Blank Start/End on investment table | Missing Extract date maps or wrong date format | Add `Date(MM/dd/yyyy)` Extract + Transform pass-through |
| Amend cards empty after line edit | Breakdown not re-stamped | Run amend stamp / Amendment Studio path |
| Empty slide on standard quote | Whole-slide gate | Gate inner content only |
| Generation: `templateContentVersionId` | REST-created template | Recreate via Metadata `.dt` |
| White rectangle behind logo | Opaque PNG background | Knock out to alpha; rebuild `.dt` |
| Borders invisible | Border color = fill color | Contrasting `@white` / `@orange` / `@navy` |
| Font still Calibri | `theme.font` missing / old binary | Set theme font, rebuild, replace |

---

## Examples

**Rebuild Bears deck and replace in org**

```bash
python scripts/docgen/docgen_template_build.py create \
  scripts/docgen/layouts/chicago-bears-partnership-deck.layout.json \
  -o unpackaged/post_docgen/documentTemplates/RLM_Bears_Partnership_Deck_1.dt

python scripts/docgen/docgen_template_manage.py replace \
  RLM_Bears_Partnership_Deck \
  unpackaged/post_docgen/documentTemplates/RLM_Bears_Partnership_Deck_1.dt \
  --org master-demo --template-id 2dtgL000000boVhQAI
```

**Smoke generate against an amendment quote**

```bash
python scripts/docgen/docgen_template_generate.py \
  --record-id 0Q0gL000002PZxVSAW \
  --template-id 2dtgL000000boVhQAI \
  --org master-demo
```
