# 20-gates.sh [L2]: Claude Code version, provider, version compare, judge rung.
#
# Sets: CC_VERSION (string or empty), PROVIDER (first-party, bedrock, vertex,
#       foundry, anthropic-aws, mantle, custom-base-url, host-managed, unknown),
#       FIRST_PARTY (0 or 1), PROVIDER_NOTE (why the provider is unknown),
#       BASE_URL_FROM (environment or settings: where a custom ANTHROPIC_BASE_URL is set),
#       JUDGE_RUNG (1 or 3), JUDGE_REASON and JUDGE_HINT (a line for the summary).
# Reads: FLOOR_* and PROVIDER_VARS from the generated block, PY, HAVE_CLAUDE,
#        CLAUDE_DIR, INTERACTIVE, OPT_JUDGE_RUNG.

CC_VERSION=""
PROVIDER="unknown"
FIRST_PARTY=0
PROVIDER_NOTE=""
BASE_URL_FROM=""
JUDGE_RUNG=""
JUDGE_REASON=""
JUDGE_HINT=""
LIMITED_OUT=""

# limited_run SECONDS CMD...: runs CMD with stdout captured into LIMITED_OUT and
# stops it after SECONDS. macOS has no timeout command, so this uses a watchdog.
limited_run() {
  local secs="$1" out pid wd rc
  shift
  LIMITED_OUT=""
  out="$(mktemp 2>/dev/null)" || return 1
  "$@" > "$out" 2>/dev/null < /dev/null &
  pid=$!
  ( sleep "$secs"; kill "$pid" ) > /dev/null 2>&1 &
  wd=$!
  { wait "$pid"; } 2>/dev/null
  rc=$?
  kill "$wd" > /dev/null 2>&1
  { wait "$wd"; } 2>/dev/null
  LIMITED_OUT="$(cat "$out" 2>/dev/null)"
  rm -f "$out"
  return "$rc"
}

# Reads `claude --version` (5 second limit). An unreadable version leaves
# CC_VERSION empty, which means unknown: every eligible snippet is printed and
# nothing is written.
detect_cc_version() {
  local line
  CC_VERSION=""
  if ! command -v claude > /dev/null 2>&1; then return 0; fi
  limited_run 5 claude --version || true
  line="$(printf '%s\n' "$LIMITED_OUT" | head -n 1 | sanitize_text)"
  CC_VERSION="$(printf '%s\n' "$line" | sed -n 's/^[^0-9]*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*$/\1/p')"
  return 0
}

# version_ge A B: returns 0 when A >= B, comparing part by part as integers.
# An empty or non-numeric A or B returns 1.
version_ge() {
  local a="$1" b="$2" i pa pb
  case "$a$b" in *[!0-9.]*) return 1 ;; esac
  [ -n "$a" ] && [ -n "$b" ] || return 1
  i=1
  while [ "$i" -le 3 ]; do
    pa="$(printf '%s' "$a" | cut -d. -f"$i")"
    pb="$(printf '%s' "$b" | cut -d. -f"$i")"
    pa="${pa:-0}"
    pb="${pb:-0}"
    if [ "$pa" -gt "$pb" ]; then return 0; fi
    if [ "$pa" -lt "$pb" ]; then return 1; fi
    i=$((i + 1))
  done
  return 0
}

provider_from_var() { # $1=variable name -> provider name
  case "$1" in
    CLAUDE_CODE_USE_BEDROCK) printf 'bedrock' ;;
    CLAUDE_CODE_USE_VERTEX) printf 'vertex' ;;
    CLAUDE_CODE_USE_FOUNDRY) printf 'foundry' ;;
    CLAUDE_CODE_USE_ANTHROPIC_AWS) printf 'anthropic-aws' ;;
    CLAUDE_CODE_USE_MANTLE) printf 'mantle' ;;
    *) printf 'unknown' ;;
  esac
}

provider_label() { # $1=provider -> plain name
  case "$1" in
    first-party) printf 'the Anthropic API' ;;
    bedrock) printf 'Amazon Bedrock' ;;
    vertex) printf "Google Cloud's Agent Platform (Vertex)" ;;
    foundry) printf 'Microsoft Foundry' ;;
    anthropic-aws) printf 'Claude Platform on AWS' ;;
    mantle) printf 'Bedrock Mantle' ;;
    custom-base-url) printf 'another address in ANTHROPIC_BASE_URL' ;;
    host-managed) printf 'a host-managed provider' ;;
    *) printf 'a provider that could not be identified' ;;
  esac
}

