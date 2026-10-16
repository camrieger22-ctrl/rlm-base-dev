---
name: revenue-cloud-quoting
description: >
  Route Salesforce Revenue Cloud quoting in Claude Desktop. After reconnect
  call getRevenueCloudQuotingCatalog. Inbound email: Gmail newest, then one
  createRevenueCloudQuote (contact names/email/address if no Account).
  Follow-up: updateQuoteLines with fromEmail=Gmail From; add Contact with
  signature title/phone/address. Never invent email. Never Create Prospect
  first. Never insert Quote/Order/Asset/Account; never send mail.
  Same-mix: cloneRevenueCloudQuote per option. Never wait. Never Build
  Quote Options. AE notes are chat-only. Quote change + draft + PDF
  link: one prompt, one turn. Never a later "now add the PDF". Ramp
  schedule: createRevenueCloudRampSchedule (preview then confirm). Ramp
  edits: applyRevenueCloudQuoteRamp editsJson. Never Ramp Builder.
  Bundle add: describe, wait, configure; never skip constraints.
  Bundle picker: keep or drill attrs then add-ons.
  Ramp year: blanket discount then named exception.
---

# Revenue Cloud quoting

You have **Revenue Cloud Quoting** MCP tools plus Salesforce **SObject All** for
reads. **Gmail** and **Microsoft 365 / Outlook** connectors (when enabled on
this chat) are for reading customer mail only. **Google Calendar** (when
enabled on this chat) is for finding a meeting / call recap — do that as
part of inbound quote, without being asked. Never create, update, or delete
calendar events. Never send a calendar invite. **Google Drive** (when
enabled on this chat) is for opening a Sheet, Doc, or PDF the email or
calendar event links to — do that without being asked. A PDF uploaded in
this chat is the same: read it, then quote. SObject All is for lookup and
recap only. Never insert `Quote`, `QuoteLineItem`, `Order`, `OrderItem`, or
`Asset` rows yourself. Never update `Asset` rows to change quantity. Never use
SObject All to explain a price, rebuild a waterfall, or recap installed
base — call `explainRevenueCloudQuotePrice` or
`getRevenueCloudInstalledBase` instead. Never send mail to the customer.

## Which tool

After reconnect, or when a tool parameter such as `startDate` is “unknown”,
call **`getRevenueCloudQuotingCatalog` first**. If that tool is missing,
stop and tell the user to reconnect MCP and re-upload this skill. Do **not**
call the catalog on an inbound-email or calendar quote unless a quoting
tool is missing.

| User intent | Tool |
|---|---|
| After reconnect / stale tools / skill version | `getRevenueCloudQuotingCatalog` |
| Same products, new term and/or discount | One `cloneRevenueCloudQuote` per option with `clonedQuoteName`, `termMonths`, and `discountPercentage`. **Never wait. Never Build Quote Options.** Do not resend `lines` |
| Two or more **new mixes** under one Opportunity | `buildRevenueCloudQuoteOptions` with `lines` on each option |
| One new Draft quote | `createRevenueCloudQuote` (always pass `opportunityName` + `quoteName` + `linesJson`) |
| Prospect / sender not in Salesforce | One `createRevenueCloudQuote` with `contactFirstName`, `contactLastName`, `contactEmail`, and billing address. That call creates Account + Contact + Opportunity + Draft. Do **not** call `createRevenueCloudProspect` first. If this prompt already said to create them from the email, that is the confirm — do not wait again. Never SObject-insert Account, Contact, Opportunity, or Quote |
| Sender From: not a Contact on an existing Account | On the same `updateRevenueCloudQuoteLines` / add-product call, pass `fromEmail` = Gmail **From** mailbox + `fromName`. Recap the sender picker in `resultsDisplay`. If `needsAction`, wait. Then `addRevenueCloudAccountContact`. Quote Contact is not the sender. Never skip. Never invent email |
| Add catalog products to an existing Draft quote | `addProductToRevenueCloudQuote` with `linesJson` for every new SKU in that call. New lines inherit the quote `StartDate`/`EndDate` (do not pass `termMonths` unless this SKU should differ). Recap `lineSummaryDisplay` + Open Quote. If `lineSummaryDisplay` has an **AE note**, say it in chat (never Gmail). If `needsAction` for a **bundle**, call `describeRevenueCloudBundleConfiguration` **in this turn**, render the picker, and **wait** — do not skip because Instant Pricing priced the parent. Do **not** explain or preview after add. Q-Rack 750 / One-Time hardware bundle: quantity 1. If Salesforce returns fractional quantity and qty > 1, immediately add again at quantity 1 — do not stop the quote. **Ramped quote:** `applyRevenueCloudQuoteRamp` `editsJson` instead |
| Which Draft quote / reconnect / several Acme deals | `findRevenueCloudOpenQuotes` with `opportunityName` from the email — ask only if several rows |
| See bundle option groups / current picks / attributes | `describeRevenueCloudBundleConfiguration` (keep-or-drill: current picks then names — never dump every value) |
| Save bundle picks the user chose from describe | `configureRevenueCloudBundle` (`attributePicksJson` for attribute values) |
| Percent off | `applyRevenueCloudQuoteDiscount` (discount only) or `updateRevenueCloudQuoteLines` when also changing qty or term. **Ramped quote:** `applyRevenueCloudQuoteRamp` `editsJson` — year blanket omits `product`; named SKU overlays (including bundle children). Never `applyRevenueCloudQuoteDiscount` on a ramped quote |
| Change quantity, term, start date, quote name, or remove a line on an existing Draft | `updateRevenueCloudQuoteLines` with `quantitiesJson` (quantity 0 or `"remove":true` drops that parent line), `termMonths`, `startDate`, and/or `quoteName` — never rebuild, never SObject-delete QuoteLineItem. **Ramped quote:** `applyRevenueCloudQuoteRamp` `editsJson` instead |
| What-if on a live Draft (36 months, 15% off, 20 more seats, TCV) | One `updateRevenueCloudQuoteLines`, then `getRevenueCloudBillingAndUsage` for TCV (GrandTotal). Never rebuild, never Build Quote Options |
| Change the quote **and** refresh the unsent email + PDF | **One turn.** `updateRevenueCloudQuoteLines`, then preview until `bodyDisplay`, then **update the existing Gmail draft**. Do not stop after the line update. Do not wait for a second “add the PDF” prompt |
| Customer pack (explain + proposal PDF + unsent email) | Explain once, then preview until `bodyDisplay` in **this turn**. **Never wait/Pause. Never ask the user to prompt again.** Gmail that HTML. **Never** `draftRevenueCloudCustomerReply` after preview. Never send |
| Close / take a named deal to order and activate | Find the quote, `getRevenueCloudDealStatus`, submit if Draft, decide only if this user is the assignee, `createRevenueCloudOrderFromQuote`, `activateRevenueCloudOrder`, then installed base. Stop if approval is waiting on someone else |
| Recap lines and prices | `getRevenueCloudQuoteSummary` |
| Why this price / walk the customer through list → final | `explainRevenueCloudQuotePrice` |
| Preview the order form / quote proposal PDF | `previewRevenueCloudQuoteDocument`. If `isPartial`, call again **immediately** until `bodyDisplay`. Never wait/Pause. Never ask the user to retry. Gmail `bodyDisplay`; do not Draft |
| Submit a Draft quote that has lines | `submitRevenueCloudQuoteForApproval` |
| Approve or reject a submitted quote (assignee) | `decideRevenueCloudQuoteApproval` (`decision=approve` or `reject`) |
| Create an order from a quote | `createRevenueCloudOrderFromQuote` |
| Activate an order so Salesforce creates assets | `activateRevenueCloudOrder` |
| Amend an existing asset (quantity change) | `amendRevenueCloudAsset` (pass `opportunityName`) |
| What they own / MRR / ARR / current discount / how often they add on | `getRevenueCloudInstalledBase` — period Discount, never quotes, never `Asset.CurrentMrr` |
| Quote vs what they own (qty / discount) | `compareRevenueCloudQuoteToInstalledBase` — quote 30% off is not owned Discount |
| Where is this deal / approval / order / assets | `getRevenueCloudDealStatus` — read only |
| Renew or cancel what they own | Confirm first, then `renewOrCancelRevenueCloudAsset` (`action=renew` or `cancel`). Then create order + activate. Never PATCH Asset |
| Draft a customer reply | `draftRevenueCloudCustomerReply` — Gmail draft/create with `bodyDisplay` verbatim. No Lightning URLs in the email. Never send |
| Add a PDF link to an existing unsent Gmail draft | `draftRevenueCloudCustomerReply` **once**, then **update that Gmail draft** with the proposal PDF `<a href>`. Do **not** preview. Do **not** explain. Do **not** create a second draft |
| Draft / refresh the email for the current quote | `previewRevenueCloudQuoteDocument` until `bodyDisplay` **in this turn**, then update Gmail. Never wait. Never ask them to prompt again. **Never** `draftRevenueCloudCustomerReply` |
| Preview or create a ramp schedule (Annual/Custom, trial, prorated) | `createRevenueCloudRampSchedule` — preview first, then `confirm=true`. Never Ramp Builder |
| Add / remove / qty / % off on ramp years (or first-add 10/20/30) | `applyRevenueCloudQuoteRamp` — `editsJson` for Trial/Year N/stub; omit `product` for a year blanket then named SKU exceptions; `segmentsJson` for 10/20/30. If `needsAction` for a bundle, describe in this turn, wait, then configure. Never `updateRevenueCloudQuoteLines` or `addProductToRevenueCloudQuote` on a ramped quote. Create the schedule first |
| Next bill / TCV / usage | `getRevenueCloudBillingAndUsage` — TCV is quote GrandTotal, not ARR |
| Build a quote from a customer email | Skip catalog. Gmail `in:inbox` newest (not a 30-day OR search). Open Drive Sheet/PDF now if present. Then **one** `createRevenueCloudQuote` (`opportunityName`, `quoteName`, `linesJson`, `contactEmail`; plus contact names/address if no Account). Recap only after it returns. If `alreadyExisted`, update — do not create again |
| Quote from a meeting / call / calendar recap | Skip catalog. Search **Google Calendar** (or Microsoft 365 calendar if that is what is on). Open the event description and any Drive notes now — do not wait for “read the recap.” Then one `createRevenueCloudQuote` with `opportunityName`, `quoteName`, `linesJson`, `startDate` from the event, `contactEmail` from a customer attendee (plus contact names/address if no Account). If `alreadyExisted`, update — do not create again |
| Later email / reconnect on an existing quote | `findRevenueCloudOpenQuotes` with that `opportunityName`, then `updateRevenueCloudQuoteLines` with `fromEmail` = Gmail From — never a second quote |

