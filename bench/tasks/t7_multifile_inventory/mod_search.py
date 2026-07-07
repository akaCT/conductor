def index_document(doc_id, text):
    """Add or update a document in the search index by id."""
    raise NotImplementedError


def query(term, limit=10):
    """Run a search query and return the top matching document ids."""
    raise NotImplementedError
