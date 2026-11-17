-- =============================================================================
-- Migration 003: agroup column on calib_samples + sample_for_fit passthrough
--
-- Adds the treatment-arm/cohort design column needed by curveRweights'
-- saturated cell-means location model (fit_precision_weights(), via
-- as_weight_data(design = c("timeperiod", "agroup"))). Named to match the
-- source column exactly at every layer -- madi_results.xmap_sample.agroup ->
-- sample_for_fit (added here) -> worker samples frame -> curveRfreq/curveRbayes
-- $samples passthrough (unmodified, no package change needed) -> calib_samples.
--
-- Confirmed 2026-10-04: xmap_sample.agroup exists, but madi_results.sample_for_fit
-- did not select it (verified via `SELECT column_name FROM information_schema.
-- columns WHERE table_name='sample_for_fit'` -- 20 columns, no agroup). Its
-- JOIN is directly against xmap_sample (not through sample_unmasked), so the
-- column is already in scope -- this just adds it to the SELECT list.
--
-- calib_samples: non-key carried column, exactly as anticipated by the comment
-- already on this table (see calib_schema_v1.sql): "Additional design columns,
-- e.g. cohort_arm/agroup for curveRweights, can be added later as non-key
-- carried columns without affecting the key."
--
-- varchar(40) mirrors madi_results.xmap_sample.agroup's declared width.
--
-- Run order: after 001 (initial schema) and 002 (pareto/asymmetry). Idempotent:
-- ADD COLUMN IF NOT EXISTS / CREATE INDEX IF NOT EXISTS / CREATE OR REPLACE VIEW.
-- Run as the view's owner (matches create_unmasked_views.sql convention).
-- =============================================================================

-- ── 1. calib_samples: add the column ─────────────────────────────────────────

ALTER TABLE madi_results.calib_samples
  ADD COLUMN IF NOT EXISTS agroup varchar(40);

-- Supports the curveRweights precision-weighting job's read pattern: pull all
-- persisted samples for a (curve_id scope, design-cell) combination. Mirrors
-- the shape of the existing idx_calib_samples_patient index.
CREATE INDEX IF NOT EXISTS idx_calib_samples_agroup
    ON madi_results.calib_samples (curve_id, agroup);

-- ── 2. sample_for_fit: add agroup to the output ──────────────────────────────
-- Reproduced verbatim from `SELECT pg_get_viewdef('madi_results.sample_for_fit',
-- true)` (captured 2026-10-04), with ONLY `s.agroup` appended to the SELECT
-- list (last position -- CREATE OR REPLACE VIEW cannot reorder or remove
-- existing output columns, only append). FROM/JOIN/WHERE are byte-identical to
-- the live definition; verify against pg_get_viewdef again before applying if
-- this view has changed since 2026-10-04.
--
-- Safe for existing readers: the worker's fetch_smp_for_fit() does
-- `SELECT * FROM sample_for_fit`, so the new trailing column is additive only.

CREATE OR REPLACE VIEW madi_results.sample_for_fit AS
 SELECT cl.curve_id,
    cl.multiplate_group_id,
    s.project_id,
    s.study_accession,
    s.experiment_accession,
    cl.antigen,
    cl.feature,
    cl.source,
    cl.wavelength,
    cl.nominal_sample_dilution,
    s.plate,
    s.plateid,
    s.well,
    s.sampleid,
    s.patientid,
    s.timeperiod,
    s.source AS sample_source,
    s.dilution,
    s.antibody_mfi AS mfi,
    s.antibody_n,
    s.agroup
   FROM madi_results.xmap_sample s
     JOIN madi_results.curve_lookup cl ON cl.project_id = s.project_id AND cl.study_accession::text = s.study_accession::text AND cl.experiment_accession::text = s.experiment_accession::text AND cl.plateid::text = s.plateid::text AND cl.plate::text = s.plate::text AND cl.nominal_sample_dilution::text = s.nominal_sample_dilution::text AND cl.wavelength::text = COALESCE(s.wavelength, '__none__'::character varying)::text AND cl.antigen::text = COALESCE(s.antigen, '__none__'::character varying)::text AND cl.feature::text = COALESCE(s.feature, '__none__'::character varying)::text AND cl.masked = false
  WHERE s.masked = false;