# vendor_alias_model PROVIDER ALIAS: what the alias resolves to off the
# first-party API (vendor table read 2026-10-12; same data as facts.json
# vendor_alias_table, which tests/test-effort.sh compares with this function).
vendor_alias_model() {
  case "$1:$2" in
    bedrock:sonnet|vertex:sonnet|foundry:sonnet) printf 'Sonnet 4.5' ;;
    anthropic-aws:sonnet) printf 'Sonnet 4.6' ;;
    bedrock:haiku|vertex:haiku|foundry:haiku|anthropic-aws:haiku) printf 'Haiku 4.5' ;;
    foundry:opus) printf 'Opus 4.6' ;;
    *) printf 'not stated' ;;
  esac
}

# base_url_is_default VALUE: true when VALUE is the vendor's own address,
# https://api.anthropic.com, with the host in any letter case and at most 1
# trailing slash. Any other value, even one that only starts with it, is not.
base_url_is_default() {
  local u
  u="$(printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z')"
  u="${u%/}"
  [ "$u" = "https://api.anthropic.com" ]
}

# settings_env_names: prints the names (of PROVIDER_VARS and PROVIDER_BLOCK_VARS)
# that the `env` block of the user settings holds with a non-empty value; an
# ANTHROPIC_BASE_URL that is the vendor's own address (see base_url_is_default)
# is not printed. Needs PY. Returns 3 when settings.json does not parse, 2 when
# PY is missing. Python runs isolated (-I -B): the folder the installer was
# started in is never on its module path.
settings_env_names() {
  [ -n "$PY" ] || return 2
  [ -f "$CLAUDE_DIR/settings.json" ] || return 0
  "$PY" -I -B -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        text = fh.read()
    data = json.loads(text) if text.strip() else {}
except Exception:
    sys.exit(3)
env = data.get("env") if isinstance(data, dict) else None
if isinstance(env, dict):
    for name in sys.argv[2:]:
        val = env.get(name)
        if val is not None and str(val) != "":
            url = str(val).lower()
            if name == "ANTHROPIC_BASE_URL" and (url[:-1] if url.endswith("/") else url) == "https://api.anthropic.com":
                continue
            print(name)
' "$CLAUDE_DIR/settings.json" $PROVIDER_VARS $PROVIDER_BLOCK_VARS
}

# The provider is the first-party API only when none of the 5 provider variables
# is non-empty in the process environment or the settings env block, and
# CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST is not set, and ANTHROPIC_BASE_URL is
# either not set or the vendor's own address (https://api.anthropic.com, with or
# without a trailing slash; any other value is another provider). An empty
# string counts as unset. Reading the settings env block needs python3; without
# it the provider is "unknown" unless the process environment already names one.
detect_provider() {
  local v val names n rc
  PROVIDER=""
  FIRST_PARTY=0
  PROVIDER_NOTE=""
  BASE_URL_FROM=""
  for v in $PROVIDER_VARS; do
    eval "val=\"\${$v:-}\""
    if [ -n "$val" ]; then PROVIDER="$(provider_from_var "$v")"; return 0; fi
  done
  if [ -n "${CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST:-}" ]; then PROVIDER="host-managed"; return 0; fi
  if [ -n "${ANTHROPIC_BASE_URL:-}" ] && ! base_url_is_default "$ANTHROPIC_BASE_URL"; then
    PROVIDER="custom-base-url"
    BASE_URL_FROM="environment"
    return 0
  fi
  names="$(settings_env_names)"
  rc=$?
  if [ "$rc" = 2 ]; then
    PROVIDER="unknown"
    PROVIDER_NOTE="the env block of your settings was not read because python3 is not usable: ${PY_REASON:-not found}"
    return 0
  fi
  if [ "$rc" = 3 ]; then
    PROVIDER="unknown"
    PROVIDER_NOTE="your settings.json does not parse, so its env block was not read"
    return 0
  fi
  for n in $names; do
    case " $PROVIDER_VARS " in *" $n "*) PROVIDER="$(provider_from_var "$n")"; return 0 ;; esac
  done
  for n in $names; do
    if [ "$n" = "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST" ]; then PROVIDER="host-managed"; return 0; fi
  done
  for n in $names; do
    if [ "$n" = "ANTHROPIC_BASE_URL" ]; then PROVIDER="custom-base-url"; BASE_URL_FROM="settings"; return 0; fi
  done
  PROVIDER="first-party"
  FIRST_PARTY=1
  return 0
}

