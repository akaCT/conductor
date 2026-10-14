# tests/lib/assert.sh: assertions and the test counter. Source it from a suite.
#
#   t_begin NAME   start a test (a test that never reaches t_end counts as failed)
#   t_end          finish it: prints "PASS NAME", or "FAIL NAME" and its failures
#   t_summary      print the suite totals; returns 1 when any test failed
#
# tests/run.sh reads the lines that start with "PASS " and "FAIL ". Name every
# test after the criterion it proves, for example:
#   t_begin "REQ-INS-002.3 backup outside the file's folder"
#
# Assertions record a failure and carry on; they never exit the suite.
#   assert_eq EXPECTED ACTUAL [MSG]       assert_file PATH [MSG]
#   assert_no_file PATH [MSG]             assert_mode PATH MODE [MSG]
#   assert_contains HAYSTACK NEEDLE [MSG] assert_not_contains HAYSTACK NEEDLE [MSG]
#   assert_exit CODE cmd args...          CODE may be "!0" for any non-zero code
# assert_exit runs the command in a subshell and leaves its combined output in
# ASSERT_OUT and its exit code in ASSERT_RC.

# The list of private names a release run supplies in CONDUCTOR_LEAK_BASE (1 regular
# expression per line, # comments). It is captured here, before sandbox_new clears the
# CONDUCTOR_ variables, and exported for the python checks. Empty in a public checkout: the
# private-token tests then check only the generic patterns (a /Users/ path, an email).
LEAK_BASE_FILE="${CONDUCTOR_LEAK_BASE:-}"
export LEAK_BASE_FILE

# private_hits FILE...: prints "file:line" for each line of those files that holds a private
# token: a /Users/ path, an email address, or a match of any pattern in LEAK_BASE_FILE. It
# never prints the matched text. Prints nothing when the files are clean.
private_hits() {
  python3 -I - "$@" <<'PYEOF'
import os, re, sys
pats = [re.compile(r"/Users/"), re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}")]
base = os.environ.get("LEAK_BASE_FILE", "")
if base:
    for raw in open(base, encoding="utf-8").read().split("\n"):
        line = raw.strip()
        if line and not line.startswith("#"):
            pats.append(re.compile(line, re.IGNORECASE))
for path in sys.argv[1:]:
    with open(path, encoding="utf-8", errors="replace") as fh:
        for no, text in enumerate(fh.read().split("\n"), 1):
            if any(p.search(text) for p in pats):
                print("%s:%d" % (path, no))
PYEOF
}

T_NAME=""
T_OPEN=0
T_FAILS=0
T_DETAIL=""
T_PASSED=0
T_FAILED=0
ASSERT_OUT=""
ASSERT_RC=0

t_begin() {
  if [ "$T_OPEN" = 1 ]; then
    t_fail "t_end was never called"
    t_end
  fi
  T_NAME="$1"
  T_FAILS=0
  T_DETAIL=""
  T_OPEN=1
}

t_fail() {
  T_FAILS=$((T_FAILS + 1))
  T_DETAIL="${T_DETAIL}    $*"$'\n'
}

t_end() {
  [ "$T_OPEN" = 1 ] || return 0
  if [ "$T_FAILS" = 0 ]; then
    printf 'PASS %s\n' "$T_NAME"
    T_PASSED=$((T_PASSED + 1))
  else
    printf 'FAIL %s\n' "$T_NAME"
    printf '%s' "$T_DETAIL"
    T_FAILED=$((T_FAILED + 1))
  fi
  T_OPEN=0
}

t_summary() {
  t_end
  printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$T_PASSED" "$T_FAILED"
  [ "$T_FAILED" = 0 ]
}

assert_eq() {
  if [ "$1" != "$2" ]; then
    t_fail "${3:-assert_eq}: expected [$1] got [$2]"
  fi
}

assert_file() {
  if [ ! -f "$1" ]; then t_fail "${2:-assert_file}: missing file $1"; fi
}

assert_no_file() {
  if [ -e "$1" ] || [ -L "$1" ]; then t_fail "${2:-assert_no_file}: unexpected $1"; fi
}

# file_mode_of PATH: the octal mode (GNU stat first, then BSD stat). Also defined
# in sandbox.sh.
if ! type file_mode_of > /dev/null 2>&1; then
  file_mode_of() {
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
  }
fi

assert_mode() {
  local got
  got="$(file_mode_of "$1")"
  if [ "$got" != "$2" ]; then t_fail "${3:-assert_mode}: $1 has mode [$got], expected [$2]"; fi
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) t_fail "${3:-assert_contains}: missing [$2] in [$(printf '%s' "$1" | head -c 300)]" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) t_fail "${3:-assert_not_contains}: found [$2] in [$(printf '%s' "$1" | head -c 300)]" ;;
  esac
}

assert_exit() {
  local want="$1"
  shift
  ASSERT_OUT="$("$@" 2>&1)"
  ASSERT_RC=$?
  if [ "$want" = "!0" ]; then
    if [ "$ASSERT_RC" = 0 ]; then t_fail "assert_exit: expected a non-zero code from: $* (output: $(printf '%s' "$ASSERT_OUT" | head -c 200))"; fi
  elif [ "$ASSERT_RC" != "$want" ]; then
    t_fail "assert_exit: expected code $want, got $ASSERT_RC from: $* (output: $(printf '%s' "$ASSERT_OUT" | head -c 300))"
  fi
}
