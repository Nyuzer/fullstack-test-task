# ADR-002: Bring Tailscale up before Docker and Ghost

## Status

Accepted.

## Problem

With no public SSH, the tunnel is the only way in. If cloud-init fails, the
server is unreachable — there is no second channel to debug it.

## Options

**Install everything, then join the tailnet.** The natural reading order, and how
most cloud-init examples are written.

**Join the tailnet first, then install everything.**

## Decision

Join the tailnet first. `ghost-bootstrap.sh` runs `tailscale up --ssh` as its
second action, before Docker is installed and before Ghost exists.

## Trade-offs

This turns most failures from terminal into merely degraded. If the Docker
install script 503s, or Ghost will not boot on SQLite, or the Funnel command is
rejected because the policy file is missing a node attribute, the box is still
reachable over Tailscale SSH, and `deploy.sh` reads the phase markers off it and
names the phase that failed. Only a failure *before* `tailscale up` leaves a
brick, which narrows the unrecoverable window to: the apt stage (`curl`,
`ca-certificates`, `jq`), downloading and running the Tailscale install script,
and `tailscale up` itself.

Hardening sshd was originally the first phase, which widened that window for no
benefit and could abort the run outright if an sshd reload failed under
`set -e`. It now runs *after* `tailscale up`, and is non-fatal: the deny-all
firewall is attached at server create, so nothing is exposed in the interim, and
the drop-in that disables password and root login is written by cloud-init
itself rather than by a `sed` that could fail.

For that remaining window the break-glass is the Hetzner VNC console
(`./console.sh`), which is out-of-band and needs neither SSH nor a firewall
change. No root password is baked into the image: Hetzner serves user-data to
anything in the instance network namespace, including the Ghost container, so a
long-lived password there would turn a Ghost compromise into root on the box.
`console.sh` points at `hcloud server reset-password`, which mints one on demand
and needs no SSH. The bootstrap also shreds itself and the cached user-data once
the auth key is spent.

Hetzner rescue mode is deliberately *not* part of the recovery path. Rescue mode
is reached over SSH to the public IP, which this firewall blocks, so using it
would require temporarily opening port 22 — undoing the premise of the exercise.
That caveat is documented rather than worked around.

The cost is ordering rigidity: the bootstrap cannot be reordered for speed, and
the Tailscale install script becomes a hard dependency of the very first phase.
