def make_key(user, action):
    """Build the cache key for a user and an action."""
    return f"{user}:{action}"


def split_key(key):
    """Split a cache key back into its user and action parts."""
    user, action = key.split(":", 1)
    return user, action


def expired(age_s, ttl_s):
    """Return True when an entry of age_s seconds has outlived ttl_s."""
    return age_s >= ttl_s


def _hash_key(key):
    return hash(key)
