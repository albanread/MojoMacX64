//===- CocoaKBDatabase.h - Compile-time reads of cocoa.sqlite -------------===//
//
// The Cocoa metadata database, asked point questions at compile time: what is
// this selector's encoding, how big is this struct, which framework declares
// this class.
//
// This began inside the elaborator, where `cocoakb_query` is evaluated. It
// lives here because the parser needs it too: an Objective-C class declared
// with `class` (COCOA_CLASS_DESIGN.md) is registered with an encoding per
// method, and those encodings come from the SDK rather than from a mapping
// written by hand -- see that document's sprint 2 note on why deriving them
// from Mojo types does not work.
//
// Not to be confused with CocoaCompletion.h, which answers the opposite kind
// of question -- everything starting with these characters, ranked, bounded --
// and has its own reader for its own indexes. These share the database file
// and the path it is configured with, and nothing else.
//
//===----------------------------------------------------------------------===//

#ifndef KGEN_COCOAKB_COCOAKBDATABASE_H
#define KGEN_COCOAKB_COCOAKBDATABASE_H

#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/Support/Error.h"

#include <mutex>
#include <string>

struct sqlite3;
struct sqlite3_stmt;

namespace M::KGEN::CocoaKB {

/// A lazily-opened, read-only handle on the Cocoa metadata database, shared
/// for the life of the process. Elaboration is concurrent, so every use is
/// guarded; the queries themselves are reads against an immutable file.
class CocoaKBDatabase {
public:
  static CocoaKBDatabase &get() {
    static CocoaKBDatabase instance;
    return instance;
  }

  llvm::Expected<int64_t> queryInt(llvm::StringRef query,
                                   llvm::ArrayRef<llvm::StringRef> args);
  llvm::Expected<std::string> queryString(llvm::StringRef query,
                                          llvm::ArrayRef<llvm::StringRef> args);

  /// Whether a database is configured and openable, and why not if not.
  ///
  /// Callers need this to tell "the SDK has no such class" from "there is no
  /// SDK metadata here", which are the same empty answer and completely
  /// different problems. Reporting the second as the first is how a
  /// configuration mistake ends up wearing a source error's clothes.
  llvm::Error availability();

  /// The same as `queryString`, but a miss is an empty optional rather than an
  /// error. For callers that have a next thing to try: a selector the SDK has
  /// never heard of is an ordinary state when the class declaring it is ours.
  std::optional<std::string> lookup(llvm::StringRef query,
                                    llvm::ArrayRef<llvm::StringRef> args);

private:
  CocoaKBDatabase() = default;
  llvm::Error openLocked();
  llvm::Expected<sqlite3_stmt *> prepare(llvm::StringRef query,
                                         llvm::ArrayRef<llvm::StringRef> args);

  std::mutex mutex;
  sqlite3 *db = nullptr;
  bool attempted = false;
  std::string openError;
  std::string openedPath;
  std::string cachedHash;
};

} // namespace M::KGEN::CocoaKB

#endif // KGEN_COCOAKB_COCOAKBDATABASE_H
