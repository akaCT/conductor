# 80-uninstall.sh [L1a]: manifest-driven uninstall.
#
# Acts only on regular files inside the config roots, never through a symbolic
# link, whose hash matches a recorded or released hash. A file the user changed,
# a create-only file, a path outside the roots, a settings key outside the set
# Conductor writes, and a value outside its allowed set are named and left alone.

# pin_allowed KEY JSONVALUE: true for a settings key Conductor may write, with a
# value from the set it may write (PRD section 8.1).
pin_allowed() {
  local v
  case "$1" in
    modelSettings.claude-opus-5-5.effortLevel|modelSettings.claude-sonnet-5-5.effortLevel)
      case "$2" in '"low"'|'"medium"'|'"high"'|'"xhigh"') return 0 ;; esac
      ;;
    env.ANTHROPIC_DEFAULT_HAIKU_MODEL)
      [ "$2" = '"claude-haiku-5-5"' ] && return 0
      ;;
    model)
      case "$2" in
        '"'*'"')
          v="${2#\"}"
          v="${v%\"}"
          case "$v" in ""|*[!A-Za-z0-9._-]*) ;; *) return 0 ;; esac
          ;;
      esac
      ;;
  esac
  return 1
}

# uninstall_pins: puts back the settings keys Conductor changed, each to the
# value recorded before its first change (or removes the key if it was absent).
# A key the user changed since is left alone.
uninstall_pins() {
  local lines line key val prev present cur rc tmp
  lines="$(manifest_py "$CLAUDE_DIR" list-pins 2>/dev/null)"
  [ -n "$lines" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="$(printf '%s' "$line" | cut -f1)"
    val="$(printf '%s' "$line" | cut -f2)"
    prev="$(printf '%s' "$line" | cut -f3)"
    present="$(printf '%s' "$line" | cut -f4)"
    if ! pin_allowed "$key" "$val" || { [ "$present" = 1 ] && ! pin_allowed "$key" "$prev"; }; then
      warn "left alone: setting $(clean_name "$key")"
      info "it is outside what Conductor writes"
      continue
    fi
    cur="$(settings_py get "$key")"
    rc=$?
    if [ "$rc" = 12 ]; then
      [ "${DRY_RUN:-0}" = "1" ] || manifest_py "$CLAUDE_DIR" pin-forget "$key" || true
      continue
    fi
    if [ "$rc" != 0 ]; then
      warn "left alone: setting $(clean_name "$key")"
      info "settings.json cannot be read as JSON"
      continue
    fi
    if [ "$cur" != "$val" ]; then
      warn "left alone: setting $(clean_name "$key")"
      info "you changed it since the install"
      [ "${DRY_RUN:-0}" = "1" ] || manifest_py "$CLAUDE_DIR" pin-forget "$key" || true
      continue
    fi
    if [ "${DRY_RUN:-0}" = "1" ]; then
      if [ "$present" = 1 ]; then info "would restore setting $key"; else info "would remove setting $key"; fi
      continue
    fi
    new_tmp tmp settings || return 1
    if [ "$present" = 1 ]; then settings_py set "$key" "$prev" > "$tmp"; else settings_py unset "$key" > "$tmp"; fi
    rc=$?
    if [ "$rc" = 0 ]; then
      settings_apply "$tmp" || return 1
    elif [ "$rc" != 11 ]; then
      warn "left alone: setting $(clean_name "$key")"
      info "settings.json could not be changed"
      continue
    fi
    manifest_py "$CLAUDE_DIR" pin-forget "$key" || true
    if [ "$present" = 1 ]; then ok "restored setting $key"; else ok "removed setting $key"; fi
  done <<EOF
$lines
EOF
}

# uninstall_hooks: removes Conductor's hook entries from settings.json.
uninstall_hooks() {
  local rec out gone rc n
  n="$(manifest_py "$CLAUDE_DIR" list-hooks 2>/dev/null | grep -c . || true)"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    if [ "${n:-0}" != 0 ]; then info "would remove $n hook entries from settings.json"; fi
    return 0
  fi
  new_tmp rec spec || return 1
  new_tmp out spec || return 1
  new_tmp gone spec || return 1
  manifest_py "$CLAUDE_DIR" get hooks > "$rec" 2>/dev/null || : > "$rec"
  settings_py unwire "$CLAUDE_DIR" "$rec" "$gone" > "$out"
  rc=$?
  case "$rc" in
    0) settings_apply "$out" || return 1; settings_say_removed "$gone"; ok "removed the hook entries from settings.json" ;;
    11) ;;
    *)
      warn "settings.json cannot be read as JSON; its hook entries were left as they are"
      info "remove the entries whose command holds $CLAUDE_DIR/conductor/hooks/"
      ;;
  esac
}

