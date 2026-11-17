-- =============================================================================
-- Migration 008: out-of-range test samples -- censoring, predictive intervals,
-- threshold probabilities (curveRcore / curveRfreq / curveRbayes >= 0.5.0)
--
-- Adds per-sample columns produced by curveRcore::classify_censoring_multiplate()
-- and the engines' curveRcore::summarize_conc_draws(), plus the two settings that
-- drive them. All columns are non-key carried values; the calib_samples PK is
-- unchanged.
--
-- ORDER MATTERS: apply this BEFORE rolling workers built on curveR 0.5.0.
-- save_calib()'s .append() silently drops data-frame columns the table lacks,
-- so new workers against an un-migrated DB would lose these columns with no
-- error (verify_saved() now reports it as a hard failure).
--
-- (predicted_log10_concentration and pcov_gate_class already exist on the live
-- table; they are now also recorded in the tracked DDL files.)
--
-- Run order: after 001-007. Idempotent (ADD COLUMN IF NOT EXISTS, guarded
-- constraint creation, ON CONFLICT DO NOTHING). Run as the table owner.
-- =============================================================================

BEGIN;

-- ── 1. calib_samples ─────────────────────────────────────────────────────────

ALTER TABLE madi_results.calib_samples
  ADD COLUMN IF NOT EXISTS censor_class       text,
  ADD COLUMN IF NOT EXISTS censor_type        text,
  ADD COLUMN IF NOT EXISTS censor_lower       double precision,
  ADD COLUMN IF NOT EXISTS censor_upper       double precision,
  ADD COLUMN IF NOT EXISTS conc_q_lo          double precision,
  ADD COLUMN IF NOT EXISTS conc_q_med         double precision,
  ADD COLUMN IF NOT EXISTS conc_q_hi          double precision,
  ADD COLUMN IF NOT EXISTS p_below_lloq       double precision,
  ADD COLUMN IF NOT EXISTS p_above_uloq       double precision,
  ADD COLUMN IF NOT EXISTS p_below_cutoff     double precision,
  ADD COLUMN IF NOT EXISTS frac_draws_below_a double precision,
  ADD COLUMN IF NOT EXISTS frac_draws_above_d double precision;

COMMENT ON COLUMN madi_results.calib_samples.censor_class IS
  'quantified | lod_to_lloq | below_lod | below_lloq | above_uloq | saturated | no_response; NULL = curve has no LOQs (or pre-0.5.0 row)';
COMMENT ON COLUMN madi_results.calib_samples.censor_type IS
  'none | left | interval | right -- censoring code for downstream censored-data methods';
COMMENT ON COLUMN madi_results.calib_samples.censor_lower IS
  'Lower censoring bound, natural scale, dilution-corrected (same scale as final_concentration); NULL = unbounded (0 for left-censored)';
COMMENT ON COLUMN madi_results.calib_samples.censor_upper IS
  'Upper censoring bound, natural scale, dilution-corrected; NULL = unbounded';
COMMENT ON COLUMN madi_results.calib_samples.conc_q_lo IS
  '2.5% predictive quantile of concentration, natural scale, dilution-corrected (out-of-range draws counted as censored)';
COMMENT ON COLUMN madi_results.calib_samples.conc_q_med IS
  '50% predictive quantile of concentration, natural scale, dilution-corrected';
COMMENT ON COLUMN madi_results.calib_samples.conc_q_hi IS
  '97.5% predictive quantile of concentration, natural scale, dilution-corrected; NULL = unbounded above';
COMMENT ON COLUMN madi_results.calib_samples.p_below_lloq IS
  'Probability the (pre-dilution) concentration is below the curve LLOQ';
COMMENT ON COLUMN madi_results.calib_samples.p_above_uloq IS
  'Probability the (pre-dilution) concentration is above the curve ULOQ';
COMMENT ON COLUMN madi_results.calib_samples.p_below_cutoff IS
  'Probability the dilution-corrected concentration is below calib_diagnostics.decision_cutoff; NULL when no cutoff is set';
COMMENT ON COLUMN madi_results.calib_samples.frac_draws_below_a IS
  'Share of predictive draws whose response lay beyond the low-concentration asymptote (excluded from se_concentration/pcov)';
COMMENT ON COLUMN madi_results.calib_samples.frac_draws_above_d IS
  'Share of predictive draws whose response lay beyond the high-concentration asymptote (excluded from se_concentration/pcov)';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'calib_samples_censor_class_chk') THEN
    ALTER TABLE madi_results.calib_samples ADD CONSTRAINT calib_samples_censor_class_chk
      CHECK (censor_class IN ('quantified','lod_to_lloq','below_lod','below_lloq',
                              'above_uloq','saturated','no_response'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'calib_samples_censor_type_chk') THEN
    ALTER TABLE madi_results.calib_samples ADD CONSTRAINT calib_samples_censor_type_chk
      CHECK (censor_type IN ('none','left','interval','right'));
  END IF;
END $$;

-- ── 2. calib_diagnostics: provenance of the settings used ────────────────────

ALTER TABLE madi_results.calib_diagnostics
  ADD COLUMN IF NOT EXISTS decision_cutoff  double precision,
  ADD COLUMN IF NOT EXISTS n_interval_draws integer;

-- ── 3. settings cascade ──────────────────────────────────────────────────────
-- decision_cutoff: NO __system__ row on purpose -- unset means "no cutoff"
-- (p_below_cutoff is NULL). Set it per project/study/antigen in the settings
-- editor, which lists every calib_settings_meta row whether or not it is set.
-- n_interval_draws: system default 1000 (frequentist Monte Carlo draws/sample).

INSERT INTO madi_results.calib_settings
  (project_id, study_accession, experiment_accession, feature, antigen,
   param_name, param_data_type, param_integer_value, param_numeric_value,
   param_boolean_value, param_character_value, param_user)
VALUES
  (-1,'__none__','__none__','__none__','__none__','n_interval_draws','integer',1000,NULL,NULL,NULL,'__seed__')
ON CONFLICT ON CONSTRAINT calib_settings_scope_param_uniq DO NOTHING;

INSERT INTO madi_results.calib_settings_meta
  (param_name, param_group, param_label, param_data_type,
   param_control_type, param_description)
VALUES
  ('decision_cutoff', 'calibration', 'Decision cutoff (concentration)', 'numeric',
   'numericInput',
   'Optional concentration threshold, in the same dilution-corrected units as '
   || 'final_concentration (e.g. a protective level). Each sample then gets '
   || 'p_below_cutoff, the probability its concentration is below it. Leave '
   || 'unset for none. Usually set per antigen.'),
  ('n_interval_draws', 'calibration', 'Interval draws (frequentist)', 'integer',
   'numericInput',
   'Monte Carlo draws per sample for frequentist predictive intervals and '
   || 'threshold probabilities. Default 1000; 0 disables them. Bayesian fits '
   || 'use their posterior draws instead.')
ON CONFLICT (param_name) DO NOTHING;

COMMIT;

-- ── VERIFY ───────────────────────────────────────────────────────────────────
-- SELECT column_name, data_type FROM information_schema.columns
--  WHERE table_schema = 'madi_results' AND table_name = 'calib_samples'
--    AND column_name IN ('censor_class','conc_q_lo','p_below_cutoff','frac_draws_below_a');
-- SELECT * FROM madi_results.calib_settings_meta
--  WHERE param_name IN ('decision_cutoff','n_interval_draws');
