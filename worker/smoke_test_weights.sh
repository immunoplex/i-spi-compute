#!/usr/bin/env bash
# =============================================================================
# smoke_test_weights.sh — end-to-end smoke test for the precision-weighting
# job (worker_weights.R), run DIRECTLY against the real DB from a dev machine
# (bypassing the API/Redis/supervisor — see worker_weights.R's own CLI
# contract, which this script drives exactly as supervisor.py would).
#
# What it does:
#   1. Resolve (study, experiment, antigen, feature) -> curve_ids via
#      curve_lookup, and report the multiplate groups found.
#   2. Check calib_samples coverage for --method (the precondition: a
#      calibration job must already have run and persisted for these
#      curve_ids/method, or there's nothing to compute weights from).
#   3. Check which --design columns actually have variation in this scope
#      (warns, rather than silently fitting a degenerate design, if a
#      requested column is constant/NULL for every row).
#   4. Run worker_weights.R for real (small chains/warmup/iter by default —
#      this is a SMOKE test, not a publication-quality fit; override via
#      --chains/--warmup/--iter for a real run).
#   5. Query calib_weights/calib_weights_fit afterward and print a summary.
#
# Requires: psql, Rscript (with curveRweights + a working Stan backend
# installed), and a .env file (same keys worker_curveR.R/worker_weights.R
# read: DB_NAME/HOST/PORT/USER/PASSWORD/SSLMODE) in this directory's parent
# (the repo root) or set in the environment already.
#
# Usage:
#   ./smoke_test_weights.sh \
#     --study MADI_P3_GAPS --experiment IgG1 --antigen prn --feature IgG1 \
#     --method bayesian --design timeperiod
#
# Optional: --chains N --warmup N --iter N --adapt_delta N --seed N
#           --scale_predictor se|pcov --job_id STR --psql /path/to/psql
# =============================================================================
set -euo pipefail

# ── defaults ──────────────────────────────────────────────────────────────
STUDY=""; EXPERIMENT=""; ANTIGEN=""; FEATURE=""
METHOD=""; DESIGN=""
SCALE_PREDICTOR="se"
CHAINS="2"; WARMUP="200"; ITER="400"; ADAPT_DELTA="0.9"; SEED=""
JOB_ID="smoke-$(date +%Y%m%d%H%M%S)"
PSQL="${PSQL_BIN:-psql}"

while [ $# -gt 0 ]; do
  case "$1" in
    --study) STUDY="$2"; shift 2 ;;
    --experiment) EXPERIMENT="$2"; shift 2 ;;
    --antigen) ANTIGEN="$2"; shift 2 ;;
    --feature) FEATURE="$2"; shift 2 ;;
    --method) METHOD="$2"; shift 2 ;;
    --design) DESIGN="$2"; shift 2 ;;
    --scale_predictor) SCALE_PREDICTOR="$2"; shift 2 ;;
    --chains) CHAINS="$2"; shift 2 ;;
    --warmup) WARMUP="$2"; shift 2 ;;
    --iter) ITER="$2"; shift 2 ;;
    --adapt_delta) ADAPT_DELTA="$2"; shift 2 ;;
    --seed) SEED="$2"; shift 2 ;;
    --job_id) JOB_ID="$2"; shift 2 ;;
    --psql) PSQL="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

for req in STUDY EXPERIMENT ANTIGEN FEATURE METHOD DESIGN; do
  if [ -z "${!req}" ]; then
    echo "Missing required --${req,,}" >&2
    exit 1
  fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi
: "${DB_HOST:?DB_HOST not set (source .env or export it first)}"
export PGPASSWORD="${DB_PASSWORD:-}"
export PGSSLMODE="${DB_SSLMODE:-require}"

# worker_weights.R's cross-group fan-out uses parallel::mclapply() (fork-based
# -- only works on Linux, which is what the deployed pod actually runs). On a
# Windows dev machine mc.cores > 1 is fatal, not just slow, so force serial
# execution here unless the caller already set WORKER_MAX_PARALLEL. This only
# affects how many groups run AT ONCE on a local smoke test; it has no effect
# on (and reveals nothing about) how the deployed pod runs.
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) export WORKER_MAX_PARALLEL="${WORKER_MAX_PARALLEL:-1}" ;;
esac

PSQL_ARGS=(-h "$DB_HOST" -p "${DB_PORT:-5432}" -d "${DB_NAME:-postgres}" -U "${DB_USER:-}")

echo "=============================================================="
echo " smoke_test_weights: study=$STUDY experiment=$EXPERIMENT antigen=$ANTIGEN feature=$FEATURE"
echo " method=$METHOD design=$DESIGN job_id=$JOB_ID"
echo "=============================================================="

echo
echo "── [1/5] Resolving curve_ids + multiplate groups ──────────────────────"
"$PSQL" "${PSQL_ARGS[@]}" -c "
SELECT source, multiplate_group_id, count(*) AS n_curves
  FROM madi_results.curve_lookup
 WHERE study_accession = '$STUDY' AND experiment_accession = '$EXPERIMENT'
   AND antigen = '$ANTIGEN' AND feature = '$FEATURE'
 GROUP BY 1, 2 ORDER BY 1;"

