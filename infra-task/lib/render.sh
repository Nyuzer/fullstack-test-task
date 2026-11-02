# shellcheck shell=bash
# Renders the cloud-init template. Requires common.sh to be sourced first.
#
# No break-glass password is generated or baked in. Hetzner serves user-data to
# anything in the instance network namespace, including the Ghost container, so
# a long-lived root password there would be a container-escape-to-root path.
# `./console.sh` uses `hcloud server reset-password` on demand instead.

# render_cloud_init <template> <output>
# The output holds the single-use auth key, so it is written with mode 600 and
# lives under infra-task/.run/ (gitignored).
render_cloud_init() {
  local tmpl=$1 out=$2
  [ -f "$tmpl" ] || die "$EXIT_USAGE" "cloud-init template not found: $tmpl"

  # chmod explicitly rather than relying on umask: msys ignores umask on NTFS.
  : > "$out"
  chmod 600 "$out"
  sed -e "s|__TS_AUTHKEY__|${TS_AUTHKEY}|g" \
      -e "s|__GHOST_HOSTNAME__|${GHOST_HOSTNAME}|g" \
      -e "s|__TS_TAG__|${TS_TAG}|g" \
      "$tmpl" > "$out"

  if grep -q '__[A-Z_]*__' "$out"; then
    die "$EXIT_USAGE" "cloud-init still contains unsubstituted placeholders: $(grep -o '__[A-Z_]*__' "$out" | sort -u | tr '\n' ' ')"
  fi
}
