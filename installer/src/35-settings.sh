# 35-settings.sh [L1a]: the install record (manifest) and settings.json wrappers.
#
# With python3 usable, every record and settings change goes through the 2
# embedded helpers (py/manifest.py, py/settings_merge.py), each run from a mode
# 600 temp copy, with data passed by file path. They run with -I (isolated: no
# environment variables, no user site) and -B (no bytecode files, which some
# systems would write into the home folder). Without python3 the record is
# written by a small bash writer (mfb_*) that covers the core fields, and
# settings.json is never changed.
#
# Globals: PY_MANIFEST_FILE PY_SETTINGS_FILE TMP_FILES MFB_DIR (temp copies),
# WIRE_IDS (hook file ids to wire; set by install_full_tier), WIRED_SAID (ids
# whose "wired" line was printed: each prints once however often hooks are
# merged), HOOKS_REFRESHED (1 when a re-run changed Conductor's own hook entries in
# settings.json: the summary says so), KEYS_WRITTEN and KEYS_PRINTED (settings paths written or printed, 1
# per line; the summary shows them next to the effort pins that 50-effort.sh
# tracks in PINS_*).

PY_MANIFEST_FILE=""
PY_SETTINGS_FILE=""
TMP_FILES=""
MFB_DIR=""
MF_FROZEN_SAID=0
WIRE_IDS=""
WIRED_SAID=""
HOOKS_PRINTED=0
HOOKS_REFRESHED=0
KEYS_WRITTEN=""
KEYS_PRINTED=""
SETTINGS_WRITTEN=0
SKIPPED_HELD=""
LAUNCHER_REL="conductor/bin/conductor"
MF_BATCH=0
MF_STARTED=""

# ---- temp copies of the helpers ---------------------------------------------------

# Extracts the embedded helpers once, in the main shell (a command substitution
# would lose the variables). Safe to call again.
py_prepare() {
  if [ -z "$MFB_DIR" ]; then
    MFB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/conductor-mfb.XXXXXX")" || { MFB_DIR=""; return 1; }
    TMP_FILES="${TMP_FILES}${MFB_DIR}"$'\n'
  fi
  if [ -n "$PY" ]; then
    if [ -z "$PY_MANIFEST_FILE" ]; then
      PY_MANIFEST_FILE="$(mktemp "${TMPDIR:-/tmp}/conductor-manifest.XXXXXX")" || { PY_MANIFEST_FILE=""; return 1; }
      TMP_FILES="${TMP_FILES}${PY_MANIFEST_FILE}"$'\n'
      emit_py_manifest > "$PY_MANIFEST_FILE" || return 1
    fi
    if [ -z "$PY_SETTINGS_FILE" ]; then
      PY_SETTINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/conductor-settings.XXXXXX")" || { PY_SETTINGS_FILE=""; return 1; }
      TMP_FILES="${TMP_FILES}${PY_SETTINGS_FILE}"$'\n'
      emit_py_settings_merge > "$PY_SETTINGS_FILE" || return 1
    fi
  fi
  return 0
}

# Removes the temp copies (runs when the installer exits, by any route).
cleanup_tmp() {
  local f
  manifest_flush_pending
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      */conductor-mfb.*) rm -rf "$f" ;;
      */conductor-manifest.*|*/conductor-settings.*|*/conductor-block.*|*/conductor-doc.*|*/conductor-spec.*) rm -f "$f" ;;
    esac
  done <<EOF
$TMP_FILES
EOF
  TMP_FILES=""
}

# new_tmp: makes a mode 600 temp file, remembers it for cleanup, prints its path
# into the variable named by $1.
new_tmp() { # $1=variable name  $2=label
  local p
  p="$(mktemp "${TMPDIR:-/tmp}/conductor-$2.XXXXXX")" || return 1
  TMP_FILES="${TMP_FILES}${p}"$'\n'
  eval "$1=\$p"
}

# ---- the install record -----------------------------------------------------------

mf_path() { printf '%s/conductor/.install-manifest' "$1"; }

manifest_exists() { [ -f "$(mf_path "$1")" ]; }

# manifest_py ROOT ARGS...: runs manifest.py on the record of ROOT.
manifest_py() {
  local root="$1"
  shift
  [ -n "$PY_MANIFEST_FILE" ] || py_prepare || return 1
  if [ "${1:-}" != "add-files" ]; then manifest_flush "$root" || return 1; fi
  "$PY" -I -B "$PY_MANIFEST_FILE" "$(mf_path "$root")" "$@"
}

# manifest_batch_begin / manifest_batch_end: file records made between the 2
# calls are collected and written in 1 step (at the end, or before any other
# change to the record). Without them each manifest_add_file writes at once.
manifest_batch_begin() { MF_BATCH=1; }

manifest_batch_end() {
  MF_BATCH=0
  if [ "$HAVE_CLAUDE" = 1 ]; then manifest_flush "$CLAUDE_DIR" || return 1; fi
  if [ "$HAVE_CODEX" = 1 ]; then manifest_flush "$CODEX_DIR" || return 1; fi
  return 0
}

# manifest_flush_pending: writes any collected file records, so that a run that
# stops early still records the files it wrote. Never fails.
manifest_flush_pending() {
  if [ "${DRY_RUN:-0}" = "1" ] || [ -z "${PY:-}" ]; then return 0; fi
  if [ "${HAVE_CLAUDE:-0}" = 1 ]; then manifest_flush "$CLAUDE_DIR" 2> /dev/null || true; fi
  if [ "${HAVE_CODEX:-0}" = 1 ]; then manifest_flush "$CODEX_DIR" 2> /dev/null || true; fi
  return 0
}

