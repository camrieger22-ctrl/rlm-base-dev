# Ramp Builder (`post_ramp_ux`)

Flow-hosted Ramp Builder matching the schedule + products-by-segment mockup.

- Quote action `Ramp Builder` is a headless LWC action (`rlmOpenRampBuilder.invoke()`). It assigns `/lightning/cmp/c__rlmRampBuilder?c__recordId=…` so the first click is not cancelled by a screen-action teardown.
- The LWC reads the quote, groups, and lines with GraphQL / UI API
- **Browse catalog** opens a panel beside the products-by-segment grid (the grid stays visible). Product Discovery (`getProducts` / `findProducts`) uses the quote as `transactionId`, the same invocables behind the quote Browse Catalog action. Cards show `displayUrl` images and every priced selling model from that response. Add asks where to place the product: this segment, this and later, all segments, or chosen years. New cells seed quantity and discount/markup from that segment’s schedule defaults; each cell can then set Discount or Markup independently.
- **Configure** on a bundle persists the parent line, then opens a Ramp add-on panel (option groups, quantities, parent attributes, constraint messages). Load/save call Configurator `configure` with the same options as Default Product Configurator: configuration rules, catalog validation, qualification, ARC validation, pricing, and default components on first configure. Attribute updates go through `QuoteLineItemAttribute` nodes (`AttributeKey` / `AttributeValue`), not QLI field names. After the engine accepts the graph, selected children are written through Place Sales Transaction (the same persist path as Ramp Save Plan). **Advanced** still hosts Default Product Configurator (`RLM_Ramp_Product_Config`) when the full UI is needed. Save Plan skips those already-written bundle lines.
- Save calls `RLM_RampTransactionAction.savePlan`, which persists through Place Sales Transaction

Quote/group/line reads do not use Apex. Catalog browse goes through Product Discovery so qualification and pricing run against the quote. Line writes go through PST, not direct DML. The Flow
`RLM_Ramp_Builder` remains if an admin wants to wrap the screen; it is not the
default launch path because a Flow modal cannot show the products-by-segment grid.
ApplyPlan also repairs the group tree (`RampScheduleGroup` root, segment `Type` null)
because `groupRampAction` alone leaves a ramp that cannot be activated.
