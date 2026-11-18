# Database migrations

All objects live in the `madi_results` schema. Apply by hand (`psql -f`), as the
table owner, in the order below. Every file is idempotent, so re-running one is a
no-op.

| Order | File | What it does | Status |
|---|---|---|---|
| 001 | `../../db/calib_schema_v1.sql` | Creates the core `calib_*` tables | Required |
| 002 | `002_pareto_asymmetry.sql` | `bayes_pareto_k` + asymmetry columns on `bayes_curves` | **Legacy** (old batch calculator; the curveR worker does not use it) |
| 003 | `003_calib_samples_agroup.sql` | `calib_samples.agroup`; adds `agroup` to `sample_for_fit` | Required |
| 004 | `004_calib_weights.sql` | `calib_weights`, `calib_weights_fit` | Required |
| 005 | `005_standard_dilution_reference.sql` | Settings meta row `standard_dilution_reference` | Required |
| 006 | `006_compute_cluster.sql` | Settings meta row `compute_cluster` (compute-clone routing) | Required |
| 007 | `007_standard_dilution_reference_description.sql` | Backfills the description for 005 | Required for installs that ran 005 before 2026-10-09 |
| 008 | `008_calib_samples_censoring.sql` | Censoring / predictive-interval columns; `decision_cutoff`, `n_interval_draws` settings | Required (curveR >= 0.5.0) |
| 009 | `009_calib_draws_scope_key.sql` | `calib_draws` key gains `param_scope`; CHECKs | Required (curveRfreq >= 0.5.0) |
| 010 | `010_calib_weights_model.sql` | `model` + additive-model columns on the weights tables | Required (curveRweights >= 0.3.0) |
| 011 | `011_point_estimates_reference_manifest.sql` | `calib_controls`; estimate columns + `recovery_pct` on `calib_standards`; `control_reference` + `calib_controls_qc`; `calib_run.manifest`; `schema_version`; `control_for_fit` view | Required (curveRcore >= 0.7.0) |
| — | `bayes_keying_migration.sql` | Re-keys `bayes_ensemble` / `bayes_pareto_k` | **Legacy** (old batch calculator) |

## After 011: one-off backfill

Curves fitted before 011 have no control rows and no standard estimates.
`worker/backfill_point_estimates.R` fills them from the stored fits (nothing is
refitted; fit rows are not changed), so readers need only stored values. Run it
once, from a worker container or any machine with curveRcore >= 0.7.0 and the
`DB_*` environment:

```sh
Rscript backfill_point_estimates.R --dry-run          # report what it would do
Rscript backfill_point_estimates.R                    # all curves still missing values
```

It is resumable (a stopped run continues where it left off) and each batch is one
transaction. `--curve_ids`, `--method`, `--batch` and `--limit` narrow a run. How
close the backfilled values are to what the engine would have stored is in
curveRcore's `calib_points_SPEC.md` ("Backfill"); `worker/tests/e2e_backfill_pg.sh`
checks it against the real engines on a throwaway PostgreSQL.

New fits need no backfill: the worker computes the same values right after each
fit and saves them with it (`worker/point_estimates.R`, shared by the worker and
the backfill, so both give identical values; the e2e test checks this). If that
step fails for a group, the fit is still saved without them and the backfill
fills them later. Against a database without 011 the worker still runs; the new
values are just not stored.

Prerequisites these files do **not** create: `curve_lookup` (with
`multiplate_group_id`), the `xmap_*` tables, the `*_unmasked` and `*_for_fit`
views, `calib_settings` / `calib_settings_meta` and the `resolve_settings*`
functions. Some `calib_*` tables written by the worker (`calib_draws`,
`calib_hyperparam`, `calib_fit_diag`, `calib_standards`, `calib_blanks`) are
defined in curveRcore's `R/calib_schema.sql`. Migration 011 also needs
`xmap_control` and `xmap_header`. A complete, curated DDL for a fresh
install is planned for the i-spi-deployment repository.
