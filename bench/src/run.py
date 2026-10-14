#!/usr/bin/env python3
"""Conductor bench runner (track T-1, REQ-EVAL-001).

Runs every task in 3 arms and writes a run record:

  a  without Conductor
  b  with Conductor at default effort (installed with the effort pins declined)
  c  with Conductor and the effort pins

Each run is 1 `claude -p --output-format stream-json --verbose` call. Its raw
stream is kept under results/raw/<run id>/ with 1 extra last line, a
bench_outcome line, that holds the task, arm, run number and pass/fail result,
so the file alone is enough for rederive.py. At the end the runner writes
results/RUN-<run id>.json and the rendered results/RUN-<run id>.md.

Env vars:
  BENCH_MOCK=1          synthesize every run, call nothing, install nothing.
                        Every record and page it writes starts with MOCK DATA.
  RUNS                  runs per task per arm (default 3)
  BENCH_TASKS           comma separated task ids or id prefixes (t1,t7) for a
                        smoke run; the default is every task
  BENCH_MODEL           the model id passed to --model on every arm. Required in
                        real mode, no default there (mock default: claude-sonnet-5-5)
  BENCH_CONFIG_DIR      real mode only, required: the signed-in Claude Code
                        config folder the runs use. No default.
  BENCH_ALLOW_DEFAULT=1 lets BENCH_CONFIG_DIR be ~/.claude, your default profile
  BENCH_TASK_TIMEOUT_S  per run limit in seconds (default 300); a run that hits
                        it is an error
  BENCH_RESULTS_DIR     where results go (default bench/results)
  BENCH_INSTALLER       the install.sh to use for arms b and c (default: this
                        repo's install.sh)
  BENCH_RUN_ID          fix the run id (default: UTC time and 4 random hex)
  BENCH_PERMISSION_MODE claude --permission-mode (default acceptEdits)
  BENCH_ALLOWED_TOOLS   claude --allowedTools (default Bash,Edit,Write)

Real mode never reads, prints or copies a credential file: it only checks that
a sign-in record exists. Before any claude run it asks the installer's dry run
whether arm c can be pinned. Claude and the installer get an environment built
from an allowlist (ENV_ALLOWLIST), not the whole shell. Real mode installs into
the config folder for arms b and c and uninstalls afterward, also when a run
fails or is interrupted. A failed uninstall stops the run and marks the record
INVALID RUN. At the end it checks that settings.json and CLAUDE.md came back
byte for byte and that no Conductor install is left.

Stdlib only.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import report

BENCH_DIR = report.BENCH_DIR
TASKS_DIR = report.TASKS_DIR
CONDUCTOR_ROOT = BENCH_DIR.parent
INSTALLER = Path(os.environ.get("BENCH_INSTALLER") or (CONDUCTOR_ROOT / "install.sh"))
ARMS = report.ARMS
CHECK_FILES = ("check.py", "check.sh")
# The only variables claude and the installer inherit from the shell. The runs
# also get CLAUDE_CONFIG_DIR (and the installer its own folder variables).
ENV_ALLOWLIST = ("PATH", "HOME", "LANG", "TERM", "TMPDIR", "USER", "SHELL")
EFFORT_ENV = "CLAUDE_CODE_EFFORT_LEVEL"
# The line the installer's dry run prints for a pin it would write.
WOULD_PIN = "would offer: Set "
MOCK_DEFAULT_MODEL = "claude-sonnet-5-5"


class RunnerError(Exception):
    pass


def discover_tasks() -> list:
    if not TASKS_DIR.is_dir():
        return []
    ids = [
        p.name for p in TASKS_DIR.iterdir() if p.is_dir() and (p / "meta.json").is_file()
    ]
    return sorted(ids, key=report.task_key)


def load_meta(task_id: str) -> dict:
    return json.loads((TASKS_DIR / task_id / "meta.json").read_text())


def select_tasks() -> tuple:
    """(task ids to run, not_run list). BENCH_TASKS narrows the set for a smoke run."""
    all_ids = discover_tasks()
    spec = os.environ.get("BENCH_TASKS", "").strip()
    if not spec:
        return all_ids, []
    wanted = []
    for tok in spec.split(","):
        tok = tok.strip()
        if not tok:
            continue
        found = [t for t in all_ids if t == tok or t.startswith(tok + "_")]
        if len(found) != 1:
            raise RunnerError(
                "BENCH_TASKS names '%s', which matches %d tasks (need exactly 1). "
                "Task ids: %s" % (tok, len(found), ", ".join(all_ids))
            )
        if found[0] not in wanted:
            wanted.append(found[0])
    not_run = [
        {"task_id": t, "reason": "not in BENCH_TASKS (smoke subset)"}
        for t in all_ids
        if t not in wanted
    ]
    return sorted(wanted, key=report.task_key), not_run


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def make_run_id(mock: bool) -> str:
    return "%s-%s-%s" % (
        utc_now().strftime("%Y%m%dT%H%M%SZ"),
        "mock" if mock else "real",
        uuid.uuid4().hex[:4],
    )


def write_raw(path: Path, stream_text: str, outcome: dict) -> None:
    if stream_text and not stream_text.endswith("\n"):
        stream_text += "\n"
    with open(path, "w") as f:
        f.write(stream_text)
        f.write(json.dumps(outcome, sort_keys=True) + "\n")


def raw_name(task_id: str, arm: str, run_n: int) -> str:
    return "%s__%s__%d.jsonl" % (task_id, arm, run_n)


# ---------------------------------------------------------------------------
# Mock mode: a synthetic stream per run, deterministic from task, arm and run.
# ---------------------------------------------------------------------------


def _seeded(seed_text: str, low: float, high: float) -> float:
    digest = hashlib.sha256(seed_text.encode("utf-8")).hexdigest()
    frac = int(digest[:8], 16) / 0xFFFFFFFF
    return low + frac * (high - low)


def synth_mock(task_id: str, category: str, arm: str, run_n: int, model: str, price_table: dict):
    """Returns (stream_text, outcome dict). No claude call happens."""
    # Every arm gets the same draws (the seed leaves the arm out), so a mock page
    # can never show a difference between arms. Only the session id names the arm.
    seed = "%s:%d" % (task_id, run_n)
    delegating = category == "multifile_delegation"
    sid = "mock-" + hashlib.sha256(("%s:%s" % (arm, seed)).encode()).hexdigest()[:12]
    n_top = int(_seeded(seed + ":top", 5, 15)) if delegating else int(_seeded(seed + ":top", 2, 8))
    lo, hi = (0, 2) if delegating else (0, 1)
    disp = min(int(_seeded(seed + ":disp", lo, hi + 1)), max(n_top - 1, 0))
    disp_at = [1 + 2 * i for i in range(disp)]
    names = ["Read", "Glob", "Grep", "Bash", "Edit", "Write"]

    ev = [{"type": "system", "subtype": "init", "session_id": sid, "model": model, "mock": True}]
    for i in range(n_top):
        name = "Agent" if i in disp_at else names[int(_seeded(seed + ":n%d" % i, 0, len(names)))]
        tid = "toolu_%s_%d" % (sid, i)
        ev.append(
            {
                "type": "assistant",
                "message": {
                    "id": "msg_%s_%d" % (sid, i),
                    "role": "assistant",
                    "content": [{"type": "tool_use", "id": tid, "name": name, "input": {}}],
                },
                "parent_tool_use_id": None,
                "session_id": sid,
            }
        )
        if name == "Agent":
            for j in range(2 + (i % 2)):
                ev.append(
                    {
                        "type": "assistant",
                        "message": {
                            "id": "msg_%s_%d_%d" % (sid, i, j),
                            "role": "assistant",
                            "content": [
                                {"type": "tool_use", "id": "%s_n%d" % (tid, j), "name": names[j], "input": {}}
                            ],
                        },
                        "parent_tool_use_id": tid,
                        "session_id": sid,
                    }
                )
        ev.append(
            {
                "type": "user",
                "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tid, "content": "ok"}]},
                "parent_tool_use_id": None,
                "session_id": sid,
            }
        )

    wall = round(_seeded(seed + ":wall", 8, 45), 1)
    is_error = _seeded(seed + ":err", 0, 1) < 0.05
    passed = _seeded(seed + ":pass", 0, 1) < 0.85
    if is_error:
        outcome = "error"
    else:
        outcome = "passed" if passed else "failed"
        total_in = int(_seeded(seed + ":in", 1200, 4200))
        total_out = int(_seeded(seed + ":out", 400, 1600))
        cache_r = int(_seeded(seed + ":cr", 0, 2000))
        cache_w = int(_seeded(seed + ":cc", 0, 500))
        parts = [(model, 0.5), ("claude-haiku-5-5", 0.3), ("claude-opus-5-5", 0.2)]
        usage = {}
        for mid, share in parts:
            u = usage.setdefault(
                mid, {"inputTokens": 0, "outputTokens": 0, "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0}
            )
            u["inputTokens"] += int(total_in * share)
            u["outputTokens"] += int(total_out * share)
            u["cacheReadInputTokens"] += int(cache_r * share)
            u["cacheCreationInputTokens"] += int(cache_w * share)
        result = {
            "type": "result",
            "subtype": "success",
            "is_error": False,
            "duration_ms": int(wall * 1000),
            "num_turns": n_top + 1,
            "result": "[mock] synthesized reply for %s/%s/run%d" % (task_id, arm, run_n),
            "session_id": sid,
            "usage": {
                "input_tokens": total_in,
                "output_tokens": total_out,
                "cache_read_input_tokens": cache_r,
                "cache_creation_input_tokens": cache_w,
            },
            "modelUsage": usage,
        }
        result["total_cost_usd"] = report.usage_figures(result, price_table)["cost_usd"]
        ev.append(result)
    oc = {
        "type": "bench_outcome",
        "schema": 1,
        "task_id": task_id,
        "arm": arm,
        "run": run_n,
        "outcome": outcome,
        "mock": True,
        "claude_rc": None,
        "wall_time_s": wall,
        "detail": "synthesized by BENCH_MOCK=1",
    }
    return "\n".join(json.dumps(e, sort_keys=True) for e in ev) + "\n", oc


# ---------------------------------------------------------------------------
# Real mode: preflight, install and uninstall, a single claude run.
# ---------------------------------------------------------------------------


def conductor_installed(cfg: Path) -> list:
    """The signs of a Conductor install in the folder: the install record, the
    skill and the payload folders (the uninstall keeps conductor/backups and
    conductor/defaults.md on purpose, so those are not signs), and the doctrine
    marker line of CLAUDE.md."""
    signs = []
    for rel in ("conductor/.install-manifest", "skills/conductor/.install-manifest", "skills/conductor/SKILL.md"):
        if (cfg / rel).is_file():
            signs.append(rel)
    for rel in ("skills/conductor", "conductor/bin", "conductor/lib", "conductor/runbooks", "conductor/templates"):
        if (cfg / rel).is_dir():
            signs.append(rel + "/")
    md = cfg / "CLAUDE.md"
    if md.is_file():
        try:
            for line in md.read_text(errors="replace").splitlines():
                if line.startswith("<!-- BEGIN CONDUCTOR (managed)"):
                    signs.append("CLAUDE.md doctrine block")
                    break
        except OSError:
            pass
    return signs


def effort_in_settings(path: Path) -> list:
    """Where settings.json sets an effort level, as dotted paths: a top-level
    effortLevel, modelSettings.<model>.effortLevel and env.CLAUDE_CODE_EFFORT_LEVEL.
    Reads the parsed file, so a note that only mentions the word counts for
    nothing. Raises ValueError when the file does not parse."""
    if not path.is_file():
        return []
    data = json.loads(path.read_text())
    found = []
    if isinstance(data, dict):
        if "effortLevel" in data:
            found.append("effortLevel")
        models = data.get("modelSettings")
        if isinstance(models, dict):
            for name in sorted(models):
                if isinstance(models[name], dict) and "effortLevel" in models[name]:
                    found.append("modelSettings.%s.effortLevel" % name)
        env = data.get("env")
        if isinstance(env, dict) and str(env.get(EFFORT_ENV, "")) != "":
            found.append("env." + EFFORT_ENV)
    return found


def relevant_lines(text: str) -> str:
    """The lines of an installer's output that say why it would write no pin."""
    keys = ("effort pin", "BASE_URL", "provider", "not usable", "Claude Code version")
    lines = [ln.strip(" \t•!") for ln in text.splitlines() if any(k in ln for k in keys)]
    return " | ".join(lines)[:700] if lines else text[-400:].strip()


