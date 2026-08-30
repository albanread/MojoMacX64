//===- CocoaCompletion.cpp - Cocoa completion from the SDK database -------===//

#include "KGEN/CocoaKB/CocoaCompletion.h"
#include "KGEN/Support/Configuration.h"

#include "llvm/ADT/SmallString.h"
#include "llvm/ADT/StringExtras.h"

#include <mutex>
#include <sqlite3.h>

using namespace llvm;

namespace M::KGEN::CocoaKB {
namespace {

/// A read-only handle on cocoa.sqlite, opened once per process.
///
/// The evaluator has its own; sharing one would mean sharing a mutex between
/// compilation and an editor keystroke, and these have very different latency
/// expectations. sqlite handles multiple readers of the same file fine.
class Database {
public:
  static Database &get() {
    static Database instance;
    return instance;
  }

  sqlite3 *handle() {
    std::lock_guard<std::mutex> lock(mutex);
    if (!attempted) {
      attempted = true;
      // The config object owns the string, so copy before it goes away.
      auto configOr = MojoConfig::open();
      std::string path =
          configOr.isError() ? std::string()
                             : configOr.get().getCocoaKBPath().str();
      if (!path.empty() &&
          sqlite3_open_v2(path.c_str(), &db, SQLITE_OPEN_READONLY, nullptr) !=
              SQLITE_OK) {
        if (db)
          sqlite3_close(db);
        db = nullptr;
      }
    }
    return db;
  }

