#!/usr/bin/env python3
"""Fixture helper for tests/test-report.sh: describes a prefilled issue address.

  urlcheck.py URL_FILE [BODY_FILE]     prints key=value lines; body_equal compares the decoded
                                       body of the address with BODY_FILE byte for byte
"""
import re
import sys
import urllib.parse


def describe(url, body_file=None):
    out = {}
    u = urllib.parse.urlsplit(url)
    out["scheme"] = u.scheme
    out["host"] = u.netloc
    out["path"] = u.path
    out["length"] = str(len(url))
    out["fragment"] = "yes" if u.fragment else "no"
    try:
        q = urllib.parse.parse_qs(u.query, keep_blank_values=True, strict_parsing=True)
    except ValueError:
        q = {}
        out["query_error"] = "yes"
    out["keys"] = ",".join(sorted(q))
    out["labels"] = "yes" if "labels" in q else "no"
    out["raw_unsafe"] = "yes" if re.search(r"[^A-Za-z0-9._~:/?&=%-]", url) else "no"
    out["bad_escape"] = "yes" if re.search(r"%(?![0-9A-F]{2})", url) else "no"
    out["amp_count"] = str(u.query.count("&"))
    body = q.get("body", [""])[0]
    out["title"] = q.get("title", [""])[0]
    if body_file is not None:
        with open(body_file, "rb") as fh:
            out["body_equal"] = "yes" if fh.read() == body.encode("utf-8") else "no"
    return out, body


def main():
    url = open(sys.argv[1], encoding="utf-8").read()
    out, _ = describe(url, sys.argv[2] if len(sys.argv) > 2 else None)
    for k in sorted(out):
        print("%s=%s" % (k, out[k]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
