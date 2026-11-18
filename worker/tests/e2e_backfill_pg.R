#!/usr/bin/env Rscript
# =============================================================================
# e2e_backfill_pg.R -- end-to-end test of migration 011 and
# backfill_point_estimates.R against a LOCAL throwaway PostgreSQL (never the
# shared DB). Wrapper: e2e_backfill_pg.sh starts/stops the temp server.
#
# Env: PGPORT, PSQL, CORE_DDL_060 (curveRcore 0.6.0 R/calib_schema.sql: the
# schema before this change), R_LIBS (curveRcore >= 0.7.0, curveRfreq,
# curveRbayes), E2E_SKIP_BAYES=1 to skip the Bayesian scenario.
#
# The stored fits are made by the real engines and saved with the worker's own
# flatten_result()/save_calib(), so the database looks exactly like a curve
# fitted before 0.7.0: calib_standards rows without estimates, no controls.
# Control wells are copies of some fitted test samples, so each backfilled
# control can be compared with the estimate the ENGINE stored for the same
# response in calib_samples.
#
# Scenarios
#   M  migration 011 on the 0.6.0 schema; re-applied (idempotent)
#   F  frequentist fit: dry run writes nothing; backfill fills standards and
#      controls; controls equal the engine's sample estimates; masked control
#      estimated with included = false; second run has nothing to do
#   R  control_reference + calib_controls_qc give recovery for the control
#   B  bayesian fit with persisted draws: controls agree with the engine's
#      sample estimates within Monte Carlo error
# =============================================================================
suppressMessages({ library(DBI); library(RPostgres) })
port <- Sys.getenv("PGPORT", "54332"); psql <- Sys.getenv("PSQL", "psql")
ddl060 <- Sys.getenv("CORE_DDL_060")
here <- dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])))
mig011 <- file.path(here, "..", "migrations", "011_point_estimates_reference_manifest.sql")
stopifnot(file.exists(ddl060), file.exists(mig011),
          utils::packageVersion("curveRcore") >= "0.7.0")
source(file.path(here, "..", "flatten_and_save.R"))
source(file.path(here, "..", "backfill_point_estimates.R"))
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

results <- list()
check <- function(id, ok, what) {
  results[[length(results) + 1L]] <<- data.frame(scenario = id, ok = isTRUE(ok), check = what)
  cat(sprintf("  [%s] %s  %s\n", if (isTRUE(ok)) "PASS" else "FAIL", id, what))
}
run_sql <- function(file, db = "bf") {
  st <- system2(psql, c("-h", "localhost", "-p", port, "-U", "tester", "-d", db, "-q",
                        "-v", "ON_ERROR_STOP=1", "-f", shQuote(file, type = "cmd")),
                stdout = FALSE, stderr = FALSE)
  as.integer(st)
}
admin <- dbConnect(RPostgres::Postgres(), dbname = "postgres", host = "localhost",
                   port = as.integer(port), user = "tester")
invisible(dbExecute(admin, "DROP DATABASE IF EXISTS bf")); invisible(dbExecute(admin, "CREATE DATABASE bf"))
dbDisconnect(admin)

