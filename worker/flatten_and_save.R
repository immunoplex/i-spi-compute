# =============================================================================
# flatten_and_save.R — turn a curveR calibration_result(_multiplate) into
# calib_* rows and persist them idempotently, keyed purely on curve_id.
#
# Design (see REFACTOR_PLAN.md §3 and the natural-key note):
#   * curve_lookup is authoritative and load-time only. This code NEVER writes
#     to it. It resolves curve_id by READ, and errors on an unresolved curve.
#   * Every write keys on curve_id (+ method). Idempotency = delete-by-
#     (curve_id, method) then insert, inside one transaction.
#   * The calibration_result contract is identical across engines; only the
#     selection fields differ (AIC vs LOO), handled in flatten_fit()/flatten_loo().
#
# Public functions:
#   lookup_curve_ids(conn, nk_df)          # read-only NK -> curve_id resolver
#   flatten_result(mp, job_id, method)     # -> named list of data.frames
#   save_calib(conn, flat, schema)         # idempotent transactional write
#
# Confirmed against curveRbayes source (fit_calibration_bayes.R):
#   * LLOQ/ULOQ + shape-LOQ read from cr$ensemble[[best]]$eligibility.
#   * LOO comparison/weights read from mp$meta$selection; weights aligned to
#     ensemble model order.
#   * Inflection point derived from the grid (point estimate only).
#
# Two OPTIONAL one-line curveRbayes changes would enrich output (not required):
#   (a) persist loo_results  -> populates calib_loo pareto-k counts
#   (b) keep names on loo_weights -> removes reliance on positional alignment
#   Plus a curveRcore compute_inflection() would fill the inflection CI columns.
# =============================================================================

suppressWarnings(suppressMessages({ library(DBI); library(RPostgres) }))

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a
.na <- function(x) if (is.null(x) || length(x) == 0) NA_real_ else suppressWarnings(as.numeric(x)[1])
.chr <- function(x) if (is.null(x) || length(x) == 0) NA_character_ else as.character(x)[1]


# ── READ-ONLY curve_id resolution ────────────────────────────────────────────
# nk_df: one row per curve with the 10 curve_lookup_nk columns. Returns nk_df
# with a curve_id column. Curves that don't resolve are an ERROR by default —
# the worker must not invent curve_lookup rows.
lookup_curve_ids <- function(conn, nk_df, schema = "madi_results",
                             on_missing = c("error", "warn", "drop")) {
  on_missing <- match.arg(on_missing)
  nk_cols <- c("project_id","study_accession","experiment_accession","plateid",
               "plate","nominal_sample_dilution","source","wavelength",
               "antigen","feature")
  miss <- setdiff(nk_cols, names(nk_df))
  if (length(miss)) stop("nk_df missing NK columns: ", paste(miss, collapse = ", "))

  lk <- DBI::dbReadTable(conn, DBI::Id(schema = schema, table = "curve_lookup"))
  out <- merge(nk_df, lk[, c(nk_cols, "curve_id")], by = nk_cols, all.x = TRUE)

  unresolved <- out[is.na(out$curve_id), , drop = FALSE]
  if (nrow(unresolved)) {
    msg <- sprintf("%d curve(s) have no curve_lookup row (loaded data missing?).",
                   nrow(unresolved))
    if (on_missing == "error") stop(msg, call. = FALSE)
    if (on_missing == "warn")  warning(msg, immediate. = TRUE)
    if (on_missing == "drop")  out <- out[!is.na(out$curve_id), , drop = FALSE]
  }
  out
}


# ── Normalise a multiplate/single result to a list of single-curve results ───
.as_plates <- function(mp) {
  if (inherits(mp, "calibration_result_multiplate")) return(mp$plates)
  if (inherits(mp, "calibration_result"))
    return(stats::setNames(list(mp), as.character(mp$meta$curve_id)))
  stop("mp must be a calibration_result or calibration_result_multiplate")
}

# per-model gate table, tried in the two places it may live
.get_gates <- function(cr, model_name) {
  g <- tryCatch(cr$ensemble[[model_name]]$eligibility$gates, error = function(e) NULL)
  if (is.data.frame(g)) return(g)
  g <- tryCatch(cr$selection$assessments[[model_name]]$gates, error = function(e) NULL)
  if (is.data.frame(g)) return(g)
  NULL
}
.get_assessment <- function(cr, model_name) {
  a <- tryCatch(cr$selection$assessments[[model_name]], error = function(e) NULL)
  if (!is.null(a)) return(a)
  tryCatch(cr$ensemble[[model_name]]$eligibility, error = function(e) NULL)
}


