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

[ "$#" -le 1 ] || die "$EXIT_USAGE" "too many arguments. Usage: ./deploy.sh [--preflight-only]"

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

log "phase 2/4: provision"
mkdir -p "$HERE/.run"
TS_AUTHKEY=$(ts_mint_authkey)
hz_firewall_ensure "$FIREWALL_NAME"
render_cloud_init "$HERE/cloud-init/ghost.yaml.tmpl" "$HERE/.run/cloud-init.yaml"
hz_server_create "$GHOST_HOSTNAME" "$SERVER_TYPE" "$SERVER_IMAGE" \
  "$SERVER_LOCATION" "$FIREWALL_NAME" "$HERE/.run/cloud-init.yaml"

# From here on a billable server exists. Any non-zero exit — including Ctrl-C
# during the multi-minute waits below — must say so, or it is silently orphaned.
trap 'ec=$?; if [ "$ec" -ne 0 ]; then
        printf "\n  A billable server named %s now exists.\n  Run ./destroy.sh to remove it.\n\n" "$GHOST_HOSTNAME" >&2
      fi; exit "$ec"' EXIT INT TERM

log "phase 3/4: waiting for the tailnet node"
FQDN=$(wait_for_node "$GHOST_HOSTNAME" 300 5)

log "phase 4/4: waiting for the public URL"
if ! wait_for_funnel "$FQDN" 600 10; then
  report_boot_phase "$FQDN"
  exit "$EXIT_NO_FUNNEL"
fi

trap - EXIT INT TERM

cat <<SUMMARY

  Ghost is live.

  Blog          https://${FQDN}/
  Admin setup   https://${FQDN}/ghost/
  Shell         ssh root@${FQDN}                 (over Tailscale SSH)
  Boot log      ssh root@${FQDN} 'cat /var/log/ghost-deploy/status'
  Break-glass   ./console.sh                     (out-of-band VNC, no SSH needed)
  Teardown      ./destroy.sh

  The VPS firewall has no inbound rules. Tailscale Funnel is the only ingress.

SUMMARY
