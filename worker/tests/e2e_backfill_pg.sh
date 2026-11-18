#!/usr/bin/env bash
# =============================================================================
# e2e_backfill_pg.sh -- start a throwaway PostgreSQL, run e2e_backfill_pg.R
# against it (migration 011 + backfill_point_estimates.R), stop and delete it.
# Never touches any shared database.
#
#   R_LIBS=/path/to/lib-with-curveRcore-0.7.0 \
#   CORE_DDL_060=/path/to/curveRcore-0.6.0/R/calib_schema.sql \
#   worker/tests/e2e_backfill_pg.sh
#
# CORE_DDL_060 is the schema BEFORE migration 011, e.g.
#   git -C curveRcore show v0.6.0:R/calib_schema.sql > /tmp/calib_schema_060.sql
# Optional: PG_BIN (dir with initdb/pg_ctl), RSCRIPT, PGPORT (default 54332),
# E2E_SKIP_BAYES=1 (skip the Bayesian scenario, which needs CmdStan).
# =============================================================================
set -euo pipefail
PG_BIN="${PG_BIN:-/c/Program Files/PostgreSQL/16/bin}"
RSCRIPT="${RSCRIPT:-Rscript}"
PGPORT="${PGPORT:-54332}"
: "${CORE_DDL_060:?set CORE_DDL_060 to the curveRcore 0.6.0 R/calib_schema.sql}"
HERE="$(cd "$(dirname "$0")" && pwd)"
D="$(mktemp -d)"
trap '"$PG_BIN/pg_ctl" -D "$D/data" -m fast stop >/dev/null 2>&1 || true; rm -rf "$D"' EXIT

"$PG_BIN/initdb" -D "$D/data" -U tester --auth=trust -E UTF8 >/dev/null
"$PG_BIN/pg_ctl" -D "$D/data" -o "-p $PGPORT" -l "$D/pg.log" -w start >/dev/null
export PGPORT RSCRIPT CORE_DDL_060
export PSQL="$PG_BIN/psql"
"$RSCRIPT" "$HERE/e2e_backfill_pg.R"