# manifest_flush ROOT: writes the collected file records of ROOT.
manifest_flush() {
  local root="$1" pf
  [ -n "$PY" ] || return 0
  [ -n "$MFB_DIR" ] || return 0
  pf="$MFB_DIR/$(mfb_rk "$root").pending"
  [ -s "$pf" ] || return 0
  [ -n "$PY_MANIFEST_FILE" ] || return 0
  manifest_exists "$root" || return 0
  if "$PY" -I -B "$PY_MANIFEST_FILE" "$(mf_path "$root")" add-files "$pf"; then
    : > "$pf"
  else
    return 1
  fi
}

mf_source_url() { printf 'https://%s%s' "$UPDATE_HOST" "$UPDATE_PATH"; }

# manifest_begin ROOT: creates the record when there is none (a record that
# cannot be read is backed up first). Called before the first settings change.
manifest_begin() {
  local root="$1" harness mf bak sha rc
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  case " $MF_STARTED " in *" $root "*) return 0 ;; esac
  harness="$(harness_of_mroot "$root")"
  mf="$(mf_path "$root")"
  sha="${CONDUCTOR_INSTALLER_SHA256:-}"
  case "$sha" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) [ "${#sha}" = 64 ] || sha="" ;;
    *) sha="" ;;
  esac
  if [ -n "$PY" ]; then
    py_prepare || return 1
    manifest_py "$root" init "version=$CONDUCTOR_VERSION" "harness=$harness" "source_url=$(mf_source_url)" \
      "python3=$PY" "installer_sha256=$sha" "launcher=$LAUNCHER_REL" 2> /dev/null
    rc=$?
    if [ "$rc" = 3 ]; then
      bak="$(backup_file "$mf")" || return 1
      warn "the install record could not be read; a new one is started"
      info "backup: $bak"
      rm -f "$mf"
      manifest_py "$root" init "version=$CONDUCTOR_VERSION" "harness=$harness" "source_url=$(mf_source_url)" \
        "python3=$PY" "installer_sha256=$sha" "launcher=$LAUNCHER_REL" || return 1
    elif [ "$rc" != 0 ]; then
      return 1
    fi
  else
    py_prepare || return 1
    mfb_load "$root"
    if mfb_is_frozen "$root"; then mfb_say_frozen; MF_STARTED="$MF_STARTED $root"; return 0; fi
    mfb_write "$root"
  fi
  MF_STARTED="$MF_STARTED $root"
  if [ ! -f "$mf" ]; then return 0; fi
  mf_seed_legacy "$root" "$harness"
}

# Carries what a 0.3.0 install recorded into a new record (REQ-UPD-003.3).
mf_seed_legacy() { # $1=root $2=harness
  local root="$1" harness="$2"
  if [ "$harness" = "claude" ] && [ "$EXISTING_CLAUDE" = "v030" ]; then
    if [ "$LEGACY_CLAUDE_MD_PATCHED" = 1 ]; then manifest_set "$root" legacy_030_claude_md true; fi
    if [ -n "$LEGACY_MODEL_SET" ]; then manifest_set "$root" legacy_030_model "$(json_quote "$LEGACY_MODEL_SET")"; fi
  elif [ "$harness" = "codex" ] && [ "$EXISTING_CODEX" = "v030" ]; then
    if [ "$LEGACY_CODEX_MD_PATCHED" = 1 ]; then manifest_set "$root" legacy_030_codex_md true; fi
  fi
}

# manifest_set ROOT KEY JSON: sets a top-level key to a JSON value. The 3 legacy
# keys (legacy_030_claude_md, legacy_030_codex_md, legacy_030_model) set a field
# inside the legacy_030 object.
manifest_set() {
  local root="$1" key="$2" val="$3"
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  if [ -n "$PY" ]; then
    case "$key" in
      legacy_030_claude_md) manifest_py "$root" sub-set legacy_030 claude_md_patched "$val" ;;
      legacy_030_codex_md) manifest_py "$root" sub-set legacy_030 codex_agents_md_patched "$val" ;;
      legacy_030_model) manifest_py "$root" sub-set legacy_030 settings_model_set "$val" ;;
      *) manifest_py "$root" set "$key" "$val" ;;
    esac
  else
    mfb_set "$root" "$key" "$val"
  fi
}

# manifest_get ROOT KEY: prints a value (text as is, a list of text 1 item per
# line, null as nothing). Empty when there is no record.
manifest_get() {
  local root="$1" key="$2"
  manifest_exists "$root" || return 0
  if [ -n "$PY" ]; then
    manifest_py "$root" get "$key" 2>/dev/null
  else
    mfb_read_key "$(mf_path "$root")" "$key"
  fi
}

# manifest_files ROOT: dest, root key, sha256, policy, component, id (tab separated).
manifest_files() {
  local root="$1"
  manifest_exists "$root" || return 0
  if [ -n "$PY" ]; then
    manifest_py "$root" list-files 2>/dev/null
  else
    mfb_read_files "$(mf_path "$root")"
  fi
}

# manifest_sha_of ROOT DEST ROOTKEY: the recorded sha256, or nothing.
manifest_sha_of() {
  manifest_files "$1" | awk -F '\t' -v d="$2" -v r="$3" '$1 == d && $2 == r { print $3; exit }'
}

