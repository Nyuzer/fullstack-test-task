#!/usr/bin/env bash
# Removes everything deploy.sh created. Each delete is a no-op when absent.

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib/common.sh"
. "$HERE/lib/tailscale.sh"
. "$HERE/lib/hetzner.sh"

[ "$#" -eq 0 ] || die "$EXIT_USAGE" "this command takes no arguments"

load_env "$HERE/.env"
# Checked up front: without these, the deletes below would abort part-way under
# `set -u`, leaving the operator unsure which resources actually went away.
require_env HCLOUD_TOKEN
require_env TS_API_KEY

# Server before firewall: Hetzner refuses to delete a firewall still applied to
# a resource.
hz_server_delete "$GHOST_HOSTNAME"
hz_firewall_delete "$FIREWALL_NAME"

# Non-fatal: a Tailscale API hiccup must not strand the local cleanup below, and
# a leftover device record is visible and removable in the admin console.
ts_delete_device_by_hostname "$GHOST_HOSTNAME" ||
  warn "could not remove the tailnet device; check https://console.tailscale.com/admin/machines"

rm -rf "$HERE/.run"
log "teardown complete"
