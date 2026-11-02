# ADR-003: Verify tailnet policy prerequisites, never patch them

## Status

Accepted.

## Problem

Funnel requires a `nodeAttrs` entry granting `funnel` to the tag of the server,
and Tailscale SSH requires an `ssh` rule for that tag. The Tailscale
documentation notes that `autogroup:member` does not include tagged devices, so
the default Funnel entry that works for a laptop does not cover a tagged server.
Inside cloud-init there is no interactive "visit this URL to enable Funnel"
fallback, so a missing attribute is a silent failure at the last phase of the
deploy.

## Options

**Patch the policy file.** `GET` the policy, merge in the two entries, `POST` it
back. Most literally one click.

**Verify and instruct.** Read the policy, refuse to proceed if either entry is
missing, print the exact snippet and the admin console URL.

## Decision

Verify and instruct.

## Trade-offs

Patching was rejected because the policy file is tailnet-wide: it governs every
device the operator owns, not just this server. A deploy script for a demo blog
silently rewriting the access-control policy for an entire tailnet is a bad
default, and a `POST` that clobbers a concurrent edit is worse than a clear error
message. It would also require a token with policy-file write scope, where read
is enough.

The cost is that a first-run deploy can stop with an error instead of finishing,
which is a real dent in the one-click claim. This is mitigated by placing the
check in preflight, before any billable resource exists, and by printing the
literal JSON to paste — so the fix is a copy, a paste, and a re-run, with nothing
to clean up. `./deploy.sh --preflight-only` lets the operator confirm
prerequisites without creating anything.

HTTPS certificate status is not exposed by the Tailscale API, so it is a logged
reminder rather than a gate. A missing certificate surfaces as a failed `funnel`
phase, which the post-deploy report reads off the node.
