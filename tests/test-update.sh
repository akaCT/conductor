#!/bin/bash
# tests/test-update.sh: conductor update and the installer's update subcommand.
# Criteria REQ-UPD-002.1 to .12, REQ-UI-001.2, .3 and .6 for the update text.
#
# A fixture update host (tests/fixtures/update/server.py) listens on 127.0.0.1. The suite
# starts it itself (the only background process), waits for its port file with a bounded
# poll and stops it in the exit trap. The fixture installers written here are small files
# that carry the same data blocks as a built installer and record how they were run.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/tests/lib/assert.sh"
. "$REPO/tests/lib/sandbox.sh"
sandbox_new
SRV_PIDS=""
cleanup() {
  { for p in $SRV_PIDS; do kill "$p"; done; for p in $SRV_PIDS; do wait "$p"; done; } 2> /dev/null
  sandbox_cleanup
}
trap cleanup EXIT
sandbox_guard
. "$REPO/tests/fixtures/doctor/lib.sh"
UFX="$REPO/tests/fixtures/update"
WWW="$SBX/www"
UTMP="$SBX/utmp"
MARKER="$SBX/marker.txt"
CONST_URL="https://raw.githubusercontent.com/akaCT/conductor/main/install.sh"
mkdir -p "$WWW" "$UTMP"
export FIXTURE_MARKER="$MARKER"

start_server() { # NAME [server arguments]: sets nothing; the port is in $SBX/NAME.port
  local name="$1" i=0
  shift
  "$SBX_PY" -B "$UFX/server.py" --root "$WWW" --log "$SBX/$name.log" --port-file "$SBX/$name.port" "$@" > /dev/null 2>&1 &
  SRV_PIDS="$SRV_PIDS $!"
  while [ ! -s "$SBX/$name.port" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if [ ! -s "$SBX/$name.port" ]; then echo "the fixture server $name did not start" >&2; exit 98; fi
}

sha_of() { (sha256sum "$1" 2> /dev/null || shasum -a 256 "$1") | awk '{print $1}'; }
sha_of_text() { printf '%s\n' "$1" | (sha256sum 2> /dev/null || shasum -a 256) | awk '{print $1}'; }
flat() { printf '%s' "$1" | tr '\n' ' ' | tr -s ' '; }
json_get() { "$SBX_PY" -B -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }

# make_installer FILE VERSION [VARIANT]: a fixture installer with the data blocks of a built
# one. VARIANT: good (default), html, nomarkers, nomain, twoversions, binary, empty.
make_installer() {
  local f="$1" v="$2" variant="${3:-good}" bsha csha sha1
  bsha="$(sha_of_text "NEW BUILDER $v")"
  csha="$(sha_of "$CLAUDE_DIR/agents/critic.md" 2> /dev/null || echo 0)"
  sha1="$(sha_of_text "x $v")"
  case "$variant" in
    html) printf '<html><body>Not Found %s</body></html>\n' "$v" > "$f"; return ;;
    empty) : > "$f"; return ;;
  esac
  {
    printf '#!/usr/bin/env bash\n# Fixture installer, not a Conductor release.\n'
    printf 'CONDUCTOR_VERSION="%s"\n' "$v"
    [ "$variant" = twoversions ] && printf 'CONDUCTOR_VERSION="%s"\n' "$v"
    [ "$variant" = binary ] && printf 'binary \000 data\n'
    if [ "$variant" != nomarkers ]; then
      printf '#@@FILES-BEGIN\n'
      printf '#@@FILE|agent_builder|claude|agents/builder.md|agent|core|-|-|-|%s\n' "$bsha"
      printf '#@@FILE|agent_scout|claude|agents/scout.md|agent|core|-|-|-|%s\n' "$sha1"
      printf '#@@FILE|agent_critic|claude|agents/critic.md|agent|core|-|-|-|%s\n' "$csha"
      printf '#@@FILE|runbook_new|claude|conductor/runbooks/new-runbook.md|replace|core|-|-|-|%s\n' "$sha1"
      printf '#@@FILE|defaults|claude|conductor/defaults.md|create-only|core|-|-|-|%s\n' "$sha1"
      printf '#@@FILE|hook_usage_split|claude|conductor/hooks/usage-split-check.py|replace|hook_usage_split|-|-|-|%s\n' "$sha1"
      printf '#@@FILE|doctrine|claude|CLAUDE.md|doctrine-block|core|-|-|-|%s\n' "$sha1"
      printf '#@@FILES-END\n'
      printf '#@@CHANGELOG-BEGIN\n'
      printf '#@@| ## %s (2026-11-01)\n#@@|\n' "$v"
      printf '#@@| Upgrade notes: nothing to do by hand.\n'
      printf '#@@| - Added the optional usage-split hook.\n'
      printf '#@@| - Control characters: \033[31mred\033[0m bell\007 c1\xc2\x9b end.\n'
      printf '#@@|\n#@@| ## 0.4.1 (2026-10-20)\n#@@|\n#@@| - Fixed a small thing.\n#@@|\n'
      printf '#@@| ## 0.4.0 (2026-10-12)\n#@@|\n#@@| - ALREADY-INSTALLED-ENTRY.\n#@@|\n'
      printf '#@@| ## 0.3.0 (2026-07-04)\n#@@|\n#@@| - OLD-ENTRY.\n'
      printf '#@@CHANGELOG-END\n'
    fi
    cat << 'EOS'
main() {
  if [ -n "${FIXTURE_MARKER:-}" ]; then
    {
      printf 'ran\n'
      printf 'sha256=%s\n' "$( (sha256sum "$0" 2> /dev/null || shasum -a 256 "$0") | awk '{print $1}')"
      printf 'env_sha=%s\n' "${CONDUCTOR_INSTALLER_SHA256:-}"
      printf 'components=%s\n' "${CONDUCTOR_COMPONENTS:-}"
      printf 'yes=%s\n' "${CONDUCTOR_YES:-}"
      printf 'args=%s\n' "$*"
      printf 'stdin_tty=%s\n' "$([ -t 0 ] && echo yes || echo no)"
    } > "$FIXTURE_MARKER"
  fi
  m="${CLAUDE_DIR:-$HOME/.claude}/conductor/.install-manifest"
  if [ -f "$m" ]; then
    sed "s/\"version\": \"[0-9.]*\"/\"version\": \"$CONDUCTOR_VERSION\"/" "$m" > "$m.new" && cat "$m.new" > "$m" && rm -f "$m.new"
  fi
}
EOS
    if [ "$variant" = nomain ]; then printf 'echo done\n'; else printf 'main "$@"\n'; fi
  } > "$f"
}

