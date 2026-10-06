# Claude Hosted MCP — Revenue Cloud quoting

Custom Hosted MCP tools so Claude Desktop can create a Draft quote, add a
product via the managed add-line action, configure a bundle, apply a line
discount, recap the quote, submit it for approval, or build several commercial
options under one Opportunity. Backs the tools with `global` invocables;
add/discount/summary delegate to the existing Quoting Assistant services.
Bundle describe/configure wrap `RLM_RampConfiguratorAction` catalog load plus
Place Sales Transaction (no Configurator HTTP). Submit starts the
`RLM_Quote_Smart_Approval` flow. Build Quote Options creates 2–5 Draft quotes
on one named Opportunity.

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
