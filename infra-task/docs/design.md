# One-click Ghost deploy to Hetzner over Tailscale Funnel — Design

**Date:** 2026-11-02
**Scope:** `infra-task/`
**Status:** Approved

## Goal

A single command, `./deploy.sh`, provisions a Hetzner VPS running Ghost, reachable
publicly over HTTPS via Tailscale Funnel, with **zero inbound ports open** on the
VPS firewall. Administration happens over Tailscale SSH. `./destroy.sh` removes
everything.

## Constraints

- No public SSH. The VPS firewall has no inbound rules at all.
- One command to deploy. No Terraform, no Ansible, no second phase.
- Plain `bash` plus the `hcloud` CLI, `curl`, and `jq`.
- The script never mutates the tailnet policy file.

## Architecture

```
deploy.sh
  1. preflight    local tools, credentials, tailnet prerequisites  -> fail before spending money
  2. provision    mint auth key -> create deny-all firewall -> create server with cloud-init
  3. wait         poll the Tailscale API until the node registers
  4. verify       probe the public Funnel URL; on failure read boot phases over Tailscale SSH
```

On the VPS, cloud-init runs in a deliberate order:

```
install tailscale, `tailscale up --ssh --advertise-tags=tag:ghost`      (admin access first)
  -> harden sshd via a 00- drop-in
  -> derive the .ts.net name from `tailscale status --json`
  -> install docker
  -> write /opt/ghost/compose.yml, `docker compose up -d`                  (Ghost on 127.0.0.1:2368)
  -> `tailscale funnel --bg 2368`                                          (public ingress last)
```

Admin access is established in the *first* step so that every later failure is
recoverable over Tailscale SSH instead of being terminal.

## Key decisions

### Bash + hcloud CLI, not Terraform

Terraform would need `terraform init`, a provider download, state handling, and a
second tool for the wait-and-probe loop — so the deliverable stops being one
click. Rejected; recorded as ADR-001.

### Verify-and-instruct, not auto-patch, for tailnet policy

Funnel requires a `nodeAttrs` entry granting `funnel` to `tag:ghost`, and Tailscale
SSH requires an `ssh` rule for `dst: tag:ghost`. Tailscale's docs note that
`autogroup:member` does **not** include tagged devices, so a policy that works for
a laptop will not work for a tagged server. The script reads the policy file
(`GET /tailnet/{tailnet}/acl` with `Accept: application/json`, which returns
parseable JSON rather than HuJSON) and refuses to proceed if either entry is
missing, printing the exact snippet to paste and the admin-console URL. It never
writes a tailnet-wide security policy on the user's behalf. Recorded as ADR-003.

### SQLite, not MySQL

Ghost officially supports only MySQL 8 in production; SQLite is documented as
development-only. MySQL 8 also wants ~1 GB RAM to itself. For a demo this is a
deliberate simplification, recorded as ADR-004, with a `ghost-healthy` bootstrap
phase that fails loudly if Ghost refuses to start.

### Ghost's public URL is derived on the node, not constructed by the client

Ghost needs its `url` at boot, but the Funnel FQDN does not exist until the node
registers. The bootstrap script resolves it on the node from
`tailscale status --json` (`.Self.DNSName`) after `tailscale up`, then writes
`/opt/ghost/.env` for Docker Compose. That removes the chicken-and-egg and avoids
assuming the operator already has a device in the tailnet. `deploy.sh`
independently reads the same name from the API to print and probe the URL.

## Failure handling

Each wait is bounded and exits with a distinct code plus a remediation message.

| Code | Meaning | Recovery |
|------|---------|----------|
| 2 | Missing local tool or env var, or bad argument | message names the tool/var |
| 3 | Tailnet or credential prerequisite unmet | message names the console page and the policy snippet |
| 4 | Node never registered in the tailnet | box is unreachable; `./console.sh` to read cloud-init logs, or destroy and redeploy |
| 5 | Funnel URL never returned 200 | node is reachable; script prints the boot phases read over Tailscale SSH |

Both waits use wall-clock deadlines, and every outbound `curl` has a connect and
total timeout, so an unresponsive API cannot hang a deploy with a billable server
running.

cloud-init appends to `/var/log/ghost-deploy/status` after each phase, so once the
node registers the script can report exactly how far boot got.

For the unreachable cases the break-glass path is the Hetzner VNC console
(`hcloud server request-console`, wrapped by `console.sh`). It is out-of-band and
needs no SSH and no firewall change. No root password is baked into the image:
Hetzner serves user-data to anything in the instance network namespace, including
the Ghost container, so a long-lived password there would be a container-escape
path to root. `console.sh` directs the operator to `hcloud server reset-password`
instead, which mints one on demand.

Hetzner rescue mode is *not* a clean fallback, because rescue mode is reached
over SSH to the public IP, which this firewall blocks; that caveat is documented
rather than papered over.

## File structure

| Path | Responsibility |
|------|----------------|
| `infra-task/deploy.sh` | orchestrator, arg parsing, summary output |
| `infra-task/destroy.sh` | teardown of server, firewall, tailnet device |
| `infra-task/console.sh` | break-glass out-of-band VNC console |
| `infra-task/lib/common.sh` | logging, `die`, `require_cmd`, env loading, exit codes |
| `infra-task/lib/tailscale.sh` | Tailscale API: mint key, find device, delete device |
| `infra-task/lib/preflight.sh` | all verify-and-instruct checks |
| `infra-task/lib/render.sh` | cloud-init templating |
| `infra-task/lib/hetzner.sh` | `hcloud` wrappers: firewall, server, id, ip |
| `infra-task/lib/verify.sh` | bounded waits and probes |
| `infra-task/cloud-init/ghost.yaml.tmpl` | user-data template |
| `infra-task/README.md` | one-time tailnet setup, usage, exit codes, troubleshooting |
| `infra-task/docs/adr/` | ADR-001..005 |

## Verification approach

There is no automated test suite — a deliberate scope cut, recorded as ADR-005.
Each build step is verified by exercising it directly: syntax checks, rendering the
cloud-init template and parsing it as YAML, running `./deploy.sh --preflight-only`
against the real tailnet, and grepping the tree to prove no inbound rule or SSH key
exists anywhere. The security claim is verified against the live server: the public
URL must serve 200 to a client with no Tailscale, and port 22 on the public IP must
be unreachable.

## Out of scope

Automated tests, backups, Ghost mail configuration, a custom domain, monitoring,
multi-environment support.
