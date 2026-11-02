#!/usr/bin/env bash
# Removes everything deploy.sh created. Each delete is a no-op when absent.

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib/common.sh"
. "$HERE/lib/tailscale.sh"
. "$HERE/lib/hetzner.sh"

load_env "$HERE/.env"

hz_server_delete "$GHOST_HOSTNAME"
hz_firewall_delete "$FIREWALL_NAME"

# The auth key is single-use and ephemeral, so it expires on its own. The device
# record is removed explicitly in case the node never shut down cleanly.
ts_delete_device_by_hostname "$GHOST_HOSTNAME"

rm -rf "$HERE/.run"
log "teardown complete"