If they said **same products / current mix / just term and discount**, do
**not** call Build Quote Options. For each option: one
`cloneRevenueCloudQuote` (original Draft, or `current` / `latest` = oldest
Draft; pass `accountName` + `opportunityName`) with `clonedQuoteName`,
`termMonths`, and `discountPercentage`. Do not resend products. **Never
wait / Pause.** If clone fails, stop — do not rebuild. A **new mix** still
uses Build Quote Options with `lines`. Do not loop Create Quote yourself.

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
preview document, submit, create-order, activate, amend, prospect,
find-open-quotes, compare, clone, and Build Quote Options. Echo markdown already
present in `message`, `comparisonDisplay`, `resultsDisplay`,
`summaryDisplay`, or `assetsDisplay`. Never paste a raw Salesforce Id as
the thing to click. Also render `[Open Account](accountUrl)` /
`[Open Contact](contactUrl)` when those fields are set.

`quoteUrl` and `pdfUrl` are **Lightning** pages. Put them in Claude chat
only. Never put `/lightning/r/` links, Open Quote, or Open PDF in a Gmail
or Outlook draft — the customer cannot log in. Use `coachDisplay` from
`draftRevenueCloudCustomerReply` for those AE links.

## Derived-price AE note (required)

Create, add-line, clone, update-lines, Build Quote Options, and quote
summary can return an **AE note (chat only, never the customer email)**
when a derived-price SKU is on the quote without its contributing
products — for example Software Maintenance at 20% of Additional API
and/or QB API Management Solution.

- Put that note in the **Claude chat** recap so the rep sees which
  products the line is supposed to go with.
- Render the numbered options as a picker (same chip rules as bundle
  configure). **Stop and wait.** Do **not** add products until they pick.
- After they pick: `addProductToRevenueCloudQuote` with `linesJson` for
  the named SKU(s). One contributor is enough for a non-zero price; both
  only if they chose “add both.”
- **Add bundle** only when that option is in the AE note. Then add the
  bundle parent and `describeRevenueCloudBundleConfiguration` — do not
  configure until they pick components. Do **not** add Complete (or any
  bundle) on top of an existing standalone mix if the note omitted that
  option.
- **Configure bundle** when that option is in the note: describe, then
  wait, then configure those contributing SKUs. Do not add them as
  extra standalone lines.
- Do **not** copy the AE note into Gmail/Outlook `bodyDisplay`, the
  proposal PDF, or any customer email.
- Do not invent pairing rules or extra bundle options. If the recap has
  no AE note, the live derived-price rules are already satisfied (or
  this SKU is not derived).
- If they pick leave at $0, recap that Instant Pricing will warn and
  stop.

## Next-best-action (required after mutates)

After every **successful** create, add-line, update-lines, discount, ramp,
configure, submit, decide, create-order, activate, amend, renew/cancel,
customer pack, clone, or Build Quote Options, end the user-facing reply with
**one** short Next line. Do not add it after catalog ping, explain-only,
deal-status-only, or when you stopped to ask a question.

| Just happened | Next line |
|---|---|
| New or updated Draft (create / add / update / discount / ramp / configure / options) | Next: ramp 10/20/30, change term or discount, submit for approval, or prepare the customer pack. |
| Customer pack | Next: submit for approval, or take this deal to an order. |
| Submitted, waiting on someone else | Next: check deal status, or approve if you are the assignee. |
| Approved | Next: create the order and activate. |
| Order created, not activated | Next: activate so Salesforce creates assets. |
| Activated / amend or renew quote ready | Next: recap installed base, or compare this quote to what they own. (After amend/renew quote: create the order and activate.) |

