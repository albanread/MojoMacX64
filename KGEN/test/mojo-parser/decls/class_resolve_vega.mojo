class EmptyBases():
    pass

class Multiline(
    NSView,
    NSTextInputClient,
):
    pass

class TabBar(NSView):
    """A docstring."""

    def isFlipped(self) -> Bool:
        return True

@fieldwise_init
struct PlainStruct:
    var x: Int

def main():
    var s = PlainStruct(7)
    print("struct untouched:", s.x)
