#!/usr/bin/env bash
# =============================================================================
# e2e_local_pg.sh -- start a throwaway PostgreSQL, run e2e_local_pg.R against it,
# stop and delete it. Never touches any shared database.
#
#   R_LIBS=/path/to/lib-with-curveRcore-0.6.0-and-curveRweights-0.3.0 \
#   CORE_DDL=/path/to/curveRcore/R/calib_schema.sql \
#   worker/tests/e2e_local_pg.sh
#
# Optional: PG_BIN (dir with initdb/pg_ctl), RSCRIPT, PGPORT (default 54331).
# =============================================================================
set -euo pipefail
PG_BIN="${PG_BIN:-/c/Program Files/PostgreSQL/16/bin}"
RSCRIPT="${RSCRIPT:-Rscript}"
PGPORT="${PGPORT:-54331}"
: "${CORE_DDL:?set CORE_DDL to curveRcore/R/calib_schema.sql}"
HERE="$(cd "$(dirname "$0")" && pwd)"
D="$(mktemp -d)"
trap '"$PG_BIN/pg_ctl" -D "$D/data" -m fast stop >/dev/null 2>&1 || true; rm -rf "$D"' EXIT

"$PG_BIN/initdb" -D "$D/data" -U tester --auth=trust -E UTF8 >/dev/null
"$PG_BIN/pg_ctl" -D "$D/data" -o "-p $PGPORT" -l "$D/pg.log" -w start >/dev/null
export PGPORT RSCRIPT CORE_DDL
export PSQL="$PG_BIN/psql"
"$RSCRIPT" "$HERE/e2e_local_pg.R"
