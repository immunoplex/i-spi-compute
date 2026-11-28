# Unit tests for the noise model and the response adjustment in the curveR worker
# (no database; Stan only for the Bayesian case, skipped with E2E_SKIP_BAYES=1).
#   Rscript -e 'testthat::test_file("worker/tests/test-noise_model_offset.R")'
# Needs curveRcore >= 0.7.1.9000, curveRfreq >= 0.6.0, curveRbayes >= 0.6.0.
#
# Origin: ELISA project 118 (absorbance; blanks and some samples <= 0). The whole
# per-group pipeline runs through fit_one_group(), with the database calls
# replaced so the flattened rows that would be saved can be inspected.

library(testthat)

here <- normalizePath(file.path(getwd(), if (basename(getwd()) == "tests") ".." else
                                  if (basename(getwd()) == "worker") "." else "worker"))
Sys.setenv(WORKER_SOURCE_ONLY = "1", WORKER_COMPONENTS_DIR = here)
source(file.path(here, "worker_curveR.R"), local = TRUE)   # overrides below must be found

# No database: capture what would be saved.
saved <- NULL
open_conn    <- function() NULL
save_calib   <- function(conn, flat, ...) saved <<- flat
verify_saved <- function(...) list(ok = TRUE)

gid <- "aaaaaaaa-0000-0000-0000-000000000118"
sim_group <- function(n_plates = 4, seed = 118, neg = TRUE) {
  set.seed(seed)
  dil <- 3^(0:9)
  conc <- 1000 / dil
  sg <- do.call(rbind, lapply(seq_len(n_plates), function(p) {
    mu <- 0.05 + (2.8 - 0.05) / (1 + (conc / (8 * 1.1^p))^-1.1)
    data.frame(curve_id = p, multiplate_group_id = gid, antigen = "PT", feature = "IgG",
               stype = "S", sampleid = sprintf("STD_%02d", 1:10), well = sprintf("S%d", 1:10),
               source = "Std1", dilution = dil,
               mfi = mu + rnorm(10, 0, sqrt(0.008^2 + (0.06 * mu)^2)),
               masked = FALSE, stringsAsFactors = FALSE)
  }))
  bg <- do.call(rbind, lapply(seq_len(n_plates), function(p)
    data.frame(curve_id = p, multiplate_group_id = gid, antigen = "PT", feature = "IgG",
               stype = "B", sampleid = "BLANK", well = c("B1", "B2"), source = "Std1",
               dilution = 1, mfi = c(-0.02, 0.01), masked = FALSE, stringsAsFactors = FALSE)))
  smg <- do.call(rbind, lapply(seq_len(n_plates), function(p)
    data.frame(curve_id = p, multiplate_group_id = gid, antigen = "PT", feature = "IgG",
               stype = "X", sampleid = sprintf("s%d_%d", p, 1:4), well = sprintf("X%d", 1:4),
               patientid = sprintf("P%d", 1:4), timeperiod = "t1", agroup = "A",
               dilution = 1, mfi = c(if (neg) -0.003 else 0.03, 0.2, 0.9, 2.2),
               stringsAsFactors = FALSE)))
  cg <- do.call(rbind, lapply(seq_len(n_plates), function(p)
    data.frame(curve_id = p, well = c("C1", "C2", "C3"), sampleid = c("NC", "PC", "NCm"),
               control_source = "Ctl", dilution = 1,
               mfi = c(if (neg) -0.005 else 0.04, 1.4, -0.5),
               masked = c(FALSE, FALSE, TRUE), mask_reason = c(NA, NA, "manual"),
               stringsAsFactors = FALSE)))
  list(sg = sg, bg = bg, smg = smg, cg = cg)
}
bundle <- function(d, noise_model, bo = "ignored", is_log = TRUE) list(
  gid = gid, sg = d$sg, bg = d$bg, smg = d$smg, cg = d$cg, antigen = "PT", feature = "IgG",
  n_grp = length(unique(d$sg$curve_id)), tag = "test-group",
  study_params = list(is_log_response = is_log, is_log_independent = TRUE, apply_prozone = FALSE),
  models = c("logistic4", "gompertz4"), pcov_th = 20, inc_me = TRUE, decision_cutoff = NULL,
  n_interval_draws = 200L, b_chains = 2L, b_warmup = 300L, b_samp = 300L, b_adapt = 0.9,
  persist_draws = TRUE, bayes_single_plate = FALSE, sc = 1000, bo = bo,
  noise_model = noise_model)
run_group <- function(gb, method = "frequentist") {
  saved <<- NULL
  r <- fit_one_group(gb, method, identical(method, "bayesian"), seed = 7L, job_id = "t", per_fit = 1L)
  if (!is.null(r$fail)) stop(r$fail$msg)
  saved
}
meta_of <- function(flat) jsonlite::fromJSON(flat$run$params[1], simplifyVector = TRUE)

test_that("noise_model vocabulary falls back to constant", {
  expect_identical(.valid_noise_model("add_prop"), "add_prop")
  expect_identical(.valid_noise_model(" ADD_PROP "), "add_prop")
  expect_identical(.valid_noise_model("power"), "constant")
  expect_identical(.valid_noise_model(NULL), "constant")
})

