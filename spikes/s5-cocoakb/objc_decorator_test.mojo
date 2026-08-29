# `@objc` -- the escape hatch from the two naming rules.
#
# Underscore mapping is total but not surjective, and a class registers under
# its Mojo name into a runtime namespace shared by the whole process. Both
# need an override, and this is it: `@objc("...")` on a method fixes the
# selector, on a class fixes the registered name.
#
# The override is not a way around the checking. A selector whose colon count
# disagrees with the arguments is still refused -- see class_decl_errors.mojo
# -- because such a method registers and then never receives anything, which
# is the failure this whole design exists to prevent.
from std.objc import (
    ObjCObject, ObjCClass, msg_send, load_framework, named_global,
)

comptime g_flipped = named_global["dec.flipped", Int]
comptime g_private = named_global["dec.private", Int]


# The Mojo name is short and unqualified; the runtime name is not, because the
# runtime has one namespace for every class in the process and a collision
# makes objc_allocateClassPair return nil.
@objc("RoastDecoratorProbe")
class Probe(NSView):
    # `flipped` reads better in Mojo than `isFlipped`, and AppKit only ever
    # sends the latter.
    @objc("isFlipped")
    def flipped(self) -> Bool:
        g_flipped()[] += 1
        return True

    # A leading underscore normally means "private to Mojo, never exposed".
    # `@objc` is explicit intent and overrides that -- which is the point,
    # since AppKit itself has plenty of selectors beginning with `_`, and
    # there is otherwise no way to spell one at all.
    @objc("mouseDownCanMoveWindow")
    def _can_move(self) -> Bool:
        g_private()[] += 1
        return False


def main() raises:
    if not load_framework["AppKit"]():
        raise Error("no AppKit")

    var probe = Probe()
    var obj = ObjCObject(probe.__objc_id)

    var flipped = msg_send[Bool, "NSView", "isFlipped"](obj)
    var movable = msg_send[Bool, "NSView", "mouseDownCanMoveWindow"](obj)

    # The class answers to the name the decorator gave, and not to its Mojo
    # name: registration used one string, not both.
    var renamed = ObjCClass.lookup["RoastDecoratorProbe"]()
    var mojo_name = ObjCClass.lookup["Probe"]()

    if (
        not flipped
        or movable
        or g_flipped()[] != 1
        or g_private()[] != 1
        or renamed.is_nil()
        or not mojo_name.is_nil()
    ):
        print("isFlipped               ->", flipped, "want True")
        print("mouseDownCanMoveWindow  ->", movable, "want False")
        print("selector hits           ->", g_flipped()[], g_private()[], "want 1 1")
        print("RoastDecoratorProbe     ->", not renamed.is_nil(), "want True")
        print("Probe (mojo name)       ->", mojo_name.is_nil(), "want True")
        raise Error("@objc did not reach the runtime")

    print("@objc selector and class rename OK")
