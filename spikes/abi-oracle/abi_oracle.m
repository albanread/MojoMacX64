/* clang is the oracle.
 *
 * Whatever this file does with a struct by value IS the Objective-C ABI on
 * this machine, because clang is what compiled AppKit. Every other Cocoa test
 * in this tree has Mojo on both ends, which proves only that we agree with
 * ourselves. This one puts the real compiler on the other side.
 *
 * Ported in shape from the sister fork's abi_oracle.c, with the CASES
 * replaced. Theirs exercises AAPCS64: indirect arguments, HFA in v0-v3, sret
 * through the hidden x8 register. We are x86-64 System V, where the
 * interesting cases are different in kind, not merely in register names:
 *
 *   - a struct over 16 bytes is passed ON THE STACK, not as a caller-owned
 *     copy behind a pointer;
 *   - a struct over 16 bytes is returned through a DIFFERENT ENTRY POINT,
 *     objc_msgSend_stret, which does not exist on arm64 at all;
 *   - x87 long double is returned through objc_msgSend_fpret, which also does
 *     not exist on arm64.
 *
 * Those last two are the reason this file exists: a binding that is correct on
 * Apple silicon can be silently wrong here, because the arm64 path never has
 * to choose an entry point.
 */
#import <Foundation/Foundation.h>
#include <objc/message.h>
#include <objc/runtime.h>

typedef struct { double a, b, c, d, e, f; } Big;   /* 48 bytes: MEMORY class */
typedef struct { double x, y; } Pair;              /* 16 bytes: SSE, SSE     */

/* ── Direction A: Mojo sends, clang receives ─────────────────────────────
 * A real Objective-C class, compiled by clang. If Mojo can drive this
 * correctly then our msg_send variant selection is right.
 */
/* The class implements REAL SDK selectors, chosen for their ABI shapes, so the
 * Mojo side can reach them through the ordinary checked `send` path -- our
 * bindings verify every selector against cocoa.sqlite, and an invented name
 * would not be there. The shapes:
 *
 *   setFrameSize:  NSSize, 16 bytes, two doubles   -> SSE registers
 *   setFrame:      NSRect, 32 bytes, four doubles  -> MEMORY, passed on stack
 *   frame          NSRect return, 32 bytes         -> objc_msgSend_stret
 */
@interface ABIOracle : NSObject
@property NSRect stored;
@end

@implementation ABIOracle
- (void)setFrameSize:(NSSize)s {
  _stored.size = s;
}
- (void)setFrame:(NSRect)r {
  _stored = r;
}
- (NSRect)frame {
  return NSMakeRect(1.5, 2.5, 4.5, 8.5);   /* sums to 17 */
}
/* Read back what the struct arguments actually delivered, as one double each,
 * so the value crossing into Mojo cannot itself be in question. */
- (CGFloat)alphaValue {
  return _stored.origin.x + _stored.origin.y +
         _stored.size.width + _stored.size.height;
}
@end

/* Constructor so Mojo does not need to allocate it. */
id abi_oracle_new(void) { return [[ABIOracle alloc] init]; }

/* ── Direction B: clang sends, Mojo receives ─────────────────────────────
 * The trampoline test. These target a class REGISTERED FROM MOJO, so they
 * exercise the receiving half of the ABI -- what phase 1 adds, and what has
 * no coverage today.
 */
double poke_set_frame_size(id obj) {
  NSSize v = {10.5, 20.5};                                   /* expect 31 */
  ((void (*)(id, SEL, NSSize))objc_msgSend)(
      obj, sel_registerName("setFrameSize:"), v);
  return ((double (*)(id, SEL))objc_msgSend)(obj, sel_registerName("alphaValue"));
}

double poke_set_frame(id obj) {
  NSRect v = {{1.5, 2.5}, {3.5, 4.5}};                       /* expect 12 */
  ((void (*)(id, SEL, NSRect))objc_msgSend)(
      obj, sel_registerName("setFrame:"), v);
  return ((double (*)(id, SEL))objc_msgSend)(obj, sel_registerName("alphaValue"));
}

/* Struct return FROM Mojo. On x86-64 this must go through _stret; calling
 * plain objc_msgSend here would read the wrong registers. */
double poke_frame(id obj) {
  NSRect t;
  ((void (*)(NSRect *, id, SEL))objc_msgSend_stret)(
      &t, obj, sel_registerName("frame"));
  return t.origin.x + t.origin.y + t.size.width + t.size.height;
}