Do not list every option. Use the matching row. Keep it one sentence.
If the recap includes an AE derived-price numbered picker, a
sender-contact `promptDisplay` with `needsAction`, **or** a bundle
configure picker (`needsAction` after create / add / ramp / describe /
configure), that picker **is** the Next line — wait for their choice.
Do not also add ramp / submit / customer pack.

## How to prompt (one turn)

When they change the quote **and** want the customer email / proposal
PDF updated, do **all of it in this turn**. Verified 2026-10-14: one
prompt (`80% off` + draft + PDF link) finished quickly. A later
standalone “hyperlink the PDF” prompt started a second generate, took
~2.5 minutes, and failed.

- **Do:** `update the quote to 80% off and add the proposal PDF to the existing draft`
- **Do not:** update first, then in a new message `now hyperlink the PDF`
- **Do:** `preview a 40-month annual ramp with a 30-day trial starting October 15 2026 on the 8-year quote`
- **Do:** `create that ramp schedule and add QuantumBit Database at 10, 20, then 30`
- **Do not:** open Ramp Builder, or create the schedule by applying 10/20/30 before `createRevenueCloudRampSchedule`

After the line update, preview until `bodyDisplay` and patch the
existing Gmail draft. Do not stop. Do not ask them to prompt again.

## Clone Quote

Same mix, new term / discount. Call **once per option**:

`cloneRevenueCloudQuote` with `accountName`, `opportunityName`,
`quoteName` = the **original** Draft (or `current` / `latest` = oldest
Draft), plus `clonedQuoteName`, `termMonths`, and `discountPercentage`.

Do not resend products. Do not Update Quote Lines unless clone said to.
**Never wait / Pause. Never Build Quote Options.** If clone fails, stop.

## Build Quote Options

Pass `accountName`, optional `opportunityName` (defaults to
`<Account> Commercial Options`), and `optionsJson`.

**Same mix, new term / discount:** do **not** use this tool. Call
`cloneRevenueCloudQuote` once per option with `clonedQuoteName`,
`termMonths`, and `discountPercentage`.

**New mix** (different products): pass `lines`:

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
tool. Create the empty schedule with `createRevenueCloudRampSchedule`, then
`applyRevenueCloudQuoteRamp`. First-add uses `segmentsJson`. Per-year add,
remove, qty, or discount uses `editsJson`. Never `updateRevenueCloudQuoteLines`
or `addProductToRevenueCloudQuote` on a ramped quote.

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

## Inbound quote from calendar (call / meeting / recap)

When they ask to **build a quote from a call, meeting, calendar event, or
call recap** (“quote my Acme call”, “today’s meeting”, “the notes on my
calendar”):

1. Use **Google Calendar** — not Salesforce — to find the event. If
   Microsoft 365 is on and exposes calendar events, same intent.
   - Search by account name + today / this week. Do not dump the calendar.
   - Several matching events: ask which row. Do not guess.
   - Calendar off or missing: say so and ask them to enable **Google
     Calendar** on this chat. Do not invent an event. If they said
     “email,” follow **Inbound quote from email** instead.
2. **Read the recap now.** Do **not** ask whether to open the notes. Do
   **not** wait for “read the recap” or “pull in those details.”
   - Event description first, if it already has product/qty.
   - Then any Drive Doc / Sheet / PDF attached to the event, or a Drive
     URL in the description. Call **Google Drive** immediately (same
     extract rules as inbound email step 2). Prefer a Sheet over a Doc
     or PDF when both exist.
   - Meet / Zoom **recording** links only: say you cannot transcribe
     video. Do not invent lines from the title.
   - Vague notes (“they want more licenses”) with no SKU or qty: show
     what you extracted and wait. Do not invent SKUs.
   - Drive off and the **only** lines are in an attached file: ask them
     to enable **Google Drive**. Do not invent SKUs.
   - Do **not** treat our Quote Proposal PDF as an inbound recap.
3. Map the event, then follow **Inbound quote from email** steps 3–8
   (extract, prospect, confirm, one Create Quote):
   - `accountName` / `opportunityName` / `quoteName` from the event
     title. Use a stable deal name (`Acme Expansion`), not
     `Acme <> AE weekly`.
   - `startDate` = the event date (`yyyy-mm-dd`). Do not ask if the
     event has a date.
   - `contactEmail` = the first attendee who is not the connected user
     / AE. Do not use your own address as the contact.
   - `linesJson` from the description or Drive notes.
4. Same ask again: `alreadyExisted` or Find Open Quotes, then update —
   never a second Draft.
5. A **later** meeting with updated qty / term: find that newest event
   and its notes, then follow **Follow-up email (qty / term revision)**
   steps 3–6. Do not create another quote.

If they named **both** a meeting and an email: Calendar for the pin
(`opportunityName`, `startDate`, attendees) and notes; Gmail only if the
event has no usable lines.

Never create, update, or delete calendar events. Never send a calendar
invite.

## Inbound quote from email

If they say **update / revise / latest quantities** on an existing quote,
or the newest mail is clearly a change to a deal already quoted, skip this
section and follow **Follow-up email (qty revision)** below. If they named
a **call / meeting / calendar recap**, use **Inbound quote from calendar**
instead.

When the user asks to **build a new quote** from email (“latest Acme email”,
“the customer request in my inbox”, a named sender):

1. Use **Gmail** or **Microsoft 365 / Outlook** — not Salesforce — to find
   and read the message. Skip `getRevenueCloudQuotingCatalog`.
   - Gmail: `search_threads` with `in:inbox newer_than:2d` (add the company
     name from the prompt when they named one), newest first. Then
     `get_thread` on the first match. Do **not** search
     `quote OR pricing OR quotation` over 30 days.
   - Outlook: the mail search/read tools that connector exposes. Same
     intent — newest inbox, not a month of keyword OR.
   - Search narrowly. Do not dump the inbox.
   - If those connectors are missing or off, say so and ask them to enable
     Gmail or Microsoft 365 on this chat, or paste the email. Do not invent
     an inbox.
2. **Spreadsheet or PDF in that mail — open it now.** After you have the
   message, look for a Google Sheet / Drive / PDF URL
   (`docs.google.com/spreadsheets`, `drive.google.com`, a `.pdf` Drive
   link), or Gmail “inserted from Drive” attachment metadata (file id or
   URL, including PDF). If any of those exist:
   - Call **Google Drive** immediately (the search / open / read tools that
     connector exposes). Do **not** ask whether to read the file. Do **not**
     wait for “read the sheet,” “read the PDF,” or “pull in those details.”
   - Map product/qty to `linesJson`: Product / SKU / Name / Item →
     `product`; Quantity / Qty → `quantity`. A Discount / Discount %
     column or mention is discount language, not a price override. Ignore
     Unit Price / List / Amount — Create Quote prices from Salesforce.
   - Prefer a **Sheet** over a PDF when both exist; reconcile, do not drop
     sheet rows. Prefer file rows over a vague body (“please quote the
     attached”). If the body also names products, reconcile; do not drop
     file rows.
   - Several PDFs: pick the one named quote / RFP / BOM / request, or ask.
     Do not merge blindly.
   - Recap the parsed lines on the confirmation card, then continue. If
     you cannot find readable products, show what you extracted and wait.
     Do not invent SKUs.
   - Scanned / image-only PDF: try Drive; if there is no selectable text,
     say so. A PDF uploaded in this chat is the fallback (you can read
     pages there).
   - Drive off or missing, and the **only** lines are in the Sheet or PDF:
     stop and ask them to enable **Google Drive** on this chat. Do not
     invent SKUs.
   - Drive off, but the body already has product/qty: quote from the body
     and say the file was skipped because Drive is off.
   - A downloaded `.xlsx` / `.csv` / `.pdf` attached as a normal email
     file, with **no** Drive URL: Gmail cannot read the cells or pages.
     Say that. Same fallback (body lines, or stop). Do not invent lines
     from the filename.
   - A spreadsheet or PDF uploaded in this Claude chat: read that file
     the same way.
   - Do **not** treat our **Quote Proposal** PDF (`previewRevenueCloudQuoteDocument`
     / `pdfUrl`) as an inbound customer request.
