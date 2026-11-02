# shellcheck shell=bash
# Verify-and-instruct preflight. Every check either passes or prints the exact
# remediation and exits, before any billable resource is created.
# Requires common.sh and tailscale.sh to be sourced first.
#
# This file never writes the tailnet policy. That file governs every device in
# the tailnet, so changing it is the operator's decision (see ADR-003).

ACL_URL=https://console.tailscale.com/admin/acls
DNS_URL=https://console.tailscale.com/admin/dns

# --- pure policy predicates (return 0/1, print nothing) ---

policy_has_tag_owner() {
  printf '%s' "$1" | jq -e --arg t "$TS_TAG" '(.tagOwners // {}) | has($t)' >/dev/null 2>&1
}

policy_has_funnel_attr() {
  printf '%s' "$1" | jq -e --arg t "$TS_TAG" '
    [.nodeAttrs[]?
      | select((.target // []) | index($t))
      | select((.attr // []) | index("funnel"))
    ] | length > 0' >/dev/null 2>&1
}

policy_has_ssh_rule() {
  printf '%s' "$1" | jq -e --arg t "$TS_TAG" '
    [.ssh[]?
      | select(.action == "accept")
      | select((.dst // []) | index($t))
      | select((.users // []) | index("root"))
    ] | length > 0' >/dev/null 2>&1
}

# --- checks (print remediation and exit on failure) ---

check_local_tools() {
  require_cmd curl   "Install it from https://curl.se/ or via your package manager."
  require_cmd jq     "Install it with: winget install --id jqlang.jq -e"
  require_cmd ssh    "Install OpenSSH (ships with Git for Windows)."
  require_cmd hcloud "Install it from https://github.com/hetznercloud/cli/releases"
}

check_config() {
  require_env HCLOUD_TOKEN
  require_env TS_API_KEY
}

check_hcloud_token() {
  hcloud server list -o noheader >/dev/null 2>&1 ||
    die "$EXIT_PREREQ" "HCLOUD_TOKEN was rejected. Generate a Read & Write token at https://console.hetzner.com -> project -> Security -> API Tokens"
}

check_magicdns() {
  local enabled
  enabled=$(ts_api GET "/tailnet/${TS_TAILNET}/dns/preferences" | jq -r '.magicDNS // false') ||
    die "$EXIT_PREREQ" "TS_API_KEY was rejected by the Tailscale API. Check the token at https://console.tailscale.com/admin/settings/keys"
  [ "$enabled" = "true" ] ||
    die "$EXIT_PREREQ" "MagicDNS is disabled for this tailnet and Funnel requires it. Enable it at ${DNS_URL}"
}

check_tailnet_policy() {
  local policy
  policy=$(ts_api GET "/tailnet/${TS_TAILNET}/acl") ||
    die "$EXIT_PREREQ" "Could not read the tailnet policy file. TS_API_KEY needs policy-file read access."

  if ! policy_has_tag_owner "$policy"; then
    printf '\n%s is not declared in tagOwners, so no device can claim it.\n' "$TS_TAG" >&2
    printf 'Add this at %s\n\n' "$ACL_URL" >&2
    printf '  "tagOwners": {\n    "%s": ["autogroup:admin"],\n  },\n\n' "$TS_TAG" >&2
    die "$EXIT_PREREQ" "tailnet policy is missing a tagOwners entry for ${TS_TAG}"
  fi

  if ! policy_has_funnel_attr "$policy"; then
    printf '\n%s is not granted the "funnel" node attribute, so the server cannot\n' "$TS_TAG" >&2
    printf 'publish itself. Note that autogroup:member does NOT cover tagged devices,\n' >&2
    printf 'so the default Funnel entry is not enough.\n' >&2
    printf 'Add this at %s\n\n' "$ACL_URL" >&2
    printf '  "nodeAttrs": [\n    {"target": ["%s"], "attr": ["funnel"]},\n  ],\n\n' "$TS_TAG" >&2
    die "$EXIT_PREREQ" "tailnet policy is missing a funnel nodeAttrs entry for ${TS_TAG}"
  fi

  if ! policy_has_ssh_rule "$policy"; then
    printf '\nNo Tailscale SSH rule grants root on %s, so you could not administer\n' "$TS_TAG" >&2
    printf 'or debug the server after it boots.\n' >&2
    printf 'Add this at %s\n\n' "$ACL_URL" >&2
    printf '  "ssh": [\n    {"action": "accept", "src": ["autogroup:member"], "dst": ["%s"], "users": ["root"]},\n  ],\n\n' "$TS_TAG" >&2
    die "$EXIT_PREREQ" "tailnet policy is missing an ssh rule for ${TS_TAG}"
  fi

  log "tailnet prerequisites OK (tagOwners, funnel attr, ssh rule)"
}

# HTTPS certificate status is not exposed by the Tailscale API, so this is a
# logged reminder rather than a gate. A missing certificate surfaces as a failed
# "funnel" phase, which the post-deploy report reads off the node.
warn_https_certs_unverifiable() {
  log "note: Funnel also needs HTTPS certificates enabled (${DNS_URL}); this cannot be verified via the API"
}

run_preflight() {
  check_local_tools
  check_config
  check_hcloud_token
  check_magicdns
  check_tailnet_policy
  warn_https_certs_unverifiable
}
