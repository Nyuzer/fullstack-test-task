# One-click Ghost on Hetzner via Tailscale Funnel — Implementation Plan

**Goal:** `./deploy.sh` provisions a Hetzner VPS running Ghost, publicly reachable over HTTPS through Tailscale Funnel, with zero inbound firewall rules and admin access only via Tailscale SSH.

**Architecture:** A bash orchestrator runs four phases — preflight (verify credentials and tailnet prerequisites before spending money), provision (mint auth key, create deny-all firewall, create server with cloud-init), wait (poll the Tailscale API for node registration), verify (probe the public URL, and on failure read boot phases over Tailscale SSH). On the VPS, cloud-init establishes Tailscale SSH *first*, then Docker, then Ghost, then Funnel, so later failures stay recoverable.

**Tech Stack:** bash, `hcloud` CLI, `curl`, `jq`, cloud-init, Docker Compose, Ghost 5 (SQLite), Tailscale (SSH + Funnel), Hetzner Cloud API.

**Design:** `infra-task/docs/design.md`

**Exit codes:** `2` usage/missing tool or env var · `3` prerequisite unmet · `4` node never registered · `5` Funnel never served 200

**No automated test suite** — deliberate scope cut, see ADR-005. Each task below is verified by exercising it directly.

---

## Task 1: Shared helpers and environment loading

**Files:** create `infra-task/lib/common.sh`, `infra-task/.env.example`, `infra-task/.gitignore`

- [ ] **Step 1:** Install `jq` (missing on this machine; every JSON check needs it): `winget install --id jqlang.jq -e --accept-source-agreements`
- [ ] **Step 2:** Verify the toolchain: `for c in bash curl ssh jq hcloud; do printf '%-8s %s\n' "$c" "$(command -v $c || echo MISSING)"; done` — expect five paths, no `MISSING`.
- [ ] **Step 3:** Write `lib/common.sh`: exit-code constants, `log`/`warn`/`die`, `require_cmd`, `require_env`, `load_env` with defaults.
- [ ] **Step 4:** Write `.env.example` with `HCLOUD_TOKEN`, `TS_API_KEY`, `TS_TAILNET`, and the optional overrides commented out.
- [ ] **Step 5:** Write `.gitignore` ignoring `.run/` (holds the rendered cloud-init, which contains the single-use auth key).
- [ ] **Step 6: Verify** defaults apply and `require_env` exits 2:
  ```bash
  cd infra-task && bash -c '. lib/common.sh; load_env .env.example; echo "type=$SERVER_TYPE tag=$TS_TAG fw=$FIREWALL_NAME"'
  bash -c '. lib/common.sh; unset HCLOUD_TOKEN; require_env HCLOUD_TOKEN'; echo "exit=$?"
  ```
  Expect `type=cx22 tag=tag:ghost fw=ghost-deny-inbound`, then an error naming `HCLOUD_TOKEN` and `exit=2`.
- [ ] **Step 7: Verify** no secrets in the template: `grep -nE '=(tskey|[A-Za-z0-9]{20,})' .env.example || echo clean`
- [ ] **Step 8: Commit** `feat(infra): add shared bash helpers and env template`

---

## Task 2: Tailscale API client

**Files:** create `infra-task/lib/tailscale.sh`

- [ ] **Step 1:** Write `ts_api` (curl wrapper; `Accept: application/json` matters — the policy endpoint otherwise returns HuJSON with comments, which `jq` cannot parse). Feed the token via `curl --config -` on stdin, not argv, and set `--connect-timeout`/`--max-time`: these calls sit inside loops that advertise a deadline.
- [ ] **Step 2:** Write `ts_mint_authkey` — single-use, **not** ephemeral, pre-approved, tagged; dies with exit 3 naming `tagOwners` if the API returns no key. Ephemeral would deregister the server on any disconnect and change its Funnel FQDN.
- [ ] **Step 3:** Write `ts_device_count`, `ts_device_fqdn` (reads `.devices[].name`, strips the trailing dot, and dies rather than guessing if two devices share the hostname) and `ts_delete_device_by_hostname`.
- [ ] **Step 4: Verify** against the real API — this also confirms `TS_API_KEY` works:
  ```bash
  cd infra-task && bash -c '. lib/common.sh; . lib/tailscale.sh; load_env .env; ts_api GET "/tailnet/$TS_TAILNET/devices" | jq -r ".devices[].hostname"'
  ```
  Expect your existing device hostnames.