def preflight_pins(cfg: Path) -> None:
    """Arm c cannot run without an effort pin. Ask the installer's dry run, in
    this folder and with the environment the real installs get, before any
    claude run. A dry run changes nothing."""
    with tempfile.TemporaryDirectory(prefix="bench-dry-") as stub:
        try:
            proc = run_installer(cfg, Path(stub), ["--dry-run", "--core", "--apply-effort-pins"])
        except (OSError, subprocess.SubprocessError) as e:
            raise RunnerError("the installer's dry run could not run (%s). Nothing was run." % e)
    out = proc.stdout + proc.stderr
    if proc.returncode == 0 and WOULD_PIN in out:
        return
    exited = "" if proc.returncode == 0 else " (it exited %d)" % proc.returncode
    raise RunnerError(
        "arm c needs the effort pins, but the installer's dry run with --apply-effort-pins%s "
        "would write none in BENCH_CONFIG_DIR (an old Claude Code, another provider or address, "
        "or no python3). What it said: %s Nothing was run." % (exited, relevant_lines(out).rstrip(".") + ".")
    )


def preflight_real() -> Path:
    raw = os.environ.get("BENCH_CONFIG_DIR", "").strip()
    if not raw:
        raise RunnerError(
            "BENCH_CONFIG_DIR is required for a real run: the signed-in Claude Code "
            "config folder the runs use. There is no default. Nothing was run."
        )
    if not os.path.isabs(raw):
        raise RunnerError("BENCH_CONFIG_DIR must be an absolute path (got: %s)" % raw)
    cfg = Path(raw)
    if not cfg.is_dir():
        raise RunnerError("BENCH_CONFIG_DIR is not a folder: %s" % raw)
    default = os.path.realpath(os.path.join(os.path.expanduser("~"), ".claude"))
    if os.path.realpath(raw) == default and os.environ.get("BENCH_ALLOW_DEFAULT") != "1":
        raise RunnerError(
            "BENCH_CONFIG_DIR is your default profile (~/.claude). The bench installs and "
            "removes Conductor in the folder it runs in; use a separate signed-in folder, "
            "or set BENCH_ALLOW_DEFAULT=1 if you mean it. Nothing was run."
        )
    # Existence only: the runner never opens a credential file.
    if not ((cfg / ".credentials.json").is_file() or (cfg / ".claude.json").is_file()):
        raise RunnerError(
            "BENCH_CONFIG_DIR has no sign-in record (no .credentials.json and no .claude.json). "
            "Sign in once with CLAUDE_CONFIG_DIR=<folder> claude, then rerun. "
            "The runner checks that the file exists and never opens it."
        )
    signs = conductor_installed(cfg)
    if signs:
        raise RunnerError(
            "Conductor is installed in BENCH_CONFIG_DIR (%s). Arm a needs a folder without "
            "Conductor, and arms b and c install and remove it. Uninstall it first with "
            "CLAUDE_DIR=<folder> bash install.sh --uninstall, or use another folder. "
            "Nothing was run." % ", ".join(signs)
        )
    try:
        held = effort_in_settings(cfg / "settings.json")
    except (OSError, ValueError) as e:
        raise RunnerError(
            "settings.json in BENCH_CONFIG_DIR does not parse (%s), so the runner cannot tell "
            "whether it sets an effort level. Fix or move it. Nothing was run." % e
        )
    if held:
        raise RunnerError(
            "settings.json in BENCH_CONFIG_DIR already sets an effort level (%s), so arms a and b "
            "would not run at default effort. Use a folder without such a setting. Nothing was run."
            % ", ".join(held)
        )
    if os.environ.get(EFFORT_ENV):
        raise RunnerError(
            "%s is set in the environment, so arms a and b would not run at default effort. "
            "Unset it and rerun. Nothing was run." % EFFORT_ENV
        )
    if shutil.which("claude") is None:
        raise RunnerError("claude is not on PATH. Nothing was run.")
    if not INSTALLER.is_file():
        raise RunnerError("installer not found: %s" % INSTALLER)
    preflight_pins(cfg)
    return cfg


