# Use of generative AI in this project

*Last reviewed: 2026-11-17. Maintainer: Michael S. Zens.*

This statement describes how a generative AI assistant (Anthropic's Claude,
used through the Claude Code command-line tool) has been used in developing
i-spi-compute, the job API, Redis queue and curveR worker that fit standard
curves and precision weights for the I-SPI application, and how its output is
checked. It follows the principle that a project should say plainly what AI
did, what people did, and who is accountable. The I-SPI application and the
curveR packages carry their own statements of the same kind.

## Summary

| | |
|---|---|
| **Tool** | Claude (Anthropic) via Claude Code; model versions are recorded in the working notes, not in commits |
| **Where it was used** | (1) checking that the worker carries the statistical analysis of assay responses (calibration curves, censoring of out-of-range samples, precision weights) from the curveR packages into the database without loss or distortion; (2) drafting worker and API code, database migrations, container builds, CI workflows, tests and deployment documentation under direction |
| **Where it was not used** | choosing scientific questions, study designs or statistical models; interpreting results for any publication; operating the deployed systems; handling participant-level data outside the access controls of the institution |
| **Accountability** | The maintainer reviews and is responsible for every change that is merged, tagged or deployed. AI is not an author of the software or of any analysis |

## What the assistant did

* **Integrity of the analysis pipeline.** Traced each result produced by the
  curveR packages (fits, concentrations and their uncertainty, censoring
  classes, predictive intervals, precision weights) through the worker's
  flattening and saving code to the `calib_*` tables, and wrote checks that a
  saved result matches what the package returned (`verify_saved.R`). For
  example, it found that columns missing from a table were dropped silently on
  save, which led to the rule that a database migration is applied before a
  worker that writes new columns is rolled out, and to the worker refusing to
  run the additive weights model on a database without its columns.
* **Engineering.** Wrote worker and API code (job types, parameter validation,
  parallel fitting, progress reporting), the numbered database migrations,
  container builds that pin and record the curveR package versions, CI
  workflows, tests and documentation, from instructions given by the
  maintainer.
* **Diagnosis.** Investigated failures reported by the maintainer (for example
  jobs failing when an optional setting was unset) and proposed fixes.

## What people did

* Set the requirements, for instance that the default behaviour and existing
  results stay unchanged and that a new statistical model is opt-in until it
  has been validated.
* Decided which statistical approach to adopt and which results to trust.
* Reviewed all diffs and approved every commit, tag, release and database
  change.
* Operated the deployed systems. The assistant has no access to the
  Kubernetes clusters; deployments are made by the maintainer.
* Hold all credentials. The assistant works with a restricted set of
  permissions and does not store secrets in repositories.

## How output is verified

1. **Automated tests.** Unit tests (`worker/tests/`) and the curveR packages'
   own test suites, including tests that pin pre-existing behaviour, must pass
   unmodified.
2. **End-to-end checks on disposable infrastructure.** Worker changes are run
   against a throwaway PostgreSQL database built from the migrations
   (`worker/tests/e2e_local_pg.sh`) before any shared database is touched.
3. **Database changes.** Migrations are idempotent and reviewed before they
   are applied; a snapshot of affected rows is taken before any overwrite, and
   a rollback path exists.
4. **Pinned, labelled images.** Release images record the exact curveR
   package versions they contain, so a result can be traced to the code that
   produced it.
5. **Human review.** Nothing reaches the public repository, the image registry
   or a deployed system without the maintainer approving it.

Assistant output can be wrong in plausible-sounding ways. Where the
documentation makes a numerical claim, the number is produced by code.

## Data and privacy

The assistant runs on the maintainer's workstation and can read the files and
database queries the maintainer permits during a session; content it reads is
processed by the AI provider's service. The maintainer limits that access to
what the task needs and applies the institution's rules for research data.
Exports that contain patient identifiers are stored outside the repositories,
and credentials are kept in files that are excluded from version control.

## Reproducibility and provenance

Release tags, image tags and the git history record what changed and when.
Commits are authored by the maintainer and, from v1.0.0 on, do not carry an AI
co-author trailer; this document is the project's disclosure instead. Some
earlier commits carry such a trailer from before this policy was adopted.

## Contact

Questions about the use of AI in this project or about a specific analytic
decision: open an issue in this repository or contact the maintainer.
