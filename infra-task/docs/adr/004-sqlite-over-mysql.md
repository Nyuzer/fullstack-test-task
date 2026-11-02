# ADR-004: SQLite instead of MySQL 8

## Status

Accepted, with a known limitation.

## Problem

The Ghost documentation states that MySQL 8 is the only supported database for
production, and that SQLite3 is supported only in development environments where
scalability and data consistency across upgrades are not critical.

## Options

**MySQL 8 in a second container.** Officially supported, and what a real
deployment should use.

**SQLite on a Docker volume.** One container, no credentials to generate, no
second service to wait for.

## Decision

SQLite, as a deliberate scope cut for a demo.

## Trade-offs

MySQL 8 wants roughly a gigabyte of memory to itself, which would push the VPS to
a larger instance for a blog with no readers. It also adds a service the
bootstrap has to wait for and a generated password to thread through cloud-init,
for no benefit to what this exercise demonstrates — namely that the deployment is
one click and the tunnel is the only ingress.

The cost is that this is not a configuration Ghost supports for production. Ghost
runs on SQLite with `NODE_ENV=production`, but upgrades and concurrent writes are
outside what upstream tests, so this should not carry real traffic. The
`ghost-healthy` phase in the bootstrap exists partly to catch this: if a future
Ghost release refuses to start on SQLite in production mode, the deploy fails
loudly at a named phase rather than serving a broken site.

Moving to MySQL later is a contained change: add a `mysql:8` service to
`compose.yml`, generate a password alongside the root password in `deploy.sh`,
and swap the four `database__*` environment variables. No other file changes.
