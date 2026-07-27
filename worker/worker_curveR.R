#!/usr/bin/env Rscript
# =============================================================================
# worker_curveR.R — thin orchestration worker (replaces worker_batch.R).
#
# Pipeline per fit-unit "group" (antigen × source × wavelength × nominal ×
# feature, spanning N plates):
#   1. slice bulk standards/samples/blanks to the group
#   2. resolve curve_id per plate from curve_lookup  (READ ONLY — never insert)
#   3. preprocess_standards() → concentration column
#   4. dispatch: curveRbayes::fit_calibration_bayes()   (hierarchical, pooled)
#             or curveRfreq::fit_calibration_freq_multiplate()  (independent)
#   5. compute_detection_limits_multiplate()
#   6. flatten_result() → save_calib()  (idempotent, curve_id-keyed)
#   7. verify_saved()   → progress JSON
#
# Same CLI as worker_batch.R plus --method / --models, so supervisor.py's
# SCRIPT_REGISTRY entry needs no change beyond pointing at this file.
#
# DB creds from env: DB_NAME/HOST/PORT/USER/PASSWORD/SSLMODE.
#
# Review-grade: not yet run end-to-end. Seams that depend on the live curveR
# object/signatures are marked [CONFIRM].
# =============================================================================

suppressWarnings(suppressMessages({
  library(DBI); library(RPostgres); library(dplyr); library(jsonlite)
  library(curveRcore); library(curveRfreq); library(curveRbayes)
}))

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || (length(a) == 1 && is.na(a))) b else a

# Resolve this script's directory across three launch modes: Rscript (--file=),
# source() (frame $ofile), and in-process debug harnesses where commandArgs()
# is masked (no --file=, so we must fall back to $ofile, not getwd()).
.script_dir <- local({
  a <- tryCatch(commandArgs(FALSE), error = function(e) character())
  m <- grep("^--file=", a, value = TRUE)
  if (length(m)) return(dirname(normalizePath(sub("^--file=", "", m[1]))))
  for (i in rev(seq_len(sys.nframe()))) {          # source() sets $ofile in a frame
    of <- sys.frame(i)$ofile
    if (!is.null(of) && nzchar(of)) return(dirname(normalizePath(of)))
  }
  getwd()
})

# Load sibling components, searching a few plausible locations, and skipping any
# already defined (e.g. pre-sourced by a harness). An env override wins if set.
for (f in c("flatten_and_save.R", "verify_saved.R")) {
  cand <- unique(file.path(c(Sys.getenv("WORKER_COMPONENTS_DIR", ""),
                             .script_dir, file.path(.script_dir, "worker"),
                             getwd(), file.path(getwd(), "worker")), f))
  hit <- cand[nzchar(cand) & file.exists(cand)]
  if (length(hit)) source(hit[1])
}
# Fail loudly rather than dying later with "could not find function flatten_result".
if (!all(vapply(c("flatten_result", "save_calib", "verify_saved"),
                exists, logical(1), mode = "function"))) {
  stop("Could not load flatten_and_save.R / verify_saved.R beside worker_curveR.R.\n",
       "Searched near: ", .script_dir,
       "\nPut them in the same folder, or set WORKER_COMPONENTS_DIR.")
}


# ── CLI ──────────────────────────────────────────────────────────────────────
parse_args <- function(argv = commandArgs(trailingOnly = TRUE)) {
  p <- list(study = "", scope = "study", experiment = "", antigen = "",
            source = "", project_id = NA, cdan_cv = "20", job_id = "local",
            progress_dir = tempdir(), output_dir = tempdir(),
            method = "bayesian", models = "", blank_option = "ignored",
            chains = "4", warmup = "1000", sampling = "1000",
            adapt_delta = "0.9", seed = "")
  i <- 1L
  while (i <= length(argv)) {
    key <- sub("^--", "", argv[i])
    val <- if (i + 1L <= length(argv) && !grepl("^--", argv[i + 1L])) argv[i + 1L] else ""
    p[[key]] <- val
    i <- i + (if (nzchar(val)) 2L else 1L)
  }
  p
}

