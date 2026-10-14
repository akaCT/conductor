# 40-components.sh [L1a]: component selection and the by-name prompts, the core
# files, the full tier and the hooks.
# The component and file tables come from the generated block (05-payload.sh).
#
# Sets: SELECTED (space separated), DECLINED_INSTALLED (components the user said
# no to that the record held), SKIPPED_HELD (held components that could not be
# refreshed this run, kept in the record), WANT_MODEL (a default model the user
# asked for, or empty).

SELECTED=""
DECLINED_INSTALLED=""
NAMED_COMPONENTS=""
WANT_MODEL=""
HOOK_NOTE_SAID=0
SECTION_NOW=""
SECTION_SEEN=""

# section_heading HARNESS: prints the heading of the folder the lines that follow
# belong to (claude or codex), when it is not the folder the last heading named, so
# a Claude Code action never sits under the Codex heading or the other way round.
# The first heading of a folder names the install; a later one says "continued".
section_heading() {
  local dir label
  [ "${OPT_UNINSTALL:-0}" = 1 ] && return 0
  [ "$SECTION_NOW" = "$1" ] && return 0
  SECTION_NOW="$1"
  case "$1" in
    claude) dir="$CLAUDE_DIR"; label="Claude Code" ;;
    codex) dir="$CODEX_DIR"; label="Codex" ;;
    *) return 0 ;;
  esac
  say ""
  case " $SECTION_SEEN " in
    *" $1 "*) say "  $label, continued: ${B}$dir${RST}" ;;
    *)
      SECTION_SEEN="$SECTION_SEEN $1"
      if [ "${DRY_RUN:-0}" = "1" ]; then say "  $label: would install into ${B}$dir${RST}"; else say "  $label: installing into ${B}$dir${RST}"; fi
      ;;
  esac
}

# model_name_ok NAME: true for a default model Claude Code accepts as a name: an alias
# (opus, sonnet, haiku, fable, best, default) or a full model id that starts with claude-.
model_name_ok() {
  case "$1" in
    opus|sonnet|haiku|fable|best|default) return 0 ;;
    claude-?*)
      case "$1" in *[!A-Za-z0-9._-]*) return 1 ;; esac
      return 0
      ;;
  esac
  return 1
}

component_selected() { # $1=name -> returns 0 when selected
  case " ${SELECTED:-} " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# component_title ID: the name shown in a prompt.
component_title() {
  case "$1" in
    full) printf 'the full tier' ;;
    hook_pointer) printf 'the session-start pointer hook' ;;
    hook_nudge) printf 'the checkpoint nudge hook' ;;
    hook_usage_split) printf 'the usage-split check hook' ;;
    hook_project_home) printf 'the project-home check hook' ;;
    hook_contract) printf 'the contract check hook' ;;
    *) printf '%s' "$1" ;;
  esac
}

# recorded_components: the components the Claude install record holds.
recorded_components() {
  if [ "$HAVE_CLAUDE" = 1 ] && manifest_exists "$CLAUDE_DIR"; then
    manifest_get "$CLAUDE_DIR" components | tr '\n' ' '
  fi
}

# list_component_names: prints the names that exist, wrapped, on stderr.
list_component_names() {
  local line="" w
  err "The names that exist:"
  for w in $COMPONENT_IDS; do
    if [ $((${#line} + ${#w} + 1)) -gt 60 ]; then
      err "  $line"
      line="$w"
    else
      line="${line:+$line }$w"
    fi
  done
  if [ -n "$line" ]; then err "  $line"; fi
}

# parse_named_components: validates CONDUCTOR_COMPONENTS and --full into
# NAMED_COMPONENTS. A name that is not a component of this release (a feedback
# channel included) is a usage error, before anything is written. A hook named
# brings the components it requires.
parse_named_components() {
  local item r list="${CONDUCTOR_COMPONENTS:-}" rest
  NAMED_COMPONENTS=" "
  if [ "${OPT_FULL:-0}" = 1 ]; then NAMED_COMPONENTS="$NAMED_COMPONENTS""full "; fi
  rest="$list"
  while [ -n "$rest" ]; do
    item="${rest%%,*}"
    if [ "$item" = "$rest" ]; then rest=""; else rest="${rest#*,}"; fi
    item="$(printf '%s' "$item" | tr -d ' \t')"
    [ -n "$item" ] || continue
    case " $COMPONENT_IDS " in
      *" $item "*) ;;
      *)
        err "CONDUCTOR_COMPONENTS names '$(clean_name "$item")', which is not a component here."
        list_component_names
        usage_error "Nothing was changed."
        ;;
    esac
    case "$NAMED_COMPONENTS" in *" $item "*) ;; *) NAMED_COMPONENTS="$NAMED_COMPONENTS$item " ;; esac
    for r in $(component_requires "$item"); do
      case "$NAMED_COMPONENTS" in *" $r "*) ;; *) NAMED_COMPONENTS="$NAMED_COMPONENTS$r " ;; esac
    done
  done
}

