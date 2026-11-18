-- =============================================================================
-- Migration 011: estimates for controls and calibrators, control reference
-- values, release-manifest provenance (curveRcore >= 0.7.0)
--
-- * calib_controls (new): one row per control well, curve and method, with the
--   modelled estimates calib_samples holds for test samples. Masked controls are
--   estimated too (included = false).
-- * calib_standards: the same estimate columns plus recovery_pct (nullable; key
--   and existing columns unchanged; rows written earlier keep NULL until the
--   one-off backfill, worker/backfill_point_estimates.R, or a refit).
-- * control_reference (new, owned by I-SPI) and view calib_controls_qc: expected
--   values of controls joined to the estimates by run date.
-- * calib_run.manifest (jsonb): the release manifest each job ran under.
-- * schema_version (new): records calib_schema 0.7.0.
-- * control_for_fit (new view): control wells per curve, matched like
--   sample_for_fit (every standard source of the plate), masked wells included.
--
-- The canonical definition is curveRcore R/calib_schema.sql and
-- curveRcore::point_estimates_contract(); every statement below except
-- control_for_fit is copied verbatim from it (generated, do not edit by hand).
--
-- Safe while the app and workers are running: new tables and views, and nullable
-- ADD COLUMN without a default (metadata-only). lock_timeout makes the migration
-- give up instead of queueing behind a long-running query. Apply BEFORE rolling a
-- worker built on curveRcore >= 0.7.0.
--
-- Run order: after 001-010. Idempotent. Run as the table owner.
-- Prerequisites: curve_lookup, xmap_control, xmap_header.
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '5s';

-- ---- calib_run.manifest -------------------------------------------------------
ALTER TABLE madi_results.calib_run
    ADD COLUMN IF NOT EXISTS manifest jsonb;

-- ---- calib_standards: estimate columns ----------------------------------------
ALTER TABLE madi_results.calib_standards
    ADD COLUMN IF NOT EXISTS predicted_concentration numeric,
    ADD COLUMN IF NOT EXISTS predicted_log10_concentration numeric,
    ADD COLUMN IF NOT EXISTS final_concentration numeric,
    ADD COLUMN IF NOT EXISTS se_concentration numeric,
    ADD COLUMN IF NOT EXISTS pcov numeric,
    ADD COLUMN IF NOT EXISTS pcov_rmse numeric,
    ADD COLUMN IF NOT EXISTS pcov_pass boolean,
    ADD COLUMN IF NOT EXISTS pcov_gate_class text CHECK (pcov_gate_class IN ('belowLLOQ','inDynamicRange','aboveULOQ')),
    ADD COLUMN IF NOT EXISTS censor_class text CHECK (censor_class IN ('quantified','lod_to_lloq','below_lod',
                                                                       'below_lloq','above_uloq','saturated','no_response')),
    ADD COLUMN IF NOT EXISTS censor_type text CHECK (censor_type IN ('none','left','interval','right')),
    ADD COLUMN IF NOT EXISTS censor_lower double precision,
    ADD COLUMN IF NOT EXISTS censor_upper double precision,
    ADD COLUMN IF NOT EXISTS conc_q_lo double precision,
    ADD COLUMN IF NOT EXISTS conc_q_med double precision,
    ADD COLUMN IF NOT EXISTS conc_q_hi double precision,
    ADD COLUMN IF NOT EXISTS p_below_lloq double precision,
    ADD COLUMN IF NOT EXISTS p_above_uloq double precision,
    ADD COLUMN IF NOT EXISTS p_below_cutoff double precision,
    ADD COLUMN IF NOT EXISTS frac_draws_below_a double precision,
    ADD COLUMN IF NOT EXISTS frac_draws_above_d double precision,
    ADD COLUMN IF NOT EXISTS recovery_pct double precision;

