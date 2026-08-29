class GridView(NSView, NSTextInputClient, NSDraggingDestination):
    def isFlipped(self) -> Bool:
        return True

    def drawRect_(self, r: Int):
        pass

    # Private to Mojo: no selector, so it must not appear in the walk.
    def _tab_width(self) -> Int:
        return 8

def main():
    print("x")