open_conn <- function() {
  DBI::dbConnect(RPostgres::Postgres(),
    dbname   = Sys.getenv("DB_NAME",    "local_madi_ispi"),
    host     = Sys.getenv("DB_HOST",    "localhost"),
    port     = as.integer(Sys.getenv("DB_PORT", "5432")),
    user     = Sys.getenv("DB_USER",    ""),
    password = Sys.getenv("DB_PASSWORD", ""),
    sslmode  = Sys.getenv("DB_SSLMODE", "disable"),
    options  = "-c search_path=madi_results")
}


# ── Data adapter (SQL copied verbatim from worker_batch.R fetchers) ──────────
discover_combos <- function(conn, study, project_id, experiment = NULL,
                            antigen = NULL, source_val = NULL) {
  sql <- "
    SELECT h.project_id, s.study_accession, s.experiment_accession,
           h.nominal_sample_dilution, s.feature, s.antigen, s.source,
           COALESCE(s.wavelength,'__none__') AS wavelength,
           COUNT(DISTINCT h.plate) AS n_plate
    FROM madi_results.standard_unmasked s
    INNER JOIN madi_results.header_unmasked h
      ON h.study_accession = s.study_accession
     AND h.experiment_accession = s.experiment_accession
     AND TRIM(h.plate_id) = TRIM(s.plate_id)
    WHERE s.study_accession = $1 AND h.project_id = $2"
  prm <- list(study, project_id); n <- 3L
  if (nzchar(experiment %||% "")) { sql <- paste0(sql, sprintf(" AND s.experiment_accession = $%d", n)); prm <- c(prm, experiment); n <- n + 1L }
  if (nzchar(antigen %||% ""))    { sql <- paste0(sql, sprintf(" AND s.antigen = $%d", n));              prm <- c(prm, antigen);    n <- n + 1L }
  if (nzchar(source_val %||% "")) { sql <- paste0(sql, sprintf(" AND s.source = $%d", n));               prm <- c(prm, source_val) }
  sql <- paste0(sql, "
    GROUP BY h.project_id, s.study_accession, s.experiment_accession,
             h.nominal_sample_dilution, s.feature, s.antigen, s.source,
             COALESCE(s.wavelength,'__none__')
    ORDER BY s.experiment_accession, s.antigen, s.source")
  DBI::dbGetQuery(conn, sql, params = prm)
}

# Masked-inclusive sources. The *_unmasked views now project `masked` +
# `mask_reason` and (with their mask filter left commented out) return ALL
# wells, so the worker reads them to PERSIST masked wells with their status.
# curve resolution still uses curve_lookup_unmasked (whole-curve masking).
# Reading the views (not the base xmap_* tables) means a non-owner worker role
# needs SELECT on the VIEWS only — the views run with the owner's rights.
#
# NOTE: these reads no longer join header_unmasked. `plate`, `plateid`,
# `nominal_sample_dilution`, and `project_id` are denormalized onto the
# standard/blank/sample rows, so we read them directly. The old
# `TRIM(plate_id)=TRIM(plate_id)` join fanned every well out by the number of
# header rows sharing that plate_id (plate_id is not unique at plate grain),
# which broke the calib_standards/calib_blanks PK. If PLATE-level masking is
# ever enforced, it must be applied explicitly here — it is NOT provided by the
# *_unmasked views (their mask filter is currently commented out).
STD_SRC   <- Sys.getenv("WORKER_STD_SRC",   "madi_results.standard_unmasked")
BLANK_SRC <- Sys.getenv("WORKER_BLANK_SRC", "madi_results.blank_unmasked")

fetch_standards <- function(conn, project_id, study, experiment) DBI::dbGetQuery(conn, sprintf("
  SELECT s.antigen, s.plateid, s.plate, s.nominal_sample_dilution,
         s.antibody_mfi AS mfi,
         s.dilution AS dilution, s.feature, s.source,
         COALESCE(s.wavelength,'__none__') AS wavelength, s.project_id,
         s.well, COALESCE(s.masked, FALSE) AS masked, s.mask_reason
  FROM %s s
  WHERE s.project_id = $1 AND s.study_accession = $2 AND s.experiment_accession = $3", STD_SRC),
  params = list(project_id, study, experiment))

fetch_samples <- function(conn, project_id, study, experiment) DBI::dbGetQuery(conn, "
  SELECT s.antigen, s.plateid, s.plate, s.nominal_sample_dilution,
         s.sampleid, s.antibody_mfi AS mfi, s.dilution, s.timeperiod,
         s.patientid, s.well, s.feature, s.source,
         COALESCE(s.wavelength,'__none__') AS wavelength, s.project_id
  FROM madi_results.sample_unmasked s
  WHERE s.project_id = $1 AND s.study_accession = $2 AND s.experiment_accession = $3",
  params = list(project_id, study, experiment))

fetch_blanks <- function(conn, project_id, study, experiment) DBI::dbGetQuery(conn, sprintf("
  SELECT b.antigen, b.source, COALESCE(b.wavelength,'__none__') AS wavelength,
         b.plateid, b.plate, b.nominal_sample_dilution,
         b.antibody_mfi AS mfi, b.project_id,
         b.well, COALESCE(b.masked, FALSE) AS masked, b.mask_reason
  FROM %s b
  WHERE b.project_id = $1 AND b.study_accession = $2 AND b.experiment_accession = $3
    AND UPPER(b.stype) = 'B' AND b.antibody_mfi > 0", BLANK_SRC),
  params = list(project_id, study, experiment))

fetch_sc_conc <- function(conn, study, experiment) {
  res <- tryCatch(DBI::dbGetQuery(conn, "
    SELECT DISTINCT antigen, standard_curve_concentration
    FROM madi_results.antigen_feature_settings
    WHERE study_accession = $1 AND experiment_accession = $2
      AND standard_curve_concentration IS NOT NULL",
    params = list(study, experiment)), error = function(e) data.frame())
  if (!nrow(res)) return(list())
  res <- res[!duplicated(res$antigen), ]
  stats::setNames(as.list(as.numeric(res$standard_curve_concentration)), as.character(res$antigen))
}

# Blanks are NEVER subtracted automatically. Subtraction happens only when a
# caller explicitly asks for it via `blank_option`; anything unrecognised (or
# empty) collapses to "ignored" so a typo or NULL can never trigger a
# subtraction. Allowed values:
#   ignored        blanks are transformed for display/persistence only; the
#                  standard responses are left untouched (DEFAULT)
#   included       add the included-blank geometric mean as an extra fit point
#   subtracted     subtract 1x the included-blank geomean from the standards
#   subtracted_3x  subtract 3x
#   subtracted_10x subtract 10x
.BLANK_OPTS <- c("ignored", "included", "subtracted", "subtracted_3x", "subtracted_10x")
.valid_blank_option <- function(x) {
  x <- tolower(trimws(x %||% ""))
  if (length(x) != 1L || is.na(x) || !(x %in% .BLANK_OPTS)) "ignored" else x
}

# Optional per-antigen blank handling, read from antigen_feature_settings ONLY
# when the column is named explicitly (env WORKER_BLANK_OPTION_COL). Absent ->
# empty map -> the run-level --blank_option is used (itself defaulting to
# "ignored"). This keeps subtraction an explicit, opt-in choice rather than a
# schema-driven surprise.
fetch_blank_options <- function(conn, study, experiment) {
  col <- Sys.getenv("WORKER_BLANK_OPTION_COL", "")
  if (!nzchar(col)) return(list())
  qcol <- DBI::dbQuoteIdentifier(conn, col)
  res <- tryCatch(DBI::dbGetQuery(conn, sprintf("
    SELECT DISTINCT antigen, %s AS blank_option
    FROM madi_results.antigen_feature_settings
    WHERE study_accession = $1 AND experiment_accession = $2
      AND %s IS NOT NULL", qcol, qcol),
    params = list(study, experiment)), error = function(e) data.frame())
  if (!nrow(res)) return(list())
  res <- res[!duplicated(res$antigen), ]
  stats::setNames(as.list(as.character(res$blank_option)), as.character(res$antigen))
}

GROUP_COLS <- c("antigen", "feature", "source", "wavelength", "nominal_sample_dilution")
# Patient samples carry no standard 'source' (it's NULL in xmap_sample), so they
# are grouped and keyed to a curve WITHOUT source. plate/antigen/feature/
# wavelength/nominal still identify the curve uniquely (plateid encodes nominal).
SAMPLE_GROUP_COLS <- setdiff(GROUP_COLS, "source")
# Blanks (buffer wells) carry NO `source` -- it is NULL on every xmap_buffer row
# (verified) -- so, exactly like samples, they must slice/resolve without it.
BLANK_GROUP_COLS  <- setdiff(GROUP_COLS, "source")
slice_group <- function(df, grp, cols = GROUP_COLS) {
  if (is.null(df) || !nrow(df)) return(df[0, , drop = FALSE])
  keep <- rep(TRUE, nrow(df))
  for (k in intersect(cols, names(df)))
    # `%in% TRUE` maps NA -> FALSE, so a NULL/NA cell excludes the row instead of
    # poisoning `keep` to NA (which df[NA, ] would turn into fabricated all-NA rows).
    keep <- keep & ((as.character(df[[k]]) == as.character(grp[[k]][1])) %in% TRUE)
  df[keep, , drop = FALSE]
}

# READ-ONLY curve_id attach: join a fetched frame to curve_lookup on the 10-col
# NK (types coerced to character to avoid silent merge misses). Rows that don't
# resolve keep curve_id = NA and are surfaced by the caller — never invented.
NK <- c("project_id","study_accession","experiment_accession","plateid","plate",
        "nominal_sample_dilution","source","wavelength","antigen","feature")
SAMPLE_NK <- setdiff(NK, "source")   # samples resolve to a curve without 'source'
BLANK_NK  <- setdiff(NK, "source")   # blanks likewise: source is NULL in xmap_buffer
attach_curve_id <- function(df, lookup, study, experiment, group_feature = NULL,
                            key_cols = NK) {
  if (is.null(df) || !nrow(df)) return(df)
  df$study_accession      <- study
  df$experiment_accession <- experiment
  if (!("feature" %in% names(df)) && !is.null(group_feature)) df$feature <- group_feature
  key <- function(x) do.call(paste, c(lapply(key_cols, function(k) as.character(x[[k]])), sep = "\r"))
  lk  <- lookup[, c(key_cols, "curve_id")]
  lk$.k <- key(lk)
  # A reduced key (e.g. samples keyed without 'source') can match several lookup
  # rows. Collapse to one curve_id per key; warn only if genuinely ambiguous
  # (same reduced key -> >1 distinct curve_id, which shouldn't happen per plate).
  if (!setequal(key_cols, NK)) {
    n_cid <- tapply(lk$curve_id, lk$.k, function(v) length(unique(v)))
    amb   <- names(n_cid[n_cid > 1])
    if (length(amb))
      warning(sprintf("attach_curve_id: %d key(s) map to >1 curve; taking first", length(amb)))
  }
  lk <- lk[!duplicated(lk$.k), c(".k", "curve_id")]
  df$.k <- key(df)
  out <- merge(df, lk, by = ".k", all.x = TRUE)
  out$.k <- NULL
  out
}


# ── settings from CLI params ─────────────────────────────────────────────────
build_models <- function(p) {
  if (nzchar(p$models)) trimws(strsplit(p$models, ",")[[1]])
  # Fallback only when a job arrives with no models param. Matches the
  # antigen_feature_settings.model_form_list default so the worker and the
  # settings table agree on the full five-model curveRcore set.
  else c("logistic5", "loglogistic5", "logistic4", "loglogistic4", "gompertz4")
}


# ── progress ─────────────────────────────────────────────────────────────────
write_progress <- function(dir, job_id, total, done, status, cur_exp = "", cur_grp = "") {
  tryCatch({
    dir.create(dir, showWarnings = FALSE, recursive = TRUE)
    jsonlite::write_json(list(
      job_id = job_id, total_combos = total, completed_combos = done,
      percentage = if (total > 0) round(100 * done / total, 1) else 0,
      status = status, current_experiment = cur_exp, current_group = cur_grp,
      updated_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S")),
      file.path(dir, paste0("progress_", job_id, ".json")), auto_unbox = TRUE)
  }, error = function(e) message("  (progress write skipped: ", conditionMessage(e), ")"))
}


# ── MAIN ─────────────────────────────────────────────────────────────────────
main <- function() {
  P <- parse_args()
  P$project_id <- suppressWarnings(as.integer(P$project_id))
  method  <- match.arg(P$method, c("bayesian", "frequentist"))
  is_bayes <- identical(method, "bayesian")
  models  <- build_models(P)
  pcov_th <- suppressWarnings(as.numeric(P$cdan_cv)) %||% 20
  seed    <- if (nzchar(P$seed)) as.integer(P$seed) else NULL

  message(sprintf("worker_curveR: study=%s scope=%s method=%s models=%s job=%s",
                  P$study, P$scope, method, paste(models, collapse = "+"), P$job_id))
  # CPU cap. parallel::detectCores() is NOT cgroup-aware and over-reports under a
  # K8s/Docker CPU limit, so honor WORKER_CORES (set by the deployment) when
  # present. cmdstanr's $sample() defaults parallel_chains = getOption("mc.cores"),
  # so this single setting also caps Stan's parallel chains.
  worker_cores <- local({
    env <- suppressWarnings(as.integer(Sys.getenv("WORKER_CORES", "")))
    if (!is.na(env) && env >= 1L) env
    else max(1L, tryCatch(parallel::detectCores(), error = function(e) 1L))
  })
  options(mc.cores = worker_cores)
  message(sprintf("worker cores: %d  (source: %s)", worker_cores,
                  if (nzchar(Sys.getenv("WORKER_CORES"))) "WORKER_CORES" else "detectCores()"))

  conn <- open_conn(); on.exit(try(DBI::dbDisconnect(conn), silent = TRUE), add = TRUE)

  exp_filter <- if (P$scope %in% c("experiment", "antigen")) P$experiment else NULL
  ant_filter <- if (P$scope == "antigen") P$antigen else NULL
  combos <- discover_combos(conn, P$study, P$project_id, exp_filter, ant_filter,
                            if (nzchar(P$source)) P$source else NULL)
  if (!nrow(combos)) { message("No combos found. Exiting."); return(0L) }
  combos$n_plate <- as.integer(combos$n_plate)   # COUNT() returns numeric -> keep %d happy

  total_curves <- sum(combos$n_plate)
  done <- 0L; failures <- 0L
  write_progress(P$progress_dir, P$job_id, total_curves, done, "running")

  # Run-level default blank handling. Validated so an unknown/typo value can
  # never trigger a subtraction — it collapses to "ignored". A per-antigen
  # setting (fetch_blank_options) can override this per group; nothing
  # subtracts blanks unless a value explicitly asks for it.
  run_blank_option <- .valid_blank_option(P$blank_option)
  study_params <- list(is_log_response = TRUE, is_log_independent = TRUE,
                       apply_prozone = TRUE)
  message(sprintf("blank handling: run default = '%s'%s", run_blank_option,
                  if (nzchar(Sys.getenv("WORKER_BLANK_OPTION_COL")))
                    sprintf(" (per-antigen overrides from settings.%s)",
                            Sys.getenv("WORKER_BLANK_OPTION_COL")) else ""))

  for (exp_name in unique(combos$experiment_accession)) {
    message("\n==== experiment: ", exp_name, " ====")
    std_all  <- fetch_standards(conn, P$project_id, P$study, exp_name)
    samp_all <- fetch_samples(conn,  P$project_id, P$study, exp_name)
    blank_all<- fetch_blanks(conn,   P$project_id, P$study, exp_name)
    sc_map   <- fetch_sc_conc(conn,  P$study, exp_name)
    bo_map   <- fetch_blank_options(conn, P$study, exp_name)
    lookup   <- DBI::dbGetQuery(conn,
      "SELECT * FROM madi_results.curve_lookup_unmasked WHERE project_id=$1 AND study_accession=$2 AND experiment_accession=$3",
      params = list(P$project_id, P$study, exp_name))

    grp_rows <- combos[combos$experiment_accession == exp_name, , drop = FALSE]
    for (gi in seq_len(nrow(grp_rows))) {
      grp <- grp_rows[gi, , drop = FALSE]
      tag <- sprintf("%s | %s | src=%s wl=%s nom=%s", exp_name, grp$antigen,
                     grp$source, grp$wavelength, grp$nominal_sample_dilution)
      sc  <- sc_map[[as.character(grp$antigen)]] %||% as.numeric(grp$nominal_sample_dilution)
      bo  <- .valid_blank_option(bo_map[[as.character(grp$antigen)]] %||% run_blank_option)

      res <- tryCatch({
        std_g <- attach_curve_id(slice_group(std_all,  grp), lookup, P$study, exp_name)
        samp_g<- attach_curve_id(slice_group(samp_all, grp, SAMPLE_GROUP_COLS),
                                 lookup, P$study, exp_name, key_cols = SAMPLE_NK)
        blk_g <- attach_curve_id(slice_group(blank_all, grp, BLANK_GROUP_COLS),
                                 lookup, P$study, exp_name,
                                 group_feature = grp$feature, key_cols = BLANK_NK)

        if (anyNA(std_g$curve_id))
          stop(sprintf("%d standard row(s) did not resolve to a curve_lookup id",
                       sum(is.na(std_g$curve_id))))

        # Keep only rows that resolved to a curve; pass NULL (not a 0-row frame)
        # so the fit's "must contain curve_id" guard doesn't trip on empty inputs.
        # Standards must fully resolve (checked above); samples/blanks may be empty.
        .resolved <- function(d) {
          if (is.null(d) || !nrow(d)) return(NULL)
          if ("curve_id" %in% names(d)) d <- d[!is.na(d$curve_id), , drop = FALSE]
          if (nrow(d)) d else NULL
        }
        n_samp_in <- if (is.data.frame(samp_g)) nrow(samp_g) else 0L
        samp_g <- .resolved(samp_g); blk_g <- .resolved(blk_g)
        n_samp_out <- if (is.null(samp_g)) 0L else nrow(samp_g)
        if (n_samp_in > n_samp_out)
          message(sprintf("  note: %d/%d sample row(s) had no curve_id, skipped",
                          n_samp_in - n_samp_out, n_samp_in))

        # Row-level mask status -> included flag (TRUE = enters the fit).
        # Masked wells are retained here; they are transformed and persisted but
        # NEVER handed to the fitter.
        std_g$included <- !(as.logical(std_g$masked) %in% TRUE)
        if (!is.null(blk_g)) blk_g$included <- !(as.logical(blk_g$masked) %in% TRUE)

        # Preprocess the FULL set (stats from included; transforms applied to
        # all rows). Keep the whole object: $data + $blanks are persisted, and
        # the fitter is fed only the included subset.
        pp <- preprocess_standards(
          data = std_g, antigen_settings = list(standard_curve_concentration = sc),
          response_variable = "mfi", independent_variable = "concentration",
          is_log_response = study_params$is_log_response,
          blank_data = blk_g, blank_option = bo,
          is_log_independent = study_params$is_log_independent,
          apply_prozone = study_params$apply_prozone,
          include_col = "included")

        # Fit inputs: included rows only. We ALSO strip the mask-aware columns
        # that this pipeline attaches (curveRcore >=0.3.0's preprocess adds
        # `included` + `assay_response_raw`; the worker adds `included`/`masked`
        # above). The downstream fitters (curveRfreq / curveRbayes / curveRweights)
        # are UNCHANGED and expect the pre-mask frame shape, so we hand them exactly
        # that — byte-identical to the pre-mask fit. Persistence is unaffected: it
        # reads the full `pp` object, so calib_standards/calib_blanks keep every
        # column and every (incl. masked) row. Only the fit INPUT is trimmed.
        .fit_cols <- function(df) {
          if (is.null(df)) return(df)
          df[, setdiff(names(df), c("included", "assay_response_raw", "masked")),
             drop = FALSE]
        }
        std_fit <- .fit_cols(pp$data[pp$data$included %in% TRUE, , drop = FALSE])

        blk_fit <- if (is.null(blk_g)) NULL else {
          bf <- blk_g[blk_g$included %in% TRUE, , drop = FALSE]
          if (nrow(bf)) .fit_cols(bf) else NULL
        }

        if (is_bayes) {
          mp <- curveRbayes::fit_calibration_bayes(
            standards = std_fit, samples = samp_g, blanks = blk_fit,
            response_var = "mfi", model_names = models,
            is_log_response = study_params$is_log_response,
            is_log_independent = study_params$is_log_independent,
            std_curve_conc = sc, cv_x_max = 150, pcov_threshold = pcov_th,
            chains = as.integer(P$chains), warmup = as.integer(P$warmup),
            sampling = as.integer(P$sampling), adapt_delta = as.numeric(P$adapt_delta),
            seed = seed, run_loo = TRUE, verbose = FALSE)
        } else {
          mp <- curveRfreq::fit_calibration_freq_multiplate(
            standards = std_fit, blanks = blk_fit, samples = samp_g,
            response_var = "mfi", model_names = models,
            is_log_response = study_params$is_log_response,
            is_log_independent = study_params$is_log_independent,
            std_curve_conc = sc, cv_x_max = 150)
        }

        mp <- curveRcore::compute_detection_limits_multiplate(mp)

        flat <- flatten_result(mp, job_id = P$job_id, method = method)
        # Attach the persisted standard/blank point sets (ALL rows, with status)
        # built from the preprocessing output, not from the fitted object.
        pts <- flatten_calib_points(pp, job_id = P$job_id, method = method,
                                    response_var = "mfi",
                                    is_log_independent = study_params$is_log_independent)
        flat$standards <- pts$standards
        flat$blanks    <- pts$blanks
        save_calib(conn, flat)
        v <- verify_saved(mp, job_id = P$job_id, method = method, conn = conn,
                          points = pp, verbose = FALSE)
        if (!isTRUE(v$ok)) warning(tag, ": verify_saved reported failures")
        grp$n_plate
      }, error = function(e) { message("  FAIL ", tag, " :: ", conditionMessage(e)); NA_integer_ })

      if (is.na(res)) failures <- failures + 1L else done <- done + res
      write_progress(P$progress_dir, P$job_id, total_curves, done, "running", exp_name, tag)
    }
  }

  status <- if (failures == 0L) "completed" else "failed"
  write_progress(P$progress_dir, P$job_id, total_curves, done, status)
  message(sprintf("\n==== DONE — %d/%d curves saved, %d group failure(s) ====",
                  done, total_curves, failures))
  if (failures > 0L) 1L else 0L
}

# Auto-run as a script/harness. A smoke test (or any caller) can set
# WORKER_SOURCE_ONLY=1 or options(worker_curveR.source_only=TRUE) to load the
# functions/components without executing a run.
.source_only <- identical(Sys.getenv("WORKER_SOURCE_ONLY"), "1") ||
                isTRUE(getOption("worker_curveR.source_only", FALSE))
if (!.source_only) {
  status <- tryCatch(main(), error = function(e) { message("FATAL: ", conditionMessage(e)); 2L })
  if (!interactive()) quit(status = status)
}
