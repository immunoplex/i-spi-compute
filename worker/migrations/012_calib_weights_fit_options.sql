-- =============================================================================
-- Migration 012: calib_weights_fit.fit_options and fit diagnostics
-- (curveRcore >= 0.7.1, curveRweights >= 0.3.1)
--
-- fit_options: nullable text holding a JSON object, the options the additive
-- precision-weights fit actually used (use_censoring, patient_col, plate_col,
-- fix_beta1, fix_kappa), so a stored weight set says how it was made. NULL for
-- multiplicative rows.
-- Six nullable diagnostic columns, filled for BOTH models: rhat_max,
-- n_divergent, ess_min (convergence), ident_sd_ratio (posterior / prior SD of
-- the key scale parameter) and resid_sd, resid_sd_ratio (does the variance
-- model describe the scaled residuals across the se range).
-- All NULL for rows written before this migration. Keys unchanged. The canonical definition is curveRcore R/calib_schema.sql and
-- curveRcore::weights_contract(); records calib_schema 0.7.1.
--
-- ORDER: apply BEFORE rolling a worker built with curveRcore >= 0.7.1. Its
-- additive jobs need this column (worker_weights.R refuses to run --model
-- additive without it); multiplicative jobs run either way.
--
-- Safe while the app and workers are running: ADD COLUMN without a default is
-- metadata-only. Run after 001-011. Idempotent. Run as the table owner.
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '5s';

ALTER TABLE madi_results.calib_weights_fit
    ADD COLUMN IF NOT EXISTS fit_options text,
    ADD COLUMN IF NOT EXISTS rhat_max double precision,
    ADD COLUMN IF NOT EXISTS n_divergent integer,
    ADD COLUMN IF NOT EXISTS ess_min double precision,
    ADD COLUMN IF NOT EXISTS ident_sd_ratio double precision,
    ADD COLUMN IF NOT EXISTS resid_sd double precision,
    ADD COLUMN IF NOT EXISTS resid_sd_ratio double precision;

INSERT INTO madi_results.schema_version (component, version, description)
VALUES ('calib_schema', '0.7.1',
        'curveRcore calib_* contract: calib_weights_fit.fit_options and fit diagnostics (both weights models)')
ON CONFLICT (component, version) DO NOTHING;

COMMIT;
