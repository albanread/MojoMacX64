class Responder(NSView):
    # nullary: no underscore, no colon
    def isFlipped(self) -> Bool:
        return True

    # one underscore, one argument after self
    def drawRect_(self, r: Int):
        pass

    # three underscores, three arguments
    def outlineView_child_ofItem_(self, a: Int, b: Int, c: Int) -> Int:
        return a + b + c

    # leading underscore: private to Mojo, never exposed, snake_case is fine
    def _tab_width(self) -> Int:
        return 8

    def __repr__(self) -> Int:
        return 0

def main():
    print("selectors derived")