CURVE_IDS=$("$PSQL" "${PSQL_ARGS[@]}" -t -A -c "
SELECT string_agg(curve_id::text, ',' ORDER BY curve_id)
  FROM madi_results.curve_lookup
 WHERE study_accession = '$STUDY' AND experiment_accession = '$EXPERIMENT'
   AND antigen = '$ANTIGEN' AND feature = '$FEATURE';")

if [ -z "$CURVE_IDS" ]; then
  echo "No curve_ids found for this (study, experiment, antigen, feature). Check spelling/case --" >&2
  echo "antigen/feature values in this schema are case-sensitive and not always uppercase." >&2
  exit 1
fi
N_CURVES=$(echo "$CURVE_IDS" | tr ',' '\n' | wc -l)
echo "Resolved $N_CURVES curve_ids: $CURVE_IDS"

echo
echo "── [2/5] Checking calib_samples coverage for method=$METHOD ───────────"
"$PSQL" "${PSQL_ARGS[@]}" -c "
SELECT cl.source, count(DISTINCT cs.curve_id) AS n_curves_with_samples, count(*) AS n_sample_rows
  FROM madi_results.curve_lookup cl
  JOIN madi_results.calib_samples cs ON cs.curve_id = cl.curve_id AND cs.method = '$METHOD'
 WHERE cl.study_accession = '$STUDY' AND cl.experiment_accession = '$EXPERIMENT'
   AND cl.antigen = '$ANTIGEN' AND cl.feature = '$FEATURE'
 GROUP BY 1 ORDER BY 1;"

N_WITH_SAMPLES=$("$PSQL" "${PSQL_ARGS[@]}" -t -A -c "
SELECT count(DISTINCT cs.curve_id)
  FROM madi_results.curve_lookup cl
  JOIN madi_results.calib_samples cs ON cs.curve_id = cl.curve_id AND cs.method = '$METHOD'
 WHERE cl.study_accession = '$STUDY' AND cl.experiment_accession = '$EXPERIMENT'
   AND cl.antigen = '$ANTIGEN' AND cl.feature = '$FEATURE';")
if [ "$N_WITH_SAMPLES" = "0" ]; then
  echo "No calib_samples rows for method=$METHOD in this scope. Run calibration (script_type=$METHOD) first." >&2
  exit 1
fi

echo
echo "── [3/5] Checking design column variation: $DESIGN ─────────────────────"
IFS=',' read -ra DCOLS <<< "$DESIGN"
for col in "${DCOLS[@]}"; do
  echo "-- $col --"
  "$PSQL" "${PSQL_ARGS[@]}" -c "
  SELECT cs.$col, count(*) FROM madi_results.curve_lookup cl
    JOIN madi_results.calib_samples cs ON cs.curve_id = cl.curve_id AND cs.method = '$METHOD'
   WHERE cl.study_accession = '$STUDY' AND cl.experiment_accession = '$EXPERIMENT'
     AND cl.antigen = '$ANTIGEN' AND cl.feature = '$FEATURE'
   GROUP BY 1 ORDER BY 1;"
done

echo
echo "── [4/5] Running worker_weights.R (job_id=$JOB_ID) ─────────────────────"
PROGRESS_DIR="$(mktemp -d)"
RSCRIPT="${RSCRIPT_BIN:-Rscript}"
SEED_ARGS=(); [ -n "$SEED" ] && SEED_ARGS=(--seed "$SEED")

"$RSCRIPT" "$SCRIPT_DIR/worker_weights.R" \
  --curve_ids "$CURVE_IDS" \
  --method "$METHOD" \
  --design "$DESIGN" \
  --scale_predictor "$SCALE_PREDICTOR" \
  --chains "$CHAINS" --warmup "$WARMUP" --iter "$ITER" --adapt_delta "$ADAPT_DELTA" \
  "${SEED_ARGS[@]}" \
  --job_id "$JOB_ID" --progress_dir "$PROGRESS_DIR"
RC=$?
rm -rf "$PROGRESS_DIR"

if [ $RC -ne 0 ]; then
  echo "worker_weights.R exited $RC — see output above for which group(s) failed." >&2
  exit $RC
fi

echo
echo "── [5/5] Verifying persisted results ───────────────────────────────────"
"$PSQL" "${PSQL_ARGS[@]}" -c "
SELECT multiplate_group_id, method, antigen, feature, design_cols, scale_predictor,
       round(phi::numeric, 4) AS phi, round(beta1::numeric, 4) AS beta1,
       interpretation, n_fit, round(n_eff::numeric, 1) AS n_eff,
       round(weight_ratio::numeric, 1) AS weight_ratio
  FROM madi_results.calib_weights_fit
 WHERE job_id = '$JOB_ID' ORDER BY multiplate_group_id;"

"$PSQL" "${PSQL_ARGS[@]}" -c "
SELECT count(*) AS n_weight_rows, count(DISTINCT curve_id) AS n_curves,
       round(min(w_norm)::numeric, 3) AS min_w_norm, round(max(w_norm)::numeric, 3) AS max_w_norm
  FROM madi_results.calib_weights
 WHERE job_id = '$JOB_ID';"

echo
echo "Done. job_id=$JOB_ID"
