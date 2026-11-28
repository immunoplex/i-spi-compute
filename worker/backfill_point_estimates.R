#!/usr/bin/env Rscript
# =============================================================================
# backfill_point_estimates.R -- ONE-OFF: fill calib_controls and the 0.7.0
# estimate columns of calib_standards for curves fitted before curveRcore 0.7.0.
#
# Nothing is refitted and no existing fit row changes. For every best fit
# (calib_fit.is_best) still missing the new values, the stored fit (calib_param,
# calib_grid, calib_diagnostics, calib_draws) is read back and
# curveRcore::estimate_points_from_stored() back-calculates:
#   * the curve's standard points (calib_standards rows: response_model, nominal
#     log10_concentration) -> UPDATE of the estimate columns + recovery_pct;
#   * the curve's control wells (control_for_fit, masked wells included) ->
#     calib_controls rows (replaced per curve and method).
# Rows written here carry job_id 'backfill-0.7.0' (controls) and leave the
# standards' original job_id unchanged. How close the values are to what the
# engine would have stored: curveRcore calib_points_SPEC.md, "Backfill".
#
# Requires migration 011 (checked: schema_version calib_schema >= 0.7.0) and
# curveRcore >= 0.7.0. Resumable: a (curve, method) is done once its standards
# have estimates and its controls exist, so a stopped run picks up where it left off.
#
# Usage (DB_* env as for the worker):
#   Rscript backfill_point_estimates.R --dry-run              # compute, report, write nothing
#   Rscript backfill_point_estimates.R                         # everything still missing
#   Rscript backfill_point_estimates.R --curve_ids 101,102 --method bayesian
#   Rscript backfill_point_estimates.R --batch 100 --limit 500
# Each batch is one transaction.
# =============================================================================

BACKFILL_JOB_ID <- "backfill-0.7.0"
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

# point_estimates.R sits beside this script (sourced copy, Rscript, or /app).
if (!exists("pe_compute_one", mode = "function")) local({
  dirs <- character()
  for (i in rev(seq_len(sys.nframe()))) {
    of <- sys.frame(i)$ofile
    if (!is.null(of) && nzchar(of)) { dirs <- c(dirs, dirname(normalizePath(of))); break }
  }
  f <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(f)) dirs <- c(dirs, dirname(normalizePath(sub("^--file=", "", f[1]))))
  dirs <- c(dirs, Sys.getenv("WORKER_COMPONENTS_DIR", ""), getwd(), file.path(getwd(), "worker"), "/app")
  hit <- file.path(dirs[nzchar(dirs)], "point_estimates.R")
  hit <- hit[file.exists(hit)]
  if (!length(hit)) stop("point_estimates.R not found beside backfill_point_estimates.R")
  source(hit[1])
})

.in_ids <- function(x) {
  v <- suppressWarnings(as.integer(x)); v <- v[!is.na(v)]
  if (!length(v)) "NULL" else paste(unique(v), collapse = ",")
}

# PostgreSQL double precision[] as returned by RPostgres ("{1,2,3}") or as a list.
bf_parse_array <- function(x) {
  if (is.list(x)) return(lapply(x, as.numeric))
  lapply(as.character(x), function(s) {
    s <- gsub("[{}]", "", s)
    if (!nzchar(s)) numeric(0) else suppressWarnings(as.numeric(strsplit(s, ",", fixed = TRUE)[[1]]))
  })
}

bf_check_schema <- function(conn) {
  v <- tryCatch(DBI::dbGetQuery(conn,
         "SELECT version FROM madi_results.schema_version WHERE component = 'calib_schema'"),
         error = function(e) data.frame(version = character()))
  ok <- nrow(v) && any(vapply(v$version, function(s)
          utils::compareVersion(s, curveRcore::calib_schema_version()) >= 0, logical(1)))
  if (!ok) stop("calib_schema ", curveRcore::calib_schema_version(),
                " is not recorded in madi_results.schema_version: apply migration 011 first.")
  invisible(TRUE)
}