# ── FLATTEN ──────────────────────────────────────────────────────────────────
flatten_result <- function(mp, job_id, method = NULL) {
  plates <- .as_plates(mp)
  method <- method %||%
    (if (inherits(mp, "calibration_result_multiplate")) mp$meta$method else plates[[1]]$meta$method)
  is_bayes <- identical(method, "bayesian")

  fit_rows <- param_rows <- gate_rows <- grid_rows <- samp_rows <-
    diag_rows <- loo_rows <- list()

  # pooled LOO info (bayes): computed once on the joint fit, replicated per curve
  loo_info <- if (is_bayes) .loo_table(mp) else NULL   # data.frame(model_name, elpd_loo, ...)

  for (cid in names(plates)) {
    cr <- plates[[cid]]; if (is.null(cr)) next
    ens  <- cr$ensemble %||% list()
    sel  <- cr$selection %||% list()
    best <- sel$best_model_name %||% NA_character_
    pkg  <- cr$meta$package %||% NA_character_
    ver  <- cr$meta$version %||% NA_character_
    cid_i <- suppressWarnings(as.numeric(cid))

    # AIC weights table (freq): model_name, aic, delta_aic, weight, converged
    aic_w <- if (!is_bayes) sel$weights else NULL

    for (m in names(ens)) {
      e   <- ens[[m]]
      asm <- .get_assessment(cr, m)

      sscore <- if (is_bayes) {
        if (!is.null(loo_info)) .na(loo_info$elpd_loo[loo_info$model_name == m]) else NA_real_
      } else if (is.data.frame(aic_w)) .na(aic_w$aic[aic_w$model_name == m]) else NA_real_

      swt <- if (is_bayes) {
        if (!is.null(loo_info)) .na(loo_info$weight[loo_info$model_name == m]) else NA_real_
      } else if (is.data.frame(aic_w)) .na(aic_w$weight[aic_w$model_name == m]) else NA_real_

      fit_rows[[length(fit_rows)+1L]] <- data.frame(
        curve_id = cid_i, method = method, model_name = m,
        package = pkg, version = ver,
        converged = isTRUE(e$converged),
        eligible  = tryCatch(isTRUE(asm$eligible), error = function(z) NA),
        is_best   = identical(m, best),
        is_fallback = isTRUE(sel$fallback),
        criterion = sel$criterion %||% NA_character_,
        score_type = if (is_bayes) "loo_elpd" else "aic",
        selection_score = sscore,
        selection_weight = swt,
        dynamic_range_log10 = .na(asm$dynamic_range_log10),
        n_params = tryCatch(nrow(e$parameters), error = function(z) NA_integer_),
        job_id = job_id, stringsAsFactors = FALSE)

      # parameters (long): freq term/estimate/std_error[/ci]; bayes term/mean/sd/q*
      p <- e$parameters
      if (is.data.frame(p) && nrow(p)) {
        est <- p$estimate %||% p$mean
        se  <- p$std_error %||% p$sd
        param_rows[[length(param_rows)+1L]] <- data.frame(
          curve_id = cid_i, method = method, model_name = m,
          term = as.character(p$term),
          estimate = .col(est, nrow(p)), std_error = .col(se, nrow(p)),
          q_lo  = .col(p[["q2.5"]] %||% p$ci_lower, nrow(p)),
          q_med = .col(p[["q50"]],                 nrow(p)),
          q_hi  = .col(p[["q97.5"]] %||% p$ci_upper, nrow(p)),
          stringsAsFactors = FALSE)
      }

      # gates
      g <- .get_gates(cr, m)
      if (is.data.frame(g) && nrow(g)) {
        gate_rows[[length(gate_rows)+1L]] <- data.frame(
          curve_id = cid_i, method = method, model_name = m,
          gate = as.character(g$gate),
          passed = as.logical(g$passed),
          detail = .col(g$detail, nrow(g), NA_character_),
          stringsAsFactors = FALSE)
      }

      # LOO per model (bayes) — group values replicated onto this curve_id
      if (is_bayes && !is.null(loo_info) && m %in% loo_info$model_name) {
        r <- loo_info[loo_info$model_name == m, , drop = FALSE][1, ]
        loo_rows[[length(loo_rows)+1L]] <- data.frame(
          curve_id = cid_i, method = "bayesian", model_name = m,
          elpd_loo = .na(r$elpd_loo), se_elpd_loo = .na(r$se_elpd_loo),
          p_loo = .na(r$p_loo), looic = .na(r$looic),
          elpd_diff = .na(r$elpd_diff), se_diff = .na(r$se_diff),
          pareto_k_good = .int(r$pareto_k_good), pareto_k_ok = .int(r$pareto_k_ok),
          pareto_k_bad = .int(r$pareto_k_bad), pareto_k_vbad = .int(r$pareto_k_vbad),
          job_id = job_id, stringsAsFactors = FALSE)
      }
    }

    # grid (best model)
    gd <- cr$grid
    if (is.data.frame(gd) && nrow(gd)) {
      grid_rows[[length(grid_rows)+1L]] <- data.frame(
        curve_id = cid_i, method = method, point_index = seq_len(nrow(gd)),
        model_name = best,
        log10_concentration = .col(gd$log10_concentration, nrow(gd)),
        concentration       = .col(gd$concentration, nrow(gd)),
        predicted_response  = .col(gd$predicted_response, nrow(gd)),
        ci_lower = .col(gd$ci_lower, nrow(gd)), ci_upper = .col(gd$ci_upper, nrow(gd)),
        predicted_concentration = .col(gd$predicted_concentration, nrow(gd)),
        se_concentration = .col(gd$se_concentration, nrow(gd)),
        pcov = .col(gd$pcov, nrow(gd)), pcov_rmse = .col(gd$pcov_rmse, nrow(gd)),
        pcov_pass = .col(gd$pcov_pass, nrow(gd), NA),
        d2y_dx2 = .col(gd$d2y_dx2, nrow(gd)),
        noise_mode = .col(gd$noise_mode, nrow(gd), NA_character_),
        job_id = job_id, stringsAsFactors = FALSE)
    }

    # samples (may be NULL / 0 rows). Identity cols are NOT NULL in the DB, so
    # coalesce missing identity to '__none__', then drop rows identical across the
    # full identity key (they'd violate the PK; real samples have distinct ids).
    sm <- cr$samples
    if (is.data.frame(sm) && nrow(sm)) {
      n <- nrow(sm)
      srow <- data.frame(
        curve_id = cid_i, method = method,
        sampleid   = .id(sm$sampleid,   n),
        patientid  = .id(sm$patientid,  n),
        timeperiod = .id(sm$timeperiod, n),
        dilution   = .id(sm$dilution,   n),
        predicted_concentration = .col(sm$predicted_concentration, n),
        final_concentration     = .col(sm$final_concentration, n),
        se_concentration = .col(sm$se_concentration, n),
        pcov = .col(sm$pcov, n), pcov_rmse = .col(sm$pcov_rmse, n),
        pcov_pass = .col(sm$pcov_pass, n, NA),
        job_id = job_id, stringsAsFactors = FALSE)
      dup <- duplicated(srow[, c("sampleid","patientid","timeperiod","dilution")])
      if (any(dup))
        message(sprintf("  [flatten] curve %s: dropped %d sample row(s) with duplicate identity key",
                        cid, sum(dup)))
      samp_rows[[length(samp_rows)+1L]] <- srow[!dup, , drop = FALSE]
    }

    # diagnostics (one row per curve). LLOQ/ULOQ + shape-LOQ live on the BEST
    # model's per-curve eligibility (not $diagnostics, which this curveR build
    # leaves unset). Inflection is derived from the grid as a point estimate;
    # curveR does not yet emit a posterior inflection CI (see note at EOF).
    dl   <- cr$detection_limits %||% list()
    eb   <- cr$ensemble[[best]]$eligibility %||% .get_assessment(cr, best) %||% list()
    infl <- .infl_from_grid(cr$grid)
    diag_rows[[length(diag_rows)+1L]] <- data.frame(
      curve_id = cid_i, method = method, model_name = best,
      lloq_log10 = .na(eb$lloq), uloq_log10 = .na(eb$uloq),
      lloq_conc  = .pow10(eb$lloq), uloq_conc = .pow10(eb$uloq),
      shape_lloq_log10 = .na(eb$shape_lloq_log10), shape_uloq_log10 = .na(eb$shape_uloq_log10),
      shape_lloq_conc  = .na(eb$shape_lloq_conc),  shape_uloq_conc  = .na(eb$shape_uloq_conc),
      inflect_x = .na(infl$x), inflect_y = .na(infl$y),
      inflect_x_lower = NA_real_, inflect_x_upper = NA_real_,  # await curveR posterior inflection CI
      lower_lod_response = .na(dl$lods$lower_lod_response),
      upper_lod_response = .na(dl$lods$upper_lod_response),
      lower_lod_log10_conc = .na(dl$lods$lower_lod_log10_conc),
      upper_lod_log10_conc = .na(dl$lods$upper_lod_log10_conc),
      lower_lod_conc = .na(dl$lods$lower_lod_conc),
      upper_lod_conc = .na(dl$lods$upper_lod_conc),
      mdc_lower_log10 = .na(dl$mdc_rdl$mdc_lower_log10),
      mdc_upper_log10 = .na(dl$mdc_rdl$mdc_upper_log10),
      mdc_lower_conc  = .na(dl$mdc_rdl$mdc_lower_conc),
      mdc_upper_conc  = .na(dl$mdc_rdl$mdc_upper_conc),
      rdl_lower_log10 = .na(dl$mdc_rdl$rdl_lower_log10),
      rdl_upper_log10 = .na(dl$mdc_rdl$rdl_upper_log10),
      rdl_lower_conc  = .na(dl$mdc_rdl$rdl_lower_conc),
      rdl_upper_conc  = .na(dl$mdc_rdl$rdl_upper_conc),
      pcov_threshold = .na(cr$meta$pcov_threshold),
      cv_x_max = .na(cr$meta$cv_x_max),
      alpha = .na(dl$alpha),
      job_id = job_id, stringsAsFactors = FALSE)
  }

  bind <- function(x) if (length(x)) do.call(rbind, x) else NULL
  run <- data.frame(
    job_id = job_id, method = method,
    package = if (inherits(mp,"calibration_result_multiplate")) mp$meta$package %||% NA else NA,
    version = NA_character_,
    best_model = if (inherits(mp,"calibration_result_multiplate")) mp$meta$best_model %||% NA else NA,
    params = .meta_json(mp), status = "completed",
    stringsAsFactors = FALSE)

  list(run = run, fit = bind(fit_rows), param = bind(param_rows),
       gate = bind(gate_rows), grid = bind(grid_rows), samples = bind(samp_rows),
       diagnostics = bind(diag_rows), loo = bind(loo_rows),
       method = method,
       curve_ids = unique(vapply(names(plates), function(x) suppressWarnings(as.numeric(x)), numeric(1))))
}

