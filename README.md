# i-spi-compute

Background job system for running computationally expensive calibration-curve
fitting (**Bayesian** and **frequentist**) outside the i-spi Shiny app. Jobs are
submitted to a REST API, queued in Redis, and processed by worker containers that
fit curves with the **curveR** engine and save results directly to PostgreSQL.

`i-spi-compute` is the **application tier** (api + worker + redis). The science
lives in the separately-versioned **curveR** R packages
(`curveRcore` / `curveRfreq` / `curveRbayes`), and **i-spi** is the Shiny front
end this tier serves.

## Architecture

```
  Client (i-spi / curl)
        │
        ▼
  ┌────────────────────┐
  │  i-spi-compute-api   │  POST /jobs, GET /jobs/{id}, DELETE /jobs/{id}
  │  (FastAPI, port 8000)│
  └──────────┬─────────┘
             │ RPUSH job_id
             ▼
  ┌────────────────────┐
  │  i-spi-compute-redis │  Queue: ispi:batch:queue
  └──────────┬─────────┘
             │ BLPOP
             ▼
  ┌──────────────────────┐
  │  i-spi-compute-worker  │
  │   supervisor.py        │  Dispatches SCRIPT_REGISTRY[script_type] + --method
  │     └─ Rscript ───────┐│
  │        worker_curveR.R ││  bayesian / frequentist (curveR + CmdStan)
  │        + flatten_and_save.R
  │        + verify_saved.R
  └──────────┬───────────┘
             │ idempotent write (delete-by-(curve_id,method) then insert)
             ▼
  ┌────────────────────┐
  │      PostgreSQL      │  madi_results.calib_*
  └────────────────────┘
```

Both `bayesian` and `frequentist` run the **same** `worker_curveR.R`; they differ
only in the `--method` flag. Results go to the method-agnostic `calib_*` tables
(a `method` column distinguishes the two engines).

## Quick Start (Local Development)

```bash
# 1. Clone
git clone https://github.com/immunoplex/i-spi-compute.git
cd i-spi-compute

# 2. Configure secrets + DB credentials
cp .env.example .env
# Edit .env: set API_KEY, REDIS_AUTH, and DB_HOST/DB_USER/DB_PASSWORD/DB_SSLMODE.
# Plain KEY=value lines, no `export`. See SECRETS.md.

# 3. Start
docker compose up --build

# 4. Verify
curl http://localhost:8000/health          # {"status":"ok","redis":"connected"}
open http://localhost:8000/docs             # Swagger UI
```

**First build takes ~20–25 minutes** — it installs CmdStan, the curveR packages,
and precompiles the Bayesian Stan models into the image. Subsequent builds reuse
cached layers and are fast.

> Local note: if `DB_HOST` points at a campus/VPN database, the container must be
> able to reach it (Docker Desktop's VM has its own network path). For pure
> plumbing tests use a local Postgres; real DB-backed fitting is best run in the
> cluster, where the worker sits on the same network as the database.

## API Reference

All endpoints except `/health` require the `X-API-Key` header. If `API_KEY` is
unset, the API falls back to the dev key `dev-key-immunoplex` (never rely on this
in production).

### POST /jobs — Submit a Job

```bash
curl -X POST http://localhost:8000/jobs \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $API_KEY" \
  -d '{
    "project_id": 17,
    "study": "INCEN_IN_QIV1",
    "experiment": "FcgR2a",
    "antigen": "B_Phuket_HA",
    "scope": "antigen",
    "script_type": "frequentist"
  }'
```

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `project_id` | int | **yes** | — | Workspace/project ID |
| `study` | string | **yes** | — | Study accession |
| `experiment` | string | no | null | Required if scope is `experiment` or `antigen` |
| `antigen` | string | no | null | Required if scope is `antigen` |
| `source` | string | no | null | Standard source filter |
| `scope` | string | no | `study` | `study`, `experiment`, or `antigen` |
| `script_type` | string | no | `bayesian` | **`bayesian` or `frequentist`** — selects the engine |
| `params` | dict | no | `{}` | Passthrough → each key becomes a `--key value` CLI arg |
| `cdan_cv_threshold` | float | no | `20.0` | CV% gate (auto-merged into params as `cdan_cv`) |

The `params` passthrough is how you tune the engine without any API change, e.g.:
- `{"models": "logistic4,gompertz4"}` — restrict the model set
- `{"chains": "4", "warmup": "1000", "sampling": "1000"}` — Bayesian Stan settings

### GET /jobs/{job_id} — Poll Status

```bash
curl -H "X-API-Key: $API_KEY" http://localhost:8000/jobs/{job_id}
```

| Field | Description |
|-------|-------------|
| `status` | `queued` → `running` → `completed` / `failed` / `cancelled` |
| `percentage` | 0.0–100.0, suitable for a progress bar |
| `eta_display` | Human-readable time remaining |
| `current_experiment` | Which experiment is being processed |
| `error` | Tail of the worker output on failure (null otherwise) |
| `output_path` | On success: `madi_results.calib_* (job_id=…)` |

### GET /jobs — List Jobs

```bash
curl -H "X-API-Key: $API_KEY" "http://localhost:8000/jobs?study=INCEN_IN_QIV1&status=running"
```

### DELETE /jobs/{job_id} — Cancel a Job

```bash
curl -X DELETE -H "X-API-Key: $API_KEY" http://localhost:8000/jobs/{job_id}
```

### GET /health — Health Check (no auth)

```bash
curl http://localhost:8000/health
```

## Project Structure

```
i-spi-compute/
  api/
    app.py                 # FastAPI application
    api.Dockerfile
    requirements.txt
  worker/
    worker_curveR.R        # curveR worker (bayesian + frequentist)
    flatten_and_save.R     # result flattener + idempotent DB writer  ┐ sourced as
    verify_saved.R         # post-save verifier                        ┘ SIBLINGS
    supervisor.py          # Python supervisor (BLPOP + subprocess + progress)
    entrypoint.sh          # verifies curveR + CmdStan, then launches supervisor
    worker.Dockerfile
    requirements.txt
  db/
    calib_schema_v1.sql    # one-time migration: creates the calib_* tables
  docker-compose.yml       # local dev stack
  i-spi-compute.k8s.yaml   # Kubernetes manifests (namespace madi-preprod)
  DEPLOYMENT.md            # full deployment & configuration reference
  SECRETS.md               # how to create/wire API_KEY, DB_PASSWORD, REDIS_AUTH
  .env.example             # environment variable template
```

> **Sibling-file rule:** `worker_curveR.R` `source()`s `flatten_and_save.R` and
> `verify_saved.R` from its own directory at startup and aborts if they're
> missing. All three must stay together in `worker/` (and are copied together into
> the image).

## Adding a New Calculation Script

The supervisor dispatches on `script_type` via a registry in `supervisor.py`,
mapping each type to `(interpreter, script_path, method_flag)`:

```python
SCRIPT_REGISTRY = {
    "bayesian":    ("Rscript", SCRIPTS_DIR / "worker_curveR.R", "bayesian"),
    "frequentist": ("Rscript", SCRIPTS_DIR / "worker_curveR.R", "frequentist"),
    # "qc_report": ("python3", SCRIPTS_DIR / "worker_qc.py", None),   # example
}
```

`method_flag` is passed to the worker as `--method`; use `None` for a script that
doesn't take one. To add a script: write it (accept `--study`, `--job_id`,
`--progress_dir`, …; write `{progress_dir}/progress_{job_id}.json` with
`total_combos`/`completed_combos`; exit 0 on success), add one line to
`SCRIPT_REGISTRY`, `COPY` it in the worker Dockerfile, and submit with that
`script_type`.