- [ ] **Step 5: Commit** `feat(infra): add Tailscale API client for keys and devices`

---

## Task 3: Verify-and-instruct preflight

**Files:** create `infra-task/lib/preflight.sh`

- [ ] **Step 1:** Write the pure predicates `policy_has_tag_owner`, `policy_has_funnel_attr`, `policy_has_ssh_rule` (jq over the policy JSON, return 0/1, print nothing).
- [ ] **Step 2:** Write `check_local_tools`, `check_config`, `check_hcloud_token`, `check_magicdns`, `check_hostname_free` (no existing Hetzner server *and* no existing tailnet device with that hostname).
- [ ] **Step 3:** Write `check_tailnet_policy` — on each failure print the literal JSON snippet to paste plus `console.tailscale.com/admin/acls`, then exit 3. Never writes the policy.
- [ ] **Step 4:** Write `warn_https_certs_unverifiable` (HTTPS cert status is not exposed by the API, so it is a logged reminder, not a gate) and `run_preflight`.
- [ ] **Step 5: Verify** the predicates reject a member-only policy, which is the realistic failure since `autogroup:member` does not cover tagged devices:
  ```bash
  cd infra-task && bash -c '
    . lib/common.sh; . lib/preflight.sh; TS_TAG=tag:ghost
    bad={\"nodeAttrs\":[{\"target\":[\"autogroup:member\"],\"attr\":[\"funnel\"]}]}
    policy_has_funnel_attr "$bad" && echo "BUG: accepted" || echo "correctly rejected"'
  ```
  Expect `correctly rejected`.
- [ ] **Step 6: Commit** `feat(infra): add verify-and-instruct preflight checks`

---

## Task 4: Cloud-init template and rendering

**Files:** create `infra-task/cloud-init/ghost.yaml.tmpl`, `infra-task/lib/render.sh`

- [ ] **Step 1:** Write the template: `write_files` for `/opt/ghost/compose.yml` (Ghost 5 on SQLite, bound to `127.0.0.1:2368`) and `/usr/local/bin/ghost-bootstrap.sh`, plus a `runcmd` that invokes the bootstrap.
- [ ] **Step 2:** The bootstrap script writes a phase marker to `/var/log/ghost-deploy/status` before each phase, in this order: `tailscale-install`, `tailscale-up`, `hardening`, `resolve-url`, `docker-install`, `docker-ready`, `ghost-up`, `ghost-healthy`, `funnel`, `cleanup`, `done`. Tailscale comes up first, before sshd hardening and before Docker exists, so any later failure leaves a debuggable box. An `ERR` trap records an `UNEXPECTED-FAILURE` marker for anything not routed through `fail`.
- [ ] **Step 3:** Write `lib/render.sh` — `render_cloud_init` only (mode 600, dies with exit 2 if any `__TOKEN__` survives). No root password is generated: user-data is readable from inside the instance, including from the Ghost container.
- [ ] **Step 4: Verify** rendering substitutes everything, the output is 600, and it is valid YAML:
  ```bash
  cd infra-task && mkdir -p .run && bash -c '
    . lib/common.sh; . lib/render.sh
    TS_AUTHKEY=tskey-auth-xyz GHOST_HOSTNAME=ghost TS_TAG=tag:ghost
    render_cloud_init cloud-init/ghost.yaml.tmpl .run/preview.yaml'
  grep -c '__[A-Z_]*__' .run/preview.yaml
  grep -ci 'chpasswd' .run/preview.yaml
  python -c "import yaml; yaml.safe_load(open('.run/preview.yaml')); print('valid yaml')"
  ```
  Expect `0`, `0`, `valid yaml`. (`stat -c '%a'` reports 644 on Git Bash/NTFS even
  though `chmod 600` ran — that filesystem only maps the read-only flag.)
- [ ] **Step 5: Verify** the rendered bootstrap is itself valid bash: extract it and run `bash -n`.
- [ ] **Step 6: Commit** `feat(infra): add cloud-init template with tunnel-first bootstrap`

---

## Task 5: Hetzner provisioning wrappers

**Files:** create `infra-task/lib/hetzner.sh`

