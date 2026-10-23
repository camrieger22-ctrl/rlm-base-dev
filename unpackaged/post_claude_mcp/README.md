# Claude Hosted MCP — Revenue Cloud quoting

Custom Hosted MCP tools so Claude Desktop can ping the quoting catalog
after reconnect, create a Draft quote (and Account/Contact/Opportunity
when the company is new — pass contact names, email, and address on
Create Quote; do not call Create Prospect first), or **reuse**
the Draft on the same Opportunity and quote name, add several products
to an existing Draft via `linesJson`, list open Drafts filtered by
Opportunity, recap deal/approval status, approve or reject an assigned
work item, renew or cancel an asset, draft an unsent customer reply
(Gmail draft/create when that connector tool exists), preview or create
a standard ramp schedule then add products or patch segment quantities, recap next bill/TCV/usage, compare a quote
to installed base, patch quantity, term, and/or a percent
discount on existing Draft lines in one Place Sales Transaction, configure a
bundle (Lightning Constraint Rules Engine, then Place Sales Transaction), recap the quote, explain how a quote price was calculated, preview the
quote proposal PDF, submit it for approval, create an order from a quote,
activate that order (assets
follow), amend an existing asset, recap installed base (current period MRR,
derived ARR, add-ons), or build several commercial options under
one Opportunity. Backs the tools
with `global` invocables; add/discount/summary delegate to the existing
Quoting Assistant services. Bundle describe/configure call Lightning
Configure (`executeConfigurationRules=true`) so Dual/Gold/qty/auto-add come
from Constraint Rules Engine, then persist that graph through Place Sales
Transaction. Hosted MCP cannot `Http.send` that Configure call in the tool
transaction (uncatchable Script-thrown). The invocable upserts a Pending
`RLM_CreCalloutCache__c` row and returns `CRE_LOADING`; a record-triggered
Flow async path enqueues the Queueable Named Credential callout after that
transaction commits. The Queueable callout authenticates through Named
Credential `RLM_SalesforceLoopback` (OAuth client credentials in the org;
never a stored `UserInfo` session). Attribute apply uses the same
Pending-cache path so Dual does not EventBus.publish in the Hosted MCP
transaction. Claude retries describe/configure immediately. REST and
anonymous Apex still call Configure synchronously. Submit starts the `RLM_Quote_Smart_Approval` flow.
Create Order calls `createOrdersFromQuote`. Activate sets
`Order.Status = Activated` and lists resulting assets. Amend Asset calls
`initiateAmendment` (quote output); closing the amendment still uses create
order + activate. Decide Quote Approval calls `reviewApprovalWorkItem`
(approve/reject); the connected user must be an assignee. Create Ramp
Schedule previews then persists the standard empty group-ramp structure
(Annual/Custom, trial, prorated stub) through Place Sales Transaction —
not Ramp Builder. Apply Quote Ramp then adds a product across those
segments, patches quantities, or applies `editsJson` (add / remove /
qty / line discount on Trial, Year N, or the prorated stub). Sync Quote To Opportunity starts or stops the same
`Opportunity.SyncedQuoteId` link as Lightning Start Sync / Stop Sync —
only when they name the quote; never after create. Get Quoting Catalog returns the
skill version and tool count so a stale Claude connector is obvious. Explain Quote Price reads Quote / QuoteLineItem /
QuoteLineDetail (list, header discount, amendment slices, proration,
amount due) so a rep can walk the price even when amendment Net Unit
Price is blank on the line. It does not call the Connect waterfall GET
from Hosted MCP — those callouts hang or throw in that context and Claude
then spends minutes rebuilding the story via SObject queries. Preview Quote
Document starts `RLM_DocumentGenerationCreate` for **RLM_QuoteProposal**
(same path as Preview PDF). Salesforce finishes the PDF in about 10 seconds
after the transaction commits, so the first preview returns `isPartial`
(retry with the process Id until `pdfUrl` in the same turn). Later previews reuse that Success PDF when the quote has not
changed. Build Quote Options creates 2–5 Draft quotes on one named
Opportunity. Same mix with a new term or discount: `cloneRevenueCloudQuote`
once per option (in-process Place copy of the source lines) with
`clonedQuoteName`, `termMonths`, and `discountPercentage`. Do not rebuild
via Build Quote Options. Build Quote Options is for a **new** product mix only.

Create, add-line, clone, update-lines, Build Quote Options, and quote
summary append an **AE note** when a derived-price product (for example
Software Maintenance) is on the quote without its contributing SKUs.
That note is for Claude chat only — never the customer email. It names
the contributing products from live `PricebookEntryDerivedPrice` rows
and asks the rep to add one, add both, add/configure a bundle that
already includes those SKUs, or leave the line at $0. Claude must wait;
it does not auto-add. It does not offer “add Complete” on top of an
existing standalone mix (Database + Q-Rack + Maintenance).

