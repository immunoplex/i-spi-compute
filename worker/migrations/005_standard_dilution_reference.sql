-- =============================================================================
-- Migration 005: standard_dilution_reference setting
--
-- Registers a new settings-cascade param for the bead (.rbx/.srbx) assay
-- import pipeline's Standards reference table (RBX_DILUTION_AUTHORITATIVE_
-- SOURCE_PLAN.md, i-spi-refactor repo). Standards/calibrator wells whose
-- dilution cannot be recovered from the instrument file (the Bio-Plex binary
-- carries no usable value for Standards -- confirmed empirically, see that
-- plan's Phase 0 Findings) or from the Description text (no "1:N" ratio) need
-- the user to supply an explicit label->dilution mapping once per experiment.
-- That mapping is entered in-context during import (assay_std_reference_ui.R,
-- "Stage 1.5" of the pre-processor) and persists here so repeat batches in the
-- same experiment don't re-prompt for descriptions already seen.
--
-- calib_settings_meta already exists (created by i-spi-refactor's
-- dead/migrate_study_config_cascade.sql, already applied) -- this migration
-- only adds one row to it. No new table.
--
-- Value shape: param_character_value holds a JSON array of
-- {"description": <raw Description text, exact match>, "dilution": <number>}
-- objects -- NOT an ordinal/positional list (a lab's internal standard
-- labels aren't guaranteed to contain digits at all; see .rbx_type_from() in
-- reader_bead_rbx.R, which collapses every Standard on a plate to type code
-- "S" with no suffix when they don't). Parsed/serialized by
-- ai_std_reference_parse()/ai_std_reference_serialize() in
-- assay_std_reference_rules.R.
--
-- Scope: requires experiment (not just project+study) -- a study commonly
-- runs different standard-curve designs across its experiments, confirmed by
-- the user during design. feature/antigen stay wildcarded ('__none__'): a
-- well's dilution doesn't depend on which antigen column is read off it.
-- param_control_type = 'textInput' is a deliberate, safe fallback: the
-- generic settings editor (settings_cascade_ui.R's .value_control()) renders
-- any unrecognized control type as a plain text box, so an admin could still
-- view/edit the raw JSON there if ever needed -- but the intended entry
-- point is the import-time Stage 1.5 screen, not this generic editor.
--
-- Idempotent: ON CONFLICT on calib_settings_meta's param_name PRIMARY KEY.
-- Run order: after 001 (initial schema) -- no dependency on 002-004.
--
-- param_description added 2026-10-09 (originally missing -- see migration 007,
-- which backfills this for any install that already ran this file before the
-- description existed here).
-- =============================================================================

INSERT INTO madi_results.calib_settings_meta
  (param_name, param_group, param_label, param_data_type, param_control_type,
   param_description)
VALUES
  ('standard_dilution_reference', 'assay_import',
   'Standard curve dilution reference (label -> dilution, JSON)',
   'character', 'textInput',
   'Usually set automatically during import (Standards dilution reference step); '
   || 'edit here directly only to add or correct a value for the whole study '
   || 'without re-importing.')
ON CONFLICT (param_name) DO NOTHING;
