//===- AirLegality.h - Data-driven legality firewall for AIR -------------===//
//
// A table of rules, each independently set to permit / log / fail.
//
// Why a table and not a pile of `if`s: LLVM's verifier is target-agnostic by
// construction, so it cannot see any of this. `i4` is a valid LLVM type;
// address-space *meaning* is target-defined. Every AIR defect this backend has
// shipped was legal LLVM IR that was illegal for the target, and each was
// found one crash at a time, days apart, from an error naming nothing.
//
// A rule added as `Fail` on day one is a rule that stops the build on its
// first false positive, and a gate that cries wolf gets switched off. So each
// rule carries its own action and every rule is listed from the start, most of
// them at `Log`. Promote to `Fail` once a full sweep is clean.
//
//===----------------------------------------------------------------------===//

#ifndef KGEN_OBJECTCOMPILER_TARGET_AIR_AIRLEGALITY_H
#define KGEN_OBJECTCOMPILER_TARGET_AIR_AIRLEGALITY_H

#include <string>
#include <vector>

#include "llvm/ADT/StringRef.h"

namespace llvm {
class Module;
}

namespace M::KGEN::Air {

/// What to do when a rule matches.
enum class RuleAction {
  Permit, ///< do not even check
  Log,    ///< report to stderr, keep going
  Fail,   ///< report and abort the compile
};

/// One finding, tagged with the rule that produced it.
struct Finding {
  llvm::StringRef ruleId;
  std::string detail;
  RuleAction action;
};

/// Run every non-Permit rule over `m`.
///
/// Findings come back tagged; the caller decides what to print and whether any
/// `Fail` finding stops the compile. Config is read once from the environment
/// (see `configureFromEnv`).
std::vector<Finding> checkLegality(llvm::Module &m);

/// Apply the transforms that are enabled: the llvm.*->air.* rename table and
/// the correctness guards. Returns true if anything changed.
bool applyTransforms(llvm::Module &m);

/// Parse APPLEGPU_AIR_RULES. Idempotent; called automatically on first use.
///
///   APPLEGPU_AIR_RULES="all=log,generic-load=fail,addrspacecast=permit"
///
/// Names are the rule ids in the table. `all` sets every rule at once and may
/// be combined with later overrides -- last assignment wins. Values are
/// permit / log / fail, and off / warn / error are accepted as synonyms.
void configureFromEnv();

/// Print the rule and transform tables with each entry's ACTIVE setting.
/// Called automatically when APPLEGPU_AIR_RULES contains `list`.
void printRuleTable();

/// Enumerate declaration-only symbols the Apple reader would have to resolve,
/// validate `air.*` names and function types against the builtin registry, and
/// report non-AIR symbols not on the measured allowlist. Separate from
/// checkLegality because it must run on the FINAL module, immediately before
/// bitcode serialization: the downgrade pipeline and PointerRewriter both
/// strand declarations after the earlier sweeps have run.
std::vector<Finding> checkExternals(llvm::Module &m);

/// Print every finding to stderr, changing nothing. Exposed so
/// `kgen-llvm-opt -passes=air-legality` can review a corpus of .ll files under
/// exactly the rules the backend enforces -- outside any bazel action, where
/// setting APPLEGPU_AIR_RULES would re-key every action and force a rebuild.
void reportLegality(llvm::Module &m);

} // namespace M::KGEN::Air

#endif
