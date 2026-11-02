# ADR-001: Plain bash and the hcloud CLI instead of Terraform

## Status

Accepted.

## Problem

The brief asks for a one-click script. Provisioning needs a VPS, a firewall, a
Tailscale auth key, and then a wait-and-probe loop that confirms the tunnel came
up. Terraform is the default reflex for the first three.

## Options

**Terraform.** `hcloud_firewall` with no inbound rules, `hcloud_server` with
`user_data`, `tailscale_tailnet_key` for the auth key. Declarative, idempotent,
clean teardown via `terraform destroy`, and the security claim is readable off
the diff.

**Bash plus the hcloud CLI.** Imperative, but the whole deliverable is a handful
of files the reviewer can read top to bottom.

## Decision

Bash plus the `hcloud` CLI.

## Trade-offs

Terraform was rejected on two grounds. First, it is not one click: a reviewer has
to run `terraform init`, download two providers, and manage state before anything
happens, and Terraform cannot express "poll until the Funnel URL returns 200" —
so a wrapper script would be needed anyway, making the script the real entry
point and Terraform an extra layer underneath it. Second, the provider toolchain
is heavy relative to the task: four resources total, created once and destroyed
once, with no drift to reconcile and no team sharing state.

What we give up is real. There is no state file, so `destroy.sh` deletes by
convention — it derives resource names from `GHOST_HOSTNAME` — rather than from a
recorded inventory. If someone renames a resource by hand, teardown will miss it.
`deploy.sh` is idempotent only in the weak sense that it checks for an existing
server and refuses, rather than reconciling toward a desired state.

If this grew past a handful of resources, or more than one person deployed it,
that trade would flip and Terraform would become the right answer.