-- ---- calib_controls -------------------------------------------------------------
CREATE TABLE IF NOT EXISTS madi_results.calib_controls (
    curve_id bigint NOT NULL,
    method character varying(20) NOT NULL,
    well character varying(20) NOT NULL,
    sampleid character varying(128),
    source character varying(64),
    dilution numeric,
    included boolean NOT NULL,
    exclusion_reason character varying(20) NOT NULL DEFAULT 'none'::character varying,
    mask_reason character varying,
    concentration numeric,
    log10_concentration numeric,
    response_model numeric,
    assay_response_raw numeric,
    predicted_concentration numeric,
    predicted_log10_concentration numeric,
    final_concentration numeric,
    se_concentration numeric,
    pcov numeric,
    pcov_rmse numeric,
    pcov_pass boolean,
    pcov_gate_class text CHECK (pcov_gate_class IN ('belowLLOQ','inDynamicRange','aboveULOQ')),
    censor_class text CHECK (censor_class IN ('quantified','lod_to_lloq','below_lod',
                                              'below_lloq','above_uloq','saturated','no_response')),
    censor_type text CHECK (censor_type IN ('none','left','interval','right')),
    censor_lower double precision,
    censor_upper double precision,
    conc_q_lo double precision,
    conc_q_med double precision,
    conc_q_hi double precision,
    p_below_lloq double precision,
    p_above_uloq double precision,
    p_below_cutoff double precision,
    frac_draws_below_a double precision,
    frac_draws_above_d double precision,
    job_id character varying(64),
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT calib_controls_pkey PRIMARY KEY (curve_id, method, well),
    CONSTRAINT calib_controls_curve_id_fkey FOREIGN KEY (curve_id) REFERENCES madi_results.curve_lookup(curve_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_calib_controls_source
    ON madi_results.calib_controls USING btree (curve_id, source);

-- ---- control_reference + calib_controls_qc ---------------------------------------
CREATE TABLE IF NOT EXISTS madi_results.control_reference (
    reference_id bigint GENERATED ALWAYS AS IDENTITY,
    project_id integer NOT NULL,
    study_accession character varying(15) NOT NULL DEFAULT '__none__'::character varying,
    control_source character varying(64) NOT NULL,
    control_lot character varying(64) NOT NULL DEFAULT '__none__'::character varying,
    antigen character varying(64) NOT NULL,
    feature character varying(15) NOT NULL DEFAULT '__none__'::character varying,
    units text,
    expected_conc numeric,
    expected_sd numeric,
    lower_limit numeric,
    upper_limit numeric,
    basis text,
    valid_from date NOT NULL DEFAULT '-infinity'::date,
    valid_to date,
    assigned_by text,
    assigned_at timestamp with time zone NOT NULL DEFAULT now(),
    note text,
    CONSTRAINT control_reference_pkey PRIMARY KEY (reference_id),
    CONSTRAINT control_reference_scope_uniq UNIQUE (project_id, study_accession, control_source, control_lot, antigen, feature, valid_from),
    CONSTRAINT control_reference_basis_chk CHECK (basis IS NULL OR basis IN ('certificate','assigned','historical')),
    CONSTRAINT control_reference_period_chk CHECK (valid_to IS NULL OR valid_to > valid_from),
    CONSTRAINT control_reference_limits_chk CHECK (lower_limit IS NULL OR upper_limit IS NULL OR lower_limit <= upper_limit),
    CONSTRAINT control_reference_sd_chk CHECK (expected_sd IS NULL OR expected_sd > 0)
);

-- Prerequisites (external, not created here): curve_lookup and xmap_header.
CREATE OR REPLACE VIEW madi_results.calib_controls_qc AS
SELECT cc.curve_id, cc.method, cc.well, cc.sampleid, cc.source, cc.dilution,
       cc.included, cc.exclusion_reason, cc.mask_reason,
       cc.final_concentration, cc.predicted_log10_concentration, cc.se_concentration,
       cc.pcov, cc.pcov_pass, cc.pcov_gate_class, cc.censor_class, cc.censor_type,
       cc.conc_q_lo, cc.conc_q_med, cc.conc_q_hi, cc.job_id,
       cl.project_id, cl.study_accession, cl.experiment_accession, cl.plateid, cl.plate,
       cl.antigen, cl.feature, cl.source AS standard_source, cl.wavelength,
       hd.run_date,
       r.reference_id, r.control_lot, r.units, r.expected_conc, r.expected_sd,
       r.lower_limit, r.upper_limit, r.basis,
       CASE WHEN r.expected_conc > 0 AND cc.final_concentration IS NOT NULL
            THEN 100 * cc.final_concentration / r.expected_conc END AS recovery_pct,
       CASE WHEN r.expected_sd > 0 AND cc.final_concentration IS NOT NULL
            THEN (cc.final_concentration - r.expected_conc) / r.expected_sd END AS z_score,
       CASE WHEN cc.final_concentration IS NULL
              OR (r.lower_limit IS NULL AND r.upper_limit IS NULL) THEN NULL
            ELSE cc.final_concentration >= COALESCE(r.lower_limit, cc.final_concentration)
             AND cc.final_concentration <= COALESCE(r.upper_limit, cc.final_concentration)
       END AS within_limits
FROM madi_results.calib_controls cc
JOIN madi_results.curve_lookup cl ON cl.curve_id = cc.curve_id
LEFT JOIN LATERAL (
    SELECT min(h.acquisition_date) AS run_date
    FROM madi_results.xmap_header h
    WHERE h.project_id = cl.project_id
      AND h.study_accession = cl.study_accession
      AND h.experiment_accession = cl.experiment_accession
      AND h.plateid = cl.plateid
) hd ON true
LEFT JOIN LATERAL (
    SELECT r0.*
    FROM madi_results.control_reference r0
    WHERE r0.project_id = cl.project_id
      AND r0.study_accession IN (cl.study_accession, '__none__')
      AND r0.control_source = cc.source
      AND r0.antigen = cl.antigen
      AND r0.feature IN (cl.feature, '__none__')
      AND (hd.run_date IS NULL
           OR (r0.valid_from <= hd.run_date::date
               AND (r0.valid_to IS NULL OR hd.run_date::date < r0.valid_to)))
    ORDER BY (r0.study_accession <> '__none__') DESC, (r0.feature <> '__none__') DESC,
             r0.valid_from DESC
    LIMIT 1
) r ON true;

-- ---- control_for_fit: control wells per curve (masked wells included) ----------
-- Same matching as sample_for_fit: plate, nominal sample dilution, wavelength,
-- antigen and feature, so a control is read on every standard source of its
-- plate. `source` is the curve's standard source (as in sample_for_fit);
-- `control_source` is the control's own name, written to calib_controls.source.
CREATE OR REPLACE VIEW madi_results.control_for_fit AS
 SELECT cl.curve_id,
    cl.multiplate_group_id,
    c.project_id,
    c.study_accession,
    c.experiment_accession,
    cl.antigen,
    cl.feature,
    cl.source,
    cl.wavelength,
    cl.nominal_sample_dilution,
    c.plate,
    c.plateid,
    c.well,
    c.sampleid,
    c.source AS control_source,
    c.dilution,
    c.antibody_mfi AS mfi,
    c.antibody_n,
    c.masked,
    c.mask_reason
   FROM (madi_results.xmap_control c
     JOIN madi_results.curve_lookup cl ON (((cl.project_id = c.project_id) AND ((cl.study_accession)::text = (c.study_accession)::text) AND ((cl.experiment_accession)::text = (c.experiment_accession)::text) AND ((cl.plateid)::text = (c.plateid)::text) AND ((cl.plate)::text = (c.plate)::text) AND ((cl.nominal_sample_dilution)::text = (c.nominal_sample_dilution)::text) AND ((cl.wavelength)::text = (COALESCE(c.wavelength, '__none__'::character varying))::text) AND ((cl.antigen)::text = (COALESCE(c.antigen, '__none__'::character varying))::text) AND ((cl.feature)::text = (COALESCE(c.feature, '__none__'::character varying))::text) AND (cl.masked = false))));

-- ---- schema_version (last: recorded only if everything above applied) ----------
CREATE TABLE IF NOT EXISTS madi_results.schema_version (
    component text NOT NULL,
    version text NOT NULL,
    description text,
    applied_at timestamp with time zone NOT NULL DEFAULT now(),
    applied_by text NOT NULL DEFAULT current_user,
    CONSTRAINT schema_version_pkey PRIMARY KEY (component, version)
);

INSERT INTO madi_results.schema_version (component, version, description)
VALUES ('calib_schema', '0.7.0',
        'curveRcore calib_* contract: calib_controls, calib_standards estimates, control_reference, calib_run.manifest, schema_version')
ON CONFLICT (component, version) DO NOTHING;

COMMIT;