3. Extract: sender name and email, account hint, products and quantities
   (from the sheet or PDF when step 2 ran),
   term, discount language, **new sale vs change to something they already
   own**. If this company is **not in Salesforce**, skip
   `getRevenueCloudInstalledBase`. If they already own that SKU
   (`getRevenueCloudInstalledBase`), this is an **amend**
   (`amendRevenueCloudAsset` with a delta and `startDate`), not a new
   quote. Pass `opportunityName`.
4. Do **not** query `Product2` (or the catalog) with SObject All. Create Quote
   resolves product names. Use SObject All only when the sender is unclear,
   or Asset when this looks like an amendment. If **no Account** matches the
   company:
   - If this prompt already asked to create the account / contact /
     opportunity / quote from the email, **that is the confirm**. Go to
     step 6 in **this turn**. Do not wait for a second yes. Do **not**
     call `createRevenueCloudProspect`.
   - Otherwise show the parsed company/contact/lines and wait, then
     step 6.
   Never SObject-insert `Account`, `Contact`, `Opportunity`, or `Quote`.
   Create Quote creates Account, Contact, and Opportunity when those
   fields are passed. If a similar account exists, Create Quote asks —
   do not create a duplicate.
5. If they already named a **new** Opportunity, or already said to create
   the deal from this email, do **not** stop to confirm the Opportunity
   and do **not** ask which existing Opportunity to use.
   Otherwise show a short confirmation card (account, lines) and wait.
6. One mix: **one** `createRevenueCloudQuote` call. Do **not** call
   `createRevenueCloudProspect`. Do **not** recap, discuss mailing the
   customer, or call any other quoting tool until it returns. Do **not**
   call `addProductToRevenueCloudQuote` per SKU. Do **not** call
   `buildRevenueCloudQuoteOptions`. Pass:
   - `accountName`
   - `quoteName` (stable name from the subject or the name they chose)
   - `opportunityName` (**required** when the account has several open
     deals — never omit it on Acme)
   - `contactFirstName` / `contactLastName` / `contactEmail` from the
     email (required when the company is not in Salesforce)
   - billing street/city/state/postal/country from the email when present
     (`useDemoAddress=true` only if they confirmed a demo address)
   - `termMonths` from the email (12 if they asked for 12 months)
   - `linesJson`: `[{"product":"QuantumBit Database","quantity":10}, ...]`
     using the names from the sheet or PDF when step 2 ran, otherwise the
     email body. Put **Q-Rack 750** last in that array. **Q-Rack 750**
     (and other One-Time hardware bundles): pass `quantity` **1**, even
     if the mail asked for 8. Qty > 1 fails Salesforce bundle validation
     (`Cannot have a fractional quantity` on a child component). If Create
     Quote still reports that error, immediately
     `addProductToRevenueCloudQuote` with that product at quantity 1. Do
     not create another quote. Say it is sold per rack.
   If Create Quote returns `alreadyExisted=true`, **do not add lines**.
   Call `updateRevenueCloudQuoteLines` or `addProductToRevenueCloudQuote`.
   If the message says they already own a product, confirm amend vs new
   sale before submitting.
   - Describe/configure only if a returned line is a bundle that still needs
     picks. Discount only if the email, sheet, or PDF asked for one.
7. Recap only after Create Quote returns. Use `linesDisplay` (or the
   line list in `message`) and render **Open Account** / **Open Contact** /
   **Open Opportunity** / **Open Quote**. Do **not** discuss mailing the
   customer. Do **not** call
   `previewRevenueCloudQuoteDocument` unless they asked for the order form,
   proposal, or PDF. Do **not** call `getRevenueCloudQuoteSummary`.
8. **Never** `send_message`, `reply`, Outlook send, or email a PDF to the
   customer. Draft a reply only if they explicitly ask — leave it unsent.
   Do not write “reconciling totals” or wait messages. If they already said
   to create a new Opportunity, do not ask which existing one to use.

## Add products to an existing Draft

When the user wants to **add** a catalog product to a quote that already
has lines (new SKU, not a quantity change on an existing line):

1. Call **`addProductToRevenueCloudQuote` once** with that `quoteId` and
   `linesJson` for every new SKU. Do not add-product per SKU. Do not
   retry other payload shapes.
2. **Term.** New lines inherit the quote `StartDate` / `EndDate`. If the
   quote is 36 months, the new line is 36 months. Pass `termMonths` (or
   a per-row `termMonths` in `linesJson`) **only** when they said this
   SKU should be a different term (for example 12 months). Do **not**
   call `updateRevenueCloudQuoteLines` afterward just to stretch the
   new line to the quote term.
3. **Discount.** Do not apply the quote’s existing percent off to the
   new line unless they asked. If they said not to discount this line,
   add only — never `applyRevenueCloudQuoteDiscount` in the same turn.
4. Recap `lineSummaryDisplay` (includes the inherited term) and
   **Open Quote**. Stop.
5. Do **not** call `explainRevenueCloudQuotePrice` after add unless they
   asked why the price is what it is. Do **not** preview the PDF. Do
   **not** `getRevenueCloudQuoteSummary` unless the add tool timed out.
6. If Add Product fails with a connector timeout (`isn't responding`)
   or similar: **do not retry add**, do not explain, do not preview.
   Call `getRevenueCloudQuoteSummary` once and Open Quote — the line
   often already committed. Then stop.

## Update quantity, term, start date, discount, or quote name

Works from **chat** (verbal request) or from email. No inbox required.

When the user wants to change quantity, **remove a line**, subscription
term, start date, a percent off, and/or the **quote name** on a Draft
quote:

1. Call **`updateRevenueCloudQuoteLines` once** with the `quoteId` you already
   have. Pass `quantitiesJson`, `termMonths`, `startDate`,
   `discountPercentage`, and `quoteName` in the **same** call when they
   asked for more than one of those. Rename only when they asked — do
   not invent a new name after a term change. To **remove** a parent
   line, pass quantity `0` or `"remove":true` (e.g.
   `[{"product":"Software Maintenance","quantity":0}]`). Do not set
   quantity 0 on a bundle child — remove or reconfigure the parent.
   ```json
   [{"product":"QuantumBit Database","quantity":20},{"product":"Q-Rack 750","quantity":3}]
   ```
   Convert spoken terms to months (`5 years` → `termMonths=60`). Convert
   spoken dates to `yyyy-mm-dd` (`12/1/2026` → `startDate=2026-12-01`).
   Keep the existing start date **only** when they did not give a new one.
