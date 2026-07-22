-- =============================================================================
-- calib_schema_v1.sql — method-agnostic calibration tables for the curveR
-- refactor of immunoplex_batch_calculator.
--
-- Design principles:
--   * One set of tables for BOTH curveRfreq and curveRbayes, distinguished by
--     a `method` column ('frequentist' | 'bayesian'). Lets one curve carry
--     both fits for direct comparison (compare_calibrations from SQL).
--   * Everything keyed on curve_id (from the existing curve_lookup) + method
--     (+ model_name / term / point where per-model or per-row).
--   * All FKs cascade from curve_lookup, so re-running a curve is a clean
--     delete-by-key + insert — no stale-row / duplicate-key class of bug.
--   * Column names mirror the calibration_result contract verbatim.
--
-- NON-DESTRUCTIVE: creates new calib_* tables only; does not touch bayes_* or
-- curve_lookup (curve_lookup is reused as-is: curve_id IDENTITY + curve_lookup_nk).
--
-- STATUS: v1, decisions locked. Sample identity = (patientid, sampleid,
-- timeperiod, dilution); inflection stored with x-CI; LOO/pareto-k group values
-- replicated per curve_id. Remaining open item is purely in the flattener, not
-- the schema: confirming exact loo_results field names when wiring it up.
-- =============================================================================

BEGIN;

SET search_path = madi_results;

-- ── Run-level provenance (one row per submitted job) ─────────────────────────
CREATE TABLE IF NOT EXISTS calib_run (
    job_id        varchar(64) PRIMARY KEY,
    method        text NOT NULL CHECK (method IN ('frequentist','bayesian')),
    package       text,
    version       text,
    best_model    text,
    params        jsonb,                 -- multiplate $meta (chains, warmup, pcov_threshold, seed, …)
    status        text,                  -- 'running' | 'completed' | 'failed'
    started_at    timestamptz DEFAULT now(),
    finished_at   timestamptz
);

-- ── Per-model fit + selection outcome ────────────────────────────────────────
-- grain: curve_id × method × model_name. Replaces bayes_curves(best) + bayes_ensemble(per-model).
CREATE TABLE IF NOT EXISTS calib_fit (
    curve_id            bigint NOT NULL
                        REFERENCES curve_lookup(curve_id) ON DELETE CASCADE,
    method              text   NOT NULL CHECK (method IN ('frequentist','bayesian')),
    model_name          text   NOT NULL,           -- logistic4/5, loglogistic5, gompertz4
    package             text,
    version             text,
    converged           boolean,
    eligible            boolean,
    is_best             boolean NOT NULL DEFAULT false,
    is_fallback         boolean,                    -- selection fell back (no eligible model)
    criterion           text,                       -- 'AIC+eligibility' | 'LOO+eligibility'
    score_type          text CHECK (score_type IN ('aic','loo_elpd')),
    selection_score     numeric,                    -- AIC value (freq) or LOO elpd (bayes)
    selection_weight    numeric,                    -- AIC weight (freq) or stacking weight (bayes)
    dynamic_range_log10 numeric,
    n_params            integer,
    job_id              varchar(64),
    created_at          timestamptz DEFAULT now(),
    PRIMARY KEY (curve_id, method, model_name)
);
CREATE INDEX IF NOT EXISTS idx_calib_fit_best
    ON calib_fit (curve_id, method) WHERE is_best;

-- ── Model parameters (long format) ───────────────────────────────────────────
-- grain: curve_id × method × model_name × term. Unifies freq (estimate/std_error)
-- and bayes (mean/sd + quantiles) — freq leaves the quantile cols NULL.
CREATE TABLE IF NOT EXISTS calib_param (
    curve_id    bigint NOT NULL,
    method      text   NOT NULL,
    model_name  text   NOT NULL,
    term        text   NOT NULL,          -- a, b, c, d, g
    estimate    numeric,                   -- freq $estimate / bayes $mean
    std_error   numeric,                   -- freq $std_error / bayes $sd
    q_lo        numeric,                   -- bayes q2.5  (freq NULL)
    q_med       numeric,                   -- bayes q50   (freq NULL)
    q_hi        numeric,                   -- bayes q97.5 (freq NULL)
    PRIMARY KEY (curve_id, method, model_name, term),
    FOREIGN KEY (curve_id, method, model_name)
        REFERENCES calib_fit (curve_id, method, model_name) ON DELETE CASCADE
);

-- ── Eligibility gate results ─────────────────────────────────────────────────
-- grain: curve_id × method × model_name × gate. (Alternative: fold into
-- calib_fit as jsonb; kept relational for queryability.)
CREATE TABLE IF NOT EXISTS calib_gate (
    curve_id    bigint NOT NULL,
    method      text   NOT NULL,
    model_name  text   NOT NULL,
    gate        text   NOT NULL,          -- at_bound | vcov_condition | rel_se | dynamic_range
    passed      boolean,
    detail      text,
    PRIMARY KEY (curve_id, method, model_name, gate),
    FOREIGN KEY (curve_id, method, model_name)
        REFERENCES calib_fit (curve_id, method, model_name) ON DELETE CASCADE
);

