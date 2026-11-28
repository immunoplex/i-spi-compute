# =============================================================================
# point_estimates.R -- back-calculated estimates for a curve's standard points
# (calib_standards estimate columns) and control wells (calib_controls), from a
# stored or just-flattened fit. curveRcore >= 0.7.0 contract.
#
# ONE implementation, two callers:
#   * worker_curveR.R: right after each fit, from the in-memory flattened rows
#     (pe_attach), written in the same transaction as the fit;
#   * backfill_point_estimates.R: once, for curves fitted before 0.7.0, from the
#     rows read back from the database.
# Both build the same input list `L` (the shape of the stored tables) and call
# pe_compute_one(), which calls curveRcore::estimate_points_from_stored(), so a
# new curve and a backfilled curve get identical calculations.
#
# `L` is a list of data frames, each keyed by curve_id (and method where the
# stored table has it):
#   params      curve_id, method, term, estimate             best model only
#   grid        curve_id, method, log10_concentration, concentration, se_concentration
#   diag        calib_diagnostics row(s)
#   draws       curve_id, method, term, param_scope, draws (list column)
#   noise_model curve_id, method, noise_model ("constant" | "add_prop"; NA =
#               constant, e.g. fits from before curveR 0.6.0)
#   adjustment  curve_id, method, blank_value, offset, response_floor -- the
#               response adjustment of the fit (calib_run.params
#               response_adjustment); absent/NA = none (pre-0.6.0 fits)
#   x_scale     curve_id, method, log_x
#   settings    curve_id, param_name, value_text
#   standards   calib_standards rows (response_model, nominal concentration, ...)
#   controls    control_for_fit rows (well, sampleid, control_source, dilution,
#               mfi, masked, mask_reason)
# Helper names carry a pe_ prefix so this file can be sourced beside the worker's
# own helpers without replacing them.
# =============================================================================

pe_as_bool <- function(x, default) {
  x <- if (is.null(x) || !length(x)) NA_character_ else tolower(trimws(as.character(x)))
  if (is.na(x[1])) default else x[1] %in% c("true", "t", "1", "yes")
}

pe_num1 <- function(x, default) {
  v <- suppressWarnings(as.numeric(x))
  if (length(v) && is.finite(v[1])) v[1] else default
}

# The fit's response adjustment for one curve (row of L$adjustment), or NULL.
pe_adjustment <- function(a) {
  if (!is.data.frame(a) || !nrow(a)) return(NULL)
  out <- list(blank_value = pe_num1(a$blank_value, 0), offset = pe_num1(a$offset, 0),
              response_floor = pe_num1(a$response_floor, NA_real_))
  if (!is.finite(out$response_floor)) out$response_floor <- NULL
  out
}

pe_available <- function()
  requireNamespace("curveRcore", quietly = TRUE) &&
    "estimate_points_from_stored" %in% getNamespaceExports("curveRcore")

# Population draws the observation model needs (both noise models).
pe_noise_terms <- function() c("sigma_obs", "nu", "sigma_add", "cv")

pe_est_cols <- function() curveRcore::point_estimates_contract("standards", estimates_only = TRUE)$column

# Response scale of a curve: inferred from its standards (response_model vs the
# raw response, after the fit's blank subtraction and offset) when unambiguous,
# else the resolved setting.
pe_is_log_response <- function(std, setting, adj = NULL) {
  if (!is.data.frame(std) || !nrow(std)) return(setting)
  rm <- suppressWarnings(as.numeric(std$response_model))
  raw <- suppressWarnings(as.numeric(std$assay_response_raw))
  bv <- pe_num1(adj$blank_value, 0)
  raw_lin <- raw - bv
  raw <- raw_lin + pe_num1(adj$offset, 0)
  ok <- is.finite(rm) & is.finite(raw) & raw > 0
  if (sum(ok) >= 2L) {
    d_log <- stats::median(abs(rm[ok] - log10(raw[ok])))
    d_lin <- stats::median(abs(rm[ok] - raw_lin[ok]))
    if (d_log < 1e-6) return(TRUE)
    if (d_lin < 1e-6) return(FALSE)
  }
  setting
}

