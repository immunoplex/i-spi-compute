"""
i-spi-compute — Worker Supervisor

Thin Python process that:
1. BLPOP on Redis queue (ispi:batch:queue)
2. Reads job metadata from Redis hash
3. Looks up script_type in SCRIPT_REGISTRY to find the right worker script
4. Spawns the script with common + script-specific CLI args
5. Monitors progress file written by the script
6. Updates job status in Redis (running → completed/failed)

A job is a **batch of curve_ids** (see HANDOFF_worker_curve_id_batch.md). The
supervisor forwards the batch to the worker via a single comma-joined
`--curve_ids` argument (and optional `--multiplate_group_ids`); it does not
resolve or understand scope.

This runs as the main process in the worker container.
"""

import os
import sys
import json
import time
import signal
import logging
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import redis

# ── Logging ──────────────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("i_spi_compute_worker")

# ── Config ───────────────────────────────────────────────────────────────────

REDIS_HOST = os.getenv("REDIS_HOST", "redis")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))
REDIS_AUTH = os.getenv("REDIS_AUTH", "")
REDIS_DB = int(os.getenv("REDIS_DB", "0"))

QUEUE_KEY = "ispi:batch:queue"
JOB_PREFIX = "ispi:job:"

PROGRESS_DIR = Path(os.getenv("PROGRESS_DIR", "/tmp"))

# ── Script Registry ───────────────────────────────────────────────────────
# Maps script_type → (interpreter, script_path, method_flag).
# Both "bayesian" and "frequentist" run the SINGLE curveR worker; they differ
# only in the --method flag passed to it. method_flag=None means "don't pass
# --method" (for a future non-curve script, e.g. a QC report).
# To add a new calculation: drop the script here and add a line.
SCRIPTS_DIR = Path(__file__).parent
SCRIPT_REGISTRY = {
    "bayesian":    ("Rscript", SCRIPTS_DIR / "worker_curveR.R", "bayesian"),
    "frequentist": ("Rscript", SCRIPTS_DIR / "worker_curveR.R", "frequentist"),
    # "qc_report": ("python3", SCRIPTS_DIR / "worker_qc.py", None),
}

# How often (seconds) to poll the progress file while R is running
PROGRESS_POLL_INTERVAL = 5

# ── Globals for graceful shutdown ────────────────────────────────────────────

_shutdown = False
_current_proc = None


def _handle_signal(signum, frame):
    global _shutdown
    logger.info("Received signal %s, shutting down gracefully...", signum)
    _shutdown = True
    if _current_proc and _current_proc.poll() is None:
        logger.info("Terminating running Rscript (pid=%d)...", _current_proc.pid)
        _current_proc.terminate()


signal.signal(signal.SIGTERM, _handle_signal)
signal.signal(signal.SIGINT, _handle_signal)

# ── Redis ────────────────────────────────────────────────────────────────────


def get_redis() -> redis.Redis:
    return redis.Redis(
        host=REDIS_HOST,
        port=REDIS_PORT,
        password=REDIS_AUTH if REDIS_AUTH else None,
        db=REDIS_DB,
        decode_responses=True,
    )


def update_job(r: redis.Redis, job_id: str, **fields):
    """Update one or more fields in a job's Redis hash."""
    key = f"{JOB_PREFIX}{job_id}"
    mapping = {k: str(v) for k, v in fields.items()}
    r.hset(key, mapping=mapping)


# ── Progress monitoring ──────────────────────────────────────────────────────


def read_progress(job_id: str) -> dict | None:
    """Read the progress JSON file written by R."""
    pf = PROGRESS_DIR / f"progress_{job_id}.json"
    if not pf.exists():
        return None
    try:
        with open(pf) as f:
            return json.load(f)
    except (json.JSONDecodeError, IOError):
        return None


def _human_time(secs: float) -> str:
    """Convert seconds to a human-readable string like '3 min 20 sec'."""
    if secs <= 0:
        return "done"
    secs = int(secs)
    if secs < 60:
        return f"~{secs} sec"
    mins, s = divmod(secs, 60)
    if mins < 60:
        return f"~{mins} min {s} sec" if s else f"~{mins} min"
    hours, m = divmod(mins, 60)
    return f"~{hours}h {m}m"