def allowlisted_env() -> dict:
    """The shell variables a child may inherit: ENV_ALLOWLIST and nothing else, so
    a token exported in the shell never reaches the model's Bash tool."""
    return {k: os.environ[k] for k in ENV_ALLOWLIST if k in os.environ}


def installer_env(cfg: Path, stub: Path) -> dict:
    env = allowlisted_env()
    env["CLAUDE_DIR"] = str(cfg)
    env["CLAUDE_CONFIG_DIR"] = str(cfg)
    # No Codex folder exists at these paths, so the installer skips Codex.
    env["CODEX_DIR"] = str(stub / "codex")
    env["CODEX_HOME"] = str(stub / "codex")
    env["AGENTS_SKILLS_DIR"] = str(stub / "agents")
    env["CONDUCTOR_YES"] = "1"
    return env


def run_installer(cfg: Path, stub: Path, args: list) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["/bin/bash", str(INSTALLER)] + args,
        env=installer_env(cfg, stub),
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=180,
    )


def install_arm(cfg: Path, stub: Path, arm: str) -> None:
    args = ["--core"] + (["--apply-effort-pins"] if arm == "c" else [])
    proc = run_installer(cfg, stub, args)
    if proc.returncode != 0:
        raise RunnerError(
            "the installer failed for arm %s (rc %d): %s"
            % (arm, proc.returncode, (proc.stdout + proc.stderr)[-600:])
        )
    try:
        has_pin = bool(effort_in_settings(cfg / "settings.json"))
    except (OSError, ValueError) as e:
        raise RunnerError("settings.json in the folder does not parse after the install (%s)" % e)
    if arm == "c" and not has_pin:
        raise RunnerError(
            "arm c needs the effort pins, but the installer wrote none (an old Claude Code, "
            "another provider, or no python3). Its output: %s" % (proc.stdout + proc.stderr)[-600:]
        )
    if arm == "b" and has_pin:
        raise RunnerError("arm b must run with the effort pins declined, but settings.json holds an effortLevel")