A follow-up email on an existing account applies the quote tweaks
on `updateRevenueCloudQuoteLines` and **must** pass `fromEmail` =
Gmail **From**. The update recap includes the AE picker when that
address is not a Contact (the quote Contact may be someone else,
e.g. Jordan Hale). Claude waits; it does not invent an email from
the body. `addRevenueCloudAccountContact` does the write and can
stamp `Quote.ContactId`. It never creates an Account. Title, phone,
and mailing address from the email signature are passed through when
present; they are never invented.

Deploy to the target org, activate the server in Setup → MCP Servers, then
add a Claude connector at:

`https://api.salesforce.com/platform/mcp/v1/custom/RevenueCloudQuoting`

(Use `/sandbox/custom/` on sandbox or scratch orgs.)

## Claude Skill

The MCP tools are the verbs. The skill is the playbook (which verb, in what
order). Copy `skills/revenue-cloud-quoting/` into Claude Desktop **Skills**
(or upload `SKILL.md` on the Claude project). Enable it so the Skills panel
shows `revenue-cloud-quoting`. Keep project instructions short; let the skill
own routing.

Claude Desktop caps the YAML `description` in `SKILL.md` at **1024
characters**. Keep that field as a short router (when to use the skill). Put
procedure in the markdown body — the body has no such cap. If upload fails
with that error, trim `description`, not the playbook.

Create Quote and Add Product retry a One-Time bundle (Q-Rack 750) at
quantity 1 when Salesforce rejects qty > 1 with `Cannot have a fractional
quantity`. The skill also passes quantity 1 for those bundles up front.
Add Product stamps the quote `StartDate` / `EndDate` on new lines (a
36-month quote adds a 36-month subscription unless the user asked for a
different term). After add, Claude recaps and Open Quote — it should not
explain the price or preview a PDF.

Adding a PDF link to an existing Gmail draft is **one** Draft Customer
Reply (public link on the latest proposal file) then a Gmail draft
update. Do **not** Preview Quote Document for that — generating a PDF
is the slow OmniStudio path. Preview now reuses the latest file on the
quote unless `regenerate=true`.

**Prompting — one turn.** When the demo is “change the quote and
refresh the email + PDF,” put it in **one** Claude prompt. Verified
2026-10-14: `update the quote to 80% off, generate a draft that
reflects it, and add a proposal PDF link` finished quickly. A later
standalone “hyperlink the PDF” prompt started a second generate, took
~2.5 minutes, and failed. Do not split update and PDF into two chats.

Ramp modeling is the same rule. Preview or create the schedule and add
products in **one** prompt (`preview a 40-month annual ramp with a
30-day trial…` then `create that schedule and add Database at 10, 20,
then 30`). After the schedule exists, per-year add / remove / qty /
discount is also one prompt (`add Q-Rack to Year 2 and Year 3, remove
Database from Trial, and 20% off Database in Year 2`). Q-Rack on a ramp
is a **bundle gate**, not a finished $3,980 parent: Claude must describe,
stop on a Rule card or one stock keep-current-mix line (not a 22-value
dump), then configure (constraints stay on). Per-year
discount is the same `editsJson` path: `Year 2 25% off
all lines. Year 3 35% except QB-PowerSafe 1000D at 20%` — blanket then
named exception, including nested bundle children. Do not open Ramp
Builder. Do not apply 10/20/30 before the schedule exists. Do not use
update-lines or add-product to target a ramp year.

Drafting or refreshing the email for the current quote is Preview
until `bodyDisplay` **in that same turn** (Apex waits on the in-flight
PDF job; Claude must not Pause or ask the user to prompt again), then
Gmail using that HTML. Do **not** call Draft Customer Reply after
Preview.

Create, prospect, add-line, update-lines, find-open-quotes, catalog ping, deal-status, renew/cancel, draft-reply, ramp, billing/usage, compare-to-installed-base, discount, summary, explain, installed-base, preview document, submit, decide-approval,
configure, create-order, activate, amend, and Build Quote Options return
Lightning `quoteUrl` / `opportunityUrl` / `orderUrl` / `assetUrl` /
`pdfUrl` fields plus markdown `[Open Quote](...)` / `[Open Order](...)` /
`[Open Asset](...)` / `[Open PDF](...)` links in the **Claude chat**
display text. Never put those Lightning URLs in a customer Gmail draft —
the recipient cannot log in. `draftRevenueCloudCustomerReply` keeps AE
links on `coachDisplay` and a short customer note on `bodyDisplay`.
Re-upload the skill after changing `SKILL.md` so Claude renders those as
clickable chat links.

