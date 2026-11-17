-- =============================================================================
-- Migration 007: backfill standard_dilution_reference's param_description
--
-- 005_standard_dilution_reference.sql's INSERT never set param_description,
-- so the Calibration Settings page shows this row with no one-line
-- explanation underneath the label, unlike every other param on that page.
-- Found 2026-10-09 during live testing. Fixed here as an UPDATE, not a
-- correction to 005's INSERT, because 005 already ran against every existing
-- deployment and its ON CONFLICT ... DO NOTHING would silently no-op a
-- re-run -- an UPDATE is the only way this actually reaches an install that
-- already has the row. 005 itself is also corrected going forward, for a
-- fresh install that hasn't run it yet.
--
-- Idempotent: an UPDATE ... WHERE param_description IS NULL only ever touches
-- the row once; running this twice is a no-op the second time.
-- Run order: after 005 (the row must already exist).
--
-- *** MUST BE APPLIED BY HAND AGAINST THE DEPLOYED DATABASE, same as 006.
-- =============================================================================

UPDATE madi_results.calib_settings_meta
SET param_description =
  'Usually set automatically during import (Standards dilution reference step); '
  || 'edit here directly only to add or correct a value for the whole study '
  || 'without re-importing.'
WHERE param_name = 'standard_dilution_reference'
  AND param_description IS NULL;