# manifest_add_file ROOT ID [DEST [POLICY]]: records the file now on disk.
manifest_add_file() {
  local root="$1" id="$2" dest="${3:-}" policy="${4:-}" rkey rdir path real sha
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  [ -n "$dest" ] || dest="$(file_dest "$id")"
  [ -n "$policy" ] || policy="$(file_policy "$id")"
  [ "$policy" = "also" ] && policy="replace"
  rkey="$(file_root "$id")"
  rdir="$(rootdir_for "$root" "$rkey")"
  path="$rdir/$dest"
  real="$path"
  if [ -L "$path" ]; then real="$(resolve_link "$path")" || return 1; fi
  sha="$(sha256_of "$real")" || return 1
  if [ -n "$PY" ]; then
    if [ "$MF_BATCH" = 1 ] && [ -n "$MFB_DIR" ]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$dest" "${rkey:--}" "$sha" "$policy" "$(file_component "$id")" "$id" >> "$MFB_DIR/$(mfb_rk "$root").pending"
    else
      manifest_py "$root" add-file "$dest" "${rkey:--}" "$sha" "$policy" "$(file_component "$id")" "$id"
    fi
  else
    mfb_add_file "$root" "$dest" "$rkey" "$sha" "$policy" "$(file_component "$id")" "$id"
  fi
}

# manifest_rm_file ROOT DEST ROOTKEY: drops a file entry.
manifest_rm_file() {
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  manifest_exists "$1" || return 0
  if [ -n "$PY" ]; then
    manifest_py "$1" rm-file "$2" "${3:--}"
  else
    mfb_rm_file "$1" "$2" "$3"
  fi
}

# json_list WORD...: prints the words as a JSON list of strings.
json_list() {
  local out="" w
  for w in "$@"; do
    if [ -n "$out" ]; then out="$out, "; fi
    out="$out\"$w\""
  done
  printf '[%s]' "$out"
}

# manifest_finish: completes the record of every root this run installed into,
# then removes the 0.3.0 records the upgrade replaced.
manifest_finish() {
  local comps c judge
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  comps="$SELECTED"
  for c in $SKIPPED_HELD; do
    case " $comps " in *" $c "*) ;; *) comps="$comps $c" ;; esac
  done
  judge="${JUDGE_RUNG:-}"
  if [ "$HAVE_CLAUDE" = 1 ]; then
    manifest_begin "$CLAUDE_DIR" || true
    case "$judge" in
      1|3) manifest_set_many "$CLAUDE_DIR" version "$(json_quote "$CONDUCTOR_VERSION")" components "$(json_list $comps)" \
             python3 "$(mf_json_or_null "$PY")" launcher "$(json_quote "$LAUNCHER_REL")" judge_rung "$judge" ;;
      *) manifest_set_many "$CLAUDE_DIR" version "$(json_quote "$CONDUCTOR_VERSION")" components "$(json_list $comps)" \
             python3 "$(mf_json_or_null "$PY")" launcher "$(json_quote "$LAUNCHER_REL")" ;;
    esac
    if [ -n "${CONDUCTOR_INSTALLER_SHA256:-}" ] && [ "${#CONDUCTOR_INSTALLER_SHA256}" = 64 ]; then
      manifest_set "$CLAUDE_DIR" installer_sha256 "$(json_quote "$CONDUCTOR_INSTALLER_SHA256")"
    fi
    if [ "$EXISTING_CLAUDE" = "v030" ]; then
      rm -f "$CLAUDE_DIR/skills/conductor/.install-manifest"
    fi
  fi
  if [ "$HAVE_CODEX" = 1 ]; then
    manifest_begin "$CODEX_DIR" || true
    manifest_set_many "$CODEX_DIR" version "$(json_quote "$CONDUCTOR_VERSION")" components '["core"]' \
      python3 "$(mf_json_or_null "$PY")" launcher "$(json_quote "$LAUNCHER_REL")"
    if [ "$HAVE_CLAUDE" = 1 ]; then manifest_share "$CODEX_DIR" "$CLAUDE_DIR"; fi
    if [ "$EXISTING_CODEX" = "v030" ]; then
      rm -f "$CODEX_DIR/.conductor-manifest"
    fi
  fi
  return 0
}

# manifest_set_many ROOT KEY JSON [KEY JSON ...]: several keys in 1 write.
manifest_set_many() {
  local root="$1"
  shift
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  if [ -n "$PY" ]; then
    manifest_py "$root" set-many "$@"
  else
    while [ "$#" -ge 2 ]; do
      mfb_set "$root" "$1" "$2"
      shift 2
    done
  fi
}

mf_json_or_null() {
  if [ -n "$1" ]; then json_quote "$1"; else printf 'null'; fi
}

# manifest_share CODEXROOT CLAUDEROOT / manifest_unshare: the Claude folders that
# use a Codex folder (shared_with in the Codex record).
manifest_share() {
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  if [ -n "$PY" ]; then manifest_py "$1" list-add shared_with "$2"; else mfb_list_edit "$1" shared_with add "$2"; fi
}

manifest_unshare() {
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  manifest_exists "$1" || return 0
  if [ -n "$PY" ]; then manifest_py "$1" list-del shared_with "$2"; else mfb_list_edit "$1" shared_with del "$2"; fi
}

