from geo import get_user_region


def log_access(user_id, resource):
    region = get_user_region(user_id)
    print(f"user {user_id} in {region} accessed {resource}")
