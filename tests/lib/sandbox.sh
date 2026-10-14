# tests/lib/sandbox.sh: the throwaway-config fixture. Source it from a suite.
#
# Every install, upgrade, uninstall and hook test runs inside a sandbox: a fresh
# folder under ${TMPDIR:-/tmp} holding a fake HOME and every config root. No
# test touches a real home, config folder or settings file.
#
#   sandbox_new                  make $SBX; export HOME and the 5 root variables
#                                under it ($HOME/.claude, .codex, .agents); the
#                                folders themselves are NOT created, so a test
#                                decides which harness exists; unset the provider
#                                variables, CLAUDE_CODE_EFFORT_LEVEL, CONDUCTOR_*
#                                and NO_COLOR; put $SBX/bin first on PATH
#   sandbox_guard                abort the suite (exit 99) when HOME, CLAUDE_DIR,
#                                CLAUDE_CONFIG_DIR, CODEX_DIR, CODEX_HOME or
#                                AGENTS_SKILLS_DIR is not under $SBX
#                                (REQ-OPS-002.2). Call it before the first install.
#   sandbox_fake_claude VERSION  a claude on PATH that prints "VERSION (Claude Code)"
#   sandbox_fake_python VERSION  a python3 on PATH that prints VERSION for -c
#   sandbox_fake_xcode_select FAIL|OK
#   sandbox_fake_uname NAME      a uname that prints NAME (Darwin, Linux, MINGW64_NT)
#   sandbox_no_python            a PATH of symbolic links to the basic tools, with
#                                no python3 (add more with sandbox_link_tools)
#   sandbox_link_tools NAME...   link more tools into the no-python PATH
#   sandbox_tree_sum DIR         1 line per entry: path, type, mode, sha256
#   sandbox_notty CMD...         run CMD with no controlling terminal (give it
#                                < /dev/null so stdin is not a terminal either)
#   sandbox_pty CMD...           run CMD on a pseudo terminal; PTY_INPUT, when
#                                set, is typed into it; prints what CMD wrote;
#                                PTY_TIMEOUT seconds (default 30) is the deadline
#   sandbox_clear_fakes          remove every fake tool and restore the PATH
#   sandbox_cleanup              remove $SBX
#
# A suite looks like:  sandbox_new; trap sandbox_cleanup EXIT; sandbox_guard

SBX=""
SBX_PY=""
SBX_BASE_PATH=""

# file_mode_of PATH: the octal mode (GNU stat first, then BSD stat). Also defined
# in assert.sh; this copy keeps sandbox.sh usable on its own.
if ! type file_mode_of > /dev/null 2>&1; then
  file_mode_of() {
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
  }
fi

sandbox_new() {
  local base="${TMPDIR:-/tmp}" v
  base="${base%/}"
  SBX="$(mktemp -d "$base/conductor-test.XXXXXX")" || { echo "sandbox_new: mktemp failed" >&2; exit 99; }
  if [ -z "$SBX_BASE_PATH" ]; then SBX_BASE_PATH="$PATH"; fi
  SBX_PY="$(PATH="$SBX_BASE_PATH" command -v python3 || true)"
  mkdir -p "$SBX/home" "$SBX/bin"
  export SBX
  export HOME="$SBX/home"
  export CLAUDE_DIR="$HOME/.claude" CLAUDE_CONFIG_DIR="$HOME/.claude"
  export CODEX_DIR="$HOME/.codex" CODEX_HOME="$HOME/.codex"
  export AGENTS_SKILLS_DIR="$HOME/.agents"
  for v in $(compgen -v | grep -E '^(CLAUDE_CODE_USE_|CONDUCTOR_)' || true); do unset "$v"; done
  unset ANTHROPIC_BASE_URL CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST CLAUDE_CODE_EFFORT_LEVEL NO_COLOR
  export PATH="$SBX/bin:$SBX_BASE_PATH"
}