# fresh_update_env: an installed 0.4.0 with 2 files the user changed and a defaults file
fresh_update_env() {
  fresh_roots 2.1.296
  fx_claude_install
  printf 'my defaults\n' > "$CLAUDE_DIR/conductor/defaults.md"
  printf 'my edit\n' >> "$CLAUDE_DIR/agents/scout.md"
  printf 'my edit\n' >> "$CLAUDE_DIR/agents/architect.md"
  rm -rf "$UTMP"
  mkdir -p "$UTMP"
  rm -f "$MARKER" "$SBX/plain.log" "$SBX/tls.log"
  export TMPDIR="$UTMP"
  export CONDUCTOR_TEST_UPDATE_URL="http://127.0.0.1:$PLAIN_PORT/install.sh"
  make_installer "$WWW/install.sh" 0.5.0
}

run_update() { # ARGS: no terminal
  OUT="$(/bin/bash "$CLAUDE_DIR/conductor/bin/conductor" update "$@" 2>&1 < /dev/null)"
  RC=$?
}

run_update_pty() { # ANSWER ARGS
  local ans="$1"
  shift
  OUT="$(PTY_INPUT="$ans" sandbox_pty /bin/bash "$CLAUDE_DIR/conductor/bin/conductor" update "$@")"
  RC=$?
}

request_count() { # LOGFILE: number of requests the fixture host saw
  if [ -f "$1" ]; then grep -c '^GET ' "$1" || true; else echo 0; fi
}

leftover_tmp() { ls "$UTMP" 2> /dev/null | grep -c 'conductor-update' || true; }

start_server plain
PLAIN_PORT="$(cat "$SBX/plain.port")"

# ---------------------------------------------------------------------------------
t_begin "REQ-UPD-002.1 an older install, a newer installer served locally, a yes: the preview lists both versions, files to replace and keep, the upgrade applies, the manifest shows the new version"
fresh_update_env
run_update_pty $'y\n'
assert_eq 0 "$RC" "exit status"
assert_contains "$OUT" "Update preview"
assert_contains "$OUT" "  Installed version: 0.4.0"
assert_contains "$OUT" "  Available version: 0.5.0"
assert_contains "$OUT" "Files to replace (2)"
assert_contains "$OUT" "  agents/builder.md"
assert_contains "$OUT" "  CLAUDE.md (the Conductor block only)"
assert_contains "$OUT" "Files to keep (3)"
assert_contains "$OUT" "  agents/scout.md (you changed it)"
assert_contains "$OUT" "  conductor/defaults.md (yours to edit; never overwritten)"
assert_contains "$OUT" "  agents/architect.md (no longer shipped, but you changed it)"
assert_contains "$OUT" "Files to add (1)"
assert_contains "$OUT" "  conductor/runbooks/new-runbook.md"
assert_not_contains "$OUT" "  conductor/hooks/usage-split-check.py" "a hook the install does not hold is offered by name, not listed as a file to add"
assert_contains "$OUT" "Files to remove (no longer shipped) (1)"
assert_contains "$OUT" "  agents/judge.md"
assert_contains "$OUT" "Files already current: 1"
assert_contains "$OUT" "Update finished. Installed version: 0.5.0"
assert_eq 0.5.0 "$(json_get "$CLAUDE_DIR/conductor/.install-manifest" version)" "manifest version"
assert_file "$MARKER" "the installer ran after the yes"
t_end

t_begin "REQ-UPD-002.1 the changelog shows the entries between the 2 versions only"
fresh_update_env
run_update_pty $'n\n'
assert_contains "$OUT" "What changed (from the changelog inside the fetched file)"
assert_contains "$OUT" "## 0.5.0 (2026-11-01)"
assert_contains "$OUT" "Upgrade notes: nothing to do by hand."
assert_contains "$OUT" "## 0.4.1 (2026-10-20)"
assert_contains "$OUT" "Fixed a small thing."
assert_not_contains "$OUT" "ALREADY-INSTALLED-ENTRY"
assert_not_contains "$OUT" "OLD-ENTRY"
t_end