# recycle-safe column extractor
.col <- function(x, n, default = NA_real_, cast = identity) {
  if (is.null(x) || length(x) == 0) return(rep(cast(default), n))
  if (length(x) == 1L) return(rep(cast(x), n))
  cast(x)
}
# identity column: coerce to character, map NA/empty to the '__none__' sentinel.
# calib_samples identity cols are NOT NULL (default '__none__'), and an explicit
# NULL from dbAppendTable bypasses the default — so we must supply the sentinel.
.id <- function(x, n) {
  v <- .col(x, n, "__none__", as.character)
  v[is.na(v) | !nzchar(v)] <- "__none__"
  v
}
.int   <- function(x) if (is.null(x)||length(x)==0) NA_integer_ else as.integer(x)[1]
.pow10 <- function(x) { v <- .na(x); if (is.na(v)) NA_real_ else 10^v }

# inflection point estimate from the best-model grid: the steepest point of a
# monotone sigmoid is where curvature (d2y_dx2) crosses zero, approximated by
# the grid row of minimum |d2y_dx2|. Point estimate only; CI needs the posterior.
.infl_from_grid <- function(gd) {
  if (!is.data.frame(gd) ||
      !all(c("d2y_dx2","log10_concentration","predicted_response") %in% names(gd)))
    return(list(x = NA_real_, y = NA_real_))
  ok <- is.finite(gd$d2y_dx2) & is.finite(gd$log10_concentration)
  if (!any(ok)) return(list(x = NA_real_, y = NA_real_))
  i <- which(ok)[which.min(abs(gd$d2y_dx2[ok]))]
  list(x = gd$log10_concentration[i], y = gd$predicted_response[i])
}

