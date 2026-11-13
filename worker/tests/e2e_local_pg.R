#!/usr/bin/env Rscript
# =============================================================================
# e2e_local_pg.R -- end-to-end test of worker_weights.R against a LOCAL throwaway
# PostgreSQL (never the shared DB). Drives the real script exactly as supervisor.py
# does (CLI args + DB_* env), for both models, and checks what lands in
# calib_weights / calib_weights_fit.
#
# Wrapper: e2e_local_pg.sh starts/stops the temp server. Env read here:
#   PGPORT (default 54331), RSCRIPT, R_LIBS (library with curveRcore >= 0.6.0 and
#   curveRweights >= 0.3.0), CORE_DDL (path to curveRcore R/calib_schema.sql).
#
# Scenarios
#   A  default job (no --model)        -> multiplicative rows; additive cols NULL
#   B  --model additive                -> SAME keys replaced; model='additive';
#                                         censored rows have NULL w_norm; phi NULL
#   C  default job again               -> back to multiplicative (the rollback path)
#   D  curve_ids with no samples       -> job FAILS (non-zero exit), nothing written
#   E  DB without the 0.6.0 columns    -> multiplicative still works; additive refuses
# =============================================================================
suppressMessages({library(DBI); library(RPostgres)})

port    <- Sys.getenv("PGPORT", "54331")
rscript <- Sys.getenv("RSCRIPT", file.path(R.home("bin"), "Rscript"))
ddl     <- Sys.getenv("CORE_DDL")
worker  <- normalizePath(file.path(dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])), "..", "worker_weights.R"))
stopifnot(file.exists(ddl), file.exists(worker))

connect <- function(db) dbConnect(RPostgres::Postgres(), dbname = db, host = "localhost",
                                  port = as.integer(port), user = "tester",
                                  options = "-c search_path=madi_results")
admin <- dbConnect(RPostgres::Postgres(), dbname = "postgres", host = "localhost",
                   port = as.integer(port), user = "tester")
for (db in c("e2e", "e2e_old")) {
  dbExecute(admin, sprintf("DROP DATABASE IF EXISTS %s", db))
  dbExecute(admin, sprintf("CREATE DATABASE %s", db))
}
dbDisconnect(admin)

# ---- schema ------------------------------------------------------------------
sql <- readLines(ddl, warn = FALSE)
grab <- function(from_pat, to_pat) {
  i <- grep(from_pat, sql)[1]; j <- i + which(grepl(to_pat, sql[(i + 1):length(sql)]))[1]
  sql[i:j]
}
calib_samples_ddl <- paste(grab("^CREATE TABLE IF NOT EXISTS madi_results.calib_samples", "^\\);"), collapse = "\n")
w_start <- grep("^-- Precision weights \\(curveRweights\\)", sql)[1]
w_end   <- grep("^-- Children with NO FK", sql)[1] - 2
weights_block <- paste(sql[w_start:w_end], collapse = "\n")
# the pre-0.6.0 definition = the block without its ALTER TABLE additions
old_weights_block <- sub("-- 0\\.6\\.0 extension.*$", "", weights_block)

stub <- "CREATE SCHEMA madi_results;
CREATE TABLE madi_results.curve_lookup (curve_id bigint PRIMARY KEY, multiplate_group_id uuid,
  antigen varchar(64), feature varchar(15), source text, plate text);"
psql <- Sys.getenv("PSQL", "psql")
for (db in c("e2e", "e2e_old")) {
  f <- tempfile(fileext = ".sql")
  writeLines(c(stub, calib_samples_ddl, if (db == "e2e") weights_block else old_weights_block), f)
  st <- system2(psql, c("-h", "localhost", "-p", port, "-U", "tester", "-d", db, "-q",
                        "-v", "ON_ERROR_STOP=1", "-f", shQuote(f, type = "cmd")),
                stdout = FALSE, stderr = FALSE)
  stopifnot(identical(as.integer(st), 0L))
}

# ---- simulated calibration output --------------------------------------------
set.seed(11)
gids <- c("aaaaaaaa-0000-0000-0000-000000000001", "bbbbbbbb-0000-0000-0000-000000000002")
lookup <- data.frame(curve_id = 1:4, multiplate_group_id = rep(gids, each = 2),
                     antigen = rep(c("prn", "pt"), each = 2), feature = "IgG1",
                     source = "std", plate = paste0("plate_", 1:4), stringsAsFactors = FALSE)
