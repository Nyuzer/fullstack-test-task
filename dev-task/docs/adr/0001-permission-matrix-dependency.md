# ADR 0001: Enforce authorization with a permission matrix and a dependency factory

Status: accepted
Date: 2026-11-01

## Context

The template ships a single `is_superuser` boolean, checked two inconsistent
ways: a route-level dependency on six endpoints, and ad-hoc
`if not current_user.is_superuser` branches inside five route bodies. The
assignment requires three roles and warns that adding a role should not mean
touching ten files. Two properties mattered most: a reader should understand the
whole model in a few minutes, and enforcement should be impossible to forget
when adding a route.

## Options

1. **Role checks at each route.** `if user.role != "admin": raise 403`.
   Smallest diff, no new concepts. Rejected: it scatters policy across the
   codebase, so adding a role means auditing every route, and the policy can
   only be read by grepping.
2. **A permission matrix plus a dependency factory.** A `ROLE_PERMISSIONS` dict
   mapping role to a frozenset of permissions, and `require(Permission.X)`
   producing a FastAPI dependency.
3. **A policy engine** (Casbin, oso, a rules DSL). Most capable, handles
   resource-level and attribute-based rules. Rejected as disproportionate for
   seven permissions and three roles.
4. **Middleware mapping URL paths to permissions.** Rejected: the mapping lives
   away from the routes it governs, path patterns drift silently from the
   router, and it cannot express conditional cases such as "self is always
   allowed".

## Decision

Option 2. Roles and permissions are string enums, the matrix is one dict in
`app/core/permissions.py`, and `require()` in `app/api/deps.py` turns a
permission into a dependency that raises 403 and logs the denial. Routes declare
their requirement in the decorator, so it is visible in the signature. The three
conditional routes call `has_permission()` in the body against the same matrix,
so there is still exactly one source of truth.

## Consequences

Adding a role is an enum member and a dict row; no route changes. The matrix is
the documentation, and the tests derive their expectations from it, so routes
drifting from policy fails the suite. `require()` is per-permission rather than
per-resource, so ownership rules remain hand-written in the three routes that
need them — acceptable at this size, and the point at which a policy engine
would start to pay for itself. Permissions are coarse: whoever may
create or update users can mint an admin, because no separate `roles:assign`
permission exists. That is safe while only `admin` holds those permissions, but
a future role granted `users:update_any` would silently inherit the ability to
grant admin.
