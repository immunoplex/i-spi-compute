# =============================================================================
# verify_saved.R — post-save verification for the curveR calib_* tables.
#
# After a batch is fitted and saved, verify_saved() checks that the rows landed
# in the right tables with the right cardinality and content, by comparing what
# the in-memory calibration_result_multiplate object PRODUCED against what the
# database actually CONTAINS for those curve_ids + method.
#
# It is deliberately independent of the save code: if the flattener silently
# drops rows, writes to the wrong table, or double-writes, this catches it.
#
# Targets the schema in calib_schema_v1.sql (madi_results.calib_*).
#
# USAGE
#   source("verify_saved.R")
#   # mp is the object returned by fit_calibration_bayes()/_freq_multiplate()
#   res <- verify_saved(mp, job_id = "local-test")
#   res$ok        # TRUE if every hard check passed
#   res$checks    # per-check data frame (curve_id, table, check, expected, observed, pass)
#
# Connection: pass conn = <DBIConnection>, or leave NULL to open one from the
# same DB_* env vars the worker uses (DB_NAME/HOST/PORT/USER/PASSWORD/SSLMODE).
# =============================================================================

suppressWarnings(suppressMessages({
  library(DBI)
  library(RPostgres)
}))

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || (length(a) == 1 && is.na(a))) b else a


# ── internal: open a connection from env if none supplied ────────────────────
.vs_open_conn <- function(schema = "madi_results") {
  DBI::dbConnect(
    RPostgres::Postgres(),
    dbname   = Sys.getenv("DB_NAME",    "local_madi_ispi"),
    host     = Sys.getenv("DB_HOST",    "localhost"),
    port     = as.integer(Sys.getenv("DB_PORT", "5432")),
    user     = Sys.getenv("DB_USER",    ""),
    password = Sys.getenv("DB_PASSWORD", ""),
    sslmode  = Sys.getenv("DB_SSLMODE", "disable"),
    options  = paste0("-c search_path=", schema),
    connect_timeout = 10L
  )
}