# pooled LOO -> per-model table (bayes). Location confirmed: mp$meta$selection
# carries loo_comparison (a loo_compare matrix) and loo_weights (unnamed numeric
# in ensemble/fit order). loo_results is NOT persisted by this curveR build, so
# pareto-k counts stay NA unless curveRbayes is changed to keep loo_results
# (one line: `eligible_selection$loo_results <- loo_selection$loo_results`).
.loo_table <- function(mp) {
  sel <- tryCatch(mp$meta$selection, error = function(e) NULL)
  if (is.null(sel) || is.null(sel$loo_comparison)) return(NULL)
  comp <- as.data.frame(sel$loo_comparison, stringsAsFactors = FALSE)
  ens  <- tryCatch(names(mp$plates[[1]]$ensemble), error = function(e) NULL)

  # Model identity: rownames if they name the models, else a column whose values
  # match the ensemble names (installed curveRbayes returns a compare.loo
  # data.frame that may carry the model id in a column, not rownames).
  mn <- rownames(comp)
  if (is.null(mn) || !length(mn) || (!is.null(ens) && !any(mn %in% ens))) {
    chr <- names(comp)[vapply(comp, function(x) is.character(x) || is.factor(x), logical(1))]
    for (cc in chr)
      if (!is.null(ens) && any(as.character(comp[[cc]]) %in% ens)) { mn <- as.character(comp[[cc]]); break }
  }
  comp$model_name <- mn
  getc <- function(nm) if (nm %in% names(comp)) comp[[nm]] else rep(NA_real_, nrow(comp))

  # weights: align by name; else by matching length to the comparison rows;
  # else leave NA rather than mis-assign (installed build may return a length
  # that doesn't match the model count).
  wts  <- sel$loo_weights
  wvec <- stats::setNames(rep(NA_real_, nrow(comp)), comp$model_name)
  if (!is.null(wts) && length(wts)) {
    if (!is.null(names(wts)) && any(names(wts) %in% comp$model_name)) {
      hit <- intersect(names(wts), comp$model_name); wvec[hit] <- wts[hit]
    } else if (length(wts) == nrow(comp) && !is.null(ens)) {
      names(wts) <- ens[seq_len(nrow(comp))]
      hit <- intersect(names(wts), comp$model_name); wvec[hit] <- wts[hit]
    }
  }

  res <- sel$loo_results   # NULL in current build -> pareto-k NA
  pk <- function(m) {
    k <- tryCatch(res[[m]]$diagnostics$pareto_k, error = function(e) NULL)
    if (is.null(k)) return(c(NA_integer_, NA_integer_, NA_integer_, NA_integer_))
    c(sum(k < .5), sum(k >= .5 & k < .7), sum(k >= .7 & k < 1), sum(k >= 1))
  }
  pkm <- t(vapply(comp$model_name, pk, numeric(4)))
  data.frame(
    model_name = comp$model_name,
    elpd_loo = getc("elpd_loo"), se_elpd_loo = getc("se_elpd_loo"),
    p_loo = getc("p_loo"), looic = getc("looic"),
    elpd_diff = getc("elpd_diff"), se_diff = getc("se_diff"),
    pareto_k_good = pkm[,1], pareto_k_ok = pkm[,2],
    pareto_k_bad = pkm[,3], pareto_k_vbad = pkm[,4],
    weight = wvec[comp$model_name],
    stringsAsFactors = FALSE)
}

