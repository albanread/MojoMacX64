class Bare:
    pass

class WithSuper(NSObject):
    pass

class WithProtocols(NSObject, NSApplicationDelegate, NSWindowDelegate):
    pass

class Qualified(foundation.NSView):
    pass

class TrailingComma(NSObject, NSWindowDelegate,):
    pass

def main():
    print("parsed")
