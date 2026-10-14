#!/usr/bin/env python3
"""render.py IN OUT [KEY=VALUE ...]: copy IN to OUT replacing @@KEY@@ with VALUE
and @@AGO:<n><s|m|h|d>@@ with an ISO UTC time that long ago. Test fixture helper."""
import re
import sys
import time

AGO = re.compile(r"@@AGO:(\d+)([smhd])@@")


def ago_iso(n, unit):
    secs = int(n) * {"s": 1, "m": 60, "h": 3600, "d": 86400}[unit]
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - secs))


def main():
    src, dst = sys.argv[1], sys.argv[2]
    text = open(src, encoding="utf-8").read()
    for kv in sys.argv[3:]:
        k, _, v = kv.partition("=")
        text = text.replace("@@%s@@" % k, v)
    text = AGO.sub(lambda m: ago_iso(m.group(1), m.group(2)), text)
    open(dst, "w", encoding="utf-8").write(text)


if __name__ == "__main__":
    main()
