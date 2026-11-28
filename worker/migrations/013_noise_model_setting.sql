-- =============================================================================
-- Migration 013: response noise model setting (curveRbayes / curveRfreq >= 0.6.0)
--
-- Registers the settings-cascade parameter `noise_model`:
--   constant  one residual SD on the fitting scale (the behaviour before 0.6.0;
--             system default, so existing results reproduce)
--   add_prop  additive + proportional: sd = sqrt(sigma_add^2 + (cv * mu)^2) on
--             the raw response, pooled across the plates of a fit group.
--             Recommended for absorbance (ELISA OD).
-- The worker reads it per group (CLI `noise_model` overrides). Fits record the
-- model, the pooled frequentist terms and the response adjustment (blank value,
-- offset for responses <= 0) in calib_run.params; under add_prop calib_param
-- holds terms sigma_add and cv instead of sigma_resid / sigma_obs.
--
-- No table changes, so calib_schema (curveRcore's contract version) is not
-- bumped. Run order: after 001-012. Idempotent. Run as the table owner.
-- =============================================================================

BEGIN;

INSERT INTO madi_results.calib_settings
  (project_id, study_accession, experiment_accession, feature, antigen,
   param_name, param_data_type, param_integer_value, param_numeric_value,
   param_boolean_value, param_character_value, param_group, param_user)
VALUES
  (-1,'__none__','__none__','__none__','__none__','noise_model','character',
   NULL,NULL,NULL,'constant','calibration','__seed__')
ON CONFLICT ON CONSTRAINT calib_settings_scope_param_uniq DO NOTHING;

INSERT INTO madi_results.calib_settings_meta
  (param_name, param_group, param_label, param_data_type,
   param_control_type, param_choices_list, param_description)
VALUES
  ('noise_model', 'calibration', 'Response noise model', 'character',
   'radioButtons', 'constant,add_prop',
   'How the spread of the standards around the curve is modelled. constant '
   || '(default): one SD on the fitting scale. add_prop: an additive floor plus '
   || 'a part proportional to the response, sqrt(sigma_add^2 + (cv * mean)^2), '
   || 'estimated once per fit group. Use add_prop for absorbance (ELISA OD), '
   || 'where a constant SD over-trusts either the low end (log response) or the '
   || 'high end (linear response).')
ON CONFLICT (param_name) DO NOTHING;

COMMIT;

-- ── VERIFY ───────────────────────────────────────────────────────────────────
-- SELECT * FROM madi_results.calib_settings      WHERE param_name = 'noise_model';
-- SELECT * FROM madi_results.calib_settings_meta WHERE param_name = 'noise_model';
