# Immunoplex Batch Calculator — Deployment & Configuration Reference

> **Purpose of this document.** It is the single source of truth for how the
> Batch Calculator is built, configured, and deployed. It is written to be
> **machine-readable**: an LLM (or engineer) should be able to read this file
> plus the referenced source files and generate complete, environment-specific
> deployment documentation and manifests (docker-compose, Kubernetes, Helm) for a
> **new distribution** with no additional context. Sections 6 (environment
> variables), 12 (new-distribution checklist), and the manifest skeletons are the
> primary inputs for that generation task. Wherever a value must be supplied per
> environment it is written as `<PLACEHOLDER>`.

---

## 1. System overview

The Batch Calculator fits immunoassay standard curves (Bayesian **and**
frequentist) and back-calculates sample concentrations, writing results to
PostgreSQL. It is a queue-worker system with four runtime components plus an
external database.

```
  i-SPI app ──HTTP──▶  API (FastAPI)  ──RPUSH──▶  Redis queue
                                                     │ BLPOP
                                                     ▼
                                        Worker container
                                     ┌───────────────────────────┐
                                     │ supervisor.py (Python)     │
                                     │   └─spawns Rscript─────────┐│
                                     │        worker_curveR.R  (R)││
                                     │        + flatten_and_save.R││
                                     │        + verify_saved.R    ││
                                     └───────────────────────────┘│
                                                     │ DBI/RPostgres
                                                     ▼
                                        PostgreSQL (madi_results.calib_*)
```

**Flow:** the API validates a job request, writes a job hash to Redis, and
pushes the `job_id` onto the queue. A worker's supervisor `BLPOP`s the id, reads
the hash, resolves `script_type` → worker script + `--method`, spawns the R
worker with CLI args, polls the R-written progress file, mirrors progress into
the Redis job hash, and marks the job `completed`/`failed`. The R worker reads
assay data from PostgreSQL, fits curves, and writes results to the `calib_*`
tables. Nothing is written to disk as a result artifact.

---

## 2. Components

| Component | Language / base | Role | Scales by |
| --- | --- | --- | --- |
| **i-spi-compute-api** | Python 3.11 (FastAPI + uvicorn) | Accept/validate jobs, enqueue, expose status | replicas (stateless) |
| **i-spi-compute-redis** | Redis 7 (stock upstream image) | Job queue + job state (hashes, sorted-set index) | single instance (or managed) |
| **i-spi-compute-worker** | `rocker/tidyverse` + Python venv | Supervisor loop + R curve-fitting engine | replicas (each pops one job at a time) |
| **PostgreSQL** | External (not built here) | Assay input data + `calib_*` results | managed externally |

`i-spi-compute-redis` is a **service name over the stock `redis:7` image** (not a
repo you build). The **api** and **worker** are the images you build. `i-spi` (the
Shiny front end this tier serves) and PostgreSQL are external.

> **Naming convention.** `curveR` = the science (R packages, versioned
> independently). `i-spi-compute` = this application tier (`-api`, `-worker`,
> `-redis`). `i-spi` = the front end it serves. The prefix marks what is
> developed and deployed together.

> **Target cluster & isolation (observed).** Deploys to namespace
> `madi-preprod`, registry `ghcr.io/immunoplex`, image pull secret `regcred`.
> A **production** batch calculator already runs there
> (`immunoplex-batch-cal-api/-worker`, `redis-batch-cal`, secret
> `immunoplex-batch-cal`) plus a separate general `redis` (secret `madi`). The
> `i-spi-compute-*` names and the dedicated secret `i-spi-compute` keep the new
> stack from sharing a Redis queue with the running production stack. Concrete
> manifests: **`i-spi-compute.k8s.yaml`**.

---

## 3. Repositories & artifacts

**API repo** (`i-spi-compute-api`) → image `ghcr.io/immunoplex/i-spi-compute-api`:
- `app.py` — FastAPI application (endpoints, job schema, Redis writes).
- `requirements.txt` — `fastapi`, `uvicorn[standard]`, `redis`, `pydantic`.
- `Dockerfile` — `python:3.11-slim`, installs deps, runs uvicorn on `:8000`.

