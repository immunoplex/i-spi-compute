-- =============================================================================
-- Migration 009: calib_draws -- scope in the key, controlled vocabularies,
-- fixed-parameter rows (curveRfreq >= 0.5.0)
--
-- 1. Primary key gains param_scope: (curve_id, method, model_name, term,
--    param_scope). A curve-level and a population-level parameter with the same
--    term name could otherwise collide.
-- 2. param_scope NOT NULL, CHECK in ('curve','population').
-- 3. sample_kind CHECK in ('posterior','mvn','fixed'). 'fixed' is new: a
--    parameter held fixed during the fit (fixed lower asymptote `a`) is stored
--    as a one-element array so a curve can be rebuilt from calib_draws alone.
--
-- Context: from curveRfreq 0.5.0 the frequentist MVN parameter draws are
-- persisted by DEFAULT (not only under persist_draws), are named like the
-- calib_param terms (a, b, c, d, g), and are the very draws behind each
-- sample's predictive interval -- together with calib_param 'sigma_resid' and
-- the run's interval_seed they reproduce calib_samples.conc_q_* exactly. The
-- worker also now writes the arrays at full double precision.
--
-- Run order: after 008. Idempotent. Run as the table owner.
-- =============================================================================

BEGIN;

UPDATE madi_results.calib_draws SET param_scope = 'curve' WHERE param_scope IS NULL;
ALTER TABLE madi_results.calib_draws ALTER COLUMN param_scope SET NOT NULL;

ALTER TABLE madi_results.calib_draws DROP CONSTRAINT IF EXISTS calib_draws_pkey;
ALTER TABLE madi_results.calib_draws
  ADD CONSTRAINT calib_draws_pkey PRIMARY KEY (curve_id, method, model_name, term, param_scope);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'calib_draws_param_scope_chk') THEN
    ALTER TABLE madi_results.calib_draws ADD CONSTRAINT calib_draws_param_scope_chk
      CHECK (param_scope IN ('curve', 'population'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'calib_draws_sample_kind_chk') THEN
    ALTER TABLE madi_results.calib_draws ADD CONSTRAINT calib_draws_sample_kind_chk
      CHECK (sample_kind IN ('posterior', 'mvn', 'fixed'));
  END IF;
END $$;

COMMENT ON COLUMN madi_results.calib_draws.sample_kind IS
  'posterior (Bayesian MCMC) | mvn (frequentist asymptotic-normal; same draws as the sample intervals) | fixed (parameter held fixed in the fit; one-element array)';

COMMIT;

-- ── OPTIONAL CLEAN-UP (destructive; review before running) ───────────────────
-- Frequentist rows written before curveRfreq 0.5.0 have positional term names
-- (p1, p2, ...) that cannot be joined to calib_param. They are regenerated,
-- correctly named, on the next frequentist recompute. To remove them now:
--
-- SELECT count(*) FROM madi_results.calib_draws
--  WHERE method = 'frequentist' AND term ~ '^p[0-9]+$';
-- DELETE FROM madi_results.calib_draws
--  WHERE method = 'frequentist' AND term ~ '^p[0-9]+$';

-- ── VERIFY ───────────────────────────────────────────────────────────────────
-- SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
--  WHERE conrelid = 'madi_results.calib_draws'::regclass;