-- ── Best-model prediction + precision grid ───────────────────────────────────
-- grain: curve_id × method × point_index. Replaces bayes_curve_grid + bayes_cdan_grid.
CREATE TABLE IF NOT EXISTS calib_grid (
    curve_id                bigint NOT NULL
                            REFERENCES curve_lookup(curve_id) ON DELETE CASCADE,
    method                  text   NOT NULL,
    point_index             integer NOT NULL,       -- 1..n_grid
    model_name              text,                    -- best model this grid is for
    log10_concentration     numeric,
    concentration           numeric,
    predicted_response      numeric,                 -- fitted curve (MFI/OD scale)
    ci_lower                numeric,
    ci_upper                numeric,
    predicted_concentration numeric,                 -- back-calc precision profile
    se_concentration        numeric,                 -- uncapped log10-scale SD
    pcov                    numeric,                 -- capped percent CV
    pcov_rmse               numeric,
    pcov_pass               boolean,
    d2y_dx2                 numeric,
    noise_mode              text,                    -- bayes only; NULL for freq
    job_id                  varchar(64),
    created_at              timestamptz DEFAULT now(),
    PRIMARY KEY (curve_id, method, point_index)
);

-- ── Sample back-calculations ─────────────────────────────────────────────────
-- grain: curve_id × method × sample identity. Replaces bayes_samples.
-- Sample identity = (patientid, sampleid, timeperiod, dilution), scoped by curve_id.
-- (Additional design columns, e.g. cohort_arm/agroup for curveRweights, can be
--  added later as non-key carried columns without affecting the key.)
CREATE TABLE IF NOT EXISTS calib_samples (
    curve_id                bigint NOT NULL
                            REFERENCES curve_lookup(curve_id) ON DELETE CASCADE,
    method                  text   NOT NULL,
    sampleid                varchar(128) NOT NULL,
    patientid               varchar(128) DEFAULT '__none__' NOT NULL,
    timeperiod              varchar(64)  DEFAULT '__none__' NOT NULL,
    dilution                varchar(64)  DEFAULT '__none__' NOT NULL,
    predicted_concentration numeric,                 -- log10 scale (when is_log_independent)
    final_concentration     numeric,                 -- natural scale, dilution-corrected
    se_concentration        numeric,
    pcov                    numeric,
    pcov_rmse               numeric,
    pcov_pass               boolean,
    job_id                  varchar(64),
    created_at              timestamptz DEFAULT now(),
    PRIMARY KEY (curve_id, method, sampleid, patientid, timeperiod, dilution)
);
CREATE INDEX IF NOT EXISTS idx_calib_samples_patient
    ON calib_samples (curve_id, patientid);

-- ── Per-curve diagnostics (best model) ───────────────────────────────────────
-- grain: curve_id × method. Replaces the diagnostic columns of bayes_curves.
CREATE TABLE IF NOT EXISTS calib_diagnostics (
    curve_id             bigint NOT NULL
                         REFERENCES curve_lookup(curve_id) ON DELETE CASCADE,
    method               text   NOT NULL,
    model_name           text,
    -- pcov-threshold LOQs (from eligibility, log10 + natural)
    lloq_log10           numeric,
    uloq_log10           numeric,
    lloq_conc            numeric,
    uloq_conc            numeric,
    -- curvature (shape) LOQs
    shape_lloq_log10     numeric,
    shape_uloq_log10     numeric,
    shape_lloq_conc      numeric,
    shape_uloq_conc      numeric,
    -- inflection point with credible/confidence interval on x (populated from
    -- the posterior for bayes; left NULL by a method that yields no CI)
    inflect_x            numeric,
    inflect_y            numeric,
    inflect_x_lower      numeric,
    inflect_x_upper      numeric,
    -- LODs (response + log10 + natural)
    lower_lod_response   numeric,
    upper_lod_response   numeric,
    lower_lod_log10_conc numeric,
    upper_lod_log10_conc numeric,
    lower_lod_conc       numeric,
    upper_lod_conc       numeric,
    -- MDC / RDL
    mdc_lower_log10      numeric,
    mdc_upper_log10      numeric,
    mdc_lower_conc       numeric,
    mdc_upper_conc       numeric,
    rdl_lower_log10      numeric,
    rdl_upper_log10      numeric,
    rdl_lower_conc       numeric,
    rdl_upper_conc       numeric,
    -- context
    pcov_threshold       numeric,
    cv_x_max             numeric,
    alpha                numeric,
    job_id               varchar(64),
    created_at           timestamptz DEFAULT now(),
    PRIMARY KEY (curve_id, method)
);

-- ── LOO / PSIS diagnostics (bayesian only) ───────────────────────────────────
-- grain: curve_id × method × model_name. Replaces bayes_pareto_k, now curve-keyed.
-- LOO/pareto-k are computed once on the pooled multi-curve fit (per method ×
-- model_name across a group of curve_ids). The flattener writes those SAME
-- group-level values onto EVERY curve_id in the group, by design: querying the
-- LOO/pareto-k for one curve_id is then a single-key lookup with no need to
-- track which group it belonged to.
CREATE TABLE IF NOT EXISTS calib_loo (
    curve_id        bigint NOT NULL,
    method          text   NOT NULL DEFAULT 'bayesian',
    model_name      text   NOT NULL,
    elpd_loo        numeric,
    se_elpd_loo     numeric,
    p_loo           numeric,
    looic           numeric,
    elpd_diff       numeric,
    se_diff         numeric,
    pareto_k_good   integer,             -- k < 0.5
    pareto_k_ok     integer,             -- 0.5 <= k < 0.7
    pareto_k_bad    integer,             -- 0.7 <= k < 1
    pareto_k_vbad   integer,             -- k >= 1
    job_id          varchar(64),
    created_at      timestamptz DEFAULT now(),
    PRIMARY KEY (curve_id, method, model_name),
    FOREIGN KEY (curve_id, method, model_name)
        REFERENCES calib_fit (curve_id, method, model_name) ON DELETE CASCADE
);

COMMIT;
