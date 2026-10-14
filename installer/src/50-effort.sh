# 50-effort.sh [L2]: the effort-gap text, the per-model pin offers, the printed
# snippets, --apply-effort-pins, the provider note and the Haiku note.
#
# Reads: CC_VERSION PROVIDER FIRST_PARTY (20-gates.sh), PY, HAVE_CLAUDE,
#        CLAUDE_DIR, DRY_RUN, OPT_APPLY_EFFORT_PINS, FLOOR_* (generated block).
# Calls (L1a): settings_set_key, settings_unset_key, manifest_get, manifest_set.
# Sets for the summary: PINS_WRITTEN, PINS_PRINTED, PINS_KEPT (space separated
# lists of pin names: opus, sonnet) and HAIKU_NOTE (1 line, may be empty).
#
# Rules: a pin is offered only on the first-party API, with a usable python3,
# at or above the model's floor. Anything else is printed, never written. The
# proposed value is always high, never max. The Haiku model setting is never
# written at any version.

PINS_WRITTEN=""
PINS_PRINTED=""
PINS_KEPT=""
HAIKU_NOTE=""
PIN_VALUE="high"

pin_label() { # $1=opus|sonnet
  case "$1" in opus) printf 'Opus 5.5' ;; sonnet) printf 'Sonnet 5.5' ;; esac
}

pin_model_id() {
  case "$1" in opus) printf 'claude-opus-5-5' ;; sonnet) printf 'claude-sonnet-5-5' ;; esac
}

pin_floor() {
  case "$1" in opus) printf '%s' "$FLOOR_OPUS_PIN" ;; sonnet) printf '%s' "$FLOOR_SONNET_PIN" ;; esac
}

# settings_read_json KEY...: prints the JSON text of the value at that key path
# in the user settings, or nothing when absent. Returns 2 without python3 and 3
# when settings.json does not parse. Python runs isolated (-I -B).
settings_read_json() {
  [ -n "$PY" ] || return 2
  [ -f "$CLAUDE_DIR/settings.json" ] || return 0
  "$PY" -I -B -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        text = fh.read()
    node = json.loads(text) if text.strip() else {}
except Exception:
    sys.exit(3)
for key in sys.argv[2:]:
    if not isinstance(node, dict) or key not in node:
        sys.exit(0)
    node = node[key]
print(json.dumps(node))
' "$CLAUDE_DIR/settings.json" "$@"
}

# pin_snippet KEY: prints the exact JSON to add by hand.
pin_snippet() {
  say "      {"
  say "        \"modelSettings\": {"
  say "          \"$(pin_model_id "$1")\": { \"effortLevel\": \"$PIN_VALUE\" }"
  say "        }"
  say "      }"
}

effort_gap_text() {
  info "Effort: Opus 5.5 and Sonnet 5.5 start at medium effort in Claude Code."
  info "A top-level effortLevel in your user settings does not reach them."
  info "The per-model pin under modelSettings does, so there is 1 pin per model."
  info "Higher effort can use more of your plan's usage."
  info "Each pin is written only with your yes, to this config only, after a backup."
  info "Pressing Enter answers no and changes nothing."
}

print_provider_aliases() { # $1=provider name, or unknown for every provider
  local p a m
  if [ "$1" = "unknown" ]; then
    note_wrapped info 72 "" "Your provider could not be identified${PROVIDER_NOTE:+: $PROVIDER_NOTE}. On some providers an alias resolves to an older model, so Conductor writes no model setting. Expected models per provider:"
    for p in bedrock vertex foundry anthropic-aws; do
      say "      $(provider_label "$p"):"
      say "        opus runs $(vendor_alias_model "$p" opus), sonnet runs $(vendor_alias_model "$p" sonnet), haiku runs $(vendor_alias_model "$p" haiku)"
    done
    return 0
  fi
  case "$1" in
    custom-base-url)
      note_wrapped info 72 "" "ANTHROPIC_BASE_URL is set to another address, so what each alias runs there cannot be known from here. Conductor writes no model setting and no effort pin."
      if [ "$BASE_URL_FROM" = "settings" ]; then
        note_wrapped say 72 "      " "The address is in the env block of your settings.json. If it is Anthropic's own, remove that line, then run: bash $(installer_name) --apply-effort-pins"
      else
        say "      To run the check without it, type:"
        say "      env -u ANTHROPIC_BASE_URL bash $(installer_name) --apply-effort-pins"
      fi
      return 0
      ;;
    host-managed)
      info "Your Claude Code uses $(provider_label "$1"). What each alias runs there cannot be known from here, so Conductor writes no model setting and no effort pin."
      return 0
      ;;
  esac
  info "Your Claude Code uses $(provider_label "$1"). Aliases can resolve to older models there, so Conductor writes no model setting and no effort pin."
  for a in opus sonnet haiku; do
    m="$(vendor_alias_model "$1" "$a")"
    if [ "$m" = "not stated" ]; then
      info "  alias $a: the vendor does not state what it runs on $(provider_label "$1")"
    else
      info "  alias $a runs $m on $(provider_label "$1")"
    fi
  done
}

