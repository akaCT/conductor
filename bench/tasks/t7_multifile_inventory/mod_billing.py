def apply_discount(amount, code):
    """Apply a percentage discount code to a raw dollar amount."""
    raise NotImplementedError


def issue_refund(invoice_id, amount):
    """Issue a partial or full refund against a given invoice id."""
    raise NotImplementedError


def next_invoice_number():
    """Return the next sequential invoice number for the account."""
    raise NotImplementedError