**Worker repo** (`i-spi-compute-worker`) → image `ghcr.io/immunoplex/i-spi-compute-worker`:
- `supervisor.py` — queue consumer + process supervisor + progress sync.
- `worker_curveR.R` — the R entry point (CLI). **Sources two siblings at runtime.**
- `flatten_and_save.R` — result flattener + idempotent DB writer. **Sibling; must be co-located.**
- `verify_saved.R` — post-save verifier. **Sibling; must be co-located.**
- `entrypoint.sh` — verifies the curveR stack (`curveRcore`/`curveRfreq`/`curveRbayes`) and CmdStan are importable, prints versions, then `exec`s the supervisor. Supports an optional `/curveRbayes` dev mount for reinstall-on-startup.
- `requirements.txt` — `redis`.
- `Dockerfile` — `rocker/tidyverse` + curveR + CmdStan (see §7).
- `calib_schema_v1.sql` — one-time DB migration (see §8). Not baked into the image.

**External R packages** (installed at worker image build time from GitHub):
`immunoplex/curveR` (meta-package pulling `curveRcore`, `curveRfreq`,
`curveRbayes`, `curveRweights`). The Bayesian engine requires **CmdStan** via
`cmdstanr`.

---

## 4. Job contract (API)

### 4.1 Endpoints

| Method | Path | Auth | Purpose |
| --- | --- | --- | --- |
| `POST` | `/jobs` | yes | Submit a job (returns `JobStatus`, 201) |
| `GET` | `/jobs` | yes | List jobs (filters: `study`, `status`, `script_type`, `limit`, `offset`) |
| `GET` | `/jobs/{job_id}` | yes | Get one job's status |
| `DELETE` | `/jobs/{job_id}` | yes | Cancel a queued/running job |
| `GET` | `/health` | no | Liveness + Redis ping |

**Auth:** `X-API-Key` header on every endpoint except `/health`, compared
against the `API_KEY` env var. If `API_KEY` is unset the API logs a warning and
uses `dev-key-immunoplex` — **never rely on this in production.**

### 4.2 `POST /jobs` request body

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `project_id` | int | yes | Workspace/project id (same study name can exist in multiple workspaces) |
| `study` | str | yes | Study accession |
| `experiment` | str | if `scope` ∈ {experiment, antigen} | Experiment accession |
| `antigen` | str | if `scope` = antigen | Antigen name |
| `source` | str | no | Standard-source filter |
| `scope` | str | no (default `study`) | `study` \| `experiment` \| `antigen` |
| `script_type` | str | no (default `bayesian`) | **`bayesian` \| `frequentist`** — selects the fitting engine |
| `params` | dict | no | Passthrough → each key becomes `--key value` on the worker CLI |
| `cdan_cv_threshold` | float | no (default `20.0`) | Shorthand; merged into `params.cdan_cv` for bayesian |

### 4.3 How `script_type` and `params` reach the engine

- `script_type` is the **engine selector**. The supervisor maps it via
  `SCRIPT_REGISTRY` to `(interpreter, worker_curveR.R, method_flag)` and passes
  `--method <method_flag>` to the worker. Both `bayesian` and `frequentist` run
  the **same** `worker_curveR.R`.
- `params` is a generic passthrough: the supervisor emits `--<key> <value>` for
  each entry. Unknown keys are ignored by the worker. This is the channel for
  engine-tuning knobs **without any API change**, e.g.:
  - `{"models": "logistic4,gompertz4"}` → `--models logistic4,gompertz4`
  - `{"chains": "4", "warmup": "1000", "sampling": "1000"}` (bayesian Stan settings)
  - `{"cdan_cv": 25}` (CV%% gate; also settable via `cdan_cv_threshold`)

### 4.4 Redis keys

| Key | Type | Contents |
| --- | --- | --- |
| `ispi:batch:queue` | list | FIFO of `job_id`s awaiting a worker (`RPUSH`/`BLPOP`) |
| `ispi:job:{job_id}` | hash | Full job state (status, progress, timing, params, error) |
| `ispi:jobs` | zset | All `job_id`s scored by `created_at` (newest-first listing) |

---

## 5. Worker CLI contract

`worker_curveR.R` accepts these flags (defaults in parentheses). The supervisor
supplies the common set; `params` supplies the rest.

