# shellcheck shell=bash
# Tailscale API v2 client. Requires common.sh to be sourced first.

TS_API=https://api.tailscale.com/api/v2

# ts_api <method> <path> [json body]
# Accept: application/json matters — the policy-file endpoint otherwise returns
# HuJSON (with comments), which jq cannot parse.
ts_api() {
  local method=$1 path=$2 body=${3:-}
  if [ -n "$body" ]; then
    curl -fsS -X "$method" "${TS_API}${path}" \
      -u "${TS_API_KEY}:" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json' \
      -d "$body"
  else
    curl -fsS -X "$method" "${TS_API}${path}" \
      -u "${TS_API_KEY}:" \
      -H 'Accept: application/json'
  fi
}

# Mints a single-use, ephemeral, pre-approved key tagged for this server.
# Ephemeral: the node removes itself from the tailnet when it goes away.
# Pre-approved: cloud-init does not stall waiting for manual device approval.
ts_mint_authkey() {
  local body key
  body=$(printf '{"keyType":"auth","description":"ghost one-click deploy","capabilities":{"devices":{"create":{"reusable":false,"ephemeral":true,"preauthorized":true,"tags":["%s"]}}},"expirySeconds":3600}' "$TS_TAG")
  key=$(ts_api POST "/tailnet/${TS_TAILNET}/keys" "$body" | jq -r '.key // empty')
  [ -n "$key" ] || die "$EXIT_PREREQ" \
    "Could not mint a Tailscale auth key. Check TS_API_KEY, and that ${TS_TAG} is listed under tagOwners in your policy file."
  printf '%s' "$key"
}

# Prints the MagicDNS name of the device with the given hostname, or nothing.
# Read rather than constructed: this is the authoritative Funnel FQDN.
ts_device_fqdn() {
  ts_api GET "/tailnet/${TS_TAILNET}/devices" |
    jq -r --arg h "$1" '.devices[]? | select(.hostname == $h) | .name' |
    sed 's/\.$//' |
    head -n 1
}

ts_delete_device_by_hostname() {
  local id
  id=$(ts_api GET "/tailnet/${TS_TAILNET}/devices" |
    jq -r --arg h "$1" '.devices[]? | select(.hostname == $h) | .nodeId' | head -n 1)
  if [ -n "$id" ]; then
    ts_api DELETE "/device/${id}" >/dev/null
    log "removed tailnet device ${1} (${id})"
  else
    log "no tailnet device named ${1}; nothing to remove"
  fi
}