def sync_progress_to_redis(r: redis.Redis, job_id: str, job_started_at: float):
    """Read progress file and push updates to Redis, including % and ETA.

    The progress file speaks in generic 'combos' (units of work). For the curveR
    worker one unit = one curve, so total_combos == n_curves in the batch.
    """
    progress = read_progress(job_id)
    if progress is None:
        return

    fields = {}
    total = int(progress.get("total_combos", 0))
    done = int(progress.get("completed_combos", 0))

    if total > 0:
        fields["total_combos"] = total
        fields["completed_combos"] = done
        fields["progress"] = f"{done}/{total}"

        # Percentage
        pct = round(done / total * 100, 1)
        fields["percentage"] = pct

        # Elapsed time
        elapsed_secs = time.time() - job_started_at
        elapsed_min = round(elapsed_secs / 60, 1)
        fields["elapsed_minutes"] = elapsed_min

        # Speed and ETA based on completed units
        if done > 0 and done < total:
            secs_per_combo = elapsed_secs / done
            remaining_secs = secs_per_combo * (total - done)
            eta_min = round(remaining_secs / 60, 1)
            fields["eta_minutes"] = eta_min
            fields["speed_seconds_per_combo"] = round(secs_per_combo, 1)
            fields["eta_display"] = _human_time(remaining_secs)
        elif done >= total:
            fields["eta_minutes"] = 0.0
            fields["speed_seconds_per_combo"] = round(elapsed_secs / done, 1) if done > 0 else 0.0
            fields["eta_display"] = "done"
        else:
            fields["eta_minutes"] = ""  # unknown yet
            fields["speed_seconds_per_combo"] = ""
            fields["eta_display"] = "estimating..."

    # The worker reports the multiplate group it is currently fitting.
    if progress.get("current_group"):
        fields["current_group"] = progress["current_group"]

    if fields:
        update_job(r, job_id, **fields)


def cleanup_progress(job_id: str):
    """Remove the progress file after job completes."""
    pf = PROGRESS_DIR / f"progress_{job_id}.json"
    if pf.exists():
        pf.unlink()


# ── Job execution ────────────────────────────────────────────────────────────


def run_job(r: redis.Redis, job_id: str, job_data: dict):
    """Look up script_type, spawn the right worker, and monitor until completion."""
    global _current_proc

    # ── Resolve script ────────────────────────────────────────────────────
    script_type = job_data.get("script_type", "bayesian")
    if script_type not in SCRIPT_REGISTRY:
        now = datetime.now(timezone.utc).isoformat()
        avail = ", ".join(sorted(SCRIPT_REGISTRY.keys()))
        update_job(
            r, job_id,
            status="failed",
            completed_at=now,
            error=f"Unknown script_type '{script_type}'. Available: {avail}",
        )
        logger.error("Job %s failed: unknown script_type '%s'", job_id, script_type)
        return

    interpreter, script_path, method_flag = SCRIPT_REGISTRY[script_type]

    # ── Batch fields ──────────────────────────────────────────────────────
    try:
        curve_ids = json.loads(job_data.get("curve_ids", "[]"))
    except (json.JSONDecodeError, TypeError):
        curve_ids = []
    try:
        group_ids = json.loads(job_data.get("multiplate_group_ids", "[]"))
    except (json.JSONDecodeError, TypeError):
        group_ids = []

    if not curve_ids:
        now = datetime.now(timezone.utc).isoformat()
        update_job(r, job_id, status="failed", completed_at=now,
                   error="Job has no curve_ids to fit")
        logger.error("Job %s failed: empty curve_ids", job_id)
        return

    # Parse script-specific params from JSON
    try:
        params = json.loads(job_data.get("params", "{}"))
    except (json.JSONDecodeError, TypeError):
        params = {}

    now = datetime.now(timezone.utc).isoformat()
    job_started_at = time.time()
    update_job(r, job_id, status="running", started_at=now)
    logger.info(
        "Starting job %s: script=%s method=%s n_curves=%d",
        job_id, script_type, method_flag, len(curve_ids),
    )

    # ── Build command ─────────────────────────────────────────────────────
    # A list over argv is transported as a single comma-joined arg; the worker
    # splits it on commas. curve_ids are ints; group ids are opaque strings.
    curve_ids_arg = ",".join(str(int(c)) for c in curve_ids)

    cmd = [
        interpreter,
        str(script_path),
        "--job_id", job_id,
        "--progress_dir", str(PROGRESS_DIR),
        "--curve_ids", curve_ids_arg,
    ]
    # curveR worker selects engine via --method (bayesian|frequentist)
    if method_flag:
        cmd.extend(["--method", method_flag])
    # Optional integrity check: hand over the app's intended grouping.
    if group_ids:
        cmd.extend(["--multiplate_group_ids", ",".join(str(g) for g in group_ids)])

    # Script-specific params from the params dict → --key value
    for key, value in params.items():
        cmd.extend([f"--{key}", str(value)])

    # ── Environment ───────────────────────────────────────────────────────
    env = os.environ.copy()
    # worker_curveR.R caps cores from WORKER_CORES (falling back to
    # detectCores(), which is NOT cgroup-aware). Set WORKER_CORES == the
    # container CPU limit in the deployment. We do not set threading here.

    logger.info("Spawning: %s", " ".join(cmd))

    # Capture last N lines of R output for error reporting
    output_lines: list[str] = []
    MAX_OUTPUT_LINES = 200

    try:
        # Stream R output directly to container stdout (visible in docker logs)
        # while also capturing the tail for error reporting
        _current_proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,  # line-buffered
            env=env,
        )

        import threading

        # Background thread to read R stdout line-by-line and print it
        def _stream_output():
            for line in _current_proc.stdout:
                line = line.rstrip("\n")
                # Print to container stdout so docker logs shows it
                print(f"[R] {line}", flush=True)
                output_lines.append(line)
                if len(output_lines) > MAX_OUTPUT_LINES:
                    output_lines.pop(0)

        reader_thread = threading.Thread(target=_stream_output, daemon=True)
        reader_thread.start()

        # Monitor progress while R runs
        while _current_proc.poll() is None:
            if _shutdown:
                logger.info("Shutdown requested, terminating R process...")
                _current_proc.terminate()
                _current_proc.wait(timeout=30)
                update_job(r, job_id, status="cancelled", error="Worker shutdown")
                return

            # Check if job was cancelled via API
            current_status = r.hget(f"{JOB_PREFIX}{job_id}", "status")
            if current_status == "cancelled":
                logger.info("Job %s cancelled via API, terminating R process...", job_id)
                _current_proc.terminate()
                _current_proc.wait(timeout=30)
                return

            sync_progress_to_redis(r, job_id, job_started_at)
            time.sleep(PROGRESS_POLL_INTERVAL)

        # Wait for reader thread to finish draining output
        reader_thread.join(timeout=5)

        # Process finished — get return code
        returncode = _current_proc.returncode

        # Final progress sync
        sync_progress_to_redis(r, job_id, job_started_at)

        if returncode == 0:
            # curveR writes results to PostgreSQL (madi_results.calib_*), not to
            # files. Record the DB destination for traceability.
            output_paths = f"madi_results.calib_* (job_id={job_id})"

            now = datetime.now(timezone.utc).isoformat()
            update_job(
                r, job_id,
                status="completed",
                completed_at=now,
                output_path=output_paths,
            )
            logger.info("Job %s completed successfully. Output: %s", job_id, output_paths)
        else:
            # R script failed — include tail of output in error
            error_msg = "\n".join(output_lines[-50:])
            now = datetime.now(timezone.utc).isoformat()
            update_job(
                r, job_id,
                status="failed",
                completed_at=now,
                error=error_msg,
            )
            logger.error("Job %s failed (exit code %d): %s", job_id, returncode, error_msg[:500])

    except Exception as e:
        now = datetime.now(timezone.utc).isoformat()
        update_job(
            r, job_id,
            status="failed",
            completed_at=now,
            error=str(e),
        )
        logger.exception("Job %s failed with exception", job_id)

    finally:
        _current_proc = None
        cleanup_progress(job_id)


