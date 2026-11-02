#!/usr/bin/env bash
# Break-glass out-of-band VNC console. This is the only way in when the server
# never joined the tailnet: it needs no SSH and no firewall change.
#
# Log in as root with the password below, then read:
#   /var/log/cloud-init-output.log   and   /var/log/ghost-deploy/status

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib/common.sh"
. "$HERE/lib/hetzner.sh"

load_env "$HERE/.env"

hz_server_exists "$GHOST_HOSTNAME" ||
  die "$EXIT_USAGE" "no server named '${GHOST_HOSTNAME}'"

# The hcloud CLI has no request-console subcommand, so call the API directly.
id=$(hz_server_id "$GHOST_HOSTNAME")
response=$(curl -fsS -X POST \
  "https://api.hetzner.cloud/v1/servers/${id}/actions/request_console" \
  -H "Authorization: Bearer ${HCLOUD_TOKEN}" \
  -H 'Content-Type: application/json') ||
  die "$EXIT_PREREQ" "could not request a console for server ${id}"

cat <<MSG

  Console URL   $(printf '%s' "$response" | jq -r '.wss_url')
  Password      $(printf '%s' "$response" | jq -r '.password')
  Root password $(cat "$HERE/.run/root-password" 2>/dev/null || echo '(not found; see the deploy output)')

  Note: Hetzner rescue mode is NOT a usable fallback here, because rescue mode
  is reached over SSH to the public IP, which this firewall blocks.

MSG
