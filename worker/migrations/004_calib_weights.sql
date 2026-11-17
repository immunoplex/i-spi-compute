-- =============================================================================
-- Migration 004: calib_weights + calib_weights_fit
--
-- Persists curveRweights::fit_precision_weights() output -- the precision-
-- weighting job (script_type weights_bayesian/weights_frequentist) reads
-- already-persisted calib_samples (joined to curve_lookup for
-- multiplate_group_id/antigen/feature), fits one saturated location-scale
-- model per (multiplate_group_id, method), and writes here.
--
-- Two tables, mirroring the existing calib_samples/calib_fit split:
--   calib_weights      -- per-sample: sigma/w/w_norm (curveRweights' $weights)
--   calib_weights_fit  -- one row per (multiplate_group_id, method): phi/beta1/
--                         diagnostics (curveRweights' $estimates)
--
-- Idempotent, same convention as every other calib_* table: delete-by-key then
-- insert (see save_weights() in worker_weights.R). design_cols and job_id are
-- plain (non-key) columns for traceability -- re-running a weights job (e.g.
-- with a different design set) simply replaces the prior result; it is NOT
-- versioned/kept as history.
--
-- Run order: after 001 (initial schema), 002 (pareto/asymmetry), 003
-- (calib_samples.agroup + sample_for_fit). Idempotent: CREATE TABLE IF NOT
-- EXISTS / CREATE INDEX IF NOT EXISTS.
-- =============================================================================

-- ── 1. calib_weights: per-sample weights ─────────────────────────────────────

CREATE TABLE IF NOT EXISTS madi_results.calib_weights (
    curve_id      bigint NOT NULL
                  REFERENCES madi_results.curve_lookup(curve_id) ON DELETE CASCADE,
    method        text   NOT NULL,
    sampleid      varchar(128) NOT NULL,
    patientid     varchar(128) DEFAULT '__none__' NOT NULL,
    timeperiod    varchar(64)  DEFAULT '__none__' NOT NULL,
    dilution      varchar(64)  DEFAULT '__none__' NOT NULL,
    agroup        varchar(40),         -- non-key, nullable (mirrors calib_samples.agroup);
                                       -- carried through regardless of whether it was one
                                       -- of this job's --design columns
    se            double precision,   -- se_concentration, the scale predictor used
    pcov          double precision,   -- reference only
    sigma         double precision,   -- phi * se^beta1
    w             double precision,   -- 1 / sigma^2
    w_norm        double precision,   -- w / mean(w)
    job_id        varchar(64),
    created_at    timestamptz DEFAULT now(),
    PRIMARY KEY (curve_id, method, sampleid, patientid, timeperiod, dilution)
);
CREATE INDEX IF NOT EXISTS idx_calib_weights_patient
    ON madi_results.calib_weights (curve_id, patientid);

-- ── 2. calib_weights_fit: one row per (multiplate_group_id, method) fit ──────

CREATE TABLE IF NOT EXISTS madi_results.calib_weights_fit (
    -- uuid, matching curve_lookup/curve_lookup_unmasked/*_for_fit's own
    -- declared type (confirmed via information_schema -- every one of them is
    -- uuid; this table was the lone text outlier, which breaks any JOIN
    -- comparing it to curve_lookup.multiplate_group_id: "operator does not
    -- exist: text = uuid". A plain text literal is still fine on INSERT
    -- (assignment-cast context allows text -> uuid), which is why
    -- worker_weights.R's writes never surfaced this.
    multiplate_group_id uuid NOT NULL,
    method              text NOT NULL,
    antigen             varchar(64),
    feature             varchar(15),
    design_cols         text,               -- e.g. 'timeperiod,agroup'
    scale_predictor     text,               -- 'se' | 'pcov'
    phi                 double precision,
    phi_lo              double precision,
    phi_hi              double precision,
    beta1               double precision,
    beta1_lo            double precision,
    beta1_hi            double precision,
    interpretation      text,
    n_fit               integer,
    n_eff               double precision,
    weight_ratio        double precision,
    job_id              varchar(64),
    created_at          timestamptz DEFAULT now(),
    PRIMARY KEY (multiplate_group_id, method)
);
