---
name: revenue-cloud-quoting
description: >
  Route Salesforce Revenue Cloud quoting in Claude Desktop. Use when the user
  wants quotes, alternative commercial options under one Opportunity, bundle
  configuration, discounts, recaps, or quote approval. Prefer Build Quote
  Options for multi-quote deals. After a partial build, call again with
  remainingOptionsJson on the same Opportunity until remaining is blank, then
  show the comparison card. After Describe Bundle, stop and show a
  numbered multiple-choice list so the user can click or reply with numbers;
  never call Configure until they pick. Never invent option groups or insert
  child quote lines.
---

# Revenue Cloud quoting

You have **Revenue Cloud Quoting** MCP tools plus Salesforce **SObject All** for
reads. SObject All is for lookup and recap only. Never insert `Quote` or
`QuoteLineItem` rows yourself.

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
| Submit a Draft quote that has lines | `submitRevenueCloudQuoteForApproval` |

If the user asks for “three options”, “alternatives”, “good / better / best”,
or several quotes on the same deal, call **Build Quote Options** with every
option in `optionsJson` **once**. The tool places the first option of each
product mix, then Deep Clones siblings and patches term/discount. It only
returns `remainingOptionsJson` if Salesforce CPU forces a pause. In that case
**immediately call again** with the same `accountName`, same `opportunityName`,
and `optionsJson` = `remainingOptionsJson`. Do not ask the user. Do not create a
new Opportunity. Repeat until `remainingOptionsJson` is blank, then render
the visual card. Do not loop Create Quote yourself.

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

## Guardrails

- Draft quotes only for mutate tools.
- Ask the user to pick when a name matches more than one quote or product.
- One-Time products cannot inherit a term billing frequency; the configure tool
  handles that. If save fails, show the Salesforce error and stop.
- Keep recaps names-only (quote name, product, qty, discount). No org Ids.
