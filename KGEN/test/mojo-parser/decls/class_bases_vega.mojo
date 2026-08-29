# Real classes: must resolve, and record their frameworks.
class Good(NSView, NSTextInputClient):
    pass

class Qualified(foundation.NSObject):
    pass

# The one that matters: a typo in a superclass does NOT fail at runtime -- it
# builds a root class and a window that never appears.
class Typo(NSVeiw):
    pass

class AlsoTypo(NSWindoww):
    pass

def main():
    print("x")
