#!/usr/bin/env bash
# One-click Ghost deploy: Hetzner VPS, no inbound ports, public via Tailscale Funnel.
# Usage: ./deploy.sh [--preflight-only]

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib/common.sh"
. "$HERE/lib/tailscale.sh"
. "$HERE/lib/preflight.sh"
. "$HERE/lib/render.sh"
. "$HERE/lib/hetzner.sh"
. "$HERE/lib/verify.sh"

PREFLIGHT_ONLY=false
case "${1:-}" in
  --preflight-only) PREFLIGHT_ONLY=true ;;
  "") ;;
  *) die "$EXIT_USAGE" "unknown argument '$1'. Usage: ./deploy.sh [--preflight-only]" ;;
esac

load_env "$HERE/.env"

log "phase 1/4: preflight"
run_preflight
if [ "$PREFLIGHT_ONLY" = true ]; then
  log "preflight passed; stopping here as requested"
  exit 0
fi

if hz_server_exists "$GHOST_HOSTNAME"; then
  die "$EXIT_USAGE" "a server named '${GHOST_HOSTNAME}' already exists. Run ./destroy.sh first, or set GHOST_HOSTNAME to something else."
fi

log "phase 2/4: provision"
mkdir -p "$HERE/.run"
ROOT_PASSWORD=$(generate_root_password)
printf '%s\n' "$ROOT_PASSWORD" > "$HERE/.run/root-password"
chmod 600 "$HERE/.run/root-password"

TS_AUTHKEY=$(ts_mint_authkey)
hz_firewall_ensure "$FIREWALL_NAME"
render_cloud_init "$HERE/cloud-init/ghost.yaml.tmpl" "$HERE/.run/cloud-init.yaml"
hz_server_create "$GHOST_HOSTNAME" "$SERVER_TYPE" "$SERVER_IMAGE" \
  "$SERVER_LOCATION" "$FIREWALL_NAME" "$HERE/.run/cloud-init.yaml"

log "phase 3/4: waiting for the tailnet node (up to 5 minutes)"
FQDN=$(wait_for_node "$GHOST_HOSTNAME" 60 5)

log "phase 4/4: waiting for the public URL (up to 8 minutes)"
if ! wait_for_funnel "$FQDN" 96 5; then
  report_boot_phase "$GHOST_HOSTNAME"
  exit "$EXIT_NO_FUNNEL"
fi

cat <<SUMMARY

  Ghost is live.

  Blog          https://${FQDN}/
  Admin setup   https://${FQDN}/ghost/
  Shell         ssh root@${GHOST_HOSTNAME}        (over Tailscale SSH)
  Boot log      ssh root@${GHOST_HOSTNAME} 'cat /var/log/ghost-deploy/status'
  Break-glass   infra-task/.run/root-password     (Hetzner VNC console only)
  Teardown      ./destroy.sh

  The VPS firewall has no inbound rules. Tailscale Funnel is the only ingress.

SUMMARY