# ---- M: 0.6.0 schema + prerequisites, then migration 011 -------------------------
stub <- tempfile(fileext = ".sql")
writeLines("CREATE SCHEMA madi_results;
CREATE TABLE madi_results.curve_lookup (curve_id bigint PRIMARY KEY, project_id int,
  study_accession varchar(15), experiment_accession varchar(15), plateid varchar(100),
  plate varchar(40), nominal_sample_dilution varchar(128), feature varchar(15),
  antigen varchar(64), source varchar(25), wavelength varchar(15),
  masked boolean NOT NULL DEFAULT false, multiplate_group_id uuid);
CREATE TABLE madi_results.xmap_control (project_id int, study_accession varchar(15),
  experiment_accession varchar(15), plate_id varchar(640), plateid varchar(128),
  plate varchar(15), nominal_sample_dilution varchar(128), well varchar(6),
  sampleid varchar(15), source varchar(25), dilution numeric(9,0), antigen varchar(64),
  feature varchar(15), wavelength varchar(15), antibody_mfi numeric(12,4),
  antibody_n int, masked boolean NOT NULL DEFAULT false, mask_reason text);
CREATE TABLE madi_results.xmap_header (project_id int, study_accession varchar(15),
  experiment_accession varchar(15), plateid varchar(2024), acquisition_date timestamptz);", stub)
cat("M: migration 011 on the 0.6.0 schema\n")
check("M", run_sql(stub) == 0 && run_sql(ddl060) == 0, "0.6.0 schema + prerequisites created")
check("M", run_sql(mig011) == 0, "migration 011 applies")
check("M", run_sql(mig011) == 0, "migration 011 re-applies (idempotent)")
con <- dbConnect(RPostgres::Postgres(), dbname = "bf", host = "localhost",
                 port = as.integer(port), user = "tester", options = "-c search_path=madi_results")
check("M", identical(dbGetQuery(con, "SELECT version FROM schema_version WHERE component='calib_schema'")$version, "0.7.0"),
      "schema_version records calib_schema 0.7.0")
cols <- dbGetQuery(con, "SELECT column_name FROM information_schema.columns
                          WHERE table_schema='madi_results' AND table_name='calib_controls' ORDER BY ordinal_position")$column_name
check("M", identical(cols, curveRcore::point_estimates_contract("controls")$column), "calib_controls matches the contract")

# ---- stored fits made by the real engines -------------------------------------
data("bead_assay_example", package = "curveRcore")
ex <- bead_assay_example
prep <- function(cid) {
  p <- curveRcore::preprocess_standards(
    data = ex$standards[ex$standards$curve_id == cid, ],
    antigen_settings = list(standard_curve_concentration = 10000),
    response_variable = "mfi", independent_variable = "concentration",
    is_log_response = TRUE, is_log_independent = TRUE, apply_prozone = TRUE)
  p$data$curve_id <- cid; p
}
post <- function(mp) curveRcore::classify_censoring_multiplate(
  curveRcore::classify_pcov_gates_multiplate(curveRcore::compute_detection_limits_multiplate(mp)))

store_fit <- function(cids, method, job_id, mp, pp) {
  flat <- flatten_result(mp, job_id = job_id, method = method)
  pts <- flatten_calib_points(pp, job_id = job_id, method = method, response_var = "mfi",
                              is_log_independent = TRUE)
  flat$standards <- pts$standards; flat$blanks <- pts$blanks
  save_calib(con, flat, verbose = FALSE)
}
add_curves <- function(cids, plate) {
  dbAppendTable(con, "curve_lookup", data.frame(
    curve_id = cids, project_id = 92L, study_accession = "S1", experiment_accession = "E1",
    plateid = plate, plate = plate, nominal_sample_dilution = "2000", feature = "IgG",
    antigen = "PT", source = paste0("Std", seq_along(cids)), wavelength = "__none__",
    masked = FALSE, multiplate_group_id = "aaaaaaaa-0000-0000-0000-000000000001"))
  invisible(dbAppendTable(con, "xmap_header", data.frame(project_id = 92L, study_accession = "S1",
    experiment_accession = "E1", plateid = plate, acquisition_date = as.POSIXct("2026-03-02", tz = "UTC"))))
}
# Control wells = copies of fitted test samples of curve `cid` (one masked).
add_controls <- function(cid, plate, n = 8) {
  s <- ex$samples[ex$samples$curve_id == cid, ][seq_len(n), ]
  ctl <- data.frame(project_id = 92L, study_accession = "S1", experiment_accession = "E1",
    plate_id = plate, plateid = plate, plate = plate, nominal_sample_dilution = "2000",
    well = sprintf("H%d", seq_len(n)), sampleid = sprintf("H%d", seq_len(n)),
    source = rep(c("QC1", "QC2"), length.out = n), dilution = s$dilution,
    antigen = "PT", feature = "IgG", wavelength = NA_character_,
    antibody_mfi = round(s$mfi, 4), antibody_n = 50L, masked = c(TRUE, rep(FALSE, n - 1)),
    mask_reason = c("bubble", rep(NA, n - 1)))
  dbAppendTable(con, "xmap_control", ctl)
  data.frame(well = ctl$well, sampleid = s$sampleid, patientid = s$patientid,
             timeperiod = s$timeperiod, masked = ctl$masked)
}

compare_to_engine <- function(id, method, cid, map, tol_x, tol_pcov) {
  cc <- dbGetQuery(con, sprintf("SELECT * FROM calib_controls WHERE curve_id = %d AND method = '%s'", cid, method))
  sm <- dbGetQuery(con, sprintf("SELECT * FROM calib_samples WHERE curve_id = %d AND method = '%s'", cid, method))
  cc$sampleid <- NULL
  m <- merge(map, cc, by = "well"); m <- merge(m, sm, by = c("sampleid", "patientid", "timeperiod"),
                                               suffixes = c(".bf", ".eng"))
  num <- function(x) as.numeric(as.character(x))
  dx <- abs(num(m$predicted_log10_concentration.bf) - num(m$predicted_log10_concentration.eng))
  rp <- abs(num(m$pcov.bf) - num(m$pcov.eng)) / num(m$pcov.eng)
  check(id, nrow(m) == nrow(map), sprintf("%d control rows matched to the engine's sample rows", nrow(m)))
  check(id, max(dx) <= tol_x, sprintf("point estimate within %.3g log10 of the engine (max %.2g)", tol_x, max(dx)))
  check(id, stats::median(rp) <= tol_pcov, sprintf("pcov within %.0f%% of the engine (median %.2g%%)", 100 * tol_pcov, 100 * stats::median(rp)))
  agree <- mean(m$pcov_gate_class.bf == m$pcov_gate_class.eng & m$censor_class.bf == m$censor_class.eng)
  check(id, agree >= if (method == "frequentist") 1 else 0.85,
        sprintf("gate and censoring class agree on %.0f%% of controls", 100 * agree))
  invisible(m)
}

# ---- F: frequentist -------------------------------------------------------------
cat("\nF: frequentist fit\n")
pp1 <- prep(1); pp2 <- prep(2)
std <- rbind(pp1$data, pp2$data)
smp <- ex$samples[ex$samples$curve_id %in% 1:2, ]
add_curves(1:2, "P1")
mpf <- post(curveRfreq::fit_calibration_freq_multiplate(
  standards = std, samples = smp, response_var = "mfi", std_curve_conc = 10000, interval_seed = 7))
store_fit(1:2, "frequentist", "job-F", mpf, list(data = std, blanks = NULL))
map1 <- add_controls(1, "P1")
man <- dbGetQuery(con, "SELECT manifest ->> 'calib_schema' AS cs, manifest ->> 'component' AS comp,
                                manifest -> 'packages' ->> 'curveRcore' AS core
                           FROM calib_run WHERE job_id = 'job-F'")
check("F", nrow(man) == 1 && identical(man$cs, "0.7.0") && identical(man$comp, "i-spi-compute-worker") &&
           identical(man$core, as.character(utils::packageVersion("curveRcore"))),
      "the worker's save path records calib_run.manifest (component, curveRcore, calib schema)")
check("F", all(is.na(dbGetQuery(con, "SELECT pcov FROM calib_standards")$pcov)), "stored standards start without estimates (legacy state)")
check("F", nrow(dbGetQuery(con, "SELECT * FROM control_for_fit")) == 2 * nrow(map1),
      "control_for_fit: every control on both standard sources of its plate")

tot <- backfill_point_estimates(con, dry_run = TRUE, verbose = nzchar(Sys.getenv("E2E_DEBUG")))
check("F", tot$pairs == 2 && nrow(dbGetQuery(con, "SELECT 1 FROM calib_controls")) == 0 &&
           all(is.na(dbGetQuery(con, "SELECT pcov FROM calib_standards")$pcov)), "dry run computes 2 pairs and writes nothing")
tot <- backfill_point_estimates(con, verbose = FALSE)
st <- dbGetQuery(con, "SELECT * FROM calib_standards")
check("F", tot$pairs == 2 && all(!is.na(st$pcov)), sprintf("all %d standard rows filled", nrow(st)))
rec <- 100 * 10^(as.numeric(st$predicted_log10_concentration) - as.numeric(st$log10_concentration))
check("F", isTRUE(all.equal(as.numeric(st$recovery_pct), rec, tolerance = 1e-8)), "recovery_pct = estimate / nominal")
check("F", all(as.numeric(st$pcov_rmse) >= as.numeric(st$pcov) - 1e-9), "standards' pcov_rmse >= pcov (bias included)")
check("F", all(st$job_id == "job-F"), "standards keep their original job_id")
cc <- dbGetQuery(con, "SELECT * FROM calib_controls ORDER BY curve_id, well")
if (nzchar(Sys.getenv("E2E_DEBUG"))) print(cc[, c("curve_id", "method", "well", "sampleid", "source", "included", "job_id", "predicted_log10_concentration")])
check("F", nrow(cc) == 2 * nrow(map1) && all(cc$job_id == "backfill-0.7.0"), "controls written for both curves, job_id backfill-0.7.0")
mk <- cc[cc$well == "H1", ]
check("F", nrow(mk) == 2 && all(!mk$included) && all(mk$exclusion_reason == "masked") && all(mk$mask_reason == "bubble") &&
           all(!is.na(mk$predicted_log10_concentration)), "masked control estimated, included = false, reason kept")
check("F", setequal(unique(cc$source), c("QC1", "QC2")), "control name stored in source")
compare_to_engine("F", "frequentist", 1L, map1, tol_x = 1e-6, tol_pcov = 0.01)
again <- backfill_point_estimates(con, verbose = FALSE)
check("F", again$pairs == 0, "second run has nothing to do (resumable)")

# ---- R: reference values ----------------------------------------------------------
cat("\nR: control_reference + calib_controls_qc\n")
invisible(dbExecute(con, "INSERT INTO control_reference (project_id, control_source, antigen, expected_conc, expected_sd, lower_limit, upper_limit, basis)
                VALUES (92, 'QC1', 'PT', 1000, 100, 800, 1200, 'assigned')"))
qc <- dbGetQuery(con, "SELECT * FROM calib_controls_qc WHERE source = 'QC1' AND curve_id = 1")
check("R", nrow(qc) > 0 && all(abs(as.numeric(qc$recovery_pct) - 100 * as.numeric(qc$final_concentration) / 1000) < 1e-6, na.rm = TRUE),
      "recovery_pct = final / expected for QC1")
check("R", all(is.na(dbGetQuery(con, "SELECT expected_conc FROM calib_controls_qc WHERE source = 'QC2'")$expected_conc)),
      "QC2 has no reference value: QC columns empty")

# ---- B: bayesian ------------------------------------------------------------------
if (!identical(Sys.getenv("E2E_SKIP_BAYES"), "1")) {
  cat("\nB: bayesian fit with persisted draws\n")
  pp3 <- prep(3)
  add_curves(3L, "P3")
  invisible(dbExecute(con, "UPDATE curve_lookup SET multiplate_group_id = 'bbbbbbbb-0000-0000-0000-000000000002' WHERE curve_id = 3"))
  mpb <- post(curveRbayes::fit_calibration_bayes(
    standards = pp3$data, samples = ex$samples[ex$samples$curve_id == 3, ], response_var = "mfi",
    model_names = "logistic4", std_curve_conc = 10000, chains = 2, warmup = 400, sampling = 500,
    seed = 5, persist_draws = TRUE, include_measurement_error = TRUE, run_loo = FALSE, verbose = FALSE))
  store_fit(3L, "bayesian", "job-B", mpb, list(data = pp3$data, blanks = NULL))
  map3 <- add_controls(3, "P3")
  tot <- backfill_point_estimates(con, curve_ids = 3, verbose = FALSE)
  check("B", tot$pairs == 1 && tot$controls == nrow(map3), "bayesian pair processed")
  check("B", all(tot$sources == "draws"), "se from the stored draws for every point")
  compare_to_engine("B", "bayesian", 3L, map3, tol_x = 0.15, tol_pcov = 0.15)
}

dbDisconnect(con)
res <- do.call(rbind, results)
cat(sprintf("\n%d checks, %d passed, %d FAILED\n", nrow(res), sum(res$ok), sum(!res$ok)))
if (any(!res$ok)) quit(status = 1)
