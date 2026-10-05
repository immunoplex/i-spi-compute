#!/usr/bin/env Rscript
# =============================================================================
# worker_weights.R — precision-weighting job (curveRweights).
#
# Sibling to worker_curveR.R, but reads already-PERSISTED calibration output
# instead of fitting from raw wells: no curveRfreq/curveRbayes calibration call
# here at all. A weights job is deliberately decoupled, in time and in failure
# domain, from the calibration pipeline -- a Stan crash in a precision-weight
# fit can never jeopardize an already-good calibration result, because it
# never touches the calibration job's code path, data, or Redis job entry.
#
# CONTRACT (see the architecture discussion in the project history):
#   The job is a curve_id batch, exactly like a calibration job (same
#   --curve_ids/--multiplate_group_ids CLI shape, same supervisor.py dispatch
#   mechanism via SCRIPT_REGISTRY["weights_bayesian"/"weights_frequentist"]).
#   For each multiplate_group_id in the batch (same grain calibration already
#   uses -- curves differing only by plate):
#     1. read madi_results.calib_samples (joined to curve_lookup for
#        multiplate_group_id/antigen/feature), filtered to this group + the
#        requested --method ('bayesian' | 'frequentist' -- calib_samples is
#        keyed by method, so a caller must pick one)
#     2. curveRweights::as_weight_data() on that data.frame directly (the
#        documented "foreign-data escape hatch" -- there is no in-memory
#        calibration_result here, just persisted rows)
#     3. curveRweights::fit_precision_weights()
#     4. persist to calib_weights (per-sample) + calib_weights_fit (per-group)
#
# Known limitation (inherited from curveRweights, not introduced here):
#   as_weight_data.data.frame() always assumes is_log_independent = TRUE (its
#   own documented behavior: "we do not know is_log_independent here, so we
#   assume TRUE when a log10 predicted_concentration column is present").
#   Holds for every study today (the settings cascade's is_log_independent
#   default is "true" everywhere) but would silently mis-scale a study that
#   ever ran with it FALSE. Not fixed here -- flagged, matching how
#   curveRweights documents it.
#
# DB creds from env: DB_NAME/HOST/PORT/USER/PASSWORD/SSLMODE (same as
# worker_curveR.R).
# =============================================================================

suppressWarnings(suppressMessages({
  library(DBI); library(RPostgres); library(jsonlite); library(curveRweights)
  library(parallel)
}))

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || (length(a) == 1 && is.na(a))) b else a

# Resolve this script's directory across launch modes (see worker_curveR.R for
# the full rationale -- same helper, duplicated rather than shared, matching
# this codebase's existing convention of light per-script duplication over a
# shared module: open_conn()/.in_ids()-style helpers are already duplicated
# between worker_curveR.R and verify_saved.R).
.script_dir <- local({
  a <- tryCatch(commandArgs(FALSE), error = function(e) character())
  m <- grep("^--file=", a, value = TRUE)
  if (length(m)) return(dirname(normalizePath(sub("^--file=", "", m[1]))))
  for (i in rev(seq_len(sys.nframe()))) {
    of <- sys.frame(i)$ofile
    if (!is.null(of) && nzchar(of)) return(dirname(normalizePath(of)))
  }
  getwd()
})

# Only flatten_and_save.R is needed, for its .append() (dynamic column
# intersection against information_schema.columns) -- reused as-is, no change
# made there. Sourcing it also defines a lot of calibration-specific functions
# (flatten_result(), save_calib(), ...) that this script simply never calls.
for (f in c("flatten_and_save.R")) {
  cand <- unique(file.path(c(Sys.getenv("WORKER_COMPONENTS_DIR", ""),
                             .script_dir, file.path(.script_dir, "worker"),
                             getwd(), file.path(getwd(), "worker")), f))
  hit <- cand[nzchar(cand) & file.exists(cand)]
  if (length(hit)) source(hit[1])
}
if (!exists(".append", mode = "function")) {
  stop("Could not load flatten_and_save.R beside worker_weights.R (need .append()).\n",
       "Searched near: ", .script_dir,
       "\nPut it in the same folder, or set WORKER_COMPONENTS_DIR.")
}