# Best fits still missing standard estimates or controls.
bf_targets <- function(conn, curve_ids = NULL, method = NULL, limit = NULL) {
  where <- c("f.is_best")
  if (length(curve_ids)) where <- c(where, sprintf("f.curve_id IN (%s)", .in_ids(curve_ids)))
  if (length(method))    where <- c(where, sprintf("f.method = %s", DBI::dbQuoteLiteral(conn, method)))
  sql <- sprintf(
    "SELECT f.curve_id, f.method, f.model_name
       FROM madi_results.calib_fit f
      WHERE %s
        AND ((EXISTS (SELECT 1 FROM madi_results.calib_standards s
                       WHERE s.curve_id = f.curve_id AND s.method = f.method)
              -- not yet estimated: no standard of the pair has any estimate.
              -- (Testing pcov alone re-selected every curve with a point
              -- beyond an asymptote, whose pcov stays NULL by design.)
              AND NOT EXISTS (SELECT 1 FROM madi_results.calib_standards s
                               WHERE s.curve_id = f.curve_id AND s.method = f.method
                                 AND (s.pcov IS NOT NULL OR s.predicted_log10_concentration IS NOT NULL
                                      OR s.censor_class IS NOT NULL)))
             OR (EXISTS (SELECT 1 FROM madi_results.control_for_fit c WHERE c.curve_id = f.curve_id)
                 AND NOT EXISTS (SELECT 1 FROM madi_results.calib_controls cc
                                  WHERE cc.curve_id = f.curve_id AND cc.method = f.method)))
      ORDER BY f.curve_id, f.method%s",
    paste(where, collapse = " AND "),
    if (length(limit)) sprintf(" LIMIT %d", as.integer(limit)) else "")
  tg <- DBI::dbGetQuery(conn, sql)
  tg$curve_id <- as.numeric(tg$curve_id)      # bigint arrives as integer64
  tg
}