sandbox_guard() {
  local v val
  if [ -z "${SBX:-}" ] || [ ! -d "$SBX" ]; then
    echo "sandbox_guard: no sandbox; call sandbox_new first. Aborting." >&2
    exit 99
  fi
  for v in HOME CLAUDE_DIR CLAUDE_CONFIG_DIR CODEX_DIR CODEX_HOME AGENTS_SKILLS_DIR; do
    eval "val=\"\${$v:-}\""
    case "$val" in
      "$SBX"/*) ;;
      *) echo "sandbox_guard: $v='$val' is not under $SBX. Aborting." >&2; exit 99 ;;
    esac
  done
}

sandbox_fake_claude() {
  printf '#!/bin/sh\necho "%s (Claude Code)"\n' "$1" > "$SBX/bin/claude"
  chmod 755 "$SBX/bin/claude"
}

sandbox_fake_python() {
  printf '#!/bin/sh\nfor a in "$@"; do if [ "$a" = "-c" ]; then echo "%s"; fi; done\nexit 0\n' "$1" > "$SBX/bin/python3"
  chmod 755 "$SBX/bin/python3"
}

sandbox_fake_xcode_select() {
  case "$1" in
    FAIL) printf '#!/bin/sh\necho "xcode-select: error: unable to get active developer directory" >&2\nexit 2\n' > "$SBX/bin/xcode-select" ;;
    OK) printf '#!/bin/sh\necho /Library/Developer/CommandLineTools\nexit 0\n' > "$SBX/bin/xcode-select" ;;
    *) echo "sandbox_fake_xcode_select: use FAIL or OK" >&2; return 1 ;;
  esac
  chmod 755 "$SBX/bin/xcode-select"
}

sandbox_fake_uname() {
  printf '#!/bin/sh\necho "%s"\n' "$1" > "$SBX/bin/uname"
  chmod 755 "$SBX/bin/uname"
}

sandbox_link_tools() {
  local name path
  mkdir -p "$SBX/nopy"
  for name in "$@"; do
    path="$(PATH="$SBX_BASE_PATH" command -v "$name" 2>/dev/null || true)"
    case "$path" in
      /*) ln -sf "$path" "$SBX/nopy/$name" ;;
    esac
  done
}

sandbox_no_python() {
  rm -f "$SBX/bin/python3"
  sandbox_link_tools bash sh env cat cp mv rm ls mkdir rmdir chmod mktemp date dirname basename \
    awk sed grep egrep tr cut head tail sort uniq cmp diff readlink uname sha256sum shasum openssl \
    xcode-select find wc touch ln id printf test expr od sleep stat tee xargs true false
  export PATH="$SBX/bin:$SBX/nopy"
}

sandbox_tree_sum() {
  local dir="$1" p type mode sum
  [ -d "$dir" ] || return 0
  (
    cd "$dir" || exit 1
    find . | LC_ALL=C sort | while IFS= read -r p; do
      if [ -L "$p" ]; then
        type="link"; mode="-"; sum="$(readlink "$p")"
      elif [ -d "$p" ]; then
        type="dir"; mode="$(file_mode_of "$p")"; sum="-"
      else
        type="file"; mode="$(file_mode_of "$p")"
        sum="$( (sha256sum "$p" 2>/dev/null || shasum -a 256 "$p") | awk '{print $1}')"
      fi
      printf '%s\t%s\t%s\t%s\n' "$p" "$type" "$mode" "$sum"
    done
  )
}

sandbox_notty() {
  "$SBX_PY" -c '
import os, sys
pid = os.fork()
if pid == 0:
    os.setsid()
    os.execvp(sys.argv[1], sys.argv[1:])
_, st = os.waitpid(pid, 0)
sys.exit(os.WEXITSTATUS(st) if os.WIFEXITED(st) else 128 + os.WTERMSIG(st))
' "$@"
}

sandbox_pty() {
  "$SBX_PY" -c '
import os, pty, select, signal, sys, time
inp = os.environ.get("PTY_INPUT", "").encode()
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
if inp:
    os.write(fd, inp)
out = b""
deadline = time.time() + float(os.environ.get("PTY_TIMEOUT", "30"))
timed_out = False
while True:
    left = deadline - time.time()
    if left <= 0:
        timed_out = True
        os.kill(pid, signal.SIGKILL)
        break
    ready, _, _ = select.select([fd], [], [], left)
    if not ready:
        continue
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    out += data
_, st = os.waitpid(pid, 0)
sys.stdout.write(out.decode("utf-8", "replace").replace("\r\n", "\n"))
if timed_out:
    sys.exit(124)
sys.exit(os.WEXITSTATUS(st) if os.WIFEXITED(st) else 1)
' "$@"
}

sandbox_cleanup() {
  case "$SBX" in
    */conductor-test.*)
      if [ -d "$SBX" ] && [ ! -L "$SBX" ]; then rm -rf "$SBX"; fi
      ;;
  esac
  if [ -n "$SBX_BASE_PATH" ]; then export PATH="$SBX_BASE_PATH"; fi
}

# sandbox_clear_fakes: remove every fake tool from $SBX/bin and the no-python
# PATH; a test that wrote a fake calls this so later tests see the real tools.
sandbox_clear_fakes() {
  rm -f "$SBX"/bin/* 2>/dev/null || true
  rm -rf "$SBX/nopy"
  export PATH="$SBX/bin:$SBX_BASE_PATH"
}
