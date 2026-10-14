# tests/fixtures/doctor/lib.sh: helpers shared by test-doctor.sh, test-report.sh and
# test-update.sh. Source it after tests/lib/assert.sh and tests/lib/sandbox.sh
# and after sandbox_new. Needs REPO (the repo root) and SBX.
#
# These helpers build throwaway Conductor installs inside the sandbox by copying payload
# files and writing install records; they never run the installer.

FXD="$REPO/tests/fixtures/doctor"
export PYTHONDONTWRITEBYTECODE=1

# The real environment must not leak into a fixture run.
l1b_clean_env() {
  local v
  for v in ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL \
    ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_BASE_URL \
    CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_EFFORT_LEVEL CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST \
    CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY \
    CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_MANTLE CONDUCTOR_HOOKS CONDUCTOR_DEBUG \
    CONDUCTOR_YES CONDUCTOR_COMPONENTS CONDUCTOR_TEST_UPDATE_URL CONDUCTOR_TEST_OPENER \
    CONDUCTOR_TEST_SANDBOX NO_COLOR PYTHONPATH TMPDIR_UPDATE; do
    unset "$v"
  done
  export CONDUCTOR_TEST_SANDBOX="$SBX"
}

# fx_launcher ROOT: the launcher, its libraries and the facts file, as an install lays them
fx_launcher() {
  mkdir -p "$1/conductor/bin" "$1/conductor/lib"
  cp "$REPO/payload/claude/conductor/bin/conductor" "$1/conductor/bin/conductor"
  chmod 755 "$1/conductor/bin/conductor"
  cp "$REPO/payload/claude/conductor/lib/doctor.py" "$REPO/payload/claude/conductor/lib/report.py" \
    "$REPO/payload/claude/conductor/lib/facts.json" "$1/conductor/lib/"
  cp "$REPO/payload/feedback-codes.txt" "$1/conductor/feedback-codes.txt"
}