2. Do **not** rebuild the quote. Do **not** create a new Opportunity. Do
   **not** call `buildRevenueCloudQuoteOptions` for a term change. Do
   **not** call `addProductToRevenueCloudQuote` to “add the difference.”
   Do    **not** update `Quote` or delete `QuoteLineItem` with SObject All. Do
   **not** tell them to edit dates or delete lines in Salesforce. Do
   **not** rebuild the quote to drop a line.
3. Do **not** also call `applyRevenueCloudQuoteDiscount` in the same turn
   when `discountPercentage` was already passed.
4. Recap `resultsDisplay` and **Open Quote**. If they also asked for an
   email or draft, call **`draftRevenueCloudCustomerReply` next** — do
   **not** preview the PDF, do not explain, do not poll, do not compare
   the old PDF. Quantity `0` is the remove format; do not retry other
   shapes. Do not preview the PDF unless they asked for the pack or
   order form.
5. **What-if / TCV.** If they said “what if,” “make it *n* months,” a
   percent off, or “what does *n* more seats do” (to price or TCV): after
   the update, call **`getRevenueCloudBillingAndUsage`** with that
   `quoteId` and recap GrandTotal as TCV. Call explain only if they also
   asked why the price changed. Never rebuild. Never Build Quote Options
   for a term or discount tweak. Never preview the PDF.

Discount-only (no qty change): `applyRevenueCloudQuoteDiscount` with
`applyToAll=true` is fine. Then the same TCV recap when they asked what-if.

## Follow-up email (qty / term revision)

When a later email from the same customer has updated quantities or term
(days later is fine):

1. Use **Gmail** or **Outlook** to find the **newest** message from that
   customer (newest first). Read that message. Do not treat the original
   request as the source of truth for quantities or term.
2. If **this** message has a Drive Sheet or PDF (link or Drive-attached),
   or they uploaded a spreadsheet/PDF in this chat, open it now (same
   rules as inbound quote step 2). Do not wait to be told. Extract products
   and quantities from that file when present, otherwise from this email
   body, plus term (`2 years` → 24 months) and a percent off if they asked.
   Leave lines they did not mention unchanged.
3. Resolve the existing **Draft** quote:
   - Use the `quoteId` already in this chat if you have one.
   - Else **`findRevenueCloudOpenQuotes`** with `accountName` **and**
     `opportunityName` from the original email/subject. Never query
     `Quote` or `Product2` with SObject All.
   - If that Opportunity has exactly one Draft, use `latestQuoteId`.
   - If more than one Draft matches, ask which row. Do **not** guess
     and do **not** create another quote.
4. Call **`updateRevenueCloudQuoteLines` once** with that `quoteId`,
   `quantitiesJson`, and `termMonths` / `discountPercentage` when present.
   **Required:** `fromEmail` = Gmail/Outlook **From mailbox** (e.g.
   `crieger@salesforce.com`) and `fromName` = From display (e.g. Bryce
   Majors). Do **not** omit this. Quote Contact (Jordan Hale) is **not**
   the sender unless From matches.
5. Do **not** `createRevenueCloudQuote`. Do **not** rebuild. Do **not** call
   `buildRevenueCloudQuoteOptions`. Do **not** add delta lines. Products in
   the follow-up that are **not** on the quote: **one**
   `addProductToRevenueCloudQuote` with `linesJson` for every new SKU.
   Do not add-product per SKU. New lines inherit the quote term; do
   not pass `termMonths` unless they asked for a different term on
   that SKU. Do not explain or preview after add.
6. Recap `resultsDisplay` / `lineSummaryDisplay` (including the sender
   picker) and **Open Quote**. No PDF unless they asked. Never send mail
   to the customer.
7. If `needsAction` is true, that sender picker **is** the Next line —
   **wait**. Do not add ramp / submit / pack. Do not skip because the
   quote already has a Contact.
8. If the recap has no sender picker, call
   `checkRevenueCloudSenderContact` with the same From. Never invent
   email from the body. If Gmail did not return From, say so and stop.

## Sender contact on an existing account (required)

When you just applied a follow-up email to an existing Account:

1. The update/add result already includes the sender picker when you
   passed `fromEmail`. Recap it. If you omitted From, the recap will
   say Quote Contact is not the sender — call again with `fromEmail`.
2. If `needsAction`, **stop and wait**.
3. After they pick: **one** `addRevenueCloudAccountContact` with
   `accountName`, names from From display, `contactEmail` = From,
   `quoteId` when you have it, `action=setEmail` only when they chose
   set. If the email signature or body has a **title**, **phone**, or
   **mailing address**, pass `title`, `phone`, and `mailingStreet` /
   `mailingCity` / `mailingState` / `mailingPostalCode` /
   `mailingCountry`. Omit any that are not in the email. Never invent.
   Recap `resultsDisplay` + Open Contact.
4. Skip = stop. Never Create Prospect. Never SObject-insert Contact.

## Installed base (what they own)

When the user asks what an account owns, their MRR, ARR, **current
discount**, asset lifecycle, state periods, asset actions, or how often
they add on:

1. Call **`getRevenueCloudInstalledBase` once** with `accountName`.
2. Recap `summaryDisplay` (current MRR, derived ARR, per-product **Discount**
   from the current `AssetStatePeriod`, next period if a future upsell
   exists, add-on cadence) and **Open Account** / **Open Asset**.
3. Do **not** query `Asset`, `AssetStatePeriod`, or `AssetAction` with
   SObject All. Do **not** use `Asset.CurrentMrr` (it is often 0). Do **not**
   treat quote line `Discount` as what they own — that is a Draft quote.
   ARR is **derived** (MRR × 12); Salesforce does not store ARR.
4. To change quantity on what they own, that is an amendment
   (`amendRevenueCloudAsset`), not this recap.

## New prospect (not in Salesforce)

When Create Quote says no account matched, or the email is from a company
that is not in Salesforce:

1. If this prompt already asked to create the account, contact,
   opportunity, and quote from the email, **skip a second confirm**.
   Otherwise show the company name, contact, and email you extracted and
   **stop** before creating records.
2. **One** `createRevenueCloudQuote` with `accountName`,
   `contactFirstName` / `contactLastName`, `contactEmail`, billing
   address from the email (or `useDemoAddress=true` only after they
   confirm a demo address), `opportunityName`, `quoteName`, `termMonths`,
   and `linesJson`. That call creates Account, Contact, Opportunity, and
   Draft. Do **not** call `createRevenueCloudProspect`. Never
   SObject-insert `Account`, `Contact`, or `Opportunity`.
3. If the message asks which similar account to use, ask reuse vs create.
   Do not insert a duplicate.
4. Recap only after that call returns. Render **Open Account** /
   **Open Contact** / **Open Opportunity** / **Open Quote**.

## Which quote (several Drafts)

When the user says “the Acme quote” and more than one Draft might exist,
or a follow-up email has no `quoteId` in this chat:

1. Call **`findRevenueCloudOpenQuotes`** with `accountName` and
   `opportunityName` when you have it (email subject / named deal).
2. Recap `summaryDisplay` and **Open Quote** links. If more than one row,
   **ask which**. Use `latestQuoteId` when that Opportunity has one Draft
   or they said the latest / newest.
3. Do **not** query `Quote` with SObject All. Do **not** create a quote.

## Quote vs installed base

