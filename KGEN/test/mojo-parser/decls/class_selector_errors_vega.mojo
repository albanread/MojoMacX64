class Broken(NSView):
    # The dangerous one: meant drawRect_, wrote drawRect. Derives a NULLARY
    # selector, would register cleanly, and would then never receive a draw.
    def drawRect(self, r: Int):
        pass

    # The other direction: an underscore with no argument to match it.
    def setTitle_(self):
        pass

    # Two colons, one argument.
    def a_b_(self, x: Int):
        pass

def main():
    print("x")
