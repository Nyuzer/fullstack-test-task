# Role-based access control on the Full Stack FastAPI Template

Adds three roles — `admin`, `manager`, `member` — to the vendored
[full-stack-fastapi-template](https://github.com/fastapi/full-stack-fastapi-template),
enforced in the backend and reflected in the React frontend.

- [Setup from a clean clone](#setup-from-a-clean-clone)
- [Seeded users](#seeded-users)
- [Running the tests](#running-the-tests)
- [Permission matrix](#permission-matrix)
- [Authorization approach](#authorization-approach)
- [Architecture decision records](#architecture-decision-records)

## Setup from a clean clone

Requirements: Docker, [uv](https://docs.astral.sh/uv/), [bun](https://bun.sh).
All commands run from `dev-task/`.

The repository ships a working `.env` with development defaults, so no
configuration is needed to start.

```bash
# 1. Start Postgres, Mailpit and the API
docker compose up -d --build db mailpit backend

# 2. Apply migrations and seed the three demo users.
#    prestart.sh runs `alembic upgrade head` followed by `app/initial_data.py`.
docker compose exec -T backend bash -c 'cd /app/backend && bash scripts/prestart.sh'

# 3. Start the frontend
bun install
bun run dev
```

The frontend is at <http://localhost:5173>, the API at <http://localhost:8000>,
interactive API docs at <http://localhost:8000/docs>, and Mailpit at
<http://localhost:8025>.

To seed again later without re-running migrations:

```bash
docker compose exec -T backend bash -c 'cd /app/backend && python app/initial_data.py'
```

### Database migrations

The role column is added by `backend/app/alembic/versions/7b2d4c1a9f30_add_role_to_user.py`,
which revises `fe56fa70289e`. It adds `user.role` as nullable, backfills it from
the pre-existing `is_superuser` flag (`admin` where true, `member` otherwise),
then marks the column `NOT NULL` with a `member` server default and indexes it.
The downgrade drops the column, which discards role information that cannot be
reconstructed from `is_superuser` alone — a `manager` returns as `member` on a
re-upgrade.

## Seeded users

`init_db` creates one account per role. The admin is always seeded; the manager
and member accounts are seeded only when `FASTAPI_ENV=development`, so a
production prestart does not create demo logins. All three share
`FIRST_SUPERUSER_PASSWORD`, which the committed `.env` sets to `changethis`.

| Email | Password | Role |
|---|---|---|
| `admin@example.com` | `changethis` | admin |
| `manager@example.com` | `changethis` | manager |
| `member@example.com` | `changethis` | member |

Seeding is idempotent: `seed_user` creates an account only when the email does
not already exist, and it never changes the role of an account that does.

## Running the tests

The suite is not in the container image, so run it from the host against the
Postgres container:

```bash
cd backend
PYTHONUTF8=1 FASTAPI_ENV=development uv run pytest tests/ -q
```

86 tests pass: the template's original 58 plus 28 authorization cases.

**The tests wipe the development database.** The session-scoped `db` fixture in
`tests/conftest.py` deletes every user and item at teardown, so the seeded
accounts are gone once the suite finishes. Re-seed before using the app again:

```bash
docker compose exec -T backend bash -c 'cd /app/backend && python app/initial_data.py'
```

Authorization coverage lives in one file,
`backend/tests/api/routes/test_permissions.py` (9 test functions). It asserts
both allowed and denied outcomes for every role, and deliberately holds two
views of the matrix: one parametrized over role × endpoint that derives its
expectations from `ROLE_PERMISSIONS`, and one hand-written table transcribed
from the assignment. The first catches routes drifting from the matrix; the
second catches the matrix itself being edited to accommodate a failing test.

On Windows, `PYTHONUTF8=1` is required because the template reads files without
an explicit encoding.

## Permission matrix

| Action | admin | manager | member |
|---|---|---|---|
| List all users (`users:read`) | yes | yes | no |
| View any user by id (`users:read`) | yes | yes | no |
| Create user (`users:create`) | yes | no | no |
| Update any profile (`users:update_any`) | yes | no | no |
| Delete user (`users:delete`) | yes | no | no |
| View metrics (`metrics:read`) | yes | yes | no |
| Global settings, test email (`settings:manage`) | yes | no | no |
| Act on items owned by others (`items:manage_any`) | yes | no | no |
| View and update own profile | yes | yes | yes |
| Act on own items | yes | yes | yes |

Own-profile and own-item access needs no permission: the `/users/me*` routes are
self-scoped by construction and the item routes are owner-scoped, which is why
`member` holds an empty permission set rather than a set of "own" permissions.

A member listing items receives `200` with only their own rows, not `403`. That
is scoping, not a silent denial — the response contains everything the caller is
entitled to see.

## Authorization approach

**Where the checks live.** Authorization is a FastAPI dependency, not
middleware and not inline branching. `app/api/deps.py` exposes a factory,
`require(Permission.X)`, which returns a dependency that admits only callers
holding that permission and raises `403` otherwise, logging the denial at
WARNING with the user id, role and permission. Routes declare their requirement
in the decorator — `dependencies=[Depends(require(Permission.USERS_READ))]` —
so the requirement is visible in the route signature and enforced before the
handler body runs. Three routes need the permission *inside* the body because
the decision is conditional rather than absolute: `read_user_by_id` (self is
always allowed), `delete_user_me` (whoever may delete users may not delete
themselves) and the item routes (ownership widens or narrows the query). Those
call `has_permission(role, Permission.X)` directly, against the same matrix.

**How roles are stored and validated.** `User.role` is a `UserRole` string
enum stored as `VARCHAR(20)`, chosen over a Postgres enum type so that adding a
role is a code change rather than a schema migration. The entire model is one
dict in `app/core/permissions.py`: `ROLE_PERMISSIONS` maps each `UserRole` to a
`frozenset[Permission]`. Adding a role means adding an enum member and a row to
that dict; no route, test or frontend file needs editing, because nothing
outside the matrix compares role names. `permissions_for` fails closed — a role
string the matrix does not recognise grants nothing — so a stale row during a
rollback denies rather than crashes the dependency.

The template's original `is_superuser` boolean is retained as a derived mirror
of `role == admin`. It is kept in step by `app/crud.py`, which recomputes it on
every create and on any update that carries a role, and it is never read for an
authorization decision. Keeping it preserved the 58 inherited tests unchanged
and kept the API backward compatible; `UserUpdate` drops the field entirely, so
privilege can only move through `role` and the two cannot be set out of step.

**How the frontend learns capabilities.** `GET /users/me` returns `UserMe`, a
schema used only by that route, which adds a computed `permissions: list[str]`
to the public user fields. A dedicated schema keeps the list off `UserPublic`,
so the user-list endpoint does not serialize a permission array per row. The
frontend's `useAuth` hook exposes `can("users:read")`; no component mentions a
role name, so a new role changes behaviour without a frontend change. The
sidebar filters its entries on `requires`, `/admin` and `/metrics` render a
403 page instead of redirecting, and the Add User button and per-row Edit and
Delete controls are gated on `users:create`, `users:update_any` and
`users:delete` respectively.

The frontend is a convenience layer, never the control. A `401` clears the token
and returns to the login page; a `403` leaves the session intact and renders
`Forbidden`, because being refused one page is not a reason to be logged out.

## Architecture decision records

- [ADR 0001: enforce authorization with a permission matrix and a dependency factory](docs/adr/0001-permission-matrix-dependency.md)
- [ADR 0002: expose permissions to the frontend on a dedicated /users/me schema](docs/adr/0002-frontend-permissions.md)

---

The sections below are the upstream template's own documentation.

## Backend Development

Backend docs: [backend/README.md](./backend/README.md).

## Frontend Development

Frontend docs: [frontend/README.md](./frontend/README.md).

## Deployment

FastAPI Cloud deployment: [deployment.md](./deployment.md).

Self-hosted deployment with Docker Compose: [deployment-docker-compose.md](./deployment-docker-compose.md).

## Development

General development docs: [development.md](./development.md).

This includes the local FastAPI and Vite workflow, Docker Compose services, `.env` configuration, and more.

## Release Notes

Check the file [release-notes.md](./release-notes.md).

## License

The Full Stack FastAPI Template is licensed under the terms of the MIT license.
