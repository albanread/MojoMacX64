# The editor view's own state lives in the view.
#
# `edit_test` drives the editor without ever making a view, so every accessor
# there takes the pre-view fallback: it proves the migration changed no
# behaviour, and proves nothing at all about the box. This one makes the view
# first, which is the path the running app actually takes.
#
# The point of the migration is the last check. While caret and selection were
# process globals, two editor views could not have existed -- they would have
# shared a cursor. Now they cannot share one.
from std.objc import (
    ObjCObject, ObjCClass, msg_send, load_framework, box_ref, named_global,
)
from gridview import (
    make_grid_view, g_grid, g_caret, g_anchor, g_max_cols, set_rope,
    RoastGridView, rect,
)
from rope import Rope

comptime g_failures = named_global["viewstate.failures", Int]


def check(name: String, ok: Bool):
    if ok:
        print("  OK  ", name)
    else:
        print("  FAIL", name)
        g_failures()[] += 1


def main() raises:
    if not load_framework["AppKit"]():
        raise Error("no AppKit")

    var first = make_grid_view(rect(0.0, 0.0, 400.0, 300.0))
    check("make_grid_view parks the id", g_grid()[] == first.addr())

    # The accessors now reach the box, not the pre-view global.
    g_caret()[] = 12
    g_anchor()[] = 5
    g_max_cols()[] = 80
    check("caret reads back", g_caret()[] == 12)
    check("anchor reads back", g_anchor()[] == 5)
    check("max_cols reads back", g_max_cols()[] == 80)

    # ...and it really is the object's memory, seen from the other direction.
    check(
        "the write landed in the view's box",
        box_ref[RoastGridView](first.addr()).value()[].caret == 12,
    )

    # The whole reason for the migration: a second view has its own cursor.
    # Under process globals this check could not even be written.
    var second = make_grid_view(rect(0.0, 0.0, 400.0, 300.0))
    check("a second view starts at its own caret", g_caret()[] == 0)
    check(
        "and the first view kept its own",
        box_ref[RoastGridView](first.addr()).value()[].caret == 12,
    )

    g_caret()[] = 99
    check(
        "editing the second leaves the first alone",
        box_ref[RoastGridView](first.addr()).value()[].caret == 12
        and box_ref[RoastGridView](second.addr()).value()[].caret == 99,
    )

    # Nil is a state, not a hazard: this used to hand back a pointer into the
    # first page and say so only in a docstring.
    check("a nil id has no box", not box_ref[RoastGridView](0))

    if g_failures()[] != 0:
        raise Error("view state is not per view")
    print("view state OK")
