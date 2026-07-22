"""
immunoplex_batch_calculator — Batch Runner API

FastAPI application that manages batch calculation jobs.
Jobs are queued in Redis and picked up by worker containers.
Each job specifies a `script_type` (e.g. "bayesian", "frequentist") which
determines which R/Python script the worker runs.

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
logger = logging.getLogger("immunoplex_batch_api")

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
    """Request body for submitting a new batch job."""

    project_id: int = Field(
        ...,
        description="Workspace/project ID. Required — same study name can exist in different workspaces.",
    )
    study: str = Field(..., description="Study accession (e.g., 'MADI_P3_GAPS')")
    experiment: Optional[str] = Field(
        None,
        description="Experiment accession. Required if scope='experiment' or 'antigen'.",
    )
    antigen: Optional[str] = Field(
        None,
        description="Antigen name. Required if scope='antigen'.",
    )
    source: Optional[str] = Field(
        None,
        description="Standard source filter (e.g., 'NIBSC06_140'). If omitted, all sources.",
    )
    scope: str = Field(
        "study",
        description="Job scope: 'study' (all experiments), 'experiment' (single experiment), or 'antigen' (single antigen).",
    )
    script_type: str = Field(
        "bayesian",
        description=(
            "Which calculation script to run. "
            "Available: 'bayesian' (stanassay ensemble fitting). "
            "More can be registered in the worker's SCRIPT_REGISTRY."
        ),
    )
    params: dict = Field(
        default_factory=dict,
        description=(
            "Script-specific parameters passed as --key value CLI args to the worker script. "
            "For bayesian: {'cdan_cv_threshold': 25.0}. "
            "For frequentist: {'method': 'nplr'}. "
            "Keys are converted to --key CLI flags."
        ),
    )
    # Backward compat — top-level shorthand for bayesian's CDAN CV threshold.
    # Merged into params automatically for script_type='bayesian'.
    cdan_cv_threshold: float = Field(
        20.0,
        ge=1.0,
        le=100.0,
        description="Shorthand for bayesian CDAN CV%% threshold. Merged into params as 'cdan_cv'.",
    )

    def model_post_init(self, __context):
        if self.scope not in ("study", "experiment", "antigen"):
            raise ValueError("scope must be 'study', 'experiment', or 'antigen'")
        if self.scope in ("experiment", "antigen") and not self.experiment:
            raise ValueError("experiment is required when scope='experiment' or 'antigen'")
        if self.scope == "antigen" and not self.antigen:
            raise ValueError("antigen is required when scope='antigen'")
        # Merge cdan_cv_threshold into params for bayesian (backward compat)
        if self.script_type == "bayesian" and "cdan_cv" not in self.params:
            self.params["cdan_cv"] = self.cdan_cv_threshold


class JobStatus(BaseModel):
    """Response model for job status."""

    job_id: str
    status: str
    script_type: str = "bayesian"
    project_id: int = 0
    study: str
    experiment: Optional[str] = None
    source: Optional[str] = None
    scope: str
    cdan_cv_threshold: float = 20.0
    params: dict = {}
    created_at: str
    started_at: Optional[str] = None
    completed_at: Optional[str] = None

    # Combo-level progress (antigen × plate combos)
    progress: str = "0/0"
    total_combos: int = 0
    completed_combos: int = 0
    percentage: float = 0.0

    # Experiment-level progress
    experiment_progress: str = "0/0"
    experiments_done: int = 0
    experiments_total: int = 0

    # Timing
    elapsed_minutes: float = 0.0
    eta_minutes: Optional[float] = None
    eta_display: Optional[str] = None
    speed_seconds_per_combo: Optional[float] = None

    # What's running right now
    current_experiment: Optional[str] = None
    current_antigens: Optional[str] = None

    output_path: Optional[str] = None
    error: Optional[str] = None


class JobListResponse(BaseModel):
    """Response model for listing jobs."""

    jobs: list[JobStatus]
    total: int


# ── FastAPI App ──────────────────────────────────────────────────────────────

app = FastAPI(
    title="Immunoplex Batch Runner",
    description=(
        "API for submitting and monitoring batch calculation jobs (Bayesian, frequentist, etc.). "
        "Jobs are queued in Redis and dispatched to R/Python worker scripts based on `script_type`.\n\n"
        "**Authentication**: Pass `X-API-Key` header on all requests (except `/health`)."
    ),
    version="0.2.0",
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
    Submit a new batch calculation job.

    - **script_type**: Which script to run ('bayesian', 'frequentist', etc.)
    - **study**: Study accession (required)
    - **experiment**: Experiment accession (required if scope='experiment' or 'antigen')
    - **source**: Standard source filter (optional)
    - **scope**: 'study', 'experiment', or 'antigen'
    - **params**: Script-specific parameters as key-value dict
    """
    r = get_redis()
    job_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()

    job_data = {
        "job_id": job_id,
        "status": "queued",
        "script_type": submission.script_type,
        "project_id": str(submission.project_id),
        "study": submission.study,
        "experiment": submission.experiment or "",
        "antigen": submission.antigen or "",
        "source": submission.source or "",
        "scope": submission.scope,
        "params": json.dumps(submission.params),
        "cdan_cv_threshold": str(submission.cdan_cv_threshold),
        "created_at": now,
        "started_at": "",
        "completed_at": "",
        "progress": "0/0",
        "total_combos": "0",
        "completed_combos": "0",
        "current_antigens": "",
        "current_experiment": "",
        "output_path": "",
        "error": "",
    }

    pipe = r.pipeline()
    pipe.hset(f"{JOB_PREFIX}{job_id}", mapping=job_data)
    pipe.zadd(JOB_INDEX_KEY, {job_id: datetime.now(timezone.utc).timestamp()})
    pipe.rpush(QUEUE_KEY, job_id)
    pipe.execute()

    logger.info(
        "Job %s submitted: script=%s study=%s experiment=%s scope=%s",
        job_id,
        submission.script_type,
        submission.study,
        submission.experiment,
        submission.scope,
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
    study: Optional[str] = Query(None, description="Filter by study accession"),
    status: Optional[str] = Query(None, description="Filter by status"),
    script_type: Optional[str] = Query(None, description="Filter by script type (e.g. 'bayesian')"),
    limit: int = Query(50, ge=1, le=200, description="Max results"),
    offset: int = Query(0, ge=0, description="Pagination offset"),
    _key: str = Depends(verify_api_key),
):
    """List all jobs, optionally filtered by study, status, and/or script_type."""
    r = get_redis()

    # Get all job IDs from the sorted set (newest first)
    all_job_ids = r.zrevrange(JOB_INDEX_KEY, 0, -1)

    jobs = []
    for jid in all_job_ids:
        job_data = r.hgetall(f"{JOB_PREFIX}{jid}")
        if not job_data:
            continue
        # Apply filters
        if study and job_data.get("study") != study:
            continue
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
    If the job is running, the worker will stop processing after the current antigen.
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
    return JobStatus(
        job_id=data.get("job_id", ""),
        status=data.get("status", "unknown"),
        script_type=data.get("script_type", "bayesian"),
        project_id=int(data.get("project_id", 0)),
        study=data.get("study", ""),
        experiment=data.get("experiment") or None,
        source=data.get("source") or None,
        scope=data.get("scope", "study"),
        cdan_cv_threshold=_safe_float(data.get("cdan_cv_threshold"), default=20.0),
        params=_safe_json(data.get("params")),
        created_at=data.get("created_at", ""),
        started_at=data.get("started_at") or None,
        completed_at=data.get("completed_at") or None,
        progress=data.get("progress", "0/0"),
        total_combos=int(data.get("total_combos", 0)),
        completed_combos=int(data.get("completed_combos", 0)),
        percentage=_safe_float(data.get("percentage")),
        experiment_progress=data.get("experiment_progress", "0/0"),
        experiments_done=int(data.get("experiments_done", 0)),
        experiments_total=int(data.get("experiments_total", 0)),
        elapsed_minutes=_safe_float(data.get("elapsed_minutes")),
        eta_minutes=eta if eta is not None else None,
        eta_display=data.get("eta_display") or None,
        speed_seconds_per_combo=_safe_float(data.get("speed_seconds_per_combo"), default=None),
        current_experiment=data.get("current_experiment") or None,
        current_antigens=data.get("current_antigens") or None,
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