# ---- the record without python3 ---------------------------------------------------
# Scratch state lives in MFB_DIR: <claude|codex>.<key> holds the JSON text of a
# key, <claude|codex>.files holds the file lines. mfb_write writes the whole
# record in the same layout manifest.py writes, from that state.

mfb_rk() { if [ "$1" = "$CLAUDE_DIR" ]; then printf 'claude'; else printf 'codex'; fi; }

mfb_frozen() { # $1=record path: true when it holds hooks, pins or env values
  [ -f "$1" ] || return 1
  grep -q '^  "hooks": \[$' "$1" && return 0
  grep -q '^  "pins": \[$' "$1" && return 0
  grep -q '^  "env_written": \[[^]]' "$1" && return 0
  return 1
}

# mfb_read_key RECORD KEY: the value, shown as manifest_get shows it.
mfb_read_key() {
  local raw
  raw="$(sed -n 's/^  "'"$2"'": \(.*\)$/\1/p' "$1" 2>/dev/null | head -1 | sed 's/,$//')"
  case "$raw" in
    null|"") ;;
    \"*) printf '%s\n' "$raw" | sed -e 's/^"//' -e 's/"$//' -e 's/\\"/"/g' -e 's/\\\\/\\/g' ;;
    \[*) printf '%s\n' "$raw" | sed -e 's/^\[//' -e 's/\]$//' -e 's/^"//' -e 's/"$//' -e 's/", "/\
/g' | grep -v '^$' || true ;;
    *) printf '%s\n' "$raw" ;;
  esac
}

# mfb_read_files RECORD: the file lines as tab separated fields.
mfb_read_files() {
  local tab
  tab="$(printf '\t')"
  sed -n 's/^    {"dest": "\([^"]*\)", "sha256": "\([^"]*\)", "policy": "\([^"]*\)", "component": "\([^"]*\)", "id": "\([^"]*\)"\(, "root": "\([^"]*\)"\)\{0,1\}}\{0,1\},\{0,1\}$/\1'"$tab"'\7'"$tab"'\2'"$tab"'\3'"$tab"'\4'"$tab"'\5/p' "$1" 2>/dev/null
}

# mfb_load ROOT: reads an existing record into the scratch state, once.
mfb_load() {
  local root="$1" rk mf k v
  [ -n "$MFB_DIR" ] || py_prepare || return 1
  rk="$(mfb_rk "$root")"
  [ -f "$MFB_DIR/$rk.loaded" ] && return 0
  : > "$MFB_DIR/$rk.loaded"
  : > "$MFB_DIR/$rk.files"
  mf="$(mf_path "$root")"
  [ -f "$mf" ] || return 0
  if mfb_frozen "$mf"; then
    : > "$MFB_DIR/$rk.frozen"
    return 0
  fi
  for k in method version source_url installed_at installer_sha256 harness components launcher python3 \
      doctrine_block doctrine_file judge_rung legacy_030 shared_with agents_skills_existed; do
    v="$(sed -n 's/^  "'"$k"'": \(.*\)$/\1/p' "$mf" | head -1 | sed 's/,$//')"
    if [ -n "$v" ]; then printf '%s' "$v" > "$MFB_DIR/$rk.$k"; fi
  done
  # an empty root field is kept as - so that read never collapses the tabs
  mfb_read_files "$mf" | awk -F '\t' -v OFS='\t' '{ if ($2 == "") $2 = "-"; print }' > "$MFB_DIR/$rk.files"
}

mfb_is_frozen() { [ -f "$MFB_DIR/$(mfb_rk "$1").frozen" ]; }

mfb_say_frozen() {
  if [ "$MF_FROZEN_SAID" = 0 ]; then
    MF_FROZEN_SAID=1
    warn "python3 is needed to update the install record; it was left as it was"
  fi
}

mfb_key() { # $1=rk $2=key $3=default -> JSON text
  if [ -f "$MFB_DIR/$1.$2" ]; then cat "$MFB_DIR/$1.$2"; else printf '%s' "$3"; fi
}

mfb_set() { # $1=root $2=key $3=json
  local rk
  rk="$(mfb_rk "$1")"
  mfb_load "$1"
  if mfb_is_frozen "$1"; then mfb_say_frozen; return 0; fi
  case "$2" in
    legacy_030_claude_md|legacy_030_codex_md|legacy_030_model)
      local cm="false" cx="false" ml="null" cur
      cur="$(mfb_key "$rk" legacy_030 '')"
      case "$cur" in *'"claude_md_patched": true'*) cm="true" ;; esac
      case "$cur" in *'"codex_agents_md_patched": true'*) cx="true" ;; esac
      ml="$(printf '%s' "$cur" | sed -n 's/.*"settings_model_set": \(.*\)}$/\1/p')"
      [ -n "$ml" ] || ml="null"
      case "$2" in
        legacy_030_claude_md) cm="$3" ;;
        legacy_030_codex_md) cx="$3" ;;
        legacy_030_model) ml="$3" ;;
      esac
      printf '{"claude_md_patched": %s, "codex_agents_md_patched": %s, "settings_model_set": %s}' "$cm" "$cx" "$ml" > "$MFB_DIR/$rk.legacy_030"
      ;;
    *) printf '%s' "$3" > "$MFB_DIR/$rk.$2" ;;
  esac
  mfb_write "$1"
}