.meta_json <- function(mp) {
  m <- tryCatch(if (inherits(mp,"calibration_result_multiplate")) mp$meta else mp$meta,
                error = function(e) list())
  keep <- m[intersect(names(m),
    c("chains","warmup","sampling","adapt_delta","seed","pcov_threshold",
      "use_heteroscedastic_noise","n_draws_predict","n_draws_ensemble"))]
  tryCatch(jsonlite::toJSON(keep, auto_unbox = TRUE, null = "null"),
           error = function(e) NA_character_)
}


# ── SAVE (idempotent, curve_id-keyed, one transaction) ───────────────────────
save_calib <- function(conn, flat, schema = "madi_results", verbose = TRUE) {
  method <- flat$method
  ids    <- flat$curve_ids[is.finite(flat$curve_ids)]
  if (!length(ids)) { warning("no curve_ids to save"); return(invisible(NULL)) }
  id_list <- paste(ids, collapse = ",")
  mq <- DBI::dbQuoteLiteral(conn, method)

  DBI::dbBegin(conn)
  ok <- tryCatch({
    # run provenance (job-level upsert)
    if (!is.null(flat$run)) .upsert_run(conn, schema, flat$run)

    # clear prior rows for these curves+method. Deleting calib_fit cascades to
    # param/gate/loo; grid/samples/diagnostics reference curve_lookup so delete
    # them explicitly.
    for (t in c("calib_grid","calib_samples","calib_diagnostics","calib_fit")) {
      DBI::dbExecute(conn, sprintf(
        "DELETE FROM %s.%s WHERE method = %s AND curve_id IN (%s)",
        schema, t, mq, id_list))
    }

    # insert in FK order: parents (fit) before children (param/gate/loo);
    # grid/samples/diagnostics any time after nothing depends on them.
    .append(conn, schema, "calib_fit",         flat$fit)
    .append(conn, schema, "calib_param",       flat$param)
    .append(conn, schema, "calib_gate",        flat$gate)
    .append(conn, schema, "calib_loo",         flat$loo)
    .append(conn, schema, "calib_grid",        flat$grid)
    .append(conn, schema, "calib_samples",     flat$samples)
    .append(conn, schema, "calib_diagnostics", flat$diagnostics)
    TRUE
  }, error = function(e) { DBI::dbRollback(conn); stop("save_calib failed: ",
                                                       conditionMessage(e), call. = FALSE) })
  DBI::dbCommit(conn)

  if (verbose) {
    n <- function(d) if (is.null(d)) 0L else nrow(d)
    message(sprintf("Saved method=%s curves=%d | fit=%d param=%d gate=%d grid=%d samples=%d diag=%d loo=%d",
                    method, length(ids), n(flat$fit), n(flat$param), n(flat$gate),
                    n(flat$grid), n(flat$samples), n(flat$diagnostics), n(flat$loo)))
  }
  invisible(TRUE)
}

