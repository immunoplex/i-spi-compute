"""
immunoplex_batch_calculator — Worker Supervisor

Thin Python process that:
1. BLPOP on Redis queue (ispi:batch:queue)
2. Reads job metadata from Redis hash
3. Looks up script_type in SCRIPT_REGISTRY to find the right worker script
4. Spawns the script with common + script-specific CLI args
5. Monitors progress file written by the script
6. Updates job status in Redis (running → completed/failed)

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
logger = logging.getLogger("immunoplex_worker")

# ── Config ───────────────────────────────────────────────────────────────────

REDIS_HOST = os.getenv("REDIS_HOST", "redis")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))
REDIS_AUTH = os.getenv("REDIS_AUTH", "")
REDIS_DB = int(os.getenv("REDIS_DB", "0"))

QUEUE_KEY = "ispi:batch:queue"
JOB_PREFIX = "ispi:job:"

PROGRESS_DIR = Path(os.getenv("PROGRESS_DIR", "/tmp"))
OUTPUT_BASE = Path(os.getenv("OUTPUT_DIR", "/data/bayes"))

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
    """Read progress file and push updates to Redis, including % and ETA."""
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

        # Speed and ETA based on completed combos
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

    if progress.get("current_experiment"):
        fields["current_experiment"] = progress["current_experiment"]
    if progress.get("current_antigens"):
        fields["current_antigens"] = progress["current_antigens"]

    # Experiment-level progress
    exp_done = progress.get("experiments_done", 0)
    exp_total = progress.get("experiments_total", 0)
    if exp_total:
        fields["experiments_done"] = exp_done
        fields["experiments_total"] = exp_total
        fields["experiment_progress"] = f"{exp_done}/{exp_total}"

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

    # ── Common fields ─────────────────────────────────────────────────────
    study = job_data.get("study", "")
    experiment = job_data.get("experiment", "")
    antigen = job_data.get("antigen", "")
    source = job_data.get("source", "")
    scope = job_data.get("scope", "study")
    project_id = job_data.get("project_id", "0")

    # Parse script-specific params from JSON
    try:
        params = json.loads(job_data.get("params", "{}"))
    except (json.JSONDecodeError, TypeError):
        params = {}

    now = datetime.now(timezone.utc).isoformat()
    job_started_at = time.time()
    update_job(r, job_id, status="running", started_at=now)
    logger.info(
        "Starting job %s: script=%s study=%s experiment=%s scope=%s",
        job_id, script_type, study, experiment, scope,
    )

    # Build output directory
    output_dir = OUTPUT_BASE / study
    output_dir.mkdir(parents=True, exist_ok=True)

    # ── Build command ─────────────────────────────────────────────────────
    # Common args that every script receives
    cmd = [
        interpreter,
        str(script_path),
        "--study", study,
        "--scope", scope,
        "--job_id", job_id,
        "--project_id", project_id,
        "--output_dir", str(output_dir),
        "--progress_dir", str(PROGRESS_DIR),
    ]
    # curveR worker selects engine via --method (bayesian|frequentist)
    if method_flag:
        cmd.extend(["--method", method_flag])
    if experiment:
        cmd.extend(["--experiment", experiment])
    if antigen:
        cmd.extend(["--antigen", antigen])
    if source:
        cmd.extend(["--source", source])

    # Script-specific params from the params dict → --key value
    for key, value in params.items():
        cmd.extend([f"--{key}", str(value)])

    # ── Environment ───────────────────────────────────────────────────────
    env = os.environ.copy()
    # worker_curveR.R sets options(mc.cores) from parallel::detectCores() at
    # startup. NOTE: detectCores() is NOT cgroup-aware, so under K8s/Docker CPU
    # limits it may over-report cores. If you pin CPU, consider capping cores via
    # an env var the worker reads, or make the worker cgroup-aware. We do not set
    # threading here — the R process controls its own.

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
    logger.info("Immunoplex Batch Runner — Worker starting")
    logger.info("  Redis: %s:%s/%s", REDIS_HOST, REDIS_PORT, REDIS_DB)
    logger.info("  Queue: %s", QUEUE_KEY)
    logger.info("  Output: %s", OUTPUT_BASE)
    logger.info("  Scripts: %s", ", ".join(
        f"{k} → {v[1].name}" for k, v in SCRIPT_REGISTRY.items()
    ))
    logger.info("=" * 60)

    # Ensure output directory exists
    OUTPUT_BASE.mkdir(parents=True, exist_ok=True)

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