mfb_add_file() { # $1=root $2=dest $3=rootkey $4=sha $5=policy $6=component $7=id
  local rk f
  rk="$(mfb_rk "$1")"
  mfb_load "$1"
  if mfb_is_frozen "$1"; then mfb_say_frozen; return 0; fi
  f="$MFB_DIR/$rk.files"
  awk -F '\t' -v OFS='\t' -v d="$2" -v r="${3:--}" -v s="$4" -v p="$5" -v c="$6" -v i="$7" \
    '$1 == d && $2 == r { print d, r, s, p, c, i; seen = 1; next } { print } END { if (!seen) print d, r, s, p, c, i }' "$f" > "$f.new"
  mv -f "$f.new" "$f"
  mfb_write "$1"
}

mfb_rm_file() { # $1=root $2=dest $3=rootkey
  local rk f
  rk="$(mfb_rk "$1")"
  mfb_load "$1"
  if mfb_is_frozen "$1"; then mfb_say_frozen; return 0; fi
  f="$MFB_DIR/$rk.files"
  awk -F '\t' -v d="$2" -v r="${3:--}" '!($1 == d && $2 == r)' "$f" > "$f.new"
  mv -f "$f.new" "$f"
  mfb_write "$1"
}

mfb_list_edit() { # $1=root $2=key $3=add|del $4=text
  local rk cur items out="" w
  rk="$(mfb_rk "$1")"
  mfb_load "$1"
  if mfb_is_frozen "$1"; then mfb_say_frozen; return 0; fi
  cur="$(mfb_key "$rk" "$2" '[]' | sed -e 's/^\[//' -e 's/\]$//' -e 's/", "/"\
"/g' | sed -e 's/^"//' -e 's/"$//' | grep -v '^$' || true)"
  items="$cur"
  if [ "$3" = "add" ]; then
    case "
$items
" in *"
$4
"*) ;; *) items="$items
$4" ;; esac
  else
    items="$(printf '%s\n' "$items" | grep -vxF "$4" || true)"
  fi
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    if [ -n "$out" ]; then out="$out, "; fi
    out="$out$(json_quote "$w")"
  done <<EOF
$items
EOF
  printf '[%s]' "$out" > "$MFB_DIR/$rk.$2"
  mfb_write "$1"
}

# mfb_write ROOT: writes the whole record from the scratch state (temp file and
# rename). Writes nothing when the record would not change except its time.
mfb_write() {
  local root="$1" rk mf now tmp old files first line k
  rk="$(mfb_rk "$root")"
  mf="$(mf_path "$root")"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  old=""
  if [ -f "$mf" ]; then old="$(sed -n 's/^  "updated_at": "\(.*\)",$/\1/p' "$mf" | head -1)"; fi
  [ -n "$old" ] || old="$now"
  mkdir -p "$root/conductor" || return 1
  tmp="$(mktemp "$root/conductor/.manifest-tmp.XXXXXX")" || return 1
  mfb_compose "$root" "$rk" "$old" > "$tmp" || { rm -f "$tmp"; return 1; }
  if [ -f "$mf" ] && cmp -s "$tmp" "$mf"; then rm -f "$tmp"; return 0; fi
  if [ -f "$mf" ]; then
    mfb_compose "$root" "$rk" "$now" > "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  mv -f "$tmp" "$mf" || { rm -f "$tmp"; return 1; }
}

mfb_compose() { # $1=root $2=rk $3=updated_at
  local rk="$2" harness inst files line n i dflt_comp
  harness="claude"
  if [ "$rk" = "codex" ]; then harness="codex"; fi
  inst="$(mfb_key "$rk" installed_at '')"
  [ -n "$inst" ] || inst="\"$3\""
  printf '{\n'
  printf '  "schema": 1,\n'
  printf '  "product": "conductor",\n'
  printf '  "method": %s,\n' "$(mfb_key "$rk" method '"installer"')"
  printf '  "version": %s,\n' "$(mfb_key "$rk" version "\"$CONDUCTOR_VERSION\"")"
  printf '  "source_url": %s,\n' "$(mfb_key "$rk" source_url "$(json_quote "$(mf_source_url)")")"
  printf '  "installed_at": %s,\n' "$inst"
  printf '  "updated_at": "%s",\n' "$3"
  printf '  "installer_sha256": %s,\n' "$(mfb_key "$rk" installer_sha256 null)"
  printf '  "harness": %s,\n' "$(mfb_key "$rk" harness "\"$harness\"")"
  printf '  "components": %s,\n' "$(mfb_key "$rk" components '["core"]')"
  printf '  "launcher": %s,\n' "$(mfb_key "$rk" launcher "$(json_quote "$LAUNCHER_REL")")"
  printf '  "python3": %s,\n' "$(mfb_key "$rk" python3 null)"
  n="$(grep -c . "$MFB_DIR/$rk.files" 2>/dev/null || true)"
  if [ "${n:-0}" = 0 ]; then
    printf '  "files": [],\n'
  else
    printf '  "files": [\n'
    i=0
    while IFS="$(printf '\t')" read -r f_dest f_root f_sha f_policy f_comp f_id; do
      [ -n "$f_dest" ] || continue
      if [ "$f_root" = "-" ]; then f_root=""; fi
      i=$((i + 1))
      line="    {\"dest\": $(json_quote "$f_dest"), \"sha256\": \"$f_sha\", \"policy\": \"$f_policy\", \"component\": \"$f_comp\", \"id\": \"$f_id\""
      if [ -n "$f_root" ]; then line="$line, \"root\": $(json_quote "$f_root")"; fi
      line="$line}"
      if [ "$i" -lt "$n" ]; then line="$line,"; fi
      printf '%s\n' "$line"
    done < "$MFB_DIR/$rk.files"
    printf '  ],\n'
  fi
  printf '  "doctrine_block": %s,\n' "$(mfb_key "$rk" doctrine_block false)"
  if [ -f "$MFB_DIR/$rk.doctrine_file" ]; then printf '  "doctrine_file": %s,\n' "$(cat "$MFB_DIR/$rk.doctrine_file")"; fi
  printf '  "hooks_wired": false,\n'
  printf '  "hooks": [],\n'
  printf '  "pins": [],\n'
  printf '  "env_written": [],\n'
  printf '  "judge_rung": %s,\n' "$(mfb_key "$rk" judge_rung null)"
  printf '  "legacy_030": %s,\n' "$(mfb_key "$rk" legacy_030 '{"claude_md_patched": false, "codex_agents_md_patched": false, "settings_model_set": null}')"
  if [ -f "$MFB_DIR/$rk.agents_skills_existed" ]; then
    printf '  "shared_with": %s,\n' "$(mfb_key "$rk" shared_with '[]')"
    printf '  "agents_skills_existed": %s\n' "$(cat "$MFB_DIR/$rk.agents_skills_existed")"
  else
    printf '  "shared_with": %s\n' "$(mfb_key "$rk" shared_with '[]')"
  fi
  printf '}\n'
}