# handle_pin KEY MODE REASON: MODE is offer (ask or apply) or print.
handle_pin() {
  local key="$1" mode="$2" why="$3" label path cur rc curshow
  label="$(pin_label "$key")"
  path="modelSettings.$(pin_model_id "$key").effortLevel"
  cur=""
  if [ "$mode" = offer ]; then
    cur="$(settings_read_json modelSettings "$(pin_model_id "$key")" effortLevel)"
    rc=$?
    if [ "$rc" = 3 ]; then
      mode=print
      why="your settings.json does not parse, so it was left untouched"
      cur=""
    fi
  fi
  case "$cur" in
    "") curshow="not set" ;;
    *) curshow="$(printf '%s' "$cur" | tr -d '"')" ;;
  esac
  if [ -n "$cur" ] && [ "$curshow" = "$PIN_VALUE" ]; then
    ok "$label effort pin: already $PIN_VALUE, nothing to change"
    return 0
  fi
  info "$label effort pin: current $curshow, proposed $PIN_VALUE."
  info "  Why: $label starts at medium in Claude Code; this key reaches it."
  info "  Higher effort can use more of your plan's usage."
  if [ "$mode" = print ]; then
    note_wrapped info 68 "  " "$label effort pin: printed, not written ($why). To set it by hand, merge this into settings.json:"
    pin_snippet "$key"
    PINS_PRINTED="$PINS_PRINTED $key"
    return 0
  fi
  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "  would offer: Set $label to $PIN_VALUE effort for this config?"
    return 0
  fi
  if [ "${OPT_APPLY_EFFORT_PINS:-0}" = "1" ]; then
    if [ -n "$cur" ]; then
      note_wrapped info 68 "  " "$label effort pin: kept your value $curshow. --apply-effort-pins never replaces a value you set; answer the prompt in a terminal to change it."
      PINS_KEPT="$PINS_KEPT $key"
      return 0
    fi
  elif no_prompt; then
    note_wrapped info 68 "  " "$label effort pin: printed, not written (no terminal to ask in; --apply-effort-pins writes it). To set it by hand, merge this into settings.json:"
    pin_snippet "$key"
    PINS_PRINTED="$PINS_PRINTED $key"
    return 0
  elif ! ask_yn "Set $label to $PIN_VALUE effort for this config?" n; then
    info "  $label effort pin: left unchanged."
    PINS_KEPT="$PINS_KEPT $key"
    return 0
  fi
  if settings_set_key "$path" "\"$PIN_VALUE\""; then
    ok "$label effort pin: wrote $PIN_VALUE (previous: $curshow)"
    PINS_WRITTEN="$PINS_WRITTEN $key"
  else
    note_wrapped warn 72 "" "$label effort pin: could not write it. To set it by hand, merge this into settings.json:"
    pin_snippet "$key"
    PINS_PRINTED="$PINS_PRINTED $key"
  fi
  return 0
}

