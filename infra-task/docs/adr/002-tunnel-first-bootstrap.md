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
reachable with `ssh root@ghost`, and `deploy.sh` can read the phase markers off
it and name the phase that failed. Only a failure *before* `tailscale up` leaves
a brick, which narrows the unrecoverable window to installing one package.

For that remaining window the break-glass is the Hetzner VNC console
(`./console.sh`), which is out-of-band and needs neither SSH nor a firewall
change. This is why cloud-init sets a generated root password at all: console
login goes through getty, not sshd, so the password is useless to a remote
attacker while SSH password auth and root SSH login stay disabled.

Hetzner rescue mode is deliberately *not* part of the recovery path. Rescue mode
is reached over SSH to the public IP, which this firewall blocks, so using it
would require temporarily opening port 22 — undoing the premise of the exercise.
That caveat is documented rather than worked around.

The cost is ordering rigidity: the bootstrap cannot be reordered for speed, and
the Tailscale install script becomes a hard dependency of the very first phase.