| Flag | Default | Notes |
| --- | --- | --- |
| `--study` | `""` | required |
| `--scope` | `study` | `study`\|`experiment`\|`antigen` |
| `--experiment` | `""` | required for experiment/antigen scope |
| `--antigen` | `""` | required for antigen scope |
| `--source` | `""` | optional standard-source filter |
| `--project_id` | `NA` | required |
| `--cdan_cv` | `20` | CV%% gate → `pcov_threshold` |
| `--job_id` | `local` | progress file + Redis key suffix |
| `--progress_dir` | tempdir | where `progress_<job_id>.json` is written |
| `--output_dir` | tempdir | **legacy/ignored** — results go to the DB |
| `--method` | `bayesian` | `bayesian`\|`frequentist` |
| `--models` | `""` | CSV; empty → engine default `logistic4,logistic5,gompertz4` |
| `--chains` / `--warmup` / `--sampling` | `4` / `1000` / `1000` | bayesian Stan sampling |
| `--adapt_delta` | `0.9` | bayesian |
| `--seed` | `""` | optional |

**Sibling requirement (critical):** `worker_curveR.R` `source()`s
`flatten_and_save.R` and `verify_saved.R` from its own directory at startup and
**aborts if they are missing**. They must be copied into the same directory
(`/app`) in the image. An optional `WORKER_COMPONENTS_DIR` env can override the
search directory.

**Progress file:** the worker writes `progress_<job_id>.json` to `--progress_dir`
with keys `job_id, total_combos, completed_combos, percentage, status,
current_experiment, current_group, updated_at`. The supervisor polls this every
`PROGRESS_POLL_INTERVAL` (5 s) and mirrors it into the Redis job hash, adding
`elapsed_minutes`, `eta_minutes`, `eta_display`, `speed_seconds_per_combo`.

---

## 6. Environment variables (authoritative reference)

> This is the primary input for generating per-environment config. `Secret? =
> yes` means it must come from a secret store, never an image layer.
>
> **`REDIS_HOST` for this stack must be `i-spi-compute-redis`** (the dedicated
> Redis Service), *not* the code default `redis` — otherwise the new stack could
> resolve to the wrong Redis and share a queue with the production batch
> calculator. Set it explicitly on both the api and worker.

### 6.1 API

| Variable | Default | Required | Secret? | Meaning |
| --- | --- | --- | --- | --- |
| `API_KEY` | (dev key) | **prod: yes** | yes | Value clients must send in `X-API-Key` |
| `REDIS_HOST` | `redis` | yes | no | Redis hostname |
| `REDIS_PORT` | `6379` | no | no | Redis port |
| `REDIS_AUTH` | `""` | if Redis authed | yes | Redis password |
| `REDIS_DB` | `0` | no | no | Redis logical DB |
| `ROOT_PATH` | `""` | no | no | FastAPI root path (reverse-proxy prefix) |
| `PORT` | `8000` | no | no | uvicorn port (only honored in `__main__`) |

### 6.2 Worker (supervisor + R)

| Variable | Default | Required | Secret? | Meaning |
| --- | --- | --- | --- | --- |
| `REDIS_HOST` | `redis` | yes | no | Redis hostname |
| `REDIS_PORT` | `6379` | no | no | Redis port |
| `REDIS_AUTH` | `""` | if Redis authed | yes | Redis password |
| `REDIS_DB` | `0` | no | no | Redis logical DB |
| `DB_NAME` | `local_madi_ispi` | yes | no | PostgreSQL database |
| `DB_HOST` | `localhost` | yes | no | PostgreSQL host |
| `DB_PORT` | `5432` | no | no | PostgreSQL port |
| `DB_USER` | `postgres` | yes | no | PostgreSQL user |
| `DB_PASSWORD` | (unset) | yes | **yes** | PostgreSQL password |
| `DB_SSLMODE` | `disable` | prod: `require` | no | libpq sslmode |
| `PROGRESS_DIR` | `/tmp` | no | no | Progress-file directory (shared conceptually between R and supervisor) |
| `OUTPUT_DIR` | `/data/calib` | no | no | **Legacy/ignored** by the curveR worker |
| `WORKER_CORES` | (unset) | **under CPU limits: yes** | no | Hard cap on cores. Caps R `mc.cores` **and** Stan `parallel_chains`. Set to the container's CPU limit. See §9.2 |
| `CMDSTAN` | `/opt/cmdstan/current` | set in image | no | CmdStan install path (symlink set at build) |
| `WORKER_COMPONENTS_DIR` | (unset) | no | no | Override directory for the sibling `.R` files |

