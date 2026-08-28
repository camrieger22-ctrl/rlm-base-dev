# BambooHR Self-Service Agentforce assets

Local authoring artifacts for the **BambooHR Self-Service Assistant** used by the Get Pricing BFF chat embed. These live under `scripts/` (not `force-app/`) so `prepare_rlm_org` does not deploy them.

| Path | Purpose |
|------|---------|
| `specs/bamboohrSelfServiceAgent.yaml` | Spec for `sf agent generate authoring-bundle` |
| `aiAuthoringBundles/BambooHR_Self_Service_Assistant/` | Agent Script + bundle meta (publish from here) |

See `.agents/artifacts/bamboohr-agentforce-phase0-checklist.md` for publish/activate commands and Messaging setup.

## Slice 2b — Help with this page (five beats)

The **Help with this page** topic narrates the workshop qualify wizard from live
BFF page context (`qualifyStep`, `bounceType`, `bounceReason`,
`salesHandoffVisible`) collected in `static/agent-chat.js` /
`window.BH_QUALIFY_CONTEXT`. The MIAW embed pushes the same names via
`prechatAPI.setHiddenPrechatFields` (and refreshes on `bh-agent-context-refresh`
when the wizard steps or bounce panel changes). The routing flow stamps them onto
`MessagingSession.RLM_Bamboo_*__c`, and the agent reads them through the
**Get Page Context** action (`RLM_BambooAgentGetPageContext`) rather than a
read-only context variable — variables hydrate once at session start and race the
stamp. Preview hints on Get Pricing ask “Where am I?” / “Why sales?”.

The chat widget bootstraps **on launcher click, not page load** — eager
`init()` freezes hidden pre-chat at the wizard's HTML defaults. After editing the
`.agent` file, `sf agent publish authoring-bundle` **and then** `sf agent activate`;
a plain metadata deploy updates the draft without creating a live version. Details
in `.agents/artifacts/bamboohr-under25-esw-setup.md`.

## Slice A — Qualify writes CRM

The **Qualify** subagent persists wizard beats (`Save Qualify Session`), classifies
work email (`Lookup Qualify Email`), stamps SelfServe (`Commit Qualify Identity`),
or captures sales bounces (`Handoff Qualify To Sales`). Apex:
`RLM_BambooAgentSaveQualifySession`, `RLM_BambooAgentLookupQualifyEmail`,
`RLM_BambooAgentCommitQualifyIdentity`, `RLM_BambooAgentHandoffQualifyToSales`.
**Get a price or quote** must not Create Quote until `qualifyCommitted` is true.
Place still stays on the summary CTA.

## Slice B — Session memory

Sticky ids live on the Agent Script session:

| Variable | Source |
|----------|--------|
| `qualifySessionId` | Save Qualify Session, or Get Page Context / pre-chat |
| `activeAccountId` | Commit / Lookup / Create Quote / Licenses / Get Page Context |
| `lastQuoteId` + `lastQuoteUrl` | Create Quote or Get Page Context (page Quote Id merged; blank page does not wipe) |
| `lastOrderId` / `lastPaymentUrl` | Place Get Pricing Order (confirmed Purchase topic) |

Create Quote passes `lastQuoteId` and `pageQuoteId`. Get Page Context merges page + current session Ids. Place is a confirmed action on Purchase.

**ESW Setup (under-25 gap #7):** add matching Hidden/Custom attributes on
deployment **BambooHR Self Service** — names and verify steps in
`.agents/artifacts/bamboohr-under25-esw-setup.md`.

**Messaging layer is captured in the repo:** `unpackaged/post_bamboohr_messaging/`
holds the routing flow (stamps wizard + Account/Quote/qualify-session context), the `BambooHR_Web`
MessagingChannel (10 pre-chat parameters), and both `EmbeddedServiceConfig`
records (pre-chat form active). Deploy with
`cci task run deploy_post_bamboohr_messaging --org <alias>` — it is deliberately
**not** in `prepare_rlm_org`, since it needs the published agent, the
`BambooHR_Messaging_Fallback` queue, and the ESW site to exist first. The
`MessagingSession` custom fields and the agent user's read access to them ship in
`deploy_post_bamboohr`.

## Phase 2 — BFF actions

Apex Invocables in `unpackaged/post_bamboohr/classes/RLM_BambooAgent*.cls` call the
Get Pricing BFF. The Agent Script above wires them as `apex://…` targets on the
Qualify / Get a price or quote / Purchase / Change my licenses / Help with this page subagents.

Deploy + public HTTPS URL + smoke:
`.agents/artifacts/bamboohr-agentforce-phase2-checklist.md`.
