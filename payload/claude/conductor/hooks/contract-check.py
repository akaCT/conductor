#!/usr/bin/env python3
"""Keyless contract check. No network call, no outside service.

PreToolUse on the Agent and Task tools: a dispatch that names no model and no
pinned agent type gets a soft note naming the missing pin. SubagentStop: a report
from one of Conductor's pinned agent types (builder, scout, critic, architect,
judge) with no STATUS, VERDICT or OUTCOME line (or a top-level "status" JSON key)
gets a soft note. Other agent types, including the host's own helper agents with
an empty agent type, are left alone.

The only deny anywhere in Conductor: PreToolUse, when defaults.md says
`hook_block_mode: on` and the dispatch names no model and no pinned agent type.
Agent types that Claude Code runs on a model it chooses itself (fork,
claude-code-guide, statusline-setup) never need a pin, so a dispatch of one of them
is left alone.
"""
import json
import os
import re
import sys

sys.dont_write_bytecode = True
# python3 runs a hook with -I, which keeps the hook's own folder off sys.path.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import hooklib
except Exception:
    sys.exit(0)

DISPATCH_TOOLS = ("Agent", "Task")
PINNED_AGENTS = ("builder", "scout", "critic", "architect", "judge")
# Agent types Claude Code runs on a model it chooses itself: never in need of a pin.
RUNTIME_TYPES = ("fork", "claude-code-guide", "statusline-setup")
STATUS_RE = re.compile(r"^[\s>*_`#\-]*(STATUS|VERDICT|OUTCOME)\b[\s*_`]*[:=]", re.I | re.M)
FENCE_RE = re.compile(r"```(?:json)?\s*(\{.*?\})\s*```", re.S)


def pinned(ctx, tool_input, cwd):
    """(model_named, agent_pinned) for a dispatch's tool input."""
    model = tool_input.get("model")
    model_named = isinstance(model, str) and bool(model.strip())
    agent_type = tool_input.get("subagent_type")
    agent_pinned = agent_type in RUNTIME_TYPES or hooklib.agent_model(ctx, cwd, agent_type) is not None
    return model_named, agent_pinned


def on_dispatch(ev, ctx):
    if ev.get("tool_name") not in DISPATCH_TOOLS:
        return None
    tin = ev.get("tool_input")
    if not isinstance(tin, dict):
        return None
    model_named, agent_pinned = pinned(ctx, tin, ev.get("cwd"))
    if model_named or agent_pinned:
        return None
    mode = hooklib.defaults_switch(hooklib.defaults_lines(ctx), "hook_block_mode")
    if mode == "on":
        return {"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason":
                "This dispatch names no model and no pinned agent type. "
                "Block mode is on in the Conductor defaults file."}}
    return {"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "additionalContext":
            "This dispatch names no model and no pinned agent type, so the model pin is missing."}}


def report_has_status(message):
    if STATUS_RE.search(message):
        return True
    candidates = [message.strip()] + FENCE_RE.findall(message)
    for c in candidates:
        try:
            data = json.loads(c)
        except Exception:
            continue
        if isinstance(data, dict) and "status" in data:
            return True
    return False


def on_worker_stop(ev, ctx):
    if ev.get("agent_type") not in PINNED_AGENTS:
        return None
    msg = ev.get("last_assistant_message")
    if not isinstance(msg, str):
        return None
    if report_has_status(msg):
        return None
    return hooklib.soft_message(["A worker report ended with no STATUS, VERDICT or OUTCOME line."])


if __name__ == "__main__":
    hooklib.main("contract-check", {"PreToolUse": on_dispatch, "SubagentStop": on_worker_stop})