# skipped_hold C: keeps a component the record holds in the record when this run
# cannot refresh it.
skipped_hold() {
  case " $SKIPPED_HELD " in *" $1 "*) ;; *) SKIPPED_HELD="$SKIPPED_HELD $1" ;; esac
}

# Sets SELECTED to a space-separated list of component names.
#   core is always installed.
#   No prompt (CONDUCTOR_YES, a dry run, no terminal) or --core: core, what the
#   install record holds, and what a flag or CONDUCTOR_COMPONENTS names. Nothing
#   new is enabled by default.
#   A terminal: 1 prompt per optional item that is not named, default no, or
#   default yes for an item the record holds. Enter keeps an installed item; an
#   explicit no removes it (DECLINED_INSTALLED).
select_components() {
  local c rec held named r reqok needs kind want m tries
  SELECTED="core"
  DECLINED_INSTALLED=""
  SKIPPED_HELD=""
  WANT_MODEL=""
  parse_named_components
  rec=" $(recorded_components) "
  for c in $COMPONENT_IDS; do
    [ "$c" = "core" ] && continue
    held=0
    case "$rec" in *" $c "*) held=1 ;; esac
    named=0
    case "$NAMED_COMPONENTS" in *" $c "*) named=1 ;; esac
    kind="$(component_kind "$c")"
    if [ "$HAVE_CLAUDE" = 0 ]; then
      if [ "$named" = 1 ]; then warn "skipped $c: it is for Claude Code and there is no Claude Code folder"; fi
      continue
    fi
    # python3 is needed for the full tier and the hooks
    needs="$(component_needs "$c")"
    case " $needs " in
      *" python3 "*)
        if [ -z "$PY" ]; then
          if [ "$held" = 1 ] || [ "$named" = 1 ]; then
            warn "skipped $c: it needs python3"
            if [ "$held" = 1 ]; then skipped_hold "$c"; fi
          fi
          continue
        fi
        ;;
    esac
    # hooks run on macOS and Linux only, and only with a path that quotes safely
    if [ "$kind" = "hook" ]; then
      if ! hooks_os_ok; then
        if [ "$HOOK_NOTE_SAID" = 0 ]; then
          HOOK_NOTE_SAID=1
          warn "hooks are supported on macOS and Linux only; none are offered here"
        fi
        if [ "$held" = 1 ]; then skipped_hold "$c"; fi
        continue
      fi
      if path_unsafe "$CLAUDE_DIR" || path_unsafe "$PY"; then
        if [ "$HOOK_NOTE_SAID" = 0 ]; then
          HOOK_NOTE_SAID=1
          warn "no hook is offered: the path holds a quote, \$, backtick or backslash"
          info "the path is: $CLAUDE_DIR"
        fi
        if [ "$held" = 1 ]; then skipped_hold "$c"; fi
        continue
      fi
    fi
    # a component that requires another one follows it
    reqok=1
    for r in $(component_requires "$c"); do
      component_selected "$r" || reqok=0
    done
    if [ "$reqok" = 0 ]; then
      for r in $(component_requires "$c"); do
        case " $SKIPPED_HELD " in *" $r "*) if [ "$held" = 1 ]; then skipped_hold "$c"; fi ;; esac
      done
      if [ "$held" = 1 ]; then
        case " $SKIPPED_HELD " in *" $c "*) ;; *) DECLINED_INSTALLED="$DECLINED_INSTALLED $c" ;; esac
      fi
      continue
    fi
    want=0
    if [ "${OPT_CORE:-0}" = 1 ]; then
      want="$held"
    elif no_prompt; then
      if [ "$held" = 1 ] || [ "$named" = 1 ]; then want=1; fi
    elif [ "$named" = 1 ]; then
      want=1
    else
      say ""
      say "  ${B}$(component_title "$c")${RST}"
      say "    $(component_describe "$c")"
      if [ "$held" = 1 ]; then
        if ask_yn "Keep $(component_title "$c")?" y; then want=1; fi
      else
        if ask_yn "Add $(component_title "$c")?" n; then want=1; fi
      fi
    fi
    if [ "$want" = 1 ]; then
      SELECTED="$SELECTED $c"
    elif [ "$held" = 1 ]; then
      DECLINED_INSTALLED="$DECLINED_INSTALLED $c"
    fi
  done
  if ! no_prompt && [ "${OPT_CORE:-0}" = 0 ] && [ -n "$PY" ] && [ "$HAVE_CLAUDE" = 1 ]; then
    say ""
    say "  ${B}A default model${RST}"
    say "    Claude Code picks a model for new sessions. A yes writes the \"model\" key"
    say "    in settings.json (after a backup), so every new session starts on it."
    say "    Leave it unset if you switch models yourself."
    if ask_yn "Set a default model in settings.json?" n; then
      say "    Give opus, sonnet, haiku, fable, best or default, or a full model id that"
      say "    starts with claude-. Press Enter to leave the setting as it is."
      tries=0
      while [ "$tries" -lt 2 ]; do
        tries=$((tries + 1))
        m="$(ask_str "Model name" "")"
        if [ -z "$m" ]; then
          info "no default model set; your setting stays as it is"
          break
        fi
        if model_name_ok "$m"; then
          WANT_MODEL="$m"
          break
        fi
        if [ "$tries" -lt 2 ]; then
          warn "that is not a model name Claude Code takes; try again"
        else
          warn "that is not a model name; no default model is set"
        fi
      done
    fi
  fi
  return 0
}