When they ask whether quote qty/discount matches what they own, or mix
a Draft 30% off with owned 8% off:

1. Call **`compareRevenueCloudQuoteToInstalledBase`** with `quoteId` (or
   quote name / account).
2. Recap `summaryDisplay`. Quote Discount is the Draft; owned Discount is
   `AssetStatePeriod`.
3. Do **not** use `Asset.CurrentMrr`. Do **not** treat quote lines as
   ownership.

## Deal status (where is this quote)

When they ask if a quote is submitted, approved, ordered, or has assets:

1. Call **`getRevenueCloudDealStatus`** with `quoteId` (or name / account).
2. Recap `summaryDisplay` and **Open Quote** / **Open Order** / **Open Asset**.
3. Do **not** submit, create an order, or activate unless they asked for that next.

## Renew or cancel an asset

1. Confirm the account, product, and **cancel vs renew**. For cancel, **stop and
   confirm** before calling the tool.
2. Get a start date and convert it to `yyyy-mm-dd`. Required for cancel.
   Required for early or expired renewals. Do not assume today.
3. Call **`renewOrCancelRevenueCloudAsset`** with `action=renew` or
   `action=cancel`. Prefer `assetId` when known. Pass `opportunityName`
   when this is tied to an email/deal.
4. Then create an order from the returned quote and activate it. Never PATCH
   `Asset`. Never use amend for a full cancel/renew.

## Draft a customer reply (unsent)

When they ask to draft a reply, recap the quote for the customer, or write
email text:

1. Call **`draftRevenueCloudCustomerReply`** with the quote (or account).
   That tool already public-links the **latest PDF on the quote**. Do
   **not** preview first.
2. Show `subject` and `bodyDisplay` in chat. Render `coachDisplay` in
   chat only (Open Quote / Open PDF for the AE).
3. If Gmail exposes a **draft / create draft** tool, put `subject` and
   `bodyDisplay` there **verbatim**. `bodyDisplay` is **HTML** — prefer
   `html` / `body_html` / `isHtml=true` when the tool has that. Keep the
   `<a href>` “proposal PDF” link. Do not paste the raw URL. Do not
   rewrite. Do not add bundle children. Do not add Salesforce or
   Lightning URLs. If that tool can attach a file, attach the proposal
   PDF. If it cannot, tell the AE to attach it from **Open PDF** and
   leave the draft unsent. If the tool is absent, leave the draft in
   chat and say “copy to Gmail compose.”
4. **Never** `send_message`, Gmail send, or Outlook send. Even if they say
   “send it,” refuse send from this skill.

## Add a PDF link to an existing draft

When they already have an unsent Gmail draft and ask to **add the PDF**,
**put the PDF link in the email**, or **include the proposal**:

1. Call **`draftRevenueCloudCustomerReply` once**. Do **not**
   `previewRevenueCloudQuoteDocument`. Do **not** explain. Do **not**
   poll. Generating a PDF is the slow path — skip it when a file
   already exists on the quote.
2. If `publicPdfUrl` is set (or `bodyDisplay` has the “proposal PDF”
   `<a href>`), **update the existing Gmail draft** with that HTML.
   Keep the rest of the draft when you can; otherwise replace the body
   with `bodyDisplay`. Do **not** create a second draft. Do **not**
   `reply` on a thread.
3. Preview **only** if `publicPdfUrl` is blank **and** `pdfUrl` is blank
   (no PDF on the quote). Then preview until `pdfUrl` in this turn, call
   draft once, and update the Gmail draft. That generate path is the
   slow one.
4. Never send.

## Customer pack (explain + PDF + unsent draft)

When they ask to **prepare the customer pack**, **ready the proposal**,
or **explain + PDF + email** for a named quote:

1. Resolve the quote (`quoteId` in this chat, else Find Open Quotes with
   `opportunityName`). Ask only if several Drafts match.
2. Call **`explainRevenueCloudQuotePrice` once**. Render `explanationDisplay`.
3. Call **`previewRevenueCloudQuoteDocument`** (RLM_QuoteProposal) with
   `regenerate=true` only when they asked for a **new** PDF. On
   `isPartial` or `RETRY_NOW`, call again **immediately** with `quoteId`
   and `documentGenerationProcessId`. **Never** wait, sleep, Pause, or
   ask the user to prompt again. Keep going until `bodyDisplay` is set
   or `errorMessage` is set (safety cap 8). Finish Gmail in **this
   turn**. Do not start a second generation.
4. **When `bodyDisplay` is set:** put `subject` and `bodyDisplay` into
   Gmail **verbatim** as HTML. If a draft already exists, **update it**.
   Otherwise create a **new** Gmail draft (not a reply).
   **Never** call `draftRevenueCloudCustomerReply` after preview —
   `bodyDisplay` is already on the preview result. Keep the “proposal
   PDF” `<a href>`. No `/lightning/r/` URLs. **Never send.**
5. Do not submit, order, or activate as a side effect of the pack.

## Close this deal (submit → order → activate)

When they ask to **close this deal**, **take it to an order**, **finish
the deal**, or **activate** a named quote (not a cancel):

1. Resolve the quote (`quoteId` in this chat, else Find Open Quotes with
   `opportunityName`). Ask only if several match.
2. Call **`getRevenueCloudDealStatus`**. If an order or assets already
   exist, recap and stop — do not submit again.
3. If the quote is Draft and has lines: **`submitRevenueCloudQuoteForApproval`**.
4. If it is waiting on approval:
   - This user is the assignee: **`decideRevenueCloudQuoteApproval`**
     `decision=approve`.
   - Otherwise **stop**. Say it is waiting on the assignee. Render
     **Open Quote**. Do not invent an approval. Do not PATCH Quote.Status.
5. **`createRevenueCloudOrderFromQuote`**. Retry `isPartial` with the same
   quote. Do not insert `Order`.
6. **`activateRevenueCloudOrder`** unless they asked for a draft order
   only. Retry `isPartial` (cap 3).
7. Call **`getRevenueCloudInstalledBase`** and recap. Render **Open Quote**,
   **Open Order**, and each **Open Asset**.
8. Never PATCH Asset. Never send mail. Never skip step 4 when approval is
   still assigned to someone else.

## Ramp on an existing quote

Create Ramp Schedule (the standard Salesforce modal — not Ramp Builder):

1. Call **`createRevenueCloudRampSchedule`** with `quoteId`, `segmentType`
   (`Annual` or `Custom`), `startDate`, `durationMonths`, optional
   `prorationPosition` (`End` or `Beginning`), and optional `trial` +
   `trialDuration` / `trialUnit`. Default is preview only.
2. Recap the preview table. If they asked to create, call again with
   `confirm=true` in **this turn**. If they are comparing scenarios,
   preview each option and wait with a numbered picker.
3. The created schedule is **empty**. Then
   **`applyRevenueCloudQuoteRamp`** with `productName` and
   `segmentsJson` `[{"quantity":10},{"quantity":20},{"quantity":30}]`.
   10/20/30 is Years 1–3. Also put the product on Trial (Year 1 qty,
   trial discount) and on a prorated stub (last year qty). A trial
   without the SKU is empty.