## Email and calendar connectors (Gmail / Outlook / Calendar)

Quoting MCP does **not** read mail or calendar. Put Gmail or Microsoft 365
next to the Salesforce connectors in the **same Claude chat**, then the
skill searches the mailbox, confirms the parsed lines, and calls the
quoting tools. Turn **Google Drive** on in that same chat when the
customer will send a Sheet or PDF (or a Drive link). The skill opens that
file on “build a quote from the latest email” — you do not need to say
“read the sheet” or “read the PDF.” A PDF uploaded in the Claude chat is
the same path.

Turn **Google Calendar** on when the demo is “quote my Acme call.” The
skill finds that event, reads the description or Drive notes, and Create
Quote — you do not need to say “read the recap.” Calendar is read-only:
the skill never creates events or sends invites. A Meet/Zoom recording
link is not a recap — Claude will not transcribe video.

### Gmail (typical demo)

1. In Claude, open **Customize → Connectors** (desktop: **Customize** in the
   sidebar, then **Connectors**).
2. **Discover** / search **Gmail** (Made by Google) → **Connect to Claude**.
3. Sign in with the inbox that will receive customer quote requests and
   grant access.
4. **Discover** / search **Google Drive** → **Connect to Claude**. Sign in
   with the same Google account that can open the customer Sheet or PDF.
5. **Discover** / search **Google Calendar** → **Connect to Claude**. Sign
   in with the same Google account that has the customer meetings.
6. Open the quoting project/chat. Click **+** next to the message box →
   **Connectors**, and turn **on**:
   - Gmail
   - Google Drive
   - Google Calendar
   - Salesforce **SObject All** (reads)
   - **Revenue Cloud Quoting** (mutations)
7. Re-upload `skills/revenue-cloud-quoting.zip` if the skill is older than
   catalog `2026-10-23.3` (Drive-transcript hop plus
   `syncRevenueCloudQuoteToOpportunity`).

On Team/Enterprise, an Owner must enable Gmail, Google Drive, and Google
Calendar for the org before Connect appears. Pro/Max can connect them on
the account.

A Google Sheet or PDF in the email works when the mail uses **Insert from
Drive** or pastes a Drive / Sheets URL. A downloaded `.xlsx` / `.csv` /
`.pdf` attached as a normal file does **not** — Gmail only returns the
filename. Product names in the file must match the Salesforce catalog.
Prefer a Sheet over a PDF when both are in the same mail. Do not treat
the quote-proposal PDF this MCP generates as an inbound customer file.

### Microsoft 365 / Outlook

Use this when the mailbox is a **work** Outlook account (Entra tenant), not
`@outlook.com` / `@hotmail.com`.