# append df, keeping only columns that exist in the target table (robust to
# schema/column drift); no-op on NULL/empty.
.append <- function(conn, schema, table, df) {
  if (is.null(df) || !nrow(df)) return(invisible(0L))
  cols <- DBI::dbGetQuery(conn, sprintf(
    "SELECT column_name FROM information_schema.columns
      WHERE table_schema = %s AND table_name = %s",
    DBI::dbQuoteLiteral(conn, schema), DBI::dbQuoteLiteral(conn, table)))$column_name
  keep <- intersect(names(df), cols)
  DBI::dbAppendTable(conn, DBI::Id(schema = schema, table = table), df[, keep, drop = FALSE])
}

.upsert_run <- function(conn, schema, run) {
  DBI::dbExecute(conn, sprintf(
    "INSERT INTO %s.calib_run (job_id, method, package, version, best_model, params, status, finished_at)
       VALUES (%s, %s, %s, %s, %s, %s::jsonb, %s, now())
     ON CONFLICT (job_id) DO UPDATE SET
       method=EXCLUDED.method, package=EXCLUDED.package, version=EXCLUDED.version,
       best_model=EXCLUDED.best_model, params=EXCLUDED.params,
       status=EXCLUDED.status, finished_at=now()",
    schema,
    DBI::dbQuoteLiteral(conn, run$job_id[1]),
    DBI::dbQuoteLiteral(conn, run$method[1]),
    DBI::dbQuoteLiteral(conn, run$package[1] %||% NA),
    DBI::dbQuoteLiteral(conn, run$version[1] %||% NA),
    DBI::dbQuoteLiteral(conn, run$best_model[1] %||% NA),
    DBI::dbQuoteLiteral(conn, run$params[1] %||% NA),
    DBI::dbQuoteLiteral(conn, run$status[1] %||% "completed")))
}