> `PROGRESS_DIR` must resolve to the **same path** for the R worker and the
> supervisor (they run in the same container, so the default `/tmp` is fine).

---

## 7. Build

### 7.1 Worker image (see `worker.Dockerfile`)

Ordered stages and why they matter:

1. **System deps** — `libpq-dev` (RPostgres), `build-essential`/`g++`/`make`
   (CmdStan compiles Stan models to C++), `git`/`ca-certificates`
   (`remotes::install_github`), `python3`/`venv`.
2. **Python venv** — installs `redis` for the supervisor.
3. **R base deps** — `remotes, DBI, RPostgres, jsonlite, loo, R6`.
4. **CmdStan first** — install `cmdstanr` from the Stan R-universe, then
   `install_cmdstan()` into `/opt/cmdstan`, then symlink `current` →
   `cmdstan-<version>` and set `ENV CMDSTAN=/opt/cmdstan/current`. Installing
   CmdStan **before** curveRbayes lets its Stan models build.
5. **curveR ecosystem** — `remotes::install_github('immunoplex/curveR')`.
6. **Precompile Stan models** — compile curveRbayes's bundled `.stan` files into
   an image layer so containers start with "Model executable is up to date!"
   instead of compiling on first job. Best-effort (`try()`-guarded).
7. **Copy scripts** — `supervisor.py`, `entrypoint.sh`, and the **three
   co-located** R files (`worker_curveR.R`, `flatten_and_save.R`,
   `verify_saved.R`) into `/app`.

Build cost is dominated by CmdStan install + model precompile (several minutes),
but it caches; rebuilds that only change scripts are fast.

### 7.2 API image

`python:3.11-slim`, `pip install -r requirements.txt`, copy `app.py`, run
`uvicorn app:app --host 0.0.0.0 --port 8000`. No special build concerns.

---

## 8. Database

**Schema:** all objects live in the `madi_results` schema. The worker sets
`search_path=madi_results` on connect.

**One-time migration (out of band, before first run):** apply
`calib_schema_v1.sql`. It is **non-destructive** — it creates only the new
`calib_*` tables and touches nothing in the legacy `bayes_*` tables.

**Result tables written by the worker** (`method` column distinguishes
`bayesian`/`frequentist`; writes are idempotent — delete-by-`(curve_id, method)`
then insert):
`calib_run`, `calib_fit`, `calib_param`, `calib_gate`, `calib_grid`,
`calib_samples`, `calib_diagnostics`, `calib_loo` (bayesian only).

**`curve_lookup` (read-only contract):** the worker **never writes**
`curve_lookup`. It resolves `curve_id` by joining on the natural key. Standards
match on the full 10-column NK; **samples match on the NK minus `source`**
(patient wells carry no standard source) — this is load-bearing and must not be
"simplified" back to the full key. If a curve does not resolve, the worker errors
rather than inventing a row.

**Legacy `bayes_*`:** written by the old stanassay worker. The curveR worker does
**not** write them. They can coexist during parallel-run/validation and be
retired after read-side cutover.

**Database privileges the worker needs:**
- `SELECT` on `madi_results.curve_lookup`, `xmap_standard`, `xmap_sample`,
  `xmap_buffer`, `xmap_header`, `xmap_antigen_family` (input data).
- `INSERT`, `DELETE`, `SELECT` on all `madi_results.calib_*` tables.

---

## 9. Runtime & scaling

### 9.1 Queue semantics

- One worker processes **one job at a time** (blocking `BLPOP` → run → repeat).
- Horizontal scale = **more worker replicas**, each independently popping the
  queue. No coordination needed.
- Delivery is **at-least-once**: a job is popped off the list before it runs, so
  if a worker dies mid-job the job is lost from the queue (status stays
  `running`). For stricter guarantees, add a reliable-queue pattern
  (`BLMOVE` to a processing list) — not currently implemented.

### 9.2 CPU limits (`WORKER_CORES`) — required under limits

