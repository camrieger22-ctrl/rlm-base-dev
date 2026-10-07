---
name: revenue-cloud-quoting
description: >
  Route Salesforce Revenue Cloud quoting in Claude Desktop. Use for quotes,
  alternative options under one Opportunity, bundle configuration, discounts,
  recaps, explaining a quote price, previewing a quote order form, quote
  approval, create/activate order, or amend an asset. Prefer Build Quote
  Options for multi-quote deals. Never insert Quote, Order, or Asset rows;
  never update Asset quantity. quantityChange is a delta. Convert spoken
  amendment dates to yyyy-mm-dd; ask for start date only if missing; never
  assume today. If document preview isPartial, retry the same tool
  immediately with no user-facing wait. Playbook is in this skill body.
---

# Revenue Cloud quoting

You have **Revenue Cloud Quoting** MCP tools plus Salesforce **SObject All** for
reads. SObject All is for lookup and recap only. Never insert `Quote`,
`QuoteLineItem`, `Order`, `OrderItem`, or `Asset` rows yourself. Never update
`Asset` rows to change quantity. Never use SObject All to explain a price or
rebuild a waterfall — call `explainRevenueCloudQuotePrice` once instead.

## Which tool

| User intent | Tool |
|---|---|
| Two or more commercial alternatives under **one Opportunity** (term, mix, discount) | `buildRevenueCloudQuoteOptions` |
| One new Draft quote | `createRevenueCloudQuote` |
| Add a catalog product to an existing Draft quote | `addProductToRevenueCloudQuote` |
| See bundle option groups / current picks | `describeRevenueCloudBundleConfiguration` |
| Save bundle picks the user chose from describe | `configureRevenueCloudBundle` |
| Percent off | `applyRevenueCloudQuoteDiscount` |
| Recap lines and prices | `getRevenueCloudQuoteSummary` |
| Why this price / walk the customer through list → final | `explainRevenueCloudQuotePrice` |
| Preview the order form / quote proposal PDF | `previewRevenueCloudQuoteDocument` |
| Submit a Draft quote that has lines | `submitRevenueCloudQuoteForApproval` |
| Create an order from a quote | `createRevenueCloudOrderFromQuote` |
| Activate an order so Salesforce creates assets | `activateRevenueCloudOrder` |
| Amend an existing asset (quantity change) | `amendRevenueCloudAsset` |

If the user asks for “three options”, “alternatives”, “good / better / best”,
or several quotes on the same deal, call **Build Quote Options** with every
option in `optionsJson` **once**. The tool places the first option of each
product mix, then Deep Clones siblings and patches term/discount. It only
returns `remainingOptionsJson` if Salesforce CPU forces a pause. In that case
**immediately call again** with the same `accountName`, same `opportunityName`,
and `optionsJson` = `remainingOptionsJson`. Do not ask the user. Do not create a
new Opportunity. Repeat until `remainingOptionsJson` is blank, then render
the visual card. Do not loop Create Quote yourself.

## Record links (required)

Claude Desktop has no Salesforce record card. Whenever a tool returns
`quoteUrl`, `opportunityUrl`, `orderUrl`, `assetUrl`, `pdfUrl`, or asset
links, put those in the user-facing reply as markdown links:

- `[Open Quote](quoteUrl)`
- `[Open Opportunity](opportunityUrl)`
- `[Open Order](orderUrl)`
- `[Open Asset](assetUrl)` or from `assetsDisplay`
- `[Open PDF](pdfUrl)`

Do this after create, add-line, configure, discount, summary, explain,
preview document, submit, create-order, activate, amend, and Build Quote
Options. Echo markdown already present in `message`, `comparisonDisplay`,
`resultsDisplay`, `summaryDisplay`, or `assetsDisplay`. Never paste a raw
Salesforce Id as the thing to click.

## Build Quote Options

Pass `accountName`, optional `opportunityName` (defaults to
`<Account> Commercial Options`), and `optionsJson`:

```json
[
  {
    "quoteName": "12-Month Essentials",
    "termMonths": 12,
    "discountPercent": 0,
    "lines": [
      {
        "product": "QuantumBit Complete",
        "quantity": 10,
        "configure": "QuantumBit Database, Software Maintenance"
      }
    ]
  },
  {
    "quoteName": "24-Month Growth",
    "termMonths": 24,
    "discountPercent": 5,
    "lines": [
      { "product": "QuantumBit Complete", "quantity": 10 },
      { "product": "Q-Rack 750", "quantity": 1 }
    ]
  }
]
```

