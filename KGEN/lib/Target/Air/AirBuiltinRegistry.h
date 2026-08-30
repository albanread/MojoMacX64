//===- AirBuiltinRegistry.h - AIR builtin lowering contract ------*- C++ -*-===//
//
// The `llvm.air.*` names accepted from Mojo and the `air.*` declarations sent
// to Apple's reader form a compiler ABI.  Keep the family-level policy here so
// the MLIR lowering and the final LLVM legalization cannot silently drift.
// Target-specific type adapters remain beside their respective IRs; the set of
// representable payloads and the spelling of their suffixes live here.
//
//===----------------------------------------------------------------------===//

#ifndef KGEN_TARGET_AIR_AIRBUILTINREGISTRY_H
#define KGEN_TARGET_AIR_AIRBUILTINREGISTRY_H

#include <cstdint>
#include <optional>
#include <string>

#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/StringRef.h"

namespace M::KGEN::Air {

enum class BuiltinSignature : uint8_t {
  Barrier,
  Unary,
  Binary,
  Ternary,
  Shuffle,
  Ballot,
};

enum class PayloadDomain : uint8_t {
  None,
  Floating,
  FloatingOrInteger,
};

struct BuiltinFamily {
  llvm::StringLiteral stem;
  BuiltinSignature signature;
  PayloadDomain payloadDomain;
  bool convergent;
  bool carriesTypeSuffix;
};

/// Every AIR family for which this backend constructs a runtime declaration.
/// A family omitted here is not implicitly accepted merely because it starts
/// with `air.`.
inline llvm::ArrayRef<BuiltinFamily> builtinFamilies() {
  static constexpr BuiltinFamily families[] = {
      {"air.wg.barrier", BuiltinSignature::Barrier, PayloadDomain::None, true,
       false},
      {"air.simdgroup.barrier", BuiltinSignature::Barrier, PayloadDomain::None,
       true, false},

      {"air.simd_shuffle_xor", BuiltinSignature::Shuffle,
       PayloadDomain::FloatingOrInteger, true, true},
      {"air.simd_shuffle_down", BuiltinSignature::Shuffle,
       PayloadDomain::FloatingOrInteger, true, true},
      {"air.simd_shuffle_up", BuiltinSignature::Shuffle,
       PayloadDomain::FloatingOrInteger, true, true},
      {"air.simd_shuffle", BuiltinSignature::Shuffle,
       PayloadDomain::FloatingOrInteger, true, true},
      {"air.simd_sum", BuiltinSignature::Unary,
       PayloadDomain::FloatingOrInteger, true, true},
      {"air.simd_prefix_exclusive_sum", BuiltinSignature::Unary,
       PayloadDomain::FloatingOrInteger, true, true},
      {"air.simd_prefix_inclusive_sum", BuiltinSignature::Unary,
       PayloadDomain::FloatingOrInteger, true, true},
      {"air.simd_min", BuiltinSignature::Unary,
       PayloadDomain::FloatingOrInteger, true, true},
      {"air.simd_max", BuiltinSignature::Unary,
       PayloadDomain::FloatingOrInteger, true, true},
      {"air.simd_product", BuiltinSignature::Unary,
       PayloadDomain::FloatingOrInteger, true, true},

      // Ballot is explicitly pre-mangled in warp.mojo.  Its payload is i1,
      // while its result/name type is i32, so treating it as an ordinary
      // first-operand overload produces the wrong name.
      {"air.simd_ballot.i32", BuiltinSignature::Ballot, PayloadDomain::None,
       true, false},

      {"air.cos", BuiltinSignature::Unary, PayloadDomain::Floating, false,
       true},
      {"air.sin", BuiltinSignature::Unary, PayloadDomain::Floating, false,
       true},
      {"air.tan", BuiltinSignature::Unary, PayloadDomain::Floating, false,
       true},
      {"air.acos", BuiltinSignature::Unary, PayloadDomain::Floating, false,
       true},
      {"air.asin", BuiltinSignature::Unary, PayloadDomain::Floating, false,
       true},
      {"air.atan", BuiltinSignature::Unary, PayloadDomain::Floating, false,
       true},
      {"air.cosh", BuiltinSignature::Unary, PayloadDomain::Floating, false,
       true},
      {"air.sinh", BuiltinSignature::Unary, PayloadDomain::Floating, false,
       true},
      {"air.tanh", BuiltinSignature::Unary, PayloadDomain::Floating, false,
       true},
      {"air.exp", BuiltinSignature::Unary, PayloadDomain::Floating, false,
       true},
      {"air.exp2", BuiltinSignature::Unary, PayloadDomain::Floating, false,
       true},
      {"air.exp10", BuiltinSignature::Unary, PayloadDomain::Floating, false,
       true},
      {"air.log", BuiltinSignature::Unary, PayloadDomain::Floating, false,
       true},
      {"air.log2", BuiltinSignature::Unary, PayloadDomain::Floating, false,
       true},
      {"air.log10", BuiltinSignature::Unary, PayloadDomain::Floating, false,
       true},
      {"air.sqrt", BuiltinSignature::Unary, PayloadDomain::Floating, false,
       true},
      {"air.rsqrt", BuiltinSignature::Unary, PayloadDomain::Floating, false,
       true},
      {"air.fabs", BuiltinSignature::Unary, PayloadDomain::Floating, false,
       true},
      {"air.floor", BuiltinSignature::Unary, PayloadDomain::Floating, false,
       true},
      {"air.ceil", BuiltinSignature::Unary, PayloadDomain::Floating, false,
       true},
      {"air.rint", BuiltinSignature::Unary, PayloadDomain::Floating, false,
       true},
      {"air.trunc", BuiltinSignature::Unary, PayloadDomain::Floating, false,
       true},
      {"air.round", BuiltinSignature::Unary, PayloadDomain::Floating, false,
       true},
      {"air.recip", BuiltinSignature::Unary, PayloadDomain::Floating, false,
       true},
      {"air.frac", BuiltinSignature::Unary, PayloadDomain::Floating, false,
       true},

      {"air.fmin", BuiltinSignature::Binary, PayloadDomain::Floating, false,
       true},
      {"air.fmax", BuiltinSignature::Binary, PayloadDomain::Floating, false,
       true},
      {"air.pow", BuiltinSignature::Binary, PayloadDomain::Floating, false,
       true},
      {"air.powr", BuiltinSignature::Binary, PayloadDomain::Floating, false,
       true},
      {"air.fmod", BuiltinSignature::Binary, PayloadDomain::Floating, false,
       true},
      {"air.copysign", BuiltinSignature::Binary, PayloadDomain::Floating, false,
       true},
      {"air.divide", BuiltinSignature::Binary, PayloadDomain::Floating, false,
       true},

      {"air.fma", BuiltinSignature::Ternary, PayloadDomain::Floating, false,
       true},
  };
  return families;
}

inline const BuiltinFamily *findBuiltinFamily(llvm::StringRef stem) {
  for (const BuiltinFamily &family : builtinFamilies())
    if (stem == family.stem)
      return &family;
  return nullptr;
}

inline bool builtinNeedsTypeSuffix(llvm::StringRef stem) {
  const BuiltinFamily *family = findBuiltinFamily(stem);
  return family && family->carriesTypeSuffix;
}

/// Shared spelling for the ordinary single-payload AIR overloads.
///
/// Integer suffixes are unsigned because the only generic integer operations
/// this backend may infer from signless IR are bit moves and operations whose
/// two's-complement result is signedness-independent.  Integer min/max are
/// rejected by the lowering before reaching this helper.
inline std::optional<std::string> payloadTypeSuffix(bool isFloating,
                                                    unsigned bitWidth,
                                                    unsigned vectorWidth = 1) {
  llvm::StringRef scalar;
  if (isFloating) {
    if (bitWidth == 16)
      scalar = "f16";
    else if (bitWidth == 32)
      scalar = "f32";
    else
      return std::nullopt;
  } else {
    if (bitWidth == 8)
      scalar = "i8";
    else if (bitWidth == 16)
      scalar = "i16";
    else if (bitWidth == 32)
      scalar = "i32";
    else
      return std::nullopt;
  }

  std::string suffix = isFloating ? "." : ".u.";
  if (vectorWidth != 1)
    suffix += "v" + std::to_string(vectorWidth);
  suffix += scalar.str();
  return suffix;
}

/// True for calls whose participating-lane identity is semantically visible.
/// Accepts the temporary `$<signature>` tag and final type suffixes so both IR
/// stages ask the same question.
inline bool isConvergentBuiltin(llvm::StringRef name) {
  if (name.starts_with("air.simdgroup_matrix_") ||
      name.starts_with("air.quad_"))
    return true;
  for (const BuiltinFamily &family : builtinFamilies()) {
    if (!family.convergent || !name.starts_with(family.stem))
      continue;
    if (name.size() == family.stem.size())
      return true;
    const char delimiter = name[family.stem.size()];
    if (delimiter == '.' || delimiter == '$')
      return true;
  }
  return false;
}

} // namespace M::KGEN::Air

#endif
