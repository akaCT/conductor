#!/usr/bin/env python3
"""gen-transcript.py SPEC.json OUT: write a JSONL transcript from a spec. Test fixture helper.

A spec is a list of items; "ago" is how long before now (for example 90m, 3h, 2d):
  {"type": "user", "ago": "3h", "text": "hello"}
  {"type": "tool_result", "ago": "3h"}
  {"type": "assistant", "ago": "30m", "usage": [in, cache_creation, cache_read, out],
   "tools": [{"name": "Bash", "input": {}}], "text": "reply"}
  {"type": "repeat", "n": 12, "item": {...}}
  {"type": "pad", "bytes": 7000000}
"""
import json
import sys
import time


def secs(ago):
    unit = {"s": 1, "m": 60, "h": 3600, "d": 86400}[ago[-1]]
    return int(ago[:-1]) * unit


def stamp(ago):
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() - secs(ago)))


def expand(items):
    for it in items:
        if it["type"] == "repeat":
            for _ in range(it["n"]):
                yield it["item"]
        else:
            yield it


def entry(it, n):
    t = it["type"]
    ts = stamp(it.get("ago", "1m"))
    if t == "user":
        return {"type": "user", "timestamp": ts, "uuid": "u%d" % n,
                "message": {"role": "user", "content": it.get("text", "go")}}
    if t == "tool_result":
        return {"type": "user", "timestamp": ts, "uuid": "r%d" % n,
                "message": {"role": "user", "content": [
                    {"type": "tool_result", "tool_use_id": "t%d" % n, "content": "ok"}]}}
    if t == "assistant":
        content = []
        if it.get("text"):
            content.append({"type": "text", "text": it["text"]})
        for k, tool in enumerate(it.get("tools", [])):
            content.append({"type": "tool_use", "id": "t%d_%d" % (n, k),
                            "name": tool["name"], "input": tool.get("input", {})})
        msg = {"role": "assistant", "content": content}
        if "usage" in it:
            a, b, c, d = it["usage"]
            msg["usage"] = {"input_tokens": a, "cache_creation_input_tokens": b,
                            "cache_read_input_tokens": c, "output_tokens": d}
        return {"type": "assistant", "timestamp": ts, "uuid": "a%d" % n, "message": msg}
    raise SystemExit("unknown item type %s" % t)


def main():
    spec = json.load(open(sys.argv[1]))
    with open(sys.argv[2], "w") as out:
        n = 0
        for it in expand(spec):
            if it["type"] == "pad":
                written = 0
                blob = "x" * 4000
                while written < it["bytes"]:
                    line = json.dumps({"type": "summary", "note": blob}) + "\n"
                    out.write(line)
                    written += len(line)
                continue
            n += 1
            out.write(json.dumps(entry(it, n)) + "\n")


if __name__ == "__main__":
    main()