# ── internal: expected per-curve counts from the fitted object ───────────────
# Works on a calibration_result_multiplate (preferred) or a single
# calibration_result. Returns a data frame keyed by curve_id.
.vs_expected <- function(mp, method = NULL) {

  # Normalise to a named list of single-curve results
  if (inherits(mp, "calibration_result_multiplate")) {
    plates <- mp$plates
    method <- method %||% mp$meta$method
  } else if (inherits(mp, "calibration_result")) {
    plates <- stats::setNames(list(mp), as.character(mp$meta$curve_id))
    method <- method %||% mp$meta$method
  } else {
    stop("mp must be a calibration_result or calibration_result_multiplate")
  }

  rows <- lapply(names(plates), function(cid) {
    cr <- plates[[cid]]
    if (is.null(cr)) return(NULL)

    ens        <- cr$ensemble %||% list()
    n_models   <- length(ens)
    best       <- cr$selection$best_model_name %||% NA_character_

    # param rows = sum of parameter-table rows across all attempted models
    n_param <- sum(vapply(ens, function(e) {
      p <- e$parameters
      if (is.data.frame(p)) nrow(p) else 0L
    }, integer(1)))

    # gate rows: best-effort (bayes: ensemble[[m]]$eligibility$gates;
    # shared: selection$assessments[[m]]$gates). Informational only.
    n_gate <- tryCatch({
      g1 <- sum(vapply(ens, function(e) {
        gd <- e$eligibility$gates
        if (is.data.frame(gd)) nrow(gd) else 0L
      }, integer(1)))
      if (g1 > 0) g1 else {
        asmts <- cr$selection$assessments %||% list()
        sum(vapply(asmts, function(a) {
          gd <- a$gates; if (is.data.frame(gd)) nrow(gd) else 0L
        }, integer(1)))
      }
    }, error = function(e) NA_integer_)

    n_grid    <- if (is.data.frame(cr$grid)) nrow(cr$grid) else 0L
    n_samples <- if (is.data.frame(cr$samples)) nrow(cr$samples) else 0L

    data.frame(
      curve_id      = as.character(cid),
      method        = method,
      exp_fit       = n_models,          # one calib_fit row per attempted model
      exp_best      = 1L,                # exactly one is_best per curve×method
      best_model    = as.character(best),
      exp_param     = as.integer(n_param),
      exp_gate      = as.integer(n_gate),
      exp_grid      = as.integer(n_grid),
      exp_samples   = as.integer(n_samples),
      exp_diag      = 1L,                # one diagnostics row per curve×method
      exp_loo       = if (identical(method, "bayesian")) n_models else 0L,
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, Filter(Negate(is.null), rows))
}


# ── internal: grouped COUNT(*) by curve_id for one table ─────────────────────
# Returns data.frame(curve_id, n). Missing table -> NULL (with a warning).
.vs_counts <- function(conn, schema, table, method, curve_ids, job_id = NULL,
                       extra_select = "") {
  ids <- paste(as.character(curve_ids), collapse = ",")
  # Scope by (method, curve_id) only — already exact. Do NOT filter by job_id:
  # calib_param and calib_gate have no job_id column, so filtering there errors,
  # which previously got swallowed and misreported as 0 observed rows.
  where <- sprintf("method = '%s' AND curve_id IN (%s)", method, ids)
  sel <- if (nzchar(extra_select)) paste0(", ", extra_select) else ""
  sql <- sprintf(
    "SELECT curve_id, COUNT(*) AS n%s FROM %s.%s WHERE %s GROUP BY curve_id",
    sel, schema, table, where
  )
  tryCatch(
    DBI::dbGetQuery(conn, sql),
    error = function(e) {
      warning(sprintf("could not query %s.%s: %s", schema, table, conditionMessage(e)))
      NULL
    }
  )
}


#' Verify a saved batch against the fitted object
#'
#' @param mp calibration_result_multiplate (or calibration_result) that was saved.
#'   Supplies the EXPECTED counts. Required for content verification.
#' @param job_id Optional job id to further scope the DB queries.
#' @param method "frequentist"/"bayesian"; defaults to the object's method.
#' @param conn Optional DBI connection; opened from env vars if NULL.
#' @param schema Schema holding the calib_* tables. Default "madi_results".
#' @param points Optional preprocessing output (`curveRcore::preprocess_standards()`,
#'   i.e. the `pp` object with `$data` and `$blanks`). When supplied, the
#'   persisted `calib_standards` / `calib_blanks` are verified against it
#'   (per-curve row counts, plus informational included/excluded checks).
#'   NULL skips those checks so callers that never persisted points still pass.
#' @param verbose Print a readable report. Default TRUE.
#'
#' @return Invisibly, a list: ok (logical), checks (data frame), soft (data
#'   frame of informational checks). `ok` reflects the HARD checks only.
verify_saved <- function(mp,
                         job_id  = NULL,
                         method  = NULL,
                         conn    = NULL,
                         schema  = "madi_results",
                         points  = NULL,
                         verbose = TRUE) {

  exp <- .vs_expected(mp, method)
  method <- exp$method[1]
  curve_ids <- exp$curve_id

  own_conn <- is.null(conn)
  if (own_conn) conn <- .vs_open_conn(schema)
  on.exit(if (own_conn) try(DBI::dbDisconnect(conn), silent = TRUE), add = TRUE)

  # ── observed counts per table ──────────────────────────────────────────────
  fit_obs <- .vs_counts(conn, schema, "calib_fit", method, curve_ids, job_id,
                        extra_select = paste(
                          "SUM(CASE WHEN is_best THEN 1 ELSE 0 END) AS n_best",
                          "MAX(CASE WHEN is_best THEN model_name END) AS best_model",
                          sep = ", "))
  param_obs <- .vs_counts(conn, schema, "calib_param",       method, curve_ids, job_id)
  gate_obs  <- .vs_counts(conn, schema, "calib_gate",        method, curve_ids, job_id)
  grid_obs  <- .vs_counts(conn, schema, "calib_grid",        method, curve_ids, job_id)
  samp_obs  <- .vs_counts(conn, schema, "calib_samples",     method, curve_ids, job_id)
  diag_obs  <- .vs_counts(conn, schema, "calib_diagnostics", method, curve_ids, job_id)
  loo_obs   <- .vs_counts(conn, schema, "calib_loo",         method, curve_ids, job_id)

  # persisted point sets (only checked when the caller passes `points` = pp)
  std_obs <- blk_obs <- NULL
  std_exp <- blk_exp <- NULL
  if (!is.null(points)) {
    std_obs <- .vs_counts(conn, schema, "calib_standards", method, curve_ids, job_id,
                          extra_select = "SUM(CASE WHEN included THEN 1 ELSE 0 END) AS n_incl")
    blk_obs <- .vs_counts(conn, schema, "calib_blanks",    method, curve_ids, job_id)
    # expected per-curve counts derived from pp (upstream of the save code)
    .per_curve <- function(df) {
      if (!is.data.frame(df) || !nrow(df) || !("curve_id" %in% names(df)))
        return(list(n = stats::setNames(integer(0), character(0)),
                    inc = stats::setNames(integer(0), character(0))))
      cc  <- as.character(df$curve_id)
      inc <- if ("included" %in% names(df)) (df$included %in% TRUE) else rep(TRUE, nrow(df))
      list(n = tapply(seq_len(nrow(df)), cc, length),
           inc = tapply(inc, cc, sum))
    }
    # Exclude the synthetic blank_option=="included" anchor (well='blank_mean',
    # dilution=NA) from the expected standards — flatten_calib_points drops it
    # too (it would violate the calib_standards PK), so counts must agree.
    std_src <- points$data
    if (is.data.frame(std_src) && nrow(std_src) && "dilution" %in% names(std_src)) {
      k <- !is.na(std_src$dilution)
      if ("well" %in% names(std_src)) k <- k & (as.character(std_src$well) != "blank_mean")
      std_src <- std_src[k, , drop = FALSE]
    }
    std_exp <- .per_curve(std_src)
    blk_exp <- .per_curve(points$blanks)
  }

  # helper: observed n for a curve_id from a counts frame (0 if absent)
  obs_n <- function(df, cid, col = "n") {
    if (is.null(df) || !(cid %in% as.character(df$curve_id))) return(0L)
    v <- df[[col]][as.character(df$curve_id) == cid][1]
    if (is.na(v)) 0L else v
  }
  obs_chr <- function(df, cid, col) {
    if (is.null(df) || !(cid %in% as.character(df$curve_id))) return(NA_character_)
    as.character(df[[col]][as.character(df$curve_id) == cid][1])
  }

  hard <- list()   # counted in ok
  soft <- list()   # informational only

  # pure row builder — no closures, no <<-
  mk <- function(cid, table, check, expected, observed) {
    data.frame(
      curve_id = as.character(cid), table = table, check = check,
      expected = as.character(expected), observed = as.character(observed),
      pass = isTRUE(as.character(expected) == as.character(observed)),
      stringsAsFactors = FALSE)
  }

  for (i in seq_len(nrow(exp))) {
    cid <- exp$curve_id[i]

    hard <- c(hard, list(
      mk(cid, "calib_fit",         "n_models",       exp$exp_fit[i],     obs_n(fit_obs, cid)),
      mk(cid, "calib_fit",         "one_best",       exp$exp_best[i],    obs_n(fit_obs, cid, "n_best")),
      mk(cid, "calib_fit",         "best_matches",   exp$best_model[i],  obs_chr(fit_obs, cid, "best_model")),
      mk(cid, "calib_grid",        "n_points",       exp$exp_grid[i],    obs_n(grid_obs, cid)),
      mk(cid, "calib_samples",     "n_samples",      exp$exp_samples[i], obs_n(samp_obs, cid)),
      mk(cid, "calib_diagnostics", "one_row",        exp$exp_diag[i],    obs_n(diag_obs, cid)),
      mk(cid, "calib_param",       "params_present", "true",
         if (obs_n(param_obs, cid) > 0) "true" else "false")
    ))

    soft <- c(soft, list(
      mk(cid, "calib_param", "n_param_rows", exp$exp_param[i], obs_n(param_obs, cid)),
      mk(cid, "calib_loo",   "n_loo_rows",   exp$exp_loo[i],   obs_n(loo_obs, cid))
    ))

    # persisted point sets (mask-aware contract) — only when `points` supplied
    if (!is.null(points)) {
      gett <- function(t, k) {
        if (is.null(t)) return(0L)
        v <- unname(t[as.character(k)])
        if (length(v) == 0L || is.na(v)) 0L else as.integer(v)
      }
      exp_std <- gett(std_exp$n,  cid); exp_std_inc <- gett(std_exp$inc, cid)
      exp_blk <- gett(blk_exp$n,  cid)
      obs_std <- obs_n(std_obs, cid);   obs_std_inc <- obs_n(std_obs, cid, "n_incl")
      obs_blk <- obs_n(blk_obs, cid)

      hard <- c(hard, list(
        mk(cid, "calib_standards", "n_points", exp_std, obs_std),
        mk(cid, "calib_blanks",    "n_points", exp_blk, obs_blk)
      ))
      soft <- c(soft, list(
        mk(cid, "calib_standards", "n_included", exp_std_inc, obs_std_inc),
        # informational: masked points should be present & carry included=FALSE
        mk(cid, "calib_standards", "has_excluded",
           if (exp_std - exp_std_inc > 0) "true" else "false",
           if (obs_std - obs_std_inc > 0) "true" else "false")
      ))
    }
    if (!is.na(exp$exp_gate[i]))
      soft <- c(soft, list(mk(cid, "calib_gate", "n_gates", exp$exp_gate[i], obs_n(gate_obs, cid))))
  }

  checks <- if (length(hard)) do.call(rbind, hard) else
    data.frame(curve_id=character(), table=character(), check=character(),
               expected=character(), observed=character(), pass=logical())
  soft_df <- if (length(soft)) do.call(rbind, soft) else checks[0, ]

  # ── orphan check: children whose curve_id is not in calib_fit ───────────────
  orphan_rows <- tryCatch({
    ids <- paste(curve_ids, collapse = ",")
    DBI::dbGetQuery(conn, sprintf(
      "SELECT t.table, t.curve_id FROM (
         SELECT 'calib_grid' AS table, curve_id FROM %1$s.calib_grid
           WHERE method='%2$s' AND curve_id IN (%3$s)
         UNION SELECT 'calib_samples', curve_id FROM %1$s.calib_samples
           WHERE method='%2$s' AND curve_id IN (%3$s)
         UNION SELECT 'calib_diagnostics', curve_id FROM %1$s.calib_diagnostics
           WHERE method='%2$s' AND curve_id IN (%3$s)
         UNION SELECT 'calib_standards', curve_id FROM %1$s.calib_standards
           WHERE method='%2$s' AND curve_id IN (%3$s)
         UNION SELECT 'calib_blanks', curve_id FROM %1$s.calib_blanks
           WHERE method='%2$s' AND curve_id IN (%3$s)
       ) t
       LEFT JOIN %1$s.calib_fit f
         ON f.curve_id = t.curve_id AND f.method = '%2$s'
       WHERE f.curve_id IS NULL",
      schema, method, ids))
  }, error = function(e) NULL)

  n_orphans <- if (is.null(orphan_rows)) NA_integer_ else nrow(orphan_rows)
  checks <- rbind(checks, data.frame(
    curve_id = "-", table = "cross", check = "no_orphans",
    expected = "0", observed = as.character(n_orphans %||% "NA"),
    pass = isTRUE(n_orphans == 0L), stringsAsFactors = FALSE))

  ok <- all(checks$pass, na.rm = TRUE) && !anyNA(checks$pass)

  if (verbose) {
    cat("============================================================\n")
    cat(sprintf("verify_saved — method=%s  curves=%d%s\n",
                method, length(curve_ids),
                if (!is.null(job_id)) paste0("  job=", job_id) else ""))
    cat("============================================================\n")
    fails <- checks[!checks$pass %in% TRUE, , drop = FALSE]
    if (nrow(fails) == 0L) {
      cat("HARD CHECKS: all", nrow(checks), "passed.\n")
    } else {
      cat(sprintf("HARD CHECKS: %d/%d passed. Failures:\n",
                  sum(checks$pass, na.rm = TRUE), nrow(checks)))
      print(fails, row.names = FALSE)
    }
    soft_fail <- soft_df[!soft_df$pass %in% TRUE, , drop = FALSE]
    if (nrow(soft_fail) > 0L) {
      cat("\nINFORMATIONAL mismatches (not counted in ok):\n")
      print(soft_fail, row.names = FALSE)
    }
    cat("------------------------------------------------------------\n")
    cat(if (ok) "RESULT: PASS\n" else "RESULT: FAIL\n")
  }

  invisible(list(ok = ok, checks = checks, soft = soft_df, orphans = orphan_rows))
}
