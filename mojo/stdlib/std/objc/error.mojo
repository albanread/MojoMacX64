# ===----------------------------------------------------------------------=== #
# NSError out-parameters -> `raises`.
#
# Cocoa's error convention predates exceptions it never adopted: a fallible
# method takes a trailing `error:` out-parameter (`NSError **`) and signals
# failure through its RETURN VALUE -- nil for object returns, NO for BOOL
# returns. The error object is only meaningful when the return value says
# failure; checking the out-parameter instead is the classic Cocoa bug, and
# ignoring it (this codebase's own `err_out()` hack, playground.mojo) throws
# the diagnosis away.
#
# Mojo's convention is `raises`. These wrappers convert: the trailing error
# argument is supplied here (a stack slot -- no caller plumbing), the RETURN
# value decides success exactly as Cocoa specifies, and on failure the
# NSError's domain, code and localizedDescription become the message of a
# raised Mojo Error. The autorelease pool owns the NSError itself; the message
# String copies out of it, so nothing here outlives the pool.
#
# Everything msg_send checks is still checked: the selector must exist, the
# argument count INCLUDES the error slot supplied here, and the register-file
# classes are verified -- all at compile time, from the database.
#
# Explicit arities rather than a variadic: Mojo permits nothing after an
# unpacked `*args`, so the slot cannot be appended to a forwarded pack. The
# same constraint shaped IMP0/IMP1/IMP2 in classes.mojo. Cocoa error methods
# carry few leading arguments; arities up to five cover the SDK's convention
# comfortably, and a new arity is four lines.
# ===----------------------------------------------------------------------=== #

from std.memory import Pointer

from .runtime import ObjCObject, msg_send
from .foundation import ns_to_string


def _nserror_message[context: StaticString](err_addr: Int) -> String:
    """domain + code + localizedDescription, copied into a Mojo String."""
    if err_addr == 0:
        # The API broke its own contract: failure return, no error written.
        return String(context) + " failed, and no NSError was provided"
    var err = ObjCObject(err_addr)
    var domain = ns_to_string(msg_send[ObjCObject, "NSError", "domain"](err))
    var code = msg_send[Int, "NSError", "code"](err)
    var desc = ns_to_string(
        msg_send[ObjCObject, "NSError", "localizedDescription"](err)
    )
    return (
        String(context) + ": " + desc + " (" + domain + " " + String(code) + ")"
    )


def msg_send_raising[
    cls: StaticString,
    selector: StaticString,
    is_class: Bool = False,
](obj: ObjCObject) raises -> ObjCObject:
    """Send an object-returning `...error:` selector; raise on nil. The
    error slot is created and appended here -- pass the message arguments
    WITHOUT it."""
    var err_slot: Int = 0
    var result = msg_send[ObjCObject, cls, selector, is_class](
        obj, Pointer(to=err_slot)
    )
    if result.is_nil():
        raise Error(_nserror_message[selector](err_slot))
    return result


def msg_send_raising[
    cls: StaticString,
    selector: StaticString,
    T0: AnyType,
    is_class: Bool = False,
](obj: ObjCObject, a0: T0) raises -> ObjCObject:
    """Send an object-returning `...error:` selector; raise on nil. The
    error slot is created and appended here -- pass the message arguments
    WITHOUT it."""
    var err_slot: Int = 0
    var result = msg_send[ObjCObject, cls, selector, is_class](
        obj, a0, Pointer(to=err_slot)
    )
    if result.is_nil():
        raise Error(_nserror_message[selector](err_slot))
    return result


def msg_send_raising[
    cls: StaticString,
    selector: StaticString,
    T0: AnyType,
    T1: AnyType,
    is_class: Bool = False,
](obj: ObjCObject, a0: T0, a1: T1) raises -> ObjCObject:
    """Send an object-returning `...error:` selector; raise on nil. The
    error slot is created and appended here -- pass the message arguments
    WITHOUT it."""
    var err_slot: Int = 0
    var result = msg_send[ObjCObject, cls, selector, is_class](
        obj, a0, a1, Pointer(to=err_slot)
    )
    if result.is_nil():
        raise Error(_nserror_message[selector](err_slot))
    return result


def msg_send_raising[
    cls: StaticString,
    selector: StaticString,
    T0: AnyType,
    T1: AnyType,
    T2: AnyType,
    is_class: Bool = False,
](obj: ObjCObject, a0: T0, a1: T1, a2: T2) raises -> ObjCObject:
    """Send an object-returning `...error:` selector; raise on nil. The
    error slot is created and appended here -- pass the message arguments
    WITHOUT it."""
    var err_slot: Int = 0
    var result = msg_send[ObjCObject, cls, selector, is_class](
        obj, a0, a1, a2, Pointer(to=err_slot)
    )
    if result.is_nil():
        raise Error(_nserror_message[selector](err_slot))
    return result


