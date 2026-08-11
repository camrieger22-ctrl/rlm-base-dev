# BambooHR Self-Service Agentforce assets

Local authoring artifacts for the **BambooHR Self-Service Assistant** used by the Get Pricing BFF chat embed. These live under `scripts/` (not `force-app/`) so `prepare_rlm_org` does not deploy them.

| Path | Purpose |
|------|---------|
| `specs/bamboohrSelfServiceAgent.yaml` | Spec for `sf agent generate authoring-bundle` |
| `aiAuthoringBundles/BambooHR_Self_Service_Assistant/` | Agent Script + bundle meta (publish from here) |

See `.agents/artifacts/bamboohr-agentforce-phase0-checklist.md` for publish/activate commands and Messaging setup.
