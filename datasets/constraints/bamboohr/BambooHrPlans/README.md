# BambooHrPlans constraint model

Quote-level CML: at most one of **BambooHR Core / Pro / Elite** on a sales
transaction (a la carte). Package Path A (`BAMBOO-PKG-WORKFORCE`) uses
`PCG-BH-BASE` min/max **1** for the same exclusivity inside the configurator.

## Import

```bash
cci task run validate_cml -o cml_dir scripts/cml -o data_dir datasets/constraints/bamboohr/BambooHrPlans -o expression_set_name BambooHrPlans
cci task run import_cml --org <alias> \
  -o data_dir datasets/constraints/bamboohr/BambooHrPlans \
  -o dataset_dirs datasets/sfdmu/bamboohr/en-US/bh-pcm
cci org default <alias>
cci task run manage_expression_sets \
  --operation activate_versions \
  --version-full-names BambooHrPlans_V1
```

`prepare_bamboohr` runs validate + import + activate when `bamboohr` and
`constraints_data` are true.

## Notes

- `lineitems[Type]` aggregates **Quantity**; use `> 0` for presence. Do not use
  `sum(types) <= 1` (fails when a single plan has qty &gt; 1).
- Re-uploading `ConstraintModel` on an existing ESDV may not invalidate the
  platform compile cache. Prefer a fresh ExpressionSet / type tags on dirty orgs.
- Smoke: `python scripts/bamboohr/plan_exclusivity_smoke.py --via-cci`
  (add `--path-b` for a la carte configure checks on a clean org)