def msg_send_raising[
    cls: StaticString,
    selector: StaticString,
    T0: AnyType,
    T1: AnyType,
    T2: AnyType,
    T3: AnyType,
    is_class: Bool = False,
](obj: ObjCObject, a0: T0, a1: T1, a2: T2, a3: T3) raises -> ObjCObject:
    """Send an object-returning `...error:` selector; raise on nil. The
    error slot is created and appended here -- pass the message arguments
    WITHOUT it."""
    var err_slot: Int = 0
    var result = msg_send[ObjCObject, cls, selector, is_class](
        obj, a0, a1, a2, a3, Pointer(to=err_slot)
    )
    if result.is_nil():
        raise Error(_nserror_message[selector](err_slot))
    return result


def msg_send_raising[
    cls: StaticString,
    selector: StaticString,
    T0: AnyType,
    T1: AnyType,
    T2: AnyType,
    T3: AnyType,
    T4: AnyType,
    is_class: Bool = False,
](obj: ObjCObject, a0: T0, a1: T1, a2: T2, a3: T3, a4: T4) raises -> ObjCObject:
    """Send an object-returning `...error:` selector; raise on nil. The
    error slot is created and appended here -- pass the message arguments
    WITHOUT it."""
    var err_slot: Int = 0
    var result = msg_send[ObjCObject, cls, selector, is_class](
        obj, a0, a1, a2, a3, a4, Pointer(to=err_slot)
    )
    if result.is_nil():
        raise Error(_nserror_message[selector](err_slot))
    return result


def msg_send_raising_check[
    cls: StaticString,
    selector: StaticString,
    is_class: Bool = False,
](obj: ObjCObject) raises:
    """Send a BOOL-returning `...error:` selector; raise on NO. Same slot
    handling as `msg_send_raising`."""
    var err_slot: Int = 0
    var result = msg_send[Bool, cls, selector, is_class](
        obj, Pointer(to=err_slot)
    )
    if not result:
        raise Error(_nserror_message[selector](err_slot))


def msg_send_raising_check[
    cls: StaticString,
    selector: StaticString,
    T0: AnyType,
    is_class: Bool = False,
](obj: ObjCObject, a0: T0) raises:
    """Send a BOOL-returning `...error:` selector; raise on NO. Same slot
    handling as `msg_send_raising`."""
    var err_slot: Int = 0
    var result = msg_send[Bool, cls, selector, is_class](
        obj, a0, Pointer(to=err_slot)
    )
    if not result:
        raise Error(_nserror_message[selector](err_slot))


def msg_send_raising_check[
    cls: StaticString,
    selector: StaticString,
    T0: AnyType,
    T1: AnyType,
    is_class: Bool = False,
](obj: ObjCObject, a0: T0, a1: T1) raises:
    """Send a BOOL-returning `...error:` selector; raise on NO. Same slot
    handling as `msg_send_raising`."""
    var err_slot: Int = 0
    var result = msg_send[Bool, cls, selector, is_class](
        obj, a0, a1, Pointer(to=err_slot)
    )
    if not result:
        raise Error(_nserror_message[selector](err_slot))


def msg_send_raising_check[
    cls: StaticString,
    selector: StaticString,
    T0: AnyType,
    T1: AnyType,
    T2: AnyType,
    is_class: Bool = False,
](obj: ObjCObject, a0: T0, a1: T1, a2: T2) raises:
    """Send a BOOL-returning `...error:` selector; raise on NO. Same slot
    handling as `msg_send_raising`."""
    var err_slot: Int = 0
    var result = msg_send[Bool, cls, selector, is_class](
        obj, a0, a1, a2, Pointer(to=err_slot)
    )
    if not result:
        raise Error(_nserror_message[selector](err_slot))


def msg_send_raising_check[
    cls: StaticString,
    selector: StaticString,
    T0: AnyType,
    T1: AnyType,
    T2: AnyType,
    T3: AnyType,
    is_class: Bool = False,
](obj: ObjCObject, a0: T0, a1: T1, a2: T2, a3: T3) raises:
    """Send a BOOL-returning `...error:` selector; raise on NO. Same slot
    handling as `msg_send_raising`."""
    var err_slot: Int = 0
    var result = msg_send[Bool, cls, selector, is_class](
        obj, a0, a1, a2, a3, Pointer(to=err_slot)
    )
    if not result:
        raise Error(_nserror_message[selector](err_slot))


def msg_send_raising_check[
    cls: StaticString,
    selector: StaticString,
    T0: AnyType,
    T1: AnyType,
    T2: AnyType,
    T3: AnyType,
    T4: AnyType,
    is_class: Bool = False,
](obj: ObjCObject, a0: T0, a1: T1, a2: T2, a3: T3, a4: T4) raises:
    """Send a BOOL-returning `...error:` selector; raise on NO. Same slot
    handling as `msg_send_raising`."""
    var err_slot: Int = 0
    var result = msg_send[Bool, cls, selector, is_class](
        obj, a0, a1, a2, a3, a4, Pointer(to=err_slot)
    )
    if not result:
        raise Error(_nserror_message[selector](err_slot))

