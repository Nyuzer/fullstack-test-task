# infra-task: what was built, what was verified, where it stopped

**Time spent:** ~1h30. Stopped because of Claude Code usage limits and the time
budget, not because the work reached a natural end.

**Status: incomplete.** The deploy runs end to end and provisions a working
Ghost on a Hetzner VPS with no public SSH, but the **public URL never served
traffic**, because Tailscale Funnel is not enabled on the tailnet used for the
test. The cause is identified and external to the code; see
[Where it stopped](#where-it-stopped).

---

## What works, with evidence

From the final run on 2026-11-02 (`cx23`, `ubuntu-24.04`, `nbg1`):

```
[ghost-deploy] phase 1/4: preflight
[ghost-deploy] tailnet prerequisites OK (tagOwners, funnel attr, ssh rule)
[ghost-deploy] server type cx23 is available in nbg1
[ghost-deploy] phase 2/4: provision
Waiting for create_server (server: 174156212, image: 161547269) ...
Waiting for apply_firewall (firewall: 11950882, server: 174156212) ... done
[ghost-deploy] created server 'ghost' (cx23, ubuntu-24.04, nbg1)
[ghost-deploy] phase 3/4: waiting for the tailnet node
[ghost-deploy] node registered as ghost.tail717c0c.ts.net
```

| Claim | Evidence |
|---|---|
| One command provisions everything | `./deploy.sh` ran phases 1-3 unattended |
| The firewall has zero inbound rules | `hcloud firewall list` → `ghost-deny-inbound  0 Rules` |
| The firewall is attached before first boot | `apply_firewall` completes inside `create_server`, per the output above |
| No SSH key is injected | `grep -rn '--ssh-key' lib/ cloud-init/` → comments only |
| The node joins the tailnet by dialling out | registered as `ghost.tail717c0c.ts.net` in under 300s |
| Tailscale SSH works for administration | `ssh root@ghost.tail717c0c.ts.net` returned the boot log and ran diagnostics |
| Ghost is running and healthy | on-node `curl http://127.0.0.1:2368/` → `301` (Ghost redirecting to its configured url) |
| Ghost boots on SQLite in production mode | `phase=ghost-healthy` was reached, which is gated on a successful local HTTP probe — this settles the open question in ADR-004 |
| Ghost derives its own public URL | `phase=resolve-url` succeeded; `/opt/ghost/.env` was written from `tailscale status --json` |
| Preflight fails before spending money | first run exited 3 on a missing `tagOwners` entry, having created nothing |
| Exit codes are distinct and bounded | observed 2 (bad arg, missing `.env`), 3 (policy, server type), 5 (funnel timeout) |

Boot phases recorded on the node, which is the mechanism the design relies on for
diagnosis:

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
12:10:42 phase=funnel          <- stopped here
```

Boot to a healthy Ghost took 79 seconds.

## Where it stopped

`deploy.sh` exited 5 after 600s with `HTTP 000` from the public URL, and printed
the boot phases above. Diagnosis over Tailscale SSH:

```
$ tailscale serve status
No serve config

$ pgrep -af ghost-bootstrap
6933 bash /usr/local/bin/ghost-bootstrap.sh      # still running, 14 min later

$ timeout 20 tailscale funnel --bg 2368 </dev/null
Funnel is not enabled on your tailnet.
To enable, visit:
         https://login.tailscale.com/f/funnel?node=n8hYYtMrT121CNTRL
exit=124                                          # killed by timeout, not finished

$ tailscale cert ghost.tail717c0c.ts.net
500 Internal Server Error: your Tailscale account does not support getting TLS certs
```

Two separate causes, one external and one ours:

**External: Funnel and HTTPS certificates are not enabled on this tailnet.** The
policy-file `nodeAttrs` entry that preflight checks is necessary but *not
sufficient* — Funnel also has to be switched on tailnet-wide, and HTTPS
certificates have to be enabled. Neither is exposed by the Tailscale API, so
preflight could not gate on them; it warned about the certificate requirement and
could not check the other at all.

**Ours: the `funnel` phase hung instead of failing.** `tailscale funnel --bg`
prints the consent URL and then waits indefinitely for someone to click it. With
no TTY it never returns, so the bootstrap sat at `phase=funnel` forever and wrote
neither `done` nor `FAILED`. Fixed in `41a8912`: the command is now wrapped in
`timeout 90` with stdin closed, and its output is appended to the status file —
so the consent URL now appears in the deploy output, turning an indefinite hang
into a named failure with its own remediation. **This fix has not been re-run
against a live deploy.**

### To finish it

1. Open <https://console.tailscale.com/admin/dns> and enable **HTTPS
   Certificates**.
2. Enable **Funnel** (the consent URL above, or the Funnel section of the DNS
   page).
3. `./destroy.sh && ./deploy.sh`

Expected total runtime is roughly 2-4 minutes. Everything up to and including a
healthy Ghost is already proven; only the last phase is unexercised.

## What the pre-deployment review caught

A review agent audited the implementation before the first real deploy. It found
no defect on the happy path, and ten real problems in the failure handling —
recorded in [ADR-006](adr/006-pre-deployment-review.md). Two mattered most:

- **The exit-5 diagnostic was dead code.** `wait_for_funnel` ended in `die`,
  which calls `exit`; being inside an `if !` suppresses `set -e`, not `exit`, so
  the `report_boot_phase` call after it was unreachable. Every document promised
  boot phases on exit 5 and none would have printed. This run is the proof the
  fix was worth it: the phase list above is the only reason the root cause was
  found in minutes rather than by guesswork.
- **sshd hardening ran before `tailscale up`**, inside the window ADR-002 exists
  to shrink, with no failure tolerance. A rejected sshd config would have bricked
  the box. Reordered and made non-fatal — and the `note=sshd-reload-skipped` line
  in the live run shows that tolerance being exercised for real.

The review also found three bugs in the preflight policy predicates — the exact
code ADR-005 named as most deserving a test when the test suite was cut. That
scope cut has now been paid for once.

## Known gaps

Honest list of what is not done or not proven:

- **The public URL has never served a request.** The Funnel phase is the only
  part of the pipeline with no successful run behind it.
- **The `timeout 90` fix is unverified** against a live deploy.
- **Preflight cannot check tailnet-wide Funnel enablement or HTTPS certificate
  status.** Neither is in the Tailscale API. A deploy will still get as far as
  the `funnel` phase before discovering it — now failing in 90s with the consent
  URL rather than hanging. Checking these would need a probe from a node that is
  already in the tailnet, which preflight by design does not have.
- **No automated tests** ([ADR-005](adr/005-no-automated-tests.md)).
- **No state file** ([ADR-001](adr/001-bash-over-terraform.md)); teardown deletes
  by naming convention.
- **SQLite is not a Ghost-supported production database**
  ([ADR-004](adr/004-sqlite-over-mysql.md)). It does boot, which was previously
  unproven, but should not carry real traffic.
- **`destroy.sh` has not been run against a live server** — only against an empty
  project, where it was correctly a no-op.
- No backups, no mail configuration, no custom domain, no monitoring.

## Scope cuts, and why

| Cut | Reason | ADR |
|---|---|---|
| Terraform | would stop this being one click; four resources created once | [001](adr/001-bash-over-terraform.md) |
| MySQL 8 | ~1 GB RAM for a blog with no readers | [004](adr/004-sqlite-over-mysql.md) |
| Automated test suite | harness comparable in size to the thing tested | [005](adr/005-no-automated-tests.md) |
| Auto-patching the tailnet policy | it governs every device the operator owns | [003](adr/003-verify-not-patch-policy.md) |

## Commit history

Eleven commits, one per step, each verified before being committed:

```
41a8912 fix(infra): time-box the funnel phase so it fails instead of hanging
141fd83 fix(infra): validate server type and location in preflight
7792011 docs(infra): correct claims invalidated by the pre-deployment review
5a50ccc fix(infra): use hcloud request-console and make teardown fail-safe
6da3620 fix(infra): bring Tailscale up before hardening and drop baked-in root password
31742fa fix(infra): add API timeouts, drop ephemeral keys, detect hostname collisions
85da6e2 fix(infra): make exit-5 report boot phases instead of dying silently
cbcbcc6 docs(infra): document the deploy model, runbook and ADRs
e09e790 feat(infra): add teardown and out-of-band console access
da66017 feat(infra): add one-click deploy orchestrator
08d7871 feat(infra): add bounded waits with distinct exit codes
3d1cac9 feat(infra): add hcloud wrappers with deny-all firewall
da7df15 feat(infra): add cloud-init template with tunnel-first bootstrap
a5c44c2 feat(infra): add verify-and-instruct preflight checks
6ec78f2 feat(infra): add Tailscale API client for keys and devices
3e621e0 feat(infra): add shared bash helpers and env template
```

## If there were more time

In priority order:

1. Enable Funnel and HTTPS certs, re-run, and prove the public URL serves 200 to
   a client with no Tailscale — plus the negative test that port 22 on the public
   IP is unreachable, which was specified but never executed.
2. Add back the test suite for the preflight policy predicates, which have now
   demonstrably harboured three bugs.
3. Run `destroy.sh` against a live server to prove teardown.
4. MySQL 8 instead of SQLite, since the demo constraint would no longer apply.
5. Back up the Ghost content volume somewhere off-box.
