-- =============================================================================
-- Migration 010: calib_weights / calib_weights_fit hold the weights of more than one
-- model (curveRweights >= 0.3.0, curveRcore >= 0.6.0)
--
-- One table per concept, one weight set per (sample, method): `model` records which
-- model produced it ('multiplicative' = every row written before this migration;
-- 'additive' = the measurement-error model). The primary keys are UNCHANGED, so the
-- sample hierarchy is the same as calib_samples. All new columns are nullable (NULL =
-- does not apply to the model that wrote the row) except `model`, which defaults to
-- 'multiplicative'. The canonical definition is curveRcore R/calib_schema.sql and
-- curveRcore::weights_contract(); this file is the same ADD COLUMN statements.
--
-- ORDER MATTERS: apply this BEFORE rolling a worker that writes the additive model.
-- .append() (flatten_and_save.R) silently drops data-frame columns the table lacks, so
-- an un-migrated DB would lose the new columns with no error. worker_weights.R
-- therefore refuses to run --model additive until these columns exist.
--
-- Safe while the app and workers are running: ADD COLUMN with a constant default is
-- metadata-only on PostgreSQL >= 11 (the live server is 14). lock_timeout makes the
-- migration give up instead of queueing behind a long-running query.
--
-- Run order: after 001-009. Idempotent (ADD COLUMN IF NOT EXISTS). Run as the table
-- owner. Already applied to the shared preprod DB (verified 2026-11-12: 23 and 32
-- columns, identical to weights_contract()); a no-op there, needed for other
-- environments.
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '5s';

ALTER TABLE madi_results.calib_weights
    ADD COLUMN IF NOT EXISTS model text NOT NULL DEFAULT 'multiplicative',
    ADD COLUMN IF NOT EXISTS weights_pkg_version character varying(32),
    ADD COLUMN IF NOT EXISTS v_meas double precision,
    ADD COLUMN IF NOT EXISTS tau2 double precision,
    ADD COLUMN IF NOT EXISTS reliability double precision,
    ADD COLUMN IF NOT EXISTS reliability_lo double precision,
    ADD COLUMN IF NOT EXISTS reliability_hi double precision,
    ADD COLUMN IF NOT EXISTS censor_type text CHECK (censor_type IN ('none','left','interval','right')),
    ADD COLUMN IF NOT EXISTS bound double precision;

ALTER TABLE madi_results.calib_weights_fit
    ADD COLUMN IF NOT EXISTS model text NOT NULL DEFAULT 'multiplicative',
    ADD COLUMN IF NOT EXISTS weights_pkg_version character varying(32),
    ADD COLUMN IF NOT EXISTS tau double precision,
    ADD COLUMN IF NOT EXISTS tau_lo double precision,
    ADD COLUMN IF NOT EXISTS tau_hi double precision,
    ADD COLUMN IF NOT EXISTS kappa double precision,
    ADD COLUMN IF NOT EXISTS kappa_lo double precision,
    ADD COLUMN IF NOT EXISTS kappa_hi double precision,
    ADD COLUMN IF NOT EXISTS reliability double precision,
    ADD COLUMN IF NOT EXISTS reliability_lo double precision,
    ADD COLUMN IF NOT EXISTS reliability_hi double precision,
    ADD COLUMN IF NOT EXISTS fix_beta1 boolean,
    ADD COLUMN IF NOT EXISTS n_censored integer,
    ADD COLUMN IF NOT EXISTS identifiability text;

COMMIT;
