# Claude Hosted MCP — Revenue Cloud quoting

Custom Hosted MCP tools so Claude Desktop can create a Draft quote, add a
product via the managed add-line action, configure a bundle, apply a line
discount, recap the quote, explain how a quote price was calculated, preview the
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

Create, add-line, discount, summary, explain, preview document, submit,
configure, create-order, activate, amend, and Build Quote Options return
Lightning `quoteUrl` / `opportunityUrl` / `orderUrl` / `assetUrl` /
`pdfUrl` fields plus markdown `[Open Quote](...)` / `[Open Order](...)` /
`[Open Asset](...)` / `[Open PDF](...)` links in the display text.
Re-upload the skill after changing `SKILL.md` so Claude renders those as
clickable chat links.
