//===- CocoaCompletion.h - Cocoa completion from the SDK database ---------===//
//
// Completion candidates read from cocoa.sqlite, the same database the
// elaborator answers `cocoakb_query` from at compile time.
//
// The elaborator asks point questions -- what is this selector's encoding, how
// big is this struct -- and gets one answer. Completion asks the opposite kind
// of question: everything that starts with these characters, ranked, bounded.
// Different queries, different indexes, so this is its own reader rather than
// an extension of the evaluator's; they share only the database file and the
// path it is configured with.
//
//===----------------------------------------------------------------------===//

#ifndef KGEN_COCOAKB_COCOACOMPLETION_H
#define KGEN_COCOAKB_COCOACOMPLETION_H

#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/StringRef.h"
#include <string>
#include <vector>

namespace M::KGEN::CocoaKB {

/// One candidate. `detail` is what the editor shows beside the name -- a
/// superclass for a class, a decoded signature for a selector.
struct CompletionItem {
  std::string name;
  std::string detail;
  std::string documentation;
  bool isClassMethod = false;
};

/// Objective-C classes whose name starts with `prefix`, case-sensitively,
/// because Objective-C class names are.
///
/// Returns nothing at all if the database is unreachable. A language server
/// that cannot find cocoa.sqlite should offer no Cocoa completions, not fail
/// the request and take the Mojo ones down with it.
std::vector<CompletionItem> completeClasses(llvm::StringRef prefix,
                                            unsigned limit = 200);

/// Selectors that `cls` responds to, including everything it inherits.
///
/// Inheritance is the point: asking `NSWindow` for selectors and getting only
/// the ones declared on `NSWindow` would miss `alloc`, `init`, `retain` and
/// most of what anyone actually types.
std::vector<CompletionItem> completeSelectors(llvm::StringRef cls,
                                              llvm::StringRef prefix,
                                              bool classMethods,
                                              unsigned limit = 300);

/// Human-readable rendering of an Objective-C type encoding, e.g.
/// "v@:@" -> "(id, SEL, id) -> void". Returns the encoding unchanged if it
/// cannot be parsed -- a partial answer beats an empty one in a tooltip.
std::string describeEncoding(llvm::StringRef encoding);

/// Whether a database is configured and openable. For diagnostics only;
/// the completion entry points are safe to call regardless.
bool available();

} // namespace M::KGEN::CocoaKB

#endif // KGEN_COCOAKB_COCOACOMPLETION_H
