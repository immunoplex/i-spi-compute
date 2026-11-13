# Unit tests for worker_weights.R (no database, no Stan).
#   Rscript -e 'testthat::test_file("worker/tests/test-worker_weights.R")'
# Needs curveRweights >= 0.3.0 and curveRcore >= 0.6.0 installed.

library(testthat)

here <- normalizePath(file.path(getwd(), if (basename(getwd()) == "tests") ".." else
                                  if (basename(getwd()) == "worker") "." else "worker"))
Sys.setenv(WORKER_SOURCE_ONLY = "1", WORKER_COMPONENTS_DIR = here)
source(file.path(here, "worker_weights.R"))

sg <- function() data.frame(
  .obs_id = 1:4, patientid = c("p1", "p2", "p3", "p4"),
  timeperiod = c("t1", "t1", "t2", "t2"), dilution = "2000",
  agroup = c("A", "A", "B", "B"), stringsAsFactors = FALSE)

gb <- list(gid = "11111111-1111-1111-1111-111111111111", antigen = "prn", feature = "IgG1")

fake_mult <- function() list(
  weights = data.frame(obs_id = 1:4, sampleid = c("a", "b", "c", "d"),
                       curve_id = c("1", "1", "2", "2"), se = c(.1, .2, .1, .3),
                       pcov = NA_real_, sigma = c(.2, .4, .2, .6),
                       w = c(25, 6.25, 25, 2.78), w_norm = c(1.5, .4, 1.5, .2),
                       stringsAsFactors = FALSE),
  estimates = list(model = "multiplicative", phi = 1.1, phi_CI = c(lo = .9, hi = 1.3),
                   beta1 = .9, beta1_CI = c(lo = .6, hi = 1.2),
                   interpretation = "moderate precision weighting",
                   diagnostics = list(n_fit = 4L, weight = list(n_eff = 3.5, weight_ratio = 9))))

fake_add <- function() {
  pw <- fake_mult()
  pw$weights$v_meas <- c(.01, .04, .01, .09); pw$weights$tau2 <- .09
  pw$weights$reliability <- c(.9, .69, .9, .5)
  pw$weights$reliability_lo <- pw$weights$reliability - .05
  pw$weights$reliability_hi <- pw$weights$reliability + .05
  pw$weights$censor_type <- c("none", "none", "none", "left")
  pw$weights$bound <- c(NA, NA, NA, .3)
  pw$weights$w_norm[4] <- NA_real_
  pw$weights$w[2] <- Inf                       # must become NULL, not Infinity
  pw$estimates <- list(
    model = "additive", tau = .3, tau2 = .09, kappa = 1.02, beta1 = 1,
    tau_CI = c(lo = .25, hi = .36), kappa_CI = c(lo = .6, hi = 1.6),
    beta1_CI = c(lo = NA_real_, hi = NA_real_), reliability = .8,
    reliability_CI = c(lo = .7, hi = .88),
    interpretation = "kappa identified from the data",
    diagnostics = list(n_fit = 4L, fix_beta1 = TRUE,
                       n_by_censoring = list(quantified = 3L, left = 1L, right = 0L, interval = 0L),
                       weight = list(n_eff = 2.9, weight_ratio = 4)))
  pw
}

test_that("CLI: model defaults to multiplicative and fix_beta1 to true", {
  P <- parse_args(c("--method", "bayesian", "--design", "timeperiod"))
  expect_equal(P$model, "multiplicative")
  expect_equal(P$fix_beta1, "true")
  P2 <- parse_args(c("--method", "bayesian", "--model", "additive", "--fix_beta1", "false"))
  expect_equal(P2$model, "additive"); expect_equal(P2$fix_beta1, "false")
})

test_that("multiplicative rows keep the 0.2.x shape (+ model, version) and validate", {
  w <- build_weight_rows(fake_mult(), sg(), "frequentist", "job1", "multiplicative")
  expect_equal(names(w), c("curve_id", "method", "sampleid", "patientid", "timeperiod",
                           "dilution", "agroup", "se", "pcov", "sigma", "w", "w_norm",
                           "job_id", "model", "weights_pkg_version"))
  expect_equal(unique(w$model), "multiplicative")
  expect_type(w$curve_id, "integer")
  expect_equal(nrow(w), 4L)
  f <- build_fit_row(fake_mult(), gb, c("timeperiod", "agroup"), "se", "job1",
                     "frequentist", "multiplicative")
  expect_equal(names(f), c("multiplate_group_id", "method", "antigen", "feature",
                           "design_cols", "scale_predictor", "phi", "phi_lo", "phi_hi",
                           "beta1", "beta1_lo", "beta1_hi", "interpretation", "n_fit",
                           "n_eff", "weight_ratio", "job_id", "model", "weights_pkg_version"))
  expect_equal(f$design_cols, "timeperiod,agroup")
  expect_silent(.validate_weight_rows(w, f, "multiplicative"))
  # the columns the additive model owns are absent, i.e. NULL in the DB
  expect_false(any(c("tau", "kappa", "reliability", "v_meas") %in% c(names(w), names(f))))
})

test_that("additive rows carry the new concepts and validate", {
  w <- build_weight_rows(fake_add(), sg(), "bayesian", "job2", "additive")
  expect_true(all(c("v_meas", "tau2", "reliability", "reliability_lo", "reliability_hi",
                    "censor_type", "bound", "model") %in% names(w)))
  expect_equal(unique(w$model), "additive")
  expect_true(is.na(w$w[2]))                     # Inf -> NULL
  expect_true(is.na(w$w_norm[4]))                # censored row: no weight
  expect_equal(w$censor_type[4], "left")
  f <- build_fit_row(fake_add(), gb, c("timeperiod", "agroup"), "se", "job2",
                     "bayesian", "additive")
  expect_equal(f$scale_predictor, "se")
  expect_false("phi" %in% names(f))              # phi does not exist in this model
  expect_equal(f$tau, .3); expect_equal(f$kappa, 1.02)
  expect_true(f$fix_beta1); expect_equal(f$beta1, 1)
  expect_true(is.na(f$beta1_lo))
  expect_equal(f$n_censored, 1L)
  expect_equal(f$identifiability, "kappa identified from the data")
  expect_silent(.validate_weight_rows(w, f, "additive"))
})

test_that("rows from one model are rejected as the other", {
  w <- build_weight_rows(fake_add(), sg(), "bayesian", "job2", "additive")
  f <- build_fit_row(fake_add(), gb, "timeperiod", "se", "job2", "bayesian", "additive")
  expect_error(.validate_weight_rows(w, f, "multiplicative"), "belongs to the additive")
})

test_that("rows rejoin to calib_samples identity by obs_id regardless of row order", {
  pw <- fake_mult(); pw$weights <- pw$weights[4:1, ]
  w <- build_weight_rows(pw, sg(), "frequentist", "j", "multiplicative")
  expect_equal(w$patientid[w$sampleid == "a"], "p1")
  expect_equal(w$agroup[w$sampleid == "d"], "B")
})
