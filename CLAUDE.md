# Project rules

Take-home submission with two independent tasks:

- `dev-task/` — RBAC (admin / manager / member) on a vendored
  `fastapi/full-stack-fastapi-template`
- `infra-task/` — one-click Ghost deploy to a Hetzner VPS with no public SSH

The assignment text is in `ASSIGNMENT.md`. Read it before starting either task.

## Repo-wide

- **Never add `Co-Authored-By` or any AI attribution trailer to commit messages.**
- Small commits, one per plan step, conventional-commit style, single-line subject.
- Never commit secrets. Tokens and auth keys live in `infra-task/.env`, which is
  gitignored. Check `git log -p` for leaked credentials before pushing.
- Documentation is plain technical English: no emoji headers, no marketing tone,
  no filler paragraphs.
- Evidence before claims: don't say something works until you ran it and saw it work.

---

# dev-task: RBAC

Timeboxed. Keep scope tight. Roles: `admin`, `manager`, `member`.

## Non-negotiable

- **Never edit files under `dev-task/frontend/src/client/`** — generated from OpenAPI.
  After changing any API schema, run `bash scripts/generate-client.sh`.
- **Never modify test files to make tests pass.** If a test looks wrong, stop and ask.
- **Never add a role check inline in a route.** All permission data lives in a single
  matrix in `backend/app/core/permissions.py`. Adding a role = editing one dict.
- Any change to `models.py` requires an Alembic migration in the same commit.

## Authorization model

- `UserRole` enum + `role` column on `User` (single source of truth).
- `Permission` enum; `ROLE_PERMISSIONS: dict[UserRole, frozenset[Permission]]`.
- Enforcement: FastAPI dependency factory `require(Permission.X)` in `app/api/deps.py`.
- `/users/me` returns a computed `permissions: list[str]`; the frontend calls
  `can("users:read")` and never hardcodes role names.
- 401 = no/invalid token. 403 = authenticated but not permitted. Never 200 with empty data.

## Security invariants (check on every change)

- `UserUpdateMe` must not accept `role` or `is_superuser`.
- `/users/signup` must not accept `role` — always lowest privilege.
- A non-admin must not update another user's profile.
- Log denied attempts at WARNING with `user_id` and `permission`.

## Commands

All commands run from `dev-task/`.

```bash
# stack
docker compose up -d --build
docker compose exec -T backend bash -c 'cd /app/backend && bash scripts/prestart.sh'
bun install && bun run dev              # frontend :5173

# tests — run LOCALLY, they are not in the container image
cd backend && PYTHONUTF8=1 FASTAPI_ENV=development uv run pytest tests/ -q

# tests WIPE the dev database — always re-seed afterwards
docker compose exec -T backend bash -c 'cd /app/backend && python app/initial_data.py'

# regenerate the TypeScript client after schema changes
PYTHONUTF8=1 bash scripts/generate-client.sh
```

Windows: `PYTHONUTF8=1` is required (the template reads files without `encoding=`).
Git Bash mangles container paths — wrap them in `bash -c '...'` or set `MSYS_NO_PATHCONV=1`.

## Workflow

- Tests come from the permission matrix (parametrized, allowed **and** denied),
  plus explicit privilege-escalation tests.
- Verify in the browser as all three roles before claiming done; green tests are not enough.
- Keep biome's mass-reformatting noise out of feature commits.
