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

**ESW Setup (under-25 gap #7):** add matching Hidden/Custom attributes on
deployment **BambooHR Self Service** — names and verify steps in
`.agents/artifacts/bamboohr-under25-esw-setup.md`.

**Messaging layer is captured in the repo:** `unpackaged/post_bamboohr_messaging/`
holds the routing flow (stamps the 4 context fields), the `BambooHR_Web`
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
Get a price or quote / Change my licenses subagents.

Deploy + public HTTPS URL + smoke:
`.agents/artifacts/bamboohr-agentforce-phase2-checklist.md`.