1. A Microsoft Entra Global Administrator must grant tenant consent for
   Claude’s Microsoft 365 connector. Team/Enterprise Claude Owners enable
   it under organization **Connectors**. See
   [Connect to Microsoft 365](https://support.claude.com/en/articles/15183774-connect-to-microsoft-365).
2. **Customize → Connectors** → **Microsoft 365** → **Connect**, then sign
   in with the work account.
3. In the quoting chat, turn on **Microsoft 365**, **Google Drive** (if
   the mail or meeting will link a Sheet, Doc, or PDF), **Google
   Calendar** (if quoting from a call recap), **SObject All**, and
   **Revenue Cloud Quoting**.

Leave Outlook **send** / write tools off (or always require approval). The
skill forbids sending the quote PDF to the customer.

### Try it

Put a product/qty request in that inbox, then ask:

> Build a quote from the latest Acme email.

Claude should search `in:inbox` newest (not a 30-day keyword OR), skip the
quoting catalog, then **one** Create Quote with `opportunityName`,
`quoteName`, and `linesJson` (no per-SKU add, no Product2 SObject queries)
and return **Open Quote**. If that company is not in Salesforce, and you
already asked it to create the account and contact from the email, it
should still be **one** Create Quote (pass contact names, email, and
address on that call — it creates Account + Contact + Opportunity). Do
not call Create Prospect first. If that mail has a Drive Sheet or PDF, it
should open Drive and take product/qty from that file without being
asked. A PDF dropped in the Claude chat should do the same. A second ask
for the same named deal **reuses**
that Draft (`alreadyExisted`) — it must not insert another “Claude Email
Test.” After reconnect, Find Open Quotes with that Opportunity name first.
It should **not** generate a PDF unless you ask for the order form. If Gmail
or Microsoft 365 is off, it should say so — do not paste the email unless
you want that fallback. If the only lines are in a Sheet or PDF and Drive
is off, it should ask to enable Google Drive. A raw email `.pdf` / `.xlsx`
attachment with no Drive link should be called out as unreadable.

A later email with updated quantities or term is **not** a new quote. Put
the revision in the same inbox, then ask:

> Look at the latest Acme email and update the existing quote from that
> message.

Claude should read the newest mail, then Find Open Quotes with the
Opportunity name, then **one** Update Quote Lines on that Draft (qty,
`termMonths`, discount as asked) — same Opportunity, no rebuild. If several
Drafts exist on that Opportunity, it should ask which one. New SKUs in that
mail are **one** Add Product with `linesJson`, not a second quote. New
lines inherit the quote term. A sender
with no Account: confirm, then **one** Create Quote with contact names,
email, and address (or confirmed demo address). They already own the SKU:
amend, not a new sale.

A meeting / call recap is the same Create Quote path, from Calendar
instead of Gmail. Put an event on the connected calendar (title
`Acme Expansion`, a customer attendee, product/qty in the description or
an attached Drive Doc), then ask:

> Build a quote from my Acme call.

Claude should find that event, open Drive notes if present, then **one**
Create Quote with `opportunityName`, `quoteName`, `linesJson`, `startDate`
from the event, and `contactEmail` from the customer attendee. Same ask
again **reuses** the Draft. If Calendar is off, it should say so. A
recording-only event should be called out as unreadable. A later meeting
with new quantities is **one** Update Quote Lines, not a second quote.

A **named Drive Doc** (Gemini / Meet notes, no calendar event) is Drive
first, not Calendar. Product names in the Doc must match the catalog.
Ask:

> Build a quote from my Infinitech call transcript in Drive.

Claude should search Google Drive, extract catalog SKUs only, then **one**
Create Quote. Vague notes wait. It must not invent Dual/Gold or auto-sync.
If Drive is off, it should ask to enable it. Slackbot without Drive tools
should ask you to paste the notes or a Drive link — a workspace Google
Drive app is not the same as Slackbot being able to open the file.

Spoken **what-if** on that Draft is not a new quote. Ask:

> Make it 36 months and 15% off.

Claude should **one** Update Quote Lines, then recap TCV (quote
GrandTotal). It should not rebuild or call Build Quote Options.

Adding a SKU to that Draft is not a new quote and not a 12-month line.
Ask:

> Add Software Maintenance quantity 5. Do not apply the 15% discount to
> this line.

Claude should **one** Add Product, inherit the quote term (36 months if
the quote is 36 months), recap Open Quote, and skip explain / PDF.

On a ramped Draft (for example **Bryce Majors Ramp Trial Oct14**), ask:

> Add Q-Rack to Year 2 and Year 3.

Claude must **stop** on a Rule card (paste it; wait for a number) or one
stock keep-current-mix line — not a 22-value dump and not a two-step
keep-or-drill essay. Hosted MCP describe/configure call Lightning
Configure (`executeConfigurationRules=true`) so Dual/Gold/qty come from
Constraint Rules Engine, then persist that graph through Place Sales
Transaction. Recap added/removed/qty/attr from the engine — do not infer
Dual vs Gold. Attribute values copy to every ramp year. Constraint
messages still block year-copy when present. Catalog `2026-10-23.3`.
Reconnect MCP after deploy.

The **customer pack** and **close the deal** beats (still never send
mail):

> Prepare the customer pack for Acme Expansion.

Claude should explain the price, preview the Quote Proposal PDF (poll
`isPartial` **immediately** until `bodyDisplay` in that turn, never
wait/Pause, never ask you to prompt again), then Gmail using that HTML
`bodyDisplay` verbatim — never Draft Customer Reply after Preview. The
proposal PDF is a hyperlink, not a raw URL. Lightning
Open Quote / Open PDF stay in the Claude chat — the customer cannot
open those. If Gmail cannot attach the PDF, the AE attaches it from
Open PDF before sending by hand.

If a draft already exists and you only want the PDF link in it, ask:

> Add the PDF link to the draft email.

Claude should **one** Draft Customer Reply, then update that Gmail
draft. It should **not** Preview Quote Document.

> Take the Acme Expansion quote to an order and activate it.

Claude should check deal status, submit if Draft, approve only if you
are the assignee (otherwise stop and say who it is waiting on), then
create the order, activate, and recap installed base. After each
successful mutate it should end with one **Next:** line (ramp, pack,
submit, or activate — not a menu of every tool).
