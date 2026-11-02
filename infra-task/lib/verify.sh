# shellcheck shell=bash
# Bounded waits and probes. Every wait has a wall-clock deadline and its own
# exit code, so the script never hangs and always says what to do next.
# Requires common.sh and tailscale.sh to be sourced first.

# The two functions that touch the outside world, kept separate and overridable.
http_status() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$1/"; }
read_boot_status() {
  ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes \
    "root@$1" 'cat /var/log/ghost-deploy/status' 2>/dev/null
}

# wait_for_node <hostname> <budget-seconds> <poll-seconds>
# Prints the MagicDNS FQDN on success. Dies on timeout: there is nothing left to
# report, because an unregistered node is unreachable.
wait_for_node() {
  local host=$1 budget=$2 poll=$3 deadline fqdn
  deadline=$((SECONDS + budget))
  log "waiting up to ${budget}s for '${host}' to register in the tailnet"
  while [ "$SECONDS" -lt "$deadline" ]; do
    fqdn=$(ts_device_fqdn "$host" || true)
    if [ -n "$fqdn" ]; then
      log "node registered as ${fqdn}"
      printf '%s' "$fqdn"
      return 0
    fi
    sleep "$poll"
  done
  cat >&2 <<'MSG'

The server was created but never joined the tailnet, so there is no way in:
cloud-init probably failed before Tailscale came up.

  - read the cloud-init log over the out-of-band console:  ./console.sh
  - or discard it and try again:                           ./destroy.sh && ./deploy.sh

MSG
  die "$EXIT_NO_NODE" "node '${host}' did not register within ${budget}s"
}

# wait_for_funnel <fqdn> <budget-seconds> <poll-seconds>
# Returns EXIT_NO_FUNNEL rather than dying, so the caller can still report the
# boot phases — which is the whole point of an exit 5.
wait_for_funnel() {
  local fqdn=$1 budget=$2 poll=$3 deadline code=
  deadline=$((SECONDS + budget))
  log "waiting up to ${budget}s for https://${fqdn}/ to serve 200"
  while [ "$SECONDS" -lt "$deadline" ]; do
    code=$(http_status "$fqdn")
    if [ "$code" = "200" ]; then
      log "public URL is live (HTTP 200)"
      return 0
    fi
    sleep "$poll"
  done
  warn "https://${fqdn}/ last returned HTTP ${code}"
  warn "Funnel did not serve 200 within ${budget}s"
  return "$EXIT_NO_FUNNEL"
}

# Reads the phase markers off the node and prints them. The node stays reachable
# over Tailscale SSH even when Ghost or Funnel failed, which is the whole point
# of bringing Tailscale up first (ADR-002). Takes the FQDN so it works without
# MagicDNS search domains configured locally.
report_boot_phase() {
  local status
  status=$(read_boot_status "$1" || true)
  if [ -z "$status" ]; then
    warn "could not read /var/log/ghost-deploy/status over Tailscale SSH at ${1}"
    warn "your own machine must be in the tailnet, and the policy ssh rule must cover it"
    return 0
  fi
  printf '\n--- boot phases on %s ---\n%s\n\n' "$1" "$status" >&2
}
