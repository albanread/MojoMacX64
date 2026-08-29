# Does the compiler synthesize __objc_register__ for a class, and does that
# function actually construct the registrar?
class GridView(NSView, NSTextInputClient):
    pass

class Plain(NSObject):
    pass

def main():
    print("compiled")
