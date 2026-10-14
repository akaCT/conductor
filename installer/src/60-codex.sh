# 60-codex.sh [L2]: Codex install (doctrine block, agents, skill, override
# warning). Codex gets the doctrine block, the 4 generated agent files and the
# $conductor skill. It gets no hooks and no settings change, and no effort key
# unless components.json lists one.
#
# Reads: HAVE_CODEX, CODEX_DIR. Calls (L1a): write_doctrine_block, manifest_begin,
# install_payload_file.

# record_agents_root: writes into the Codex install record whether the Codex skills
# folder (AGENTS_SKILLS_DIR) was there before Conductor wrote into it, so that the
# uninstall removes it only when Conductor made it. The first answer is kept on a re-run.
record_agents_root() {
  local seen
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  seen="$(manifest_get "$CODEX_DIR" agents_skills_existed)"
  [ -z "$seen" ] || return 0
  if [ -d "$AGENTS_SKILLS_DIR" ]; then
    manifest_set "$CODEX_DIR" agents_skills_existed true
  else
    manifest_set "$CODEX_DIR" agents_skills_existed false
  fi
}

install_codex() {
  local override id
  if [ "$HAVE_CODEX" != 1 ]; then
    info "Codex folder not found ($CODEX_DIR): Codex skipped."
    return 0
  fi
  section_heading codex
  override="$CODEX_DIR/AGENTS.override.md"
  if [ -s "$override" ]; then
    note_wrapped warn 72 "" "AGENTS.override.md is not empty. Codex reads that file instead of AGENTS.md, so the Conductor block will not take effect until you merge it into the override file ($override). The block is still written to AGENTS.md."
  fi
  if [ "${DRY_RUN:-0}" != "1" ]; then
    manifest_begin "$CODEX_DIR"
    record_agents_root
  fi
  write_doctrine_block codex || return 1
  for id in $FILE_IDS; do
    [ "$(file_harness "$id")" = "codex" ] || continue
    [ "$(file_policy "$id")" != "doctrine-block" ] || continue
    component_selected "$(file_component "$id")" || continue
    install_payload_file "$id" || return 1
  done
  return 0
}

# uninstall_codex_extra MADE: once the Codex files are gone, the shared skills folder
# goes too, but only when the install record said Conductor made it (MADE is "false"
# for "was not there before") and nothing else is in it (rmdir refuses a folder that
# holds anything, so another tool's skills keep it). A folder that was there before the
# install, or a record that does not say, is left as it is.
uninstall_codex_extra() {
  if [ "${DRY_RUN:-0}" = "1" ]; then return 0; fi
  if [ "${1:-}" != "false" ]; then
    # Kept: the folder was there before this install, or the record cannot tell (an
    # upgrade from 0.3.0). Say so when it is now empty, so the user can remove it.
    if [ -d "$AGENTS_SKILLS_DIR" ] && [ ! -L "$AGENTS_SKILLS_DIR" ] && [ -z "$(ls -A "$AGENTS_SKILLS_DIR" 2>/dev/null)" ]; then
      note_wrapped info 72 "" "kept the empty Codex skills folder $AGENTS_SKILLS_DIR: it was there before this install, or an earlier Conductor made it. Remove it if you do not use it."
    fi
    return 0
  fi
  if [ ! -L "$AGENTS_SKILLS_DIR" ]; then rmdir "$AGENTS_SKILLS_DIR" 2>/dev/null || true; fi
  return 0
}