# Back-calculate one (curve, method). Returns list(standards, controls, sources),
# or NULL when the curve has no stored parameters or diagnostics.
pe_compute_one <- function(L, cid, method, model_name, job_id) {
  cid <- as.numeric(cid)
  sel <- function(d) {
    if (!is.data.frame(d) || !nrow(d)) return(d)
    keep <- as.numeric(d$curve_id) == cid
    if ("method" %in% names(d)) keep <- keep & d$method == method
    d[keep, , drop = FALSE]
  }
  pr <- sel(L$params)
  params <- if (is.data.frame(pr) && nrow(pr)) stats::setNames(as.numeric(pr$estimate), pr$term) else numeric(0)
  dg <- sel(L$diag)
  if (!length(params) || !is.data.frame(dg) || !nrow(dg)) return(NULL)
  dg <- dg[1, ]
  st <- sel(L$settings)
  sv <- function(nm, default)
    pe_as_bool(if (is.data.frame(st) && nrow(st)) st$value_text[st$param_name == nm] else NULL, default)

  # Points in a fixed order (well, dilution): Bayesian measurement noise is drawn
  # in sequence, so the order -- not where the rows came from (database or
  # memory) -- must decide which noise draw each point gets.
  std <- sel(L$standards)
  if (is.data.frame(std) && nrow(std))
    std <- std[order(as.character(std$well), as.numeric(std$dilution)), , drop = FALSE]
  xs <- sel(L$x_scale)
  log_x <- if (is.data.frame(xs) && nrow(xs) && !is.na(xs$log_x[1])) isTRUE(as.logical(xs$log_x[1]))
           else sv("is_log_independent", TRUE)
  adj <- pe_adjustment(sel(L$adjustment))
  log_y <- pe_is_log_response(std, sv("is_log_response", TRUE), adj)

  dr <- sel(L$draws)
  has_dr <- is.data.frame(dr) && nrow(dr)
  curve_draws <- if (has_dr) {
    d <- dr[dr$param_scope == "curve", , drop = FALSE]
    if (nrow(d)) stats::setNames(lapply(d$draws, as.numeric), d$term) else NULL
  } else NULL
  # a fixed lower asymptote is stored as a one-element 'a' draw (sample_kind 'fixed')
  fixed_a <- NULL
  if (!"a" %in% names(params) && length(curve_draws$a) == 1L) fixed_a <- curve_draws$a
  noise <- NULL
  if (method == "bayesian" && has_dr && sv("include_measurement_error", TRUE)) {
    pop <- dr[dr$param_scope == "population", , drop = FALSE]
    g <- function(t) if (t %in% pop$term) as.numeric(pop$draws[[match(t, pop$term)]]) else NULL
    nm <- sel(L$noise_model)
    nm <- if (is.data.frame(nm) && nrow(nm)) as.character(nm$noise_model[1]) else NA_character_
    # sigma_obs is drawn under both models (prior-only under add_prop), so its
    # length still aligns the noise with the curve draws.
    if (!is.null(g("sigma_obs")) && !is.null(g("nu")))
      noise <- list(sigma_obs = g("sigma_obs"), nu = g("nu"),
                    noise_model = if (identical(nm, "add_prop")) "add_prop" else "constant",
                    sigma_add = g("sigma_add"), cv = g("cv"))
  }
  lim_cols <- c("lloq_log10", "uloq_log10", "lower_lod_response", "upper_lod_response",
                "lower_lod_log10_conc", "upper_lod_log10_conc", "inflect_x")
  limits <- lapply(stats::setNames(lim_cols, lim_cols), function(k)
    if (k %in% names(dg)) suppressWarnings(as.numeric(dg[[k]])) else NA_real_)
  num <- function(k, d) {
    v <- if (k %in% names(dg)) suppressWarnings(as.numeric(dg[[k]])) else NA_real_
    if (length(v) && is.finite(v)) v else d
  }
  est <- function(response, dilution, nominal = NULL, seed)
    curveRcore::estimate_points_from_stored(
      response, dilution, model_name, params, method,
      grid = sel(L$grid), limits = limits, draws = curve_draws, fixed_a = fixed_a,
      noise = noise, is_log_independent = log_x, is_log_response = log_y, nominal = nominal,
      cv_x_max = num("cv_x_max", 150), pcov_threshold = num("pcov_threshold", 20),
      decision_cutoff = num("decision_cutoff", NULL), seed = seed)

  out <- list(standards = NULL, controls = NULL, sources = character())
  if (is.data.frame(std) && nrow(std)) {
    nominal <- if (log_x) std$log10_concentration else std$concentration
    e <- est(as.numeric(std$response_model), as.numeric(std$dilution), as.numeric(nominal),
             seed = as.integer(cid %% 2147483647))
    out$sources <- c(out$sources, attr(e, "se_source"))
    # included / exclusion_reason ride along for validation only; not updated
    out$standards <- cbind(std[, c("curve_id", "method", "well", "dilution", "included",
                                   "exclusion_reason")], e)
  }
  ct <- sel(L$controls)
  if (is.data.frame(ct) && nrow(ct)) {
    ct <- ct[!duplicated(ct$well), , drop = FALSE]
    ct <- ct[order(as.character(ct$well)), , drop = FALSE]
    raw <- suppressWarnings(as.numeric(ct$mfi))
    # Same transform as the fit's standards and samples (blank subtraction,
    # offset, floor). Fits without an adjustment keep the legacy 1e-6 floor.
    resp <- if ("transform_sample_response" %in% getNamespaceExports("curveRcore"))
              curveRcore::transform_sample_response(raw, log_y, adj)
            else if (log_y) log10(pmax(raw, 1e-6)) else raw
    dil <- suppressWarnings(as.numeric(ct$dilution)); dil[!is.finite(dil)] <- 1
    e <- est(resp, dil, seed = as.integer((cid + 1) %% 2147483647))
    out$sources <- c(out$sources, attr(e, "se_source"))
    inc <- !(as.logical(ct$masked) %in% TRUE)
    out$controls <- cbind(data.frame(
      curve_id = cid, method = method, well = as.character(ct$well),
      sampleid = as.character(ct$sampleid), source = as.character(ct$control_source),
      dilution = suppressWarnings(as.numeric(ct$dilution)),
      included = inc, exclusion_reason = ifelse(inc, "none", "masked"),
      mask_reason = as.character(ct$mask_reason),
      response_model = resp, assay_response_raw = raw, stringsAsFactors = FALSE), e,
      job_id = job_id)
  }
  out
}

