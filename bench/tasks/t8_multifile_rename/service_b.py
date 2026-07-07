from geo import get_user_region


def tax_rate(user_id):
    region = get_user_region(user_id)
    rates = {"us": 0.07, "eu": 0.20}
    return rates.get(region, 0.0)