`configure` is optional and only for bundle parents. Use catalog names or SKUs
from this org, not products from another demo.

`termMonths` is the **subscription term** on TermDefined lines (12 → 1 Annual,
24 → 2 Annual, 36 → 3 Annual), not only the quote header dates. One-Time
hardware is not given an end date.

Year-over-year **group ramps** (qty 10 / 20 / 30 as segments) are not in this
tool. Build the quotes here, then use Ramp Builder in Salesforce for segment
quantities.

### Visual recap (required)

After `buildRevenueCloudQuoteOptions` succeeds, **do not** dump the raw line
list as the main answer. Render `comparisonDisplay` as a **visual card**
(artifact if the client supports it):

1. Title: `<Account> Quote Options`
2. Subtitle: N options · opportunity name
3. Clickable **Open Opportunity** from `opportunityUrl`
4. Three stats: Lowest Net, Highest Net, Range
5. One row per option: name, term, line count, net, **Open** quote link

Keep one short sentence under the card. Put line-item detail behind a follow-up
("show lines") instead of in the first message.

Do **not** render the final card until `remainingOptionsJson` is blank. A
partial call may show 1 of 3 options — continue the tool, then show the card.

## Bundle configuration

1. Describe first. If it fails, show the error and stop.
2. Offer **only** the groups and products describe returned. Never invent groups.
3. Tell the user why items are already checked: required, catalog default
   (the bundle’s starting mix), or already saved on the quote. Do not imply
   they configured those themselves unless the line says already on this quote.
4. **Stop. Do not call Configure yet.** Show a picker (below) and wait.
5. After they pick, Configure with those names/SKUs. Never insert child
   `QuoteLineItem`s. Do not add the same bundle parent twice.

### Picker (required after every successful describe)

The chat cannot host a true checkbox widget. Make choosing as close to a click
as Claude allows:

- End your message with a **multiple-choice question**.
- One **optional** product per numbered line. Short **product name** only
  (SKU in parentheses is fine). Keep each line under ~60 characters so the
  client can show it as a tappable suggestion.
- Skip required items in the numbered list; mention them above as already on.
- Catalog defaults that are optional: include them as “keep default” vs
  “remove” where that helps, or list only adds and say defaults stay unless
  they say to remove.
- Number continuously across groups (1, 2, 3…) so they can answer `2 and 5`.
- Last lines of the numbered list should include:
  - `Keep the catalog defaults`
  - `Don't change anything`
- Then ask: **What do you want to add or change?** If suggestion chips
  appear, they can click those. Otherwise they can reply with numbers or names.

Example shape (use real names from describe, not this sample):

```
Catalog defaults are already selected (required Database; default API mix).
Optional adds:

1. Software Maintenance
2. QuantumBit Essentials Training
3. Additional API
4. Keep the catalog defaults
5. Don't change anything

What do you want to add or change? Click a suggestion or reply with numbers.
```

Only call `configureRevenueCloudBundle` after that reply. Map numbers back to
the describe names. If they click/type “Keep the catalog defaults”, configure
with the current [x] items (required + defaults) and no extra optionals.

## Explain quote price

When the user asks why the price is X, how you got to the number, to walk a
customer through the waterfall, or why Net Unit Price is blank on an
amendment:

1. Call `explainRevenueCloudQuotePrice` **once** with the quote (name, number,
   or Id). Pass `accountName` when known. Pass `productName` when they named a
   product (for example QuantumBit Database).
2. Do **not** query Quote, QuoteLineItem, QuoteLineDetail, or Asset with
   SObject All before or after that call. Do not “check the math” yourself.
3. Render `explanationDisplay` as the customer-facing story and stop. Do
   **not** send them to Quote Line Details or Calculation Details.
4. If the tool errors, show `errorMessage` and stop. Do not retry. Do not
   rebuild the waterfall from SObjects.
5. Blank Net Unit Price on an amendment line is expected. Never say pricing
   failed because NUP is blank.
6. Speak **list price**, **header/quote discount**, **quantity** (net add vs
   restated slices), **proration** (dates and percent of term), and
   **amount due**. Keep recipe-engine internals out of the customer reply.

## Preview quote document (order form)

When the user wants to preview the order form, quote proposal, or PDF for a
quote:

1. Call `previewRevenueCloudQuoteDocument`. Default template is
   **RLM_QuoteProposal** — do not pass `templateName` unless they named a
   different Active template. Do not use `Order_Form` (it is Draft).
