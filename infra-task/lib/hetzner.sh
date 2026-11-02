# shellcheck shell=bash
# hcloud CLI wrappers. Requires common.sh to be sourced first.
# HCLOUD_TOKEN is read from the environment by the CLI itself.

hz_firewall_exists() { hcloud firewall describe "$1" >/dev/null 2>&1; }

# Created with no rules at all. A Hetzner firewall with no inbound rules drops
# all inbound traffic, while outbound stays unrestricted — which is all
# Tailscale needs. There is deliberately no port 22 rule anywhere in this file.
hz_firewall_create() {
  hcloud firewall create --name "$1" >/dev/null
  log "created firewall '$1' with no inbound rules (all inbound traffic dropped)"
}

hz_firewall_ensure() {
  if hz_firewall_exists "$1"; then
    log "firewall '$1' already exists"
  else
    hz_firewall_create "$1"
  fi
}

hz_firewall_delete() {
  if hz_firewall_exists "$1"; then
    hcloud firewall delete "$1" >/dev/null
    log "deleted firewall '$1'"
  else
    log "no firewall named '$1'; nothing to delete"
  fi
}

hz_server_exists() { hcloud server describe "$1" >/dev/null 2>&1; }

# Passing --firewall to `server create` attaches it before first boot, closing
# the window where port 22 would otherwise be reachable. Attaching afterwards
# with `firewall apply-to-resource` gives no such guarantee.
# No --ssh-key is injected: there is no public SSH path by design.
hz_server_create() {
  local name=$1 type=$2 image=$3 location=$4 firewall=$5 userdata=$6
  hcloud server create \
    --name "$name" \
    --type "$type" \
    --image "$image" \
    --location "$location" \
    --firewall "$firewall" \
    --user-data-from-file "$userdata" >/dev/null
  log "created server '$name' ($type, $image, $location)"
}

hz_server_delete() {
  if hz_server_exists "$1"; then
    hcloud server delete "$1" >/dev/null
    log "deleted server '$1'"
  else
    log "no server named '$1'; nothing to delete"
  fi
}

hz_server_id() { hcloud server describe "$1" -o 'format={{.ID}}'; }
hz_server_ip() { hcloud server ip "$1"; }