def uninstall_arm(cfg: Path, stub: Path) -> str:
    """Uninstall Conductor from the folder. Returns "" when it ran clean and left
    nothing, else what went wrong."""
    try:
        proc = run_installer(cfg, stub, ["--uninstall"])
    except (OSError, subprocess.SubprocessError) as e:
        return "the uninstaller could not run: %s" % e
    if proc.returncode != 0:
        return "the uninstaller exited %d: %s" % (proc.returncode, (proc.stdout + proc.stderr)[-400:].strip())
    left = conductor_installed(cfg)
    if left:
        return "Conductor is still in the folder after the uninstall (%s)" % ", ".join(left)
    return ""


def make_backup(cfg: Path, results: Path, run_id: str) -> tuple:
    """Copy settings.json and CLAUDE.md to a private backup folder under the
    results folder. Returns (backup dir, {name: existed})."""
    bdir = results / ("backup-" + run_id)
    bdir.mkdir(parents=True, exist_ok=True)
    os.chmod(bdir, 0o700)
    existed = {}
    for name in ("settings.json", "CLAUDE.md"):
        src = cfg / name
        existed[name] = src.is_file()
        if existed[name]:
            # Created mode 600, so the copy is never readable by others, not even briefly.
            fd = os.open(str(bdir / name), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "wb") as f:
                f.write(src.read_bytes())
            os.chmod(bdir / name, 0o600)
    return bdir, existed


