# ADR-005: No automated test suite

## Status

Accepted, as a scope cut.

## Problem

The logic worth testing here is small but real: preflight policy parsing,
cloud-init template rendering, exit-code selection, and device lookup. All of it
wraps external CLIs and HTTP APIs, so testing it means stubbing `curl` and
`hcloud`.

## Options

**A bash test suite.** A small dependency-free runner plus a `tests/fakebin/`
directory of stub executables prepended to `PATH`, letting the pure logic run
without touching a cloud account.

**No suite; verify each step directly.**

## Decision

No suite. Each build step was verified by exercising it directly, and the system
as a whole is verified by one real end-to-end deploy.

## Trade-offs

The deliverable is a one-click script, and a test harness is a second artifact
with its own runner, stub binaries, and fixtures to read and maintain — roughly
comparable in size to the thing being tested, for something deployed once.
Cutting it keeps the reviewable surface to the scripts that actually do the work.

What was given up is regression safety. The policy predicates in
`lib/preflight.sh` are the part that most deserves a test: their failure mode is
silently accepting a policy that does not actually grant Funnel to the tag, which
would surface only as a failed deploy minutes later. They were instead verified
by hand against a correct policy and against a member-only policy, confirming
both the accept and the reject path. That check is not repeatable without
re-running it by hand, so a later edit to those jq filters has nothing guarding
it.

If this were to be maintained rather than submitted, the suite is the first thing
to add back, starting with those three predicates.