# ── CLI ──────────────────────────────────────────────────────────────────────
# Same curve_id-batch shape as worker_curveR.R; --method has NO default (the
# two script_types weights_bayesian/weights_frequentist always pass it via
# supervisor.py's method_flag) because calib_samples is keyed by method and
# silently defaulting would pick a method the caller never chose.
parse_args <- function(argv = commandArgs(trailingOnly = TRUE)) {
  p <- list(curve_ids = "", multiplate_group_ids = "",
            job_id = "local", progress_dir = tempdir(),
            method = "", design = "", scale_predictor = "se",
            iter = "4000", warmup = "1000", chains = "4",
            adapt_delta = "0.95", seed = "")
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

# Same IN-list-interpolation convention as worker_curveR.R's .in_ids(): these
# are worker-controlled integers (never user text), so building "IN (...)" by
# string interpolation carries no injection surface. RPostgres doesn't bind an
# R vector to a PG array parameter (see worker_curveR.R's note on this).
.in_ids <- function(curve_ids) {
  v <- suppressWarnings(as.integer(curve_ids)); v <- v[!is.na(v)]
  if (!length(v)) "NULL" else paste(v, collapse = ",")
}

# One row per persisted sample, joined to curve_lookup for the group/antigen/
# feature columns calib_samples itself doesn't carry.
fetch_calib_samples <- function(conn, curve_ids, method) {
  DBI::dbGetQuery(conn, sprintf(
    "SELECT cs.*, cl.multiplate_group_id, cl.antigen, cl.feature
       FROM madi_results.calib_samples cs
       JOIN madi_results.curve_lookup cl ON cl.curve_id = cs.curve_id
      WHERE cs.curve_id IN (%s) AND cs.method = $1",
    .in_ids(curve_ids)),
    params = list(method))
}


# ── progress (same file/field contract worker_curveR.R writes, so the
# supervisor's existing progress-poller needs no change) ────────────────────
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


# ── resource budgeting (duplicated from worker_curveR.R rather than sourcing
# it wholesale -- sourcing worker_curveR.R would also execute its own
# guarded-but-fragile auto-run block unless WORKER_SOURCE_ONLY is set. These
# three helpers are pure/short; same values, same env vars, same semantics --
# a weights fit is the same MCMC cost class as a bayesian calibration fit, so
# it reuses WORKER_FIT_MEM_MB_BAYES rather than inventing a new knob). ───────
worker_mem_mb <- function() {
  env <- suppressWarnings(as.integer(Sys.getenv("WORKER_MEM_MB", "")))
  if (!is.na(env) && env >= 1L) return(env)
  limit <- Inf
  for (p in c("/sys/fs/cgroup/memory.max",
              "/sys/fs/cgroup/memory/memory.limit_in_bytes")) {
    v <- tryCatch(readLines(p, n = 1, warn = FALSE), error = function(e) NA_character_)
    n <- suppressWarnings(as.numeric(v))
    if (length(n) && is.finite(n) && n > 0 && n < 8e18) { limit <- n / 1024^2; break }
  }
  if (!is.finite(limit)) return(Inf)
  frac <- suppressWarnings(as.numeric(Sys.getenv("WORKER_MEM_FRACTION", "0.90")))
  rsv  <- suppressWarnings(as.integer(Sys.getenv("WORKER_MEM_RESERVE_MB", "1500")))
  usable <- min(limit * if (is.finite(frac)) frac else 0.90,
                limit - if (!is.na(rsv)) rsv else 1500L)
  max(1L, as.integer(usable))
}

worker_fit_mem_mb <- function() {
  env <- suppressWarnings(as.integer(Sys.getenv("WORKER_FIT_MEM_MB_BAYES",
                                                Sys.getenv("WORKER_FIT_MEM_MB", ""))))
  if (!is.na(env) && env >= 1L) return(env)
  1280L
}

plan_parallelism <- function(cores, chains,
                             mem_mb = worker_mem_mb(),
                             fit_mem_mb = worker_fit_mem_mb()) {
  per_fit   <- max(1L, as.integer(chains))
  by_cores  <- max(1L, cores %/% per_fit)
  by_memory <- if (is.finite(mem_mb) && fit_mem_mb > 0)
                 max(1L, as.integer(mem_mb %/% fit_mem_mb)) else by_cores
  n_parallel <- min(by_cores, by_memory)
  cap <- suppressWarnings(as.integer(Sys.getenv("WORKER_MAX_PARALLEL", "")))
  if (!is.na(cap) && cap >= 1L) n_parallel <- min(n_parallel, cap)
  list(n_parallel = n_parallel, per_fit = per_fit,
       by_cores = by_cores, by_memory = by_memory, mem_mb = mem_mb)
}

.quiet <- function(expr) withCallingHandlers(expr, message = function(m) {
  if (grepl("Waiting for profiling", conditionMessage(m), fixed = TRUE))
    invokeRestart("muffleMessage")
})


# ── persistence: delete-by-key then insert, same idempotency convention as
# save_calib() (reuses .append() from flatten_and_save.R; defines its own
# delete+insert here rather than modifying save_calib(), keeping the weights
# path fully additive and untouched-by/untouching calibration code). ────────
save_weights <- function(conn, weights_df, fit_row, job_id) {
  DBI::dbBegin(conn)
  ok <- tryCatch({
    if (is.data.frame(weights_df) && nrow(weights_df)) {
      method <- weights_df$method[1]
      ids <- unique(weights_df$curve_id)
      DBI::dbExecute(conn, sprintf(
        "DELETE FROM madi_results.calib_weights WHERE method = %s AND curve_id IN (%s)",
        DBI::dbQuoteLiteral(conn, method), paste(ids, collapse = ",")))
      .append(conn, "madi_results", "calib_weights", weights_df)
    }
    if (is.data.frame(fit_row) && nrow(fit_row)) {
      DBI::dbExecute(conn, sprintf(
        "DELETE FROM madi_results.calib_weights_fit WHERE multiplate_group_id = %s AND method = %s",
        DBI::dbQuoteLiteral(conn, fit_row$multiplate_group_id[1]),
        DBI::dbQuoteLiteral(conn, fit_row$method[1])))
      .append(conn, "madi_results", "calib_weights_fit", fit_row)
    }
    TRUE
  }, error = function(e) { DBI::dbRollback(conn); stop("save_weights failed: ",
                                                       conditionMessage(e), call. = FALSE) })
  DBI::dbCommit(conn)
  invisible(ok)
}


# ── fit ONE multiplate group (forked child, or inline when n_parallel == 1).
# Mirrors fit_one_group()'s isolation contract in worker_curveR.R: opens its
# OWN connection, never mutates parent state, returns a small result -- one
# group's failure is caught here and never aborts the batch. ────────────────
fit_one_weights_group <- function(gb, method, design_cols, scale_predictor,
                                  iter, warmup, chains, adapt_delta, seed,
                                  job_id, per_fit) {
  options(mc.cores = per_fit)
  # No DB read happens in this function (the batch was already fetched once,
  # in the parent, before forking) -- the connection is opened lazily, right
  # before the one place it's actually needed: persisting this group's result.

  .quiet(tryCatch({
    sg <- gb$sg
    sg$.obs_id <- seq_len(nrow(sg))   # positional key back from as_weight_data()'s obs_id

    wd <- curveRweights::as_weight_data(
      sg, design = design_cols, source = "samples", include_plate = TRUE)

    pw <- curveRweights::fit_precision_weights(
      wd, scale_predictor = scale_predictor, plate_col = "curve_id",
      iter = iter, warmup = warmup, chains = chains, cores = per_fit,
      adapt_delta = adapt_delta, seed = seed)

    # pw$weights carries obs_id/sampleid/curve_id/se/pcov/sigma/w/w_norm but
    # not patientid/timeperiod/dilution -- rejoin to the original rows by the
    # stable positional obs_id (as_weight_data() never reorders/drops rows
    # when drop_oor = FALSE, the default used above).
    ident <- sg[, c(".obs_id", "patientid", "timeperiod", "dilution"), drop = FALSE]
    wrow <- merge(pw$weights, ident, by.x = "obs_id", by.y = ".obs_id")
    wrow$method <- method
    wrow$job_id <- job_id
    # as_weight_data() coerces curve_id to character (out$curve_id <-
    # as.character(tidy$curve_id)) -- cast back for the bigint column, or
    # dbAppendTable() may reject it or silently misbehave.
    wrow$curve_id <- as.integer(wrow$curve_id)
    wrow <- wrow[, c("curve_id", "method", "sampleid", "patientid", "timeperiod",
                     "dilution", "se", "pcov", "sigma", "w", "w_norm", "job_id")]

    est <- pw$estimates
    fit_row <- data.frame(
      multiplate_group_id = gb$gid, method = method,
      antigen = gb$antigen, feature = gb$feature,
      design_cols = paste(design_cols, collapse = ","),
      scale_predictor = scale_predictor,
      phi = est$phi, phi_lo = est$phi_CI[["lo"]], phi_hi = est$phi_CI[["hi"]],
      beta1 = est$beta1, beta1_lo = est$beta1_CI[["lo"]], beta1_hi = est$beta1_CI[["hi"]],
      interpretation = est$interpretation,
      n_fit = as.integer(est$diagnostics$n_fit %||% NA_integer_),
      n_eff = est$diagnostics$weight$n_eff %||% NA_real_,
      weight_ratio = est$diagnostics$weight$weight_ratio %||% NA_real_,
      job_id = job_id, stringsAsFactors = FALSE)

    conn <- open_conn(); on.exit(try(DBI::dbDisconnect(conn), silent = TRUE), add = TRUE)
    save_weights(conn, wrow, fit_row, job_id)

    list(done = 1L, fail = NULL)
  }, error = function(e) {
    message("  FAIL ", gb$tag, ": ", conditionMessage(e))
    list(done = 0L, fail = list(gid = gb$gid, antigen = gb$antigen,
                                feature = gb$feature, msg = conditionMessage(e)))
  }))
}


# ── MAIN ─────────────────────────────────────────────────────────────────────
main <- function() {
  P <- parse_args()
  if (!nzchar(P$method))
    stop("--method is required ('bayesian' or 'frequentist') -- calib_samples ",
         "is keyed by method; there is no default.")
  method <- match.arg(P$method, c("bayesian", "frequentist"))
  design_cols <- trimws(strsplit(P$design, ",")[[1]])
  design_cols <- design_cols[nzchar(design_cols)]
  if (!length(design_cols))
    stop("--design is required (comma-joined column names, e.g. timeperiod,agroup)")

  scale_predictor <- match.arg(P$scale_predictor, c("se", "pcov"))
  iter        <- as.integer(P$iter)
  warmup      <- as.integer(P$warmup)
  chains      <- as.integer(P$chains)
  adapt_delta <- as.numeric(P$adapt_delta)
  # NB: NOT NULL when unset -- fit_saturated_weight()'s own default is 42, but
  # that default only applies if the `seed` arg is omitted entirely. Passing
  # seed = NULL explicitly (rather than omitting it) reaches brms::brm() as a
  # literal NULL and fails with "Cannot coerce 'seed' to a single numeric
  # value" (confirmed via smoke test). Match the package's own default instead
  # of trying to omit the argument through several layers of `...`.
  seed        <- if (nzchar(P$seed)) as.integer(P$seed) else 42L

  batch <- suppressWarnings(as.integer(strsplit(trimws(P$curve_ids), "\\s*,\\s*")[[1]]))
  batch <- unique(batch[!is.na(batch)])
  if (!length(batch)) { message("No curve_ids supplied. Exiting."); return(0L) }

  worker_cores <- local({
    env <- suppressWarnings(as.integer(Sys.getenv("WORKER_CORES", "")))
    if (!is.na(env) && env >= 1L) env
    else max(1L, tryCatch(parallel::detectCores(), error = function(e) 1L))
  })
  options(mc.cores = worker_cores)

  conn <- open_conn(); on.exit(try(DBI::dbDisconnect(conn), silent = TRUE), add = TRUE)
  cs <- fetch_calib_samples(conn, batch, method)
  try(DBI::dbDisconnect(conn), silent = TRUE)
  if (!nrow(cs)) {
    message("No calib_samples rows for this batch/method (", method,
            "). Was calibration run (and persisted) for these curve_ids first? Exiting.")
    return(0L)
  }

  gids <- unique(as.character(cs$multiplate_group_id))
  total_groups <- length(gids)
  done <- 0L; failures <- 0L; fail_log <- list()

  build_bundle <- function(gid) {
    sg <- cs[as.character(cs$multiplate_group_id) == gid, , drop = FALSE]
    list(gid = gid, sg = sg,
         antigen = as.character(sg$antigen[1]), feature = as.character(sg$feature[1]),
         tag = sprintf("group=%s antigen=%s feature=%s n_samples=%d",
                       gid, sg$antigen[1], sg$feature[1], nrow(sg)))
  }
  bundles <- lapply(gids, build_bundle)

  pp_plan <- plan_parallelism(worker_cores, chains)
  np <- pp_plan$n_parallel; per_fit <- pp_plan$per_fit

  message(sprintf("worker_weights: method=%s n_groups=%d design=%s job=%s",
                  method, length(gids), paste(design_cols, collapse = ","), P$job_id))
  message(sprintf("parallelism: %d group(s) at once x %d core(s)/fit (cores=%d)",
                  np, per_fit, worker_cores))
  write_progress(P$progress_dir, P$job_id, total_groups, done, "running")

  absorb <- function(r, gb) {
    if (inherits(r, "try-error") || is.null(r) || !is.list(r) || is.null(r$done)) {
      failures <<- failures + 1L
      msg <- if (inherits(r, "try-error")) conditionMessage(attr(r, "condition")) else "worker returned no result (crash/OOM?)"
      fail_log[[length(fail_log) + 1L]] <<- list(gid = gb$gid, msg = paste("child failed:", msg))
      message("  FAIL ", gb$tag)
    } else if (!is.null(r$fail)) {
      failures <<- failures + 1L
      fail_log[[length(fail_log) + 1L]] <<- r$fail
    } else {
      done <<- done + r$done
    }
  }

  run_one <- function(gb) fit_one_weights_group(
    gb, method, design_cols, scale_predictor, iter, warmup, chains,
    adapt_delta, seed, P$job_id, per_fit)

  if (np <= 1L) {
    for (gb in bundles) {
      absorb(run_one(gb), gb)
      write_progress(P$progress_dir, P$job_id, total_groups, done, "running", cur_group = gb$tag)
    }
  } else {
    batches <- split(seq_along(bundles), ceiling(seq_along(bundles) / np))
    for (bi in batches) {
      outs <- parallel::mclapply(bundles[bi], run_one, mc.cores = np, mc.preschedule = FALSE)
      for (k in seq_along(bi)) absorb(outs[[k]], bundles[[bi[k]]])
      write_progress(P$progress_dir, P$job_id, total_groups, done, "running",
                     cur_group = sprintf("%d/%d group(s) fit", done, total_groups))
    }
  }

  status <- if (failures == 0L) "completed" else "failed"
  write_progress(P$progress_dir, P$job_id, total_groups, done, status)
  message(sprintf("\n==== DONE — %d/%d group(s) saved, %d failed ====",
                  done, total_groups, failures))
  for (f in fail_log) message("  ", f$gid, ": ", f$msg)
  if (failures > 0L) 1L else 0L
}

.source_only <- identical(Sys.getenv("WORKER_SOURCE_ONLY"), "1") ||
                isTRUE(getOption("worker_weights.source_only", FALSE))
if (!.source_only) {
  status <- tryCatch(main(), error = function(e) { message("FATAL: ", conditionMessage(e)); 2L })
  if (!interactive()) quit(status = status)
}