4. After the schedule exists, **one** `applyRevenueCloudQuoteRamp` with
   `editsJson` for per-year add / remove / qty / discount. Examples:
   `[{"product":"Q-Rack 750","segments":["Year 2","Year 3"],"quantity":1}]`,
   `[{"product":"QuantumBit Database","segments":["Trial"],"remove":true}]`,
   `[{"segments":["Year 2"],"discount":25},{"segments":["Year 3"],"discount":35},{"product":"QB-PowerSafe 1000D","segments":["Year 3"],"discount":20}]`.
   Omit `product` = stamp that percent on **every** line in those years
   (parents and bundle children). A later named row overlays that SKU
   only. Qty / remove still require a parent SKU — never a child.
   Omit `segments` (or `all`) = every ramped group. `paid` skips Trial.
   Aliases: Trial, Y2, year 2, prorated, stub, Year 4. Combined add +
   remove + discount in **one** `editsJson`. Do **not** call
   `updateRevenueCloudQuoteLines`, `addProductToRevenueCloudQuote`, or
   `applyRevenueCloudQuoteDiscount` — those cannot target a year.
5. Describe only: `applyRevenueCloudQuoteRamp` with `quoteId`.
6. Do not open Ramp Builder. Do not SObject-insert `QuoteLineGroup`.
   Do not rebuild the quote. Create does not edit an existing schedule.

## Next bill, TCV, and usage

When they ask what they will be billed next, TCV, or usage consumed:

1. Call **`getRevenueCloudBillingAndUsage`** with `accountName` (and `quoteId`
   when the TCV is for a specific Draft).
2. Recap `summaryDisplay`. **TCV is quote GrandTotal**, not ARR, not
   `Asset.CurrentMrr`. ARR stays MRR × 12 from installed base.
3. Do **not** query `BillingSchedule`, `Invoice`, or `UsageSummary` with
   SObject All.

## Bundle configuration

After create / add / ramp, if the recap `needsAction` for a bundle (parent
only, Instant Pricing on the parent is not done): describe **in this turn**
with `quoteId` and `quoteLineItemId` from the recap, then **wait**. Do not
skip because the parent has a price. Do not use add-product to “add CPU as
a standalone line.” Do not PDF / email / submit until configure returns
`needsAction` false.

1. Describe first (`quoteLineItemId` when the same SKU is on more than one
   ramp year). If it fails, show the error and stop.
2. Offer **only** the groups and products describe returned. Never invent
   groups or SKUs. Required options stay selected.
3. Tell the user why items are already checked: required, catalog default
   (the bundle’s starting mix), or already saved on the quote. Do not imply
   they configured those themselves unless the line says already on this quote.
4. **Stop. Do not call Configure yet.** Run the keep-or-drill picker
   (below). Hold picks in chat. **One configure after Step 2** — do not
   persist between waits.
5. After Step 2, Configure with those names/SKUs, `attributePicksJson`,
   and the same `quoteLineItemId`. Never insert child `QuoteLineItem`s. Do
   not add the same bundle parent twice. Never invent attribute values.
6. If configure `needsAction` is still true (CML / required / price-impacting
   attributes still blank), show those messages, wait, and configure again.
   Do not proceed.
7. After a clean save, the same mix is copied to other unconfigured ramp
   years of that SKU. Recap which years were copied. If they asked for a
   different mix per year, describe that year’s `quoteLineItemId` instead.

### Picker (required after every successful describe)

The chat cannot host a true checkbox widget. **Do not** dump every
alternate value or SKU on the overview (no 22-chip wall, no 1–69 list).
**Do not** ask them to pick a category as a meta-step. Describe is for
you to read; the user sees a **keep-or-drill** flow. Hold picks until
the end, then **one** `configureRevenueCloudBundle`.

**Step 1 of 2 — Attributes.** Opening line: we are setting product
attributes (some affect price). Bullet every current value; mark
**affects price**; `(not set)` on blanks. Chips: `Keep all current
attributes`, then each **attribute name** (not its values). Ask: **Keep
these, or pick which attributes to change?** They can answer `1` or
`3 and 6` in one reply.

Keep all → go to Step 2, except **required blanks still get a card**.
Change named attrs → one card each: current value, Keep that value,
other options (~60 chars). Unnamed attrs keep describe values. Never
invent. Skip hidden / read-only (already omitted).

**Step 2 of 2 — Add-on products.** Same shape. Bullet what’s already
`[x]` per **leaf group** that has SKUs (skip empty parents like
Computing). Chips: `Keep all catalog add-ons`, then each **group name**
(not SKUs). Named groups get one card: Keep this group, then optional
adds (and optional remove of a non-required default). Required
mentioned, not removable.

After Step 2, configure with current `[x]` items plus
`attributePicksJson`. Send **every** attribute key — Keep all still
sends the describe values. A defaulted price-impacting attribute is not
done until it is sent.

Example Step 1 overview (use real names from describe, not this sample):

```
**Step 1 of 2 — Attributes**
These specify the rack. Workload affects price. Current:

- Workload: General — affects price
- Performance Tier: Standard
- Socket: Single
- Redundancy: (not set) — needs a pick

1. Keep all current attributes
2. Workload
3. Performance Tier
4. Socket
5. Redundancy

Keep these, or pick which attributes to change?
```

Example drill card after they pick Workload:

```
Workload is General — affects price. Keep it, or pick another?

1. Keep General
2. AI
3. High Performance Computing

Keep this attribute or change it?
```

Example Step 2 overview:

```
**Step 2 of 2 — Add-on products**
Catalog defaults already on. Keep them, or pick which groups to change.

- Memory: QB-MEM 32GB
- GPUs: none
- Power Supply: PowerSafe 2000D

1. Keep all catalog add-ons
2. Memory
3. GPUs
4. Power Supply

Keep these add-ons, or pick which groups to change?
```

Never invent values. Never persist between waits.

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

Call this tool **only** when the user asks to preview the order form, quote
proposal, or PDF. Never preview as a side effect of create, add-product, or
building a quote from email.

When they do ask:

1. Call `previewRevenueCloudQuoteDocument`. Default template is
   **RLM_QuoteProposal** — do not pass `templateName` unless they named a
   different Active template. Do not use `Order_Form` (it is Draft).
2. Do **not** insert `ContentVersion` or generate a Word/PDF yourself. Do
   **not** query `DocumentGenerationProcess` with SObject All.
3. If `isPartial` is true **or** `message` starts with `RETRY_NOW`:
   - Do **not** write anything to the user (no “generating”, no “please wait”).
   - **Never** use a Wait tool, sleep, bash `sleep`, or “Wait for the
     PDF to finish generating.” Call the same tool **immediately**.
   - Call again with `quoteId` and `documentGenerationProcessId` from
     the last result.
   - Repeat until `pdfUrl` / `bodyDisplay` is set or `errorMessage` is
     set (safety cap 8). Finish in **this turn**. Never ask the user to
     prompt again. Do not start a new generation. Do not Pause.
4. When `pdfUrl` is set, render **Open PDF** and **Open Quote**. Preview
   also returns `publicPdfUrl` and HTML `bodyDisplay`. Use those for
   email. Do **not** call `draftRevenueCloudCustomerReply`.
5. A later preview of the same unchanged quote returns the existing PDF on
   the first call. Do not start a new generation and do not tell the user
   you are regenerating.

When they ask to **regenerate the PDF and refresh the email draft**:

