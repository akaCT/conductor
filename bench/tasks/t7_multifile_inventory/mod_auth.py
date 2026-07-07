def hash_password(raw):
    """Hash a raw password string using the configured slow hash algorithm."""
    raise NotImplementedError


def verify_token(token):
    """Verify a session token's signature and expiry, returning the user id."""
    raise NotImplementedError
