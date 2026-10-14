# 85-update.sh [L1b]: the installer's own `update` subcommand (the curl form:
# curl ... | bash -s -- update [--check]).
#
# A single implementation serves both forms. The launcher (payload file `launcher`)
# holds the update code: fetch rules, form check, preview, confirmation, sha256
# re-check. This installer carries the launcher, its facts file and the reader it
# needs inside its own embedded payload, writes them to a mode 700 temporary
# folder and runs them with `update`. Nothing is fetched here, and no fetched byte
# runs before the user's yes. Both forms therefore reach the same preview.

update_via_launcher() { # $@ = arguments for `conductor update`
  local tmp rc
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/conductor-update-run.XXXXXX")" || { err "could not make a temporary folder"; return 1; }
  chmod 700 "$tmp" || { rm -rf "$tmp"; err "could not protect the temporary folder"; return 1; }
  if ! mkdir -p "$tmp/conductor/bin" "$tmp/conductor/lib" \
    || ! payload_emit launcher > "$tmp/conductor/bin/conductor" \
    || ! payload_emit facts > "$tmp/conductor/lib/facts.json" \
    || ! payload_emit doctor > "$tmp/conductor/lib/doctor.py" \
    || ! chmod 755 "$tmp/conductor/bin/conductor"; then
    rm -rf "$tmp"
    err "could not prepare the update"
    return 1
  fi
  CLAUDE_DIR="$CLAUDE_DIR" CODEX_DIR="$CODEX_DIR" AGENTS_SKILLS_DIR="$AGENTS_SKILLS_DIR" \
    /bin/bash "$tmp/conductor/bin/conductor" update "$@" < /dev/null
  rc=$?
  rm -rf "$tmp"
  return "$rc"
}

do_update() {
  update_via_launcher
}

do_update_check() {
  update_via_launcher --check
}