# The Haiku note. The Haiku model setting is never written. Below the Haiku 5.5
# floor the installer says so; at or above it, a value an earlier Conductor
# install recorded is offered for removal.
haiku_note() {
  local recorded cur rc
  HAIKU_NOTE=""
  [ "$FIRST_PARTY" = 1 ] || return 0
  [ -n "$CC_VERSION" ] || return 0
  if ! version_ge "$CC_VERSION" "$FLOOR_HAIKU55"; then
    HAIKU_NOTE="needs Claude Code v$FLOOR_HAIKU55 or later; run: claude update"
    note_wrapped info 72 "" "Haiku 5.5 needs Claude Code v$FLOOR_HAIKU55 or later. Until then the haiku alias runs an older model. Run: claude update. Conductor does not write a Haiku model setting."
    return 0
  fi
  recorded="$(manifest_get "$CLAUDE_DIR" env_written 2>/dev/null)"
  case "$recorded" in *ANTHROPIC_DEFAULT_HAIKU_MODEL*) ;; *) return 0 ;; esac
  cur="$(settings_read_json env ANTHROPIC_DEFAULT_HAIKU_MODEL)"
  rc=$?
  if [ "$rc" = 0 ] && [ -z "$cur" ]; then return 0; fi
  note_wrapped info 72 "" "An earlier Conductor install set env.ANTHROPIC_DEFAULT_HAIKU_MODEL. From Claude Code v$FLOOR_HAIKU55 the haiku alias already runs Haiku 5.5, so that value is no longer needed."
  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "  would offer: Remove env.ANTHROPIC_DEFAULT_HAIKU_MODEL from your settings?"
    return 0
  fi
  if no_prompt || [ -z "$PY" ]; then
    info "  Not removed: there is no terminal to ask in, or python3 is not usable."
    say "      To remove it, delete the ANTHROPIC_DEFAULT_HAIKU_MODEL line"
    say "      from the env block of settings.json."
    return 0
  fi
  if ask_yn "Remove env.ANTHROPIC_DEFAULT_HAIKU_MODEL from your settings?" n; then
    if settings_unset_key "env.ANTHROPIC_DEFAULT_HAIKU_MODEL"; then
      manifest_set "$CLAUDE_DIR" env_written "[]"
      ok "Removed env.ANTHROPIC_DEFAULT_HAIKU_MODEL"
    else
      warn "Could not remove it. Delete the ANTHROPIC_DEFAULT_HAIKU_MODEL line"
      say "      from the env block of settings.json."
    fi
  else
    info "  Left in place."
  fi
  return 0
}

# gate_offer_pins: the version and provider gates for the pins and the Haiku note. Writes nothing without a yes (or
# --apply-effort-pins) and only when the gates pass.
gate_offer_pins() {
  local key mode why floor shown=0 need_update=0
  PINS_WRITTEN=""
  PINS_PRINTED=""
  PINS_KEPT=""
  HAIKU_NOTE=""
  [ "$HAVE_CLAUDE" = 1 ] || return 0
  section_heading claude
  if [ "$FIRST_PARTY" != 1 ] && [ "$PROVIDER" != "unknown" ]; then
    print_provider_aliases "$PROVIDER"
    return 0
  fi
  if [ -z "$CC_VERSION" ]; then
    info "Claude Code version: unknown. Effort pins are printed, not written."
  else
    info "Claude Code version: $CC_VERSION"
  fi
  for key in opus sonnet; do
    floor="$(pin_floor "$key")"
    if [ -n "$CC_VERSION" ] && ! version_ge "$CC_VERSION" "$floor"; then
      continue
    fi
    if [ "$shown" = 0 ]; then effort_gap_text; shown=1; fi
    if [ -z "$CC_VERSION" ]; then
      mode=print; why="Claude Code version unknown"
    elif [ "$FIRST_PARTY" != 1 ]; then
      mode=print; why="provider unknown: ${PROVIDER_NOTE:-could not be identified}"
    elif [ -z "$PY" ]; then
      mode=print; why="python3 is not usable: ${PY_REASON:-not found}"
    else
      mode=offer; why=""
    fi
    handle_pin "$key" "$mode" "$why"
  done
  for key in opus sonnet; do
    floor="$(pin_floor "$key")"
    if [ -n "$CC_VERSION" ] && ! version_ge "$CC_VERSION" "$floor"; then
      info "$(pin_label "$key") effort pin: not offered (Claude Code $CC_VERSION is below $floor)."
      need_update=1
    fi
  done
  if [ "$need_update" = 1 ]; then
    info "Update Claude Code to get the effort pins: claude update"
  fi
  if [ "$FIRST_PARTY" != 1 ]; then
    print_provider_aliases "$PROVIDER"
  fi
  haiku_note
  return 0
}
