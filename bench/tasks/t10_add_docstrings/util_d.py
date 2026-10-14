def chunk(items, size):
    return [items[i:i + size] for i in range(0, len(items), size)]


def flatten(rows):
    return [x for row in rows for x in row]