def check_restore(cfg: Path, bdir: Path, existed: dict) -> dict:
    problems = []
    for name, was in sorted(existed.items()):
        cur = cfg / name
        if was:
            if not cur.is_file():
                problems.append("%s is missing after the run" % name)
            elif cur.read_bytes() != (bdir / name).read_bytes():
                note = ""
                if name.endswith(".json"):
                    try:
                        same = json.loads(cur.read_bytes()) == json.loads((bdir / name).read_bytes())
                    except ValueError:
                        same = False
                    note = " (same JSON content, different formatting)" if same else ""
                problems.append("%s differs from its backup%s" % (name, note))
        elif cur.exists():
            problems.append("%s did not exist before the run and exists now" % name)
    left = conductor_installed(cfg)
    if left:
        problems.append("Conductor is still in the folder after the run (%s)" % ", ".join(left))
    if problems:
        detail = "; ".join(problems) + " (backup kept in " + bdir.name + ")"
        print("FAIL restore check: " + detail)
        return {"checked": True, "ok": False, "detail": detail}
    print("restore check: settings.json and CLAUDE.md are back byte for byte and no Conductor install is left")
    return {"checked": True, "ok": True, "detail": "settings.json and CLAUDE.md match their backups and no Conductor install is left"}


def check_cmd(success_cmd: str) -> list:
    """The task's success check as an argument list. A python check runs in
    isolated mode (-I): the work folder the model wrote into is not on its
    import path, so a planted module there cannot stand in for a standard one."""
    cmd = shlex.split(success_cmd)
    if cmd and os.path.basename(cmd[0]) in ("python3", "python"):
        cmd = [cmd[0], "-I"] + cmd[1:]
    return cmd


