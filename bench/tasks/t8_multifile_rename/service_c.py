from geo import get_user_region


class ShippingCalculator:
    def estimate(self, user_id, weight_kg):
        region = get_user_region(user_id)
        base = weight_kg * 2.5
        if region == "eu":
            base *= 1.1
        return base
