#!/usr/bin/env python3
"""Fixture driver for tests/test-report.sh.

  canary_run.py all  --lib DIR --work DIR     seed each of the 150 canaries into a throwaway
                                              config, build the bug bundle in process, and
                                              check it
  canary_run.py seed --claude DIR --bin DIR --index N
                                              seed 1 canary into an existing Claude folder
                                              (for an end-to-end run through the launcher)
  canary_run.py show --index N                print canary N

Each canary goes into every place user text can sit: agent model and effort lines, agent
bodies, an extra agent file name, settings values, install record fields, CLAUDE.md,
defaults, the debug trace, the version output of claude and codex, environment
variables and the project folder name. Python 3.9, standard library only.
"""
import argparse
import json
import os
import re
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import canaries  # noqa: E402

CODES = "H101\tfixture 1\nH102\tfixture 2\nH103\tfixture 3\n"
SEATS = ("builder", "scout", "critic", "architect", "judge")

LINE_RES = [re.compile(p) for p in (
    r"^Conductor bug report \(made by conductor report\)$",
    r"^version: ([0-9]+\.[0-9]+\.[0-9]+|other)$",
    r"^method: (installer|plugin|manual|other), (core|full)$",
    r"^runtime: claude ([0-9]+\.[0-9]+\.[0-9]+|not found|other); codex ([0-9]+\.[0-9]+\.[0-9]+|not found|other); python3 ([0-9]+\.[0-9]+\.[0-9]+|other)$",
    r"^provider: (first-party|bedrock|vertex|foundry|anthropic-aws|mantle|custom-base-url|host-managed|unknown|other)$",
    r"^seats:$",
    r"^- (conductor|builder|scout|critic|architect|judge): (opus|sonnet|haiku|fable|inherit|missing|other), "
    r"((Opus|Sonnet|Haiku|Fable) [0-9]+(\.[0-9]+)?|unknown|not stated|older model|other), (agent file|settings pin|inherited|other)$",
    r"^judge_rung: (1|2|3|other)$",
    r"^hooks: (none|(pointer|nudge|usage-split|project-home|contract)(, (pointer|nudge|usage-split|project-home|contract))*); hooks running: (on|off)$",
    r"^error_codes: (none|[A-Z][0-9]{3}(, [A-Z][0-9]{3})*)$",
    r"^roots: (none|\{claude-dir\}|\{codex-dir\}|\{agents-dir\}|\{claude-dir\}, \{codex-dir\}|\{claude-dir\}, \{agents-dir\}|"
    r"\{codex-dir\}, \{agents-dir\}|\{claude-dir\}, \{codex-dir\}, \{agents-dir\})$",
    r"^counts:$",
    r"^- (core|full|hook_pointer|hook_nudge|hook_usage_split|hook_project_home|hook_contract|other): "
    r"written (other|[0-9]+), kept (other|[0-9]+), modified (other|[0-9]+)$",
    r"^- none recorded$",
    r"^dropped \(looked like a path or a key\): [a-z_]+(, [a-z_]+)*$",
)]


def safe(text):
    return re.sub(r"[^A-Za-z0-9._-]", "_", text)[:40] or "x"


