#!/usr/bin/env Rscript
# =============================================================================
# worker_curveR.R — thin orchestration worker (curve_id-batch edition).
#
# CONTRACT (see HANDOFF_worker_curve_id_batch.md):
#   The worker no longer resolves scope and no longer knows natural keys. It is
#   handed a BATCH of curve_ids. It reads the fit-delivery views
#   (madi_results.{standard,blank,sample}_for_fit) filtered by
#   `curve_id = ANY(batch)`, GROUPS the rows by `multiplate_group_id` into
#   multiplate fitting units, fits each group, and persists — idempotently,
#   keyed on (curve_id, method).
#
# Pipeline per multiplate group (all curves that differ only by plate):
#   1. subset the batch's standard/blank/sample rows to this multiplate_group_id
#   2. set the row-level `included` flag from `masked`
#   3. preprocess_standards() → concentration column
#   4. dispatch: curveRbayes::fit_calibration_bayes()   (hierarchical, pooled)
#             or curveRfreq::fit_calibration_freq_multiplate()  (independent)
#   5. compute_detection_limits_multiplate()
#   6. flatten_result() + flatten_calib_points() → save_calib()  (curve_id-keyed)
#   7. verify_saved()   → progress JSON
#
# The views already carry curve_id, multiplate_group_id, antigen, feature,
# source, mfi, masked, mask_reason (and the columns preprocess/fit/persist need),
# and the standard-source-in / other-source-out grain is baked in — so a blank
# shared by N standard sources arrives as N rows (one per curve_id). No R-side
# NK slicing, curve_id attaching, or header joins remain.
#
# DB creds from env: DB_NAME/HOST/PORT/USER/PASSWORD/SSLMODE.
#
# Review-grade: seams that depend on the live curveR object/signatures and on
# the exact for_fit view columns are marked [CONFIRM].
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
# The job is a curve_id batch: --curve_ids is a comma-joined integer list; the
# optional --multiplate_group_ids (parallel to curve_ids) is used only as an
# integrity check against the grouping the views carry.
parse_args <- function(argv = commandArgs(trailingOnly = TRUE)) {
  p <- list(curve_ids = "", multiplate_group_ids = "",
            cdan_cv = "20", job_id = "local",
            progress_dir = tempdir(), output_dir = tempdir(),
            method = "bayesian", models = "", blank_option = "ignored",
            chains = "4", warmup = "1000", sampling = "1000",
            adapt_delta = "0.9", seed = "",
            include_measurement_error = "true")
  i <- 1L
  supplied <- character(0)
  while (i <= length(argv)) {
    key <- sub("^--", "", argv[i])
    val <- if (i + 1L <= length(argv) && !grepl("^--", argv[i + 1L])) argv[i + 1L] else ""
    p[[key]] <- val
    supplied <- c(supplied, key)
    i <- i + (if (nzchar(val)) 2L else 1L)
  }
  # Record which keys the CALLER actually passed, so the worker can let an
  # explicit CLI value override a resolved cascade default (and otherwise fall
  # back to the cascade). attr avoids changing p's shape for existing readers.
  attr(p, "supplied") <- unique(supplied)
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


# ── FETCH: read the fit-delivery views by curve_id ───────────────────────────
# NOTE: RPostgres does NOT bind an R vector to a PG array parameter — a
# length-N vector param is treated as N row-wise executions, which yields
# "malformed array literal" on `= ANY($1)` and a length-mismatch on any
# multi-param query. curve_ids are integers we fully control, so we interpolate
# them into an `IN (...)` list — the same idiom save_calib()/verify_saved()
# already use. .in_ids() coerces to integer and drops non-numerics, so nothing
# but digits ever reaches the SQL (no injection surface).
.in_ids <- function(curve_ids) {
  v <- suppressWarnings(as.integer(curve_ids)); v <- v[!is.na(v)]
  if (!length(v)) "NULL" else paste(v, collapse = ",")   # IN (NULL) -> no rows
}
# One row per standard well; carries curve_id, multiplate_group_id, masked, ...
fetch_std_for_fit <- function(conn, curve_ids) DBI::dbGetQuery(conn, sprintf(
  "SELECT * FROM madi_results.standard_for_fit WHERE curve_id IN (%s)", .in_ids(curve_ids)))
# One row per (blank well x standard-source curve) — the view's 1-to-many grain.
fetch_blk_for_fit <- function(conn, curve_ids) DBI::dbGetQuery(conn, sprintf(
  "SELECT * FROM madi_results.blank_for_fit  WHERE curve_id IN (%s)", .in_ids(curve_ids)))
# Unmasked samples only.
fetch_smp_for_fit <- function(conn, curve_ids) DBI::dbGetQuery(conn, sprintf(
  "SELECT * FROM madi_results.sample_for_fit WHERE curve_id IN (%s)", .in_ids(curve_ids)))


# ── Per-antigen settings (standard_curve_concentration, blank_option) ─────────
# These live in madi_results.antigen_feature_settings per (antigen, feature),
# which is constant within a multiplate_group_id. We scope the lookup to the
# (study, experiment) pairs present in the delivered standard rows when the view
# exposes those columns (SELECT * → it normally does); otherwise we fall back to
# scoping by antigen alone. [CONFIRM: standard_for_fit column set.]
.se_pairs <- function(std) {
  if (!all(c("study_accession", "experiment_accession") %in% names(std))) return(NULL)
  se <- unique(std[, c("study_accession", "experiment_accession"), drop = FALSE])
  se[!is.na(se$study_accession) & !is.na(se$experiment_accession), , drop = FALSE]
}

# Run one antigen_feature_settings query per (study, experiment) pair (or by
# antigen if the view lacks study/experiment), rbind the results, de-dup by
# antigen, and return an antigen -> value named list.
.settings_map <- function(conn, std, value_col, only_when = NULL, quote_value = FALSE) {
  qv <- if (quote_value) DBI::dbQuoteIdentifier(conn, value_col) else NULL
  col_sql <- if (quote_value) as.character(qv) else value_col
  base <- sprintf("SELECT DISTINCT antigen, %s AS v FROM madi_results.antigen_feature_settings",
                  col_sql)
  filt <- if (nzchar(only_when %||% "")) paste0(" AND ", only_when) else ""
  se <- .se_pairs(std)
  res <- if (is.null(se)) {
    ants <- unique(as.character(std$antigen))
    ants <- ants[!is.na(ants) & nzchar(ants)]
    if (!length(ants)) return(list())
    in_lit <- paste(DBI::dbQuoteLiteral(conn, ants), collapse = ",")
    tryCatch(DBI::dbGetQuery(conn,
      paste0(base, sprintf(" WHERE antigen IN (%s)", in_lit), filt)),
      error = function(e) data.frame())
  } else {
    acc <- lapply(seq_len(nrow(se)), function(i) tryCatch(DBI::dbGetQuery(conn,
      paste0(base, " WHERE study_accession = $1 AND experiment_accession = $2", filt),
      params = list(se$study_accession[i], se$experiment_accession[i])),
      error = function(e) data.frame()))
    acc <- Filter(function(d) is.data.frame(d) && nrow(d), acc)
    if (!length(acc)) data.frame() else do.call(rbind, acc)
  }
  if (is.null(res) || !nrow(res)) return(list())
  res <- res[!duplicated(res$antigen), , drop = FALSE]
  stats::setNames(as.list(res$v), as.character(res$antigen))
}

fetch_sc_conc <- function(conn, std) {
  m <- .settings_map(conn, std, "standard_curve_concentration",
                     only_when = "standard_curve_concentration IS NOT NULL")
  lapply(m, function(x) suppressWarnings(as.numeric(x)))
}

# Optional per-antigen blank handling, read from antigen_feature_settings ONLY
# when the column is named explicitly (env WORKER_BLANK_OPTION_COL). Absent ->
# empty map -> the run-level --blank_option is used (itself defaulting to
# "ignored"). Keeps subtraction an explicit, opt-in choice.
fetch_blank_options <- function(conn, std) {
  col <- Sys.getenv("WORKER_BLANK_OPTION_COL", "")
  if (!nzchar(col)) return(list())
  m <- .settings_map(conn, std, col,
                     only_when = paste0(as.character(DBI::dbQuoteIdentifier(conn, col)), " IS NOT NULL"),
                     quote_value = TRUE)
  lapply(m, as.character)
}


# ── UNIFIED SETTINGS CASCADE (calib_settings via resolve_settings_batch) ──────
# One round-trip per job: resolve every param for every curve_id in the batch,
# then index per multiplate group (settings are uniform within a group, so any
# member curve_id yields the group's values). Replaces the hardcoded study_params
# fixture and the antigen_feature_settings reads. Values come back typed-as-text;
# coerce at the point of use. IN-list binding (RPostgres won't bind = ANY).
fetch_resolved_settings <- function(conn, curve_ids) {
  df <- tryCatch(DBI::dbGetQuery(conn, sprintf(
    "SELECT curve_id, param_name, param_data_type, value_text
       FROM madi_results.resolve_settings_batch(ARRAY[%s]::bigint[])", .in_ids(curve_ids))),
    error = function(e) { message("  (settings resolve failed: ", conditionMessage(e), ")"); data.frame() })
  df
}

# Build curve_id -> (param_name -> value_text) and a group-representative index.
# `settings_for(cid, param, default)` returns the resolved value for the group
# that `cid` belongs to, or `default` if unresolved (defensive: __system__ seeds
# everything, so a miss should not happen).
make_settings_accessor <- function(resolved) {
  if (is.null(resolved) || !nrow(resolved))
    return(function(cid, param, default = NULL) default)
  by_cid <- split(resolved, as.character(resolved$curve_id))
  function(cid, param, default = NULL) {
    r <- by_cid[[as.character(cid)]]
    if (is.null(r)) return(default)
    hit <- r[r$param_name == param, , drop = FALSE]
    if (!nrow(hit)) return(default)
    v <- hit$value_text[1]
    if (is.null(v) || is.na(v)) default else v
  }
}
# Typed coercions from the text the resolver returns.
.as_bool <- function(x, default = NA) {
  if (is.null(x) || is.na(x)) return(default)
  tolower(trimws(x)) %in% c("true","t","1","yes")
}
.as_num <- function(x, default = NA_real_) {
  v <- suppressWarnings(as.numeric(x)); if (is.na(v)) default else v
}

# CLI-over-cascade precedence: if the caller explicitly supplied `cli_key`, use
# the CLI value; else use the resolved cascade value; else the coded default.
# `supplied` is the attr set by parse_args. Returns raw text (coerce at use).
make_pick <- function(P) {
  supplied <- attr(P, "supplied") %||% character(0)
  function(cli_key, cascade_val, default = NULL) {
    if (cli_key %in% supplied && nzchar(P[[cli_key]] %||% "")) P[[cli_key]]
    else if (!is.null(cascade_val) && !is.na(cascade_val)) cascade_val
    else default
  }
}


# ── blank-handling vocabulary ────────────────────────────────────────────────
# Blanks are NEVER subtracted automatically. Subtraction happens only when a
# caller explicitly asks via `blank_option`; anything unrecognised (or empty)
# collapses to "ignored" so a typo or NULL can never trigger a subtraction.
#   ignored        blanks transformed for display/persistence only (DEFAULT)
#   included       add the included-blank geometric mean as an extra fit point
#   subtracted     subtract 1x the included-blank geomean from the standards
#   subtracted_3x  subtract 3x
#   subtracted_10x subtract 10x
.BLANK_OPTS <- c("ignored", "included", "subtracted", "subtracted_3x", "subtracted_10x")
.valid_blank_option <- function(x) {
  x <- tolower(trimws(x %||% ""))
  if (length(x) != 1L || is.na(x) || !(x %in% .BLANK_OPTS)) "ignored" else x
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
# Units are curves. `total`/`done` are curve counts; `cur_group` is a human tag
# for the multiplate group currently being fitted.
write_progress <- function(dir, job_id, total, done, status, cur_group = "") {
  tryCatch({
    dir.create(dir, showWarnings = FALSE, recursive = TRUE)
    jsonlite::write_json(list(
      job_id = job_id, total_combos = total, completed_combos = done,
      percentage = if (total > 0) round(100 * done / total, 1) else 0,
      status = status, current_group = cur_group,
      updated_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S")),
      file.path(dir, paste0("progress_", job_id, ".json")), auto_unbox = TRUE)
  }, error = function(e) message("  (progress write skipped: ", conditionMessage(e), ")"))
}


# ── MAIN ─────────────────────────────────────────────────────────────────────
main <- function() {
  P <- parse_args()
  method   <- match.arg(P$method, c("bayesian", "frequentist"))
  is_bayes <- identical(method, "bayesian")
  pick     <- make_pick(P)           # CLI-over-cascade precedence helper
  seed     <- if (nzchar(P$seed)) as.integer(P$seed) else NULL
  # NOTE: models, pcov_th, inc_me, and the study_params (is_log_response,
  # is_log_independent, apply_prozone) and the bayes sampling knobs are now
  # resolved PER GROUP from the settings cascade (with CLI override) inside the
  # loop, not fixed here. Only method/seed are run-global.

  # Parse the curve_id batch and (optional) declared group ids.
  batch <- suppressWarnings(as.integer(strsplit(trimws(P$curve_ids), "\\s*,\\s*")[[1]]))
  batch <- unique(batch[!is.na(batch)])
  if (!length(batch)) { message("No curve_ids supplied. Exiting."); return(0L) }
  app_gids <- if (nzchar(P$multiplate_group_ids))
    unique(trimws(strsplit(P$multiplate_group_ids, "\\s*,\\s*")[[1]])) else NULL

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

  conn <- open_conn(); on.exit(try(DBI::dbDisconnect(conn), silent = TRUE), add = TRUE)

  # ── read the batch from the fit-delivery views ──────────────────────────
  std <- fetch_std_for_fit(conn, batch)
  if (!nrow(std)) { message("No standard rows for this batch. Exiting."); return(0L) }
  blk <- fetch_blk_for_fit(conn, batch)
  smp <- fetch_smp_for_fit(conn, batch)

  if (!("multiplate_group_id" %in% names(std)))
    stop("standard_for_fit is missing multiplate_group_id — cannot group. [CONFIRM view]")
  std$masked <- as.logical(std$masked)
  if (nrow(blk)) blk$masked <- as.logical(blk$masked)

  # Resolve ALL settings for the batch in ONE round-trip; index per group below.
  resolved <- fetch_resolved_settings(conn, batch)
  sget     <- make_settings_accessor(resolved)
  run_blank_option <- .valid_blank_option(P$blank_option)

  # Grouping comes straight from the view.
  gids <- unique(as.character(std$multiplate_group_id))

  # Belt-and-suspenders: assert the app's intended grouping == the view's.
  if (!is.null(app_gids)) {
    app_only  <- setdiff(app_gids, gids)
    view_only <- setdiff(gids, app_gids)
    if (length(app_only) || length(view_only))
      warning(sprintf(
        "multiplate_group_id mismatch app vs view: %d app-only, %d view-only",
        length(app_only), length(view_only)), immediate. = TRUE)
  }

  total_curves <- length(batch)
  done <- 0L; failures <- 0L
  fail_log <- list()   # structured per-group failures -> deduplicated summary

  # Muffle dependency progress chatter (e.g. "Waiting for profiling to be done...")
  # so it doesn't flood the job's captured stderr. This catches message()-based
  # output; if the chatter is cat()/Stan-refresh output instead, set the fitter's
  # refresh/verbose to 0 rather than relying on this.
  quiet <- function(expr) withCallingHandlers(expr, message = function(m) {
    if (grepl("Waiting for profiling", conditionMessage(m), fixed = TRUE))
      invokeRestart("muffleMessage")
  })
  message(sprintf("worker_curveR: method=%s n_curves=%d n_groups=%d job=%s (settings: cascade, CLI overrides)",
                  method, total_curves, length(gids), P$job_id))
  message(sprintf("worker cores: %d  (source: %s)", worker_cores,
                  if (nzchar(Sys.getenv("WORKER_CORES"))) "WORKER_CORES" else "detectCores()"))
  message(sprintf("blank handling: run default = '%s'%s", run_blank_option,
                  if (nzchar(Sys.getenv("WORKER_BLANK_OPTION_COL")))
                    sprintf(" (per-antigen overrides from settings.%s)",
                            Sys.getenv("WORKER_BLANK_OPTION_COL")) else ""))
  write_progress(P$progress_dir, P$job_id, total_curves, done, "running")

  # ── fit each multiplate group ───────────────────────────────────────────
  for (gid in gids) {
    sg  <- std[as.character(std$multiplate_group_id) == gid, , drop = FALSE]
    bg  <- if (nrow(blk)) blk[as.character(blk$multiplate_group_id) == gid, , drop = FALSE]
           else blk[0, , drop = FALSE]
    smg <- if (nrow(smp)) smp[as.character(smp$multiplate_group_id) == gid, , drop = FALSE]
           else smp[0, , drop = FALSE]

    antigen <- as.character(sg$antigen[1]); feature <- as.character(sg$feature[1])
    n_grp   <- length(unique(sg$curve_id))
    rep_cid <- sg$curve_id[1]              # representative curve_id (settings are group-uniform)
    tag     <- sprintf("group=%s antigen=%s feature=%s n_curves=%d",
                       gid, antigen, feature, n_grp)

    # ---- resolve this group's settings (cascade), with CLI override ----------
    study_params <- list(
      is_log_response    = .as_bool(sget(rep_cid, "is_log_response",    "true"), TRUE),
      is_log_independent = .as_bool(sget(rep_cid, "is_log_independent", "true"), TRUE),
      apply_prozone      = .as_bool(sget(rep_cid, "apply_prozone",      "true"), TRUE))
    models  <- {
      mv <- pick("models", sget(rep_cid, "model_form_list", NULL),
                 "logistic5,loglogistic5,logistic4,loglogistic4,gompertz4")
      trimws(strsplit(mv, ",")[[1]])       # defensive trim (store is clean, UI may not be)
    }
    pcov_th <- .as_num(pick("cdan_cv", sget(rep_cid, "pcov_threshold", NULL), "20"), 20)
    inc_me  <- !identical(tolower(trimws(
                 pick("include_measurement_error",
                      sget(rep_cid, "include_measurement_error", NULL), "true"))), "false")
    # bayes sampling knobs: CLI over cascade over coded default.
    b_chains  <- as.integer(pick("chains",   sget(rep_cid, "bayes_chains",   NULL), "4"))
    b_warmup  <- as.integer(pick("warmup",   sget(rep_cid, "bayes_warmup",   NULL), "1000"))
    b_samp    <- as.integer(pick("sampling", sget(rep_cid, "bayes_sampling", NULL), "1000"))
    b_adapt   <- .as_num(pick("adapt_delta", sget(rep_cid, "adapt_delta",    NULL), "0.9"), 0.9)

    # standard_curve_concentration is a HARD requirement of curveRcore — it is a
    # concentration, conceptually and often type-distinct from a dilution factor,
    # so there is NO fallback (e.g. to nominal_sample_dilution). With the cascade
    # __system__ default of 10000 (arbitrary units) this effectively always
    # resolves, but the loud stop is kept as a low-cost, consistent safety net.
    sc      <- .as_num(sget(rep_cid, "standard_curve_concentration", NULL), NA_real_)
    bo      <- .valid_blank_option(pick("blank_option",
                 sget(rep_cid, "blank_option", NULL), run_blank_option))

    res <- quiet(tryCatch({
      if (is.null(sc) || is.na(sc))
        stop(sprintf("no standard_curve_concentration in antigen_feature_settings for antigen '%s' (feature '%s') — required by curveRcore; not fitting this group",
                     antigen, feature))

      # Row-level mask status -> included flag (TRUE = enters the fit). Masked
      # wells are retained (transformed and persisted) but NEVER fed to the fitter.
      sg$included <- !(as.logical(sg$masked) %in% TRUE)
      if (nrow(bg)) bg$included <- !(as.logical(bg$masked) %in% TRUE)

      # Preprocess the FULL set (stats from included; transforms applied to all).
      # Keep the whole object: $data + $blanks are persisted; the fitter gets
      # only the included subset.
      pp <- preprocess_standards(
        data = sg, blank_data = if (nrow(bg)) bg else NULL,
        antigen_settings = list(standard_curve_concentration = sc),
        response_variable = "mfi", independent_variable = "concentration",
        is_log_response = study_params$is_log_response,
        is_log_independent = study_params$is_log_independent,
        apply_prozone = study_params$apply_prozone,
        blank_option = bo, include_col = "included")

      # Fit inputs: included rows only, with pipeline/grouping columns stripped so
      # the (UNCHANGED) fitters see exactly the pre-cutover frame shape:
      #   included / assay_response_raw / masked  — mask-aware columns this worker
      #     and preprocess add; the fitters never saw them.
      #   multiplate_group_id                     — the view's grouping key. It is
      #     NOT a fit input (multiplate fitting keys on curve_id), so it must not
      #     leak into the fitter, where it would be unused at best or break the
      #     input contract at worst.
      # curve_id is preserved — the fitters require it.
      .fit_cols <- function(df) {
        if (is.null(df)) return(df)
        df[, setdiff(names(df),
                     c("included", "assay_response_raw", "masked", "multiplate_group_id")),
           drop = FALSE]
      }
      std_fit <- .fit_cols(pp$data[pp$data$included %in% TRUE, , drop = FALSE])
      blk_fit <- if (!nrow(bg)) NULL else {
        bf <- bg[bg$included %in% TRUE, , drop = FALSE]
        if (nrow(bf)) .fit_cols(bf) else NULL
      }
      # Samples also arrive straight from the view (SELECT *), so strip the same
      # grouping column before handing them to the fitter.
      smp_in <- if (nrow(smg)) .fit_cols(smg) else NULL

      if (is_bayes) {
        mp <- curveRbayes::fit_calibration_bayes(
          standards = std_fit, samples = smp_in, blanks = blk_fit,
          response_var = "mfi", model_names = models,
          is_log_response = study_params$is_log_response,
          is_log_independent = study_params$is_log_independent,
          std_curve_conc = sc, cv_x_max = 150, pcov_threshold = pcov_th,
          chains = b_chains, warmup = b_warmup,
          sampling = b_samp, adapt_delta = b_adapt,
          seed = seed, include_measurement_error = inc_me,
          run_loo = TRUE, verbose = FALSE)
      } else {
        mp <- curveRfreq::fit_calibration_freq_multiplate(
          standards = std_fit, blanks = blk_fit, samples = smp_in,
          response_var = "mfi", model_names = models,
          is_log_response = study_params$is_log_response,
          is_log_independent = study_params$is_log_independent,
          std_curve_conc = sc, cv_x_max = 150)
      }

      mp <- curveRcore::compute_detection_limits_multiplate(mp)

      flat <- flatten_result(mp, job_id = P$job_id, method = method)
      # Attach persisted standard/blank point sets (ALL rows, with status),
      # built from preprocessing output. curve_id is already on every row.
      pts <- flatten_calib_points(pp, job_id = P$job_id, method = method,
                                  response_var = "mfi",
                                  is_log_independent = study_params$is_log_independent)
      flat$standards <- pts$standards
      flat$blanks    <- pts$blanks
      save_calib(conn, flat)
      v <- verify_saved(mp, job_id = P$job_id, method = method, conn = conn,
                        points = pp, verbose = FALSE)
      if (!isTRUE(v$ok)) warning(tag, ": verify_saved reported failures")
      n_grp
    }, error = function(e) {
      message("  FAIL ", tag)                          # one concise line only
      fail_log[[length(fail_log) + 1L]] <<- list(      # <<- targets main()'s local
        gid = gid, antigen = antigen, feature = feature, n = n_grp,
        msg = conditionMessage(e))
      NA_integer_
    }))

    if (is.na(res)) failures <- failures + 1L else done <- done + res
    write_progress(P$progress_dir, P$job_id, total_curves, done, "running", cur_group = tag)
  }

  status <- if (failures == 0L) "completed" else "failed"

  # Collapse identical failures to one line + a few example groups. Strip the
  # row-specific DETAIL/CONTEXT so, e.g., 22 duplicate-key errors share one
  # signature instead of printing 22 multi-line COPY blocks.
  .summ <- function(fl) {
    if (!length(fl)) return(character(0))
    sig <- vapply(fl, function(f) {
      m <- sub("DETAIL:.*", "", f$msg)
      m <- sub("save_calib failed: ", "", m, fixed = TRUE)
      substr(gsub("\\s+", " ", trimws(m)), 1, 140)
    }, character(1))
    by <- split(fl, sig)
    vapply(names(by), function(s) {
      g  <- by[[s]]
      ex <- vapply(utils::head(g, 3L), function(f)
        sprintf("%s (%s/%s)", substr(f$gid, 1, 8), f$antigen, f$feature), character(1))
      sprintf("  [%d group(s)] %s\n      e.g. %s%s", length(g), s,
              paste(ex, collapse = ", "),
              if (length(g) > 3L) sprintf(" +%d more", length(g) - 3L) else "")
    }, character(1), USE.NAMES = FALSE)
  }

  write_progress(P$progress_dir, P$job_id, total_curves, done, status)
  message(sprintf("\n==== DONE — %d/%d curves saved, %d/%d group(s) failed ====",
                  done, total_curves, failures, length(gids)))
  for (l in .summ(fail_log)) message(l)
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
