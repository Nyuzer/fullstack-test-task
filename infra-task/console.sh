#!/usr/bin/env bash
# Break-glass out-of-band access. This is the way in when the server never
# joined the tailnet: it needs no SSH and no firewall change.
#
# Two steps, because a VNC console still needs a password to log in with, and no
# password is baked into the image on purpose (see lib/render.sh).

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib/common.sh"
. "$HERE/lib/hetzner.sh"

[ "$#" -eq 0 ] || die "$EXIT_USAGE" "this command takes no arguments"

load_env "$HERE/.env"
require_env HCLOUD_TOKEN

hz_server_exists "$GHOST_HOSTNAME" ||
  die "$EXIT_USAGE" "no server named '${GHOST_HOSTNAME}'"

log "requesting a console for '${GHOST_HOSTNAME}'"
hcloud server request-console "$GHOST_HOSTNAME" ||
  die "$EXIT_PREREQ" "could not request a console for '${GHOST_HOSTNAME}'"

cat <<MSG

  The wss:// URL above is a WebSocket endpoint, not something a browser can
  open directly. In practice, use the web console:

    1. Open https://console.hetzner.com -> your project -> ${GHOST_HOSTNAME}
    2. Click the Console tab (top right)

  To get a root password to log in with:

    hcloud server reset-password ${GHOST_HOSTNAME}

  That prints a new root password and needs no SSH. It does require the qemu
  guest agent, which the Ubuntu cloud image ships with. If it fails, Hetzner
  also emailed a root password when the server was created, since no SSH key
  was injected.

  Once logged in, the two files worth reading are:

    /var/log/cloud-init-output.log     why the bootstrap failed
    /var/log/ghost-deploy/status       how far it got

  Note: Hetzner rescue mode is NOT a usable fallback here. Rescue mode is
  reached over SSH to the public IP, which this firewall blocks.

MSG
