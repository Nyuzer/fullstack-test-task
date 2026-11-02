# ADR 0002: Expose permissions to the frontend on a dedicated /users/me schema

Status: accepted
Date: 2026-11-01

## Context

The UI must hide controls the user cannot use and show a clear "access denied"
page on direct navigation. Before this change the frontend branched on
`UserPublic.is_superuser` in four places, and `/admin` silently redirected
non-superusers to `/`. The question was what representation of "what may this
user do" the backend should send, and on which schema.

## Options

1. **Send the role, branch on it in the frontend.** `user.role === "admin"`.
   Simple, but it duplicates the matrix in TypeScript, so adding a role means
   editing both sides and the two can disagree. Rejected.
2. **Put the role in the JWT and read the claims client-side.** No extra
   request. Rejected: it makes role changes take effect only after the token
   expires, and it invites treating a client-readable claim as authoritative.
3. **Send a computed permission list, on `UserPublic`.** The frontend gates on
   permission strings. Rejected in this form: `UserPublic` is also the row
   schema for the user-list endpoint, so every row in `/users/` would carry a
   redundant permission array.
4. **Send a computed permission list on a schema used only by `/users/me`.**

## Decision

Option 4. `UserMe` extends `UserPublic` with `permissions: list[str]`, computed
from `ROLE_PERMISSIONS` at serialization time, and is the response model for
`GET` and `PATCH /users/me` only. `useAuth` exposes `can(permission)`, and no
component compares a role name. The error handler distinguishes the two failure
modes: `401` clears the token and returns to login, `403` keeps the session and
lets the route render `Forbidden`.

## Consequences

Adding a role requires no frontend change, since the UI reacts to permissions it
is handed rather than to roles it knows about. The permission list is derived on
every `/users/me` response, so a role change takes effect on the next fetch
rather than on token expiry. Keeping the list off `UserPublic` costs one extra
schema and a small `to_user_me` helper.

The frontend gate is cosmetic by design: every permission is independently
enforced server-side. `can()` returns `false` while `/users/me` is in flight, so
gated controls appear a moment after the page — preferable to showing a control
that then disappears. The permission strings are now a published contract, which
is why the TypeScript `Permission` union is written out explicitly rather than
inferred as `string`.
