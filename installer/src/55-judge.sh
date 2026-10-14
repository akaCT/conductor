# 55-judge.sh [L2]: the judge file and the plain statement of its rung.
#
# resolve_judge_rung (20-gates.sh) has already set JUDGE_RUNG (1 or 3) and
# JUDGE_REASON. The 2 judge entries in components.json share the dest
# agents/judge.md and carry the select key judge_rung; this writes the one whose
# value equals JUDGE_RUNG, through install_payload_file.

install_judge() {
  local id
  [ "$HAVE_CLAUDE" = 1 ] || return 0
  case "$JUDGE_RUNG" in
    1) id="agent_judge_r1" ;;
    3) id="agent_judge_r3" ;;
    *) return 0 ;;
  esac
  section_heading claude
  install_payload_file "$id" || return 1
  if [ "$JUDGE_RUNG" = 1 ]; then
    info "You are on judge rung 1."
    note_wrapped say 70 "      " "The judge runs on Fable 5.1, a different model family from the builders, and holds Read, Grep and Glob only."
    JUDGE_HINT="to use rung 3 instead: bash $(installer_name) --judge-rung=3"
  else
    info "You are on judge rung 3."
    note_wrapped say 70 "      " "The judge runs on Sonnet 5.5 at xhigh in a fresh context, and holds Read, Grep and Glob only. A same-lab judge is a weaker second view than a different model family."
    if [ -n "$JUDGE_REASON" ]; then note_wrapped say 74 "      " "Why: $JUDGE_REASON."; fi
    note_wrapped say 70 "      " "To change the rung: bash $(installer_name) --judge-rung=1 (needs the Anthropic API and Claude Code $FLOOR_FABLE or later)."
    JUDGE_HINT="to use rung 1 instead: bash $(installer_name) --judge-rung=1"
  fi
  if [ "${DRY_RUN:-0}" != "1" ]; then
    manifest_set "$CLAUDE_DIR" judge_rung "$JUDGE_RUNG"
  fi
  return 0
}