2. Do **not** insert `ContentVersion` or generate a Word/PDF yourself. Do
   **not** query `DocumentGenerationProcess` with SObject All.
3. If `isPartial` is true **or** `message` starts with `RETRY_NOW`:
   - Do **not** write anything to the user (no “generating”, no “please wait”).
   - Immediately call the same tool again with `quoteId` and
     `documentGenerationProcessId` from the last result.
   - Repeat until `isPartial` is false or `errorMessage` is set (cap 8).
4. When `pdfUrl` is set, render **Open PDF** and **Open Quote**. Claude
   cannot show the PDF inline; the link is the preview.
5. A later preview of the same unchanged quote returns the existing PDF on
   the first call. Do not start a new generation and do not tell the user
   you are regenerating.

## Order and assets

1. Create the order from the quote (`createRevenueCloudOrderFromQuote`). If
   `isPartial` (quote still pricing), call again with the same quote. Do not
   insert an `Order`.
2. Then activate (`activateRevenueCloudOrder`) unless the user only wanted a
   draft order. If `isPartial`, **immediately call again** with the same
   `orderId` (up to 3 times) until `isPartial` is false or there is an error.
3. Render **Open Order** and each **Open Asset** link. Assets are created
   asynchronously after activation; an empty first activate is normal.

The account must have a Contact (Bill to Contact) and a billing or shipping
address. If activation says those are missing, tell the user — do not invent
contacts.

## Amend an asset

1. Look up the asset with SObject All if you need to confirm account, product,
   and current quantity. Prefer a named child product such as **QuantumBit
   Database**, not the **Complete** parent, unless the user names the parent.
2. **Get a start date, then convert it to `yyyy-mm-dd` before the tool call.**
   Spoken dates are fine in chat (`October 28th 2026`, `Oct 28 2026`, `today`).
   Never pass month names, ordinals, or `mm/dd/yyyy` into `startDate`.
   If the user already named a date, convert it and do **not** ask again.
   If they did not, **stop and ask**. Do not assume today. Offer a picker:

```
When should this amendment start?

1. Today (YYYY-MM-DD)
2. I'll type a different date

What start date should I use?
```

   Replace `YYYY-MM-DD` with today's real date. If they pick 1, use that date.
   If they type or say a date, convert it to `yyyy-mm-dd` (example:
   October 28th 2026 → `2026-10-28`).
3. Call `amendRevenueCloudAsset` with `quantityChange` as a **delta** (5 adds
   five; -2 removes two) and required `startDate`. Pass `assetId` when known;
   otherwise `accountName` + `productName`. If the named product is a **bundle
   component** (for example QuantumBit Database under Complete), still call
   this tool with that product name. The tool amends the top-level parent and
   applies the delta to the component line. Do **not** refuse, and do **not**
   add the quantity to Complete instead.
4. If `needsDisambiguation`, ask which asset. If `isPartial`, call again with
   the same asset and start date.
5. The tool creates an **amendment Quote**. Then create an order from that
   quote and activate it so the asset updates. Do not stop after the amend
   quote unless the user only wanted a draft quote.
6. Render **Open Quote** and **Open Asset**. Never PATCH `Asset.Quantity`.

## Guardrails

- Draft quotes only for quote mutate tools (add/configure/discount). Creating
  an order from a priced quote is allowed while the quote is still Draft.
- Ask the user to pick when a name matches more than one quote, order, or product.
- One-Time products cannot inherit a term billing frequency; the configure tool
  handles that. If save fails, show the Salesforce error and stop.
- Keep recaps names-only (quote name, product, qty, discount). No raw org
  Ids; clickable Lightning URLs from `quoteUrl` / `opportunityUrl` /
  `orderUrl` / `assetUrl` / `assetsDisplay` are required.
- `quantityChange` on amend is a delta, never the resulting quantity.
- Never assume today's date for an amendment. Ask only if they did not
  already give one. Convert whatever they said to `yyyy-mm-dd` before the
  tool call.
- Bundle components cannot be the `initiateAmendment` target. The Amend
  Asset tool walks to the parent and patches the component line. Do not
  tell the user they must add quantity on Complete instead.
- Price explanations: one `explainRevenueCloudQuotePrice` call. Never
  reconstruct list/discount/proration with SObject All.
- Quote document preview: `previewRevenueCloudQuoteDocument` with
  RLM_QuoteProposal. Never insert Files yourself. On `isPartial` or
  `RETRY_NOW`, retry immediately and do not tell the user to wait.