- [ ] **Step 1:** Write `hz_firewall_exists`/`_create`/`_ensure`/`_delete`. The firewall is created with **no rules at all** — a Hetzner firewall with no inbound rules drops all inbound traffic while leaving outbound unrestricted, which is all Tailscale needs.
- [ ] **Step 2:** Write `hz_server_exists`, `hz_server_create`, `hz_server_delete`, `hz_server_id`, `hz_server_ip`. `server create` takes `--firewall`, which attaches before first boot and closes the window where port 22 would be reachable; `firewall apply-to-resource` gives no such guarantee. No `--ssh-key` is injected.
- [ ] **Step 3: Verify** the token works and no SSH path exists anywhere in the tree:
  ```bash
  cd infra-task && bash -c '. lib/common.sh; . lib/hetzner.sh; load_env .env; hcloud server list -o noheader; echo "token ok"'
  grep -rnE 'add-rule|--ssh-key|port.*\b22\b' lib/ cloud-init/ deploy.sh 2>/dev/null || echo "no inbound rules, no ssh keys"
  ```
- [ ] **Step 4: Commit** `feat(infra): add hcloud wrappers with deny-all firewall`

---

## Task 6: Bounded waits and verification

**Files:** create `infra-task/lib/verify.sh`

- [ ] **Step 1:** Write `http_status` and `read_boot_status` (the two functions that touch the outside world, kept separate so they are easy to reason about).
- [ ] **Step 2:** Write `wait_for_node` — polls `ts_device_fqdn`, prints the FQDN on success; on timeout prints the `console.sh` / destroy-and-redeploy remediation and exits 4.
- [ ] **Step 3:** Write `wait_for_funnel` — polls for HTTP 200, reports the last status code, exits 5 on timeout.
- [ ] **Step 4:** Write `report_boot_phase` — reads the phase markers over Tailscale SSH and prints them, so an exit 5 names the phase that failed.
- [ ] **Step 5: Verify** both timeout paths return the right codes using injected stubs:
  ```bash
  cd infra-task && bash -c '. lib/common.sh; . lib/verify.sh; http_status() { printf 502; }; wait_for_funnel x.ts.net 2 0' >/dev/null 2>&1; echo "funnel_timeout_exit=$?"
  bash -c '. lib/common.sh; . lib/tailscale.sh; . lib/verify.sh; ts_device_fqdn() { :; }; wait_for_node ghost 2 0' >/dev/null 2>&1; echo "node_timeout_exit=$?"
  ```
  Expect `funnel_timeout_exit=5` and `node_timeout_exit=4`.
- [ ] **Step 6: Commit** `feat(infra): add bounded waits with distinct exit codes`

---

## Task 7: The deploy orchestrator

**Files:** create `infra-task/deploy.sh`

- [ ] **Step 1:** Source the libs, parse `--preflight-only`, `load_env`, and refuse to proceed if a server with that name already exists.
- [ ] **Step 2:** Run the four phases; install an `EXIT`/`INT`/`TERM` trap after `hz_server_create` so an interrupt during the multi-minute waits cannot silently orphan a billable server; on a Funnel timeout call `report_boot_phase` before exiting 5. `wait_for_funnel` must `return`, not `die`, or the report is unreachable.
- [ ] **Step 3:** Print a summary: blog URL, admin URL, SSH command, boot-log command, break-glass command, teardown command.
- [ ] **Step 4: Verify** syntax and argument rejection:
  ```bash
  cd infra-task && chmod +x deploy.sh && bash -n deploy.sh && echo "syntax ok"
  bash deploy.sh --nonsense; echo "exit=$?"
  ```
  Expect `syntax ok`, an error naming `--nonsense`, `exit=2`.
- [ ] **Step 5: Verify** preflight against the real tailnet — **this is a gate; do not start Task 10 until it exits 0:**
  ```bash
  cd infra-task && cp .env.example .env   # then fill in both tokens
  bash deploy.sh --preflight-only; echo "exit=$?"
  ```
  Expect `exit=0`, or `exit=3` with a pasteable policy snippet.
- [ ] **Step 6: Commit** `feat(infra): add one-click deploy orchestrator`

---

## Task 8: Teardown and break-glass console

**Files:** create `infra-task/destroy.sh`, `infra-task/console.sh`

