# Secrets Setup — API_KEY, DB_PASSWORD, REDIS_AUTH

A basic, do-this-in-order guide to creating the three secrets and wiring them in
correctly. Two paths are shown: **Docker Compose** (simplest, dev/single-host)
and **Kubernetes** (production). Do the Compose path first if you're unsure.

## What the three secrets are

| Secret | Who reads it | What it protects | Must match… |
| --- | --- | --- | --- |
| `API_KEY` | the **API** | Who can submit/list/cancel jobs (sent as `X-API-Key`) | the value your i-SPI client sends |
| `DB_PASSWORD` | the **worker** | The PostgreSQL login | the password of `DB_USER` **in PostgreSQL** |
| `REDIS_AUTH` | the **API and worker** | The Redis queue | the `requirepass` you set **on Redis** |

Two things people get wrong, so note them up front:
- `DB_PASSWORD` must be the password the database **already expects** for `DB_USER`. This secret doesn't *set* the DB password; it must match it.
- `REDIS_AUTH` does nothing unless Redis is **started with the same password** (`--requirepass`). Set it in both places or neither.

---

## Step 1 — Generate strong values

Run this **three times** (once per secret) and keep the outputs somewhere safe
for a moment. Hex is used because it has no special characters that could break a
connection string, URL, or shell.

**Linux / macOS / Git Bash on Windows:**
```bash
openssl rand -hex 32
```

**If you don't have openssl but have Python:**
```bash
python -c "import secrets; print(secrets.token_hex(32))"
```

Each gives a 64-character value like `9f2a…c1`. Generate a **different** value
for each of the three secrets. Never reuse, never use a dictionary word.

---

## Step 2 (Docker Compose) — Put them in a `.env` file

1. In the same folder as your `docker-compose.yml`, create a file named `.env`:

   ```dotenv
   API_KEY=<paste first generated value>
   DB_PASSWORD=<paste second generated value>
   REDIS_AUTH=<paste third generated value>
   ```

2. **Never commit it.** Add these lines to `.gitignore`:
   ```gitignore
   .env
   *.env
   ```

3. Lock down file permissions (Linux/macOS):
   ```bash
   chmod 600 .env
   ```

There is a ready-to-copy template in `.env.example` — copy it to `.env` and fill
in real values:
```bash
cp .env.example .env
```

---

## Step 3 (Docker Compose) — Wire them into services

Docker Compose automatically reads `.env` and substitutes `${VAR}` in the compose
file. Reference the secrets like this (only the relevant lines shown):

```yaml
services:
  i-spi-compute-redis:
    image: redis:7
    command: ["redis-server", "--requirepass", "${REDIS_AUTH}"]   # <-- enables Redis auth

  i-spi-compute-api:
    environment:
      API_KEY: "${API_KEY}"
      REDIS_HOST: i-spi-compute-redis
      REDIS_AUTH: "${REDIS_AUTH}"     # API must authenticate to Redis

  i-spi-compute-worker:
    environment:
      DB_PASSWORD: "${DB_PASSWORD}"
      REDIS_HOST: i-spi-compute-redis
      REDIS_AUTH: "${REDIS_AUTH}"     # worker must authenticate to Redis
```

Key point: `REDIS_AUTH` appears in **three** places — the Redis `--requirepass`,
the API, and the worker — and all three must be the **same value**. `API_KEY`
goes only to the API. `DB_PASSWORD` goes only to the worker.

Bring it up:
```bash
docker compose up -d
```

---

## Step 4 — Verify it works

1. **Redis auth is on and the API can reach it:**
   ```bash
   curl http://localhost:8000/health
   # expect: {"status":"ok","redis":"connected"}
   ```
   If Redis auth is misconfigured, `/health` returns 503.

2. **The API_KEY is enforced** (wrong/missing key is rejected):
   ```bash
   curl -i http://localhost:8000/jobs           # no key  -> 401
   curl -i -H "X-API-Key: wrong" http://localhost:8000/jobs   # bad key -> 403
   curl -i -H "X-API-Key: <your API_KEY>" http://localhost:8000/jobs   # -> 200
   ```

3. **DB_PASSWORD is correct:** submit a tiny job and watch it reach `completed`
   (a DB-auth failure shows up as a failed job with a connection error in
   `error`):
   ```bash
   curl -X POST http://localhost:8000/jobs \
     -H "X-API-Key: <your API_KEY>" -H "Content-Type: application/json" \
     -d '{"project_id":17,"study":"<STUDY>","experiment":"<EXP>","antigen":"<ANTIGEN>","scope":"antigen","script_type":"frequentist"}'
   # then poll: curl -H "X-API-Key: <your API_KEY>" http://localhost:8000/jobs/<job_id>
   ```

---


## Kubernetes path (production — namespace `madi-preprod`, Sealed Secrets)