1. Call `previewRevenueCloudQuoteDocument` with `regenerate=true`.
2. Poll as above — **immediately**, never wait/Pause. Stay in this turn
   until `bodyDisplay` is set.
3. When `bodyDisplay` is set, **update the existing Gmail draft** with
   that HTML. Keep the proposal PDF `<a href>`. **Never** call
   `draftRevenueCloudCustomerReply`. Do **not** create a second draft.
   Never send. Never ask them to prompt again.

## Order and assets

If they asked to **close this deal** / take it to an order **and
activate**, follow **Close this deal** (submit and decide first). For
order-only or activate-only:

1. Create the order from the quote (`createRevenueCloudOrderFromQuote`). If
   `isPartial` (quote still pricing), call again with the same quote. Do not
   insert an `Order`.
2. Then activate (`activateRevenueCloudOrder`) unless the user only wanted a
   draft order. If `isPartial`, **immediately call again** with the same
   `orderId` (up to 3 times) until `isPartial` is false or there is an error.
3. Render **Open Order** and each **Open Asset** link. Assets are created
   asynchronously after activation; an empty first activate is normal.

The account must have a Contact (Bill to Contact) and a billing or shipping
address. Create Quote writes those when you pass an address or confirmed
`useDemoAddress` on a new-prospect create. It stamps `Quote.ContactId` from
`contactEmail` or the account contact. If activation still says those are
missing, tell the user — do not invent a customer HQ.

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
   this tool with that product name. Pass `opportunityName` when this came
   from an email thread. The tool amends the top-level parent and
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
  handles that. Q-Rack 750 / One-Time hardware bundles: add at **quantity 1**.
  On `Cannot have a fractional quantity` with qty > 1, retry add at
  quantity 1 once and say it is sold per rack. Do not drop the other lines.
  Do not create a second quote. Other save failures: show the Salesforce
  error and stop.
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
- Quote document preview / draft the current quote email: Preview until
  `bodyDisplay` **in this turn**. Never wait, Pause, or ask the user to
  retry. Success returns `bodyDisplay` + `publicPdfUrl` — update Gmail.
  **Never** `draftRevenueCloudCustomerReply` after preview.
- Customer pack: explain once, preview until `bodyDisplay` in this
  turn, then Gmail that HTML. Never Draft after Preview. Never send.
  Never put an AE derived-price note in the customer email.
- Close this deal: deal status first; submit Draft; decide only if this
  user is the assignee; else stop. Then order + activate + installed
  base. Never PATCH Quote.Status or Asset.
- What-if on a Draft: one Update Quote Lines, then TCV from
  `getRevenueCloudBillingAndUsage`. Never rebuild.
- Next-best-action: one Next line after every successful mutate.
- Inbound calendar / call recap: Google Calendar (or Microsoft 365
  calendar) for read only. Never create, update, or delete events. Never
  send a calendar invite. Open the event description and Drive notes
  immediately — do not wait to be told. Recording-only events cannot be
  transcribed; say so. `startDate` from the event. `contactEmail` from a
  customer attendee, not you. Same create/reuse/amend rules as inbound
  email.
- Inbound email: Gmail/Outlook for read only. Never send mail to the
  customer. Drive Sheet or PDF (link or Drive-attached), or a file
  uploaded in this chat: open it immediately and quote those lines — do
  not wait to be told. Prefer a Sheet over a PDF when both exist. A
  downloaded `.xlsx` / `.csv` / `.pdf` with no Drive URL cannot be read;
  say so. Do not treat our Quote Proposal PDF as an inbound request.
  Always pass `opportunityName` + `quoteName`. New mix: one create with
  `linesJson`. Same request again: `alreadyExisted` or
  `findRevenueCloudOpenQuotes` then update — never a second Draft. No
  account: one Create Quote with contact names, email, and address
  (that call creates Account + Contact + Opportunity). Skip catalog.
  Gmail `in:inbox` newest — not a 30-day OR search. Recap only after
  Create Quote returns. If they already said to create them from the
  email, do not wait for a second confirm. Never call
  createRevenueCloudProspect when quoting. Never SObject-insert
  Account, Contact, or Opportunity. They already own the SKU: amend, not
  create.   Follow-up qty email: newest message (and its sheet/PDF if
  present), find with `opportunityName`, then one
  `updateRevenueCloudQuoteLines` with `fromEmail` = Gmail From. New SKUs
  on that Draft: one add with `linesJson` (inherits quote term; recap
  only — never explain or preview after add). Recap the sender picker
  (never invent email). After they pick: `addRevenueCloudAccountContact`
  with title/phone/address from the signature (omit if absent; never invent).
  Never Create Prospect. Never SObject-insert Account or Contact.
  Never SObject All on Product2, never add-product per SKU, never Build
  Quote Options, never summary, never preview unless they ask.
- Quote vs owned: `compareRevenueCloudQuoteToInstalledBase`. Do not mix
  quote Discount with `AssetStatePeriod.Discount`.
- Deal status: one `getRevenueCloudDealStatus`. Read only.
- Renew/cancel: confirm cancel, then `renewOrCancelRevenueCloudAsset`. Then
  order + activate. Never PATCH Asset.
- Customer reply after a line change: update once (quantity 0 to
  remove), then `draftRevenueCloudCustomerReply`. That includes a
  customer-safe PDF link from the latest file. Do not preview or wait
  for a new PDF. Gmail draft/create with `bodyDisplay` verbatim.
  No Lightning URLs. Never send mail.
- Add a PDF link to an existing unsent Gmail draft: one
  `draftRevenueCloudCustomerReply`, then update that Gmail draft.
  Never preview. Never explain. Never a second draft. Never send.
- Ramp: `createRevenueCloudRampSchedule` previews then creates the
  empty schedule. `applyRevenueCloudQuoteRamp` first-add 10/20/30 or
  `editsJson` add/remove/qty/discount by year. Never
  `updateRevenueCloudQuoteLines` or add-product on a ramped quote.
  Never Ramp Builder.
- Approver: `decideRevenueCloudQuoteApproval`. Never PATCH Quote.Status.
- After reconnect: `getRevenueCloudQuotingCatalog`, then find with
  `opportunityName`.
- Next bill / TCV / usage: `getRevenueCloudBillingAndUsage`. TCV ≠ ARR.
- Qty, remove a line (quantity 0), term, start date, discount, or quote
  name on an existing Draft quote: one `updateRevenueCloudQuoteLines`
  (`termMonths`: 5 years = 60; `startDate`: yyyy-mm-dd; `quoteName` to
  rename). Never rebuild. Never SObject-update Quote. Never
  SObject-delete QuoteLineItem.
  Never Build Quote Options for a term change. Never add extra lines for a
  quantity change.
- Add a SKU to an existing Draft: one `addProductToRevenueCloudQuote`
  with `linesJson`. New lines inherit the quote term unless they asked
  for a different term on that SKU. Recap `lineSummaryDisplay` + Open
  Quote. Never explain or preview after add. On connector timeout, do
  not retry add — summary once, then stop.
- Installed base / MRR / ARR / current discount / add-ons: one
  `getRevenueCloudInstalledBase`. Discount is `AssetStatePeriod.Discount`.
  ARR = current period MRR × 12. Never `Asset.CurrentMrr`. Never quote lines
  as ownership.
