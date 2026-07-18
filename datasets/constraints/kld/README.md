# KLDiscovery Constraint Models

## KLDPathway

CML model that drives the Standard Average Estimate cascade on **Nebula ECA to RelOne** (`KLD-PATH-NEB-R1`).

| Item | Value |
|------|-------|
| Expression Set | `KLDPathway` |
| Version | `KLDPathway_V1` |
| CML source | `scripts/cml/KLDPathway.cml` |
| Data plan | `datasets/constraints/kld/KLDPathway/` |
| Catalog | `datasets/sfdmu/kld/en-US/kld-pcm` |

### Architecture (volume on attributes)

Line **Quantity stays 1** for Staging / ECA / Review / PM / Tech. CML does **not** bind
`relation[Type] == volume` (that spawns multiple lines). Instead:

| When selected | Child attribute set to |
|---------------|------------------------|
| Staging | `Billable_GB` ← Source Data |
| ECA Hosting | `Billable_GB` ← ECA Data GB |
| Review | `Billable_GB` ← Active Review GB |
| PM / Tech | `Billable_Hours` ← hours/month × Term Months |

Relation cardinality is `[0..1]` (at most one line per port).

**Pricing note:** list × `LineItemQuantity` still sees qty=1 until a pricing-procedure
overlay maps `Billable_GB` / `Billable_Hours` into quantity or `ListPrice × Billable_*`.
Attribute-based adjustments cannot multiply by a continuous attribute value.

### Behavior

- **Editable:** Source Data (GB), Term Months
- **Calculated (read-only):** Decompression, Storage Expansion, ECA Data, Active Review, PM/Tech hours/month
- **When selected:** child `Billable_*` attrs sync from cascade (Quantity remains 1)

### Regenerate

```bash
python3 scripts/build_kld_pcm.py
python3 scripts/build_kld_pathway_constraints.py
```

### Import / activate (connected org)

```bash
export SF_TEMP_SHOW_SECRETS=true
cci org default camkld
cci task run insert_kld_pcm_data --org camkld
cci task run import_cml --org camkld \
  -o data_dir datasets/constraints/kld/KLDPathway \
  -o dataset_dirs "datasets/sfdmu/kld/en-US/kld-pcm"
cci task run manage_expression_sets \
  -o operation deactivate_versions \
  -o version_full_names KLDPathway_V1
cci task run manage_expression_sets \
  -o operation activate_versions \
  -o version_full_names KLDPathway_V1
```

Requires `kld-pcm` products already loaded. Flow `prepare_constraints` steps 13–14 run
import/activate when `constraints_data` and `kld` are true.

**PRC qty lock:** SFDMU Upsert cannot update existing `ProductRelatedComponent` Quantity
(Bug 5). After first load, Apex-update Staging/ECA/Review/PS PRCs to Quantity=1,
IsQuantityEditable=false, MinQuantity=1, MaxQuantity=1 if the org still has old demo qtys.
