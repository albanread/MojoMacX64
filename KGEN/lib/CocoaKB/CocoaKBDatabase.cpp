//===----------------------------------------------------------------------===//
// VEGA-FORK: the Cocoa metadata database (COCOA_DESIGN.md).
//
// Lifted out of the elaborator's anonymous namespace so the PARSER can reach
// it too: a `class` declaration needs encodings, framework attribution and a
// superclass that actually exists, and all of that is answerable here.
//
// ARCHITECTURE NOTE, and the reason this file was not taken wholesale from the
// sibling port: every ABI query below reads the `_x64` tables. The sibling is
// arm64 and reads `method_abi` / `posix_function_abi`. Those tables disagree
// -- an NSRect return is four float registers on arm64 and an sret through
// objc_msgSend_stret here -- so importing their file would have silently
// answered every ABI question for the wrong machine. Keep the `_x64` suffixes.
//===----------------------------------------------------------------------===//

#include "KGEN/CocoaKB/CocoaKBDatabase.h"
#include "KGEN/Support/Configuration.h"

#include "llvm/ADT/ScopeExit.h"
#include "llvm/ADT/StringExtras.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/Path.h"

#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/SHA256.h"

#include <sqlite3.h>

#include <cstdlib>
#include <mutex>

using namespace llvm;