# ---- settings.json -----------------------------------------------------------------

settings_path() { printf '%s/settings.json' "$CLAUDE_DIR"; }

# settings_py ARGS...: runs settings_merge.py on settings.json.
settings_py() {
  [ -n "$PY_SETTINGS_FILE" ] || py_prepare || return 1
  "$PY" -I -B "$PY_SETTINGS_FILE" "$(settings_path)" "$@" 2> /dev/null
}

# settings_apply NEWTEXTFILE: backs settings.json up (once per run, with its own
# mode) and replaces it by temp file and rename, through a link if it is one.
settings_apply() {
  local s real mode existed=0 bak
  s="$(settings_path)"
  real="$s"
  if [ -L "$s" ]; then real="$(resolve_link "$s")" || { err "too many symbolic links: $s"; return 1; }; fi
  mode=600
  if [ -f "$real" ]; then
    existed=1
    mode="$(mode_of "$real")"
    if [ "$SETTINGS_BACKED_UP" = 0 ]; then
      bak="$(backup_file "$s")" || return 1
      SETTINGS_BACKED_UP=1
      info "backup: $bak"
    fi
  fi
  atomic_write "$s" "$mode" < "$1" || { err "could not write $s"; return 1; }
  SETTINGS_WRITTEN=1
  if [ "$existed" = 0 ]; then manifest_set "$CLAUDE_DIR" settings_created true; fi
  return 0
}

# settings_print_snippet JSONPATH JSONVALUE REASON: shows the change to make by
# hand, as the smallest JSON object that holds it.
settings_print_snippet() {
  local path="$1" value="$2" reason="$3" rest seg prefix="" suffix=""
  rest="$path"
  while [ -n "$rest" ]; do
    seg="${rest%%.*}"
    if [ "$seg" = "$rest" ]; then rest=""; else rest="${rest#*.}"; fi
    prefix="$prefix{\"$seg\": "
    suffix="$suffix}"
  done
  KEYS_PRINTED="${KEYS_PRINTED}${path}"$'\n'
  info "to set it yourself: $reason"
  say "      ${prefix}${value}${suffix}"
}

# settings_set_key JSONPATH JSONVALUE: writes 1 settings key after recording its
# previous value in the install record (the first previous value stays through
# re-runs). Returns 0 when the key is written or already holds the value, 1 when
# nothing was written (the change is printed instead).
settings_set_key() {
  local path="$1" value="$2" cur rc prev present tmp
  if [ "${DRY_RUN:-0}" = "1" ]; then info "would set $path"; return 0; fi
  if [ -z "$PY" ]; then
    settings_print_snippet "$path" "$value" "python3 is not usable here"
    return 1
  fi
  [ "$HAVE_CLAUDE" = 1 ] || return 1
  py_prepare || return 1
  manifest_begin "$CLAUDE_DIR" || return 1
  cur="$(settings_py get "$path")"
  rc=$?
  case "$rc" in
    0) present=1; prev="$cur" ;;
    12) present=0; prev="null" ;;
    *)
      settings_print_snippet "$path" "$value" "settings.json could not be changed safely"
      return 1
      ;;
  esac
  if [ "$present" = 1 ] && [ "$cur" = "$value" ]; then
    info "$path is already set"
    return 0
  fi
  manifest_py "$CLAUDE_DIR" pin-record "$path" "$value" "$prev" "$present" || return 1
  new_tmp tmp settings || return 1
  settings_py set "$path" "$value" > "$tmp"
  rc=$?
  if [ "$rc" = 0 ]; then
    settings_apply "$tmp" || return 1
  elif [ "$rc" != 11 ]; then
    manifest_py "$CLAUDE_DIR" pin-forget "$path" || true
    settings_print_snippet "$path" "$value" "settings.json could not be changed safely"
    return 1
  fi
  KEYS_WRITTEN="${KEYS_WRITTEN}${path}"$'\n'
  ok "set $path"
  return 0
}

