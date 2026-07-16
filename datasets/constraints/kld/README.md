# KLDiscovery Constraint Models

## KLDPathway

CML model that drives the Standard Average Estimate cascade on the three matter pathway bundles.

| Item | Value |
|------|-------|
| Expression Set | `KLDPathway` |
| Version | `KLDPathway_V1` |
| CML source | `scripts/cml/KLDPathway.cml` |
| Data plan | `datasets/constraints/kld/KLDPathway/` |
| Catalog | `datasets/sfdmu/kld/en-US/kld-pcm` |

### Behavior

- **Editable:** Source Data (GB), Term Months
- **Calculated (read-only):** Decompression, Storage Expansion, ECA Data, Active Review, PM/Tech hours/month (Hosting matrix)
- **When selected:** Staging qty ← Source; ECA/Review qty ← ECA/Active Review GB; PM/Tech qty ← hours × Term Months

### Regenerate

```bash
python3 scripts/build_kld_pathway_constraints.py
```

### Import / activate (connected org)

```bash
export SF_TEMP_SHOW_SECRETS=true
cci org default camkld
cci task run import_cml --org camkld \
  -o data_dir datasets/constraints/kld/KLDPathway \
  -o dataset_dirs "datasets/sfdmu/kld/en-US/kld-pcm"
cci task run manage_expression_sets \
  -o operation activate_versions \
  -o version_full_names KLDPathway_V1
```

Requires `kld-pcm` products already loaded. Flow `prepare_constraints` steps 13–14 run this when `constraints_data` and `kld` are true.