  std::mutex &lock() { return queryMutex; }

private:
  Database() = default;
  std::mutex mutex;
  std::mutex queryMutex;
  sqlite3 *db = nullptr;
  bool attempted = false;
};

/// Run `sql` with text parameters and hand each row to `onRow`.
void eachRow(StringRef sql, ArrayRef<std::string> args,
             function_ref<void(sqlite3_stmt *)> onRow) {
  Database &database = Database::get();
  sqlite3 *db = database.handle();
  if (!db)
    return;

  std::lock_guard<std::mutex> lock(database.lock());
  sqlite3_stmt *stmt = nullptr;
  if (sqlite3_prepare_v2(db, sql.str().c_str(), -1, &stmt, nullptr) != SQLITE_OK)
    return;
  for (auto [index, arg] : llvm::enumerate(args))
    sqlite3_bind_text(stmt, static_cast<int>(index + 1), arg.c_str(),
                      static_cast<int>(arg.size()), SQLITE_TRANSIENT);
  while (sqlite3_step(stmt) == SQLITE_ROW)
    onRow(stmt);
  sqlite3_finalize(stmt);
}

std::string columnText(sqlite3_stmt *stmt, int col) {
  const auto *text = sqlite3_column_text(stmt, col);
  if (!text)
    return {};
  return std::string(reinterpret_cast<const char *>(text),
                     sqlite3_column_bytes(stmt, col));
}

/// LIKE pattern for a prefix match, with the characters LIKE treats specially
/// escaped. A user typing "NS_" means an underscore, not "any character".
std::string likePrefix(StringRef prefix) {
  std::string out;
  out.reserve(prefix.size() + 4);
  for (char c : prefix) {
    if (c == '%' || c == '_' || c == '\\')
      out.push_back('\\');
    out.push_back(c);
  }
  out.push_back('%');
  return out;
}

/// One type out of an @encode string, advancing `enc` past it.
///
/// This is not a complete decoder -- it handles what appears in method
/// signatures, which is most of the encoding grammar but not the whole of it.
/// Anything unrecognised comes back as the raw character so the result stays
/// readable rather than becoming wrong.
std::string decodeOne(StringRef &enc) {
  // Qualifiers that can precede a type in a method signature.
  while (!enc.empty() && StringRef("rnNoORV").contains(enc.front()))
    enc = enc.drop_front();
  if (enc.empty())
    return {};

  char c = enc.front();
  enc = enc.drop_front();
  switch (c) {
  case 'v': return "None";
  case 'c': return "Int8";
  case 'C': return "UInt8";
  case 's': return "Int16";
  case 'S': return "UInt16";
  case 'i': return "Int32";
  case 'I': return "UInt32";
  case 'l': return "Int32";
  case 'L': return "UInt32";
  case 'q': return "Int";
  case 'Q': return "UInt";
  case 'f': return "Float32";
  case 'd': return "Float64";
  case 'B': return "Bool";
  case '*': return "UnsafePointer[Int8]";
  case '#': return "ObjCClass";
  case ':': return "SEL";
  case '@': {
    // An object may name its class: @"NSString".
    if (!enc.empty() && enc.front() == '"') {
      enc = enc.drop_front();
      size_t end = enc.find('"');
      if (end != StringRef::npos) {
        std::string cls = enc.substr(0, end).str();
        enc = enc.drop_front(end + 1);
        return cls;
      }
    }
    return "ObjCObject";
  }
  case '^': {
    std::string pointee = decodeOne(enc);
    return "UnsafePointer[" + pointee + "]";
  }
  case '{': {
    // {CGRect=dddd} -- the name is the useful half.
    size_t eq = enc.find_first_of("=}");
    std::string name = enc.substr(0, eq == StringRef::npos ? 0 : eq).str();
    // Skip to the matching brace, counting nesting.
    unsigned depth = 1;
    while (!enc.empty() && depth) {
      char d = enc.front();
      enc = enc.drop_front();
      if (d == '{')
        ++depth;
      else if (d == '}')
        --depth;
    }
    return name.empty() ? "struct" : name;
  }
  case '[': {
    // [16i] -- a fixed array.
    size_t end = enc.find(']');
    std::string body = enc.substr(0, end == StringRef::npos ? 0 : end).str();
    if (end != StringRef::npos)
      enc = enc.drop_front(end + 1);
    return "Array[" + body + "]";
  }
  case '?': return "fn";
  default:  return std::string(1, c);
  }
}

} // namespace

std::string describeEncoding(StringRef encoding) {
  if (encoding.empty())
    return {};
  StringRef enc = encoding;

  // Encodings carry frame offsets (v24@0:8@16); they are not type information
  // and only get in the way here.
  auto stripDigits = [](StringRef &s) {
    while (!s.empty() && isDigit(s.front()))
      s = s.drop_front();
  };

  std::string ret = decodeOne(enc);
  stripDigits(enc);
  SmallVector<std::string> args;
  while (!enc.empty()) {
    std::string arg = decodeOne(enc);
    stripDigits(enc);
    if (arg.empty())
      break;
    args.push_back(arg);
  }
  if (ret.empty())
    return encoding.str();

  // Every Objective-C method begins with self and _cmd. Saying so in a tooltip
  // is noise -- what the reader wants is the arguments they have to supply.
  if (args.size() >= 2)
    args.erase(args.begin(), args.begin() + 2);

  std::string out = "(" + llvm::join(args, ", ") + ") -> " + ret;
  return out;
}

bool available() { return Database::get().handle() != nullptr; }

std::vector<CompletionItem> completeClasses(StringRef prefix, unsigned limit) {
  std::vector<CompletionItem> results;
  // rt_classes is the runtime's own view: every class actually present, with
  // its superclass. bs_classes is BridgeSupport's smaller, documented subset.
  static constexpr StringRef kSQL =
      "SELECT name, superclass FROM rt_classes "
      "WHERE name LIKE ?1 ESCAPE '\\' ORDER BY length(name), name LIMIT ?2";
  eachRow(kSQL, {likePrefix(prefix), std::to_string(limit)},
          [&](sqlite3_stmt *stmt) {
            CompletionItem item;
            item.name = columnText(stmt, 0);
            std::string super = columnText(stmt, 1);
            if (!super.empty())
              item.detail = ": " + super;
            results.push_back(std::move(item));
          });
  return results;
}

std::vector<CompletionItem> completeSelectors(StringRef cls, StringRef prefix,
                                              bool classMethods,
                                              unsigned limit) {
  std::vector<CompletionItem> results;
  if (cls.empty())
    return results;

  // Walk the superclass chain in SQL. Inherited selectors are most of what
  // anyone types -- alloc and init are on NSObject, not on NSWindow -- and a
  // recursive CTE gets them in one query instead of a round trip per level.
  //
  // The depth column doubles as the ranking: a selector declared on the class
  // itself should sort above one inherited from NSObject.
  static constexpr StringRef kSQL =
      "WITH RECURSIVE chain(name, depth) AS ("
      "  SELECT ?1, 0"
      "  UNION ALL"
      "  SELECT rt_classes.superclass, chain.depth + 1"
      "    FROM rt_classes JOIN chain ON rt_classes.name = chain.name"
      "   WHERE rt_classes.superclass IS NOT NULL AND chain.depth < 32"
      ") "
      "SELECT m.selector, m.encoding, m.class, MIN(chain.depth) AS d "
      "  FROM rt_methods m JOIN chain ON m.class = chain.name "
      " WHERE m.is_class = ?2 AND m.selector LIKE ?3 ESCAPE '\\' "
      " GROUP BY m.selector "
      " ORDER BY d, length(m.selector), m.selector "
      " LIMIT ?4";

  eachRow(kSQL,
          {cls.str(), classMethods ? "1" : "0", likePrefix(prefix),
           std::to_string(limit)},
          [&](sqlite3_stmt *stmt) {
            CompletionItem item;
            item.name = columnText(stmt, 0);
            item.isClassMethod = classMethods;
            std::string encoding = columnText(stmt, 1);
            std::string owner = columnText(stmt, 2);
            item.detail = describeEncoding(encoding);
            // Where it came from matters when it is not this class.
            if (!owner.empty() && owner != cls.str())
              item.documentation = "Inherited from `" + owner + "`\n\n";
            if (!encoding.empty())
              item.documentation += "`" + encoding + "`";
            results.push_back(std::move(item));
          });
  return results;
}

} // namespace M::KGEN::CocoaKB
