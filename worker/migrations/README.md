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
| — | `bayes_keying_migration.sql` | Re-keys `bayes_ensemble` / `bayes_pareto_k` | **Legacy** (old batch calculator) |

Prerequisites these files do **not** create: `curve_lookup` (with
`multiplate_group_id`), the `xmap_*` tables, the `*_unmasked` and `*_for_fit`
views, `calib_settings` / `calib_settings_meta` and the `resolve_settings*`
functions. Some `calib_*` tables written by the worker (`calib_draws`,
`calib_hyperparam`, `calib_fit_diag`, `calib_standards`, `calib_blanks`) are
defined in curveRcore's `R/calib_schema.sql`. A complete, curated DDL for a fresh
install is planned for the i-spi-deployment repository.