## Docker Operations

```bash
docker compose up --build                              # start everything
docker compose build i-spi-compute-worker              # rebuild worker only
docker compose build --no-cache i-spi-compute-worker   # force clean rebuild
docker compose logs -f i-spi-compute-worker            # watch worker logs
docker compose down                                    # stop (clears Redis)
```

### Updating curveR

curveR is installed from GitHub at image-build time (not vendored). To pick up a
new curveR release, rebuild the worker so the install layer re-runs:

```bash
docker compose build --no-cache i-spi-compute-worker
docker compose up -d
```

Pin curveR to a release/commit in `worker.Dockerfile` for reproducible builds.

## Deployment

Deploys to Kubernetes (namespace `madi-preprod`) as a **parallel** stack that
does not collide with the existing production batch calculator.

- **`i-spi-compute.k8s.yaml`** — Deployments + Services for redis/api, Deployment
  for worker, tailored to the cluster (own `i-spi-compute` secret, reused
  `madi-lumi-reader/db_pwd_x`, `/compute-api` route, amd64 nodeSelector,
  `WORKER_CORES` ↔ CPU-limit coupling).
- **`DEPLOYMENT.md`** — the full deployment & configuration reference (env-var
  tables, runbook, manifest templates).
- **`SECRETS.md`** — generating and wiring `API_KEY`, `DB_PASSWORD`, `REDIS_AUTH`
  for both Compose and Kubernetes.

Deploy sequence: create the `i-spi-compute` secret → confirm CI pushed
`ghcr.io/immunoplex/i-spi-compute-{api,worker}:main` → `kubectl apply -f
i-spi-compute.k8s.yaml` → add the Traefik `/compute-api` route → submit a test
job. See `DEPLOYMENT.md` §12.

## Environment Variables

| Variable | Used By | Description |
|----------|---------|-------------|
| `API_KEY` | api | API authentication key (clients send it as `X-API-Key`) |
| `ROOT_PATH` | api | Reverse-proxy path prefix (e.g. `/compute-api`) |
| `REDIS_HOST` | api, worker | Redis hostname (`i-spi-compute-redis` in this stack) |
| `REDIS_PORT` | api, worker | Redis port |
| `REDIS_AUTH` | api, worker | Redis password (must match Redis `--requirepass`) |
| `REDIS_DB` | api, worker | Redis database number |
| `DB_NAME` | worker | PostgreSQL database name |
| `DB_HOST` | worker | PostgreSQL host |
| `DB_PORT` | worker | PostgreSQL port |
| `DB_USER` | worker | PostgreSQL user |
| `DB_PASSWORD` | worker | PostgreSQL password (secret) |
| `DB_SSLMODE` | worker | PostgreSQL SSL mode (`require` in production) |
| `WORKER_CORES` | worker | CPU cap; set == container CPU limit. Also caps Stan `parallel_chains` |
| `PROGRESS_DIR` | worker | Progress-file directory (default `/tmp`) |
| `CMDSTAN` | worker | CmdStan path (set in the image to `/opt/cmdstan/current`) |

Full details, including the secret topology and the `WORKER_CORES` rationale, are
in `DEPLOYMENT.md`.