t_begin "REQ-UI-001.6 control characters in the fetched changelog are removed from what is shown"
fresh_update_env
run_update_pty $'n\n'
assert_contains "$OUT" "Control characters: [31mred[0m bell c1 end."
bad="$(printf '%s' "$OUT" | LC_ALL=C tr -d '\n\t\r' | LC_ALL=C grep -c "[$(printf '\001-\010\013\014\016-\037\177')]" || true)"
assert_eq 0 "$bad" "C0 control characters left in the output"
c1="$(printf '%s' "$OUT" | LC_ALL=C grep -c "$(printf '\xc2\x9b')" || true)"
assert_eq 0 "$c1" "C1 control characters left in the output"
t_end

t_begin "REQ-UPD-002.1 REQ-UI-001.3 REQ-UI-001.2 no update line is longer than 80 characters and there are no escape sequences once a terminal is the output"
fresh_update_env
run_update_pty $'n\n'
long="$(printf '%s\n' "$OUT" | sed -e "s#$SBX#{sbx}#g" | awk 'length($0) > 80 { print length($0) ": " $0 }')"
assert_eq "" "$long" "lines over 80 characters"
esc="$(printf '%s' "$OUT" | LC_ALL=C grep -c "$(printf '\033')" || true)"
# the only escape character in the output is the one the fixture changelog carried; it is removed
assert_eq 0 "$esc" "escape sequences"
run_update --check
esc="$(printf '%s' "$OUT" | LC_ALL=C grep -c "$(printf '\033')" || true)"
assert_eq 0 "$esc" "escape sequences, piped"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-UPD-002.2 the same version says up to date and changes nothing"
fresh_update_env
make_installer "$WWW/install.sh" 0.4.0
before="$(sandbox_tree_sum "$CLAUDE_DIR")"
run_update
assert_eq 0 "$RC" "exit status"
assert_contains "$OUT" "Conductor 0.4.0 is up to date."
assert_eq "$before" "$(sandbox_tree_sum "$CLAUDE_DIR")" "the config folder"
assert_no_file "$MARKER"
assert_eq 0 "$(leftover_tmp)" "temporary folders left behind"
t_end

t_begin "REQ-UPD-002.3 a lower version is refused and nothing changes"
fresh_update_env
make_installer "$WWW/install.sh" 0.3.5
before="$(sandbox_tree_sum "$CLAUDE_DIR")"
run_update
assert_eq 1 "$RC" "exit status"
assert_contains "$(flat "$OUT")" "Update refused: the fetched installer is version 0.3.5, older than the installed 0.4.0. Nothing was changed."
assert_eq "$before" "$(sandbox_tree_sum "$CLAUDE_DIR")" "the config folder"
assert_no_file "$MARKER"
t_end

t_begin "REQ-UPD-002.3 files that are not a Conductor installer are refused and nothing changes"
fresh_update_env
before="$(sandbox_tree_sum "$CLAUDE_DIR")"
for variant in html empty nomarkers nomain twoversions binary; do
  make_installer "$WWW/install.sh" 0.5.0 "$variant"
  run_update
  assert_eq 1 "$RC" "exit status for $variant"
  assert_contains "$(flat "$OUT")" "Update refused: the fetched file is not a Conductor installer" "refusal for $variant"
  assert_contains "$(flat "$OUT")" "Nothing was changed." "nothing changed for $variant"