This cluster does **not** use plain `kubectl create secret`. Secret manifests are
committed to git, so the secret values must be **encrypted at rest** with
[Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets): you produce a
`SealedSecret` (safe to commit) with `kubeseal`, and the in-cluster
sealed-secrets controller decrypts it into a real `Secret` at apply time. You
never commit the plaintext `Secret`.

This stack gets its **own** secret named `i-spi-compute` (`API_KEY` +
`REDIS_AUTH`). The DB password is **not** included — the worker reuses the
existing `madi-lumi-reader/db_pwd_x` (same DB user `d78039e`).

### One-time: a shell with the tools

`kubeseal` (and `kubectl`) are needed. A throwaway Debian container works well:

```bash
docker run -it --rm debian bash
apt update && apt install -y kubectl wget

# kubeseal CLI (match the controller version installed in the cluster)
export KUBESEAL_VERSION="0.23.0"
wget -O kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz \
  "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
tar -xvzf kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz kubeseal
```

Save the cluster's sealed-secrets **public certificate** to `kubeseal.pem` (this
is the controller's public key — safe to share; it can only *encrypt*). Use the
`kubeseal.pem` for this cluster (the MADI preprod cert is kept with the ops
notes / k8s-madi repo):

```bash
cat > kubeseal.pem << 'EOF'
-----BEGIN CERTIFICATE-----
... (MADI preprod sealed-secrets public cert) ...
-----END CERTIFICATE-----
EOF
```

### Step 1 — Build the plaintext Secret manifest (not committed)

```bash
export SECRET_NAME=i-spi-compute
kubectl create secret generic $SECRET_NAME \
  --from-literal=API_KEY="$(openssl rand -hex 32)" \
  --from-literal=REDIS_AUTH="$(openssl rand -hex 32)" \
  --dry-run=client \
  -o yaml > secret.yml
```

`--dry-run=client -o yaml` means kubectl only *renders* the manifest locally —
it does **not** touch the cluster. `secret.yml` holds plaintext; do not commit it.

### Step 2 — Seal it

```bash
./kubeseal --scope cluster-wide --format=yaml --cert=kubeseal.pem < secret.yml > sealed-i-spi-compute.yaml
```

The output `sealed-i-spi-compute.yaml` is a `SealedSecret` — encrypted, **safe to
commit**. `--scope cluster-wide` lets the sealed secret be applied in the target
namespace without being pinned to a specific name+namespace hash (matches how
the other MADI secrets are sealed).

### Step 3 — Commit + apply

Commit the `SealedSecret` to the cluster config repo alongside the manifest
(`dartmouth/k8s-madi/.../preprod-rcikube6`). When applied, the controller
decrypts it into a real `Secret` named `i-spi-compute` in `madi-preprod`. Confirm:

```bash
kubectl -n madi-preprod get sealedsecret i-spi-compute
kubectl -n madi-preprod get secret       i-spi-compute        # created by the controller
kubectl -n madi-preprod describe secret   i-spi-compute        # keys API_KEY, REDIS_AUTH (sizes only)
```

The manifest references these keys exactly as before — `secretKeyRef` to
`i-spi-compute` for `API_KEY`/`REDIS_AUTH`, and to the existing
`madi-lumi-reader`/`db_pwd_x` for `DB_PASSWORD`:

```yaml
# i-spi-compute-api
- { name: API_KEY,    valueFrom: { secretKeyRef: { name: i-spi-compute, key: API_KEY } } }
- { name: REDIS_AUTH, valueFrom: { secretKeyRef: { name: i-spi-compute, key: REDIS_AUTH } } }
# i-spi-compute-worker
- { name: REDIS_AUTH,  valueFrom: { secretKeyRef: { name: i-spi-compute,    key: REDIS_AUTH } } }
- { name: DB_PASSWORD, valueFrom: { secretKeyRef: { name: madi-lumi-reader, key: db_pwd_x   } } }
```

### Rotating a value

Re-run Steps 1–3 with a new value and re-apply the `SealedSecret`; the controller
updates the `Secret`. Then restart the consumers so they pick it up:
`kubectl -n madi-preprod rollout restart deploy/i-spi-compute-api deploy/i-spi-compute-worker`
(and, for `REDIS_AUTH`, the redis deployment too — all three share the value).


## Rules of thumb

- **Never** put secret values in the Dockerfile, the compose file, git, or logs.
  Only in `.env` (gitignored) or a Kubernetes Secret.
- Use a **different** value for each secret.
- **Rotate** by generating a new value, updating `.env` / the Secret, and
  restarting the affected services (`docker compose up -d` or
  `kubectl rollout restart deployment/<name>`). For `REDIS_AUTH`, update Redis
  and both clients together so they don't get out of sync.
- If a secret ever lands in git history, rotate it — deleting the file is not
  enough.