# Everything stored for a batch of curve_ids, best model only.
bf_load <- function(conn, curve_ids) {
  ids <- .in_ids(curve_ids)
  # bigint columns arrive as integer64, which data.frame() will not recycle:
  # make every curve_id a plain double.
  q <- function(sql) {
    d <- DBI::dbGetQuery(conn, sprintf(sql, ids))
    if ("curve_id" %in% names(d)) d$curve_id <- as.numeric(d$curve_id)
    d
  }
  best_join <- "JOIN madi_results.calib_fit f ON f.curve_id = x.curve_id AND f.method = x.method
                 AND f.model_name = x.model_name AND f.is_best"
  draws <- q(paste0("SELECT x.curve_id, x.method, x.term, x.param_scope, x.draws
                       FROM madi_results.calib_draws x ", best_join, "
                      WHERE x.curve_id IN (%s)
                        AND (x.param_scope = 'curve'
                             OR x.term IN ('sigma_obs','nu','sigma_add','cv'))"))
  if (nrow(draws)) draws$draws <- bf_parse_array(draws$draws)
  list(
    params = q(paste0("SELECT x.curve_id, x.method, x.term, x.estimate
                         FROM madi_results.calib_param x ", best_join, " WHERE x.curve_id IN (%s)")),
    grid = q("SELECT curve_id, method, log10_concentration, concentration, se_concentration
                FROM madi_results.calib_grid WHERE curve_id IN (%s)"),
    diag = q("SELECT * FROM madi_results.calib_diagnostics WHERE curve_id IN (%s)"),
    draws = draws,
    # noise model and response adjustment as recorded in the run's params
    # (curveR >= 0.6.0); NULL for older runs = constant noise, no adjustment.
    noise_model = q("SELECT f.curve_id, f.method,
                            r.params::jsonb ->> 'noise_model' AS noise_model
                       FROM madi_results.calib_fit f
                       LEFT JOIN madi_results.calib_run r ON r.job_id = f.job_id
                      WHERE f.is_best AND f.curve_id IN (%s)"),
    adjustment = q("SELECT f.curve_id, f.method,
                           (r.params::jsonb -> 'response_adjustment' ->> 'blank_value')::float8    AS blank_value,
                           (r.params::jsonb -> 'response_adjustment' ->> 'offset')::float8         AS offset,
                           (r.params::jsonb -> 'response_adjustment' ->> 'response_floor')::float8 AS response_floor
                      FROM madi_results.calib_fit f
                      LEFT JOIN madi_results.calib_run r ON r.job_id = f.job_id
                     WHERE f.is_best AND f.curve_id IN (%s)"),
    x_scale = q("SELECT curve_id, method,
                        bool_and(abs(predicted_concentration - predicted_log10_concentration) < 1e-9) AS log_x
                   FROM madi_results.calib_samples
                  WHERE curve_id IN (%s) AND predicted_concentration IS NOT NULL
                    AND predicted_log10_concentration IS NOT NULL
                  GROUP BY curve_id, method"),
    settings = tryCatch(q("SELECT curve_id, param_name, value_text
                             FROM madi_results.resolve_settings_batch(ARRAY[%s]::bigint[])
                            WHERE param_name IN ('is_log_response','is_log_independent',
                                                 'include_measurement_error')"),
                        error = function(e) data.frame(curve_id = numeric(), param_name = character(),
                                                       value_text = character())),
    standards = q("SELECT curve_id, method, well, dilution, concentration, log10_concentration,
                          response_model, assay_response_raw, included, exclusion_reason
                     FROM madi_results.calib_standards WHERE curve_id IN (%s)"),
    controls = q("SELECT curve_id, well, sampleid, control_source, dilution, mfi, masked, mask_reason
                    FROM madi_results.control_for_fit WHERE curve_id IN (%s)")
  )
}

# The calculation itself lives in point_estimates.R (shared with the worker,
# which runs it right after each fit), so a backfilled curve and a new curve get
# identical calculations.
bf_compute_one <- function(L, cid, method, model_name)
  pe_compute_one(L, cid, method, model_name, job_id = BACKFILL_JOB_ID)

bf_write <- function(conn, std, ctl) {
  if (is.data.frame(std) && nrow(std)) {
    curveRcore::validate_point_estimates(std, "standards")
    cols <- intersect(pe_est_cols(), names(std))
    tmp <- std[, c("curve_id", "method", "well", "dilution", cols)]
    DBI::dbWriteTable(conn, "bf_std_tmp", tmp, temporary = TRUE, overwrite = TRUE)
    DBI::dbExecute(conn, sprintf(
      "UPDATE madi_results.calib_standards s SET %s
         FROM bf_std_tmp t
        WHERE s.curve_id = t.curve_id AND s.method = t.method AND s.well = t.well
          AND s.dilution = t.dilution",
      paste(sprintf("%s = t.%s", cols, cols), collapse = ", ")))
    DBI::dbExecute(conn, "DROP TABLE bf_std_tmp")
  }
  if (is.data.frame(ctl) && nrow(ctl)) {
    curveRcore::validate_point_estimates(ctl, "controls")
    keys <- unique(ctl[, c("curve_id", "method")])
    for (i in seq_len(nrow(keys)))
      DBI::dbExecute(conn, "DELETE FROM madi_results.calib_controls WHERE curve_id = $1 AND method = $2",
                     params = list(keys$curve_id[i], keys$method[i]))
    DBI::dbAppendTable(conn, DBI::Id(schema = "madi_results", table = "calib_controls"), ctl)
  }
  invisible(TRUE)
}

backfill_point_estimates <- function(conn, curve_ids = NULL, method = NULL, batch = 200L,
                                     limit = NULL, dry_run = FALSE, verbose = TRUE) {
  bf_check_schema(conn)
  tg <- bf_targets(conn, curve_ids, method, limit)
  say <- function(...) if (verbose) message(sprintf(...))
  say("backfill: %d (curve, method) pairs to process%s", nrow(tg), if (dry_run) " [dry run]" else "")
  tot <- list(pairs = 0L, skipped = 0L, standards = 0L, controls = 0L, sources = character())
  if (!nrow(tg)) return(invisible(tot))
  ids <- unique(tg$curve_id)
  chunks <- split(ids, ceiling(seq_along(ids) / batch))
  for (k in seq_along(chunks)) {
    L <- bf_load(conn, chunks[[k]])
    tk <- tg[tg$curve_id %in% chunks[[k]], ]
    std_all <- list(); ctl_all <- list()
    for (i in seq_len(nrow(tk))) {
      r <- tryCatch(bf_compute_one(L, tk$curve_id[i], tk$method[i], tk$model_name[i]),
                    error = function(e) { say("  curve %s %s: %s [in %s]", tk$curve_id[i], tk$method[i],
                                              conditionMessage(e),
                                              paste(deparse(conditionCall(e))[1], collapse = "")); NULL })
      if (is.null(r)) { tot$skipped <- tot$skipped + 1L; next }
      tot$pairs <- tot$pairs + 1L
      std_all[[length(std_all) + 1L]] <- r$standards
      ctl_all[[length(ctl_all) + 1L]] <- r$controls
      tot$sources <- c(tot$sources, r$sources)
    }
    std <- if (length(std_all)) do.call(rbind, std_all) else NULL
    ctl <- if (length(ctl_all)) do.call(rbind, ctl_all) else NULL
    tot$standards <- tot$standards + NROW(std); tot$controls <- tot$controls + NROW(ctl)
    if (!dry_run) DBI::dbWithTransaction(conn, bf_write(conn, std, ctl))
    say("  batch %d/%d: %d curves, %d standard rows, %d control rows%s", k, length(chunks),
        length(chunks[[k]]), NROW(std), NROW(ctl), if (dry_run) " (not written)" else " written")
  }
  src <- table(factor(tot$sources, levels = c("draws", "profile", "none")))
  say("backfill done: %d pairs, %d skipped, %d standard rows, %d control rows; se from draws %d, profile %d, none %d",
      tot$pairs, tot$skipped, tot$standards, tot$controls, src[["draws"]], src[["profile"]], src[["none"]])
  invisible(tot)
}


# ── CLI ──────────────────────────────────────────────────────────────────────
if (sys.nframe() == 0L) {
  suppressMessages({ library(DBI); library(RPostgres) })
  if (utils::packageVersion("curveRcore") < "0.7.0") stop("curveRcore >= 0.7.0 is required.")
  a <- commandArgs(trailingOnly = TRUE)
  arg <- function(k) { i <- match(paste0("--", k), a); if (is.na(i) || i == length(a)) NULL else a[i + 1L] }
  conn <- DBI::dbConnect(RPostgres::Postgres(),
    dbname = Sys.getenv("DB_NAME", "local_madi_ispi"), host = Sys.getenv("DB_HOST", "localhost"),
    port = as.integer(Sys.getenv("DB_PORT", "5432")), user = Sys.getenv("DB_USER", ""),
    password = Sys.getenv("DB_PASSWORD", ""), sslmode = Sys.getenv("DB_SSLMODE", "disable"),
    options = "-c search_path=madi_results")
  on.exit(DBI::dbDisconnect(conn), add = TRUE)
  cids <- arg("curve_ids")
  backfill_point_estimates(conn,
    curve_ids = if (length(cids)) strsplit(cids, ",", fixed = TRUE)[[1]] else NULL,
    method = arg("method"), batch = as.integer(arg("batch") %||% 200L),
    limit = if (length(arg("limit"))) as.integer(arg("limit")) else NULL,
    dry_run = "--dry-run" %in% a)
}