# judge_rung1_possible: returns 0 when rung 1 can be offered, else 1 with the
# reason in JUDGE_REASON.
judge_rung1_possible() {
  JUDGE_REASON=""
  if [ "$FIRST_PARTY" != 1 ]; then
    JUDGE_REASON="rung 1 needs the Anthropic API, and your provider is $(provider_label "$PROVIDER")"
    return 1
  fi
  if [ -z "$CC_VERSION" ]; then
    JUDGE_REASON="rung 1 needs Claude Code $FLOOR_FABLE or later, and your version could not be read"
    return 1
  fi
  if ! version_ge "$CC_VERSION" "$FLOOR_FABLE"; then
    JUDGE_REASON="rung 1 needs Claude Code $FLOOR_FABLE or later, and yours is $CC_VERSION (run: claude update)"
    return 1
  fi
  return 0
}

# Sets JUDGE_RUNG to 1 or 3 and JUDGE_REASON. Rung 1 is the Fable 5.1 judge and
# needs the first-party API on Claude Code 2.1.257 or later. The question is
# asked only when rung 1 is possible. With no terminal and no --judge-rung the
# rung the manifest records is kept, else rung 3. A --judge-rung value that is
# not 1 or 3 never gets here: parse_args exits with 2 before any write.
resolve_judge_rung() {
  local recorded=""
  JUDGE_RUNG=""
  JUDGE_REASON=""
  JUDGE_HINT=""
  [ "$HAVE_CLAUDE" = 1 ] || return 0
  recorded="$(manifest_get "$CLAUDE_DIR" judge_rung 2>/dev/null | tr -d '" \n')"
  case "$recorded" in 1|3) ;; *) recorded="" ;; esac

  if [ "${OPT_JUDGE_RUNG:-}" = "3" ]; then
    JUDGE_RUNG=3
    JUDGE_REASON="you chose it with --judge-rung=3"
  elif [ "${OPT_JUDGE_RUNG:-}" = "1" ]; then
    if judge_rung1_possible; then
      JUDGE_RUNG=1
      JUDGE_REASON="you chose it with --judge-rung=1"
    else
      JUDGE_RUNG=3
    fi
  elif no_prompt; then
    if [ -n "$recorded" ]; then
      JUDGE_RUNG="$recorded"
      JUDGE_REASON="your earlier install recorded rung $recorded"
      if [ "$recorded" = 1 ] && ! judge_rung1_possible; then
        note_wrapped warn 72 "" "Your earlier install recorded judge rung 1, but $JUDGE_REASON. If a judge call fails, the conductor falls back to rung 3. To change it: bash $(installer_name) --judge-rung=3"
        JUDGE_REASON="your earlier install recorded rung 1"
      fi
    else
      JUDGE_RUNG=3
      JUDGE_REASON="there is no terminal to ask in and no --judge-rung flag"
    fi
  elif judge_rung1_possible; then
    note_wrapped info 72 "" "Judge seat: rung 1 runs on Fable 5.1, a different model family from the builders. Rung 3 runs on Sonnet 5.5 in a fresh context and is a weaker second view. Rung 2, a judge from another lab, comes in a later release."
    local def=n
    if [ "$recorded" = 1 ]; then def=y; fi
    if ask_yn "Does your account have Fable 5.1?" "$def"; then
      JUDGE_RUNG=1
      JUDGE_REASON="you said yes to the Fable 5.1 question"
    else
      JUDGE_RUNG=3
      JUDGE_REASON="you said no to the Fable 5.1 question"
    fi
  else
    JUDGE_RUNG=3
  fi
  return 0
}