`parallel::detectCores()` is **not cgroup-aware** and reports host cores, so
under a Kubernetes/Docker CPU limit the worker would oversubscribe. The worker
therefore honors **`WORKER_CORES`** when set, using it for `options(mc.cores)`.
Because cmdstanr's `$sample()` defaults `parallel_chains = getOption("mc.cores")`,
this single value **also caps Stan's parallel chains**.

**Rule:** set `WORKER_CORES` equal to the container's CPU limit (integer). E.g. a
pod with `resources.limits.cpu: "4"` → `WORKER_CORES=4`. Leaving it unset falls
back to `detectCores()` and will oversubscribe under a limit.

Chains beyond `WORKER_CORES` run in additional waves (e.g. 4 chains, 2 cores →
two sequential pairs), trading wall-clock for CPU compliance.

### 9.3 Memory

Bayesian fits hold posterior draws in memory; size the container for the largest
study's per-family draw matrices. Frequentist fits are lightweight. Start with
2–4 GiB per worker for Bayesian and adjust from observed usage.

### 9.4 Cancellation & shutdown

- `DELETE /jobs/{id}` sets `status=cancelled`; the supervisor polls the hash each
  interval and terminates the R process if a running job is cancelled.
- `SIGTERM`/`SIGINT` → graceful shutdown: the supervisor terminates the child and
  marks the job `cancelled`. Give pods a termination grace period ≥ the poll
  interval.

---

## 10. Health & observability

- **Liveness:** `GET /health` (API) pings Redis. Workers have no HTTP port; use a
  process/exec probe or Redis-connectivity check.
- **Per-job state:** the `ispi:job:{id}` hash carries `status`, `progress`,
  `percentage`, timing, `current_experiment`, `error` (tail of R output on
  failure), and `output_path` (now `madi_results.calib_* (job_id=…)`).
- **Logs:** the supervisor streams the R process stdout/stderr line-by-line with
  an `[R]` prefix to container stdout, and keeps the last 200 lines for the
  failure `error` field.

---

## 11. Secrets & configuration management

> **How-to:** for step-by-step instructions to generate and wire these secrets,
> see **[`SECRETS.md`](./SECRETS.md)**. In the cluster this uses **Sealed
> Secrets** (`kubeseal`): the plaintext `Secret` is never committed; an encrypted
> `SealedSecret` is committed to `k8s-madi` and the in-cluster controller
> decrypts it into the real `i-spi-compute` Secret. `.env.example` covers the
> Docker Compose case.

Provide as secrets (never in the image or committed config): `API_KEY`,
`DB_PASSWORD`, `REDIS_AUTH` (if used). Everything else in §6 is plain config.
Rotate `API_KEY` and DB credentials per your policy; both components read them
from the environment at process start.

Two correctness notes that `SECRETS.md` covers in full: `DB_PASSWORD` must
**match** the password PostgreSQL already expects for `DB_USER` (the secret does
not set it), and `REDIS_AUTH` must be the **same value** in three places — the
Redis `--requirepass`, the API, and the worker — or it protects nothing.

---

## 12. Deploying to a NEW distribution — checklist for doc/manifest generation

> An LLM generating deployment docs for a new environment should (a) fill the
> parameter table, (b) emit the manifests from the skeletons in §13 with those
> values substituted, and (c) reproduce the ordered runbook below.

### 12.1 Parameters to supply per environment

| Placeholder | Example | Used by |
| --- | --- | --- |
| `<IMAGE_REGISTRY>` | `ghcr.io/immunoplex` | image refs |
| `<API_IMAGE_TAG>` / `<WORKER_IMAGE_TAG>` | `:v0.3.0` | image refs |
| `<DB_HOST>` / `<DB_PORT>` / `<DB_NAME>` | `mlr-c3d7-db…` / `5432` / `postgres` | worker |
| `<DB_USER>` / `<DB_PASSWORD>` | (secret) | worker |
| `<DB_SSLMODE>` | `require` | worker |
| `<REDIS_HOST>` / `<REDIS_PORT>` / `<REDIS_AUTH>` | `redis` / `6379` / (secret) | api + worker |
| `<API_KEY>` | (secret) | api |
| `<WORKER_CPU_LIMIT>` → `<WORKER_CORES>` | `4` → `4` | worker (must match) |
| `<WORKER_MEM_LIMIT>` | `4Gi` | worker |
| `<WORKER_REPLICAS>` | `2` | worker |
| `<API_REPLICAS>` | `2` | api |
| `<ROOT_PATH>` | `/batch` | api (if behind a path-prefixed proxy) |

