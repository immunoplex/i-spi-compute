# =============================================================================
# Worker Dockerfile — R + curveR ecosystem + CmdStan + Python supervisor
#
# Replaces the old rstan/stanassay image. The worker now runs worker_curveR.R,
# which uses the curveR packages (curveRcore / curveRfreq / curveRbayes) and the
# cmdstanr -> CmdStan backend instead of rstan + stanassay.
#
# CmdStan is installed at build time and the curveRbayes Stan models are
# precompiled into an image layer, so container start is instant and the worker
# prints "Model executable is up to date!" rather than compiling per job.
#
# Results are written to PostgreSQL (madi_results.calib_*); no output files.
#
# Build:
#   docker compose build worker
# =============================================================================

FROM rocker/tidyverse:latest

LABEL org.opencontainers.image.source=https://github.com/immunoplex/i-spi-compute-worker
LABEL org.opencontainers.image.description="i-spi-compute — Worker (curveR)"

# ── System dependencies ──────────────────────────────────────────────────────
# build-essential + g++/make are needed by CmdStan to compile Stan models.
# git/ca-certificates are needed by remotes::install_github. libpq-dev = RPostgres.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev \
    python3 python3-pip python3-venv \
    build-essential g++ make \
    git ca-certificates curl zip \
    && rm -rf /var/lib/apt/lists/*

# ── Python dependencies (venv avoids externally-managed-environment) ─────────
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY requirements.txt /tmp/py-requirements.txt
RUN pip install --no-cache-dir -r /tmp/py-requirements.txt

# ── R dependencies for the worker + curveR ───────────────────────────────────
RUN R -e "install.packages(c('remotes','DBI','RPostgres','jsonlite','loo','R6'), repos='https://cloud.r-project.org/')"

# ── CmdStan backend ──────────────────────────────────────────────────────────
# Install cmdstanr from the Stan R-universe, then install CmdStan itself. Do this
# BEFORE curveRbayes so its Stan models can compile against a present CmdStan.
# A stable 'current' symlink lets CMDSTAN point at the install regardless of
# version or the runtime user's HOME.
RUN R -e "install.packages('cmdstanr', repos=c('https://stan-dev.r-universe.dev', getOption('repos')))"
RUN mkdir -p /opt/cmdstan \
    && R -e "cmdstanr::install_cmdstan(dir='/opt/cmdstan', cores=parallel::detectCores())" \
    && ln -sfn /opt/cmdstan/cmdstan-* /opt/cmdstan/current
ENV CMDSTAN=/opt/cmdstan/current

# ── curveR ecosystem ─────────────────────────────────────────────────────────
# Install the packages EXPLICITLY in dependency order (not just the meta-package,
# which treats curveRbayes/curveRweights as optional and can leave them out).
# Installed after CmdStan so curveRbayes' Stan build succeeds.
RUN R -e "remotes::install_github(c( \
      'immunoplex/curveRcore', \
      'immunoplex/curveRfreq', \
      'immunoplex/curveRbayes', \
      'immunoplex/curveRweights'), upgrade='never')"

# Hard verify: fail the BUILD (loudly) if any required package can't load, so a
# silent partial install can never reach runtime again.
RUN R -e "pkgs <- c('curveRcore','curveRfreq','curveRbayes'); \
          ok <- vapply(pkgs, requireNamespace, logical(1), quietly=TRUE); \
          if (!all(ok)) { cat('MISSING:', paste(pkgs[!ok], collapse=', '), '\n'); quit(status=1) }; \
          cat('curveR packages OK:', paste(pkgs, collapse=', '), '\n')"

# ── Precompile curveRbayes Stan models into the image ────────────────────────
# Bakes compiled model executables into a layer so containers start instantly
# ("Model executable is up to date!") instead of compiling on the first job.
# Uses curveRbayes' own exported compile_stan_model() (README-documented), which
# knows the inst/stan/ -> stan/ file mapping and the reduce_sum/NCP compile flags.
# Compiles all five shipped families; try()-guarded so a build isn't blocked by
# one model. CMDSTAN is already set above.
RUN R -e "for (m in c('logistic4','logistic5','loglogistic4','loglogistic5','gompertz4')) \
            try(curveRbayes::compile_stan_model(m))" || true

# ── Copy worker scripts ─────────────────────────────────────────────────────
# worker_curveR.R sources flatten_and_save.R and verify_saved.R as SIBLINGS at
# runtime — they must live in the same directory or the worker aborts on load.
WORKDIR /app
COPY supervisor.py entrypoint.sh \
     worker_curveR.R flatten_and_save.R verify_saved.R \
     ./
RUN chmod +x entrypoint.sh

# ── Environment defaults ─────────────────────────────────────────────────────
# Credentials come from K8s secrets / docker-compose env at runtime.
# OUTPUT_DIR is legacy (results now go to madi_results.calib_*); kept only
# because the supervisor still creates/passes it and the worker ignores it.
ENV REDIS_HOST=redis \
    REDIS_PORT=6379 \
    REDIS_DB=0 \
    DB_NAME=local_madi_ispi \
    DB_HOST=localhost \
    DB_PORT=5432 \
    DB_USER=postgres \
    DB_SSLMODE=disable \
    OUTPUT_DIR=/data/calib \
    PROGRESS_DIR=/tmp

# ── Entrypoint ───────────────────────────────────────────────────────────────
CMD ["/app/entrypoint.sh"]