# settings_unset_key JSONPATH: puts a key Conductor wrote back to what it was
# (its recorded previous value, or no key). Keys Conductor did not write stay.
settings_unset_key() {
  local path="$1" line prev present tmp rc key name
  if [ "${DRY_RUN:-0}" = "1" ]; then info "would restore $path"; return 0; fi
  [ -n "$PY" ] || return 1
  py_prepare || return 1
  line="$(manifest_py "$CLAUDE_DIR" list-pins 2>/dev/null | awk -F '\t' -v k="$path" '$1 == k { print; exit }')"
  if [ -n "$line" ]; then
    prev="$(printf '%s' "$line" | cut -f3)"
    present="$(printf '%s' "$line" | cut -f4)"
  else
    # An env value that an earlier Conductor install recorded under env_written
    # has no previous value to restore: the key is removed.
    case "$path" in
      env.*) name="${path#env.}" ;;
      *) return 1 ;;
    esac
    case "$(manifest_get "$CLAUDE_DIR" env_written)" in *"$name"*) ;; *) return 1 ;; esac
    prev="null"
    present=0
  fi
  new_tmp tmp settings || return 1
  if [ "$present" = 1 ]; then settings_py set "$path" "$prev" > "$tmp"; else settings_py unset "$path" > "$tmp"; fi
  rc=$?
  if [ "$rc" = 0 ]; then settings_apply "$tmp" || return 1; elif [ "$rc" != 11 ]; then return 1; fi
  manifest_py "$CLAUDE_DIR" pin-forget "$path" || true
  if [ -n "${name:-}" ]; then manifest_py "$CLAUDE_DIR" list-del env_written "$name" || true; fi
  key="$path"
  if [ "$present" = 1 ]; then ok "restored $key"; else ok "removed $key"; fi
}

# hook_command_text PYTHON SCRIPT ARGS: the command settings.json holds for 1 hook,
# the same text settings_merge.py writes. A python3 that is missing or not executable,
# or a script that is missing, or there but not readable, makes it do nothing and exit
# 0 (the guard: -x on python3, -f and -r on the script), and python3 runs isolated with
# no bytecode files (-I -B).
hook_command_text() {
  local cmd
  cmd="[ ! -x \"$1\" ] || [ ! -f \"$2\" ] || [ ! -r \"$2\" ] || \"$1\" -I -B \"$2\""
  if [ -n "$3" ]; then cmd="$cmd $3"; fi
  printf '%s' "$cmd"
}

# settings_prune_dangling: removes the hook entries that Conductor wrote (the
# guarded command naming a script under the Claude folder's conductor/hooks/ folder)
# whose script is no longer there, each one named. It runs after any step that deletes
# files (a dropped file, a removed component, the uninstall), so no entry outlives the
# script it points at. A hook of your own is never removed, whatever it names.
settings_prune_dangling() {
  local out gone rec rc
  [ "$HAVE_CLAUDE" = 1 ] || return 0
  [ -n "$PY" ] || return 0
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  [ -f "$(settings_path)" ] || return 0
  py_prepare || return 0
  new_tmp out spec || return 0
  new_tmp gone spec || return 0
  new_tmp rec spec || return 0
  if manifest_exists "$CLAUDE_DIR"; then manifest_py "$CLAUDE_DIR" get hooks > "$rec" 2> /dev/null || : > "$rec"; else : > "$rec"; fi
  settings_py prune "$CLAUDE_DIR" "$gone" "$rec" > "$out"
  rc=$?
  if [ "$rc" = 0 ]; then
    settings_apply "$out" || return 0
    section_heading claude
    ok "removed hook entries whose script is gone"
    settings_say_removed "$gone"
  fi
  return 0
}

# settings_say_removed FILE: names each hook entry the settings merge removed, 1 line
# each (a row of FILE is an event, a matcher and a script name, separated by tabs),
# without control or direction characters, so a removal is never silent.
settings_say_removed() {
  local line ev matcher name tab
  tab="$(printf '\t')"
  [ -s "$1" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ev="${line%%$tab*}"
    line="${line#*$tab}"
    matcher="${line%%$tab*}"
    name="${line#*$tab}"
    ev="$(printf '%s' "$ev" | sanitize_text | cut -c1-40)"
    matcher="$(printf '%s' "$matcher" | sanitize_text | cut -c1-40)"
    name="$(printf '%s' "$name" | sanitize_text | cut -c1-60)"
    if [ -n "$matcher" ]; then
      info "removed hook entry: $ev, matcher $matcher, $name"
    else
      info "removed hook entry: $ev, no matcher, $name"
    fi
  done < "$1"
}

# hook_entries_text: prints the settings.json entries for WIRE_IDS as JSON text to
# add by hand, 1 key per event (all the groups of an event in 1 list), with the
# commas between them, so that pasting it keeps every hook. $1 is the python3 path
# to show.
hook_entries_text() {
  local py="$1" id n i ev matcher args timeout cmd events="" e total k last_event
  for id in $WIRE_IDS; do
    n="$(file_wire_count "$id")"
    i=1
    while [ "$i" -le "$n" ]; do
      ev="$(file_wire "$id" "$i" event)"
      case " $events " in *" $ev "*) ;; *) events="$events $ev" ;; esac
      i=$((i + 1))
    done
  done
  last_event="${events##* }"
  for e in $events; do
    total=0
    for id in $WIRE_IDS; do
      n="$(file_wire_count "$id")"
      i=1
      while [ "$i" -le "$n" ]; do
        if [ "$(file_wire "$id" "$i" event)" = "$e" ]; then total=$((total + 1)); fi
        i=$((i + 1))
      done
    done
    say "  \"$e\": ["
    k=0
    for id in $WIRE_IDS; do
      n="$(file_wire_count "$id")"
      i=1
      while [ "$i" -le "$n" ]; do
        if [ "$(file_wire "$id" "$i" event)" = "$e" ]; then
          k=$((k + 1))
          matcher="$(file_wire "$id" "$i" matcher)"
          args="$(file_wire "$id" "$i" args)"
          timeout="$(file_wire "$id" "$i" timeout)"
          cmd="$(hook_command_text "$py" "$CLAUDE_DIR/$(file_dest "$id")" "$args")"
          say "    {\"matcher\": $(json_quote "$matcher"), \"hooks\": [{\"type\": \"command\","
          say "    \"command\": $(json_quote "$cmd"),"
          if [ "$k" -lt "$total" ]; then
            say "    \"timeout\": $timeout}]},"
          else
            say "    \"timeout\": $timeout}]}"
          fi
        fi
        i=$((i + 1))
      done
    done
    if [ "$e" = "$last_event" ]; then say "  ]"; else say "  ],"; fi
  done
}

