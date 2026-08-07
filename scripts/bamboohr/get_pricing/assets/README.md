# BambooHR Get Pricing assets

| File | Purpose |
|------|---------|
| `RLM_Bamboo_QuoteProposal.docx` | Branded quote proposal Word template (DocGen) |
| `bamboo_quote_layout.json` | Source layout for rebuilding the `.docx` via `docgen_template_build.py` |

## Org wiring

Template name: **`RLM_Bamboo_QuoteProposal`**

Uses Foundations ODTs `RLMQuoteExtractBasic` + `RLMQuoteTransformBasic`.

Creating via REST requires both:

1. `ContentVersion` in `DocgenDocumentTemplateLibrary` (Title = template name)
2. `DocumentTemplate` record (Active)
3. **`DocumentTemplateContentDoc`** junction linking the template to the ContentDocument

Without step 3, DGP fails with a misleading `templateContentVersionId` error.

Rebuild + re-upload sketch (JWT / CCI org):

```bash
python3 scripts/docgen/docgen_template_build.py create \
  scripts/bamboohr/get_pricing/assets/bamboo_quote_layout.json \
  --output scripts/bamboohr/get_pricing/assets/RLM_Bamboo_QuoteProposal.docx
```

Then upload via `docgen_template_manage.py replace` (SF CLI auth) or the JWT create path used in the demo setup, and ensure `DocumentTemplateContentDoc` exists.