# install_launcher_files ROOT: the launcher and the files it reads, into ROOT.
install_launcher_files() {
  local root="$1" id d
  for id in $FILE_IDS; do
    [ "$(file_harness "$id")" = "claude" ] || continue
    [ "$(file_component "$id")" = "core" ] || continue
    d="$(file_dest "$id")"
    case "$d" in
      conductor/bin/conductor|conductor/lib/*|conductor/feedback-codes.txt) ;;
      *) continue ;;
    esac
    install_payload_file_in "$id" "$root" "$root" || return 1
  done
}

# Installs the files of the core component into each root that exists. Judge
# files (a select entry) belong to install_judge, the doctrine block to
# write_doctrine_block and the Codex agents and skill to install_codex.
install_core_files() {
  local id
  manifest_batch_begin
  if [ "$HAVE_CLAUDE" = 1 ]; then
    section_heading claude
    manifest_begin "$CLAUDE_DIR" || return 1
    for id in $FILE_IDS; do
      [ "$(file_harness "$id")" = "claude" ] || continue
      [ "$(file_component "$id")" = "core" ] || continue
      [ "$(file_policy "$id")" = "doctrine-block" ] && continue
      [ -n "$(file_select "$id")" ] && continue
      install_payload_file "$id" || return 1
    done
  fi
  if [ "$HAVE_CODEX" = 1 ]; then
    section_heading codex
    manifest_begin "$CODEX_DIR" || return 1
    install_launcher_files "$CODEX_DIR" || return 1
  fi
  manifest_batch_end || return 1
  if [ "$HAVE_CLAUDE" = 1 ] && [ -n "$WANT_MODEL" ]; then
    settings_set_key model "$(json_quote "$WANT_MODEL")" || true
  fi
  return 0
}

# Installs the full tier and the hooks the user chose, removes what the user
# declined, and makes settings.json match.
install_full_tier() {
  local c id
  [ "$HAVE_CLAUDE" = 1 ] || return 0
  section_heading claude
  WIRE_IDS=""
  manifest_batch_begin
  for c in $DECLINED_INSTALLED; do
    info "removing $(component_title "$c")"
    for id in $FILE_IDS; do
      [ "$(file_harness "$id")" = "claude" ] || continue
      [ "$(file_component "$id")" = "$c" ] || continue
      remove_payload_file "$id"
    done
  done
  for c in $SELECTED; do
    [ "$c" = "core" ] && continue
    for id in $FILE_IDS; do
      [ "$(file_harness "$id")" = "claude" ] || continue
      [ "$(file_component "$id")" = "$c" ] || continue
      install_payload_file "$id" || { manifest_batch_end; return 1; }
      if [ "$(file_wire_count "$id")" != "0" ]; then
        # a hook is wired only when its script is there and can be read
        if [ "${DRY_RUN:-0}" != "1" ] && { [ ! -f "$CLAUDE_DIR/$(file_dest "$id")" ] || [ ! -r "$CLAUDE_DIR/$(file_dest "$id")" ]; }; then
          warn "did not wire $(component_title "$id"): $(file_dest "$id") is not there or cannot be read"
        else
          WIRE_IDS="$WIRE_IDS $id"
        fi
      fi
    done
  done
  manifest_batch_end || return 1
  settings_merge_hooks
}

# shipped_dests: 1 line per file this release ships, harness|root|dest, with
# the reference copy of a file and the launcher set (which also goes into the
# Codex root) as lines of their own. Built once per run so the loop below does
# not look every file up again for every record entry.
shipped_dests() {
  local id h r d a
  for id in $FILE_IDS; do
    h="$(file_harness "$id")"
    r="$(file_root "$id")"
    d="$(file_dest "$id")"
    a="$(file_also "$id")"
    printf '%s|%s|%s\n' "$h" "$r" "$d"
    if [ -n "$a" ]; then printf '%s|%s|%s\n' "$h" "$r" "$a"; fi
    if [ "$h" = "claude" ]; then
      case "$d" in
        conductor/bin/conductor|conductor/lib/*|conductor/feedback-codes.txt) printf 'codex||%s\n' "$d" ;;
      esac
    fi
  done
}

# remove_dropped_files: a file the install record lists that this release no
# longer ships. An unmodified one is removed with its record entry; one the user
# changed is kept, named, and dropped from the record (REQ-UPD-002.8).
remove_dropped_files() {
  local root lines line dest rkey sha policy id shipped harness rest tab
  tab="$(printf '\t')"
  shipped="$(shipped_dests)"
  for root in "$CLAUDE_DIR" "$CODEX_DIR"; do
    if [ "$root" = "$CLAUDE_DIR" ] && [ "$HAVE_CLAUDE" = 0 ]; then continue; fi
    if [ "$root" = "$CODEX_DIR" ] && [ "$HAVE_CODEX" = 0 ]; then continue; fi
    manifest_exists "$root" || continue
    lines="$(manifest_files "$root")"
    [ -n "$lines" ] || continue
    harness="$(harness_of_mroot "$root")"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      dest="${line%%$tab*}"
      rest="${line#*$tab}"
      rkey="${rest%%$tab*}"
      rest="${rest#*$tab}"
      sha="${rest%%$tab*}"
      rest="${rest#*$tab}"
      policy="${rest%%$tab*}"
      rest="${rest#*$tab}"
      rest="${rest#*$tab}"
      id="${rest%%$tab*}"
      case "
$shipped
" in
        *"
$harness|$rkey|$dest
"*) ;;
        *) section_heading "$harness"; remove_entry "$root" "$dest" "$rkey" "$id" "$sha" "$policy" ;;
      esac
    done <<EOF
$lines
EOF
  done
  return 0
}
