# EnderTuring — Take-Home Tasks

Submission by Nikita Konakh.

Two independent tasks, plus the AI conversations used to produce them.

| | What | Where |
|---|---|---|
| 1 | **Role-based access control** on the Full-Stack FastAPI template | [`dev-task/`](dev-task/) |
| 2 | **One-click Ghost deployment** to a Hetzner VPS with no public SSH | [`infra-task/`](infra-task/) |
| — | AI conversations used while building both | [`ai-transcripts/`](ai-transcripts/) |
| — | How AI was used, and where I disagreed with it | [`AI_USAGE.md`](AI_USAGE.md) |
| — | Scope cuts, trade-offs, time spent | [`NOTES.md`](NOTES.md) |

The original assignment text is kept verbatim in [`ASSIGNMENT.md`](ASSIGNMENT.md).

## Task 1 — RBAC

Setup, permission matrix and the authorization approach are documented in
[`dev-task/README.md`](dev-task/README.md).

Three roles — `admin`, `manager`, `member` — on the vendored FastAPI template.
The whole model is one dict in `backend/app/core/permissions.py` mapping each
role to a set of permissions; routes depend on permissions through a
`require(Permission.X)` FastAPI dependency and never compare role names, so
adding a role is an enum member and a dict row. `GET /users/me` returns the
caller's computed permission list, which the React frontend uses to hide
navigation and controls and to render a 403 page instead of redirecting. Roles
are stored in a new indexed `user.role` column with an Alembic migration that
backfills from the template's `is_superuser` flag; that flag is kept as a derived
mirror so the 58 inherited tests still pass untouched. 86 backend tests pass, 28
of them authorization cases covering allowed and denied paths for every role.
Trade-offs and known issues are in [`NOTES.md`](NOTES.md); the two decision
records are under [`dev-task/docs/adr/`](dev-task/docs/adr/).

## Task 2 — Infrastructure

Not started. [`infra-task/`](infra-task/) is a placeholder; the one-click Ghost
deployment to a Hetzner VPS with no public SSH is still to be built. The
assignment text for it is in [`ASSIGNMENT.md`](ASSIGNMENT.md).