cells <- expand.grid(timeperiod = c("t1", "t2", "t3"), agroup = c("A", "B"), stringsAsFactors = FALSE)
mk <- function(curve_id, grp) {
  d <- do.call(rbind, lapply(seq_len(nrow(cells)), function(i)
    data.frame(cells[i, ], rep = 1:14, stringsAsFactors = FALSE)))
  d$curve_id <- curve_id
  d$sampleid <- sprintf("s%d_%d_%s_%d", curve_id, seq_len(nrow(d)), d$timeperiod, d$rep)
  d$patientid <- sprintf("p%02d", d$rep + 14 * (d$agroup == "B"))
  mu <- seq(0.2, 2, length.out = nrow(cells))[match(paste(d$timeperiod, d$agroup), paste(cells$timeperiod, cells$agroup))]
  se <- exp(rnorm(nrow(d), log(0.11), 0.6))
  y  <- mu + rnorm(nrow(d), 0, sqrt(0.35^2 + se^2))
  lo <- quantile(y, 0.08)
  cens <- y < lo
  data.frame(curve_id = d$curve_id, method = "frequentist", sampleid = d$sampleid,
             patientid = d$patientid, timeperiod = d$timeperiod, dilution = "2000",
             predicted_concentration = ifelse(cens, y - 0.4, y),
             final_concentration = 10^ifelse(cens, y - 0.4, y) * 2000,
             se_concentration = ifelse(cens, se * 6, se), pcov = se * log(10) * 100,
             pcov_pass = !cens, agroup = d$agroup,
             censor_class = ifelse(cens, "below_lloq", "quantified"),
             censor_type = ifelse(cens, "left", "none"),
             censor_lower = NA_real_, censor_upper = ifelse(cens, 10^lo * 2000, NA_real_),
             job_id = "sim", stringsAsFactors = FALSE)
}
samples <- do.call(rbind, lapply(1:4, function(i) mk(i, 1)))
for (db in c("e2e", "e2e_old")) {
  con <- connect(db)
  dbAppendTable(con, DBI::Id(schema = "madi_results", table = "curve_lookup"), lookup)
  dbAppendTable(con, DBI::Id(schema = "madi_results", table = "calib_samples"), samples)
  dbDisconnect(con)
}
n_samples <- nrow(samples); n_cens <- sum(samples$censor_type == "left")
cat(sprintf("simulated %d samples (%d left-censored), 4 curves, 2 multiplate groups\n", n_samples, n_cens))

# ---- run the worker ------------------------------------------------------------
run_worker <- function(db, job_id, curve_ids = "1,2,3,4", model = NULL) {
  args <- c(shQuote(worker, type = "cmd"), "--job_id", job_id, "--progress_dir",
            shQuote(tempdir(), type = "cmd"),
            "--curve_ids", curve_ids, "--method", "frequentist",
            "--design", "timeperiod,agroup", "--iter", "600", "--warmup", "300",
            "--chains", "2", "--seed", "7")
  if (!is.null(model)) args <- c(args, "--model", model)
  env <- c(DB_NAME = db, DB_HOST = "localhost", DB_PORT = port, DB_USER = "tester",
           DB_PASSWORD = "", DB_SSLMODE = "disable", WORKER_CORES = "2", WORKER_MAX_PARALLEL = "1",
           R_LIBS = Sys.getenv("R_LIBS"))
  old <- Sys.getenv(names(env), unset = NA)
  do.call(Sys.setenv, as.list(env))
  on.exit(for (k in names(old)) if (is.na(old[[k]])) Sys.unsetenv(k) else
    do.call(Sys.setenv, stats::setNames(list(old[[k]]), k)), add = TRUE)
  out <- suppressWarnings(system2(rscript, args, stdout = TRUE, stderr = TRUE))
  list(status = attr(out, "status") %||% 0L, out = out)
}
`%||%` <- function(a, b) if (is.null(a)) b else a

results <- list()
check <- function(id, ok, what) {
  results[[length(results) + 1L]] <<- data.frame(scenario = id, ok = isTRUE(ok), check = what,
                                                 stringsAsFactors = FALSE)
  cat(sprintf("  [%s] %s  %s\n", if (isTRUE(ok)) "PASS" else "FAIL", id, what))
}
q <- function(db, sql) { con <- connect(db); on.exit(dbDisconnect(con)); dbGetQuery(con, sql) }
num <- function(x) as.numeric(as.character(x))

# A: default job
cat("\nA: default job (no --model)\n")
a <- run_worker("e2e", "job-A")
check("A", a$status == 0, "exit status 0")
w <- q("e2e", "SELECT * FROM calib_weights"); f <- q("e2e", "SELECT * FROM calib_weights_fit")
check("A", nrow(w) == n_samples, sprintf("%d weight rows written (one per sample)", nrow(w)))
check("A", all(w$model == "multiplicative"), "model = multiplicative on every row")
check("A", all(is.na(w$reliability)) && all(is.na(w$v_meas)) && all(is.na(w$tau2)), "additive columns NULL")
check("A", nrow(f) == 2 && all(!is.na(f$phi)) && all(is.na(f$tau)), "2 fit rows, phi set, tau NULL")
check("A", all(!is.na(w$weights_pkg_version)), "weights_pkg_version recorded")
w_mult <- w[order(w$curve_id, w$sampleid), ]