test_that("the group offset is decided by standards, controls and samples, never blanks", {
  d <- sim_group()
  adj <- group_response_adjustment(d$sg, d$bg, d$smg, d$cg, is_log_response = TRUE,
                                   blank_option = "ignored")
  # lowest included value is the negative control (-0.005); the masked control
  # (-0.5) and the blanks (-0.02) do not count
  expect_equal(adj$offset, 0.005 + 0.001)
  expect_equal(adj$blank_value, 0)
  # nothing <= 0 among calibrators/controls/samples: no adjustment
  d2 <- sim_group(neg = FALSE)
  adj2 <- group_response_adjustment(d2$sg, d2$bg, d2$smg, d2$cg, TRUE, "ignored")
  expect_equal(adj2$offset, 0)
  # linear response: never an offset
  expect_equal(group_response_adjustment(d$sg, d$bg, d$smg, d$cg, FALSE, "ignored")$offset, 0)
  # subtraction uses the arithmetic blank mean when a blank is <= 0, and also
  # moves the controls and samples
  adj3 <- group_response_adjustment(d$sg, d$bg, d$smg, d$cg, TRUE, "subtracted")
  expect_equal(adj3$blank_value, mean(c(-0.02, 0.01)))
})

test_that("frequentist add_prop: pooled terms, adjustment recorded, controls on the fit's axis", {
  flat <- run_group(bundle(sim_group(), "add_prop"))
  m <- meta_of(flat)
  expect_identical(m$noise_model, "add_prop")
  expect_equal(m$response_offset, 0.006)
  expect_equal(m$response_adjustment$offset, 0.006)
  expect_true(all(c("cv", "sigma_add") %in% names(m$noise_params)))
  best <- flat$param[flat$param$model_name %in% flat$fit$model_name[flat$fit$is_best], ]
  expect_true(all(c("sigma_add", "cv") %in% best$term))
  expect_false("sigma_resid" %in% best$term)
  # controls: raw - 0 + offset, then log10; the masked -0.5 is floored, kept
  ct <- flat$controls
  expect_true(nrow(ct) > 0)
  nc <- ct[ct$sampleid == "NC", ]
  expect_equal(nc$response_model, rep(log10(-0.005 + 0.006), nrow(nc)))
  expect_true(all(is.finite(ct$response_model)))
  expect_true(all(ct$included[ct$sampleid == "NCm"] == FALSE))
  pc <- ct[ct$sampleid == "PC", ]
  expect_true(all(is.finite(pc$predicted_log10_concentration)))
  # every sample is kept, the negative one included (the engines apply the
  # same adjustment; their own tests check the transformed response)
  expect_equal(nrow(flat$samples), 16L)
  # standard point estimates were filled
  expect_true(any(is.finite(flat$standards$predicted_log10_concentration)))
  # the backfill path (adjustment read back from calib_run.params) gives the
  # same controls as the worker path (adjustment passed in)
  again <- pe_attach(flat, sim_group()$cg, is_log_response = TRUE, is_log_independent = TRUE,
                     include_measurement_error = TRUE, job_id = "t")
  expect_equal(again$controls$predicted_log10_concentration, ct$predicted_log10_concentration)
  expect_equal(again$controls$response_model, ct$response_model)
})

test_that("frequentist constant noise with nothing <= 0 is the pre-0.6.0 path", {
  d <- sim_group(neg = FALSE)
  flat <- run_group(bundle(d, "constant"))
  m <- meta_of(flat)
  expect_identical(m$noise_model, "constant")
  expect_equal(m$response_offset, 0)
  best <- flat$param[flat$param$model_name %in% flat$fit$model_name[flat$fit$is_best], ]
  expect_true("sigma_resid" %in% best$term)
  ct <- flat$controls[!duplicated(flat$controls$well) & flat$controls$curve_id == 1, ]
  raw <- d$cg$mfi[d$cg$curve_id == 1]
  # legacy transform: log10, values <= 0 floored (masked well only)
  expect_equal(ct$response_model[ct$sampleid != "NCm"], log10(raw[d$cg$sampleid[d$cg$curve_id == 1] != "NCm"]))
})

test_that("standards' log scale is still recognised when an offset was added", {
  std <- data.frame(response_model = log10(c(-0.002, 0.1, 1) + 0.003),
                    assay_response_raw = c(-0.002, 0.1, 1))
  expect_true(pe_is_log_response(std, FALSE, list(blank_value = 0, offset = 0.003)))
  expect_false(pe_is_log_response(data.frame(response_model = c(0.1, 1, 2),
                                             assay_response_raw = c(0.1, 1, 2)), TRUE, NULL))
})

test_that("bayesian add_prop: noise terms persisted, controls estimated with add_prop noise", {
  skip_if(identical(Sys.getenv("E2E_SKIP_BAYES"), "1"), "E2E_SKIP_BAYES=1")
  skip_if_not(nzchar(tryCatch(cmdstanr::cmdstan_path(), error = function(e) "")), "no CmdStan")
  flat <- run_group(bundle(sim_group(), "add_prop"), method = "bayesian")
  m <- meta_of(flat)
  expect_identical(m$noise_model, "add_prop")
  expect_equal(m$response_offset, 0.006)
  pop <- flat$hyperparam[flat$hyperparam$param_scope == "population", ]
  expect_true(all(c("sigma_add", "cv") %in% pop$term))
  expect_false("sigma_obs" %in% pop$term)
  # draws keep sigma_obs (prior-only) so noise draws stay aligned
  expect_true(all(c("sigma_obs", "nu", "sigma_add", "cv") %in% flat$draws$term))
  ct <- flat$controls
  expect_equal(ct$response_model[ct$sampleid == "NC"][1], log10(0.001))
  pc <- ct[ct$sampleid == "PC", ]
  expect_true(all(is.finite(pc$predicted_log10_concentration)))
})
