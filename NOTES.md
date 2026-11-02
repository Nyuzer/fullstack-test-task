# Notes

Context and trade-offs for the RBAC task in [`dev-task/`](dev-task/). The
permission matrix, setup steps and the approach itself are in
[`dev-task/README.md`](dev-task/README.md).

## Time spent

3.5 hours: 2.5 on implementation, 1 on documentation and review. That is over
the suggested 1-hour timebox. The overrun went into fixing the template so it
would run at all, splitting the work into one commit per step, verifying all
three roles by hand in a browser, and an authorization review pass — none of
which the timebox assumes.

## Added beyond the template

**A metrics endpoint.** The assignment lists a metrics/insights page in the
surface to protect and says a stub is acceptable. The template had no such
endpoint, so `GET /api/v1/metrics/` is new: it is gated on `metrics:read` and
returns live counts (total users, active users, total items) rather than a stub,
since the counts were a few lines on top of query patterns the template already
used. It exists mainly to give `manager` a capability that `admin` shares and
`member` lacks, which is what makes the middle role meaningful rather than a
subset of admin.

## Scope cuts

**Playwright end-to-end tests.** The template's Playwright suite authenticates
once in `auth.setup.ts` and shares a single `storageState` across every spec, so
all existing e2e tests run as the superuser. Covering three roles properly means
a setup project per role and reworking the existing specs' assumptions about who
is logged in. That is a larger change than the authorization code itself, and the
assignment lists comprehensive test coverage as the first thing to cut. The
backend authorization paths are covered by pytest instead, and the frontend was
verified by hand (below). The existing Playwright suite was not run; `admin.spec.ts`
asserts the Add User button is visible, which still holds for the superuser it
logs in as.

**No resource-level policy layer.** Ownership rules stay hand-written in the
three item routes that need them. A policy engine was considered and rejected in
[ADR 0001](dev-task/docs/adr/0001-permission-matrix-dependency.md).

**No `roles:assign` permission.** `users:create` and `users:update_any` each
carry the power to mint an admin. Safe while only `admin` holds them; noted in
ADR 0001 as the thing to add before granting either to a new role.

**Role management UI is minimal.** The admin table gained a role column and the
create/edit dialogs gained a role select. No bulk actions, no audit trail of who
changed whose role.

## Defects found in the template

**The backend did not parse.** `app/api/deps.py:36` had
`except InvalidTokenError, ValidationError:` — Python 2 syntax, a `SyntaxError`
on import. Nothing ran: not the server, not the test suite. Fixed in `2e918cc`
before any other work.

**A stale token left the frontend half-authenticated.** `isLoggedIn()` only
checks that a token string exists in `localStorage`. After the test suite wiped
the database, a token for a deleted user still passed that check, so the app
rendered the full authenticated shell — sidebar, layout, dashboard — for a user
that no longer existed. `GET /users/me` answered `404 "User not found"`, and the
global error handler in `main.tsx` only reacted to 401 and 403, so the 404 fell
through and every capability check silently read as false.

Two causes, both fixed: `get_current_user` returned the wrong status codes (404
for a vanished subject, 403 for an undecodable token — both are authentication
failures and now return 401, `dadcfaa`), and the frontend conflated 401 with
403, clearing the token on both. Once roles existed that second bug would have
logged a user out on every legitimate denial, which is the opposite of the
required behaviour, so the handler now acts only on 401 (`d7918cd`).

**`POST /api/v1/private/users/` is an unauthenticated account-creation
endpoint.** Template behaviour, mounted only when `FASTAPI_ENV == "development"`.
It creates `member` accounts, so it is not an escalation path, but the committed
`.env` sets `FASTAPI_ENV=development` and a deployment that reuses that file
would expose it. `compose.yml` does not set the variable, so a by-the-book deploy
is unaffected. Left as inherited behaviour rather than changed, since altering
the template's dev tooling is outside this task — but it is the one thing worth
checking before any real deployment, and no test asserts the endpoint is absent
when `FASTAPI_ENV` is unset.

## Known issues, accepted

**Stale error message.** `delete_user_me` and `delete_user` both answer
`"Super users are not allowed to delete themselves"`. The check now keys on the
`users:delete` permission rather than on a superuser flag, so the wording is
inaccurate. Left as-is: two existing tests pin the exact string
(`test_users.py:460` and `:505`), the repository rule is not to edit tests to
accommodate a change, and the fix is cosmetic.

**Unrecognised role value returns 500 on `/users/me`.** A role string written
directly to the database that the `UserRole` enum does not contain makes
`GET /users/me` fail with 500, because the `UserMe` response model cannot
serialize it. The authorization path itself is fail-closed and correct —
`permissions_for` returns an empty set, and the permission-gated routes answer
403 — so the consequence is a crash on one endpoint, not an access grant.
Reachable only by bypassing the application to write an invalid role.

## Verification

**Automated.** 86 pytest tests pass (the template's 58, unchanged, plus 28
authorization cases). Each of the backend commits was checked to import cleanly,
so the history bisects. The role migration was applied, downgraded and
re-applied against a populated database. `tsc --noEmit`, `ruff`, `ruff format`
and `mypy` are clean on the changed files.

**Manual.** All three roles were exercised by hand in the browser against the
running stack, across every row of the permission matrix and the edge cases
above: navigation entries present or hidden per role, direct navigation to
`/admin` and `/metrics` rendering the 403 page with the session intact rather
than redirecting or logging out, the Add User button and the per-row Edit and
Delete controls appearing only for the roles that hold the matching permission,
and the role select replacing the old superuser checkbox in both dialogs. The
same matrix was checked at the API with each role's token, confirming the status
codes match the table, including 401 for a missing or malformed token versus 403
for an authenticated caller without the permission.

An independent review pass over the authorization layer found no privilege
escalation: member escalation attempts through `PATCH /users/me`,
`POST /users/signup` and `POST /private/users/` are all dropped with the stored
row unchanged, and every manager write path returns 403.

## With more time

Per-role Playwright coverage; a `roles:assign` permission separating user
management from privilege granting; a test asserting `/private/users/` is
unmounted outside development; `404` rather than `403` for items the caller does
not own, matching the non-enumerable ordering already used for users; and
persisted audit records for denied attempts, which currently only reach the log
at WARNING.