# ── Main loop ────────────────────────────────────────────────────────────────


def main():
    logger.info("=" * 60)
    logger.info("i-spi-compute — Worker starting")
    logger.info("  Redis: %s:%s/%s", REDIS_HOST, REDIS_PORT, REDIS_DB)
    logger.info("  Queue: %s", QUEUE_KEY)
    logger.info("  Scripts: %s", ", ".join(
        f"{k} → {v[1].name}" for k, v in SCRIPT_REGISTRY.items()
    ))
    logger.info("=" * 60)

    r = get_redis()

    # Verify Redis connection
    try:
        r.ping()
        logger.info("Redis connected successfully")
    except redis.ConnectionError:
        logger.error("Cannot connect to Redis at %s:%s", REDIS_HOST, REDIS_PORT)
        sys.exit(1)

    logger.info("Waiting for jobs on queue: %s", QUEUE_KEY)

    while not _shutdown:
        try:
            # Blocking pop with 5-second timeout so we can check _shutdown
            result = r.blpop(QUEUE_KEY, timeout=5)
            if result is None:
                continue  # Timeout, loop back to check _shutdown

            _, job_id = result
            logger.info("Dequeued job: %s", job_id)

            # Read job data
            job_data = r.hgetall(f"{JOB_PREFIX}{job_id}")
            if not job_data:
                logger.warning("Job %s not found in Redis, skipping", job_id)
                continue

            # Skip cancelled jobs
            if job_data.get("status") == "cancelled":
                logger.info("Job %s already cancelled, skipping", job_id)
                continue

            # Run the job
            run_job(r, job_id, job_data)

        except redis.ConnectionError:
            logger.error("Redis connection lost. Reconnecting in 5s...")
            time.sleep(5)
            try:
                r = get_redis()
                r.ping()
                logger.info("Redis reconnected")
            except redis.ConnectionError:
                continue

        except Exception:
            logger.exception("Unexpected error in main loop")
            time.sleep(2)

    logger.info("Worker shutdown complete")


if __name__ == "__main__":
    main()
