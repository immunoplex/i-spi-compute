# i-spi-compute

Background job system for running computationally expensive calibration-curve
fitting (**Bayesian** and **frequentist**) outside the i-spi Shiny app. A job is
a **batch of `curve_id`s** to fit. Jobs are submitted to a REST API, queued in
Redis, and processed by worker containers that read the batch from the
`*_for_fit` views, group it into multiplate fitting units by
`multiplate_group_id`, fit curves with the **curveR** engine, and save results
directly to PostgreSQL.

> **Job contract (curve_id batch).** `curve_id`s are minted at load time and
> pre-exist fitting; `curve_lookup` is the authoritative registry. Resolving
> *scope* (study / experiment / antigen) to `curve_id`s is a `curve_lookup`
> query the **client** already performs (the i-spi coverage panel). The client
> sends the resolved batch; the worker never re-derives scope or natural keys.
> See `HANDOFF_worker_curve_id_batch.md`.

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
  │   supervisor.py        │  Dispatches SCRIPT_REGISTRY[script_type] + --method,
  │     └─ Rscript ───────┐│  forwards --curve_ids (the batch)
  │        worker_curveR.R ││  reads *_for_fit views WHERE curve_id = ANY(batch),
  │        + flatten_and_save.R  groups by multiplate_group_id, fits each group
  │        + verify_saved.R ││  (bayesian / frequentist; curveR + CmdStan)
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

Submit the resolved batch of `curve_id`s. The client resolves scope
(study / experiment / antigen) → `curve_id`s against `curve_lookup` before
calling; the worker fits exactly what it is handed.

```bash
curl -X POST http://localhost:8000/jobs \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $API_KEY" \
  -d '{
    "curve_ids": [9057, 9058, 9101, 9102, 9145, 9146],
    "multiplate_group_ids": ["a1b2…", "a1b2…", "c3d4…", "c3d4…", "e5f6…", "e5f6…"],
    "script_type": "frequentist"
  }'
```

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `curve_ids` | list[int] | **yes** | — | The batch of `curve_lookup` ids to fit (≥ 1) |
| `multiplate_group_ids` | list[str] | no | null | Parallel to `curve_ids` (same order). If sent, length must equal `curve_ids`. Integrity check only — the `*_for_fit` views also carry the grouping |
| `script_type` | string | no | `bayesian` | **`bayesian` or `frequentist`** — selects the engine |
| `params` | dict | no | `{}` | Passthrough → each key becomes a `--key value` CLI arg; recognized keys override the settings cascade for this job (see below) |
| `cdan_cv_threshold` | float | no | `20.0` | CV% gate (auto-merged into params as `cdan_cv`) |

`multiplate_group_ids` is optional belt-and-suspenders: the worker can group
purely from the view, but when the array is supplied it asserts the app's
intended grouping matches the view's (a cheap integrity check). Send only
`curve_ids` if you prefer.

The `params` passthrough is how you tune the engine without any API change. Every
recognized key **overrides** that job's settings-cascade value (see below);
omit it to inherit the cascade default:
- `{"models": "logistic4,gompertz4"}` — restrict the model set
- `{"chains": "4", "warmup": "1000", "sampling": "3000"}` — Bayesian draws (higher `sampling` → smoother precision profile)
- `{"include_measurement_error": "false"}` — Bayesian: curve-only precision (omit assay measurement noise)
- `{"blank_option": "subtracted", "seed": "17", "adapt_delta": "0.95"}`

