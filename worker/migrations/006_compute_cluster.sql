-- =============================================================================
-- Migration 006: compute_cluster setting
--
-- Registers a new settings-cascade param that names WHICH deployed
-- i-spi-compute clone (API+Redis+worker stack) a project/study is routed to,
-- as new clones are stood up for capacity (see
-- dev/HANDOFF_configurable_compute_backend.md in i-spi-refactor). The value
-- is a free-text LABEL only (e.g. "default", "clone-b") -- NOT a URL or API
-- key. The label is resolved against a small env-var-backed registry at the
-- app layer (i-spi-refactor's src/compute_cluster_registry.R), so secrets
-- never enter this settings store or its export/import surface
-- (settings_export_import_ui.R).
--
-- calib_settings_meta already exists (created by i-spi-refactor's
-- dead/migrate_study_config_cascade.sql, already applied) -- this migration
-- only adds one row to it. No new table, and deliberately NO row inserted
-- into calib_settings itself: an unset compute_cluster resolves to NULL from
-- resolve_settings() (absent from the result set, same as any other param
-- with no value at any tier), which resolve_compute_cluster() treats as
-- "use the default clone" -- i.e. today's single ISPI_COMPUTE_URL /
-- ISPI_COMPUTE_API_KEY pair, unchanged, for every project with no explicit
-- assignment. Zero required migration for existing projects.
--
-- param_group = 'infrastructure' (new group; distinct from 'calibration' and
-- 'assay_import', the only two groups that exist today) -- this is an
-- ops/routing knob, not a curve-fitting or assay-import setting. The generic
-- settings editor (settings_cascade_ui.R's .group_title()) titlecases any
-- group string automatically, so no UI code change is needed for a new group.
--
-- param_control_type = 'textInput' is a deliberate, safe fallback, same
-- reasoning as 005's own choice: valid cluster labels are deployment-specific
-- (how many clones exist, and their names, is a Kubernetes-layer decision,
-- not known at migration-write time) -- a param_choices_list enum would need
-- a NEW migration every time a clone is added or renamed. A free-text field
-- lets an admin type any label; an unrecognized one falls back to "default"
-- with a warning() logged server-side (see resolve_compute_cluster()), it
-- never hard-fails the app.
--
-- Idempotent: ON CONFLICT on calib_settings_meta's param_name PRIMARY KEY.
-- Run order: after 001 (initial schema) -- no dependency on 002-005.
--
-- *** MUST BE APPLIED BY HAND AGAINST THE DEPLOYED DATABASE. This repo's
-- *** tooling cannot run it; run it the same way 005 was applied.
-- =============================================================================

INSERT INTO madi_results.calib_settings_meta
  (param_name, param_group, param_label, param_data_type, param_control_type,
   param_description)
VALUES
  ('compute_cluster', 'infrastructure',
   'Compute cluster (i-spi-compute clone routing label)',
   'character', 'textInput',
   'Which deployed i-spi-compute clone this project/study submits fit jobs to. '
   || 'Leave unset to use the default clone. Must match a clone label the app '
   || 'is configured with (ISPI_COMPUTE_URL__<LABEL> env var on the app pod) -- '
   || 'an unrecognized label silently falls back to the default clone.')
ON CONFLICT (param_name) DO NOTHING;
