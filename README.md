# Immunoplex Batch Runner

Generic background job system for running computationally expensive calculations (Bayesian curve fitting, frequentist methods, etc.) outside the i-spi Shiny app. Each job specifies a `script_type` that determines which R or Python worker script runs.

Jobs are submitted via a REST API, queued in Redis, and processed by worker containers that save results directly to PostgreSQL.

## Architecture

```
  Client (i-spi / curl)
        │
        ▼
  ┌──────────────┐
  │  FastAPI API  │  POST /jobs, GET /jobs/{id}, DELETE /jobs/{id}
  │  (port 8000)  │
  └──────┬───────┘
         │ RPUSH job_id
         ▼
  ┌──────────────┐
  │    Redis 7    │  Queue: ispi:batch:queue
  └──────┬───────┘
         │ BLPOP
         ▼
  ┌──────────────────┐
  │  Python Supervisor │  Dispatches to SCRIPT_REGISTRY[script_type]
  └──────┬───────────┘
         │ subprocess
         ▼
  ┌──────────────────┐
  │  Worker Script    │  bayesian → worker_batch.R (stanassay)
  │                   │  (add more via SCRIPT_REGISTRY)
  └──────┬───────────┘
         │ upsert
         ▼
  ┌──────────────┐
  │  PostgreSQL   │  madi_results.bayes_*
  └──────────────┘
```

## Quick Start (Local Development)

```bash
# 1. Clone
git clone https://github.com/immunoplex/immunoplex-batch-calculator.git
cd immunoplex-batch-calculator

# 2. Configure DB credentials (edit to match your PostgreSQL)
cp .env.example .env
# Edit .env: set DB_HOST, DB_USER, DB_PASSWORD, DB_NAME

# 3. Start
docker compose up --build

# 4. Verify
curl http://localhost:8000/health
open http://localhost:8000/docs
```

First build takes ~10 minutes (Stan C++ compilation). Subsequent builds are fast (cached layers).

## API Reference

All endpoints except `/health` require the `X-API-Key` header.

### POST /jobs — Submit a Job

```bash
curl -X POST http://localhost:8000/jobs \
  -H "Content-Type: application/json" \
  -H "X-API-Key: dev-key-immunoplex" \
  -d '{
    "project_id": 1,
    "study": "MY_STUDY",
    "experiment": "EXP1",
    "scope": "experiment"
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
| `script_type` | string | no | `bayesian` | Which worker script to run |
| `params` | dict | no | `{}` | Script-specific params (passed as `--key value` CLI args) |
| `cdan_cv_threshold` | float | no | `20.0` | Bayesian CDAN CV% threshold (auto-merged into params) |

### GET /jobs/{job_id} — Poll Status

```bash
curl -H "X-API-Key: dev-key-immunoplex" http://localhost:8000/jobs/{job_id}
```

Key response fields for UI:

| Field | Description |
|-------|-------------|
| `status` | `queued` → `running` → `completed` / `failed` / `cancelled` |
| `percentage` | 0.0–100.0, suitable for progress bar |
| `eta_display` | Human-readable time remaining (e.g. `~3 min 20 sec`) |
| `current_experiment` | Which experiment is being processed |
| `current_antigens` | Which antigens are being fitted |

### GET /jobs — List Jobs

```bash
curl -H "X-API-Key: dev-key-immunoplex" "http://localhost:8000/jobs?study=MY_STUDY&status=running"
```

### DELETE /jobs/{job_id} — Cancel a Job

```bash
curl -X DELETE -H "X-API-Key: dev-key-immunoplex" http://localhost:8000/jobs/{job_id}
```

### GET /health — Health Check (no auth)

```bash
curl http://localhost:8000/health
```

## Project Structure

```
immunoplex-batch-calculator/
  api/
    app.py              # FastAPI application
    Dockerfile
    requirements.txt
  worker/
    worker_batch.R      # Bayesian worker (stanassay ensemble fitting)
    supervisor.py       # Python supervisor (BLPOP + subprocess + progress)
    entrypoint.sh       # Container entrypoint
    Dockerfile
    requirements.txt
    stanassay_*.tar.gz  # stanassay R package (compiled at build time)
  docker-compose.yml    # Local dev stack
  .env.example          # Environment variable reference
```

## Adding a New Calculation Script

The worker dispatches jobs to scripts based on `script_type`, using a registry in `supervisor.py`:

```python
SCRIPT_REGISTRY = {
    "bayesian":    ("Rscript", SCRIPTS_DIR / "worker_batch.R"),
    # "frequentist": ("Rscript", SCRIPTS_DIR / "worker_freq.R"),
}
```

To add a new script:

1. **Write the script** — accept `--study`, `--experiment`, `--job_id`, `--progress_dir` CLI args. Write progress to `{progress_dir}/progress_{job_id}.json` with `total_combos` and `completed_combos`. Exit 0 on success.

2. **Register** — add one line to `SCRIPT_REGISTRY` in `supervisor.py`

3. **Dockerfile** — add `COPY worker_new.R .` and any R package installs

4. **Submit** — `{"script_type": "frequentist", "params": {"method": "nplr"}}`

## Docker Operations

```bash
docker compose up --build            # Start everything
docker compose build worker          # Rebuild worker only
docker compose build --no-cache worker  # Force clean rebuild
docker compose logs -f worker        # Watch worker logs
docker compose down                  # Stop (clears Redis)
```

### Updating stanassay

```bash
cd ../stanassay
R CMD build . --no-manual --no-vignettes
cp stanassay_*.tar.gz ../immunoplex-batch-calculator/worker/
cd ../immunoplex-batch-calculator
docker compose build worker
```

## Deployment

See the [deployment repo](https://github.com/immunoplex/deployment) for Kubernetes manifests and installation instructions.

## Environment Variables

| Variable | Used By | Description |
|----------|---------|-------------|
| `REDIS_HOST` | api, worker | Redis hostname |
| `REDIS_PORT` | api, worker | Redis port |
| `REDIS_AUTH` | api, worker | Redis password |
| `REDIS_DB` | api, worker | Redis database number |
| `API_KEY` | api | API authentication key |
| `ROOT_PATH` | api | Reverse proxy path prefix (e.g. `/batch-api`) |
| `DB_NAME` | worker | PostgreSQL database name |
| `DB_HOST` | worker | PostgreSQL host |
| `DB_PORT` | worker | PostgreSQL port |
| `DB_USER` | worker | PostgreSQL user |
| `DB_PASSWORD` | worker | PostgreSQL password |
| `DB_SSLMODE` | worker | PostgreSQL SSL mode |
| `PROGRESS_DIR` | worker | Progress file directory (default: `/tmp`) |
