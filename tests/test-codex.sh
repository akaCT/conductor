#!/bin/bash
# tests/test-codex.sh: the Codex agent files generated from 1 model map
# (REQ-CDX-001) and the Codex install (REQ-CDX-002).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/sandbox.sh"
. "$HERE/lib/l2-common.sh"

sandbox_new
trap sandbox_cleanup EXIT
sandbox_guard
build_installer codex

CJ="$REPO/payload/components.json"
TOML_DIR="$REPO/payload/codex/agents"

fixture() { # $1=name: a fresh copy of tools, installer and payload
  local d="$SBX/$1"
  rm -rf "$d"; mkdir -p "$d"
  cp -R "$REPO/tools" "$REPO/installer" "$REPO/payload" "$d/"
}

t_begin "REQ-CDX-001.1 4 TOML files are generated with the ids the map gives each seat"
n="$(ls "$TOML_DIR"/*.toml | wc -l | tr -d ' ')"
assert_eq "4" "$n" "generated files"
python3 - "$CJ" "$REPO/payload/claude/agents" "$TOML_DIR" <<'PYEOF' || t_fail "mapped ids do not match"
import json, re, sys
cj, agents, tomls = sys.argv[1:4]
models = json.load(open(cj))["codex_models"]
want = {"architect": "opus", "builder": "sonnet", "critic": "sonnet", "scout": "haiku"}
for seat, alias in want.items():
    text = open("%s/%s.md" % (agents, seat)).read()
    assert re.search(r"^model: %s$" % alias, text, re.M), (seat, alias)
    toml = open("%s/%s.toml" % (tomls, seat)).read()
    assert re.search(r'^model = "%s"$' % re.escape(models[alias]), toml, re.M), (seat, models[alias])
PYEOF
t_end

t_begin "REQ-CDX-001.2 an alias missing from the map fails the build"
fixture neg-map
python3 - "$SBX/neg-map/payload/components.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
del d["codex_models"]["haiku"]
open(p, "w").write(json.dumps(d, indent=1) + "\n")
PYEOF
assert_exit 1 python3 "$SBX/neg-map/tools/build.py"
assert_contains "$ASSERT_OUT" "haiku" "names the alias"
assert_contains "$ASSERT_OUT" "codex_models" "names the map"
fixture neg-alias
sed -i.bak 's/^model: haiku$/model: fable/' "$SBX/neg-alias/payload/claude/agents/scout.md" && rm -f "$SBX/neg-alias/payload/claude/agents/scout.md.bak"
assert_exit 1 python3 "$SBX/neg-alias/tools/build.py"
assert_contains "$ASSERT_OUT" "fable" "names the unmapped alias"
t_end

t_begin "REQ-CDX-001.3 the generated files hold 0 retired model ids"
hits="$(grep -nE 'gpt-5\.4|gpt-5\.5' "$TOML_DIR"/*.toml || true)"
assert_eq "" "$hits" "retired ids in the TOML files"
hits="$(python3 -c "
import json, sys
m = json.load(open(sys.argv[1]))['codex_models']
print(' '.join(v for v in m.values() if v in ('gpt-5.4', 'gpt-5.4-mini', 'gpt-5.5')))
" "$CJ")"
assert_eq "" "$hits" "retired ids in the map"
t_end

t_begin "REQ-CDX-001.4 each generated file is valid TOML"
python3 - "$TOML_DIR" "$REPO/tools" <<'PYEOF' || t_fail "a generated file does not parse"
import glob, sys
tomls, tools = sys.argv[1:3]
files = sorted(glob.glob(tomls + "/*.toml"))
assert len(files) == 4, files
try:
    import tomllib
    for f in files:
        d = tomllib.loads(open(f).read())
        assert d["model"] and d["name"] and d["developer_instructions"], f
except ImportError:
    sys.path.insert(0, tools)
    import build
    for f in files:
        d = build.minimal_toml_parse(open(f).read())
        assert d["model"] and d["name"] and d["developer_instructions"], f
PYEOF
t_end

t_begin "REQ-CDX-001.5 the release record holds the vendor list URL and the check date"
r="$(cat "$REPO/release/RECORD-0.4.0.md")"
assert_contains "$r" "https://learn.chatgpt.com/docs/models"
d="$(sed -n 's/^Map ids re-checked on: \([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\).*/\1/p' "$REPO/release/RECORD-0.4.0.md")"
[ -n "$d" ] || t_fail "no ISO check date"
for id in gpt-6-astra gpt-6.1-sol gpt-6-luna; do assert_contains "$r" "$id" "record names $id"; done
t_end

