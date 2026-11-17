-- =============================================================================
-- Migration 002: Pareto k diagnostics table + asymmetry columns on bayes_curves
--
-- Adds two new pieces of output that were previously only available from a
-- live Stan fit object:
--
--   1. madi_results.bayes_pareto_k  (new table)
--      One row per (antigen × family) — Pareto k leave-one-out diagnostic
--      summary for each of the 3 model families.  Mirrors what i-spi shows in
--      the "Pareto k Diagnostics" panel of the Model Comparisons modal.
--
--   2. Asymmetry columns on madi_results.bayes_curves  (11 new columns)
--      Per-plate posterior summary of the g (asymmetry) parameter plus the
--      global batch-level prob_4pl probability.  Mirrors bayes_state$asymmetry
--      in i-spi (the P(4PL) shown in the plate summary and notification).
--
-- Run order: after 001 (initial schema).
-- Idempotent: uses ADD COLUMN IF NOT EXISTS / CREATE TABLE IF NOT EXISTS.
-- =============================================================================

-- ── 1. New table: bayes_pareto_k ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS madi_results.bayes_pareto_k (
  bayes_pareto_k_id     SERIAL          PRIMARY KEY,
  project_id            INTEGER         NOT NULL,
  study_accession       TEXT            NOT NULL,
  experiment_accession  TEXT            NOT NULL,
  antigen               TEXT            NOT NULL,
  family                TEXT            NOT NULL,   -- '4pl' | '5pl' | 'gompertz'

  -- Pareto k bin counts (loo::pareto_k_values() thresholds)
  n_good                INTEGER,                    -- k ≤ 0.5   (reliable)
  n_ok                  INTEGER,                    -- 0.5 < k ≤ 0.7  (ok)
  n_bad                 INTEGER,                    -- 0.7 < k ≤ 1.0  (bad)
  n_vbad                INTEGER,                    -- k > 1.0   (very bad)
  max_k                 DOUBLE PRECISION,           -- worst single observation

  job_id                TEXT,
  created_at            TIMESTAMPTZ     DEFAULT NOW(),

  UNIQUE (project_id, study_accession, experiment_accession, antigen, family)
);

-- ── 2. Asymmetry columns on bayes_curves ─────────────────────────────────────
--
-- All columns are NULL for Gompertz fits (no g parameter) or when
-- summarize_asymmetry() fails.
--
-- Global (same value replicated across all plate rows for a given fit):
--   prob_4pl      — P(|mu_log_g| < 0.1): probability the batch is effectively
--                   symmetric (4PL sufficient).  > 0.8 → symmetric,
--                   < 0.3 → genuine asymmetry, otherwise ambiguous.
--   g_prior_mode  — label for the prior placed on mu_log_g (e.g. "normal")
--   mu_log_g_*    — posterior summary of the batch-level log(g) hyperparameter
--
-- Per-plate (indexed to this plate's row):
--   g_mean / g_median / g_sd / g_q2p5 / g_q97p5
--             — posterior summary of the plate-level g parameter
--               (g = 1 ↔ symmetric 4PL; g ≠ 1 ↔ asymmetric 5PL)

ALTER TABLE madi_results.bayes_curves
  ADD COLUMN IF NOT EXISTS prob_4pl         DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS g_prior_mode     TEXT,
  ADD COLUMN IF NOT EXISTS g_mean           DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS g_median         DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS g_sd             DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS g_q2p5           DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS g_q97p5          DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS mu_log_g_mean    DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS mu_log_g_sd      DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS mu_log_g_q2p5    DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS mu_log_g_q97p5   DOUBLE PRECISION;
