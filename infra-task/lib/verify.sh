# shellcheck shell=bash
# Bounded waits and probes. Every wait has a deadline and its own exit code, so
# the script never hangs and always says what to do next.
# Requires common.sh and tailscale.sh to be sourced first.

# The two functions that touch the outside world, kept separate and overridable.
http_status() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$1/"; }
read_boot_status() {
  ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    "root@$1" 'cat /var/log/ghost-deploy/status' 2>/dev/null
}

# wait_for_node <hostname> <attempts> <sleep-seconds>
# Prints the MagicDNS FQDN on success.
wait_for_node() {
  local host=$1 attempts=$2 delay=$3 i fqdn
  log "waiting for '${host}' to register in the tailnet"
  for i in $(seq 1 "$attempts"); do
    fqdn=$(ts_device_fqdn "$host" || true)
    if [ -n "$fqdn" ]; then
      log "node registered as ${fqdn}"
      printf '%s' "$fqdn"
      return 0
    fi
    sleep "$delay"
  done
  cat >&2 <<'MSG'

The server was created but never joined the tailnet, so there is no way in:
cloud-init probably failed before Tailscale came up.

  - read the cloud-init log over the out-of-band console:  ./console.sh
  - or discard it and try again:                           ./destroy.sh && ./deploy.sh

MSG
  die "$EXIT_NO_NODE" "node '${host}' did not register within $((attempts * delay))s"
}

# wait_for_funnel <fqdn> <attempts> <sleep-seconds>
wait_for_funnel() {
  local fqdn=$1 attempts=$2 delay=$3 i code=
  log "waiting for https://${fqdn}/ to serve 200"
  for i in $(seq 1 "$attempts"); do
    code=$(http_status "$fqdn")
    if [ "$code" = "200" ]; then
      log "public URL is live (HTTP 200)"
      return 0
    fi
    sleep "$delay"
  done
  warn "https://${fqdn}/ last returned HTTP ${code}"
  die "$EXIT_NO_FUNNEL" "Funnel did not serve 200 within $((attempts * delay))s"
}

# Reads the phase markers off the node and prints them. The node stays reachable
# over Tailscale SSH even when Ghost or Funnel failed, which is the whole point
# of bringing Tailscale up first (ADR-002).
report_boot_phase() {
  local status
  status=$(read_boot_status "$1" || true)
  if [ -z "$status" ]; then
    warn "could not read /var/log/ghost-deploy/status over Tailscale SSH"
    return 0
  fi
  printf '\n--- boot phases on %s ---\n%s\n\n' "$1" "$status" >&2
}
