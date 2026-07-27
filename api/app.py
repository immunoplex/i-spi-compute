"""
i-spi-compute — Batch Runner API

FastAPI application that manages batch calibration-curve jobs. A job is a
**batch of curve_ids** to fit; jobs are queued in Redis and picked up by worker
containers. Each job specifies a `script_type` (e.g. "bayesian", "frequentist")
which selects the engine the worker runs.

Job contract (curve_id batch — see HANDOFF_worker_curve_id_batch.md):
    The API no longer resolves scope. Scope -> curve_ids is a `curve_lookup`
    query the client (i-spi coverage panel) already performs. The client sends
    the resolved `curve_ids` (each optionally tagged with its
    `multiplate_group_id`); the worker reads the `*_for_fit` views by
    `curve_id = ANY(batch)`, groups by `multiplate_group_id`, fits, and persists.

Authentication: X-API-Key header required on all endpoints (except /health).
Set API_KEY env var. For local dev, defaults to "dev-key-immunoplex".

Endpoints:
    POST   /jobs          Submit a new batch job
    GET    /jobs          List all jobs (with optional filters)
    GET    /jobs/{job_id} Get status/details of a specific job
    DELETE /jobs/{job_id} Cancel a queued/running job
    GET    /health        Health check (no auth required)
"""

import os
import json
import uuid
import secrets
import logging
from datetime import datetime, timezone
from typing import Optional

from fastapi import FastAPI, HTTPException, Query, Depends, Security
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import APIKeyHeader
from pydantic import BaseModel, Field
import redis

# ── Logging ──────────────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("i_spi_compute_api")

# ── Config ───────────────────────────────────────────────────────────────────

REDIS_HOST = os.getenv("REDIS_HOST", "redis")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))
REDIS_AUTH = os.getenv("REDIS_AUTH", "")
REDIS_DB = int(os.getenv("REDIS_DB", "0"))

# API Key — if not set, generate a random one and log it on startup
API_KEY = os.getenv("API_KEY", "")

QUEUE_KEY = "ispi:batch:queue"
JOB_PREFIX = "ispi:job:"
JOB_INDEX_KEY = "ispi:jobs"  # sorted set of all job_ids by created_at

# ── Redis Connection ─────────────────────────────────────────────────────────


def get_redis() -> redis.Redis:
    """Get a Redis connection (lazily created, connection-pooled)."""
    return redis.Redis(
        host=REDIS_HOST,
        port=REDIS_PORT,
        password=REDIS_AUTH if REDIS_AUTH else None,
        db=REDIS_DB,
        decode_responses=True,
    )


# ── Auth ─────────────────────────────────────────────────────────────────────

api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)


async def verify_api_key(api_key: Optional[str] = Security(api_key_header)):
    """Validate the X-API-Key header against the configured API_KEY."""
    if not API_KEY:
        # No API_KEY configured — auth disabled (not recommended for prod)
        return None
    if not api_key:
        raise HTTPException(
            status_code=401,
            detail="Missing X-API-Key header",
        )
    if not secrets.compare_digest(api_key, API_KEY):
        raise HTTPException(
            status_code=403,
            detail="Invalid API key",
        )
    return api_key


# ── Pydantic Models ─────────────────────────────────────────────────────────


class JobSubmission(BaseModel):
    """Request body for submitting a new batch job.

    The unit of work is a **batch of curve_ids**. `curve_id`s are minted at LOAD
    time and pre-exist fitting; the client resolves scope -> curve_ids against
    `curve_lookup` (the coverage panel already does this) and sends the batch.
    The worker groups the batch into multiplate fitting units by
    `multiplate_group_id` (curves differing only by plate). Passing the group
    ids is optional belt-and-suspenders — the `*_for_fit` views also carry the
    grouping — but when supplied it lets the worker assert the app's intended
    grouping matches the view's.
    """

    curve_ids: list[int] = Field(
        ...,
        min_length=1,
        description="The batch of curve_lookup ids to fit (>= 1).",
    )
    multiplate_group_ids: Optional[list[str]] = Field(
        None,
        description=(
            "Optional. Parallel to curve_ids (same order): the "
            "multiplate_group_id of each curve. If provided, its length must "
            "equal len(curve_ids). Used only as an integrity check against the "
            "grouping the views carry."
        ),
    )
    script_type: str = Field(
        "bayesian",
        description=(
            "Which engine to run. 'bayesian' (curveRbayes + CmdStan) or "
            "'frequentist' (curveRfreq). More can be registered in the worker's "
            "SCRIPT_REGISTRY."
        ),
    )
    params: dict = Field(
        default_factory=dict,
        description=(
            "Engine-tuning parameters passed as --key value CLI args to the "
            "worker. E.g. {'models': 'logistic4,gompertz4'} or, for bayesian, "
            "{'chains': '4', 'warmup': '1000', 'sampling': '1000', "
            "'adapt_delta': '0.9', 'seed': '17', 'blank_option': 'ignored'}."
        ),
    )
    # Top-level shorthand for the CDAN CV% gate. Merged into params as 'cdan_cv'.
    cdan_cv_threshold: float = Field(
        20.0,
        ge=1.0,
        le=100.0,
        description="Shorthand for the CV%% gate. Merged into params as 'cdan_cv'.",
    )

    def model_post_init(self, __context):
        if not self.curve_ids:
            raise ValueError("curve_ids must contain at least one id")
        if self.multiplate_group_ids is not None and \
                len(self.multiplate_group_ids) != len(self.curve_ids):
            raise ValueError(
                "multiplate_group_ids, when provided, must be the same length "
                "as curve_ids (parallel arrays)"
            )
        # Merge the CV% shorthand into params unless the caller set it explicitly.
        if "cdan_cv" not in self.params:
            self.params["cdan_cv"] = self.cdan_cv_threshold