done
assert_eq "$before" "$(sandbox_tree_sum "$CLAUDE_DIR")" "the config folder"
assert_no_file "$MARKER"
assert_eq 0 "$(leftover_tmp)" "temporary folders left behind"
make_installer "$WWW/install.sh" 0.5.0
export CONDUCTOR_TEST_UPDATE_URL="http://127.0.0.1:$PLAIN_PORT/missing"
run_update
assert_eq 1 "$RC" "a 404 is refused"
assert_contains "$(flat "$OUT")" "Update refused: the fetch failed"
export CONDUCTOR_TEST_UPDATE_URL="http://127.0.0.1:$PLAIN_PORT/big"
run_update
assert_eq 1 "$RC" "a file above the size cap is refused"
assert_contains "$(flat "$OUT")" "Update refused:"
assert_eq "$before" "$(sandbox_tree_sum "$CLAUDE_DIR")" "the config folder after the fetch failures"
assert_eq 0 "$(leftover_tmp)" "temporary folders left behind"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-UPD-002.4 update --check says whether a newer version exists and changes nothing"
fresh_update_env
before="$(sandbox_tree_sum "$CLAUDE_DIR")"
run_update --check
assert_eq 0 "$RC" "exit status"
assert_contains "$OUT" "A newer Conductor is available: 0.5.0 (installed: 0.4.0)."
assert_not_contains "$OUT" "Update preview"
make_installer "$WWW/install.sh" 0.4.0
run_update --check
assert_contains "$OUT" "Conductor 0.4.0 is up to date."
make_installer "$WWW/install.sh" 0.5.0
OUT="$(/bin/bash "$REPO/install.sh" update --check 2>&1 < /dev/null)"
assert_contains "$OUT" "A newer Conductor is available: 0.5.0 (installed: 0.4.0)." "the installer form"
assert_eq "$before" "$(sandbox_tree_sum "$CLAUDE_DIR")" "the config folder"
assert_no_file "$MARKER"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-UPD-002.5 the launcher and the curl form with bash -s -- update reach the same preview"
fresh_update_env
run_update_pty $'n\n'
a="$(printf '%s\n' "$OUT" | sed -n '/^Update preview/,/^Apply this update?/p' | sed '$d')"
OUT="$(PTY_INPUT=$'n\n' sandbox_pty /bin/bash -c 'cat "$1" | /bin/bash -s -- update' _ "$REPO/install.sh")"
b="$(printf '%s\n' "$OUT" | sed -n '/^Update preview/,/^Apply this update?/p' | sed '$d')"
if [ -z "$a" ]; then t_fail "the launcher form printed no preview"; fi
assert_eq "$a" "$b" "the 2 previews"
assert_contains "$OUT" "Nothing was changed."
assert_no_file "$MARKER"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-UPD-002.6 a new hook in the newer release is named in the preview and never enabled silently"
fresh_update_env
before_settings="$(sha_of "$CLAUDE_DIR/settings.json")"
run_update_pty $'y\n'
assert_eq 0 "$RC" "exit status"
assert_contains "$(flat "$OUT")" "New optional components in this release: hook_usage_split. The installer asks about each by name; the update turns none of them on."
assert_file "$MARKER"
assert_contains "$(cat "$MARKER")" "components=full,hook_pointer,hook_nudge" "only the recorded components ride along"
assert_not_contains "$(cat "$MARKER")" "hook_usage_split"
assert_contains "$(cat "$MARKER")" "yes=" "no yes is handed to the installer"
assert_not_contains "$(cat "$MARKER")" "yes=1"
assert_contains "$(cat "$MARKER")" "stdin_tty=no" "the installer cannot read an answer"
assert_eq "$before_settings" "$(sha_of "$CLAUDE_DIR/settings.json")" "settings.json"
t_end

t_begin "REQ-UPD-002.6 CONDUCTOR_YES=1 or no terminal is not a yes: nothing is applied"
fresh_update_env
before="$(sandbox_tree_sum "$CLAUDE_DIR")"
OUT="$(CONDUCTOR_YES=1 PTY_INPUT=$'y\n' sandbox_pty /bin/bash "$CLAUDE_DIR/conductor/bin/conductor" update)"
assert_contains "$OUT" "No terminal to ask on (or CONDUCTOR_YES is set): the answer is no."
assert_no_file "$MARKER"
run_update
assert_eq 0 "$RC" "exit status without a terminal"
assert_contains "$OUT" "No terminal to ask on"
assert_no_file "$MARKER"
OUT="$(sandbox_notty /bin/bash "$CLAUDE_DIR/conductor/bin/conductor" update < /dev/null 2>&1)"
assert_contains "$OUT" "Nothing was changed."
assert_no_file "$MARKER"
assert_eq "$before" "$(sandbox_tree_sum "$CLAUDE_DIR")" "the config folder"
t_end

t_begin "REQ-UPD-002.6 an answer of no or just Enter changes nothing"
fresh_update_env
before="$(sandbox_tree_sum "$CLAUDE_DIR")"
run_update_pty $'n\n'
assert_contains "$OUT" "Nothing was changed."
run_update_pty $'\n'
assert_contains "$OUT" "Nothing was changed."
assert_no_file "$MARKER"
assert_eq "$before" "$(sandbox_tree_sum "$CLAUDE_DIR")" "the config folder"
assert_eq 0 "$(leftover_tmp)" "temporary folders left behind"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-UPD-002.7 a plain GET: no query string, no identifier, no version in what the host logs"
fresh_update_env
: > "$SBX/plain.log"
run_update --check
assert_eq 1 "$(request_count "$SBX/plain.log")" "requests"
log="$(cat "$SBX/plain.log")"
assert_contains "$log" "GET /install.sh"
assert_not_contains "$(head -n 1 "$SBX/plain.log")" "?" "a query string"
names="$(grep -E '^[a-z-]+: ' "$SBX/plain.log" | sed 's/:.*//' | sort | tr '\n' ' ')"
assert_eq "accept host user-agent " "$names" "request header names"
for word in conductor Conductor 0.4.0 0.5.0 installed version; do
  case "$log" in *"$word"*) t_fail "the request log holds: $word" ;; esac
done
t_end

t_begin "REQ-UPD-002.7 a redirect to another host is refused with nothing changed"
fresh_update_env
export CONDUCTOR_TEST_UPDATE_URL="http://127.0.0.1:$PLAIN_PORT/redir-other"
before="$(sandbox_tree_sum "$CLAUDE_DIR")"
run_update_pty $'y\n'
assert_eq 1 "$RC" "exit status"
assert_contains "$(flat "$OUT")" "Update refused: the fetch was redirected to another host. Nothing was changed."
assert_no_file "$MARKER"
assert_eq "$before" "$(sandbox_tree_sum "$CLAUDE_DIR")" "the config folder"
export CONDUCTOR_TEST_UPDATE_URL="http://127.0.0.1:$PLAIN_PORT/redir-same"
run_update --check
assert_contains "$OUT" "A newer Conductor is available: 0.5.0" "a redirect inside the same host is followed"
t_end