# settings_merge_hooks: makes the hook entries in settings.json match WIRE_IDS
# (the hooks the user chose, or that the record holds): Conductor's own entries (the
# guarded command naming a script under conductor/hooks/; a hook of your own is never
# one, whatever it names) are kept where they are with the timeout you gave them, the
# missing ones are added in a group of their own, and each entry that is not wanted any
# more is removed and named. Nothing changes when python3 is not usable, the config
# path is unsafe, or the file is not valid JSON; the entries are printed instead and the
# record says hooks_wired is false.
settings_merge_hooks() {
  local spec rec out gone rc id n i ev matcher args timeout have
  [ "$HAVE_CLAUDE" = 1 ] || return 0
  have=0
  if [ -n "$PY" ] && manifest_exists "$CLAUDE_DIR"; then
    have="$(manifest_py "$CLAUDE_DIR" list-hooks 2>/dev/null | grep -c . || true)"
  fi
  if [ -z "$WIRE_IDS" ] && [ "${have:-0}" = 0 ]; then return 0; fi
  if [ -z "$PY" ]; then
    if [ -n "$WIRE_IDS" ]; then
      warn "hooks not wired: python3 is not usable here"
      HOOKS_PRINTED=1
    fi
    return 0
  fi
  if path_unsafe "$CLAUDE_DIR" || path_unsafe "$PY"; then
    if [ -n "$WIRE_IDS" ]; then
      warn "no hook wired: the path holds a quote, \$, backtick or backslash"
      info "the path is: $CLAUDE_DIR"
      manifest_set "$CLAUDE_DIR" hooks_wired false
    fi
    return 0
  fi
  if [ "${DRY_RUN:-0}" = "1" ]; then
    for id in $WIRE_IDS; do info "would wire $(component_title "$id") in settings.json"; done
    return 0
  fi
  py_prepare || return 1
  new_tmp spec spec || return 1
  new_tmp rec spec || return 1
  new_tmp out spec || return 1
  new_tmp gone spec || return 1
  : > "$spec"
  for id in $WIRE_IDS; do
    n="$(file_wire_count "$id")"
    i=1
    while [ "$i" -le "$n" ]; do
      ev="$(file_wire "$id" "$i" event)"
      matcher="$(file_wire "$id" "$i" matcher)"
      args="$(file_wire "$id" "$i" args)"
      timeout="$(file_wire "$id" "$i" timeout)"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$ev" "$matcher" "$CLAUDE_DIR/$(file_dest "$id")" "$args" "$timeout" >> "$spec"
      i=$((i + 1))
    done
  done
  manifest_begin "$CLAUDE_DIR" || return 1
  manifest_py "$CLAUDE_DIR" get hooks > "$rec" 2> /dev/null || : > "$rec"
  settings_py wire "$spec" "$CLAUDE_DIR" "$PY" "$rec" "$gone" > "$out"
  rc=$?
  case "$rc" in
    0)
      settings_apply "$out" || return 1
      settings_say_removed "$gone"
      if [ "${have:-0}" != 0 ]; then HOOKS_REFRESHED=1; fi
      ;;
    11) ;;
    3|4)
      note_wrapped warn 70 "" "settings.json was left as it is: it is not valid JSON, or it holds something Conductor will not rewrite."
      info "to wire the hooks yourself, add these under \"hooks\":"
      hook_entries_text "$PY"
      HOOKS_PRINTED=1
      manifest_set "$CLAUDE_DIR" hooks_wired false
      return 0
      ;;
    *) err "could not read settings.json"; return 1 ;;
  esac
  manifest_py "$CLAUDE_DIR" hooks-set "$rec" || return 1
  if [ -n "$WIRE_IDS" ]; then manifest_set "$CLAUDE_DIR" hooks_wired true; else manifest_set "$CLAUDE_DIR" hooks_wired false; fi
  for id in $WIRE_IDS; do
    case " $WIRED_SAID " in *" $id "*) continue ;; esac
    WIRED_SAID="$WIRED_SAID $id"
    ok "wired $(component_title "$id")"
  done
  return 0
}
