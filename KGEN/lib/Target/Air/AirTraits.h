//===----------------------------------------------------------------------===//
// VEGA-FORK: TargetTraits for Apple AIR (air64) — the Metal GPU target.
// Fills the shape the upstream hooks were built for (codegenTriple,
// forcedBitcodeVersion) with the profile verified on this machine's
// Radeon Pro Vega II in spike S1: AIR 2.6 bitcode in LLVM-17 encoding.
//===----------------------------------------------------------------------===//

#ifndef KGEN_TARGET_AIR_AIRTRAITS_H
#define KGEN_TARGET_AIR_AIRTRAITS_H

#include "Target/TargetTraits.h"

#include "llvm/TargetParser/Triple.h"

namespace M::KGEN {

struct AirTraits final : TargetTraits {
  llvm::StringRef name() const override { return "air"; }
  bool matches(const llvm::Triple &triple) const override {
    return triple.str().starts_with("air64");
  }
  bool isGPU() const override { return true; }
  llvm::StringRef getAsmExtension() const override { return ".air.ll"; }
  llvm::StringRef getLLVMExtension() const override { return ".air-in.ll"; }
  llvm::StringRef getObjectExtension() const override { return ".metallib"; }

  /// AIR has no LLVM codegen target; the TargetMachine (used for the opt
  /// pipeline only) is built for arm64, matching upstream's "Metal GPU
  /// targets use ARM64 during compilation" convention. The bazel-built LLVM
  /// carries the AArch64 backend.
  std::string codegenTriple(llvm::StringRef triple) const override {
    return "arm64-apple-macosx14.2.0";
  }

  /// The hardware-verified AIR profile is LLVM-17-encoded bitcode.
  unsigned forcedBitcodeVersion() const override { return 17; }

  llvm::StringRef acceleratorSectionTitle() const override {
    return "Apple Metal (MacVegaFork)";
  }
  llvm::ArrayRef<AcceleratorArch> supportedAcceleratorArchs() const override {
    static const AcceleratorArch archs[] = {
        {"metal-vega2", "Radeon Pro Vega II 32GB through Metal (wave64)"},
    };
    return archs;
  }

  static const AirTraits &get();

protected:
  bool isBaseTarget() const override { return false; }
};

} // namespace M::KGEN

#endif // KGEN_TARGET_AIR_AIRTRAITS_H