class JobStatus(BaseModel):
    """Response model for job status."""

    job_id: str
    status: str
    script_type: str = "bayesian"

    # The batch this job fits
    curve_ids: list[int] = []
    multiplate_group_ids: Optional[list[str]] = None
    n_curves: int = 0

    cdan_cv_threshold: float = 20.0
    params: dict = {}
    created_at: str
    started_at: Optional[str] = None
    completed_at: Optional[str] = None

    # Progress (units = curves in the batch)
    progress: str = "0/0"
    total_combos: int = 0
    completed_combos: int = 0
    percentage: float = 0.0

    # Timing
    elapsed_minutes: float = 0.0
    eta_minutes: Optional[float] = None
    eta_display: Optional[str] = None
    speed_seconds_per_combo: Optional[float] = None

    # What's running right now (a multiplate group tag)
    current_group: Optional[str] = None

    output_path: Optional[str] = None
    error: Optional[str] = None


class JobListResponse(BaseModel):
    """Response model for listing jobs."""

    jobs: list[JobStatus]
    total: int


# ── FastAPI App ──────────────────────────────────────────────────────────────

app = FastAPI(
    title="i-spi-compute Batch Runner",
    description=(
        "API for submitting and monitoring batch calibration-curve jobs "
        "(Bayesian, frequentist). A job is a batch of `curve_ids`; jobs are "
        "queued in Redis and dispatched to the curveR worker based on "
        "`script_type`.\n\n"
        "**Authentication**: Pass `X-API-Key` header on all requests (except `/health`)."
    ),
    version="0.3.0",
    root_path=os.getenv("ROOT_PATH", ""),
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.on_event("startup")
def _startup():
    global API_KEY
    if not API_KEY:
        API_KEY = "dev-key-immunoplex"
        logger.warning(
            "API_KEY not set — using default dev key: %s  (DO NOT use in production!)",
            API_KEY,
        )
    else:
        logger.info("API_KEY configured (length=%d)", len(API_KEY))
    logger.info("Redis: %s:%s/%s", REDIS_HOST, REDIS_PORT, REDIS_DB)


# ── Endpoints ────────────────────────────────────────────────────────────────


@app.get("/health")
def health_check():
    """Health check — also verifies Redis connectivity. No auth required."""
    try:
        r = get_redis()
        r.ping()
        return {"status": "ok", "redis": "connected"}
    except redis.ConnectionError:
        raise HTTPException(status_code=503, detail="Redis unavailable")


@app.post("/jobs", response_model=JobStatus, status_code=201)
def submit_job(
    submission: JobSubmission,
    _key: str = Depends(verify_api_key),
):
    """
    Submit a new batch calibration job.

    - **curve_ids**: the batch of curve_lookup ids to fit (required, >= 1)
    - **multiplate_group_ids**: optional parallel array (integrity check only)
    - **script_type**: engine selector ('bayesian' | 'frequentist')
    - **params**: engine-tuning params as a key-value dict
    - **cdan_cv_threshold**: CV%% gate shorthand (merged into params.cdan_cv)
    """
    r = get_redis()
    job_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()

    job_data = {
        "job_id": job_id,
        "status": "queued",
        "script_type": submission.script_type,
        "curve_ids": json.dumps(submission.curve_ids),
        "multiplate_group_ids": json.dumps(submission.multiplate_group_ids or []),
        "n_curves": str(len(submission.curve_ids)),
        "params": json.dumps(submission.params),
        "cdan_cv_threshold": str(submission.cdan_cv_threshold),
        "created_at": now,
        "started_at": "",
        "completed_at": "",
        "progress": "0/0",
        "total_combos": str(len(submission.curve_ids)),
        "completed_combos": "0",
        "current_group": "",
        "output_path": "",
        "error": "",
    }

    pipe = r.pipeline()
    pipe.hset(f"{JOB_PREFIX}{job_id}", mapping=job_data)
    pipe.zadd(JOB_INDEX_KEY, {job_id: datetime.now(timezone.utc).timestamp()})
    pipe.rpush(QUEUE_KEY, job_id)
    pipe.execute()

    logger.info(
        "Job %s submitted: script=%s n_curves=%d",
        job_id,
        submission.script_type,
        len(submission.curve_ids),
    )

    return _job_data_to_status(job_data)


@app.get("/jobs/{job_id}", response_model=JobStatus)
def get_job(
    job_id: str,
    _key: str = Depends(verify_api_key),
):
    """Get the current status and details of a specific job."""
    r = get_redis()
    job_data = r.hgetall(f"{JOB_PREFIX}{job_id}")
    if not job_data:
        raise HTTPException(status_code=404, detail=f"Job {job_id} not found")
    return _job_data_to_status(job_data)


@app.get("/jobs", response_model=JobListResponse)
def list_jobs(
    status: Optional[str] = Query(None, description="Filter by status"),
    script_type: Optional[str] = Query(None, description="Filter by script type (e.g. 'bayesian')"),
    limit: int = Query(50, ge=1, le=200, description="Max results"),
    offset: int = Query(0, ge=0, description="Pagination offset"),
    _key: str = Depends(verify_api_key),
):
    """List all jobs, optionally filtered by status and/or script_type.

    Note: filtering by study/experiment/antigen no longer exists — a job is an
    opaque batch of curve_ids and carries no scope descriptor. Clients that need
    to relate jobs to a study should track the mapping on their side.
    """
    r = get_redis()

    # Get all job IDs from the sorted set (newest first)
    all_job_ids = r.zrevrange(JOB_INDEX_KEY, 0, -1)

    jobs = []
    for jid in all_job_ids:
        job_data = r.hgetall(f"{JOB_PREFIX}{jid}")
        if not job_data:
            continue
        # Apply filters
        if status and job_data.get("status") != status:
            continue
        if script_type and job_data.get("script_type", "bayesian") != script_type:
            continue
        jobs.append(_job_data_to_status(job_data))

    total = len(jobs)
    jobs = jobs[offset : offset + limit]

    return JobListResponse(jobs=jobs, total=total)


@app.delete("/jobs/{job_id}")
def cancel_job(
    job_id: str,
    _key: str = Depends(verify_api_key),
):
    """
    Cancel a queued or running job.

    If the job is queued, it will be skipped by the worker.
    If the job is running, the worker will stop after the current group.
    """
    r = get_redis()
    job_data = r.hgetall(f"{JOB_PREFIX}{job_id}")
    if not job_data:
        raise HTTPException(status_code=404, detail=f"Job {job_id} not found")

    current_status = job_data.get("status", "")
    if current_status in ("completed", "failed", "cancelled"):
        raise HTTPException(
            status_code=400,
            detail=f"Job {job_id} is already {current_status}, cannot cancel",
        )

    r.hset(f"{JOB_PREFIX}{job_id}", "status", "cancelled")
    logger.info("Job %s cancelled (was %s)", job_id, current_status)

    return {"job_id": job_id, "status": "cancelled", "previous_status": current_status}


# ── Helpers ──────────────────────────────────────────────────────────────────


def _safe_float(val, default=0.0):
    """Safely parse a float from Redis string."""
    if not val or val == "":
        return default
    try:
        return float(val)
    except (ValueError, TypeError):
        return default


def _safe_json(val, default=None):
    """Safely parse a JSON string from Redis."""
    if not val or val == "":
        return default if default is not None else {}
    try:
        return json.loads(val)
    except (json.JSONDecodeError, TypeError):
        return default if default is not None else {}


def _job_data_to_status(data: dict) -> JobStatus:
    """Convert a Redis hash dict to a JobStatus model."""
    eta = _safe_float(data.get("eta_minutes"), default=None)
    curve_ids = _safe_json(data.get("curve_ids"), default=[]) or []
    group_ids = _safe_json(data.get("multiplate_group_ids"), default=[]) or []
    return JobStatus(
        job_id=data.get("job_id", ""),
        status=data.get("status", "unknown"),
        script_type=data.get("script_type", "bayesian"),
        curve_ids=[int(c) for c in curve_ids],
        multiplate_group_ids=([str(g) for g in group_ids] if group_ids else None),
        n_curves=int(data.get("n_curves", len(curve_ids) or 0)),
        cdan_cv_threshold=_safe_float(data.get("cdan_cv_threshold"), default=20.0),
        params=_safe_json(data.get("params")),
        created_at=data.get("created_at", ""),
        started_at=data.get("started_at") or None,
        completed_at=data.get("completed_at") or None,
        progress=data.get("progress", "0/0"),
        total_combos=int(data.get("total_combos", 0)),
        completed_combos=int(data.get("completed_combos", 0)),
        percentage=_safe_float(data.get("percentage")),
        elapsed_minutes=_safe_float(data.get("elapsed_minutes")),
        eta_minutes=eta if eta is not None else None,
        eta_display=data.get("eta_display") or None,
        speed_seconds_per_combo=_safe_float(data.get("speed_seconds_per_combo"), default=None),
        current_group=data.get("current_group") or None,
        output_path=data.get("output_path") or None,
        error=data.get("error") or None,
    )


# ── Run ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "app:app",
        host="0.0.0.0",
        port=int(os.getenv("PORT", "8000")),
        reload=True,
    )
