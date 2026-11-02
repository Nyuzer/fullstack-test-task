# ADR-006: Changes made after the pre-deployment review

## Status

Accepted. Recorded because several of these reversed earlier decisions in this
same ADR set.

## Problem

The implementation was written and verified step by step, then reviewed in full
before the first real deploy. The review found no wrong CLI flag, no invalid
cloud-init YAML and no quoting bug on the happy path — but it found that the
**failure** handling did not work, and that two earlier decisions here were
wrong. Since ADR-002 and ADR-004 asserted things the code did not do, the record
needed correcting rather than quietly patching.

## Decisions

**The exit-5 diagnostic was dead code.** `wait_for_funnel` ended in `die`, which
calls `exit`. Being inside an `if !` condition suppresses `set -e`, not `exit`,
so the `report_boot_phase` call after it was unreachable. The exit code was
right; the boot-phase report that README, design.md and ADR-002 all promised was
never printed — precisely when it was most needed. `wait_for_funnel` now
`return`s its code. `wait_for_node` still dies, correctly: an unregistered node
has nothing to report.

**sshd hardening ran before Tailscale, inside the window ADR-002 exists to
shrink.** Four hardening commands ran under `set -euo pipefail` with no failure
tolerance, before `tailscale up`. A rejected sshd config would have aborted the
bootstrap with no tailnet access and no `FAILED` marker — a bricked box. The
hardening now runs after `tailscale up` and is non-fatal, and the config is a
cloud-init `write_files` drop-in rather than a `sed` that can fail. The drop-in
is named `00-` deliberately: `Include /etc/ssh/sshd_config.d/*.conf` sits at the
top of `sshd_config` and sshd takes the *first* value for a keyword, so a `99-`
prefix would lose to a `50-cloud-init.conf` that re-enabled password auth.
ADR-002 also understated the unrecoverable window as "one package"; it is now
stated accurately.

**Ephemeral auth keys were the wrong choice.** An ephemeral node is deregistered
shortly after it disconnects, so a network blip or a tailscaled restart would
drop a server meant to stay up; on rejoin MagicDNS would name it `ghost-1`,
silently diverging from the URL Ghost was configured with. `destroy.sh` already
deletes the device record explicitly, so ephemeral bought nothing and cost name
stability. Now `"ephemeral": false`.

**No root password is baked into the image any more.** Hetzner serves user-data
to anything in the network namespace of the instance, including the Ghost
container, so the break-glass password was reachable from a Ghost compromise —
turning a container escape into root via the console. `console.sh` now wraps
`hcloud server request-console` and points at `hcloud server reset-password`,
which mints one on demand. The bootstrap also shreds itself and the cached
user-data once the auth key is spent.

**`hcloud server request-console` exists.** Three documents and a code comment
claimed it did not, and `console.sh` hand-rolled an API call with the token in
`curl` argv as a result. The claim came from reading a truncated `--help`
output. The CLI call replaces it, which also removes that token from argv.

**Smaller corrections.** `ts_api` had no `curl` timeouts, so a stalled API could
hang a deploy with a billable server running, contradicting the "every wait is
bounded" claim; both waits now use wall-clock deadlines so the advertised budget
is the real one. `deploy.sh` had no `trap`, so Ctrl-C during the multi-minute
waits orphaned a server silently. `jq -r '.Self.DNSName'` yields the string
`null` rather than empty, which would have passed the emptiness guard and
configured Ghost with `https://null`; it now uses `// empty` plus a `.ts.net`
check. Preflight now refuses to start when the hostname is already taken by a
Hetzner server or a tailnet device. The policy predicates accept `"*"` wildcards
(they previously rejected valid policies) and check `src` (they previously
accepted a rule granting root to an unrelated source). `destroy.sh` validates
its environment up front, because `set -u` would otherwise abort it after
deleting the server but before reporting.

## Trade-offs

Most of this is strictly less code or the same amount. The exceptions are the
`trap`, the hostname-collision check and the `ERR` trap in the bootstrap, which
add a little surface in exchange for failures that announce themselves.

The review also vindicated ADR-005 in an uncomfortable way: the policy
predicates it named as the thing most deserving a test turned out to have both a
false positive and two false negatives. Hand-verification had checked the happy
path and the realistic failure, and missed the wildcard and `src` cases entirely.
That is the cost of the no-test decision, now paid once.

Two risks remain unverified and can only be settled by the real deploy: whether
`ghost:5-alpine` actually boots on SQLite with `NODE_ENV=production`
(see ADR-004), and whether Funnel behaves as expected on a tagged node.