# uninstall_settings_file: removes settings.json when Conductor created it and
# nothing else is in it.
uninstall_settings_file() {
  local s
  s="$(settings_path)"
  [ "$(manifest_get "$CLAUDE_DIR" settings_created)" = "true" ] || return 0
  [ -f "$s" ] && [ ! -L "$s" ] || return 0
  if settings_py empty >/dev/null 2>&1; then
    if [ "${DRY_RUN:-0}" = "1" ]; then info "would remove settings.json (Conductor created it)"; return 0; fi
    rm -f "$s" && ok "removed settings.json (Conductor created it and nothing else is in it)"
  fi
}

# uninstall_record_files ROOT: removes every file the record lists.
uninstall_record_files() {
  local root="$1" lines line dest rkey sha policy comp id
  lines="$(manifest_files "$root")"
  [ -n "$lines" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    dest="$(printf '%s' "$line" | cut -f1)"
    rkey="$(printf '%s' "$line" | cut -f2)"
    sha="$(printf '%s' "$line" | cut -f3)"
    policy="$(printf '%s' "$line" | cut -f4)"
    comp="$(printf '%s' "$line" | cut -f5)"
    id="$(printf '%s' "$line" | cut -f6)"
    remove_entry "$root" "$dest" "$rkey" "$id" "$sha" "$policy"
  done <<EOF
$lines
EOF
}

# uninstall_leftovers ROOT: names what stays and tidies up the record.
uninstall_leftovers() {
  local root="$1" f
  if [ -d "$root/conductor/logs" ]; then info "kept $root/conductor/logs (hook traces)"; fi
  if [ -d "$root/conductor/state" ]; then info "kept $root/conductor/state (hook counters, checkpoint record)"; fi
  for f in "$root"/conductor/report-*.txt; do
    if [ -f "$f" ]; then info "kept $f (a bug report you made)"; fi
  done
  if [ "${DRY_RUN:-0}" = "1" ]; then return 0; fi
  rm -f "$root"/conductor/.manifest-tmp.* "$root"/conductor/.conductor-tmp.* 2>/dev/null || true
  rmdir "$root/conductor" 2>/dev/null || true
}

# legacy_remove ROOTDIR HARNESS PATH: removes 1 file a 0.3.0 install wrote, under
# the same limits: inside the folder, no link, a regular file, a released hash.
legacy_remove() {
  local rdir="$1" harness="$2" path="$3" rel cur label
  case "$path" in
    "$rdir"/*) rel="${path#"$rdir"/}" ;;
    *) warn "left alone: $(clean_name "$path") (outside the Conductor folders)"; note_left "$(clean_name "$path")"; return 0 ;;
  esac
  label="$(clean_name "$rel")"
  if ! safe_rel "$rel"; then warn "left alone: $label (it points outside the folder)"; note_left "$label"; return 0; fi
  [ -e "$path" ] || [ -L "$path" ] || return 0
  if via_link "$rdir" "$rel"; then warn "left alone: $label (a symbolic link)"; note_left "$label"; return 0; fi
  if [ ! -f "$path" ]; then warn "left alone: $label (not a regular file)"; note_left "$label"; return 0; fi
  cur="$(sha256_of "$path")" || { warn "left alone: $label (it cannot be read; check its permissions)"; note_left "$label"; return 0; }
  if ! prior_hash_has "$harness" "$rel" "$cur"; then
    warn "kept $label (you changed it)"
    note_kept "$label"
    return 0
  fi
  if [ "${DRY_RUN:-0}" = "1" ]; then info "would remove $label"; return 0; fi
  if rm -f "$path"; then
    ok "removed $label"
    REMOVED_LIST="${REMOVED_LIST}$label"$'\n'
    prune_empty_dirs "$rdir" "$rel"
  fi
}

# uninstall_legacy ROOT HARNESS: a 0.3.0 install, as 0.3.0's own uninstall
# treated it, under the limits above.
uninstall_legacy() {
  local root="$1" harness="$2" mf line rdir known d
  if [ "$harness" = "claude" ]; then
    mf="$root/skills/conductor/.install-manifest"
  else
    mf="$root/.conductor-manifest"
  fi
  info "found a 0.3.0 install in $root"
  if [ -f "$mf" ]; then
    while IFS= read -r line; do
      case "$line" in
        ""|\#*|CLAUDE_MD_PATCHED|CODEX_AGENTS_MD_PATCHED) continue ;;
        SETTINGS_MODEL_SET:*)
          warn "the 0.3.0 install set your default model to '$(clean_name "${line#SETTINGS_MODEL_SET:}")'; it is yours to keep"
          continue
          ;;
      esac
      case "$line" in
        "$AGENTS_SKILLS_DIR"/*) legacy_remove "$AGENTS_SKILLS_DIR" "$harness" "$line" ;;
        *) legacy_remove "$root" "$harness" "$line" ;;
      esac
    done < "$mf"
  else
    # no list: the files 0.3.0 wrote, by name, when they still match
    known="$(emit_prior_hashes | awk -v h="$harness" '$2 == "0.3.0" { n = split($3, a, ":"); if (a[1] == h) print substr($3, length(h) + 2) }')"
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      case "$d" in
        CLAUDE.md|AGENTS.md) continue ;;
        skills/conductor/*) if [ "$harness" = "codex" ]; then legacy_remove "$AGENTS_SKILLS_DIR" "$harness" "$AGENTS_SKILLS_DIR/$d"; continue; fi ;;
      esac
      legacy_remove "$root" "$harness" "$root/$d"
    done <<EOF
$known
EOF
  fi
  if [ "${DRY_RUN:-0}" != "1" ]; then
    rm -f "$mf"
    if [ "$harness" = "claude" ]; then prune_empty_dirs "$root" "skills/conductor/.install-manifest"; fi
  fi
}

# uninstall_root ROOT HARNESS STATE: 1 root, whichever install it holds.
uninstall_root() {
  local root="$1" harness="$2" state="$3" pins hooks lm
  say ""
  if [ "${DRY_RUN:-0}" = "1" ]; then say "  Would uninstall from ${B}$root${RST}"; else say "  Uninstalling from ${B}$root${RST}"; fi
  if [ "$state" = "v030" ]; then
    uninstall_legacy "$root" "$harness"
    strip_doctrine_block "$harness"
    return 0
  fi
  if [ -n "$PY" ]; then
    if ! manifest_py "$root" check 2>/dev/null; then
      err "the install record in $root cannot be read; nothing was changed there"
      err "Run the installer again: it starts a new record (and keeps a backup of this one)."
      err "Then run the uninstall again."
      return 1
    fi
  else
    pins="$(grep -c '^  "pins": \[$' "$(mf_path "$root")" 2>/dev/null || true)"
    hooks="$(grep -c '^  "hooks": \[$' "$(mf_path "$root")" 2>/dev/null || true)"
    if [ "${pins:-0}" != 0 ] || [ "${hooks:-0}" != 0 ]; then
      err "python3 is needed to undo that: the install changed settings.json"
      err "${PY_REASON:-python3 was not found on your PATH}"
      err "nothing was changed in $root"
      return 1
    fi
  fi
  if [ "$harness" = "claude" ] && [ -n "$PY" ]; then
    uninstall_pins
    uninstall_hooks
  fi
  if [ "$harness" = "claude" ]; then
    lm="$(manifest_get "$root" legacy_030 | sed -n 's/.*"settings_model_set": "\([A-Za-z0-9._-]*\)".*/\1/p')"
    if [ -n "$lm" ]; then
      warn "the 0.3.0 install set your default model to '$lm'; it is yours to keep"
    fi
  fi
  uninstall_record_files "$root"
  if [ "$harness" = "claude" ] && [ -n "$PY" ]; then settings_prune_dangling; fi
  strip_doctrine_block "$harness"
  if [ "$harness" = "claude" ] && [ -n "$PY" ]; then uninstall_settings_file; fi
  if [ "${DRY_RUN:-0}" != "1" ]; then rm -f "$(mf_path "$root")"; fi
  uninstall_leftovers "$root"
  return 0
}

# offer_backup_removal ROOT KIND: the backups of a Claude Code folder may hold copies of
# settings.json, which can hold secrets; those of a Codex folder hold copies of the Codex
# files Conductor replaced (AGENTS.md among them), which can hold your own notes. They stay
# unless the user says yes.
offer_backup_removal() {
  local dir="$1/conductor/backups"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  say ""
  info "backups from the installer are in $dir"
  if [ "${2:-claude}" = "codex" ]; then
    info "they hold copies of Codex files Conductor replaced, such as AGENTS.md"
  else
    info "they can hold copies of your settings.json, which may contain secrets"
  fi
  if [ "${DRY_RUN:-0}" = "1" ]; then info "would ask whether to delete them"; return 0; fi
  if ask_yn "Delete that backups folder?" n; then
    rm -rf "$dir" && ok "deleted $dir"
    rmdir "$1/conductor" 2>/dev/null || true
  else
    info "kept $dir"
  fi
}

do_uninstall() {
  local did=0 others c claude_removed=0 shared failed=0 agents_made=""
  banner
  py_prepare || true
  detect_existing
  if [ "$HAVE_CLAUDE" = 1 ] && [ "$EXISTING_CLAUDE" != "none" ]; then
    if uninstall_root "$CLAUDE_DIR" claude "$EXISTING_CLAUDE"; then claude_removed=1; else failed=1; fi
    did=1
  fi
  if [ "$HAVE_CODEX" = 1 ] && [ "$EXISTING_CODEX" != "none" ]; then
    others=""
    if [ "$EXISTING_CODEX" = "v04" ]; then
      shared="$(manifest_get "$CODEX_DIR" shared_with)"
      while IFS= read -r c; do
        [ -n "$c" ] || continue
        if [ "$HAVE_CLAUDE" = 1 ] && [ "$c" = "$CLAUDE_DIR" ] && [ "$EXISTING_CLAUDE" != "none" ]; then continue; fi
        others="$others $c"
      done <<EOF
$shared
EOF
    fi
    if [ -n "$others" ]; then
      say ""
      info "the Codex files in $CODEX_DIR stay: another install still uses them:$(clean_name "$others")"
      if [ "$HAVE_CLAUDE" = 1 ] && [ "$claude_removed" = 1 ]; then manifest_unshare "$CODEX_DIR" "$CLAUDE_DIR"; fi
    else
      agents_made="$(manifest_get "$CODEX_DIR" agents_skills_existed)"
      if uninstall_root "$CODEX_DIR" codex "$EXISTING_CODEX"; then uninstall_codex_extra "$agents_made"; else failed=1; fi
    fi
    did=1
  fi
  if [ "$did" = 0 ]; then
    warn "No Conductor install found for Claude Code or Codex."
    say ""
    return 0
  fi
  if [ "$HAVE_CLAUDE" = 1 ]; then offer_backup_removal "$CLAUDE_DIR" claude; fi
  if [ "$HAVE_CODEX" = 1 ]; then offer_backup_removal "$CODEX_DIR" codex; fi
  say ""
  if [ "${DRY_RUN:-0}" = "1" ]; then
    say "  ${B}Dry run finished.${RST} Nothing was changed."
  elif [ "$failed" = 1 ]; then
    say "  ${B}Not everything was removed.${RST} Read the lines above."
  elif [ -n "$LEFT_LIST" ]; then
    say "  ${B}Conductor removed, except the files listed below.${RST} Files you changed"
    say "  or created are kept."
    say "  ${DIM}Restart your sessions to drop the doctrine from context.${RST}"
  else
    say "  ${GRN}${B}Conductor removed.${RST} Files you changed or created are kept."
    say "  ${DIM}Restart your sessions to drop the doctrine from context.${RST}"
  fi
  if [ "${SETTINGS_WRITTEN:-0}" = 1 ] && [ -f "$(settings_path)" ]; then
    say ""
    say_settings_layout
  fi
  if [ -n "$LEFT_LIST" ]; then
    say ""
    say "  Left alone (a link, or not a plain file; delete them yourself):"
    printf '%s' "$LEFT_LIST" | while IFS= read -r c; do [ -n "$c" ] && say "    $c"; done
  fi
  if [ -n "$KEPT_LIST" ]; then
    say ""
    say "  Kept:"
    printf '%s' "$KEPT_LIST" | while IFS= read -r c; do [ -n "$c" ] && say "    $c"; done
  fi
  say ""
  return "$failed"
}
