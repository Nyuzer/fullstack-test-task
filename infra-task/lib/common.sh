# shellcheck shell=bash
# Shared helpers. Source this before any other lib; it sets strict mode.

set -euo pipefail

EXIT_USAGE=2        # missing local tool, missing configuration, bad argument
EXIT_PREREQ=3       # credential or tailnet prerequisite unmet
EXIT_NO_NODE=4      # server created but never registered in the tailnet
EXIT_NO_FUNNEL=5    # node registered but the public URL never served 200

log()  { printf '[ghost-deploy] %s\n' "$*" >&2; }
warn() { printf '[ghost-deploy] WARNING: %s\n' "$*" >&2; }

# die <exit-code> <message...>
die() {
  local code=$1
  shift
  printf '[ghost-deploy] ERROR: %s\n' "$*" >&2
  exit "$code"
}

# require_cmd <command> <install hint>
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$EXIT_USAGE" "'$1' is not installed. $2"
}

require_env() {
  [ -n "${!1:-}" ] || die "$EXIT_USAGE" "$1 is not set. Add it to infra-task/.env (see .env.example)."
}

# Loads .env, then fills in defaults for anything the user left out.
load_env() {
  [ -f "$1" ] || die "$EXIT_USAGE" "$1 not found. Run: cp .env.example .env  and fill it in."
  set -a
  # shellcheck disable=SC1090
  . "$1"
  set +a

  : "${GHOST_HOSTNAME:=ghost}"
  : "${SERVER_TYPE:=cx22}"
  : "${SERVER_IMAGE:=ubuntu-24.04}"
  : "${SERVER_LOCATION:=nbg1}"
  : "${TS_TAG:=tag:ghost}"
  : "${TS_TAILNET:=-}"
  : "${FIREWALL_NAME:=${GHOST_HOSTNAME}-deny-inbound}"
}