t_begin "REQ-CDX-002.4 the build adds no Codex effort key while the record lists no verified values"
assert_eq "{}" "$(python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1]))['codex_effort']))" "$CJ")" "codex_effort"
hits="$(grep -l 'model_reasoning_effort' "$TOML_DIR"/*.toml || true)"
assert_eq "" "$hits" "TOML files with an effort key"
assert_contains "$(cat "$REPO/release/RECORD-0.4.0.md")" "not pinned"
t_end

# ---------------------------------------------------------------- the install

t_begin "REQ-CDX-002.1 a temp Codex folder gets the doctrine block, the 4 agents and the skill, all in the manifest"
fresh; set_cc 2.1.296
rm -rf "$CLAUDE_DIR"; mkdir -p "$CODEX_DIR"
inst --core
assert_eq "0" "$RC" "rc"
assert_contains "$(cat "$CODEX_DIR/AGENTS.md")" "BEGIN CONDUCTOR (managed)" "doctrine block"
for s in builder scout critic architect; do
  assert_file "$CODEX_DIR/agents/$s.toml"
  cmp -s "$TOML_DIR/$s.toml" "$CODEX_DIR/agents/$s.toml" || t_fail "$s.toml differs from the generated payload"
done
assert_file "$AGENTS_SKILLS_DIR/skills/conductor/SKILL.md" "skill"
m="$(cat "$CODEX_DIR/conductor/.install-manifest" 2>/dev/null)"
for dest in agents/builder.toml agents/scout.toml agents/critic.toml agents/architect.toml skills/conductor/SKILL.md; do
  assert_contains "$m" "$dest" "manifest lists $dest"
done
t_end

t_begin "REQ-CDX-002.2 a non-empty AGENTS.override.md gets a warning and the block is still written"
fresh; set_cc 2.1.296
rm -rf "$CLAUDE_DIR"; mkdir -p "$CODEX_DIR"
printf 'my own rules\n' > "$CODEX_DIR/AGENTS.override.md"
inst --core
assert_contains "$OUT" "AGENTS.override.md is not empty"
assert_contains "$(flat "$OUT")" "will not take effect until you merge it"
assert_contains "$(cat "$CODEX_DIR/AGENTS.md")" "BEGIN CONDUCTOR (managed)" "block still written"
assert_eq "my own rules" "$(cat "$CODEX_DIR/AGENTS.override.md")" "override file never edited"
fresh; set_cc 2.1.296
rm -rf "$CLAUDE_DIR"; mkdir -p "$CODEX_DIR"
: > "$CODEX_DIR/AGENTS.override.md"
inst --core
assert_not_contains "$OUT" "AGENTS.override.md is not empty" "an empty override file raises no warning"
t_end

t_begin "REQ-CDX-002.3 a Codex install wires 0 hook entries for Codex"
fresh; set_cc 2.1.296
mkdir -p "$CODEX_DIR"
inst --core
assert_no_file "$CODEX_DIR/hooks.json"
assert_no_file "$CODEX_DIR/config.toml"
hits="$(find "$CODEX_DIR" "$AGENTS_SKILLS_DIR" -iname '*hook*' 2>/dev/null || true)"
assert_eq "" "$hits" "Codex files named for hooks"
hits="$(grep -rlE '^\[+hooks|"hooks"' "$CODEX_DIR/agents" "$CODEX_DIR/AGENTS.md" 2>/dev/null || true)"
assert_eq "" "$hits" "Codex files with a hooks table"
if [ -f "$CLAUDE_DIR/settings.json" ]; then
  assert_not_contains "$(cat "$CLAUDE_DIR/settings.json")" "$CODEX_DIR" "no Claude hook points at Codex"
fi
w="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(sum(1 for f in d['files'] if f['harness'] == 'codex' and f.get('wire')))
" "$CJ")"
assert_eq "0" "$w" "Codex file entries with wire"
t_end

t_begin "REQ-CDX-002.1 no Codex folder: the install skips Codex, says so and creates nothing there"
fresh; set_cc 2.1.296
inst --core
assert_contains "$OUT" "Codex skipped"
assert_no_file "$CODEX_DIR"
assert_no_file "$AGENTS_SKILLS_DIR"
t_end

t_summary
