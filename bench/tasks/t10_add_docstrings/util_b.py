def initials(name):
    return "".join(part[0].upper() for part in name.split())


def shout(text):
    return text.upper() + "!"