# `L` from the worker's flattened fit (flatten_result() + flatten_calib_points())
# and the group's control_for_fit rows: the same rows save_calib() is about to
# store, so the result equals what the backfill would compute from the database.
pe_L_from_flat <- function(flat, controls, is_log_response, is_log_independent,
                           include_measurement_error, response_adjustment = NULL) {
  fit <- flat$fit
  best <- if (is.data.frame(fit) && nrow(fit)) fit[fit$is_best %in% TRUE, c("curve_id", "method", "model_name")] else NULL
  on_best <- function(d) {
    if (!is.data.frame(d) || !nrow(d) || is.null(best) || !nrow(best)) return(d[0, , drop = FALSE])
    k <- paste(d$curve_id, d$method, d$model_name)
    d[k %in% paste(best$curve_id, best$method, best$model_name), , drop = FALSE]
  }
  ids <- unique(as.numeric(c(flat$curve_ids, flat$standards$curve_id)))
  ids <- ids[is.finite(ids)]
  meta <- tryCatch(jsonlite::fromJSON(flat$run$params[1]), error = function(e) list())
  dr <- on_best(flat$draws)
  # NROW: a Bayesian fit saved without draws (persist_draws = FALSE, the
  # default) has draws = NULL, and nrow(NULL) is NULL, not 0.
  if (NROW(dr)) dr <- dr[dr$param_scope == "curve" |
                         dr$term %in% pe_noise_terms(), , drop = FALSE]
  list(
    best = best,
    params = on_best(flat$param),
    grid = flat$grid,
    diag = flat$diagnostics,
    draws = dr,
    noise_model = data.frame(curve_id = ids, method = rep(flat$method, length(ids)),
                             noise_model = rep(as.character(meta$noise_model %||% NA_character_)[1],
                                               length(ids)),
                             stringsAsFactors = FALSE),
    adjustment = {
      a <- response_adjustment %||% meta$response_adjustment
      data.frame(curve_id = ids, method = rep(flat$method, length(ids)),
                 blank_value = rep(pe_num1(a$blank_value, 0), length(ids)),
                 offset = rep(pe_num1(a$offset, 0), length(ids)),
                 response_floor = rep(pe_num1(a$response_floor, NA_real_), length(ids)))
    },
    x_scale = data.frame(curve_id = ids, method = rep(flat$method, length(ids)),
                         log_x = rep(isTRUE(is_log_independent), length(ids))),
    settings = data.frame(
      curve_id = rep(ids, each = 3L),
      param_name = rep(c("is_log_response", "is_log_independent", "include_measurement_error"), length(ids)),
      value_text = rep(tolower(c(isTRUE(is_log_response), isTRUE(is_log_independent),
                                 isTRUE(include_measurement_error))), length(ids)),
      stringsAsFactors = FALSE),
    standards = flat$standards,
    controls = controls)
}

# Fill the estimate columns of flat$standards and set flat$controls for every
# best fit in `flat`. Curves without a fit (no parameters) keep empty estimates;
# a later backfill run fills them. Returns `flat` with attr "pe_sources".
pe_attach <- function(flat, controls, is_log_response, is_log_independent,
                      include_measurement_error, job_id, response_adjustment = NULL) {
  L <- pe_L_from_flat(flat, controls, is_log_response, is_log_independent, include_measurement_error,
                      response_adjustment)
  if (is.null(L$best) || !nrow(L$best)) return(flat)
  std_out <- list(); ctl_out <- list(); sources <- character()
  for (i in seq_len(nrow(L$best))) {
    r <- pe_compute_one(L, L$best$curve_id[i], L$best$method[i], L$best$model_name[i], job_id)
    if (is.null(r)) next
    std_out[[length(std_out) + 1L]] <- r$standards
    ctl_out[[length(ctl_out) + 1L]] <- r$controls
    sources <- c(sources, r$sources)
  }
  std <- if (length(std_out)) do.call(rbind, std_out) else NULL
  ctl <- if (length(ctl_out)) do.call(rbind, ctl_out) else NULL
  if (is.data.frame(std) && nrow(std)) {
    curveRcore::validate_point_estimates(std, "standards")
    cols <- intersect(pe_est_cols(), names(std))
    key <- function(d) paste(as.numeric(d$curve_id), d$method, d$well, as.numeric(d$dilution), sep = "\r")
    m <- match(key(flat$standards), key(std))
    for (cc in cols) {
      v <- std[[cc]][m]
      flat$standards[[cc]] <- v
    }
  }
  if (is.data.frame(ctl) && nrow(ctl)) {
    curveRcore::validate_point_estimates(ctl, "controls")
    flat$controls <- ctl
  }
  attr(flat, "pe_sources") <- sources
  flat
}
