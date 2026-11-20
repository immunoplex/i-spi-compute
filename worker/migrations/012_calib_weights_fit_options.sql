-- =============================================================================
-- Migration 012: calib_weights_fit.fit_options (curveRcore >= 0.7.1,
-- curveRweights >= 0.3.1)
--
-- One nullable text column holding a JSON object: the options the additive
-- precision-weights fit actually used (use_censoring, patient_col, plate_col,
-- fix_beta1, fix_kappa), so a stored weight set says how it was made.
-- NULL for multiplicative rows and for rows written before this migration. Keys
-- unchanged. The canonical definition is curveRcore R/calib_schema.sql and
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
    ADD COLUMN IF NOT EXISTS fit_options text;

INSERT INTO madi_results.schema_version (component, version, description)
VALUES ('calib_schema', '0.7.1',
        'curveRcore calib_* contract: calib_weights_fit.fit_options (additive weights fit options)')
ON CONFLICT (component, version) DO NOTHING;

COMMIT;
