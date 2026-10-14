def pad_id(n, width):
    return str(n).zfill(width)


def split_pair(text):
    left, right = text.split("=", 1)
    return left.strip(), right.strip()