t_begin "REQ-UPD-002.7 the test address is accepted only for http or https on 127.0.0.1 or localhost without credentials; otherwise the real constant is used"
fresh_update_env
cp "$UFX/fake-curl.sh" "$SBX/bin/curl"
export CURL_ARGV_LOG="$SBX/curl-argv.log"
for bad in "http://example.invalid/install.sh" "http://192.0.2.1/install.sh" "ftp://127.0.0.1/install.sh" \
  "http://user@127.0.0.1:$PLAIN_PORT/install.sh" "file:///etc/hostname" "https://raw.githubusercontent.com.evil.example/install.sh"; do
  rm -f "$CURL_ARGV_LOG"
  export CONDUCTOR_TEST_UPDATE_URL="$bad"
  run_update --check
  assert_eq 1 "$RC" "exit status for $bad"
  assert_eq "$CONST_URL" "$(tail -n 1 "$CURL_ARGV_LOG")" "the address fetched when the test address was $bad"
done
rm -f "$SBX/bin/curl"
unset CURL_ARGV_LOG
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-UPD-002.8 the preview removes an unmodified dropped file and keeps and names a modified one"
fresh_update_env
run_update_pty $'n\n'
assert_contains "$OUT" "Files to remove (no longer shipped) (1)"
assert_contains "$OUT" "  agents/judge.md"
assert_contains "$OUT" "  agents/architect.md (no longer shipped, but you changed it)"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-UPD-002.9 the preview shows the sha256 of the fetched file, and a no leaves no marker"
fresh_update_env
want="$(sha_of "$WWW/install.sh")"
run_update_pty $'n\n'
assert_contains "$OUT" "sha256 of the fetched file:"
assert_contains "$OUT" "    $want"
assert_no_file "$MARKER" "a no leaves no marker"
assert_eq 0 "$(leftover_tmp)" "temporary folders left behind"
t_end

t_begin "REQ-UPD-002.9 after a yes the bytes run have that sha256 and the manifest records it"
fresh_update_env
want="$(sha_of "$WWW/install.sh")"
run_update_pty $'y\n'
assert_eq 0 "$RC" "exit status"
assert_file "$MARKER"
assert_contains "$(cat "$MARKER")" "sha256=$want" "the bytes run"
assert_contains "$(cat "$MARKER")" "env_sha=$want" "the sha256 handed to the installer"
assert_eq "$want" "$(json_get "$CLAUDE_DIR/conductor/.install-manifest" installer_sha256)" "installer_sha256 in the manifest"
assert_eq 600 "$(file_mode_of "$CLAUDE_DIR/conductor/.install-manifest")" "manifest mode kept"
assert_eq 0 "$(leftover_tmp)" "temporary folders left behind"
t_end

t_begin "REQ-UPD-002.9 a file changed between the preview and the yes is refused and not run"
fresh_update_env
OUT="$("$SBX_PY" -B "$UFX/pty_tamper.py" "$UTMP" /bin/bash "$CLAUDE_DIR/conductor/bin/conductor" update)"
assert_contains "$OUT" "[tampered: yes]"
assert_contains "$(flat "$OUT")" "Update refused: the fetched file changed after the preview. Nothing was changed."
assert_no_file "$MARKER"
assert_eq 0.4.0 "$(json_get "$CLAUDE_DIR/conductor/.install-manifest" version)" "manifest version"
assert_eq 0 "$(leftover_tmp)" "temporary folders left behind"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-UPD-002.10 a manifest that names another host is refused: nothing fetched, nothing changed"
for src in "https://evil.example/akaCT/conductor/main/install.sh" "http://localhost:$PLAIN_PORT/install.sh" "http://127.0.0.1:$PLAIN_PORT/install.sh"; do
  fresh_update_env
  fx_manifest "$CLAUDE_DIR" "source_url=\"$src\""
  before="$(sandbox_tree_sum "$CLAUDE_DIR")"
  : > "$SBX/plain.log"
  run_update_pty $'y\n'
  assert_eq 1 "$RC" "exit status for $src"
  assert_contains "$(flat "$OUT")" "Update refused: the install record names a different host than this launcher uses. Nothing was changed."
  assert_eq 0 "$(request_count "$SBX/plain.log")" "requests for $src"
  assert_no_file "$MARKER"
  assert_eq "$before" "$(sandbox_tree_sum "$CLAUDE_DIR")" "the config folder for $src"
