# shellcheck shell=bash
# Tailscale API v2 client. Requires common.sh to be sourced first.

TS_API=https://api.tailscale.com/api/v2

# ts_api <method> <path> [json body]
#
# The token is fed through a curl config file on stdin rather than argv, so it
# does not appear in `ps` output.
#
# Accept: application/json matters — the policy-file endpoint otherwise returns
# HuJSON (with comments), which jq cannot parse.
#
# Timeouts are mandatory: these calls sit inside polling loops that advertise a
# deadline, and a stalled connection would hang a deploy with a billable server
# running.
ts_api() {
  local method=$1 path=$2 body=${3:-}
  if [ -n "$body" ]; then
    printf 'user = "%s:"\n' "$TS_API_KEY" | curl --config - \
      -fsS -X "$method" "${TS_API}${path}" \
      --connect-timeout 10 --max-time 20 \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json' \
      -d "$body"
  else
    printf 'user = "%s:"\n' "$TS_API_KEY" | curl --config - \
      -fsS -X "$method" "${TS_API}${path}" \
      --connect-timeout 10 --max-time 20 \
      -H 'Accept: application/json'
  fi
}

# Mints a single-use, pre-approved key tagged for this server.
#
# Deliberately NOT ephemeral: an ephemeral node is deregistered shortly after it
# disconnects, so a network blip or a tailscaled restart would drop a server that
# is meant to stay up — and on rejoin MagicDNS would hand it a different name
# (ghost-1), silently breaking the Funnel URL that Ghost was configured with.
# destroy.sh removes the device record explicitly instead.
ts_mint_authkey() {
  local body key
  body=$(printf '{"keyType":"auth","description":"ghost one-click deploy","capabilities":{"devices":{"create":{"reusable":false,"ephemeral":false,"preauthorized":true,"tags":["%s"]}}},"expirySeconds":3600}' "$TS_TAG")
  # `|| true` keeps a failed API call from aborting under `set -e`/`pipefail`, so
  # the explicit message below is what the operator sees. A missing tagOwners
  # entry returns HTTP 400 and lands here.
  key=$(ts_api POST "/tailnet/${TS_TAILNET}/keys" "$body" | jq -r '.key // empty') || true
  [ -n "$key" ] || die "$EXIT_PREREQ" \
    "Could not mint a Tailscale auth key. Check TS_API_KEY, and that ${TS_TAG} is listed under tagOwners in your policy file."
  printf '%s' "$key"
}

# Counts tailnet devices with the given hostname.
ts_device_count() {
  ts_api GET "/tailnet/${TS_TAILNET}/devices" |
    jq -r --arg h "$1" '[.devices[]? | select(.hostname == $h)] | length'
}

# Prints the MagicDNS name of the device with the given hostname.
# Read rather than constructed: this is the authoritative Funnel FQDN.
#
# Refuses to guess when several devices share the hostname. MagicDNS would have
# named the newest one ghost-1, so picking the first match would make the script
# report and probe a different machine than the one it just created.
ts_device_fqdn() {
  local matches
  matches=$(ts_api GET "/tailnet/${TS_TAILNET}/devices" |
    jq -r --arg h "$1" '.devices[]? | select(.hostname == $h) | .name' | sed 's/\.$//')
  case $(printf '%s' "$matches" | grep -c . || true) in
    0) return 0 ;;
    1) printf '%s' "$matches" ;;
    *) die "$EXIT_PREREQ" "more than one tailnet device is named '${1}': $(printf '%s' "$matches" | tr '\n' ' ')- remove the stale one at https://console.tailscale.com/admin/machines" ;;
  esac
}

ts_delete_device_by_hostname() {
  local id
  id=$(ts_api GET "/tailnet/${TS_TAILNET}/devices" |
    jq -r --arg h "$1" '.devices[]? | select(.hostname == $h) | .nodeId' | head -n 1) || true
  if [ -n "$id" ]; then
    ts_api DELETE "/device/${id}" >/dev/null
    log "removed tailnet device ${1} (${id})"
  else
    log "no tailnet device named ${1}; nothing to remove"
  fi
}
