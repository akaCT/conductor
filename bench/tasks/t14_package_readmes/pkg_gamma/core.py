def celsius_to_f(c):
    """Convert degrees Celsius to degrees Fahrenheit."""
    return c * 9 / 5 + 32


def f_to_celsius(f):
    """Convert degrees Fahrenheit to degrees Celsius."""
    return (f - 32) * 5 / 9


def _round2(x):
    return round(x, 2)