done
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-UPD-002.11 the fetch call starts with curl -q, sets https-only protocol and redirect rules and a timeout, has no -k, and writes a mode 600 file in a mode 700 folder"
fresh_update_env
unset CONDUCTOR_TEST_UPDATE_URL
cp "$UFX/fake-curl.sh" "$SBX/bin/curl"
export CURL_ARGV_LOG="$SBX/curl-argv.log"
run_update --check
assert_eq 1 "$RC" "exit status"
args="$(cat "$CURL_ARGV_LOG")"
assert_eq "-q" "$(head -n 1 "$CURL_ARGV_LOG")" "the first argument"
assert_eq "$CONST_URL" "$(tail -n 1 "$CURL_ARGV_LOG")" "the address"
flatargs="$(printf '%s' "$args" | tr '\n' ' ')"
assert_contains "$flatargs" "--proto =https "
assert_contains "$flatargs" "--proto-redir =https "
assert_contains "$flatargs" "--max-time 30 "
assert_contains "$flatargs" "--tlsv1.2 "
assert_contains "$flatargs" "--fail "
assert_not_contains "$flatargs" "-k "
assert_not_contains "$flatargs" "--insecure"
assert_contains "$(cat "$CURL_ARGV_LOG.modes")" "file_mode=600"
assert_contains "$(cat "$CURL_ARGV_LOG.modes")" "dir_mode=700"
assert_eq 0 "$(leftover_tmp)" "temporary folders left behind"
rm -f "$SBX/bin/curl"
unset CURL_ARGV_LOG
t_end

HAVE_TLS=0
if command -v openssl > /dev/null 2>&1; then
  cat > "$SBX/ossl.cnf" << 'CNF'
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=127.0.0.1
[v3]
subjectAltName=IP:127.0.0.1
basicConstraints=CA:TRUE
CNF
  if openssl req -x509 -newkey rsa:2048 -nodes -keyout "$SBX/key.pem" -out "$SBX/cert.pem" -days 2 -config "$SBX/ossl.cnf" > /dev/null 2>&1; then
    start_server tls --cert "$SBX/cert.pem" --key "$SBX/key.pem" --http-port-file "$SBX/plain.port"
    TLS_PORT="$(cat "$SBX/tls.port")"
    HAVE_TLS=1
  fi
fi

t_begin "REQ-UPD-002.11 a ~/.curlrc with insecure does not weaken the fetch: an untrusted certificate is refused"
if [ "$HAVE_TLS" = 1 ]; then
  fresh_update_env
  printf 'insecure\n' > "$HOME/.curlrc"
  # the harness works: plain curl in this HOME accepts the untrusted certificate
  curl -sS --max-time 5 "https://127.0.0.1:$TLS_PORT/install.sh" > /dev/null 2>&1
  assert_eq 0 "$?" "positive control: curl without -q honours ~/.curlrc"
  export CONDUCTOR_TEST_UPDATE_URL="https://127.0.0.1:$TLS_PORT/install.sh"
  before="$(sandbox_tree_sum "$CLAUDE_DIR")"
  run_update --check
  assert_eq 1 "$RC" "exit status"
  assert_contains "$(flat "$OUT")" "Update refused: the fetch failed (curl exit 60"
  assert_eq "$before" "$(sandbox_tree_sum "$CLAUDE_DIR")" "the config folder"
  assert_eq 0 "$(leftover_tmp)" "temporary folders left behind"
  rm -f "$HOME/.curlrc"
else
  echo "SKIP REQ-UPD-002.11: openssl is not available, so no self-signed certificate can be made"
  T_OPEN=0
fi
t_end

t_begin "REQ-UPD-002.11 a trusted https fixture host works, and its redirect to http is refused"
if [ "$HAVE_TLS" = 1 ]; then
  fresh_update_env
  export CURL_CA_BUNDLE="$SBX/cert.pem"
  export CONDUCTOR_TEST_UPDATE_URL="https://127.0.0.1:$TLS_PORT/install.sh"
  run_update --check
  assert_eq 0 "$RC" "positive control: a trusted https host is fetched"
  assert_contains "$OUT" "A newer Conductor is available: 0.5.0"
  export CONDUCTOR_TEST_UPDATE_URL="https://127.0.0.1:$TLS_PORT/redir-http"
  : > "$SBX/plain.log"
  before="$(sandbox_tree_sum "$CLAUDE_DIR")"
  run_update_pty $'y\n'
  assert_eq 1 "$RC" "exit status"
  assert_contains "$(flat "$OUT")" "Update refused: the fetch failed"
  assert_eq 0 "$(request_count "$SBX/plain.log")" "requests that reached the http target"
  assert_no_file "$MARKER"
  assert_eq "$before" "$(sandbox_tree_sum "$CLAUDE_DIR")" "the config folder"
  unset CURL_CA_BUNDLE
else
  echo "SKIP REQ-UPD-002.11: openssl is not available, so no https fixture host can be made"
  T_OPEN=0
fi
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-UPD-002.12 the release record states the fetch rules were built in bash 3.2 and the launcher is bash 3.2 syntax"
rec="$REPO/release/RECORD-0.4.0.md"
assert_file "$rec"
assert_contains "$(cat "$rec")" "The fetch rules of conductor update were built in bash 3.2: yes."
/bin/bash -n "$REPO/payload/claude/conductor/bin/conductor" || t_fail "launcher does not parse as bash"
first="$(head -n 1 "$REPO/payload/claude/conductor/bin/conductor")"
assert_eq "#!/usr/bin/env bash" "$first" "launcher shebang"
if grep -v '^[[:space:]]*#' "$REPO/payload/claude/conductor/bin/conductor" | grep -nE '(declare -A|mapfile|readarray|readlink -f|\$\{[A-Za-z_]+(,,|\^\^)\})' > /dev/null; then
  t_fail "the launcher uses a bash 4 feature"