namespace M::KGEN::CocoaKB {

/// The queries this exposes, by the name Mojo passes as the first operand.
/// A binding asks for "struct_size", not for SQL, so the schema stays an
/// implementation detail of the compiler; a metadata layout change is a
/// one-line fix here instead of a break in every caller.
struct CocoaKBQueryDef {
  StringRef name;
  unsigned argCount;
  StringRef sql;
};

constexpr StringRef kStructSizeSQL =
    "SELECT size FROM structs WHERE name = ?1";
constexpr StringRef kStructAlignSQL =
    "SELECT align FROM structs WHERE name = ?1";
constexpr StringRef kFieldOffsetSQL =
    "SELECT offset FROM struct_fields WHERE struct = ?1 AND name = ?2";

// BridgeSupport value64 is text; CAST gives the signed reading, which is the
// one that survives narrowing in both directions (see the sister port's
// HKEY_LOCAL_MACHINE lesson in COCOA_DESIGN.md D6).
constexpr StringRef kEnumValueSQL =
    "SELECT CAST(value AS INTEGER) FROM bs_enums WHERE name = ?1 LIMIT 1";

// Extern-symbol constants (NSFontAttributeName...) are runtime addresses,
// not comptime values: the database supplies the declared type and the
// binding dlsyms the symbol at runtime.
constexpr StringRef kConstantTypeSQL =
    "SELECT type64 FROM bs_constants WHERE name = ?1 LIMIT 1";

constexpr StringRef kSuperclassSQL =
    "SELECT superclass FROM rt_classes WHERE name = ?1";

// Method lookups walk the superclass chain: the runtime ingest records a
// method on the class that DEFINES it, and inheritance is a query, not
// codegen. ORDER BY depth so the nearest definition (an override) wins.
#define COCOAKB_METHOD_CTE(column, table)                                      \
  "WITH RECURSIVE chain(c, depth) AS ("                                        \
  "  SELECT ?1, 0"                                                             \
  "  UNION ALL"                                                                \
  "  SELECT rc.superclass, chain.depth + 1 FROM rt_classes rc, chain"          \
  "    WHERE rc.name = chain.c AND rc.superclass IS NOT NULL)"                 \
  " SELECT m." column " FROM chain JOIN " table " m"                           \
  "   ON m.class = chain.c AND m.selector = ?2"                                \
  "  AND m.is_class = CAST(?3 AS INTEGER)"                                     \
  " ORDER BY chain.depth LIMIT 1"

constexpr StringRef kMethodEncodingSQL =
    COCOAKB_METHOD_CTE("encoding", "rt_methods");
constexpr StringRef kMsgSendVariantSQL =
    COCOAKB_METHOD_CTE("msgsend", "method_abi_x64");
constexpr StringRef kMethodRetClassSQL =
    COCOAKB_METHOD_CTE("ret_class", "method_abi_x64");
constexpr StringRef kMethodArgClassesSQL =
    COCOAKB_METHOD_CTE("arg_classes", "method_abi_x64");
#undef COCOAKB_METHOD_CTE

// Selector-keyed ABI: for a protocol-typed object (id<MTLTexture>, a Cocoa
// delegate, ...) the concrete class is unknown at compile time, but a selector
// carries the same ABI wherever it is implemented. Take the majority reading
// across implementing classes so one odd class can't skew it.
constexpr StringRef kSelectorVariantSQL =
    "SELECT msgsend FROM method_abi_x64 WHERE selector = ?1 "
    "GROUP BY msgsend ORDER BY COUNT(*) DESC LIMIT 1";
constexpr StringRef kSelectorArgClassesSQL =
    "SELECT arg_classes FROM method_abi_x64 WHERE selector = ?1 "
    "GROUP BY arg_classes ORDER BY COUNT(*) DESC LIMIT 1";
// The verbatim @encode signature for a selector, majority reading. Used to
// type a Mojo-implemented method when defining an ObjC class at runtime
// (class_addMethod), so even a callback's signature comes from the SDK.
constexpr StringRef kSelectorEncodingSQL =
    "SELECT encoding FROM rt_methods WHERE selector = ?1 "
    "GROUP BY encoding ORDER BY COUNT(*) DESC LIMIT 1";

constexpr StringRef kPosixSigSQL =
    "SELECT qualtype FROM posix_functions WHERE name = ?1";
constexpr StringRef kPosixRetClassSQL =
    "SELECT ret_class FROM posix_function_abi_x64 WHERE name = ?1";
constexpr StringRef kPosixArgClassesSQL =
    "SELECT arg_classes FROM posix_function_abi_x64 WHERE name = ?1";

const CocoaKBQueryDef kCocoaQueries[] = {
    {"struct_size", 1, kStructSizeSQL},
    {"struct_align", 1, kStructAlignSQL},
    {"field_offset", 2, kFieldOffsetSQL},
    {"enum_value", 1, kEnumValueSQL},
    {"constant_type", 1, kConstantTypeSQL},
    {"superclass", 1, kSuperclassSQL},
    {"method_encoding", 3, kMethodEncodingSQL},
    {"msgsend_variant", 3, kMsgSendVariantSQL},
    {"method_ret_class", 3, kMethodRetClassSQL},
    {"method_arg_classes", 3, kMethodArgClassesSQL},
    {"selector_variant", 1, kSelectorVariantSQL},
    {"selector_arg_classes", 1, kSelectorArgClassesSQL},
    {"selector_encoding", 1, kSelectorEncodingSQL},
    {"posix_sig", 1, kPosixSigSQL},
    {"posix_ret_class", 1, kPosixRetClassSQL},
    {"posix_arg_classes", 1, kPosixArgClassesSQL},
};

llvm::Error CocoaKBDatabase::openLocked() {
  if (attempted)
    return openError.empty()
               ? llvm::Error::success()
               : llvm::createStringError(llvm::inconvertibleErrorCode(),
                                         openError);
  attempted = true;

  ErrorOr<MojoConfig> configOr = MojoConfig::open();
  if (configOr.isError()) {
    openError = "cannot read the Mojo configuration to locate the Cocoa "
                "metadata database";
    return llvm::createStringError(llvm::inconvertibleErrorCode(), openError);
  }
  // The config owns the string, so copy it before the config goes away.
  std::string path = configOr.get().getCocoaKBPath().str();
  if (path.empty()) {
    openError = "no Cocoa metadata database is configured; set "
                "MODULAR_MOJO_MAX_COCOAKB_PATH to cocoa.sqlite";
    return llvm::createStringError(llvm::inconvertibleErrorCode(), openError);
  }

  // Read-only, and never created: a missing database is a configuration error
  // to report, not an empty one to invent and then answer wrongly from.
  openedPath = path;
  int rc = sqlite3_open_v2(path.c_str(), &db, SQLITE_OPEN_READONLY, nullptr);
  if (rc != SQLITE_OK) {
    openError = "cannot open the Cocoa metadata database at '" + path +
                "': " + std::string(db ? sqlite3_errmsg(db) : "out of memory");
    if (db) {
      sqlite3_close(db);
      db = nullptr;
    }
    return llvm::createStringError(llvm::inconvertibleErrorCode(), openError);
  }
  return llvm::Error::success();
}

llvm::Expected<sqlite3_stmt *>
CocoaKBDatabase::prepare(StringRef query, ArrayRef<StringRef> args) {
  const CocoaKBQueryDef *def = nullptr;
  for (const auto &candidate : kCocoaQueries)
    if (candidate.name == query)
      def = &candidate;

  if (!def) {
    std::string known;
    for (const auto &candidate : kCocoaQueries)
      known += (known.empty() ? "" : ", ") + candidate.name.str();
    return llvm::createStringError(llvm::inconvertibleErrorCode(),
                                   "unknown Cocoa metadata query '" +
                                       query.str() +
                                       "'; known queries: " + known);
  }

  if (args.size() != def->argCount)
    return llvm::createStringError(
        llvm::inconvertibleErrorCode(),
        "Cocoa metadata query '" + query.str() + "' takes " +
            std::to_string(def->argCount) + " argument(s), got " +
            std::to_string(args.size()));

  if (auto err = openLocked())
    return std::move(err);

  sqlite3_stmt *stmt = nullptr;
  if (sqlite3_prepare_v2(db, def->sql.str().c_str(), -1, &stmt, nullptr) !=
      SQLITE_OK)
    return llvm::createStringError(llvm::inconvertibleErrorCode(),
                                   StringRef(sqlite3_errmsg(db)));

  for (auto [index, arg] : llvm::enumerate(args))
    sqlite3_bind_text(stmt, static_cast<int>(index + 1), arg.data(),
                      static_cast<int>(arg.size()), SQLITE_TRANSIENT);
  return stmt;
}

llvm::Expected<int64_t> CocoaKBDatabase::queryInt(StringRef query,
                                                  ArrayRef<StringRef> args) {
  std::lock_guard<std::mutex> lock(mutex);
  auto stmt = prepare(query, args);
  if (!stmt)
    return stmt.takeError();
  llvm::scope_exit cleanup([&] { sqlite3_finalize(*stmt); });

  int rc = sqlite3_step(*stmt);
  if (rc != SQLITE_ROW)
    return llvm::createStringError(llvm::inconvertibleErrorCode(),
                                   "the Cocoa metadata has no '" + query.str() +
                                       "' for " + llvm::join(args, ", "));
  // A NULL column means the metadata knows the entity but not this property,
  // which is a different failure from not knowing the entity at all.
  if (sqlite3_column_type(*stmt, 0) == SQLITE_NULL)
    return llvm::createStringError(llvm::inconvertibleErrorCode(),
                                   "the Cocoa metadata records no " +
                                       query.str() + " for " +
                                       llvm::join(args, ", "));
  return sqlite3_column_int64(*stmt, 0);
}

llvm::Expected<std::string>
CocoaKBDatabase::queryString(StringRef query, ArrayRef<StringRef> args) {
  std::lock_guard<std::mutex> lock(mutex);

  // The reproducibility pin: a compiler whose semantics depend on a database
  // must be able to say WHICH database. Hashed lazily and cached, so tooling
  // can record the exact metadata revision a binary was built against.
  if (query == "db_hash") {
    if (!args.empty())
      return llvm::createStringError(llvm::inconvertibleErrorCode(),
                                     "'db_hash' takes no arguments");
    if (auto err = openLocked())
      return std::move(err);
    if (cachedHash.empty()) {
      llvm::ErrorOr<std::unique_ptr<llvm::MemoryBuffer>> bufferOr =
          llvm::MemoryBuffer::getFile(openedPath, /*IsText=*/false);
      if (!bufferOr)
        return llvm::createStringError(
            llvm::inconvertibleErrorCode(),
            "cannot read the Cocoa metadata database for hashing");
      llvm::SHA256 sha;
      sha.update((*bufferOr)->getBuffer());
      cachedHash = llvm::toHex(sha.final(), /*LowerCase=*/true);
    }
    return cachedHash;
  }
  auto stmt = prepare(query, args);
  if (!stmt)
    return stmt.takeError();
  llvm::scope_exit cleanup([&] { sqlite3_finalize(*stmt); });

  int rc = sqlite3_step(*stmt);
  if (rc != SQLITE_ROW || sqlite3_column_type(*stmt, 0) == SQLITE_NULL)
    return llvm::createStringError(llvm::inconvertibleErrorCode(),
                                   "the Cocoa metadata has no '" + query.str() +
                                       "' for " + llvm::join(args, ", "));

  const auto *text = sqlite3_column_text(*stmt, 0);
  return std::string(reinterpret_cast<const char *>(text),
                     sqlite3_column_bytes(*stmt, 0));
}

//===----------------------------------------------------------------------===//
// Sprint 4 additions: framework attribution and result types.
//
// These are ABI-NEUTRAL -- they answer which framework declares a class, and
// what TYPE a result is, never which register it arrives in -- so unlike the
// queries above they are identical on both architectures and were taken from
// the sibling port unchanged. They read method_ret_kind and method_ret_class,
// which the CocoaBaseMCP rebuild added.
//===----------------------------------------------------------------------===//

// Which framework declares a class. Needed before the runtime can be asked
// anything about it: objc_getClass("NSView") is nil until AppKit is in the
// process, and objc_allocateClassPair against a nil superclass builds a root
// class that silently does nothing. BridgeSupport carries the attribution the
// runtime dump cannot -- see "Two oracles" in COCOA_CLASS_DESIGN.md.
// Ordered, not just LIMIT 1: BridgeSupport lists NSObject in every framework
// that mentions it -- around seventy of them -- so an unordered pick answers
// "AVFAudio" for NSObject and the compiler emits a dlopen of AVFAudio into
// every class that inherits from it. Foundation first, then AppKit, then
// alphabetically so the answer is at least the same on two runs.
constexpr StringRef kClassFrameworkSQL =
    "SELECT framework FROM bs_classes WHERE name = ?1 "
    "ORDER BY CASE framework WHEN 'Foundation' THEN 0 WHEN 'AppKit' THEN 1 "
    "ELSE 2 END, framework LIMIT 1";

// Returned as the character's CODE POINT rather than the character, so it
// arrives as an integer the parameter evaluator can fold into a conditional
// type. The table itself stays readable.
// Written out rather than macro-generated: COCOAKB_METHOD_CTE projects
// `m.<column>` and this needs a function call around the column. It is also
// #undef'd well above here.
constexpr StringRef kMethodRetKindSQL =
    "WITH RECURSIVE chain(c, depth) AS ("
    "  SELECT ?1, 0"
    "  UNION ALL"
    "  SELECT rc.superclass, chain.depth + 1 FROM rt_classes rc, chain"
    "    WHERE rc.name = chain.c AND rc.superclass IS NOT NULL)"
    " SELECT unicode(m.kind) FROM chain JOIN method_ret_kind m"
    "   ON m.class = chain.c AND m.selector = ?2"
    "  AND m.is_class = CAST(?3 AS INTEGER)"
    " ORDER BY chain.depth LIMIT 1";

// Resolving it in SQL rather than in the caller is not only tidier. The
// caller would have to compare the answer against "@self", and a string
// comparison does not fold during parameter evaluation -- so a type
// conditioned on it stays symbolic and the whole point is lost.
constexpr StringRef kMethodRetObjCClassSQL =
    "WITH RECURSIVE chain(c, depth) AS ("
    "  SELECT ?1, 0"
    "  UNION ALL"
    "  SELECT rc.superclass, chain.depth + 1 FROM rt_classes rc, chain"
    "    WHERE rc.name = chain.c AND rc.superclass IS NOT NULL)"
    // ?1, not chain.c: the chain walk finds `alloc` on NSObject, which is
    // where it is DECLARED, and the whole point of the sentinel is that the
    // answer is where the message was SENT. `[NSString alloc]` is an NSString.
    " SELECT CASE WHEN m.ret_class = '@self' THEN ?1 ELSE m.ret_class END"
    "   FROM chain JOIN method_ret_class m"
    "     ON m.class = chain.c AND m.selector = ?2"
    "    AND m.is_class = CAST(?3 AS INTEGER)"
    " ORDER BY chain.depth LIMIT 1";

// Answers 0 rather than nothing for a name the class does not have. A
// missing row would make the query fail to fold, the result type would stay
// symbolic, and the author would see a wall of unevaluated conditional
// instead of "NSString has no lenght". The caller turns 0 into that sentence.
constexpr StringRef kRetKindForNameSQL =
    "WITH RECURSIVE chain(c, depth) AS ("
    "  SELECT ?1, 0"
    "  UNION ALL"
    "  SELECT rc.superclass, chain.depth + 1 FROM rt_classes rc, chain"
    "    WHERE rc.name = chain.c AND rc.superclass IS NOT NULL)"
    " SELECT COALESCE(("
    "   SELECT unicode(m.kind) FROM chain JOIN method_ret_kind m"
    "     ON m.class = chain.c"
    "    AND m.selector = CASE WHEN CAST(?4 AS INTEGER) = 0"
    "                        THEN replace(?2, '_', ':')"
    "                        ELSE replace(?2, '_', ':') || ':' END"
    "    AND m.is_class = CAST(?3 AS INTEGER)"
    "  ORDER BY chain.depth LIMIT 1), 0)";

// An object whose class is not recorded is answered as NSObject, which is
// true of every object and is the honest upper bound: precise where the SDK
// knows, sound where it does not. Always returns a row, so a caller can ask
// unconditionally and use the answer only when the kind says object.
// COALESCE has to wrap the whole lookup, not the selected column: a JOIN
// that matches nothing returns NO ROWS, and a default inside the projection
// never runs. Written out rather than macro-generated for that reason.
constexpr StringRef kRetClassForNameSQL =
    "WITH RECURSIVE chain(c, depth) AS ("
    "  SELECT ?1, 0"
    "  UNION ALL"
    "  SELECT rc.superclass, chain.depth + 1 FROM rt_classes rc, chain"
    "    WHERE rc.name = chain.c AND rc.superclass IS NOT NULL)"
    " SELECT COALESCE(("
    "   SELECT CASE WHEN m.ret_class = '@self' THEN ?1 ELSE m.ret_class END"
    "     FROM chain JOIN method_ret_class m"
    "       ON m.class = chain.c"
    "      AND m.selector = CASE WHEN CAST(?4 AS INTEGER) = 0"
    "                          THEN replace(?2, '_', ':')"
    "                          ELSE replace(?2, '_', ':') || ':' END"
    "      AND m.is_class = CAST(?3 AS INTEGER)"
    "    ORDER BY chain.depth LIMIT 1), 'NSObject')";

constexpr StringRef kSelectorRetKindSQL =
    "SELECT unicode(kind) FROM method_ret_kind WHERE selector = ?1 "
    "GROUP BY kind ORDER BY COUNT(*) DESC LIMIT 1";

// NOT ABI-neutral, despite arriving with the batch above: `ret_class` is the
// REGISTER class of the result, so this reads the x86-64 table. Imported from
// the sibling as `method_abi` (arm64) and corrected here -- the second time in
// this file that a straight copy would have answered for the wrong machine.
constexpr StringRef kSelectorRetClassSQL =
    "SELECT ret_class FROM method_abi_x64 WHERE selector = ?1 "
    "GROUP BY ret_class ORDER BY COUNT(*) DESC LIMIT 1";




llvm::Error CocoaKBDatabase::availability() {
  std::lock_guard<std::mutex> lock(mutex);
  if (auto err = openLocked())
    return err;
  return llvm::Error::success();
}

std::optional<std::string>
CocoaKBDatabase::lookup(StringRef query, ArrayRef<StringRef> args) {
  auto result = queryString(query, args);
  if (!result) {
    llvm::consumeError(result.takeError());
    return std::nullopt;
  }
  return *result;
}

} // namespace M::KGEN::CocoaKB
