# ===----------------------------------------------------------------------=== #
# Objective-C memory management, the Mojo way: no leaks by default.
#
# Cocoa uses manual reference counting under the hood (retain/release), plus
# autorelease pools that defer a release to the end of a scope. Mojo has value
# semantics and deterministic destruction, so we bind the two:
#
#   * `ObjCRef` OWNS a +1 reference. It retains on copy and releases on destroy
#     -- so an object's lifetime follows the Mojo value that holds it, and
#     nothing leaks unless you deliberately drop ownership.
#   * `autoreleasepool` drains deferred releases at scope exit; `ObjCRef` can
#     hand its object to the current pool with `.autorelease()`.
#
# The retain/release primitives are the objc runtime's ARC entry points
# (objc_retain / objc_release / objc_autorelease) -- direct C calls, the same
# ones the Clang ARC optimizer emits, so this interoperates with ARC code.
# ===----------------------------------------------------------------------=== #

from std.ffi import external_call
from std.memory import OpaquePointer
from .runtime import ObjCObject, msg_send


comptime _RawPtr = OpaquePointer[MutUntrackedOrigin]


@always_inline
def _objc_retain(o: _RawPtr) -> _RawPtr:
    return external_call["objc_retain", _RawPtr](o)


@always_inline
def _objc_release(o: _RawPtr):
    external_call["objc_release", NoneType](o)


@always_inline
def _objc_autorelease(o: _RawPtr) -> _RawPtr:
    return external_call["objc_autorelease", _RawPtr](o)


struct ObjCRef(Movable):
    """An owning handle on an Objective-C object: +1 on the way in, released
    when the Mojo value dies.

    Two ways in, matching the two Cocoa conventions:

      * `ObjCRef.adopt(obj)` takes ownership of an object you already own +1
        (from `alloc`/`new`/`copy`/`mutableCopy`). No extra retain.
      * `ObjCRef.retain(obj)` shares an object you have only borrowed (from any
        other selector, or a raw `id`): it adds a +1 you are responsible for.

    Either way, copying an `ObjCRef` retains and destroying it releases, so the
    reference count is always balanced without hand-written release calls.
    """

    var _obj: ObjCObject

    def __init__(out self, *, adopt: ObjCObject):
        """Take ownership of an object returned at +1 (alloc/new/copy/…)."""
        self._obj = adopt

    def __init__(out self, *, retain: ObjCObject):
        """Share a borrowed object, adding an owned +1."""
        _ = _objc_retain(retain.ptr())
        self._obj = retain

    def copy(self) -> Self:
        """Explicitly make a new owning reference (+1). ObjCRef is not
        implicitly copyable: sharing an Objective-C object is a retain, which
        should be visible in the code."""
        _ = _objc_retain(self._obj.ptr())
        return ObjCRef(adopt=self._obj)

    def __deinit__(deinit self):
        if not self._obj.is_nil():
            external_call["objc_release", NoneType](
                OpaquePointer[MutUntrackedOrigin](unsafe_from_address=self._obj.addr())
            )

    def object(self) -> ObjCObject:
        """The borrowed object, valid for the lifetime of this `ObjCRef`."""
        return self._obj

    def is_nil(self) -> Bool:
        return self._obj.is_nil()

    def autorelease(deinit self) -> ObjCObject:
        """Hand this object to the current autorelease pool and give up owning
        it. The returned handle is valid until the pool drains -- use it to
        return a Cocoa object from a function without leaking, exactly as an
        Objective-C method returning an autoreleased object would.
        """
        return ObjCObject(Int(_objc_autorelease(self._obj.ptr())))
