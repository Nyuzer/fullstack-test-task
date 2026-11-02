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

# "*" is a valid wildcard in target/dst/users and must count as a match, or a
# correct policy gets rejected with a confusing instruction to add what it has.
policy_has_funnel_attr() {
  printf '%s' "$1" | jq -e --arg t "$TS_TAG" '
    [.nodeAttrs[]?
      | select(((.target // []) | index($t)) or ((.target // []) | index("*")))
      | select((.attr // []) | index("funnel"))
    ] | length > 0' >/dev/null 2>&1
}

# Also checks src: a rule granting root on the tag to some unrelated source
# (say tag:ci) satisfies the letter of the check while granting the operator
# nothing, which would pass preflight and then fail at the exit-5 diagnostic.
policy_has_ssh_rule() {
  printf '%s' "$1" | jq -e --arg t "$TS_TAG" '
    [.ssh[]?
      | select(.action == "accept")
      | select(((.dst // []) | index($t)) or ((.dst // []) | index("*")))
      | select(((.users // []) | index("root")) or ((.users // []) | index("*")))
      | select((.src // []) | any(. == "*" or . == "autogroup:member" or . == "autogroup:admin"))
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

# Server types and locations change over time — cx22 was valid once and is not
# any more — and `hcloud server create` reports a bare "Server Type not found"
# with exit 1, after the firewall has already been created. Validate here, where
# failing is free, and list the real options.
check_server_type() {
  local locs

  hcloud location describe "$SERVER_LOCATION" >/dev/null 2>&1 || {
    warn "available locations: $(hcloud location list -o noheader -o columns=name | tr '\n' ' ')"
    die "$EXIT_PREREQ" "SERVER_LOCATION '${SERVER_LOCATION}' does not exist"
  }

  if ! hcloud server-type describe "$SERVER_TYPE" >/dev/null 2>&1; then
    printf '\nSERVER_TYPE "%s" does not exist. Shared x86 types offered in %s:\n\n' \
      "$SERVER_TYPE" "$SERVER_LOCATION" >&2
    # .locations is availability; .prices lists everywhere a type is merely
    # priced, which is not the same question.
    hcloud server-type list -o json |
      jq -r --arg loc "$SERVER_LOCATION" '
        .[] | select(.architecture == "x86" and .cpu_type == "shared")
            | select(.deprecated != true)
            | select([.locations[]?.name] | index($loc))
            | "  \(.name)  \(.cores) cores  \(.memory) GB RAM"' >&2
    printf '\nSet SERVER_TYPE in infra-task/.env to one of these.\n\n' >&2
    die "$EXIT_PREREQ" "SERVER_TYPE '${SERVER_TYPE}' not found"
  fi

  locs=$(hcloud server-type list -o json |
    jq -r --arg t "$SERVER_TYPE" '.[] | select(.name == $t) | .locations[]?.name')
  printf '%s\n' "$locs" | grep -qx "$SERVER_LOCATION" ||
    die "$EXIT_PREREQ" "SERVER_TYPE '${SERVER_TYPE}' is not offered in '${SERVER_LOCATION}'; it is available in: $(printf '%s' "$locs" | tr '\n' ' ')"

  log "server type ${SERVER_TYPE} is available in ${SERVER_LOCATION}"
}

# Both namespaces must be free before anything is created. A leftover tailnet
# device named ${GHOST_HOSTNAME} is the dangerous one: MagicDNS would name the
# new node ghost-1, while the deploy script would resolve and probe the old
# ghost — reporting a URL that is not the server it just built.
check_hostname_free() {
  hz_server_exists "$GHOST_HOSTNAME" &&
    die "$EXIT_PREREQ" "a Hetzner server named '${GHOST_HOSTNAME}' already exists. Run ./destroy.sh first, or set GHOST_HOSTNAME to something else."

  local count
  count=$(ts_device_count "$GHOST_HOSTNAME")
  [ "$count" = "0" ] ||
    die "$EXIT_PREREQ" "${count} tailnet device(s) are already named '${GHOST_HOSTNAME}'. Remove them at https://console.tailscale.com/admin/machines (or run ./destroy.sh), or set GHOST_HOSTNAME to something else."
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
  check_server_type
  check_hostname_free
  warn_https_certs_unverifiable
  log "note: administering the server needs your own machine in the tailnet; the public blog does not"
}
