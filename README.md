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

Setup, the one-time tailnet prerequisites and the runbook are in
[`infra-task/README.md`](infra-task/README.md). What was verified against a live
deploy, and what was not, is in
[`infra-task/docs/outcome.md`](infra-task/docs/outcome.md).

`./deploy.sh` provisions a Hetzner VPS running Ghost, published over HTTPS
through Tailscale Funnel, with **no inbound firewall rules at all** — the server
dials out to join the tailnet and is never reachable from the internet directly.
Plain bash and the `hcloud` CLI rather than Terraform, so the deliverable stays
one command. The script runs four phases: a preflight that validates credentials,
tailnet policy and server type and refuses to spend money if anything is missing;
provisioning that mints a tagged auth key, creates a zero-rule firewall and
attaches it *at* server create so port 22 is never briefly exposed; a bounded
wait for the node to register; and a probe of the public URL. On the box,
cloud-init deliberately brings Tailscale SSH up **first**, before Docker or Ghost
exist, so any later failure leaves a debuggable machine rather than a brick, and
each phase writes a marker that the deploy script reads back over Tailscale SSH
when something fails. Ghost runs in Docker on SQLite, bound to loopback only.
Administration is Tailscale SSH; the break-glass path is the Hetzner VNC console,
and no root password is baked into user-data because Hetzner serves user-data to
anything in the instance network namespace, including the Ghost container.

A full run succeeds end to end: one command, no interaction, no SSH key anywhere
in the flow, ending at a live blog. Boot to a healthy Ghost measured 79 seconds.
Verified on live infrastructure: the firewall has zero rules and is attached
before first boot, the public hostname resolves to Tailscale edge addresses
rather than to the VPS, Ghost boots on SQLite in production mode, and preflight
refused to proceed twice — on a missing `tagOwners` entry and on a server type
Hetzner has retired.

**Not every scenario was tested.** The HTTP 200 in the final phase was measured
from a machine inside the tailnet, so it proves the certificate and the proxy but
not that a client *without* Tailscale can reach the blog; port 22 on the public
IP was never probed, resting instead on the verified zero-rule firewall;
`destroy.sh` never ran against a live server. The full list is in
[`outcome.md`](infra-task/docs/outcome.md#what-was-not-tested). Six decision
records, including one on what a pre-deployment review changed, are under
[`infra-task/docs/adr/`](infra-task/docs/adr/).
