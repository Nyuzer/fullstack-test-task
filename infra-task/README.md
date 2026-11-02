# Ghost on Hetzner, public via Tailscale Funnel, with no public SSH

One command provisions a Hetzner VPS running Ghost, publicly reachable over
HTTPS. The VPS firewall has **no inbound rules at all**. Tailscale Funnel is the
only ingress; administration is over Tailscale SSH.

> **Status: incomplete.** A live deploy reaches a healthy Ghost in 79 seconds,
> but the public Funnel URL has never served a request — Funnel and HTTPS
> certificates were not enabled on the test tailnet. What was verified, what was
> not, and how to finish it: [docs/outcome.md](docs/outcome.md).

## How it works

```
deploy.sh
  1. preflight    local tools, credentials, tailnet prerequisites  -> fails before spending money
  2. provision    mint auth key -> deny-all firewall -> server with cloud-init
  3. wait         poll the Tailscale API until the node registers
  4. verify       probe the public URL; on failure read boot phases over Tailscale SSH
```

On the VPS, cloud-init runs in a deliberate order — Tailscale SSH first, so any
later failure leaves a debuggable box rather than a brick (see
[ADR-002](docs/adr/002-tunnel-first-bootstrap.md)):

```
tailscale up --ssh --advertise-tags=tag:ghost      <- admin access first
  -> harden sshd (non-fatal; the firewall is the real control)
  -> resolve the .ts.net name from `tailscale status --json`
  -> install docker
  -> docker compose up -d        (Ghost on 127.0.0.1:2368, SQLite)
  -> tailscale funnel --bg 2368  (public on 443)
```

Each phase writes a marker to `/var/log/ghost-deploy/status`, so a failed deploy
can name the phase that broke.

## One-time tailnet setup

Funnel and Tailscale SSH both need policy entries for the tag of the server. The
default Funnel entry is **not** enough: `autogroup:member` does not include
tagged devices. Add these at
[console.tailscale.com/admin/acls](https://console.tailscale.com/admin/acls):

```json
{
  "tagOwners": { "tag:ghost": ["autogroup:admin"] },
  "nodeAttrs": [
    { "target": ["tag:ghost"], "attr": ["funnel"] }
  ],
  "ssh": [
    { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:ghost"], "users": ["root"] }
  ]
}
```

Also enable MagicDNS and HTTPS certificates at
[console.tailscale.com/admin/dns](https://console.tailscale.com/admin/dns).

`deploy.sh` verifies all of this and prints the exact snippet to paste if
anything is missing. It never modifies the policy file — see
[ADR-003](docs/adr/003-verify-not-patch-policy.md).

## Requirements

`bash`, `curl`, `ssh`, `jq`, and the
[hcloud CLI](https://github.com/hetznercloud/cli). On Windows use Git Bash;
install `jq` with `winget install --id jqlang.jq -e`.

You also need a Hetzner Cloud API token (Read & Write) and a Tailscale API access
token with policy-file read and auth-key create.

The default server type is `cx23` (2 vCPU, 4 GB, EU locations). Hetzner retires
type names over time, so preflight checks the type exists and is offered in your
chosen location, and lists the real options if not.

## Deploy

```bash
cd infra-task
cp .env.example .env            # fill in HCLOUD_TOKEN and TS_API_KEY
./deploy.sh --preflight-only    # optional: check prerequisites, create nothing
./deploy.sh
```

On success it prints the blog URL, the admin URL, and the SSH command. First
visit `https://<host>.<tailnet>.ts.net/ghost/` to create the Ghost owner account.

## Operate

```bash
ssh root@ghost                                        # shell, over Tailscale SSH
ssh root@ghost 'cat /var/log/ghost-deploy/status'     # boot phases
ssh root@ghost 'tailscale funnel status'              # ingress state
./console.sh                                          # break-glass VNC console
./destroy.sh                                          # remove everything
```

The bare `ghost` hostname works only if your own machine is in the tailnet with
MagicDNS; the full `ghost.<tailnet>.ts.net` name that `deploy.sh` prints always
works. Readers of the blog need neither — that is what Funnel is for.

## Exit codes

| Code | Meaning | What to do |
|------|---------|-----------|
| 2 | Missing tool, missing env var, or bad argument | the message names what is missing |
| 3 | Credential or tailnet prerequisite unmet | paste the printed policy snippet, re-run |
| 3 | The name is already taken by a Hetzner server or a tailnet device | `./destroy.sh`, or set `GHOST_HOSTNAME` to something else |
| 3 | `SERVER_TYPE`/`SERVER_LOCATION` invalid or incompatible | the message lists the types actually offered there |
| 4 | Server created but never joined the tailnet | `./console.sh`, then `hcloud server reset-password ghost` to log in; or `./destroy.sh && ./deploy.sh` |
| 5 | Node joined but the public URL never served 200 | the printed boot phases name the failed phase; the box is still reachable over Tailscale SSH |

## Troubleshooting

**Exit 4.** cloud-init failed before Tailscale came up, so there is no network
path in. Run `./console.sh`: it requests a console and tells you how to open it
in the Hetzner web UI and how to mint a root password with
`hcloud server reset-password`. Then read `/var/log/cloud-init-output.log`.
Hetzner rescue mode is not a usable fallback here: it is reached over SSH to the
public IP, which this firewall blocks.

**Exit 5, phase `funnel FAILED`.** Almost always a missing `funnel` node
attribute for `tag:ghost`, or HTTPS certificates not enabled. Fix the policy,
then `ssh root@ghost 'tailscale funnel --bg 2368'`.

**Exit 5, phase `ghost-healthy FAILED`.** Ghost did not start. Check
`ssh root@ghost 'docker compose -f /opt/ghost/compose.yml logs ghost'`.

## Scope cuts

Deliberate, with reasoning in the ADRs:

- **No Terraform** — it would stop this being one click
  ([ADR-001](docs/adr/001-bash-over-terraform.md)). Cost: no state file, so
  teardown deletes by naming convention.
- **SQLite, not MySQL 8** — not a Ghost-supported production configuration
  ([ADR-004](docs/adr/004-sqlite-over-mysql.md)). Do not put real traffic on it.
- **No automated tests** — each step was verified by hand instead
  ([ADR-005](docs/adr/005-no-automated-tests.md)). Cost: the preflight policy
  predicates have no regression guard — and the pre-deployment review found three
  real bugs in exactly those predicates
  ([ADR-006](docs/adr/006-pre-deployment-review.md)).

Also not included: backups, Ghost mail configuration, a custom domain, monitoring.

## Note for Windows

`lib/render.sh` chmods the rendered cloud-init to 600 because it contains the
single-use auth key. Git Bash on NTFS only maps the read-only flag, so `stat`
reports 644 there; the mode applies correctly when deploying from Linux or macOS.
The file lives in `.run/`, which is gitignored.

## Design decisions

- [ADR-001](docs/adr/001-bash-over-terraform.md) — bash and hcloud CLI, not Terraform
- [ADR-002](docs/adr/002-tunnel-first-bootstrap.md) — Tailscale before Docker and Ghost
- [ADR-003](docs/adr/003-verify-not-patch-policy.md) — verify tailnet policy, never patch it
- [ADR-004](docs/adr/004-sqlite-over-mysql.md) — SQLite as a demo scope cut
- [ADR-005](docs/adr/005-no-automated-tests.md) — no automated test suite
- [ADR-006](docs/adr/006-pre-deployment-review.md) — what the pre-deployment review changed

Full design: [docs/design.md](docs/design.md). Build plan: [docs/plan.md](docs/plan.md).