**Settings come from a cascade, not the request.** Analysis settings
(`model_form_list`, `pcov_threshold`, `standard_curve_concentration`,
`is_log_response`, `is_log_independent`, `apply_prozone`, `blank_option`, the
Bayesian sampling knobs, `include_measurement_error`, …) are resolved per job from
the **settings cascade** (`madi_results.calib_settings` via
`resolve_settings_batch`). A `params` value overrides the cascade for that one
job; otherwise the cascade supplies the default, seeded at a `__system__` tier so
a bare job (just `curve_ids`) fits correctly. See `DEPLOYMENT.md` §5 and §8.1.

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
curl -H "X-API-Key: $API_KEY" "http://localhost:8000/jobs?status=running&script_type=frequentist"
```

> Jobs are opaque `curve_id` batches and carry no scope descriptor, so listing
> filters on `status` and `script_type` only (study/experiment/antigen filters
> no longer exist).

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
doesn't take one. To add a script: write it (accept `--curve_ids` (comma-joined),
`--job_id`, `--progress_dir`, …; write `{progress_dir}/progress_{job_id}.json`
with `total_combos`/`completed_combos`; exit 0 on success), add one line to
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

## Data Sources & Masking

The worker reads its input from the **fit-delivery views**
`madi_results.standard_for_fit`, `blank_for_fit`, and `sample_for_fit`, filtered
by `curve_id = ANY(batch)`. These views do the work the worker used to do in R:
they attach `curve_id` and `multiplate_group_id` to every row, bake in the
standard-source grain (so a blank shared by N standard sources arrives as N rows,
one per `curve_id`), and carry `antigen`, `feature`, `source`, `mfi`, `masked`,
and `mask_reason`. The worker groups the delivered rows by `multiplate_group_id`
and fits each group — no NK slicing, curve_id resolution, or header joins remain
in R.

The `*_for_fit` views build on the **masked-aware** layer: each base `xmap_*`
table carries `masked boolean` + `mask_reason text`, and masked *sample* rows are
excluded while masked *standard/blank* rows are **kept and flagged** (`masked`
travels through to the worker, which sets each row's `included` flag from it —
masked points are persisted but never handed to the fitter). The masking rule
lives entirely in the view/DB definitions — the worker needs no masking logic.
Results are written to `madi_results.calib_*` (a `method` column distinguishes
`bayesian`/`frequentist`). See `DEPLOYMENT.md` §8 for the full table/view map and
the authoritative column list (`db_schema.csv`).

**Settings via the cascade.** Analysis settings are not baked into the worker and
are not read from a single settings table. The worker resolves them per job from
`madi_results.calib_settings` through `resolve_settings_batch(curve_ids)` (a
sparse, tiered key/value store: project → study → experiment → feature → antigen,
with a `__system__` default seed). A `params`/CLI value overrides the resolved
value for that job. Definitions and editor-render metadata live in
`calib_settings_meta`. This replaces the earlier per-table reads and the worker's
hardcoded log/prozone fixtures. See `DEPLOYMENT.md` §8.1.

## Deployment

Deploys to Kubernetes (namespace `madi-preprod`) as a **parallel** stack that
does not collide with the existing production batch calculator.

- **`i-spi-compute.k8s.yaml`** — Deployments + Services for redis/api, Deployment
  for worker, tailored to the cluster (own `i-spi-compute` secret, reused
  `madi-lumi-reader/db_pwd_x`, `/i-spi-compute` route, amd64 nodeSelector,
  `WORKER_CORES` ↔ CPU-limit coupling).
- **`DEPLOYMENT.md`** — the full deployment & configuration reference (env-var
  tables, runbook, manifest templates).
- **`SECRETS.md`** — generating and wiring `API_KEY`, `DB_PASSWORD`, `REDIS_AUTH`;
  Docker Compose `.env` and the cluster **Sealed Secrets** (`kubeseal`) workflow.

Deploy sequence:

1. **Seal the secret.** Create the `i-spi-compute` Secret (`API_KEY` +
   `REDIS_AUTH`) and encrypt it with `kubeseal` into a `SealedSecret` — the
   plaintext is never committed. See `SECRETS.md` (Sealed Secrets workflow).
2. **Images.** Confirm CI pushed
   `ghcr.io/immunoplex/i-spi-compute-{api,worker}:main` (Actions tab).
3. **Apply the manifest** (committed to `dartmouth/k8s-madi/.../preprod-rcikube6`):
   `kubectl apply -f i-spi-compute.k8s.yaml`.
4. **Traefik ingress.** Add the `i-spi-compute` Ingress + `i-spi-compute-stripprefix`
   middleware so the API is reachable at `https://<host>/i-spi-compute/…`; reload
   Traefik. See `DEPLOYMENT.md` §14.
5. **Smoke test** a `frequentist` then a `bayesian` job (via the ingress URL, or
   `kubectl port-forward svc/i-spi-compute-api 8000:8000` before the route is live).

Full detail: `DEPLOYMENT.md` §12 (runbook), §14 (ingress); `SECRETS.md` (secrets).

## Environment Variables

| Variable | Used By | Description |
|----------|---------|-------------|
| `API_KEY` | api | API authentication key (clients send it as `X-API-Key`) |
| `ROOT_PATH` | api | Reverse-proxy path prefix (matches Traefik ingress, `/i-spi-compute`) |
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
