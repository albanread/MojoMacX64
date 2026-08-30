//===- AirLegality.cpp - Data-driven legality firewall for AIR -----------===//

#include "AirLegality.h"
#include "Target/Air/AirBuiltinRegistry.h"

#include <cstdlib>
#include <mutex>

#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringMap.h"
#include "llvm/ADT/DepthFirstIterator.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/PostDominators.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/FormatVariadic.h"
#include "llvm/Support/raw_ostream.h"

namespace M::KGEN::Air {
namespace {

//===----------------------------------------------------------------------===//
// The rule table
//===----------------------------------------------------------------------===//
//
// `evidence` says how we know. "measured" means this backend shipped the
// defect and the fix was verified on an M4. "air-poc" means it comes from the
// out-of-tree LLVM AIR backend at github.com/imperatormk/llvm-project
// (Apache-2.0 WITH LLVM-exception), reconstructed black-box the same way ours
// was -- so it is evidence, not specification, and stays at Log until we have
// confirmed it against our own oracle.

struct Rule {
  llvm::StringRef id;
  RuleAction action;
  llvm::StringRef evidence;
  llvm::StringRef what;
};

// clang-format off
Rule Rules[] = {
  // --- measured here, and the fix is in: safe to fail the build on ---------
  {"mask-bitcast",         RuleAction::Fail,   "measured",
   "bitcast between <N x i1> and iN -- InstCombine's `any(mask)` idiom. This "
   "is the form that was MEASURED to pass verifyModule, metallib AND air-opt "
   "and then kill the compiler service at pipeline creation"},
  {"odd-int-width",        RuleAction::Log,    "unproven",
   "integer width outside 1/8/16/32/64, other than the mask bitcast above. "
   "LOG, not fail: generalising from the i4 mask case was wrong. "
   "test_grid_dim emits `trunc i64 to i2` and passes, so the reader clearly "
   "tolerates at least some odd widths. Narrow this only with evidence"},
  {"native-int-float-cast", RuleAction::Fail,  "measured",
   "sitofp/uitofp/fptosi/fptoui -- Apple's compiler emits none of these ever; "
   "they must be air.convert.* calls"},
  {"vector-fp-cast",       RuleAction::Fail,   "measured",
   "vector fpext/fptrunc -- the scalar form is fine, the vector form is "
   "computed wrongly by the driver with no error"},
  {"vector-llvm-fma",      RuleAction::Fail,   "measured",
   "vector llvm.fma -- Apple spells it air.fma.<ty>; scalar llvm.fma.f32 is "
   "accepted"},

  {"unknown-air-symbol",   RuleAction::Fail,   "measured",
   "air.* declaration whose name or LLVM function type is not in the AIR "
   "runtime contract. A misspelled name or wrong signature survives metallib "
   "and kills the compiler service at pipeline creation"},
  {"unresolved-external",  RuleAction::Log,    "measured",
   "declaration-only symbol that Apple's reader may not resolve. Keep this at "
   "LOG until each live intrinsic in the expanded corpus is classified: "
   "llvm.vector.reduce.fadd currently reaches three packaged modules, but a "
   "metallib alone does not prove successful driver pipeline creation"},

  {"divergent-barrier",    RuleAction::Fail,   "semantic",
   "air.wg.barrier whose execution is control-dependent on an AIR thread, "
   "lane, or simdgroup identity. A workgroup barrier is one dynamic rendezvous "
   "for the whole threadgroup; selecting or skipping it per thread can silently "
   "expose partially written threadgroup memory"},

  // --- measured here, but still finding false positives: log only ----------
  {"generic-deref",        RuleAction::Log,    "measured",
   "load/store/atomic through an addrspace(0) pointer that is not "
   "alloca-derived. AIR has no generic space, so the access reads zero and "
   "writes nowhere -- silently, with correct-looking IR"},
  {"addrspacecast",        RuleAction::Log,    "measured",
   "addrspacecast -- Apple emits none; the idiom is ptrtoint+inttoptr. A "
   "same-space cast is also invalid IR outright"},
  {"dead-intrinsic-decl",  RuleAction::Log,    "measured",
   "llvm.* declaration nothing calls -- the reader resolves every declared "
   "symbol, so a dead declare is as fatal as a live call and far harder to "
   "see"},

  // --- from air-poc, unconfirmed on our hardware: log only -----------------
  {"unmapped-llvm-intrinsic", RuleAction::Log, "unproven",
   "VECTOR llvm.* math intrinsic that has a known air.* equivalent. NOTE the "
   "evidence is weaker than it looks and this rule is probably still too "
   "broad. llvm.fma.v4f32 was measured to kill pipeline creation, but "
   "llvm.maxnum.v4f32 is emitted 661 times across 10 tests and is evidently "
   "tolerated: turning rename-llvm-intrinsics on changed nothing for the "
   "three failing tests that carry it. Scalar forms are definitely fine -- "
   "Apple emits llvm.fma.f32 itself. Treat a hit here as a question, not an "
   "answer, until the specific intrinsic has been tested"},
  {"nan-minmax-unwrapped", RuleAction::Permit, "air-poc",
   "air.fmin/air.fmax with no NaN-propagation select. OFF BY DEFAULT and kept "
   "only as documentation: it cannot work as a detection rule. AIR's fmin/fmax "
   "drop NaN, but that is CORRECT for llvm.minnum/maxnum and wrong only for "
   "llvm.minimum/maximum -- and after renaming the two are indistinguishable. "
   "Apple's own output trips this 4 times. The correctness belongs in the "
   "guard-nan-minmax transform, which wraps only calls it renamed from "
   "minimum/maximum"},
  {"i64-simd-shuffle",     RuleAction::Log,    "air-poc",
   "i64 air.simd_shuffle -- the GPU JIT rejects it; rewrite as bitcast to "
   "<2 x i32>, shuffle, bitcast back"},
  {"f64",                  RuleAction::Log,    "air-poc",
   "double anywhere -- Apple Silicon has no f64; it must be demoted"},
  {"int-to-bf16",          RuleAction::Log,    "air-poc",
   "direct int->bfloat conversion -- must go via float, then bit-shuffle"},
  {"nonvolatile-loop-load", RuleAction::Log,   "air-poc",
   "device load in a loop whose body also stores through the same pointer, "
   "not marked volatile -- LLVM hoists it and the reduction reads stale data"},
  {"unguarded-scalar-store", RuleAction::Log,  "air-poc",
   "device store in a kernel with no per-thread index -- every thread in the "
   "group writes the same address unless guarded by tid.x == 0"},
};
// clang-format on

//===----------------------------------------------------------------------===//
// llvm.* -> air.* rename table
//===----------------------------------------------------------------------===//
//
// Ported from AIRIntrinsicMappings.td in the out-of-tree LLVM AIR backend
// (github.com/imperatormk/llvm-project, Apache-2.0 WITH LLVM-exception).
// Data, not code: each entry is independently checkable against `xcrun metal`
// output, and several already were -- air.fma.v4f32 was derived here by hand
// before this table was found.

struct Rename {
  llvm::StringRef llvmName;
  llvm::StringRef airName;
};

const Rename Renames[] = {
    {"llvm.maxnum.f32", "air.fmax.f32"},
    {"llvm.minnum.f32", "air.fmin.f32"},
    {"llvm.maxnum.f16", "air.fmax.f16"},
    {"llvm.minnum.f16", "air.fmin.f16"},
    {"llvm.maximum.f32", "air.fmax.f32"},
    {"llvm.minimum.f32", "air.fmin.f32"},
    {"llvm.maximum.f16", "air.fmax.f16"},
    {"llvm.minimum.f16", "air.fmin.f16"},
    {"llvm.maximum.v2f32", "air.fmax.v2f32"},
    {"llvm.maximum.v3f32", "air.fmax.v3f32"},
    {"llvm.maximum.v4f32", "air.fmax.v4f32"},
    {"llvm.minimum.v2f32", "air.fmin.v2f32"},
    {"llvm.minimum.v3f32", "air.fmin.v3f32"},
    {"llvm.minimum.v4f32", "air.fmin.v4f32"},
    {"llvm.maximum.v2f16", "air.fmax.v2f16"},
    {"llvm.maximum.v4f16", "air.fmax.v4f16"},
    {"llvm.minimum.v2f16", "air.fmin.v2f16"},
    {"llvm.minimum.v4f16", "air.fmin.v4f16"},
    {"llvm.sin.f32", "air.sin.f32"},
    {"llvm.cos.f32", "air.cos.f32"},
    {"llvm.sin.f16", "air.sin.f16"},
    {"llvm.cos.f16", "air.cos.f16"},
    {"llvm.exp.f32", "air.fast_exp.f32"},
    {"llvm.log.f32", "air.fast_log.f32"},
    {"llvm.exp2.f32", "air.exp2.f32"},
    {"llvm.log2.f32", "air.log2.f32"},
    {"llvm.pow.f32", "air.pow.f32"},
    {"llvm.exp.f16", "air.fast_exp.f16"},
    {"llvm.log.f16", "air.fast_log.f16"},
    {"llvm.exp2.f16", "air.fast_exp2.f16"},
    {"llvm.log2.f16", "air.fast_log2.f16"},
    {"llvm.sqrt.f32", "air.fast_sqrt.f32"},
    {"llvm.fabs.f32", "air.fabs.f32"},
    {"llvm.floor.f32", "air.fast_floor.f32"},
    {"llvm.ceil.f32", "air.fast_ceil.f32"},
    {"llvm.sqrt.f16", "air.fast_sqrt.f16"},
    {"llvm.fabs.f16", "air.fabs.f16"},
    {"llvm.floor.f16", "air.fast_floor.f16"},
    {"llvm.ceil.f16", "air.fast_ceil.f16"},
    {"llvm.fma.f32", "air.fma.f32"},
    {"llvm.fma.f16", "air.fma.f16"},
    {"llvm.rint.f32", "air.fast_rint.f32"},
    {"llvm.rint.f16", "air.fast_rint.f16"},
    {"llvm.maxnum.v2f32", "air.fast_fmax.v2f32"},
    {"llvm.maxnum.v3f32", "air.fast_fmax.v3f32"},
    {"llvm.maxnum.v4f32", "air.fast_fmax.v4f32"},
    {"llvm.minnum.v2f32", "air.fast_fmin.v2f32"},
    {"llvm.minnum.v3f32", "air.fast_fmin.v3f32"},
    {"llvm.minnum.v4f32", "air.fast_fmin.v4f32"},
    {"llvm.sin.v2f32", "air.sin.v2f32"},
    {"llvm.sin.v3f32", "air.sin.v3f32"},
    {"llvm.sin.v4f32", "air.sin.v4f32"},
    {"llvm.cos.v2f32", "air.cos.v2f32"},
    {"llvm.cos.v3f32", "air.cos.v3f32"},
    {"llvm.cos.v4f32", "air.cos.v4f32"},
    {"llvm.exp.v2f32", "air.fast_exp.v2f32"},
    {"llvm.exp.v3f32", "air.fast_exp.v3f32"},
    {"llvm.exp.v4f32", "air.fast_exp.v4f32"},
    {"llvm.log.v2f32", "air.fast_log.v2f32"},
    {"llvm.log.v3f32", "air.fast_log.v3f32"},
    {"llvm.log.v4f32", "air.fast_log.v4f32"},
    {"llvm.exp2.v2f32", "air.exp2.v2f32"},
    {"llvm.exp2.v3f32", "air.exp2.v3f32"},
    {"llvm.exp2.v4f32", "air.exp2.v4f32"},
    {"llvm.log2.v2f32", "air.log2.v2f32"},
    {"llvm.log2.v3f32", "air.log2.v3f32"},
    {"llvm.log2.v4f32", "air.log2.v4f32"},
    {"llvm.pow.v2f32", "air.pow.v2f32"},
    {"llvm.pow.v3f32", "air.pow.v3f32"},
    {"llvm.pow.v4f32", "air.pow.v4f32"},
    {"llvm.sqrt.v2f32", "air.fast_sqrt.v2f32"},
    {"llvm.sqrt.v3f32", "air.fast_sqrt.v3f32"},
    {"llvm.sqrt.v4f32", "air.fast_sqrt.v4f32"},
    {"llvm.fabs.v2f32", "air.fast_fabs.v2f32"},
    {"llvm.fabs.v3f32", "air.fast_fabs.v3f32"},
    {"llvm.fabs.v4f32", "air.fast_fabs.v4f32"},
    {"llvm.floor.v2f32", "air.fast_floor.v2f32"},
    {"llvm.floor.v3f32", "air.fast_floor.v3f32"},
    {"llvm.floor.v4f32", "air.fast_floor.v4f32"},
    {"llvm.ceil.v2f32", "air.fast_ceil.v2f32"},
    {"llvm.ceil.v3f32", "air.fast_ceil.v3f32"},
    {"llvm.ceil.v4f32", "air.fast_ceil.v4f32"},
    {"llvm.rint.v2f32", "air.fast_rint.v2f32"},
    {"llvm.rint.v3f32", "air.fast_rint.v3f32"},
    {"llvm.rint.v4f32", "air.fast_rint.v4f32"},
    {"llvm.fma.v2f32", "air.fma.v2f32"},
    {"llvm.fma.v3f32", "air.fma.v3f32"},
    {"llvm.fma.v4f32", "air.fma.v4f32"},
};

//===----------------------------------------------------------------------===//
// Configuration
//===----------------------------------------------------------------------===//

std::once_flag ConfigOnce;

RuleAction parseAction(llvm::StringRef v, bool &ok) {
  ok = true;
  v = v.trim();
  if (v.equals_insensitive("permit") || v.equals_insensitive("off") ||
      v.equals_insensitive("no"))
    return RuleAction::Permit;
  if (v.equals_insensitive("log") || v.equals_insensitive("warn") ||
      v.equals_insensitive("warning"))
    return RuleAction::Log;
  if (v.equals_insensitive("fail") || v.equals_insensitive("error") ||
      v.equals_insensitive("err"))
    return RuleAction::Fail;
  ok = false;
  return RuleAction::Log;
}

llvm::StringRef actionName(RuleAction a) {
  switch (a) {
  case RuleAction::Permit: return "permit";
  case RuleAction::Log:    return "log";
  case RuleAction::Fail:   return "fail";
  }
  return "?";
}

void doConfigure() {
  const char *cfg = ::getenv("APPLEGPU_AIR_RULES");
  if (!cfg || !*cfg)
    return;
  llvm::StringRef s(cfg);
  llvm::SmallVector<llvm::StringRef, 8> parts;
  s.split(parts, ',', -1, /*KeepEmpty=*/false);
  for (llvm::StringRef p : parts) {
    p = p.trim();
    if (p.equals_insensitive("list"))
      continue; // handled by listRulesIfRequested
    auto [name, val] = p.split('=');
    name = name.trim();
    val = val.trim();
    if (val.empty()) {
      llvm::errs() << "[air-rules] ignoring '" << p << "': expected id=action\n";
      continue;
    }
    bool ok = false;
    RuleAction a = parseAction(val, ok);
    if (!ok) {
      llvm::errs() << "[air-rules] ignoring '" << p << "': unknown action '"
                   << val << "' (permit|log|fail)\n";
      continue;
    }
    if (name.equals_insensitive("all")) {
      for (Rule &r : Rules)
        r.action = a;
      continue;
    }
    bool found = false;
    for (Rule &r : Rules)
      if (r.id == name) {
        r.action = a;
        found = true;
      }
    if (!found)
      llvm::errs() << "[air-rules] no such rule '" << name
                   << "' (APPLEGPU_AIR_RULES=list to see them)\n";
  }
}

const Rule *ruleFor(llvm::StringRef id) {
  for (const Rule &r : Rules)
    if (r.id == id)
      return &r;
  return nullptr;
}

//===----------------------------------------------------------------------===//
// Helpers
//===----------------------------------------------------------------------===//

bool isAllocaDerived(const llvm::Value *v);

/// Does this pointer trace back to an alloca? Private/stack memory is
/// legitimately addrspace(0), and treating it as a defect rejects most working
/// kernels -- measured: 45 findings across 13 passing tests.
bool isAllocaDerivedImpl(const llvm::Value *v, unsigned depth);

/// The alloca a pointer expression is rooted at, or null.
const llvm::AllocaInst *allocaBaseOf(const llvm::Value *p, unsigned depth) {
  for (unsigned i = 0; i < 8; ++i) {
    p = p->stripPointerCasts();
    if (const auto *a = llvm::dyn_cast<llvm::AllocaInst>(p))
      return a;
    if (const auto *g = llvm::dyn_cast<llvm::GetElementPtrInst>(p)) {
      p = g->getPointerOperand();
      continue;
    }
    return nullptr;
  }
  return nullptr;
}

bool isAllocaDerivedImpl(const llvm::Value *v, unsigned depth) {
  if (depth > 8)
    return false; // bounded: give up rather than chase a cycle
  llvm::SmallPtrSet<const llvm::Value *, 8> seen;
  llvm::SmallVector<const llvm::Value *, 8> work{v};
  while (!work.empty()) {
    const llvm::Value *cur = work.pop_back_val()->stripPointerCasts();
    if (!seen.insert(cur).second)
      continue;
    if (llvm::isa<llvm::AllocaInst>(cur))
      return true;
    if (auto *gep = llvm::dyn_cast<llvm::GetElementPtrInst>(cur)) {
      work.push_back(gep->getPointerOperand());
      continue;
    }
    if (auto *phi = llvm::dyn_cast<llvm::PHINode>(cur)) {
      for (const llvm::Value *in : phi->incoming_values())
        work.push_back(in);
      continue;
    }
    if (auto *sel = llvm::dyn_cast<llvm::SelectInst>(cur)) {
      work.push_back(sel->getTrueValue());
      work.push_back(sel->getFalseValue());
      continue;
    }
    // A pointer LOADED OUT of stack memory. `alloca [2 x ptr]` holding
    // pointers to other allocas is ordinary private indirection, and treating
    // the reload as a device access produced 77 false positives.
    //
    // But a device pointer spilled to the stack and reloaded is exactly the
    // defect this rule exists to catch, so "came off the stack" is not enough
    // on its own: follow it back to what was STORED there. Private only if
    // every store into that slot stored something itself alloca-derived.
    if (auto *ld = llvm::dyn_cast<const llvm::LoadInst>(cur)) {
      // A pointer LOADED OUT of stack memory. `alloca [2 x ptr]` holding
      // pointers to other allocas is ordinary private indirection, and
      // treating the reload as a device access produced 77 false positives.
      //
      // But a device pointer spilled to the stack and reloaded is exactly the
      // defect this rule exists to catch, so "came off the stack" is not
      // enough: follow it back to what was STORED there, and accept only if
      // every store into that slot stored something itself alloca-derived.
      //
      // This whole case may only ESTABLISH privacy or decline to; it must not
      // return false, because that would abandon the other work items and
      // report a pointer that a different path proves private. Getting that
      // wrong took suite findings from 77 to 443.
      if (const auto *base = allocaBaseOf(ld->getPointerOperand(), depth)) {
        bool sawStore = false, allPrivate = true;
        llvm::SmallPtrSet<const llvm::User *, 16> visited;
        llvm::SmallVector<const llvm::User *, 16> users(base->users());
        while (!users.empty() && allPrivate) {
          const llvm::User *u = users.pop_back_val();
          if (!visited.insert(u).second)
            continue;
          if (const auto *st = llvm::dyn_cast<llvm::StoreInst>(u)) {
            if (st->getValueOperand() != u->getOperand(1)) {
              sawStore = true;
              allPrivate = isAllocaDerivedImpl(st->getValueOperand(), depth + 1);
            }
            continue;
          }
          if (llvm::isa<llvm::BitCastInst>(u) ||
              llvm::isa<llvm::GetElementPtrInst>(u) ||
              llvm::isa<llvm::AddrSpaceCastInst>(u))
            users.append(u->user_begin(), u->user_end());
        }
        if (sawStore && allPrivate)
          return true;
      }
      continue;
    }
  }
  return false;
}

bool isAllocaDerived(const llvm::Value *v) {
  return isAllocaDerivedImpl(v, 0);
}

bool badIntWidth(unsigned w) {
  return w != 1 && w != 8 && w != 16 && w != 32 && w != 64;
}

/// Recursive search for an illegal scalar type, without descending through
/// pointers -- a struct holding an addrspace(0) pointer is normal (that is
/// what a descriptor blob IS); only dereferencing one is a defect.
llvm::StringRef illegalScalar(llvm::Type *t,
                              llvm::SmallPtrSetImpl<llvm::Type *> &seen) {
  if (!t || !seen.insert(t).second)
    return {};
  if (auto *it = llvm::dyn_cast<llvm::IntegerType>(t))
    if (badIntWidth(it->getBitWidth()))
      return "odd-int-width";

  if (t->isDoubleTy())
    return "f64";
  if (llvm::isa<llvm::PointerType>(t))
    return {};
  for (llvm::Type *sub : t->subtypes())
    if (auto why = illegalScalar(sub, seen); !why.empty())
      return why;
  return {};
}

std::string typeStr(llvm::Type *t) {
  std::string s;
  llvm::raw_string_ostream os(s);
  t->print(os);
  return s;
}

/// True for AIR builtin kernel parameters that can differ among threads in one
/// workgroup. Threadgroup position and group/grid sizes are deliberately not
/// included: they are uniform over the rendezvous domain of air.wg.barrier.
bool isWorkgroupVaryingBuiltin(llvm::StringRef tag) {
  return tag == "air.thread_position_in_grid" ||
         tag == "air.thread_position_in_threadgroup" ||
         tag == "air.thread_index_in_simdgroup" ||
         tag == "air.simdgroup_index_in_threadgroup" ||
         tag == "air.thread_index_in_threadgroup";
}

/// Read the AIR kernel argument table and collect the parameters whose values
/// vary inside a workgroup. At the final legality gate the thread builtins are
/// no longer calls: legalizeKernel has made them ordinary parameters and this
/// metadata is the authoritative description of their semantics.
void collectWorkgroupVaryingArguments(
    llvm::Module &m, const llvm::Function &fn,
    llvm::SmallPtrSetImpl<const llvm::Value *> &out) {
  const llvm::NamedMDNode *kernels = m.getNamedMetadata("air.kernel");
  if (!kernels)
    return;
  for (const llvm::MDNode *kernel : kernels->operands()) {
    if (!kernel || kernel->getNumOperands() < 3)
      continue;
    const auto *fnMD =
        llvm::dyn_cast_or_null<llvm::ValueAsMetadata>(kernel->getOperand(0));
    if (!fnMD || fnMD->getValue() != &fn)
      continue;
    const auto *args =
        llvm::dyn_cast_or_null<llvm::MDNode>(kernel->getOperand(2));
    if (!args)
      continue;
    for (const llvm::MDOperand &argOperand : args->operands()) {
      const auto *argMD =
          llvm::dyn_cast_or_null<llvm::MDNode>(argOperand.get());
      if (!argMD || argMD->getNumOperands() < 2)
        continue;
      const auto *indexMD = llvm::dyn_cast_or_null<llvm::ConstantAsMetadata>(
          argMD->getOperand(0));
      const auto *tagMD =
          llvm::dyn_cast_or_null<llvm::MDString>(argMD->getOperand(1));
      const auto *index =
          indexMD ? llvm::dyn_cast<llvm::ConstantInt>(indexMD->getValue())
                  : nullptr;
      if (!index || !tagMD || !isWorkgroupVaryingBuiltin(tagMD->getString()))
        continue;
      uint64_t argNo = index->getZExtValue();
      if (argNo < fn.arg_size())
        out.insert(fn.getArg(static_cast<unsigned>(argNo)));
    }
  }
}

/// Does `value` have an SSA data-dependence on a per-thread AIR builtin?
///
/// This intentionally follows all operands, including pointer operands of
/// loads and arguments to calls. The final AIR pipeline inlines internal
/// helpers and promotes ordinary scalar temporaries, so the generated
/// branch conditions retain this dependence in SSA. It does not invent a
/// whole-program memory-dependence analysis: a future lowering that spills a
/// thread id through unknown memory must preserve uniformity explicitly or
/// extend this verifier with MemorySSA.
bool dependsOnWorkgroupIdentity(
    const llvm::Value *value,
    const llvm::SmallPtrSetImpl<const llvm::Value *> &sources,
    llvm::SmallPtrSetImpl<const llvm::Value *> &seen) {
  if (sources.contains(value))
    return true;
  if (!seen.insert(value).second || llvm::isa<llvm::Constant>(value))
    return false;
  const auto *user = llvm::dyn_cast<llvm::User>(value);
  if (!user)
    return false;
  for (const llvm::Value *operand : user->operands())
    if (dependsOnWorkgroupIdentity(operand, sources, seen))
      return true;
  return false;
}

const llvm::Value *conditionalTerminatorValue(const llvm::Instruction &term) {
  if (const auto *branch = llvm::dyn_cast<llvm::CondBrInst>(&term))
    return branch->getCondition();
  if (const auto *sw = llvm::dyn_cast<llvm::SwitchInst>(&term))
    return sw->getCondition();
  if (const auto *indirect = llvm::dyn_cast<llvm::IndirectBrInst>(&term))
    return indirect->getAddress();
  return nullptr;
}

bool isWorkgroupBarrier(const llvm::CallBase &call) {
  const llvm::Function *callee = call.getCalledFunction();
  if (!callee)
    return false;
  llvm::StringRef name = callee->getName();
  return name.take_front(name.find('$')) == "air.wg.barrier";
}

std::string blockLabel(const llvm::BasicBlock &bb) {
  return bb.hasName() ? ("%" + bb.getName()).str() : "<unnamed block>";
}

/// Report a barrier only when a thread-varying conditional dominates it and
/// the barrier does not postdominate that conditional. The postdominator test
/// is the important half: lanes may take different paths so long as those
/// paths reconverge before all lanes execute the same barrier instance.
void checkDivergentWorkgroupBarriers(
    llvm::Module &m, llvm::Function &fn, const Rule &rule,
    llvm::function_ref<void(const Rule *, const llvm::Twine &,
                            const llvm::Function *)>
        report) {
  llvm::SmallPtrSet<const llvm::Value *, 8> sources;
  collectWorkgroupVaryingArguments(m, fn, sources);
  if (sources.empty())
    return;

  llvm::SmallVector<const llvm::BasicBlock *, 8> divergentControls;
  for (const llvm::BasicBlock &bb : fn) {
    const llvm::Value *condition =
        conditionalTerminatorValue(*bb.getTerminator());
    if (!condition)
      continue;
    llvm::SmallPtrSet<const llvm::Value *, 32> seen;
    if (dependsOnWorkgroupIdentity(condition, sources, seen))
      divergentControls.push_back(&bb);
  }
  if (divergentControls.empty())
    return;

  llvm::DominatorTree dominators(fn);
  llvm::PostDominatorTree postDominators(fn);
  for (llvm::BasicBlock &bb : fn)
    for (llvm::Instruction &inst : bb) {
      const auto *call = llvm::dyn_cast<llvm::CallBase>(&inst);
      if (!call || !isWorkgroupBarrier(*call))
        continue;
      for (const llvm::BasicBlock *control : divergentControls) {
        if (control == &bb || !dominators.dominates(control, &bb) ||
            postDominators.dominates(&bb, control))
          continue;
        report(&rule,
               "workgroup barrier in " + blockLabel(bb) +
                   " is control-dependent on thread-varying conditional in " +
                   blockLabel(*control),
               &fn);
        break; // one precise diagnostic per barrier is enough
      }
    }
}

} // namespace

void printRuleTable();

void configureFromEnv() {
  std::call_once(ConfigOnce, [] {
    doConfigure();
    // Print the table on request, once, after config is applied so the
    // listing shows the ACTIVE action for each rule rather than the default.
    const char *cfg = ::getenv("APPLEGPU_AIR_RULES");
    if (cfg && llvm::StringRef(cfg).contains("list"))
      printRuleTable();
  });
}

std::vector<Finding> checkLegality(llvm::Module &m) {
  configureFromEnv();
  std::vector<Finding> out;

  auto enabled = [&](llvm::StringRef id) -> const Rule * {
    const Rule *r = ruleFor(id);
    return (r && r->action != RuleAction::Permit) ? r : nullptr;
  };
  auto report = [&](const Rule *r, const llvm::Twine &detail,
                    const llvm::Function *fn) {
    out.push_back({r->id,
                   (detail + (fn ? "  [in @" + fn->getName() + "]" : "")).str(),
                   r->action});
  };

  llvm::StringMap<llvm::StringRef> renameMap;
  if (enabled("unmapped-llvm-intrinsic"))
    for (const Rename &rn : Renames)
      renameMap[rn.llvmName] = rn.airName;

  llvm::SmallPtrSet<llvm::Type *, 32> seen;
  auto checkType = [&](llvm::Type *t, const llvm::Twine &where,
                       const llvm::Function *fn) {
    seen.clear();
    llvm::StringRef why = illegalScalar(t, seen);
    if (why.empty())
      return;
    if (const Rule *r = enabled(why))
      report(r, where + ": " + r->what + " (" + typeStr(t) + ")", fn);
  };

  for (llvm::Function &fn : m) {
    if (fn.isDeclaration()) {
      if (const Rule *r = enabled("dead-intrinsic-decl"))
        if (fn.use_empty() && fn.isIntrinsic())
          report(r, "dead declaration @" + fn.getName(), nullptr);
      continue;
    }
    for (llvm::Argument &a : fn.args())
      checkType(a.getType(), "parameter %" + llvm::Twine(a.getArgNo()), &fn);

    for (llvm::BasicBlock &bb : fn)
      for (llvm::Instruction &inst : bb) {
        checkType(inst.getType(),
                  llvm::Twine(inst.getOpcodeName()) + " result", &fn);

        if (auto *bc = llvm::dyn_cast<llvm::BitCastInst>(&inst)) {
          auto *vt = llvm::dyn_cast<llvm::FixedVectorType>(bc->getSrcTy());
          auto *it = llvm::dyn_cast<llvm::IntegerType>(bc->getDestTy());
          if (!vt) {
            vt = llvm::dyn_cast<llvm::FixedVectorType>(bc->getDestTy());
            it = llvm::dyn_cast<llvm::IntegerType>(bc->getSrcTy());
          }
          if (vt && it && vt->getElementType()->isIntegerTy(1) &&
              it->getBitWidth() == vt->getNumElements())
            if (const Rule *r = enabled("mask-bitcast"))
              report(r, "bitcast <" + llvm::Twine(vt->getNumElements()) +
                            " x i1> <-> i" + llvm::Twine(it->getBitWidth()),
                     &fn);
        }

        switch (inst.getOpcode()) {
        case llvm::Instruction::AddrSpaceCast:
          if (const Rule *r = enabled("addrspacecast"))
            report(r, "addrspacecast", &fn);
          break;
        case llvm::Instruction::SIToFP:
        case llvm::Instruction::UIToFP:
        case llvm::Instruction::FPToSI:
        case llvm::Instruction::FPToUI:
          if (const Rule *r = enabled("native-int-float-cast"))
            report(r, llvm::Twine("native ") + inst.getOpcodeName(), &fn);
          if (inst.getType()->isBFloatTy() ||
              (inst.getType()->isVectorTy() &&
               inst.getType()->getScalarType()->isBFloatTy()))
            if (const Rule *r = enabled("int-to-bf16"))
              report(r, llvm::Twine(inst.getOpcodeName()) + " to bfloat", &fn);
          break;
        case llvm::Instruction::FPExt:
        case llvm::Instruction::FPTrunc:
          if (inst.getType()->isVectorTy())
            if (const Rule *r = enabled("vector-fp-cast"))
              report(r, llvm::Twine("vector ") + inst.getOpcodeName(), &fn);
          break;
        default:
          break;
        }

        // Dereference through a generic pointer, excluding stack memory.
        llvm::Value *ptrOp = nullptr;
        if (auto *ld = llvm::dyn_cast<llvm::LoadInst>(&inst))
          ptrOp = ld->getPointerOperand();
        else if (auto *st = llvm::dyn_cast<llvm::StoreInst>(&inst))
          ptrOp = st->getPointerOperand();
        else if (auto *rmw = llvm::dyn_cast<llvm::AtomicRMWInst>(&inst))
          ptrOp = rmw->getPointerOperand();
        else if (auto *cx = llvm::dyn_cast<llvm::AtomicCmpXchgInst>(&inst))
          ptrOp = cx->getPointerOperand();
        if (ptrOp)
          if (auto *pt = llvm::dyn_cast<llvm::PointerType>(ptrOp->getType()))
            if (pt->getAddressSpace() == 0 && !isAllocaDerived(ptrOp))
              if (const Rule *r = enabled("generic-deref"))
                report(r, llvm::Twine(inst.getOpcodeName()) + " through a "
                                                              "generic pointer",
                       &fn);

        auto *ci = llvm::dyn_cast<llvm::CallInst>(&inst);
        llvm::Function *callee = ci ? ci->getCalledFunction() : nullptr;
        if (!callee)
          continue;
        llvm::StringRef name = callee->getName();

        if (callee->isIntrinsic() && ci->getType()->isVectorTy() &&
            callee->getIntrinsicID() == llvm::Intrinsic::fma)
          if (const Rule *r = enabled("vector-llvm-fma"))
            report(r, "vector llvm.fma", &fn);

        // Vector only -- see the rule's note.
        if (!renameMap.empty() && ci->getType()->isVectorTy())
          if (auto it = renameMap.find(name); it != renameMap.end())
            if (const Rule *r = enabled("unmapped-llvm-intrinsic"))
              report(r, name + " should be " + it->second, &fn);

        if (name.starts_with("air.simd_shuffle") && name.ends_with(".i64"))
          if (const Rule *r = enabled("i64-simd-shuffle"))
            report(r, name, &fn);

        if (name.starts_with("air.fmin") || name.starts_with("air.fmax")) {
          bool wrapped = llvm::any_of(ci->users(), [](const llvm::User *u) {
            return llvm::isa<llvm::SelectInst>(u) || llvm::isa<llvm::FCmpInst>(u);
          });
          if (!wrapped)
            if (const Rule *r = enabled("nan-minmax-unwrapped"))
              report(r, name + " with no NaN-propagation select", &fn);
        }
      }

    if (const Rule *r = enabled("divergent-barrier"))
      checkDivergentWorkgroupBarriers(m, fn, *r, report);
  }
  return out;
}


//===----------------------------------------------------------------------===//
// Transforms
//===----------------------------------------------------------------------===//
//
// Separate switch from the rules, and every one defaults OFF. A detection rule
// that is wrong prints a spurious line; a transform that is wrong silently
// changes generated code. They do not deserve the same default.
//
//   APPLEGPU_AIR_XFORMS="rename-llvm-intrinsics=on,split-i64-shuffle=on"
//   APPLEGPU_AIR_XFORMS=all=on
//
// Turn one on, run the full sweep, and promote it here once clean.

namespace {

struct Transform {
  llvm::StringRef id;
  bool enabled;
  llvm::StringRef what;
};

Transform Transforms[] = {
  {"rename-llvm-intrinsics", false,
   "rename llvm.* math intrinsics to their air.* equivalents, using the "
   "ported table. Anything the optimiser introduces arrives as llvm.* and "
   "never passed through the stdlib's air.* naming"},
  {"guard-nan-minmax", false,
   "wrap renamed fmin/fmax in a NaN-propagation select. AIR's fmin/fmax DROP "
   "NaN, so llvm.minimum/maximum semantics are not preserved by the rename "
   "alone. Only meaningful with rename-llvm-intrinsics"},
  {"split-i64-shuffle", false,
   "rewrite i64 air.simd_shuffle as bitcast to <2 x i32>, shuffle, bitcast "
   "back -- the GPU JIT rejects the i64 form"},
  {"volatile-loop-loads", false,
   "mark a device load volatile when it sits in a loop whose body also stores "
   "through the same base pointer, so LLVM cannot hoist it out and read stale "
   "data"},
};

std::once_flag XformOnce;

void doConfigureXforms() {
  const char *cfg = ::getenv("APPLEGPU_AIR_XFORMS");
  if (!cfg || !*cfg)
    return;
  llvm::SmallVector<llvm::StringRef, 8> parts;
  llvm::StringRef(cfg).split(parts, ',', -1, /*KeepEmpty=*/false);
  for (llvm::StringRef p : parts) {
    auto [name, val] = p.trim().split('=');
    name = name.trim();
    val = val.trim();
    bool on = val.equals_insensitive("on") || val.equals_insensitive("yes") ||
              val.equals_insensitive("true") || val == "1";
    if (name.equals_insensitive("all")) {
      for (Transform &t : Transforms)
        t.enabled = on;
      continue;
    }
    bool found = false;
    for (Transform &t : Transforms)
      if (t.id == name) { t.enabled = on; found = true; }
    if (!found)
      llvm::errs() << "[air-xforms] no such transform '" << name << "'\n";
  }
}

bool xformEnabled(llvm::StringRef id) {
  std::call_once(XformOnce, doConfigureXforms);
  for (const Transform &t : Transforms)
    if (t.id == id)
      return t.enabled;
  return false;
}

/// llvm.* -> air.* by table. Returns the calls that were renamed to a
/// fmin/fmax, so the NaN guard can wrap exactly those.
bool renameIntrinsics(llvm::Module &m,
                      llvm::SmallVectorImpl<llvm::CallInst *> &minmax) {
  llvm::StringMap<llvm::StringRef> map;
  for (const Rename &rn : Renames)
    map[rn.llvmName] = rn.airName;

  llvm::SmallVector<llvm::CallInst *, 16> calls;
  for (llvm::Function &fn : m)
    for (llvm::BasicBlock &bb : fn)
      for (llvm::Instruction &inst : bb)
        if (auto *ci = llvm::dyn_cast<llvm::CallInst>(&inst))
          if (llvm::Function *c = ci->getCalledFunction())
            if (map.count(c->getName()))
              calls.push_back(ci);
  if (calls.empty())
    return false;

  for (llvm::CallInst *ci : calls) {
    llvm::Function *old = ci->getCalledFunction();
    llvm::StringRef nu = map[old->getName()];
    bool isMinMax = old->getName().contains(".minimum.") ||
                    old->getName().contains(".maximum.");
    llvm::FunctionCallee fc =
        m.getOrInsertFunction(nu, old->getFunctionType());
    if (auto *decl = llvm::dyn_cast<llvm::Function>(fc.getCallee())) {
      decl->setDoesNotThrow();
      decl->setWillReturn();
      decl->setMustProgress();
      decl->setUnnamedAddr(llvm::GlobalValue::UnnamedAddr::Local);
    }
    ci->setCalledFunction(fc);
    if (isMinMax)
      minmax.push_back(ci);
  }
  // The declaration is dead now, and a dead llvm.* declare is as fatal as a
  // live call -- the reader resolves every declared symbol.
  llvm::SmallVector<llvm::Function *, 8> dead;
  for (llvm::Function &fn : m)
    if (fn.isDeclaration() && fn.use_empty() && fn.isIntrinsic() &&
        map.count(fn.getName()))
      dead.push_back(&fn);
  for (llvm::Function *fn : dead)
    fn->eraseFromParent();
  return true;
}

/// air.fmin/fmax drop NaN. llvm.minimum/maximum must propagate it, so re-add
/// the semantics the rename threw away:  isnan(a) ? a : isnan(b) ? b : r
bool wrapNaN(llvm::ArrayRef<llvm::CallInst *> calls) {
  for (llvm::CallInst *ci : calls) {
    if (ci->arg_size() != 2)
      continue;
    llvm::Value *a = ci->getArgOperand(0), *b = ci->getArgOperand(1);
    llvm::IRBuilder<> bld(ci->getNextNode());
    llvm::Value *aNan = bld.CreateFCmpUNO(a, a, "a.isnan");
    llvm::Value *bNan = bld.CreateFCmpUNO(b, b, "b.isnan");
    llvm::Value *pick = bld.CreateSelect(bNan, b, ci);
    llvm::Value *res = bld.CreateSelect(aNan, a, pick, "nan.prop");
    ci->replaceUsesWithIf(res, [&](llvm::Use &u) {
      return u.getUser() != aNan && u.getUser() != bNan && u.getUser() != pick;
    });
  }
  return !calls.empty();
}

/// The GPU JIT rejects i64 air.simd_shuffle; the v2i32 form is accepted.
bool splitI64Shuffle(llvm::Module &m) {
  llvm::SmallVector<llvm::CallInst *, 8> calls;
  for (llvm::Function &fn : m)
    for (llvm::BasicBlock &bb : fn)
      for (llvm::Instruction &inst : bb)
        if (auto *ci = llvm::dyn_cast<llvm::CallInst>(&inst))
          if (llvm::Function *c = ci->getCalledFunction())
            if (c->getName().starts_with("air.simd_shuffle") &&
                ci->getType()->isIntegerTy(64))
              calls.push_back(ci);
  if (calls.empty())
    return false;
  llvm::Type *v2i32 =
      llvm::FixedVectorType::get(llvm::Type::getInt32Ty(m.getContext()), 2);
  for (llvm::CallInst *ci : calls) {
    llvm::Function *old = ci->getCalledFunction();
    llvm::IRBuilder<> b(ci);
    llvm::SmallVector<llvm::Value *, 4> args;
    llvm::SmallVector<llvm::Type *, 4> tys;
    for (llvm::Value *a : ci->args()) {
      llvm::Value *na =
          a->getType()->isIntegerTy(64) ? b.CreateBitCast(a, v2i32) : a;
      args.push_back(na);
      tys.push_back(na->getType());
    }
    std::string nu = (old->getName().take_front(
                          old->getName().rfind('.')) + ".v2i32").str();
    llvm::FunctionCallee fc = m.getOrInsertFunction(
        nu, llvm::FunctionType::get(v2i32, tys, false));
    if (auto *decl = llvm::dyn_cast<llvm::Function>(fc.getCallee())) {
      decl->setConvergent();
      decl->setDoesNotThrow();
    }
    llvm::Value *call = b.CreateCall(fc, args);
    ci->replaceAllUsesWith(b.CreateBitCast(call, ci->getType()));
    ci->eraseFromParent();
  }
  return true;
}

/// A device load inside a loop whose body also stores through the same base
/// gets marked volatile, so it is re-read each iteration.
bool volatileLoopLoads(llvm::Module &m) {
  bool changed = false;
  for (llvm::Function &fn : m) {
    if (fn.isDeclaration())
      continue;
    llvm::DominatorTree dt(fn);
    llvm::LoopInfo li(dt);
    for (llvm::Loop *top : li)
      for (llvm::Loop *lp : llvm::depth_first(top)) {
        llvm::SmallPtrSet<const llvm::Value *, 8> storedBases;
        for (llvm::BasicBlock *bb : lp->blocks())
          for (llvm::Instruction &inst : *bb)
            if (auto *st = llvm::dyn_cast<llvm::StoreInst>(&inst))
              storedBases.insert(
                  st->getPointerOperand()->stripPointerCasts());
        if (storedBases.empty())
          continue;
        for (llvm::BasicBlock *bb : lp->blocks())
          for (llvm::Instruction &inst : *bb)
            if (auto *ld = llvm::dyn_cast<llvm::LoadInst>(&inst)) {
              if (ld->isVolatile())
                continue;
              auto *pt = llvm::dyn_cast<llvm::PointerType>(
                  ld->getPointerOperand()->getType());
              if (!pt || pt->getAddressSpace() != 1)
                continue;
              if (!storedBases.count(
                      ld->getPointerOperand()->stripPointerCasts()))
                continue;
              ld->setVolatile(true);
              changed = true;
            }
      }
  }
  return changed;
}

} // namespace

void printRuleTable() {
  llvm::errs() << "AIR legality rules (APPLEGPU_AIR_RULES=id=permit|log|fail, "
                  "or all=...)\n\n";
  for (const Rule &r : Rules)
    llvm::errs() << llvm::formatv("  {0,-24} {1,-7} {2,-9} {3}\n", r.id,
                                  actionName(r.action), r.evidence, r.what);
  llvm::errs() << "\ntransforms (APPLEGPU_AIR_XFORMS=id=on|off, or all=on) -- "
                  "all default OFF\n\n";
  std::call_once(XformOnce, doConfigureXforms);
  for (const Transform &t : Transforms)
    llvm::errs() << llvm::formatv("  {0,-24} {1,-7} {2}\n", t.id,
                                  t.enabled ? "on" : "off", t.what);
  llvm::errs() << "\n";
}

bool applyTransforms(llvm::Module &m) {
  bool changed = false;
  llvm::SmallVector<llvm::CallInst *, 8> minmax;
  if (xformEnabled("rename-llvm-intrinsics"))
    changed |= renameIntrinsics(m, minmax);
  if (xformEnabled("guard-nan-minmax") && !minmax.empty())
    changed |= wrapNaN(minmax);
  if (xformEnabled("split-i64-shuffle"))
    changed |= splitI64Shuffle(m);
  if (xformEnabled("volatile-loop-loads"))
    changed |= volatileLoopLoads(m);
  return changed;
}

} // namespace M::KGEN::Air

