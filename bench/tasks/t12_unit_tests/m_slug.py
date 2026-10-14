import re


def slugify(text):
    text = text.strip().lower()
    text = re.sub(r"[^a-z0-9]+", "-", text)
    return text.strip("-")


def truncate_slug(slug, limit):
    if len(slug) <= limit:
        return slug
    return slug[:limit].rstrip("-")
