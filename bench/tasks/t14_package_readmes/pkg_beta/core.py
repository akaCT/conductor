def load_lines(path):
    """Read a text file and return its non-empty lines."""
    with open(path) as f:
        return [ln.rstrip("\n") for ln in f if ln.strip()]


def count_words(lines):
    """Count the words across a list of lines."""
    return sum(len(ln.split()) for ln in lines)


def longest(lines):
    """Return the longest line, or an empty string for an empty list."""
    return max(lines, key=len, default="")


def _debug_dump(lines):
    print(lines)