def claude_has_strict_mcp() -> bool:
    """True when this claude's help lists --strict-mcp-config."""
    try:
        p = subprocess.run(
            ["claude", "--help"],
            env=allowlisted_env(),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return "--strict-mcp-config" in (p.stdout + p.stderr)


def claude_cmd(model: str, strict_mcp: bool = False) -> list:
    """The claude command. With strict_mcp, the account's own MCP servers are
    left out: --strict-mcp-config with an empty --mcp-config."""
    cmd = [
        "claude",
        "-p",
        "--model",
        model,
        "--output-format",
        "stream-json",
        "--verbose",
        "--permission-mode",
        os.environ.get("BENCH_PERMISSION_MODE", "acceptEdits"),
        "--allowedTools",
        os.environ.get("BENCH_ALLOWED_TOOLS", "Bash,Edit,Write"),
        "--disallowedTools",
        "WebFetch,WebSearch",
    ]
    if strict_mcp:
        cmd += ["--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}']
    return cmd


def kill_group(proc: subprocess.Popen) -> None:
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (OSError, ProcessLookupError):
        try:
            proc.kill()
        except OSError:
            pass


def run_real_one(cfg: Path, task_id: str, arm: str, run_n: int, model: str, timeout_s: int, strict_mcp: bool = False) -> tuple:
    """A single claude run and its check. Returns (stream_text, outcome dict)."""
    task_dir = TASKS_DIR / task_id
    meta = load_meta(task_id)
    prompt = (task_dir / "prompt.md").read_text()
    env = allowlisted_env()
    env["CLAUDE_CONFIG_DIR"] = str(cfg)
    with tempfile.TemporaryDirectory(prefix="bench-task-") as tmp:
        work = Path(tmp)
        # The check scripts stay out of the model's folder until the run ends.
        for item in task_dir.iterdir():
            if item.name in ("meta.json", "prompt.md") or item.name in CHECK_FILES:
                continue
            dest = work / item.name
            if item.is_dir():
                shutil.copytree(item, dest)
            else:
                shutil.copy2(item, dest)
        started = time.time()
        proc = subprocess.Popen(
            claude_cmd(model, strict_mcp),
            cwd=str(work),
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        timed_out = False
        try:
            out, err = proc.communicate(input=prompt, timeout=timeout_s)
        except subprocess.TimeoutExpired:
            timed_out = True
            kill_group(proc)
            out, err = proc.communicate()
        except BaseException:
            kill_group(proc)
            raise
        wall = round(time.time() - started, 1)
        rc = proc.returncode
        parsed = report.parse_stream(out.splitlines())
        result = parsed["result"]
        outcome = "error"
        detail = ""
        if timed_out:
            detail = "timed out after %ds" % timeout_s
        elif rc != 0:
            detail = "claude exited %d: %s" % (rc, (err or "")[-300:].strip())
        elif result is None:
            detail = "no result event in the stream"
        elif result.get("is_error"):
            detail = "result is an error (%s)" % result.get("subtype", "unknown")
        else:
            for name in CHECK_FILES:
                if (task_dir / name).is_file():
                    shutil.copy2(task_dir / name, work / name)
            cmd = check_cmd(meta["success_cmd"])
            reply_path = None
            try:
                if meta.get("needs_reply_file"):
                    fd, reply_path = tempfile.mkstemp(prefix="bench-reply-")
                    with os.fdopen(fd, "w") as rf:
                        rf.write(str(result.get("result", "")))
                    cmd = cmd + [reply_path]
                try:
                    chk = subprocess.run(cmd, cwd=str(work), capture_output=True, text=True, timeout=60)
                    outcome = "passed" if chk.returncode == 0 else "failed"
                    detail = (chk.stdout + chk.stderr)[-300:].strip()
                except subprocess.TimeoutExpired:
                    outcome = "failed"
                    detail = "the check timed out"
            finally:
                if reply_path and os.path.exists(reply_path):
                    os.remove(reply_path)
    oc = {
        "type": "bench_outcome",
        "schema": 1,
        "task_id": task_id,
        "arm": arm,
        "run": run_n,
        "outcome": outcome,
        "mock": False,
        "claude_rc": None if timed_out else rc,
        "wall_time_s": wall,
        "detail": detail,
    }
    return out, oc


def claude_version() -> str:
    try:
        p = subprocess.run(["claude", "--version"], env=allowlisted_env(), stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
        return (p.stdout or p.stderr).strip().splitlines()[0] if (p.stdout or p.stderr).strip() else "unknown"
    except (OSError, subprocess.SubprocessError):
        return "unknown"


def conductor_version() -> str:
    try:
        return json.loads((CONDUCTOR_ROOT / "payload" / "components.json").read_text())["version"]
    except (OSError, ValueError, KeyError):
        return "unknown"


def repo_commit() -> str:
    """The commit of the checkout the bench runs from (it binds a record to the
    release it measures), or unknown outside a git checkout."""
    try:
        p = subprocess.run(
            ["git", "-C", str(CONDUCTOR_ROOT), "rev-parse", "HEAD"],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    out = p.stdout.strip()
    return out if p.returncode == 0 and re.fullmatch(r"[0-9a-f]{40}", out) else "unknown"


def installer_sha256() -> str:
    try:
        return hashlib.sha256(INSTALLER.read_bytes()).hexdigest()
    except OSError:
        return "unknown"


# ---------------------------------------------------------------------------
# The run.
# ---------------------------------------------------------------------------


_SAVED_SIGNALS = {}


def cleanup_signals() -> None:
    """Ignore the stop signals while the uninstall and the restore check run."""
    for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        _SAVED_SIGNALS[s] = signal.getsignal(s)
        signal.signal(s, signal.SIG_IGN)


def restore_signals() -> None:
    for s, handler in _SAVED_SIGNALS.items():
        if handler is not None:
            signal.signal(s, handler)
    _SAVED_SIGNALS.clear()


def raise_exit(code: int):
    def handler(signum, frame):
        raise SystemExit(code)

    return handler


def run_arms(*, mock, tasks, runs, model, timeout_s, raw_dir, price_table, cfg, stub, strict_mcp=False):
    """Run every arm. Returns the list of uninstall problems; a failed uninstall
    stops the run there, because the next arm would start in a folder that still
    holds Conductor."""
    total = len(tasks) * len(ARMS) * runs
    done = 0
    problems = []
    for arm in ARMS:
        installed = False
        try:
            if not mock and arm in ("b", "c"):
                installed = True
                print("[run.py] installing Conductor for arm %s (%s)" % (arm, "effort pins accepted" if arm == "c" else "effort pins declined"))
                install_arm(cfg, stub, arm)
            for run_n in range(1, runs + 1):
                for task_id in tasks:
                    if mock:
                        text, oc = synth_mock(
                            task_id, load_meta(task_id).get("category", ""), arm, run_n, model, price_table
                        )
                    else:
                        text, oc = run_real_one(cfg, task_id, arm, run_n, model, timeout_s, strict_mcp)
                    write_raw(raw_dir / raw_name(task_id, arm, run_n), text, oc)
                    done += 1
                    print("[run.py] (%d/%d) %s arm %s run %d -> %s" % (done, total, task_id, arm, run_n, oc["outcome"]))
        finally:
            if installed:
                cleanup_signals()
                print("[run.py] uninstalling Conductor (arm %s)" % arm)
                problem = uninstall_arm(cfg, stub)
                restore_signals()
                if problem:
                    problems.append("arm %s: %s" % (arm, problem))
                    print(
                        "FATAL: the uninstall failed for arm %s: %s\n"
                        "  Conductor may still be installed in %s. Remove it with:\n"
                        "  CLAUDE_DIR=%s bash %s --uninstall\n"
                        "  The run stops here and its figures are not valid."
                        % (arm, problem, shlex.quote(str(cfg)), shlex.quote(str(cfg)), shlex.quote(str(INSTALLER))),
                        file=sys.stderr,
                    )
        if problems:
            break
    return problems


def main() -> int:
    mock = os.environ.get("BENCH_MOCK", "0") == "1"
    try:
        runs = int(os.environ.get("RUNS", "3"))
        timeout_s = int(os.environ.get("BENCH_TASK_TIMEOUT_S", "300"))
        if runs < 1 or timeout_s < 1:
            raise ValueError
    except ValueError:
        print("FATAL: RUNS and BENCH_TASK_TIMEOUT_S must be whole numbers of 1 or more.", file=sys.stderr)
        return 2
    model = os.environ.get("BENCH_MODEL", "").strip()
    if not model:
        if not mock:
            print(
                "FATAL: BENCH_MODEL is required for a real run, and there is no default: the same "
                "--model must be passed on every arm, or the arms are not comparable.",
                file=sys.stderr,
            )
            return 2
        model = MOCK_DEFAULT_MODEL
    signal.signal(signal.SIGTERM, raise_exit(143))
    signal.signal(signal.SIGHUP, raise_exit(129))
    try:
        tasks, not_run = select_tasks()
        if not tasks:
            raise RunnerError("no tasks found under %s" % TASKS_DIR)
        cfg = None if mock else preflight_real()
    except RunnerError as e:
        print("FATAL: %s" % e, file=sys.stderr)
        return 2

    results = report.results_dir()
    run_id = os.environ.get("BENCH_RUN_ID", "").strip() or make_run_id(mock)
    raw_dir = results / "raw" / run_id
    if raw_dir.exists() and any(raw_dir.iterdir()):
        print("FATAL: %s already holds a run; pick another BENCH_RUN_ID" % raw_dir, file=sys.stderr)
        return 2
    raw_dir.mkdir(parents=True, exist_ok=True)
    price_table = report.load_prices()
    print(
        "[run.py] run %s mode=%s tasks=%d arms=%d runs=%d model=%s"
        % (run_id, "MOCK" if mock else "REAL", len(tasks), len(ARMS), runs, model)
    )

    restore = {"checked": False, "ok": None, "detail": "mock run: nothing was installed"}
    env_info = {
        "python": "%d.%d.%d" % sys.version_info[:3],
        "arm_order": "a, b, c",
        "bench_version": report.BENCH_VERSION,
        "commit": repo_commit(),
        "conductor_version": conductor_version(),
    }
    stub = None
    bdir = None
    existed = {}
    strict_mcp = False
    uninstall_problems = []
    rc = 0
    try:
        if not mock:
            stub = Path(tempfile.mkdtemp(prefix="bench-stub-"))
            bdir, existed = make_backup(cfg, results, run_id)
            strict_mcp = claude_has_strict_mcp()
            env_info.update(
                {
                    "claude_version": claude_version(),
                    "installer": "install.sh --core (arm c adds --apply-effort-pins), non-interactive",
                    "installer_sha256": installer_sha256(),
                    "permission_mode": os.environ.get("BENCH_PERMISSION_MODE", "acceptEdits"),
                    "allowed_tools": os.environ.get("BENCH_ALLOWED_TOOLS", "Bash,Edit,Write"),
                    "disallowed_tools": "WebFetch,WebSearch",
                    "task_timeout_s": timeout_s,
                    "config_dir_has_claude_md": existed.get("CLAUDE.md", False),
                    "env_allowlist": ", ".join(ENV_ALLOWLIST) + ", CLAUDE_CONFIG_DIR",
                    "strict_mcp_config": (
                        "used, with an empty MCP config (the account's MCP servers are left out)"
                        if strict_mcp
                        else "not available: this claude's help does not list --strict-mcp-config, "
                        "so the arms may see the account's MCP servers"
                    ),
                }
            )
            if existed.get("CLAUDE.md"):
                print(
                    "[run.py] note: the config folder has its own CLAUDE.md; arm a runs with it, "
                    "so arm a is only 'without Conductor' if that file holds no delegation rules"
                )
        else:
            env_info.update({"claude_version": "mock", "installer_sha256": "not used (a mock run installs nothing)"})
        uninstall_problems = run_arms(
            mock=mock,
            tasks=tasks,
            runs=runs,
            model=model,
            timeout_s=timeout_s,
            raw_dir=raw_dir,
            price_table=price_table,
            cfg=cfg,
            stub=stub,
            strict_mcp=strict_mcp,
        )
        completed = True
    except RunnerError as e:
        print("FATAL: %s" % e, file=sys.stderr)
        rc = 1
        completed = False
    except KeyboardInterrupt:
        print("[run.py] interrupted; no record written, raw streams kept in %s" % raw_dir)
        rc = 130
        completed = False
    except SystemExit as e:
        print("[run.py] terminated; no record written, raw streams kept in %s" % raw_dir)
        rc = e.code if isinstance(e.code, int) else 1
        completed = False
    finally:
        if not mock and cfg is not None and bdir is not None:
            cleanup_signals()
            restore = check_restore(cfg, bdir, existed)
        if stub is not None:
            shutil.rmtree(stub, ignore_errors=True)
    if not completed:
        return rc
    if restore.get("checked") and not restore["ok"]:
        rc = 1
    if uninstall_problems:
        rc = 1

    task_set = report.describe_tasks(tasks)
    rec = report.build_record(
        run_id=run_id,
        created_utc=utc_now().strftime("%Y-%m-%d %H:%M:%S"),
        model=model,
        raw_dir=raw_dir,
        task_set=task_set,
        not_run=not_run,
        price_table=price_table,
        environment=env_info,
        restore_check=restore,
        invalid_reasons=uninstall_problems,
    )
    jpath, mpath = report.write_record(rec, results)
    print("[run.py] wrote %s" % jpath)
    print("[run.py] wrote %s" % mpath)
    for label in rec["labels"]:
        print("[run.py] %s" % label)
    return rc


if __name__ == "__main__":
    sys.exit(main())