### 12.2 Ordered runbook

1. **Provision PostgreSQL** (or confirm existing) and apply `calib_schema_v1.sql`
   once. Grant the worker the privileges in §8.
2. **Provision Redis** (single instance or managed). Note host/port/auth.
3. **Build & push images:** worker (`worker.Dockerfile`) and API. Tag and push to
   `<IMAGE_REGISTRY>`.
4. **Create secrets:** `API_KEY`, `DB_PASSWORD`, `REDIS_AUTH` — follow
   [`SECRETS.md`](./SECRETS.md) (generation, `.env`/Kubernetes wiring, and the
   Redis-auth-in-three-places rule).
5. **Deploy API** with §6.1 env; expose `:8000` (behind your ingress/proxy).
6. **Deploy Worker(s)** with §6.2 env, **`WORKER_CORES` = CPU limit**, memory
   limit, and `<WORKER_REPLICAS>`.
7. **Smoke test through the real queue:**
   - `GET /health` → `{status: ok, redis: connected}`.
   - `POST /jobs` with `script_type: "frequentist"` on a small antigen scope
     (fast, no Stan) → poll `GET /jobs/{id}` to `completed`; confirm `calib_*`
     rows for that curve.
   - `POST /jobs` with `script_type: "bayesian"` → confirm completion and
     `calib_loo` rows.
8. **Validate** against legacy with the parity check before switching readers.
9. **Cut over the read side** (i-SPI) from `bayes_*` to `calib_*`.

---

## 13. Manifest skeletons (templates)

### 13.1 docker-compose (dev/single-host)

```yaml
services:
  i-spi-compute-redis:
    image: redis:7
    command: ["redis-server", "--requirepass", "${REDIS_AUTH}"]  # enables auth
  i-spi-compute-api:
    image: <IMAGE_REGISTRY>/i-spi-compute-api<API_IMAGE_TAG>
    environment:
      API_KEY: ${API_KEY}
      REDIS_HOST: i-spi-compute-redis
      REDIS_PORT: "6379"
      REDIS_AUTH: ${REDIS_AUTH}
    ports: ["8000:8000"]
    depends_on: [i-spi-compute-redis]
  i-spi-compute-worker:
    image: <IMAGE_REGISTRY>/i-spi-compute-worker<WORKER_IMAGE_TAG>
    environment:
      REDIS_HOST: i-spi-compute-redis
      REDIS_AUTH: ${REDIS_AUTH}
      DB_HOST: <DB_HOST>
      DB_PORT: "<DB_PORT>"
      DB_NAME: <DB_NAME>
      DB_USER: <DB_USER>
      DB_PASSWORD: ${DB_PASSWORD}
      DB_SSLMODE: <DB_SSLMODE>
      WORKER_CORES: "<WORKER_CORES>"
    deploy:
      resources:
        limits: { cpus: "<WORKER_CPU_LIMIT>", memory: <WORKER_MEM_LIMIT> }
    depends_on: [i-spi-compute-redis]
```

### 13.2 Kubernetes

Full, cluster-tailored manifests are in **`i-spi-compute.k8s.yaml`** (namespace
`madi-preprod`, `ghcr.io/immunoplex` images, `regcred` pull secret): Deployments
+ Services for `i-spi-compute-redis` and `i-spi-compute-api`, and a Deployment
for `i-spi-compute-worker`. The load-bearing details encoded there:

- **Isolation:** dedicated `i-spi-compute-redis` Service + its own `i-spi-compute`
  secret, so the new stack never shares the production `redis-batch-cal` queue.
- **Secrets split:** `API_KEY`/`REDIS_AUTH` from the new `i-spi-compute` secret;
  `DB_PASSWORD` reused from the existing `madi-lumi-reader/db_pwd_x` (same DB user).
- **CPU cap:** `WORKER_CORES` set equal to the worker's CPU limit.
- **Arch pin:** worker `nodeSelector: kubernetes.io/arch: amd64` (Stan models are
  precompiled for amd64).
