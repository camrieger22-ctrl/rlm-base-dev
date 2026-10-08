# Claude Hosted MCP — Revenue Cloud quoting

Custom Hosted MCP tools so Claude Desktop can create a Draft quote (optional
`linesJson` adds every product in that same call), add a
product via the managed add-line action, patch quantity and/or a percent
discount on existing Draft lines in one Place Sales Transaction, configure a
bundle, recap the quote, explain how a quote price was calculated, preview the
quote proposal PDF, submit it for approval, create an order from a quote,
activate that order (assets
follow), amend an existing asset, or build several commercial options under
one Opportunity. Backs the tools
with `global` invocables; add/discount/summary delegate to the existing
Quoting Assistant services. Bundle describe/configure wrap
`RLM_RampConfiguratorAction` catalog load plus Place Sales Transaction (no
Configurator HTTP). Submit starts the `RLM_Quote_Smart_Approval` flow.
Create Order calls `createOrdersFromQuote`. Activate sets
`Order.Status = Activated` and lists resulting assets. Amend Asset calls
`initiateAmendment` (quote output); closing the amendment still uses create
order + activate. Explain Quote Price reads Quote / QuoteLineItem /
QuoteLineDetail (list, header discount, amendment slices, proration,
amount due) so a rep can walk the price even when amendment Net Unit
Price is blank on the line. It does not call the Connect waterfall GET
from Hosted MCP — those callouts hang or throw in that context and Claude
then spends minutes rebuilding the story via SObject queries. Preview Quote
Document starts `RLM_DocumentGenerationCreate` for **RLM_QuoteProposal**
(same path as Preview PDF). Salesforce finishes the PDF in about 10 seconds
after the transaction commits, so the first preview returns `isPartial`
(retry immediately with the process Id — do not wait in chat). Later
previews reuse that Success PDF when the quote has not changed. Build Quote
Options creates 2–5 Draft quotes on one named Opportunity.

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

Create, add-line, update-lines, discount, summary, explain, preview document, submit,
configure, create-order, activate, amend, and Build Quote Options return
Lightning `quoteUrl` / `opportunityUrl` / `orderUrl` / `assetUrl` /
`pdfUrl` fields plus markdown `[Open Quote](...)` / `[Open Order](...)` /
`[Open Asset](...)` / `[Open PDF](...)` links in the display text.
Re-upload the skill after changing `SKILL.md` so Claude renders those as
clickable chat links.

## Email connectors (Gmail / Outlook)

Quoting MCP does **not** read mail. Put Gmail or Microsoft 365 next to the
Salesforce connectors in the **same Claude chat**, then the skill searches
the mailbox, confirms the parsed lines, and calls the quoting tools.

### Gmail (typical demo)

1. In Claude, open **Customize → Connectors** (desktop: **Customize** in the
   sidebar, then **Connectors**).
2. **Discover** / search **Gmail** (Made by Google) → **Connect to Claude**.
3. Sign in with the inbox that will receive customer quote requests and
   grant access.
4. Open the quoting project/chat. Click **+** next to the message box →
   **Connectors**, and turn **on**:
   - Gmail
   - Salesforce **SObject All** (reads)
   - **Revenue Cloud Quoting** (mutations)
5. Re-upload `skills/revenue-cloud-quoting.zip` if the skill is older than
   the inbound-email playbook.

On Team/Enterprise, an Owner must enable Gmail for the org before Connect
appears. Pro/Max can connect it on the account.

### Microsoft 365 / Outlook

Use this when the mailbox is a **work** Outlook account (Entra tenant), not
`@outlook.com` / `@hotmail.com`.

1. A Microsoft Entra Global Administrator must grant tenant consent for
   Claude’s Microsoft 365 connector. Team/Enterprise Claude Owners enable
   it under organization **Connectors**. See
   [Connect to Microsoft 365](https://support.claude.com/en/articles/15183774-connect-to-microsoft-365).
2. **Customize → Connectors** → **Microsoft 365** → **Connect**, then sign
   in with the work account.
3. In the quoting chat, turn on **Microsoft 365**, **SObject All**, and
   **Revenue Cloud Quoting**.

Leave Outlook **send** / write tools off (or always require approval). The
skill forbids sending the quote PDF to the customer.

### Try it

Put a product/qty request in that inbox, then ask:

> Build a quote from the latest Acme email.

Claude should search mail, then **one** Create Quote with `linesJson` (no
per-SKU add, no Product2 SObject queries) and return **Open Quote**. It
should **not** generate a PDF unless you ask for the order form. If Gmail
or Microsoft 365 is off, it should say so — do not paste the email unless
you want that fallback.