fi
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-UPD-002.12 where update cannot run, it prints the reinstall command and fetches nothing: no python3"
fresh_update_env
sandbox_no_python
: > "$SBX/plain.log"
run_update
assert_eq 1 "$RC" "exit status"
assert_contains "$OUT" "The update needs python3 3.9 or later."
assert_contains "$OUT" "curl --proto '=https' --tlsv1.2 -fsSL https://conductorskill.com/install.sh | bash"
assert_eq 0 "$(request_count "$SBX/plain.log")" "requests"
assert_no_file "$MARKER"
t_end

t_begin "REQ-UPD-002.12 no install, a 0.3.0 install, a plugin install, a manual install and an unreadable record fetch nothing"
fresh_update_env
rm -rf "$CLAUDE_DIR/conductor/.install-manifest" "$CLAUDE_DIR/agents"
: > "$SBX/plain.log"
run_update
assert_eq 0 "$RC" "no install: exit status (nothing to update is not a failure, as with doctor)"
assert_contains "$OUT" "No Conductor install found."
assert_contains "$OUT" "https://conductorskill.com/install.sh"
fresh_update_env
rm -f "$CLAUDE_DIR/conductor/.install-manifest"
mkdir -p "$CLAUDE_DIR/skills/conductor"
cp "$REPO/tests/fixtures/doctor/manifest-v030-claude.txt" "$CLAUDE_DIR/skills/conductor/.install-manifest"
run_update
assert_eq 0 "$RC" "0.3.0: exit status"
assert_contains "$OUT" "This is a Conductor 0.3.0 install. The new installer upgrades it:"
fresh_update_env
fx_manifest "$CLAUDE_DIR" 'method="plugin"'
run_update
assert_eq 0 "$RC" "plugin: exit status"
assert_contains "$OUT" "claude plugin update conductor"
fresh_update_env
fx_manifest "$CLAUDE_DIR" 'method="manual"'
run_update
assert_eq 0 "$RC" "manual: exit status"
assert_contains "$OUT" "This install was recorded as manual."
fresh_update_env
printf '{ not json' > "$CLAUDE_DIR/conductor/.install-manifest"
run_update
assert_eq 1 "$RC" "unreadable record: exit status"
assert_contains "$OUT" "The install record could not be read. Nothing was fetched."
fresh_update_env
rm -f "$CLAUDE_DIR/conductor/lib/facts.json"
run_update
assert_eq 1 "$RC" "missing facts: exit status"
assert_contains "$OUT" "Conductor's facts file is missing."
assert_eq 0 "$(request_count "$SBX/plain.log")" "requests across all of these"
assert_no_file "$MARKER"
t_end

# ---------------------------------------------------------------------------------
t_begin "REQ-UPD-002.1 a real built installer is a valid source: the preview reads its data blocks and its changelog"
rm -rf "$SBX/buildrepo"
mkdir -p "$SBX/buildrepo"
cp -R "$REPO/tools" "$REPO/installer" "$REPO/payload" "$SBX/buildrepo/"
cp "$REPO/CHANGELOG.md" "$SBX/buildrepo/CHANGELOG.md"
find "$SBX/buildrepo" -name '__pycache__' -prune -exec rm -rf {} +
"$SBX_PY" -B - "$SBX/buildrepo" << 'PYEOF'
import json, sys
root = sys.argv[1]
p = root + "/payload/components.json"
c = json.load(open(p))
c["version"] = "0.5.0"
json.dump(c, open(p, "w"), indent=2)
cl = root + "/CHANGELOG.md"
text = open(cl).read()
text = text.replace("## 0.3.0", "## 0.5.0 (2026-11-01)\n\n- Built-installer entry for the update test.\n\n## 0.3.0", 1)
open(cl, "w").write(text)
PYEOF
if (cd "$SBX/buildrepo" && "$SBX_PY" -B tools/build.py > "$SBX/build.out" 2>&1); then
  fresh_update_env
  cp "$SBX/buildrepo/install.sh" "$WWW/install.sh"
  run_update_pty $'n\n'
  assert_eq 0 "$RC" "exit status"
  assert_contains "$OUT" "  Available version: 0.5.0"
  assert_contains "$OUT" "## 0.5.0 (2026-11-01)"
  assert_contains "$OUT" "Built-installer entry for the update test."
  assert_contains "$OUT" "Files to replace ("
  assert_not_contains "$OUT" "could not be read and were skipped"
  assert_not_contains "$OUT" "Installer sha256:"
  assert_eq "$(sha_of "$WWW/install.sh")" "$(printf '%s\n' "$OUT" | sed -n '/sha256 of the fetched file:/{n;s/^ *//;p;}')" "sha256 shown"
else
  t_fail "the fixture build failed: $(tail -n 3 "$SBX/build.out")"
fi
t_end