namespace M::KGEN::Air {

//===----------------------------------------------------------------------===//
// Unresolved externals
//===----------------------------------------------------------------------===//

namespace {

std::optional<std::string> payloadSuffixForType(llvm::Type *ty) {
  unsigned vectorWidth = 1;
  if (auto *vt = llvm::dyn_cast<llvm::FixedVectorType>(ty)) {
    vectorWidth = vt->getNumElements();
    ty = vt->getElementType();
  } else if (ty->isVectorTy()) {
    return std::nullopt;
  }
  if (ty->isHalfTy())
    return payloadTypeSuffix(/*isFloating=*/true, 16, vectorWidth);
  if (ty->isFloatTy())
    return payloadTypeSuffix(/*isFloating=*/true, 32, vectorWidth);
  if (auto *it = llvm::dyn_cast<llvm::IntegerType>(ty))
    return payloadTypeSuffix(/*isFloating=*/false, it->getBitWidth(),
                             vectorWidth);
  return std::nullopt;
}

bool isFloatingPayload(llvm::Type *ty) {
  if (auto *vt = llvm::dyn_cast<llvm::FixedVectorType>(ty))
    ty = vt->getElementType();
  return ty->isHalfTy() || ty->isFloatTy();
}

std::optional<std::string> overloadTypeName(llvm::Type *ty) {
  if (ty->isFloatTy())
    return std::string("f32");
  if (ty->isHalfTy())
    return std::string("f16");
  if (ty->isBFloatTy())
    return std::string("bf16");
  if (auto *it = llvm::dyn_cast<llvm::IntegerType>(ty))
    return "i" + std::to_string(it->getBitWidth());
  if (auto *vt = llvm::dyn_cast<llvm::FixedVectorType>(ty))
    if (auto elem = overloadTypeName(vt->getElementType()))
      return "v" + std::to_string(vt->getNumElements()) + *elem;
  return std::nullopt;
}

bool validateBuiltinFamily(const llvm::Function &fn,
                           const BuiltinFamily &family,
                           llvm::StringRef visibleStem, std::string &reason) {
  llvm::FunctionType *type = fn.getFunctionType();
  if (type->isVarArg()) {
    reason = "AIR runtime declarations cannot be variadic";
    return false;
  }

  llvm::StringRef suffix = fn.getName().drop_front(visibleStem.size());
  auto failSignature = [&]() {
    reason = ("signature does not match family '" + family.stem + "'").str();
    return false;
  };

  if (!family.carriesTypeSuffix) {
    if (!suffix.empty()) {
      reason = "unexpected suffix on non-overloaded AIR builtin";
      return false;
    }
    switch (family.signature) {
    case BuiltinSignature::Barrier:
      if (!type->getReturnType()->isVoidTy() || type->getNumParams() != 2 ||
          !type->getParamType(0)->isIntegerTy(32) ||
          !type->getParamType(1)->isIntegerTy(32))
        return failSignature();
      return true;
    case BuiltinSignature::Ballot:
      if (!type->getReturnType()->isIntegerTy(32) ||
          type->getNumParams() != 1 || !type->getParamType(0)->isIntegerTy(1))
        return failSignature();
      return true;
    default:
      return failSignature();
    }
  }

  if (!suffix.starts_with(".")) {
    reason = "missing AIR payload type suffix";
    return false;
  }
  if (type->getNumParams() == 0) {
    reason = "overloaded AIR builtin has no payload operand";
    return false;
  }
  llvm::Type *payload = type->getParamType(0);
  auto expected = payloadSuffixForType(payload);
  if (!expected) {
    reason = "payload type has no legal AIR overload suffix";
    return false;
  }
  bool suffixMatches = suffix == *expected;
  if (!suffixMatches && llvm::StringRef(*expected).starts_with(".u.")) {
    std::string signedSuffix =
        ".s." + llvm::StringRef(*expected).drop_front(3).str();
    suffixMatches = suffix == signedSuffix;
  }
  if (!suffixMatches) {
    reason = ("name suffix '" + suffix + "' does not describe payload type; " +
              "expected '" + *expected + "'")
                 .str();
    return false;
  }
  if (family.payloadDomain == PayloadDomain::Floating &&
      !isFloatingPayload(payload)) {
    reason = "integer payload used with a floating-point AIR family";
    return false;
  }
  if (type->getReturnType() != payload)
    return failSignature();

  unsigned expectedParams = 0;
  switch (family.signature) {
  case BuiltinSignature::Unary:
    expectedParams = 1;
    break;
  case BuiltinSignature::Binary:
    expectedParams = 2;
    break;
  case BuiltinSignature::Ternary:
    expectedParams = 3;
    break;
  case BuiltinSignature::Shuffle:
    if (type->getNumParams() != 2 || !type->getParamType(1)->isIntegerTy(16))
      return failSignature();
    return true;
  default:
    return failSignature();
  }
  if (type->getNumParams() != expectedParams)
    return failSignature();
  for (unsigned i = 0; i != expectedParams; ++i)
    if (type->getParamType(i) != payload)
      return failSignature();
  return true;
}

bool validateConvert(const llvm::Function &fn, std::string &reason) {
  llvm::StringRef rest = fn.getName();
  if (!rest.consume_front("air.convert."))
    return false;
  llvm::FunctionType *type = fn.getFunctionType();
  if (type->isVarArg() || type->getNumParams() != 1) {
    reason = "air.convert must have exactly one operand";
    return false;
  }
  llvm::SmallVector<llvm::StringRef, 4> parts;
  rest.split(parts, '.', /*MaxSplit=*/-1, /*KeepEmpty=*/false);
  if (parts.size() != 4) {
    reason = "air.convert name must encode dst-kind.dst-type.src-kind.src-type";
    return false;
  }
  auto dst = overloadTypeName(type->getReturnType());
  auto src = overloadTypeName(type->getParamType(0));
  if (!dst || !src || parts[1] != *dst || parts[3] != *src) {
    reason = "air.convert name types do not match its LLVM function type";
    return false;
  }
  auto kindMatches = [](llvm::StringRef kind, llvm::Type *ty) {
    llvm::Type *scalar = ty->isVectorTy() ? ty->getScalarType() : ty;
    if (scalar->isFloatingPointTy())
      return kind == "f";
    if (scalar->isIntegerTy())
      return kind == "s" || kind == "u";
    return false;
  };
  if (!kindMatches(parts[0], type->getReturnType()) ||
      !kindMatches(parts[2], type->getParamType(0))) {
    reason = "air.convert signedness/kind token does not match its LLVM type";
    return false;
  }
  return true;
}

bool validateMatrixMMA(const llvm::Function &fn, std::string &reason) {
  static constexpr llvm::StringLiteral stems[] = {
      "air.simdgroup_matrix_8x8_multiply_accumulate",
      "air.simdgroup_matrix_16x16x16_multiply_accumulate",
      "air.simdgroup_matrix_16x16x16_widening_multiply_accumulate",
  };
  llvm::StringRef suffix;
  bool matched = false;
  for (llvm::StringRef stem : stems)
    if (fn.getName().starts_with(stem) &&
        fn.getName().drop_front(stem.size()).starts_with(".")) {
      suffix = fn.getName().drop_front(stem.size() + 1);
      matched = true;
      break;
    }
  if (!matched)
    return false;

  llvm::FunctionType *type = fn.getFunctionType();
  if (type->isVarArg()) {
    reason = "simdgroup matrix declarations cannot be variadic";
    return false;
  }
  llvm::SmallVector<llvm::StringRef, 8> parts;
  suffix.split(parts, '.', /*MaxSplit=*/-1, /*KeepEmpty=*/false);

  unsigned flags = 0;
  llvm::SmallVector<std::string, 5> expectedTypes;
  auto result = overloadTypeName(type->getReturnType());
  if (!result) {
    reason = "simdgroup matrix result has no AIR overload spelling";
    return false;
  }
  expectedTypes.push_back(*result);
  for (llvm::Type *param : type->params()) {
    if (param->isIntegerTy(1)) {
      ++flags;
      continue;
    }
    auto encoded = overloadTypeName(param);
    if (!encoded) {
      reason = "simdgroup matrix operand has no AIR overload spelling";
      return false;
    }
    expectedTypes.push_back(*encoded);
  }
  if (parts.size() != flags + expectedTypes.size()) {
    reason = "simdgroup matrix name has the wrong number of signature tokens";
    return false;
  }
  for (unsigned i = 0; i != flags; ++i)
    if (parts[i] != "f" && parts[i] != "t") {
      reason = "simdgroup matrix transpose token must be f or t";
      return false;
    }
  for (auto [index, expected] : llvm::enumerate(expectedTypes))
    if (parts[flags + index] != expected) {
      reason =
          "simdgroup matrix name types do not match its LLVM function type";
      return false;
    }
  return true;
}

bool validateAirRuntimeDeclaration(const llvm::Function &fn,
                                   std::string &reason) {
  for (const BuiltinFamily &family : builtinFamilies()) {
    llvm::StringRef name = fn.getName();
    if (name.starts_with(family.stem) &&
        (name.size() == family.stem.size() || name[family.stem.size()] == '.'))
      return validateBuiltinFamily(fn, family, family.stem, reason);

    if (family.payloadDomain == PayloadDomain::Floating) {
      std::string fastStem =
          "air.fast_" + family.stem.drop_front(4).str();
      if (name.starts_with(fastStem) &&
          (name.size() == fastStem.size() || name[fastStem.size()] == '.'))
        return validateBuiltinFamily(fn, family, fastStem, reason);
    }
  }
  if (fn.getName().starts_with("air.convert."))
    return validateConvert(fn, reason);
  if (fn.getName().starts_with("air.simdgroup_matrix_"))
    return validateMatrixMMA(fn, reason);
  reason = "AIR runtime symbol is not registered";
  return false;
}

/// `llvm.*` externals measured to reach AIR and be accepted.
///
/// Taken from a census of 188 distinct captured modules across 13 tests, not
/// from a guess about what ought to work. Anything absent is reported by the
/// rule: llvm.stepvector and llvm.vector.interleave2 both got this far and
/// killed the Metal compiler service rather than being rejected.
bool isAllowedExternal(const llvm::Function &fn) {
  llvm::StringRef n = fn.getName();

  // Apple's own AGX3 target intrinsics. We emit these deliberately
  // (max/mojo/max/gpu/memory/masked_load_apple.mojo) and Apple resolves them.
  //
  // Note they are NOT LLVM intrinsics: Function::isIntrinsic() is a test on
  // the `llvm.` name prefix, so it answers true for these while
  // getIntrinsicID() answers not_intrinsic. Any rule phrased as
  // "declaration + isIntrinsic()" will match them by accident.
  if (n.starts_with("llvm.agx3."))
    return true;

  switch (fn.getIntrinsicID()) {
  // Integer min/max: by far the most common, 82 modules for umax alone.
  case llvm::Intrinsic::umax:
  case llvm::Intrinsic::umin:
  case llvm::Intrinsic::smax:
  case llvm::Intrinsic::smin:
  // Generate no code at all.
  case llvm::Intrinsic::lifetime_start:
  case llvm::Intrinsic::lifetime_end:
  // Expanded by the reader; refreshOverloadedMemIntrinsics keeps the overload
  // honest after pointers are retyped.
  case llvm::Intrinsic::memcpy:
  case llvm::Intrinsic::memmove:
  case llvm::Intrinsic::memset:
  case llvm::Intrinsic::fabs:
  case llvm::Intrinsic::ctlz:
    return true;
  default:
    return false;
  }
}

} // namespace

std::vector<Finding> checkExternals(llvm::Module &m) {
  configureFromEnv();
  std::vector<Finding> out;
  const Rule *airRule = ruleFor("unknown-air-symbol");
  const Rule *externalRule = ruleFor("unresolved-external");
  if ((!airRule || airRule->action == RuleAction::Permit) &&
      (!externalRule || externalRule->action == RuleAction::Permit))
    return out;
  for (llvm::Function &fn : m) {
    if (!fn.isDeclaration())
      continue;
    if (fn.getName().starts_with("air.")) {
      if (airRule && airRule->action != RuleAction::Permit) {
        std::string reason;
        if (!validateAirRuntimeDeclaration(fn, reason))
          out.push_back({airRule->id,
                         ("invalid AIR runtime declaration @" + fn.getName() +
                          ": " + reason)
                             .str(),
                         airRule->action});
      }
      continue;
    }
    if (!externalRule || externalRule->action == RuleAction::Permit ||
        isAllowedExternal(fn))
      continue;
    // Name a caller: the symbol alone rarely says which kernel to look at.
    std::string where;
    for (const llvm::User *u : fn.users())
      if (auto *ci = llvm::dyn_cast<llvm::CallBase>(u))
        if (const llvm::Function *caller = ci->getFunction()) {
          where = ("  [called from @" + caller->getName() + "]").str();
          break;
        }
    if (where.empty() && fn.use_empty())
      where = "  [no uses -- a dead declare is resolved too]";
    out.push_back({externalRule->id,
                   ("unresolved external @" + fn.getName() + where).str(),
                   externalRule->action});
  }
  return out;
}

void reportLegality(llvm::Module &m) {
  unsigned fails = 0;
  std::vector<Finding> findings = checkLegality(m);
  llvm::append_range(findings, checkExternals(m));
  for (const Finding &f : findings) {
    llvm::errs() << (f.action == RuleAction::Fail ? "fail" : "log") << '\t'
                 << f.ruleId << '\t' << f.detail << '\n';
    fails += f.action == RuleAction::Fail;
  }
  llvm::errs() << "-- " << m.getName() << ": " << fails << " fail\n";
}

} // namespace M::KGEN::Air