- [ ] **Step 1:** `destroy.sh` calls `require_env` up front (otherwise `set -u` aborts it part-way through), deletes the server, the firewall, and the tailnet device record, then removes `.run/`. Each delete is a no-op when absent, and a failing tailnet delete warns rather than stranding the local cleanup.
- [ ] **Step 2:** `console.sh` wraps `hcloud server request-console`, then explains how to open the console in the Hetzner web UI (the returned `wss://` URL is not browser-openable) and how to mint a root password with `hcloud server reset-password`. It notes that rescue mode is not a usable fallback here.
- [ ] **Step 3: Verify** syntax and that teardown is idempotent on an empty project:
  ```bash
  cd infra-task && chmod +x destroy.sh console.sh && bash -n destroy.sh && bash -n console.sh && echo "syntax ok"
  bash destroy.sh; echo "exit=$?"
  ```
  Expect `syntax ok`, three "nothing to delete" lines, `teardown complete`, `exit=0`.
- [ ] **Step 4: Commit** `feat(infra): add teardown and out-of-band console access`

---

## Task 9: Documentation and ADRs

**Files:** rewrite `infra-task/README.md`; create ADR-001..005 under `infra-task/docs/adr/`

- [ ] **Step 1:** ADR-001 — bash and hcloud CLI, Terraform rejected (not one click; heavy for four resources; cost admitted: no state file, so teardown deletes by naming convention).
- [ ] **Step 2:** ADR-002 — Tailscale before Docker and Ghost; VNC console as break-glass; rescue mode explicitly not usable.
- [ ] **Step 3:** ADR-003 — verify tailnet policy, never patch it.
- [ ] **Step 4:** ADR-004 — SQLite as a demo scope cut.
- [ ] **Step 5:** ADR-005 — no automated test suite; what is verified instead and what that costs.
- [ ] **Step 5b:** ADR-006 — what the pre-deployment review changed and why.
- [ ] **Step 6:** README — how it works, one-time tailnet setup with the exact policy JSON, requirements, deploy, operate, exit-code table, troubleshooting per exit code, scope cuts, ADR links.
- [ ] **Step 7: Verify** every internal link resolves:
  ```bash
  cd infra-task && for f in $(grep -o 'docs/adr/[0-9a-z-]*\.md' README.md | sort -u); do [ -f "$f" ] && echo "ok   $f" || echo "MISSING $f"; done
  ```
  Expect five `ok` lines.
- [ ] **Step 8: Commit** `docs(infra): document the deploy model, runbook and ADRs`

---

## Task 10: Real end-to-end run

Nothing above proves the deploy works — only that the logic is sound. This task produces the evidence.

- [ ] **Step 1:** `bash deploy.sh 2>&1 | tee .run/deploy-evidence.log` — expect phases 1/4 through 4/4 and the summary with a `https://ghost.<tailnet>.ts.net/` URL.
- [ ] **Step 2: Verify public reachability without tailnet membership** (the whole point of Funnel): `curl -s -o /dev/null -w '%{http_code}\n' https://$FQDN/` from a context with Tailscale off, expecting `200`, and the same for `/ghost/`.
- [ ] **Step 3: Verify there is no public SSH** — the core claim:
  ```bash
  IP=$(hcloud server ip ghost); echo "public ip: $IP"
  timeout 15 ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$IP" true; echo "exit=$?"
  ```
  Expect a timeout, not a login prompt. `Connection refused` or `Permission denied` would mean the port is reachable — that is a failure.
- [ ] **Step 4: Verify admin access works over Tailscale:** `ssh root@ghost 'cat /var/log/ghost-deploy/status; tailscale funnel status'` — expect markers ending `phase=done` and a 443 proxy to `127.0.0.1:2368`.
- [ ] **Step 5: Verify the firewall has no inbound rules:** `hcloud firewall describe ghost-deny-inbound` — expect an empty rule list and the server under applied-to.
- [ ] **Step 6:** Record the actual command output in `NOTES.md` under an `## infra-task` section. Evidence, not a summary of evidence.
- [ ] **Step 7: Verify teardown leaves nothing:** `bash destroy.sh && hcloud server list && hcloud firewall list`
- [ ] **Step 8: Verify no secret reached git:** `git log -p -- infra-task | grep -nE 'tskey-|HCLOUD_TOKEN=.+' || echo "no secrets in history"`
- [ ] **Step 9: Commit** `docs: record infra-task end-to-end verification evidence`