# B: additive replaces the same keys
cat("\nB: --model additive (replaces the same keys)\n")
b <- run_worker("e2e", "job-B", model = "additive")
check("B", b$status == 0, "exit status 0")
w <- q("e2e", "SELECT * FROM calib_weights"); f <- q("e2e", "SELECT * FROM calib_weights_fit")
check("B", nrow(w) == n_samples, "same number of rows: keys replaced, none duplicated")
check("B", all(w$model == "additive"), "model = additive on every row")
check("B", all(w$job_id == "job-B"), "rows belong to the new job")
rel <- num(w$reliability)
check("B", all(rel > 0 & rel <= 1, na.rm = TRUE) && !anyNA(rel), "reliability in (0, 1] for every sample")
check("B", all(num(w$w) * num(w$tau2) <= 1 + 1e-8, na.rm = TRUE), "w never exceeds 1/tau2 (reliability = tau2 * w <= 1)")
cs <- w$censor_type == "left" & !is.na(w$censor_type)
check("B", sum(cs) == n_cens, sprintf("%d censored rows carry censor_type = left", sum(cs)))
check("B", all(is.na(w$w_norm[cs])) && all(!is.na(w$w_norm[!cs])), "w_norm NULL exactly for censored rows")
check("B", all(!is.na(w$bound[cs])) && all(is.na(w$bound[!cs])), "bound set exactly for censored rows")
check("B", nrow(f) == 2 && all(f$model == "additive"), "2 fit rows (replaced), model = additive")
check("B", all(is.na(f$phi)) && all(!is.na(f$tau)) && all(!is.na(f$kappa)) && all(f$fix_beta1), "phi NULL; tau/kappa set; beta1 fixed")
check("B", all(num(f$reliability) > 0 & num(f$reliability) <= 1) && all(f$n_censored > 0), "group reliability in (0,1]; n_censored > 0")

# C: rollback
cat("\nC: default job again (rollback to the multiplicative weights)\n")
cc <- run_worker("e2e", "job-C")
w <- q("e2e", "SELECT * FROM calib_weights"); f <- q("e2e", "SELECT * FROM calib_weights_fit")
w <- w[order(w$curve_id, w$sampleid), ]
check("C", cc$status == 0 && nrow(w) == n_samples, "exit 0; same row count")
check("C", all(w$model == "multiplicative") && all(is.na(w$reliability)) && all(is.na(w$censor_type)), "additive columns cleared again")
check("C", all(f$model == "multiplicative") && all(is.na(f$tau)) && all(!is.na(f$phi)), "fit rows back to phi/beta1")
check("C", isTRUE(all.equal(num(w$sigma), num(w_mult$sigma), tolerance = 1e-6)), "weights identical to run A (same seed): rollback restores them exactly")

# D: nothing to do must FAIL
cat("\nD: curve_ids with no calib_samples\n")
n_before <- nrow(q("e2e", "SELECT 1 FROM calib_weights"))
d <- run_worker("e2e", "job-D", curve_ids = "99,100")
check("D", d$status != 0, sprintf("exit status %s (non-zero => supervisor marks the job failed)", d$status))
check("D", any(grepl("Nothing to do", d$out)), "message explains why")
check("D", nrow(q("e2e", "SELECT 1 FROM calib_weights")) == n_before, "nothing written")

# E: DB without the 0.6.0 columns
cat("\nE: DB without the 0.6.0 columns (migration 010 not applied)\n")
e1 <- run_worker("e2e_old", "job-E1")
w <- q("e2e_old", "SELECT * FROM calib_weights")
check("E", e1$status == 0 && nrow(w) == n_samples, "multiplicative job still works on the old schema")
check("E", !"model" %in% names(w), "(old schema really has no model column)")
e2 <- run_worker("e2e_old", "job-E2", model = "additive")
check("E", e2$status != 0, sprintf("additive job refused (exit %s)", e2$status))
check("E", any(grepl("010_calib_weights_model", e2$out)), "message points at migration 010")

res <- do.call(rbind, results)
cat(sprintf("\n%d checks, %d passed, %d FAILED\n", nrow(res), sum(res$ok), sum(!res$ok)))
if (any(!res$ok)) {
  cat("\n--- worker output of failing scenarios (tail) ---\n")
  for (sc in unique(res$scenario[!res$ok])) {
    o <- get(c(A = "a", B = "b", C = "cc", D = "d", E = "e2")[[sc]])$out
    cat("scenario", sc, ":\n", paste(tail(o, 25), collapse = "\n"), "\n")
  }
  quit(status = 1)
}
