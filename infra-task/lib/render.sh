# shellcheck shell=bash
# Renders the cloud-init template. Requires common.sh to be sourced first.

# Hex only, so the value can never collide with sed's delimiter or with YAML
# quoting when it is substituted into the template.
generate_root_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

# render_cloud_init <template> <output>
# The output holds the auth key and the break-glass password, so it is written
# with mode 600 and lives under infra-task/.run/ (gitignored).
render_cloud_init() {
  local tmpl=$1 out=$2
  [ -f "$tmpl" ] || die "$EXIT_USAGE" "cloud-init template not found: $tmpl"

  # chmod explicitly rather than relying on umask: msys ignores umask on NTFS,
  # and the file holds the auth key and the break-glass password.
  : > "$out"
  chmod 600 "$out"
  sed -e "s|__ROOT_PASSWORD__|${ROOT_PASSWORD}|g" \
      -e "s|__TS_AUTHKEY__|${TS_AUTHKEY}|g" \
      -e "s|__GHOST_HOSTNAME__|${GHOST_HOSTNAME}|g" \
      -e "s|__TS_TAG__|${TS_TAG}|g" \
      "$tmpl" > "$out"

  if grep -q '__[A-Z_]*__' "$out"; then
    die "$EXIT_USAGE" "cloud-init still contains unsubstituted placeholders: $(grep -o '__[A-Z_]*__' "$out" | sort -u | tr '\n' ' ')"
  fi
}