- **Route:** `ROOT_PATH=/i-spi-compute`, distinct from the prod `/batch-api`, so a
  Traefik route can expose the new API in parallel until i-spi cuts over.

Create the secret first (see `SECRETS.md`), then `kubectl apply -f
i-spi-compute.k8s.yaml`.

---

## 14. Ingress / external access (Traefik)

The Kubernetes Service `i-spi-compute-api` is reachable **inside** the cluster,
but external clients (and i-spi) reach it only through Traefik. Traefik does not
auto-discover the Service — it needs an `Ingress` plus a **strip-prefix
middleware** so the path prefix used externally is removed before the request
hits the API. This mirrors how the production `/batch-api` route works, on a
distinct path so the two run in parallel.

**Path:** external `https://<host>/i-spi-compute/...` → strip `/i-spi-compute`
→ `i-spi-compute-api:8000`. The API's `ROOT_PATH` is set to `/i-spi-compute` in
the manifest to match this external prefix, so Swagger and redirect URLs resolve
correctly behind the strip-prefix middleware.

Three pieces, all in the `dartmouth/k8s-madi` config repo:

**1. Ingress** — appended to `i-spi-compute.k8s.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: i-spi-compute
  namespace: madi-preprod
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: i-spi-compute-stripprefix@file
spec:
  rules:
    - http:
        paths:
          - pathType: Prefix
            path: /i-spi-compute
            backend:
              service:
                name: i-spi-compute-api
                port:
                  number: 8000
```

**2. Strip-prefix middleware** — added to the cluster's static Traefik config
(`k8s-madi/.../preprod-rcikube6/traefik.yml`). The `@file` provider suffix in the
annotation above points at a middleware defined in that file:

```yaml
i-spi-compute-stripprefix:
  stripPrefix:
    prefixes:
      - /i-spi-compute
    forceSlash: false
```

**3. Apply + reload.** Commit `i-spi-compute.k8s.yaml` (with the Ingress) and the
`traefik.yml` change to `k8s-madi/.../preprod-rcikube6`. Because the middleware
lives in Traefik's **static** file config, Traefik must reload to pick it up — in
Rancher, delete and recreate the Traefik pod. The dynamic `Ingress` is picked up
automatically once applied.

**Verify:**

```bash
kubectl -n madi-preprod get ingress i-spi-compute
curl https://<host>/i-spi-compute/health          # {"status":"ok","redis":"connected"}
```

Until the Ingress + middleware are live, test with a port-forward instead:
`kubectl -n madi-preprod port-forward svc/i-spi-compute-api 8000:8000`.

## 15. Version & compatibility notes

- **Base image:** `rocker/tidyverse:latest` (Debian + R). Pin to a dated tag for
  reproducibility in production.
- **CmdStan:** installed via `cmdstanr::install_cmdstan()`; the image sets
  `CMDSTAN=/opt/cmdstan/current`. Consider pinning a CmdStan version for
  reproducible builds.
- **curveR packages:** installed from `immunoplex/curveR` at build time; pin to a
  release/commit for reproducibility.
- **`detectCores()` caveat:** see §9.2 — always set `WORKER_CORES` under CPU
  limits.

---

## 16. Known assumptions & open items

- `entrypoint.sh` verifies the curveR stack + CmdStan and `exec`s
  `supervisor.py`. It replaces the old stanassay entrypoint (which hard-failed on
  a missing `stanassay` package). A `/curveRbayes` bind-mount triggers
  reinstall-on-startup for dev iteration.
- The Stan-model precompile uses curveRbayes' exported `compile_stan_model()`
  over all five shipped families (`logistic4`, `logistic5`, `loglogistic4`,
  `loglogistic5`, `gompertz4`). Models live in `inst/stan/` in source →
  `stan/` in the installed package. Note `loglogistic4` is auto-dropped from the
  candidate set when both axes are log-transformed (it equals `logistic4`).
- Read-side migration (i-SPI reading `calib_*` instead of `bayes_*`) is a
  separate workstream and is **not** covered by this worker/API deployment.
- Reliable-queue delivery (surviving mid-job worker death) is not implemented;
  see §9.1 if stronger guarantees are required.
