def parse_version(text):
    """Split a dotted version string into a tuple of ints."""
    return tuple(int(p) for p in text.split("."))


def newer(a, b):
    """Return True when version string a is newer than b."""
    return parse_version(a) > parse_version(b)


def _normalize(text):
    return text.strip()