t_begin "REQ-UPD-002.8 the real installer applies an update, removing an unmodified dropped file and keeping a modified one"
rm -rf "$SBX/buildrepo2"
cp -R "$SBX/buildrepo" "$SBX/buildrepo2"
"$SBX_PY" -B - "$SBX/buildrepo2/payload/components.json" << 'PYEOF'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c["files"] = [f for f in c["files"] if f["id"] not in ("runbook_reflect", "runbook_execution")]
json.dump(c, open(p, "w"), indent=2)
PYEOF
rm -f "$SBX/buildrepo2/payload/claude/conductor/runbooks/reflect-and-land.md" "$SBX/buildrepo2/payload/claude/conductor/runbooks/execution-discipline.md"
if (cd "$SBX/buildrepo2" && "$SBX_PY" -B tools/build.py > "$SBX/build2.out" 2>&1); then
  fresh_roots 2.1.296
  mkdir -p "$CLAUDE_DIR"
  rm -rf "$UTMP"
  mkdir -p "$UTMP"
  rm -f "$MARKER" "$SBX/plain.log"
  export TMPDIR="$UTMP"
  export CONDUCTOR_TEST_UPDATE_URL="http://127.0.0.1:$PLAIN_PORT/install.sh"
  OUT="$(CONDUCTOR_YES=1 sandbox_notty /bin/bash "$REPO/install.sh" --core < /dev/null 2>&1)"
  RC=$?
  assert_eq 0 "$RC" "the real installer's first run: $(printf '%s' "$OUT" | tail -n 3)"
  assert_file "$CLAUDE_DIR/conductor/runbooks/reflect-and-land.md" "unmodified runbook installed"
  printf 'my own notes\n' >> "$CLAUDE_DIR/conductor/runbooks/execution-discipline.md"
  cp "$SBX/buildrepo2/install.sh" "$WWW/install.sh"
  run_update_pty $'y\n\n\n\n\n\n\n\n\n\n'
  assert_eq 0 "$RC" "update exit status"
  assert_contains "$OUT" "Files to remove (no longer shipped) (1)"
  assert_contains "$OUT" "  conductor/runbooks/reflect-and-land.md"
  assert_contains "$OUT" "  conductor/runbooks/execution-discipline.md (no longer shipped, but you changed it)"
  assert_contains "$OUT" "Update finished. Installed version: 0.5.0"
  assert_no_file "$CLAUDE_DIR/conductor/runbooks/reflect-and-land.md" "the unmodified dropped file is removed"
  assert_file "$CLAUDE_DIR/conductor/runbooks/execution-discipline.md" "the modified dropped file is kept"
  assert_contains "$(flat "$OUT")" "execution-discipline.md" "the kept file is named"
  m="$CLAUDE_DIR/conductor/.install-manifest"
  assert_eq 0.5.0 "$(json_get "$m" version)" "manifest version"
  assert_eq 0 "$("$SBX_PY" -B -c 'import json, sys; print(len([f for f in json.load(open(sys.argv[1]))["files"] if "reflect-and-land" in f["dest"] or "execution-discipline" in f["dest"]]))' "$m")" "neither dropped file stays in the record"
  assert_eq "$(sha_of "$WWW/install.sh")" "$(json_get "$m" installer_sha256)" "the fetched file's sha256 is in the record"
else
  t_fail "the fixture build failed: $(tail -n 3 "$SBX/build2.out")"
fi
t_end

t_begin "REQ-UPD-002.4 REQ-DIAG-001.5 the doctor and update --check read the record a real 0.3.0 install and a real upgrade wrote (settings_created, agents_skills root, legacy_030)"
fresh_roots 2.1.296
mkdir -p "$CLAUDE_DIR" "$CODEX_DIR"
rm -rf "$UTMP"
mkdir -p "$UTMP"
rm -f "$MARKER" "$SBX/plain.log"
export TMPDIR="$UTMP"
export CONDUCTOR_TEST_UPDATE_URL="http://127.0.0.1:$PLAIN_PORT/install.sh"
OUT="$(CONDUCTOR_YES=1 sandbox_notty /bin/bash "$REPO/tests/fixtures/install-0.3.0.sh" < /dev/null 2>&1)"
assert_eq 0 "$?" "the 0.3.0 install"
OUT="$(PTY_INPUT=$'y\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\ny\n' sandbox_pty /bin/bash "$REPO/install.sh" --full)"
assert_eq 0 "$?" "the upgrade"
m="$CLAUDE_DIR/conductor/.install-manifest"
assert_eq True "$("$SBX_PY" -B -c 'import json, sys; d = json.load(open(sys.argv[1])); print("legacy_030" in d)' "$m")" "legacy_030 is recorded"
assert_eq True "$("$SBX_PY" -B -c 'import json, sys; d = json.load(open(sys.argv[1])); print(d.get("settings_created") is True)' "$m")" "settings_created is recorded"
assert_eq True "$("$SBX_PY" -B -c 'import json, sys; d = json.load(open(sys.argv[1])); print(any(f.get("root") == "agents_skills" for f in d["files"]))' "$CODEX_DIR/conductor/.install-manifest")" "an agents_skills root is recorded"
run_conductor doctor --managed-settings "$SBX/managed-settings.json"
assert_eq 0 "$RC" "doctor exit status"
assert_not_contains "$OUT" "unreadable" "the doctor reads the record"
assert_contains "$OUT" "Version: 0.4.0"
make_installer "$WWW/install.sh" 0.5.0
run_update --check
assert_eq 0 "$RC" "update --check exit status"
assert_contains "$OUT" "0.5.0"
assert_not_contains "$OUT" "could not be read"
t_end

t_summary