def write(path, data, mode=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(data)
    if mode:
        os.chmod(path, mode)


def seed(claude, bindir, text, token, idx, work=None):
    """Seed 1 canary everywhere into the Claude folder; returns (env additions, cwd)."""
    first = text.split("\n", 1)[0]
    for seat in SEATS:
        if seat == "builder":
            write(os.path.join(claude, "agents", "builder.md"), "---\nname: builder\nmodel: %s\neffort: high\n---\n%s\n" % (first, text))
        elif seat == "critic":
            write(os.path.join(claude, "agents", "critic.md"), "---\nname: critic\nmodel: sonnet\neffort: %s\n---\n%s\n" % (first, text))
        elif seat == "judge":
            write(os.path.join(claude, "agents", "judge.md"), "---\nname: judge\nmodel: %s\n---\n%s\n" % (first, text))
        else:
            write(os.path.join(claude, "agents", seat + ".md"), "---\nname: %s\nmodel: %s\neffort: xhigh\n---\n%s\n" % (seat, "haiku" if seat == "scout" else "opus", text))
    extra = "agents/%s.md" % safe(text)
    write(os.path.join(claude, extra), text + "\n")
    record = {"schema": 1, "product": "conductor", "method": first if idx % 2 == 0 else "installer",
              "version": first if idx % 3 == 0 else "0.4.0", "source_url": text, "installed_at": text,
              "harness": "claude", "components": ["core", first], "launcher": first, "python3": first,
              "judge_rung": first if idx % 2 == 1 else 3,
              "files": [{"dest": extra, "sha256": "0" * 64, "policy": "replace", "component": first, "id": safe(text)},
                        {"dest": "agents/builder.md", "sha256": "0" * 64, "policy": "agent", "component": "core", "id": "agent_builder"},
                        {"dest": text, "sha256": text, "policy": text, "component": "full", "id": text}]}
    write(os.path.join(claude, "conductor", ".install-manifest"), json.dumps(record, indent=2) + "\n", 0o600)
    settings = {"model": text, "effortLevel": text,
                "modelSettings": {"claude-opus-5-5": {"effortLevel": text}, "claude-sonnet-5-5": {"effortLevel": "high"}},
                "env": {"ANTHROPIC_MODEL": text, "CLAUDE_CODE_SUBAGENT_MODEL": text, "ANTHROPIC_DEFAULT_SONNET_MODEL": text,
                        "ANTHROPIC_DEFAULT_HAIKU_MODEL": text},
                "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "%s conductor/hooks/contract-check.py" % text}]}]}}
    write(os.path.join(claude, "settings.json"), json.dumps(settings), 0o600)
    write(os.path.join(claude, "CLAUDE.md"), "%s\n<!-- BEGIN CONDUCTOR (managed) v%s - x -->\n%s\n<!-- END CONDUCTOR (managed) -->\n" % (text, first, text))
    write(os.path.join(claude, "conductor", "defaults.md"), "# defaults\n%s\n" % text)
    write(os.path.join(claude, "conductor", "feedback-codes.txt"), CODES)
    write(os.path.join(claude, "conductor", "logs", "trace.log"), "%s\nH101 %s\n%s H102 H999 %s\n" % (text, text, text, text))
    write(os.path.join(claude, "conductor", "service.env"), "SERVICE_API_KEY=%s\n" % text)
    os.makedirs(bindir, exist_ok=True)
    for tool in ("claude", "codex"):
        write(os.path.join(bindir, tool), "#!/bin/sh\nprintf '%s\\n' \"$FIXTURE_CANARY\"\n", 0o755)
    env = {"FIXTURE_CANARY": text, "ANTHROPIC_DEFAULT_OPUS_MODEL": text, "CLAUDE_CODE_SUBAGENT_MODEL": text,
           "ANTHROPIC_BASE_URL": text}
    if idx % 2 == 0:
        env["CLAUDE_CODE_USE_BEDROCK"] = text
    cwd = None
    if work:
        cwd = os.path.join(work, safe(text) + "-proj")
        write(os.path.join(cwd, ".claude", "settings.json"), json.dumps({"effortLevel": text, "env": {"ANTHROPIC_BASE_URL": text}}))
    return env, cwd


def check_bundle(text, canary, token, forbidden):
    """List of problems with a bundle seeded from 1 canary."""
    bad = []
    if canary in text:
        bad.append("the canary is in the bundle")
    if token in text:
        bad.append("the canary token is in the bundle")
    for ch in "/\\~":
        if ch in text:
            bad.append("path character %r in the bundle" % ch)
    for f in forbidden:
        if f and f in text:
            bad.append("%r is in the bundle" % f)
    for ln in text.rstrip("\n").split("\n"):
        if not any(r.match(ln) for r in LINE_RES):
            bad.append("line outside the bundle grammar: %r" % ln[:60])
    return bad


def run_all(lib, work):
    sys.path.insert(0, lib)
    import doctor  # noqa: E402
    import report  # noqa: E402
    facts = os.path.join(lib, "facts.json")
    cases = canaries.generate()
    assert len(cases) == 150
    failures = 0
    seeded_seen = 0
    for idx, (cat, text, token) in enumerate(cases):
        root = os.path.join(work, "c%03d" % idx)
        claude = os.path.join(root, "home", ".claude")
        bindir = os.path.join(root, "bin")
        env_add, cwd = seed(claude, bindir, text, token, idx, root)
        # positive control: the canary really sits in the seeded config
        body = open(os.path.join(claude, "agents", "builder.md"), encoding="utf-8").read()
        if text in body:
            seeded_seen += 1
        env = {"PATH": bindir + os.pathsep + "/usr/bin:/bin", "HOME": os.path.join(root, "home")}
        env.update(env_add)
        args = argparse.Namespace(self_root="", facts=facts, claude_dir=claude, codex_dir=os.path.join(root, "home", ".codex"),
                                  agents_dir=os.path.join(root, "home", ".agents"), managed_settings=os.path.join(root, "none.json"))
        info = doctor.collect(args, env, cwd)
        bundle, dropped = report.make_bundle(info)
        problems = check_bundle(bundle, text, token, [root, "zqx"])
        if "H101" not in bundle or "H102" not in bundle or "H999" in bundle:
            problems.append("error codes: expected exactly the codes listed in feedback-codes.txt")
        if problems:
            failures += 1
            print("FAILED canary %d (%s): %s" % (idx, cat, "; ".join(problems)))
    print("canaries run: %d; seeded in the config: %d; bundles with a problem: %d" % (len(cases), seeded_seen, failures))
    return 0 if failures == 0 and seeded_seen == 150 else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=("all", "seed", "show"))
    ap.add_argument("--lib", default="")
    ap.add_argument("--work", default="")
    ap.add_argument("--claude", default="")
    ap.add_argument("--bin", default="")
    ap.add_argument("--index", type=int, default=0)
    a = ap.parse_args()
    if a.mode == "all":
        return run_all(a.lib, a.work)
    cat, text, token = canaries.generate()[a.index]
    if a.mode == "show":
        print(text)
        return 0
    env, cwd = seed(a.claude, a.bin, text, token, a.index, a.work or None)
    print(token)
    return 0


if __name__ == "__main__":
    sys.exit(main())
