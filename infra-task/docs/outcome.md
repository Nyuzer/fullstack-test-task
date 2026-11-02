# infra-task: what was built, what was verified, what was not

**Status: working.** `./deploy.sh` provisions a Hetzner VPS running Ghost,
published over HTTPS through Tailscale Funnel, with zero inbound firewall rules
and administration only over Tailscale SSH. A full run completed successfully on
2026-11-02.

**Time spent:** ~1h30. Work stopped on hitting Claude Code usage limits and the
time budget, so the test coverage below is partial — see
[What was not tested](#what-was-not-tested). That section is the important one.

---

## The successful run

```
[ghost-deploy] phase 1/4: preflight
[ghost-deploy] tailnet prerequisites OK (tagOwners, funnel attr, ssh rule)
[ghost-deploy] server type cx23 is available in nbg1
[ghost-deploy] phase 2/4: provision
[ghost-deploy] created firewall 'ghost-deny-inbound' with no inbound rules (all inbound traffic dropped)
Waiting for create_server (server: 174158959, image: 161547269) ...
Waiting for apply_firewall (firewall: 11951064, server: 174158959) ... done
[ghost-deploy] created server 'ghost' (cx23, ubuntu-24.04, nbg1)
[ghost-deploy] phase 3/4: waiting for the tailnet node
[ghost-deploy] node registered as ghost.tail717c0c.ts.net
[ghost-deploy] phase 4/4: waiting for the public URL
[ghost-deploy] public URL is live (HTTP 200)

  Ghost is live.

  Blog          https://ghost.tail717c0c.ts.net/
  Admin setup   https://ghost.tail717c0c.ts.net/ghost/
  ...
  The VPS firewall has no inbound rules. Tailscale Funnel is the only ingress.
```

One command, no interaction, no SSH key anywhere in the flow.

## Verified, with evidence

| Claim | Evidence |
|---|---|
| One command provisions everything | `./deploy.sh` ran all four phases unattended to a live blog |
| The firewall has zero inbound rules | `hcloud firewall describe ghost-deny-inbound` → `Rules: No rules` |
| The firewall is attached before first boot | `apply_firewall` completes inside `create_server`, per the output above |
| No SSH key is injected | `grep -rn '\-\-ssh-key' lib/ cloud-init/` → comments only |
| The node joins by dialling out, not by being reachable | registered as `ghost.tail717c0c.ts.net` within the 300s budget |
| Tailscale SSH works for administration | `ssh root@ghost.tail717c0c.ts.net` returned the boot log and ran diagnostics on the earlier run |
| Ghost serves HTTPS on the Funnel hostname | `deploy.sh` probe returned **HTTP 200** (caveat below) |
| The public hostname points at Tailscale, not at the VPS | `nslookup ghost.tail717c0c.ts.net 8.8.8.8` → `185.40.234.55/75/198`, `2a00:dd80:20::...` — Tailscale edge addresses, not the Hetzner IP |
| Ghost boots on SQLite in production mode | `phase=ghost-healthy` reached, which is gated on a successful local HTTP probe — this settles the open question in ADR-004 |
| Ghost derives its own public URL | `phase=resolve-url` succeeded; `/opt/ghost/.env` written from `tailscale status --json` |
| Preflight fails before spending money | first attempt exited 3 on a missing `tagOwners` entry, having created nothing |
| Preflight catches invalid infrastructure config | second attempt exited 3 on `SERVER_TYPE=cx22`, listing the types actually offered in `nbg1` |
| Exit codes are distinct and bounded | observed in practice: 2 (bad argument, missing `.env`), 3 (policy, server type), 5 (funnel timeout) |
| The exit-5 diagnostic works | the failing run printed the full boot-phase list, which is how the Funnel cause was found |

Boot phases from the earlier (failed) run, which is the only run whose node was
inspected before teardown:

```
12:09:12 phase=tailscale-install
12:09:26 phase=tailscale-up
12:09:27 phase=hardening
12:09:27 note=sshd-reload-skipped
12:09:27 phase=resolve-url
12:09:27 phase=docker-install
12:09:53 phase=docker-ready
12:09:53 phase=ghost-up
12:10:31 phase=ghost-healthy
```

**79 seconds from boot to a healthy Ghost.** The `note=sshd-reload-skipped` line
is the non-fatal hardening path from ADR-006 being exercised for real.

## What was not tested

Work stopped before the test matrix was finished. These are gaps, not
speculation — each is something a reviewer should assume is unproven.

### The one that matters most

**Public reachability was never verified from outside the tailnet.** The HTTP 200
in phase 4 was measured by `curl` running on a machine that is itself a tailnet
member with MagicDNS active, so `ghost.tail717c0c.ts.net` very likely resolved to
the node's tailnet address (`100.68.99.30`) rather than to Tailscale's public
edge. Funnel implies Serve, so that 200 proves the TLS certificate and the
reverse proxy to Ghost on 2368 both work — but it does **not** by itself prove a
client with no Tailscale can reach the blog.

The supporting evidence is strong (`tailscale funnel` succeeded, and public DNS
resolves the name to Tailscale edge IPs rather than to the VPS), but the direct
test was not run. To close it, from a machine with Tailscale stopped:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://ghost.<tailnet>.ts.net/
```

Or, without leaving the tailnet, by forcing resolution to the public edge:

```bash
curl -s -o /dev/null -w '%{http_code}\n' --resolve ghost.<tailnet>.ts.net:443:185.40.234.55 \
  https://ghost.<tailnet>.ts.net/
```

A sensible `deploy.sh` improvement is to do exactly that automatically — probe
via `--resolve` against a publicly-resolved address, so phase 4 proves public
reachability rather than mere reachability.

### Also untested

- **Port 22 on the public IP was never probed.** This is the headline security
  claim and it rests on the firewall having no rules (verified) rather than on an
  executed negative test. The server was destroyed before the check could run.
  The intended test is `ssh -o ConnectTimeout=10 root@<public-ip>`, which must
  *time out* — `Connection refused` or `Permission denied` would mean the port is
  reachable and would be a failure.
- **`destroy.sh` has never run against a live server.** It was only exercised
  against an empty project, where it correctly no-opped. After the successful run
  the server was removed outside the script, leaving a stale tailnet device named
  `ghost` and the (free) firewall behind — which is itself evidence that the new
  `check_hostname_free` preflight gate is needed, since it will now refuse the
  next deploy until `./destroy.sh` tidies up.
- **`console.sh` and the break-glass path were never exercised.** The exit-4
  branch (node never registers) never occurred, so neither
  `hcloud server request-console` nor `hcloud server reset-password` has been run.
- **The `timeout 90` fix on the `funnel` phase has not been re-run in anger.**
  It was added after diagnosing the hang, and the subsequent run succeeded — so
  the *failure* path it exists for is unexercised. Its mechanism was verified by
  hand (`timeout 20 tailscale funnel --bg 2368 </dev/null` → exit 124 plus the
  consent URL), but not through a full deploy.
- **Ghost was never used.** No owner account was created, no post written, no
  image uploaded. `/ghost/` returned 200; nothing beyond that was touched.
- **Reboot persistence is untested.** `tailscale funnel --bg` is documented to
  resume after a reboot, and `restart: unless-stopped` should bring Ghost back,
  but the server was never rebooted to confirm the blog survives it.
- **Idempotency and re-runs are only partly covered.** A second `./deploy.sh`
  against existing resources now exits 3 by design; that path was reached by
  accident rather than tested deliberately, and the interaction between a stale
  tailnet device and a fresh server was never run to completion.
- **The interrupt path is untested.** The `EXIT`/`INT`/`TERM` trap added for
  orphaned servers was never triggered with a real Ctrl-C mid-deploy.
- **No failure injection.** Nothing was tested against a Docker install failure,
  a Ghost image pull failure, an apt mirror outage, or a revoked token mid-run.
- **One location, one size, one image.** Only `cx23` / `ubuntu-24.04` / `nbg1`
  was ever deployed. Arm (`cax*`) would need a different Docker install path and
  was not attempted.
- **No concurrency or load testing**, which matters more than usual given SQLite
  ([ADR-004](adr/004-sqlite-over-mysql.md)).
- **No automated regression tests at all**
  ([ADR-005](adr/005-no-automated-tests.md)) — so none of the above is guarded
  against future edits.

## What went wrong on the way, and what fixed it

**First attempt** exited 3: the tailnet policy had no `tagOwners` entry for
`tag:ghost`. Preflight caught it before creating anything — the intended
behaviour from [ADR-003](adr/003-verify-not-patch-policy.md).

**Second attempt** failed in provisioning with a bare `Server Type not found:
cx22` and exit 1, after the firewall had been created. `cx22` has been retired by
Hetzner; the Intel shared line is now `cx23/cx33/cx43/cx53`. Fixed by correcting
the default and adding a preflight check that validates the type and location
against the API and lists the real options, so the failure is free and
actionable.

**Third attempt** reached `phase=funnel` and hung there, exiting 5 after 600s
with `HTTP 000`. Diagnosis over Tailscale SSH:

```
$ tailscale serve status
No serve config
$ pgrep -af ghost-bootstrap
6933 bash /usr/local/bin/ghost-bootstrap.sh      # still running, 14 min later
$ timeout 20 tailscale funnel --bg 2368 </dev/null
Funnel is not enabled on your tailnet.
To enable, visit: https://login.tailscale.com/f/funnel?node=...
exit=124                                          # killed by timeout, not finished
$ tailscale cert ghost.tail717c0c.ts.net
500 Internal Server Error: your Tailscale account does not support getting TLS certs
```

Two separate causes:

- **External:** Funnel and HTTPS certificates were not enabled on the tailnet.
  The policy `nodeAttrs` entry that preflight checks is necessary but not
  sufficient. Neither setting is exposed by the Tailscale API, so preflight could
  not gate on them; it warned about the certificate requirement and could not
  check Funnel enablement at all. Enabling both made the next run succeed.
- **Ours:** `tailscale funnel --bg` prints the consent URL and then waits
  indefinitely for someone to click it. With no TTY it never returned, so the
  bootstrap sat at `phase=funnel` forever, writing neither `done` nor `FAILED`.
  Fixed in `41a8912`: wrapped in `timeout 90` with stdin closed, with its output
  appended to the status file — so the consent URL now reaches the operator
  through the deploy output, and an indefinite hang becomes a named failure
  carrying its own remediation.

## What the pre-deployment review caught

A review agent audited the implementation before the first real deploy. It found
no defect on the happy path and ten real problems in the failure handling, all
recorded in [ADR-006](adr/006-pre-deployment-review.md). Two earned their keep
within the hour:

- **The exit-5 diagnostic was dead code.** `wait_for_funnel` ended in `die`,
  which calls `exit`; being inside an `if !` suppresses `set -e`, not `exit`, so
  the `report_boot_phase` call after it was unreachable. Every document promised
  boot phases on exit 5 and none would have printed. The failing run above is the
  proof: that phase list is the only reason the Funnel cause was found in minutes
  instead of by guesswork.
- **sshd hardening ran before `tailscale up`**, inside the window ADR-002 exists
  to shrink, with no failure tolerance — a rejected sshd config would have bricked
  the box with no way in. Reordered and made non-fatal, and the live
  `note=sshd-reload-skipped` line shows that tolerance being used.

The review also found three bugs in the preflight policy predicates: a false
positive and two false negatives, in exactly the code
[ADR-005](adr/005-no-automated-tests.md) had named as most deserving a test when
the suite was cut. That scope cut has now been paid for once.

## Scope cuts, and why

| Cut | Reason | ADR |
|---|---|---|
| Terraform | would stop this being one click; four resources, created once | [001](adr/001-bash-over-terraform.md) |
| MySQL 8 | ~1 GB RAM for a blog with no readers | [004](adr/004-sqlite-over-mysql.md) |
| Automated test suite | harness comparable in size to the thing tested | [005](adr/005-no-automated-tests.md) |
| Auto-patching the tailnet policy | it governs every device the operator owns | [003](adr/003-verify-not-patch-policy.md) |

Also out of scope: backups, Ghost mail configuration, a custom domain,
monitoring.

## If there were more time

In priority order:

1. Close the two evidence gaps above — an external fetch proving public
   reachability, and the port-22 negative test. Then make phase 4 probe via
   `--resolve` so every deploy proves public reachability by construction.
2. Add back the test suite for the preflight policy predicates, which have
   demonstrably harboured three bugs.
3. Run `destroy.sh` against a live server, and make `deploy.sh` tolerate a stale
   tailnet device by offering to remove it rather than only refusing.
4. Probe Funnel enablement from the node during the bootstrap and fail early with
   the consent URL, rather than discovering it at the last phase.
5. MySQL 8 instead of SQLite, since the demo constraint would no longer apply.
6. Back up the Ghost content volume off-box.