fx_agents() { # ROOT
  mkdir -p "$1/agents"
  cp "$FXD"/agents/*.md "$1/agents/"
}

# fx_manifest ROOT KEY=VALUE...: a 0.4 install record whose file list covers the agent files
# present under ROOT/agents; extra KEY=JSON pairs override top-level keys.
fx_manifest() {
  local root="$1"
  shift
  "$SBX_PY" - "$root" "$@" <<'PYEOF'
import hashlib, json, os, sys
root = sys.argv[1]
files = []
agents = os.path.join(root, "agents")
if os.path.isdir(agents):
    for name in sorted(os.listdir(agents)):
        data = open(os.path.join(agents, name), "rb").read()
        files.append({"dest": "agents/" + name, "sha256": hashlib.sha256(data).hexdigest(),
                      "policy": "agent", "component": "core", "id": "agent_" + name.rsplit(".", 1)[0]})
rec = {"schema": 1, "product": "conductor", "method": "installer", "version": "0.4.0",
       "source_url": "https://raw.githubusercontent.com/akaCT/conductor/main/install.sh",
       "installed_at": "2026-10-12T10:00:00Z", "updated_at": "2026-10-12T10:00:00Z",
       "installer_sha256": None, "harness": "claude", "components": ["core"],
       "launcher": "conductor/bin/conductor", "python3": sys.executable, "files": files,
       "doctrine_block": True, "hooks_wired": False, "hooks": [], "pins": [], "env_written": [],
       "judge_rung": 3, "legacy_030": {}, "shared_with": []}
for kv in sys.argv[2:]:
    k, v = kv.split("=", 1)
    rec[k] = json.loads(v)
os.makedirs(os.path.join(root, "conductor"), exist_ok=True)
path = os.path.join(root, "conductor", ".install-manifest")
with open(path, "w") as fh:
    json.dump(rec, fh, indent=2)
    fh.write("\n")
os.chmod(path, 0o600)
PYEOF
}

fx_claude_md() { # ROOT [VERSION]
  mkdir -p "$1"
  printf 'My own notes.\n\n<!-- BEGIN CONDUCTOR (managed) v%s - https://conductorskill.com -->\nFixture doctrine.\n<!-- END CONDUCTOR (managed) -->\n' "${2:-0.4.0}" > "$1/CLAUDE.md"
}

# fx_codex_install: a Codex install under $CODEX_DIR; $1 = builder fixture (default: no effort)
fx_codex_install() {
  mkdir -p "$CODEX_DIR/agents"
  cp "$FXD"/codex/scout.toml "$FXD"/codex/critic.toml "$FXD"/codex/architect.toml "$CODEX_DIR/agents/"
  cp "$FXD/codex/${1:-builder.toml}" "$CODEX_DIR/agents/builder.toml"
  fx_manifest "$CODEX_DIR" 'harness="codex"' 'components=["core"]' 'launcher=null'
  printf '# managed by Conductor fixture\n' > "$CODEX_DIR/AGENTS.md"
}

# fx_claude_install: a complete 0.4 Claude install under $CLAUDE_DIR (core + full, 2 hooks wired)
fx_claude_install() {
  fx_launcher "$CLAUDE_DIR"
  fx_agents "$CLAUDE_DIR"
  fx_manifest "$CLAUDE_DIR" 'components=["core","full","hook_pointer","hook_nudge"]'
  fx_claude_md "$CLAUDE_DIR"
  "$SBX_PY" - "$CLAUDE_DIR" <<'PYEOF'
import json, os, sys
root = sys.argv[1]
def cmd(stem):
    return '"%s" "%s/conductor/hooks/%s.py"' % (sys.executable, root, stem)
settings = {"effortLevel": "high",
            "modelSettings": {"claude-opus-5-5": {"effortLevel": "high"}, "claude-sonnet-5-5": {"effortLevel": "high"}},
            "hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": cmd("session-start-pointer"), "timeout": 10}]}],
                      "UserPromptSubmit": [{"matcher": "", "hooks": [{"type": "command", "command": cmd("checkpoint-nudge"), "timeout": 10}]}]}}
with open(os.path.join(root, "settings.json"), "w") as fh:
    json.dump(settings, fh, indent=2)
    fh.write("\n")
PYEOF
}

# fresh_roots: empty config roots, no fakes, a clean environment and a fake claude
fresh_roots() {
  case "$HOME" in "$SBX"/*) ;; *) echo "fresh_roots: HOME is outside the sandbox" >&2; exit 99 ;; esac
  rm -rf "$HOME/.claude" "$HOME/.codex" "$HOME/.agents" "$SBX/proj"
  sandbox_clear_fakes
  l1b_clean_env
  sandbox_fake_claude "${1:-2.1.296}"
  printf '#!/bin/sh\necho "codex-cli 0.46.0"\n' > "$SBX/bin/codex"
  chmod 755 "$SBX/bin/codex"
  mkdir -p "$SBX/proj"
  cd "$SBX/proj" || exit 99
  SBXR="$(cd "$SBX" && pwd -P)"
}

# run_conductor ARGS...: run the installed launcher; leaves the output in OUT and the status in RC
run_conductor() {
  OUT="$(/bin/bash "$CLAUDE_DIR/conductor/bin/conductor" "$@" 2>&1 < /dev/null)"
  RC=$?
}

# run_doctor ARGS...: the installed launcher's doctor, with managed settings pointed away
# from the real machine
run_doctor() {
  run_conductor doctor --managed-settings "$SBX/managed-settings.json" "$@"
}

# net_deny_setup: no process the test starts can reach the network unseen. A fake curl, wget
# and nc on PATH record their call and fail; python sockets are patched through sitecustomize.
# net_deny_calls prints what was recorded (nothing when the run made no call).
net_deny_setup() {
  mkdir -p "$SBX/netdeny" "$SBX/bin"
  : > "$SBX/net-calls.log"
  cat > "$SBX/netdeny/sitecustomize.py" <<'PYEOF'
import os, socket

def _deny(*args, **kwargs):
    with open(os.environ["NETDENY_LOG"], "a") as fh:
        fh.write("python socket call\n")
    raise OSError("network denied by the test")

socket.socket.connect = _deny
socket.socket.connect_ex = _deny
socket.create_connection = _deny
socket.getaddrinfo = _deny
PYEOF
  local tool
  for tool in curl wget nc ssh; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 1\n' "$tool" "$SBX/net-calls.log" > "$SBX/bin/$tool"
    chmod 755 "$SBX/bin/$tool"
  done
  export PYTHONPATH="$SBX/netdeny" NETDENY_LOG="$SBX/netdeny.log"
  : > "$SBX/netdeny.log"
}

net_deny_calls() {
  cat "$SBX/net-calls.log" "$SBX/netdeny.log" 2>/dev/null
}

net_deny_teardown() {
  unset PYTHONPATH NETDENY_LOG
  rm -f "$SBX/bin/curl" "$SBX/bin/wget" "$SBX/bin/nc" "$SBX/bin/ssh"
}

# strip_sbx TEXT: the sandbox folder replaced by a short token, to measure fixed text
strip_sbx() {
  printf '%s' "$1" | sed "s#$SBX#{sbx}#g"
}
