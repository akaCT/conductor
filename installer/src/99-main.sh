# 99-main.sh [skeleton, then L1a]: argument parsing and the call order. The last
# line of the installer is the only statement that acts: main "$@".

usage() {
  local me
  me="$(installer_name)"
  cat <<USAGE
Conductor installer v$CONDUCTOR_VERSION

  bash $me [options]        install or upgrade
  bash $me update [--check] fetch and install the newest release

Options:
  --full               install the core and the full tier
  --core               install the core only; ask nothing about the rest
  --dry-run            print every action with "would"; change nothing
  --status             print the installed version, components and hooks
  --uninstall          reverse the install
  --replace-modified   replace Conductor files you changed (a backup is kept)
  --apply-effort-pins  write the offered effort pins without asking
  --judge-rung=1|3     choose the judge seat: 1 or 3
  --help               this message

Environment:
  CLAUDE_DIR=/path           Claude Code folder (default: \$HOME/.claude)
  CODEX_DIR=/path            Codex folder (default: \$HOME/.codex)
  AGENTS_SKILLS_DIR=/path    Codex skills root (default: \$HOME/.agents)
  CONDUCTOR_YES=1            ask nothing; take the safe default every time
  CONDUCTOR_COMPONENTS=a,b   name the components to install
  NO_COLOR=1                 print no colour

Homepage: $CONDUCTOR_URL
USAGE
}

# A usage error stops the run with exit 2 before anything is written.
usage_error() {
  err "$*"
  err "Run: bash $(installer_name) --help"
  exit 2
}

parse_args() {
  OPT_FULL=0
  OPT_CORE=0
  DRY_RUN=0
  OPT_STATUS=0
  OPT_UNINSTALL=0
  OPT_REPLACE_MODIFIED=0
  OPT_APPLY_EFFORT_PINS=0
  OPT_JUDGE_RUNG=""
  OPT_HELP=0
  OPT_UPDATE=0
  OPT_UPDATE_CHECK=0
  local val
  if [ "${1:-}" = "update" ]; then
    OPT_UPDATE=1
    shift
  fi
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h) OPT_HELP=1 ;;
      --check)
        if [ "$OPT_UPDATE" = 1 ]; then OPT_UPDATE_CHECK=1; else usage_error "--check belongs to: update --check"; fi
        ;;
      *)
        if [ "$OPT_UPDATE" = 1 ]; then usage_error "unknown argument for update: $1 (allowed: --check)"; fi
        case "$1" in
          --full) OPT_FULL=1 ;;
          --core) OPT_CORE=1 ;;
          --dry-run) DRY_RUN=1 ;;
          --status) OPT_STATUS=1 ;;
          --uninstall|-u) OPT_UNINSTALL=1 ;;
          --replace-modified) OPT_REPLACE_MODIFIED=1 ;;
          --apply-effort-pins) OPT_APPLY_EFFORT_PINS=1 ;;
          --judge-rung=*)
            val="${1#--judge-rung=}"
            case "$val" in
              1|3) OPT_JUDGE_RUNG="$val" ;;
              *) usage_error "--judge-rung must be 1 or 3 (got: $val)" ;;
            esac
            ;;
          --judge-rung) usage_error "--judge-rung needs a value: --judge-rung=1 or --judge-rung=3" ;;
          *) usage_error "unknown argument: $1" ;;
        esac
        ;;
    esac
    shift
  done
  if [ "$OPT_FULL" = 1 ] && [ "$OPT_CORE" = 1 ]; then
    usage_error "--full and --core cannot be used together"
  fi
  if [ $((OPT_STATUS + OPT_UNINSTALL + OPT_UPDATE)) -gt 1 ]; then
    usage_error "choose only 1 of: --status, --uninstall, update"
  fi
}

# A step that fails stops the run with a plain message. Every write is a whole
# file or nothing, so running the installer again is safe.
stop_install() {
  err "The install stopped before it finished. Run it again once fixed."
  exit 1
}

# The call order of an install. Every step is a function with an owner; the
# detection of roots, system, python3 and terminal happened in main.
do_install() {
  detect_cc_version
  detect_provider
  detect_existing
  print_plan
  select_components
  resolve_judge_rung
  install_core_files || stop_install
  write_doctrine_block claude || stop_install
  install_judge || stop_install
  gate_offer_pins
  install_full_tier || stop_install
  install_codex || stop_install
  remove_dropped_files
  settings_prune_dangling
  manifest_finish
  print_summary
}

main() {
  trap cleanup_tmp EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  parse_args "$@"
  if [ "$OPT_HELP" = 1 ]; then
    usage
    return 0
  fi
  detect_roots
  detect_os
  detect_python
  detect_interactive
  if [ "$OPT_UPDATE" = 1 ]; then
    if [ "$OPT_UPDATE_CHECK" = 1 ]; then do_update_check; else do_update; fi
  elif [ "$OPT_STATUS" = 1 ]; then
    do_status
  elif [ "$OPT_UNINSTALL" = 1 ]; then
    do_uninstall
  else
    require_a_root
    py_prepare || die "cannot make a temporary file; check TMPDIR"
    do_install
  fi
}

main "$@"
