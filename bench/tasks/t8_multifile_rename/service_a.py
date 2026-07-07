from geo import get_user_region


def greet(user_id):
    region = get_user_region(user_id)
    return f"Hello from {region}"
