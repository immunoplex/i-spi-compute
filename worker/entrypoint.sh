#!/bin/bash
# =============================================================================
# Worker Entrypoint (curveR)
#
# Verifies the curveR + CmdStan runtime is present, then launches the Python
# supervisor. The curveR packages and CmdStan are baked into the image at build
# time (see worker.Dockerfile); Stan models are precompiled there too.
#
# Dev override: mount a local curveRbayes source at /curveRbayes to reinstall on
# startup without a full image rebuild (recompiles Stan models — slow).
# =============================================================================

set -e

echo "============================================"
echo "Immunoplex Batch Worker (curveR) starting..."
echo "  Redis: ${REDIS_HOST}:${REDIS_PORT}"
echo "  DB:    ${DB_HOST}:${DB_PORT}/${DB_NAME}"
echo "  Cores: WORKER_CORES=${WORKER_CORES:-<unset → detectCores()>}  nproc=$(nproc)"
echo "============================================"

# Optional dev override: reinstall curveRbayes from a mounted source tree.
if [ -d "/curveRbayes" ] && [ -f "/curveRbayes/DESCRIPTION" ]; then
  MOUNTED_VER=$(grep '^Version:' /curveRbayes/DESCRIPTION | awk '{print $2}')
  echo "curveRbayes source mounted (v${MOUNTED_VER}) — reinstalling from /curveRbayes ..."
  echo "  (recompiles Stan models; can take several minutes)"
  R -e "remotes::install_local('/curveRbayes', upgrade='never', quiet=FALSE)"
fi

# Verify the curveR stack is importable.
for pkg in curveRcore curveRfreq curveRbayes; do
  if ! R --quiet -e "library($pkg)" &>/dev/null; then
    echo "ERROR: R package '$pkg' is not installed."
    echo "  Rebuild the worker image (see worker.Dockerfile), or mount a source"
    echo "  tree for dev (e.g. '- ../curveRbayes:/curveRbayes:ro' in compose)."
    exit 1
  fi
done

# Verify CmdStan is present (required for the bayesian engine).
if ! R --quiet -e "cmdstanr::cmdstan_version()" &>/dev/null; then
  echo "ERROR: CmdStan not found."
  echo "  Ensure install_cmdstan() ran at build time and CMDSTAN=${CMDSTAN} is valid."
  exit 1
fi

echo "curveRcore:  $(R --quiet -e 'cat(as.character(packageVersion("curveRcore")))' 2>/dev/null)"
echo "curveRfreq:  $(R --quiet -e 'cat(as.character(packageVersion("curveRfreq")))' 2>/dev/null)"
echo "curveRbayes: $(R --quiet -e 'cat(as.character(packageVersion("curveRbayes")))' 2>/dev/null)"
echo "CmdStan:     $(R --quiet -e 'cat(cmdstanr::cmdstan_version())' 2>/dev/null)"
echo "R version:   $(R --version | head -1)"
echo "============================================"


R --quiet -e 'stopifnot("include_col" %in% names(formals(curveRcore::preprocess_standards)))' \
  || { echo "ERROR: curveRcore lacks include_col despite version"; exit 1; }

# Legacy output dir (results now go to madi_results.calib_*; harmless to create).
mkdir -p "${OUTPUT_DIR:-/data/calib}"

# Hand off to the supervisor (queue consumer). exec so signals reach it directly.
exec python3 /app/supervisor.py
