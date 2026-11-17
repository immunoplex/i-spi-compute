-- ============================================================================
-- bayes_keying_migration.sql
-- Rekeys bayes_ensemble and bayes_pareto_k so the corrected worker can key
-- per-plate tables by curve_id and pareto_k by the 8-column group key.
-- Run ONCE. Back up first. Review the legacy-data notes before COMMIT.
-- ============================================================================
BEGIN;

-- ── bayes_ensemble: replace the 6-column NK with (curve_id, family) ─────────
-- The old UNIQUE(project, study, experiment, plateid, antigen, family) collides
-- whenever one plateid+antigen appears in two groups (different source /
-- wavelength / feature / nominal_sample_dilution): two distinct curve_ids map to
-- the same 6-tuple. That is the constraint that made the original save throw.
--
-- PRE-CHECK for legacy duplicates that would block the new constraint
-- (run first; if it returns rows, the old curve_id assignment was wrong):
--   SELECT curve_id, family, count(*)
--     FROM madi_results.bayes_ensemble
--    GROUP BY curve_id, family HAVING count(*) > 1;
-- If it returns rows, clean them or TRUNCATE bayes_ensemble and re-run the
-- affected studies (the legacy rows were mis-keyed anyway) before continuing.

ALTER TABLE madi_results.bayes_ensemble
  DROP CONSTRAINT bayes_ensemble_nk;

ALTER TABLE madi_results.bayes_ensemble
  ADD CONSTRAINT bayes_ensemble_nk UNIQUE (curve_id, family);


-- ── bayes_pareto_k: add group-key columns, then rekey to group + family ─────
-- pareto_k is fit-level (one row per group x family), but the table lacks the
-- columns that distinguish groups, so the old UNIQUE(project, study, experiment,
-- antigen, family) collides across source / wavelength / feature / nominal.
-- Add the four missing group columns (varchar sizes mirror curve_lookup).

ALTER TABLE madi_results.bayes_pareto_k
  ADD COLUMN IF NOT EXISTS nominal_sample_dilution varchar(128) NOT NULL DEFAULT '__none__',
  ADD COLUMN IF NOT EXISTS feature                 varchar(15)  NOT NULL DEFAULT '__none__',
  ADD COLUMN IF NOT EXISTS source                  varchar(25)  NOT NULL DEFAULT '__none__',
  ADD COLUMN IF NOT EXISTS wavelength              varchar(15)  NOT NULL DEFAULT '__none__';

ALTER TABLE madi_results.bayes_pareto_k
  DROP CONSTRAINT bayes_pareto_k_project_id_study_accession_experiment_access_key;

ALTER TABLE madi_results.bayes_pareto_k
  ADD CONSTRAINT bayes_pareto_k_group_nk UNIQUE
    (project_id, study_accession, experiment_accession,
     nominal_sample_dilution, feature, antigen, source, wavelength, family);

-- Legacy pareto_k rows now carry '__none__' in the four new columns. New writes
-- delete/insert by the REAL group key, so they won't overwrite those stale rows.
-- Clear them so re-runs land cleanly (optional but recommended):
--   DELETE FROM madi_results.bayes_pareto_k WHERE nominal_sample_dilution = '__none__';

COMMIT;

-- ── Optional integrity indexes for the delete-by-curve_id writes ────────────
-- CREATE INDEX IF NOT EXISTS ix_bayes_samples_curve_id    ON madi_results.bayes_samples    (curve_id);
-- CREATE INDEX IF NOT EXISTS ix_bayes_ensemble_curve_id   ON madi_results.bayes_ensemble   (curve_id);
-- CREATE INDEX IF NOT EXISTS ix_bayes_curve_grid_curve_id ON madi_results.bayes_curve_grid (curve_id);
-- CREATE INDEX IF NOT EXISTS ix_bayes_cdan_grid_curve_id  ON madi_results.bayes_cdan_grid  (curve_id);
