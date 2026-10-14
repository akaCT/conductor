# 90-summary.sh [L1a]: the plan, the summary and --status.
#
# Fixed text stays under 80 characters a line. A path or a name taken from the
# system can make a line longer; that is not fixed text.

# hook_ids_of ROOT: the ids of the hooks the record says are wired, 1 per line.
hook_ids_of() {
  local root="$1"
  manifest_exists "$root" || return 0
  if [ -n "$PY" ]; then
    manifest_py "$root" list-hooks 2>/dev/null | cut -f1 | sort -u
  else
    sed -n 's/^    {"id": "\([A-Za-z0-9_]*\)".*/\1/p' "$(mf_path "$root")" | sort -u
  fi
}

# plain_name ID: the name of a component or hook as a person reads it
# ("checkpoint nudge hook"), not the id the files use.
plain_name() {
  local t
  t="$(component_title "$1")"
  printf '%s' "${t#the }"
}

# say_wrapped LABEL ID...: prints LABEL, then the plain names of the ids joined by
# commas and wrapped so that no line is longer than 78 characters.
say_wrapped() {
  local label="$1" pad line w first=1
  shift
  pad="$(printf '%*s' "${#label}" '')"
  line="$label"
  for w in "$@"; do
    w="$(plain_name "$w")"
    if [ "$first" = 1 ]; then
      line="$line$w"
      first=0
    elif [ $((${#line} + ${#w} + 2)) -gt 76 ]; then
      say "$line,"
      line="$pad$w"
    else
      line="$line, $w"
    fi
  done
  say "$line"
}

count_backups() { # ROOT: backups made in this run
  local d="$1/conductor/backups" n=0 f
  if [ -d "$d" ]; then
    for f in "$d"/*".bak.$STAMP"*; do
      if [ -e "$f" ]; then n=$((n + 1)); fi
    done
  fi
  printf '%s' "$n"
}

lines_of() { # TEXT: prints each non-empty line, indented
  local l
  while IFS= read -r l; do
    if [ -n "$l" ]; then say "      $l"; fi
  done <<EOF
$1
EOF
}

print_plan() {
  local kind
  banner
  say "  ${B}What this will do${RST}"
  if [ "$HAVE_CLAUDE" = 1 ]; then
    info "Claude Code folder: $CLAUDE_DIR"
  else
    warn "skipping Claude Code: $CLAUDE_DIR does not exist"
  fi
  if [ "$HAVE_CODEX" = 1 ]; then
    info "Codex folder: $CODEX_DIR"
  else
    warn "skipping Codex: $CODEX_DIR does not exist"
  fi
  if [ -n "$PY" ]; then
    info "python3: $PY"
  else
    warn "${PY_REASON:-python3 was not found on your PATH}"
    info "settings.json stays untouched; the full tier and hooks are skipped"
  fi
  if [ "$OS_KIND" != "darwin" ] && [ "$OS_KIND" != "linux" ]; then
    HOOK_NOTE_SAID=1
    warn "hooks are supported on macOS and Linux only; none are offered here"
  fi
  case "$EXISTING" in
    v030) kind="an upgrade from 0.3.0 (its files are recognized)" ;;
    v04) kind="a re-run: files that are already current stay as they are" ;;
    *) kind="a new install" ;;
  esac
  info "this is $kind"
  info "a file that is replaced is copied to conductor/backups first"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "dry run: each action is listed with 'would'; nothing is changed"
  elif no_prompt; then
    info "nothing will be asked: the safe answer is used every time"
  else
    info "you will be asked about the optional parts; Enter keeps the safe answer"
    if [ "$HAVE_CLAUDE" = 1 ]; then
      info "you may be asked about: optional parts, effort pins, judge seat, a model"
    fi
  fi
  return 0
}

# summary_hooks ROOT: the hooks wired line.
summary_hooks() {
  local ids
  ids="$(hook_ids_of "$1" | tr '\n' ' ')"
  if [ -n "$ids" ] && [ "$(manifest_get "$1" hooks_wired)" != "false" ]; then
    say_wrapped "  Hooks wired:   " $ids
    if [ "$HOOKS_REFRESHED" = 1 ]; then
      say "  Hook entries:  Conductor's own were refreshed; your timeouts, matchers and"
      say "                 order stay"
    fi
    say "  Kill switch:   hooks run unless CONDUCTOR_HOOKS=off is set in Claude Code's"
    say "                 environment"
  elif [ "$HOOKS_PRINTED" = 1 ]; then
    say "  Hooks wired:   none (the entries were printed for you to add)"
  else
    say "  Hooks wired:   none"
  fi
}

# say_settings_layout: what is kept of the layout of settings.json when it is written
# (3 things), and what may change (an object written on 1 line inside an indented file).
say_settings_layout() {
  say "  Settings file: your indentation, line endings and final line break were"
  say "                 kept. An object you wrote on 1 line may now span several."
}

# pin_names LIST: "Opus 5.5, Sonnet 5.5" for a list of pin names (opus, sonnet).
pin_names() {
  local out="" k
  for k in $1; do
    if [ -n "$out" ]; then out="$out, "; fi
    out="$out$(pin_label "$k")"
  done
  printf '%s' "$out"
}

# summary_settings: the settings keys this run wrote, printed or kept. The effort
# pins come from PINS_WRITTEN, PINS_PRINTED and PINS_KEPT (50-effort.sh); other
# keys, such as the default model, from KEYS_WRITTEN and KEYS_PRINTED.
summary_settings() {
  local w p k model_w=0 model_p=0
  w="$(pin_names "$PINS_WRITTEN")"
  p="$(pin_names "$PINS_PRINTED")"
  k="$(pin_names "$PINS_KEPT")"
  case "$KEYS_WRITTEN" in model|model$'\n'*|*$'\n'model$'\n'*) model_w=1 ;; esac
  case "$KEYS_PRINTED" in model|model$'\n'*|*$'\n'model$'\n'*) model_p=1 ;; esac
  if [ -z "$w$p$k" ] && [ "$model_w$model_p" = "00" ]; then
    say "  Settings keys: none changed"
    return 0
  fi
  say "  Settings keys:"
  if [ -n "$w" ]; then say "      effort pins written: $w"; fi
  if [ -n "$p" ]; then say "      effort pins printed for you to apply: $p"; fi
  if [ -n "$k" ]; then say "      effort pins left as you have them: $k"; fi
  if [ "$model_w" = 1 ]; then say "      default model: written"; fi
  if [ "$model_p" = 1 ]; then say "      default model: printed for you to apply"; fi
  return 0
}

# summary_local_claude_files: the Claude-only entries of the local data list. The state
# folder is listed when a hook is wired (the checkpoint and tracking hooks write there) or
# the folder exists.
summary_local_claude_files() {
  local cdir="$CLAUDE_DIR/conductor" ids
  ids="$(hook_ids_of "$CLAUDE_DIR")"
  if { [ -n "$ids" ] && [ "$(manifest_get "$CLAUDE_DIR" hooks_wired)" != "false" ]; } || [ -d "$cdir/state" ]; then
    say "      $cdir/state"
  fi
}

# say_not_installed: the files that were not written, each with the reason, under their
# own heading. They are not the user's files: a file the user changed stays under
# "Kept as yours".
say_not_installed() {
  local n l
  n="$(printf '%s' "$NOT_INSTALLED_LIST" | grep -c . || true)"
  if [ "${n:-0}" = 1 ]; then
    say "  Not installed (1 file):"
  else
    say "  Not installed ($n files):"
  fi
  while IFS= read -r l; do
    if [ -n "$l" ]; then note_wrapped say 68 "      " "$l"; fi
  done <<EOF
$NOT_INSTALLED_LIST
EOF
}

print_summary() {
  local root names n k first="" nb hook_nudge=0 ids launcher nrem
  say ""
  if [ "${DRY_RUN:-0}" = "1" ]; then
    say "  ${B}Dry run finished.${RST} Nothing was changed."
    say "  Run the same command without --dry-run to install."
    say ""
    return 0
  fi
  names="$SELECTED"
  for k in $SKIPPED_HELD; do
    case " $names " in *" $k "*) ;; *) names="$names $k" ;; esac
  done
  if [ -n "$NOT_INSTALLED_LIST" ]; then
    say "  ${YEL}${B}Incomplete.${RST} Conductor v$CONDUCTOR_VERSION is only partly installed."
  else
    say "  ${GRN}${B}Done.${RST} Conductor v$CONDUCTOR_VERSION is installed."
  fi
  say ""
  say "  Version:       $CONDUCTOR_VERSION"
  say_wrapped "  Components:    " $names
  nrem="$(printf '%s' "$REMOVED_LIST" | grep -c . || true)"
  if [ "${nrem:-0}" = 0 ]; then
    say "  Files:         $N_WRITTEN written, $N_UNCHANGED unchanged, $N_REPLACED replaced"
  else
    say "  Files:         $N_WRITTEN written, $N_UNCHANGED unchanged, $N_REPLACED replaced, $nrem removed"
  fi
  if [ -n "$NOT_INSTALLED_LIST" ]; then say_not_installed; fi
  if [ -n "$KEPT_LIST" ]; then
    say "  Kept as yours (not replaced):"
    lines_of "$KEPT_LIST"
  fi
  nb=0
  for root in "$CLAUDE_DIR" "$CODEX_DIR"; do
    if [ "$root" = "$CLAUDE_DIR" ] && [ "$HAVE_CLAUDE" = 0 ]; then continue; fi
    if [ "$root" = "$CODEX_DIR" ] && [ "$HAVE_CODEX" = 0 ]; then continue; fi
    nb=$((nb + $(count_backups "$root")))
  done
  if [ "$nb" = 0 ]; then
    say "  Backups:       none made (nothing was replaced)"
  else
    say "  Backups:       $nb made, in conductor/backups of each folder"
  fi
  if [ "$HAVE_CLAUDE" = 1 ]; then
    summary_hooks "$CLAUDE_DIR"
    ids="$(hook_ids_of "$CLAUDE_DIR")"
    case " $(printf '%s' "$ids" | tr '\n' ' ') " in *" hook_nudge "*) hook_nudge=1 ;; esac
  else
    say "  Hooks wired:   none (no Claude Code folder)"
  fi
  summary_settings
  if [ "${SETTINGS_WRITTEN:-0}" = 1 ]; then say_settings_layout; fi
  if [ -n "${HAIKU_NOTE:-}" ]; then say "  Haiku 5.5:     $HAIKU_NOTE"; fi
  if [ -n "${JUDGE_RUNG:-}" ]; then
    say "  Judge seat:    rung $JUDGE_RUNG"
    if [ -n "${JUDGE_REASON:-}" ]; then note_wrapped say 60 "                 " "$JUDGE_REASON"; fi
    if [ -n "${JUDGE_HINT:-}" ]; then note_wrapped say 60 "                 " "$JUDGE_HINT"; fi
  else
    say "  Judge seat:    not set"
  fi
  if [ "$HAVE_CLAUDE" = 1 ]; then launcher="$CLAUDE_DIR/$LAUNCHER_REL"; else launcher="$CODEX_DIR/$LAUNCHER_REL"; fi
  say "  Launcher:      $launcher"
  say "  To type just \"conductor\", add this line to your shell profile."
  say "  The installer wrote nothing there:"
  printf '      alias conductor=%q\n' "$launcher"
  say ""
  say "  Local files that can hold your data (all stay on this machine):"
  for root in "$CLAUDE_DIR" "$CODEX_DIR"; do
    if [ "$root" = "$CLAUDE_DIR" ] && [ "$HAVE_CLAUDE" = 0 ]; then continue; fi
    if [ "$root" = "$CODEX_DIR" ] && [ "$HAVE_CODEX" = 0 ]; then continue; fi
    say "      $root/conductor/backups"
    say "      $root/conductor/logs"
    say "      $root/conductor/report-*.txt"
    if [ "$root" = "$CLAUDE_DIR" ]; then summary_local_claude_files; fi
  done
  if [ "$hook_nudge" = 1 ] && [ -z "${CONDUCTOR_WINDOW:-}" ]; then
    say ""
    say "  The checkpoint nudge works without CONDUCTOR_WINDOW. Set it to your context"
    say "  window size in tokens (in the env block of settings.json) to add a note at"
    say "  50 percent of context use."
  fi
  say ""
  say "  Nothing is collected or sent. To report a problem, run:"
  say "      conductor report"
  say ""
  if [ -n "$NOT_INSTALLED_LIST" ]; then
    note_wrapped say 68 "  " "${B}Next:${RST} the install is incomplete. Fix what the reason says for each file under Not installed, then run the installer again: bash $(installer_name)"
  else
    say "  ${B}Next:${RST} open a new session; it reads the doctrine and conducts."
    if [ "$HAVE_CLAUDE" = 1 ]; then
      say "  For a big objective, type: ${CYN}/conductor <your objective>${RST}"
    fi
    if [ "$HAVE_CODEX" = 1 ]; then
      say "  On Codex, type: ${CYN}\$conductor <your objective>${RST}"
    fi
  fi
  say ""
  return 0
}

do_status() {
  local found=0 ids v m comps
  banner
  detect_existing
  py_prepare || true
  if [ "$HAVE_CLAUDE" = 1 ] && [ "$EXISTING_CLAUDE" = "v04" ]; then
    found=1
    v="$(manifest_get "$CLAUDE_DIR" version)"
    m="$(manifest_get "$CLAUDE_DIR" method)"
    comps="$(manifest_get "$CLAUDE_DIR" components | tr '\n' ' ')"
    ids="$(hook_ids_of "$CLAUDE_DIR" | tr '\n' ' ')"
    say "  ${B}Claude Code${RST} ($CLAUDE_DIR)"
    say "    Version:     ${v:-unknown}"
    say "    Method:      ${m:-unknown}"
    say_wrapped "    Components:  " $comps
    if [ -n "$ids" ]; then say_wrapped "    Hooks wired: " $ids; else say "    Hooks wired: none"; fi
  elif [ "$HAVE_CLAUDE" = 1 ] && [ "$EXISTING_CLAUDE" = "v030" ]; then
    found=1
    say "  ${B}Claude Code${RST} ($CLAUDE_DIR)"
    say "    Found a 0.3.0 install. Run the installer to upgrade it."
  fi
  if [ "$HAVE_CODEX" = 1 ] && [ "$EXISTING_CODEX" = "v04" ]; then
    found=1
    v="$(manifest_get "$CODEX_DIR" version)"
    m="$(manifest_get "$CODEX_DIR" method)"
    comps="$(manifest_get "$CODEX_DIR" components | tr '\n' ' ')"
    say "  ${B}Codex${RST} ($CODEX_DIR)"
    say "    Version:     ${v:-unknown}"
    say "    Method:      ${m:-unknown}"
    say_wrapped "    Components:  " $comps
  elif [ "$HAVE_CODEX" = 1 ] && [ "$EXISTING_CODEX" = "v030" ]; then
    found=1
    say "  ${B}Codex${RST} ($CODEX_DIR)"
    say "    Found a 0.3.0 install. Run the installer to upgrade it."
  fi
  if [ "$found" = 0 ]; then
    say "  No Conductor install found for Claude Code or Codex."
  fi
  say ""
  return 0
}
