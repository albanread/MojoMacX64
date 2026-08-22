//===----------------------------------------------------------------------===//
// VEGA-FORK: TargetBackend for Apple AIR (air64) — Metal GPU kernels for the
// Radeon Pro Vega II, on an Intel Mac Pro.
//
// The upstream Metal backend is not published; this is the fork's own,
// written against a hardware-verified golden sample: an .air produced by
// Xcode 15.2's `metal` and proven to load and run on this machine's Vega II
// (spike S1). The profile replicated here, byte-for-byte where it matters:
//
//   target triple  air64-apple-macosx14.2.0
//   air.version    2.6.0        air.language_version  Metal 3.1.0
//   module flags   SDK 14.2, wchar_size 4, frame-pointer 2, air.max_* caps
//   kernels        !air.kernel = {fn, !{}, !args}; buffer args carry
//                  air.buffer/air.location_index == parameter order (the
//                  same order VegaRT binds at launch); trailing builtin
//                  params carry e.g. air.thread_position_in_grid
//   encoding       LLVM-17 bitcode (BitcodeWriter17), opaque pointers
//
// Legalization performed here (the open MetalAIRPass, v1):
//   1. Retarget the module to the AIR triple (datalayout already matches —
//      the stdlib target attr carries the AIR layout string).
//   2. Convert calls to the stdlib's `llvm.air.<builtin>[.dim]` shims into
//      trailing kernel parameters with the right AIR argument metadata.
//   3. Emit !air.kernel argument metadata for the leading parameters
//      (buffers by address space, by-value scalars as-is).
//   4. Stamp the module-level AIR metadata.
//
// Packaging shells out to `xcrun metallib` (precedent: mojo-build already
// shells to `xcrun dsymutil`), which also validates the AIR structurally.
//===----------------------------------------------------------------------===//

#include "KGEN/Compiler/ObjectCompiler.h"
#include "KGEN/Compiler/SaveAsmOutput.h"
#include "KGEN/ToolCommon/CompilationOptions.h"
#include "LLVM/Bitcode/17/BitcodeWriter17.h"
#include "LLVM/Transforms/LLVMIRDowngradePass.h"
#include "LLVM/Transforms/PointerRewriter.h"
#include "Target/Air/AirTraits.h"
#include "KGEN/Compiler/Target/TargetBackend.h"
#include "Target/TargetTraits.h"

#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/Location.h"
#include "llvm/ADT/SmallString.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/PassManager.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/Program.h"
#include "llvm/Support/raw_ostream.h"

#include <optional>
#include <string>

namespace M::KGEN {
namespace {

constexpr const char *kAirTriple = "air64-apple-macosx14.2.0";

//===----------------------------------------------------------------------===//
// Builtin shims: the stdlib emits calls to functions named
// `llvm.air.<builtin>` or `llvm.air.<builtin>.<dim>`; AIR wants them as
// trailing kernel parameters carrying metadata.
//===----------------------------------------------------------------------===//

struct BuiltinKind {
  llvm::StringRef shimBase;  // e.g. "thread_position_in_grid"
  llvm::StringRef airTag;    // e.g. "air.thread_position_in_grid"
};

constexpr BuiltinKind kBuiltins[] = {
    {"thread_position_in_grid", "air.thread_position_in_grid"},
    {"thread_position_in_threadgroup", "air.thread_position_in_threadgroup"},
    {"threadgroup_position_in_grid", "air.threadgroup_position_in_grid"},
    {"threads_per_threadgroup", "air.threads_per_threadgroup"},
    {"threads_per_grid", "air.threads_per_grid"},
    {"threadgroups_per_grid", "air.threadgroups_per_grid"},
    {"thread_index_in_simdgroup", "air.thread_index_in_simdgroup"},
    {"simdgroup_index_in_threadgroup", "air.simdgroup_index_in_threadgroup"},
    {"threads_per_simdgroup", "air.threads_per_simdgroup"},
    {"thread_index_in_threadgroup", "air.thread_index_in_threadgroup"},
};

// Parses "llvm.air.<base>[.<dim>]" into (kind, dim). dim: x=0,y=1,z=2, or
// nullopt for scalar builtins used undimensioned.
std::optional<std::pair<const BuiltinKind *, std::optional<unsigned>>>
parseBuiltinShim(llvm::StringRef name) {
  name.consume_front("llvm."); // pre-lowering spelling
  if (!name.consume_front("air."))
    return std::nullopt;
  std::optional<unsigned> dim;
  if (name.ends_with(".x") || name.ends_with(".y") || name.ends_with(".z")) {
    dim = name.back() - 'x';
    name = name.drop_back(2);
  }
  for (const BuiltinKind &kind : kBuiltins)
    if (name == kind.shimBase)
      return std::make_pair(&kind, dim);
  return std::nullopt;
}

//===----------------------------------------------------------------------===//
// AIR legalization (the open MetalAIRPass, v1)
//===----------------------------------------------------------------------===//

struct KernelBuiltinUse {
  const BuiltinKind *kind;
  bool anyDimensioned = false; // used with .x/.y/.z -> uint3 param
  llvm::SmallVector<llvm::CallInst *, 8> calls;
};

llvm::MDNode *mdStrings(llvm::LLVMContext &c,
                        llvm::ArrayRef<llvm::Metadata *> elts) {
  return llvm::MDNode::get(c, elts);
}

llvm::Metadata *mdI32(llvm::LLVMContext &c, uint32_t v) {
  return llvm::ConstantAsMetadata::get(
      llvm::ConstantInt::get(llvm::Type::getInt32Ty(c), v));
}

llvm::Metadata *mdStr(llvm::LLVMContext &c, llvm::StringRef s) {
  return llvm::MDString::get(c, s);
}

// Propagates a changed pointer address space through the use graph, mutating
// derived pointer-typed values (GEPs, phis, selects, bitcasts) in place.
void propagatePointerAS(llvm::SmallVectorImpl<llvm::Value *> &retype) {
  while (!retype.empty()) {
    llvm::Value *v = retype.pop_back_val();
    for (llvm::User *user : v->users()) {
      auto *inst = llvm::dyn_cast<llvm::Instruction>(user);
      if (!inst)
        continue;
      llvm::Type *want = nullptr;
      if (llvm::isa<llvm::GetElementPtrInst>(inst) ||
          llvm::isa<llvm::PHINode>(inst) || llvm::isa<llvm::BitCastInst>(inst))
        want = v->getType();
      else if (auto *sel = llvm::dyn_cast<llvm::SelectInst>(inst);
               sel && sel->getCondition() != v)
        want = v->getType();
      else if (auto *call = llvm::dyn_cast<llvm::CallInst>(inst)) {
        // A retyped pointer flowing into a call: retype the matching params
        // of DEFINED callees so their bodies see the new address space
        // (external callees are adapted at the call site by the
        // PointerRewriter's universal argument bitcasts).
        llvm::Function *callee = call->getCalledFunction();
        if (callee && !callee->isDeclaration()) {
          for (unsigned ai = 0, ae = call->arg_size(); ai != ae; ++ai) {
            if (call->getArgOperand(ai) == v && ai < callee->arg_size()) {
              llvm::Argument *param = callee->getArg(ai);
              if (param->getType() != v->getType() &&
                  param->getType()->isPointerTy()) {
                param->mutateType(v->getType());
                retype.push_back(param);
              }
            }
          }
        }
        continue;
      }
      if (want && inst->getType() != want &&
          llvm::isa<llvm::PointerType>(inst->getType())) {
        inst->mutateType(want);
        retype.push_back(inst);
      }
    }
  }
}

// Mojo's address-space numbering is NVPTX's (CONSTANT=4, LOCAL=5); AIR uses
// constant=2 and private=0. Remap module globals and propagate.
void remapAddressSpaces(llvm::Module &m) {
  auto mapAS = [](unsigned as) -> std::optional<unsigned> {
    if (as == 4)
      return 2u; // constant
    if (as == 5)
      return 0u; // thread-private
    return std::nullopt;
  };
  llvm::SmallVector<llvm::GlobalVariable *, 8> worklist;
  for (llvm::GlobalVariable &gv : m.globals())
    if (mapAS(gv.getAddressSpace()))
      worklist.push_back(&gv);
  for (llvm::GlobalVariable *gv : worklist) {
    unsigned newAS = *mapAS(gv->getAddressSpace());
    auto *replacement = new llvm::GlobalVariable(
        m, gv->getValueType(), gv->isConstant(), gv->getLinkage(),
        gv->hasInitializer() ? gv->getInitializer() : nullptr, "", gv,
        gv->getThreadLocalMode(), newAS, gv->isExternallyInitialized());
    replacement->takeName(gv);
    replacement->setAlignment(gv->getAlign());
    replacement->setUnnamedAddr(gv->getUnnamedAddr());
    gv->mutateType(replacement->getType());
    gv->replaceAllUsesWith(replacement);
    llvm::SmallVector<llvm::Value *, 16> retype;
    retype.push_back(replacement);
    propagatePointerAS(retype);
    gv->eraseFromParent();
  }
}

// Rewrites one kernel: builtin shim calls become trailing parameters; returns
// the new function (parameter lists are immutable, so the body is spliced
// into a fresh function) plus the per-argument AIR metadata list.
llvm::Function *legalizeKernel(llvm::Function &fn,
                               llvm::SmallVectorImpl<llvm::Metadata *> &argMD) {
  llvm::LLVMContext &c = fn.getContext();
  llvm::Module &m = *fn.getParent();

  // Collect builtin shim uses inside this kernel.
  llvm::SmallVector<KernelBuiltinUse, 4> uses;
  for (llvm::BasicBlock &bb : fn) {
    for (llvm::Instruction &inst : bb) {
      auto *call = llvm::dyn_cast<llvm::CallInst>(&inst);
      if (!call || !call->getCalledFunction())
        continue;
      auto parsed = parseBuiltinShim(call->getCalledFunction()->getName());
      if (!parsed)
        continue;
      KernelBuiltinUse *use = nullptr;
      for (KernelBuiltinUse &u : uses)
        if (u.kind == parsed->first)
          use = &u;
      if (!use) {
        uses.push_back({parsed->first, false, {}});
        use = &uses.back();
      }
      use->anyDimensioned |= parsed->second.has_value();
      use->calls.push_back(call);
    }
  }

  // New signature: original params + one param per used builtin kind.
  // Pointer params move to the AIR device address space (1): Mojo elaborates
  // device pointers as generic AS0, which NVPTX tolerates but AIR rejects —
  // this rewrite is the address-space half of the closed MetalAIRPass.
  llvm::LLVMContext &ctx_ = fn.getContext();
  // By-value scalar params become constant-address-space(2) pointer params —
  // AIR's model for MSL `constant T&` — loaded at entry; the runtime binds
  // them with setBytes at the same index. Generic pointers move to device
  // AS(1).
  llvm::SmallVector<llvm::Type *, 8> paramTypes;
  llvm::SmallVector<llvm::Type *, 8> scalarOrigTypes; // per-param, null if ptr
  for (llvm::Type *ty : fn.getFunctionType()->params()) {
    if (auto *pt = llvm::dyn_cast<llvm::PointerType>(ty)) {
      scalarOrigTypes.push_back(nullptr);
      paramTypes.push_back(pt->getAddressSpace() == 0
                               ? llvm::PointerType::get(ctx_, 1)
                               : ty);
    } else {
      scalarOrigTypes.push_back(ty);
      paramTypes.push_back(llvm::PointerType::get(ctx_, 2));
    }
  }
  unsigned firstBuiltinIdx = paramTypes.size();
  for (KernelBuiltinUse &use : uses)
    paramTypes.push_back(use.anyDimensioned
                             ? llvm::FixedVectorType::get(
                                   llvm::Type::getInt32Ty(c), 3)
                             : llvm::cast<llvm::Type>(
                                   llvm::Type::getInt32Ty(c)));

  auto *newTy =
      llvm::FunctionType::get(llvm::Type::getVoidTy(c), paramTypes, false);
  llvm::Function *newFn = llvm::Function::Create(
      newTy, fn.getLinkage(), fn.getAddressSpace(), "", &m);
  newFn->takeName(&fn);
  newFn->copyAttributesFrom(&fn);
  newFn->setCallingConv(fn.getCallingConv());

  // Splice the body and rewire the original arguments. Where a pointer
  // param changed address space, propagate the new pointer type through its
  // use graph (GEPs and friends), mutating derived pointer types in place.
  newFn->splice(newFn->begin(), &fn);
  llvm::IRBuilder<> entry(&newFn->getEntryBlock(),
                          newFn->getEntryBlock().begin());
  llvm::SmallVector<llvm::Value *, 16> retype;
  for (unsigned i = 0, e = fn.arg_size(); i != e; ++i) {
    llvm::Argument *oldArg = fn.getArg(i);
    llvm::Argument *newArg = newFn->getArg(i);
    if (scalarOrigTypes[i]) {
      // Scalar became constant-AS pointer: load the value at entry.
      llvm::Value *loaded =
          entry.CreateLoad(scalarOrigTypes[i], newArg,
                           llvm::Twine(oldArg->getName(), ".val"));
      oldArg->replaceAllUsesWith(loaded);
      newArg->setName(oldArg->getName());
      continue;
    }
    if (oldArg->getType() != newArg->getType()) {
      // Same representation, new address space: mutate the old arg's users.
      oldArg->mutateType(newArg->getType());
      retype.push_back(oldArg);
    }
    oldArg->replaceAllUsesWith(newArg);
    newArg->takeName(oldArg);
    if (!retype.empty() && retype.back() == oldArg) {
      retype.back() = newArg;
    }
  }
  propagatePointerAS(retype);

  // Replace shim calls with reads of the new parameters.
  for (unsigned u = 0; u < uses.size(); ++u) {
    llvm::Argument *arg = newFn->getArg(firstBuiltinIdx + u);
    for (llvm::CallInst *call : uses[u].calls) {
      llvm::Value *replacement = arg;
      auto parsed = parseBuiltinShim(call->getCalledFunction()->getName());
      if (uses[u].anyDimensioned) {
        unsigned dim = parsed->second.value_or(0);
        llvm::IRBuilder<> b(call);
        replacement = b.CreateExtractElement(arg, b.getInt32(dim));
      }
      // Shims return i32/i64 variants; adjust width if needed.
      if (replacement->getType() != call->getType()) {
        llvm::IRBuilder<> b(call);
        replacement =
            b.CreateZExtOrTrunc(replacement, call->getType());
      }
      call->replaceAllUsesWith(replacement);
      call->eraseFromParent();
    }
  }

  // Per-argument AIR metadata. Leading params: pointers become air.buffer
  // entries whose location_index is the parameter index — the exact order
  // VegaRT binds buffers at launch. By-value scalars keep their position but
  // are not listed (the golden sample lists buffers and builtins only... it
  // listed all three including the by-value id as builtin; scalars passed
  // by value from Mojo become setBytes-bound constant buffers instead), so
  // v1 requires kernels whose leading params are all pointers.
  for (unsigned i = 0; i != firstBuiltinIdx; ++i) {
    llvm::Argument *arg = newFn->getArg(i);
    bool isScalar = scalarOrigTypes[i] != nullptr;
    unsigned as = isScalar
                      ? 2u
                      : llvm::cast<llvm::PointerType>(arg->getType())
                            ->getAddressSpace();
    unsigned size =
        isScalar ? static_cast<unsigned>(
                       m.getDataLayout().getTypeAllocSize(scalarOrigTypes[i]))
                 : 4u;
    argMD.push_back(mdStrings(
        c, {mdI32(c, i), mdStr(c, "air.buffer"),
            mdStr(c, "air.location_index"), mdI32(c, i), mdI32(c, 1),
            mdStr(c, isScalar ? "air.read" : "air.read_write"),
            mdStr(c, "air.address_space"), mdI32(c, as ? as : 1),
            mdStr(c, "air.arg_type_size"), mdI32(c, size),
            mdStr(c, "air.arg_type_align_size"), mdI32(c, size),
            mdStr(c, "air.arg_type_name"), mdStr(c, isScalar ? "uint" : "void"),
            mdStr(c, "air.arg_name"), mdStr(c, arg->getName())}));
    if (!isScalar)
      arg->addAttr(llvm::Attribute::get(c, "air-buffer-no-alias"));
  }
  for (unsigned u = 0; u < uses.size(); ++u) {
    unsigned idx = firstBuiltinIdx + u;
    argMD.push_back(mdStrings(
        c, {mdI32(c, idx), mdStr(c, uses[u].kind->airTag),
            mdStr(c, "air.arg_type_name"),
            mdStr(c, uses[u].anyDimensioned ? "uint3" : "uint"),
            mdStr(c, "air.arg_name"), mdStr(c, uses[u].kind->shimBase)}));
  }

  fn.eraseFromParent();

  // Drop now-unused `air.*` builtin declarations; the parameters replaced
  // every call, and stray unknown declarations have no place in AIR.
  llvm::SmallVector<llvm::Function *, 8> dead;
  for (llvm::Function &g : m)
    if (g.isDeclaration() && g.getName().starts_with("air.") && g.use_empty())
      dead.push_back(&g);
  for (llvm::Function *g : dead)
    g->eraseFromParent();
  return newFn;
}

// AIR runtime-function name mangling: the stdlib emits bare stems
// (`air.simd_shuffle_xor`); AIR's real functions carry type suffixes
// (`air.simd_shuffle_xor.u.i32`, `.f32`, `.f16` — from golden MSL probes).
// Integers use the unsigned spelling: shuffles move bits, not values.
std::optional<std::string> airTypeSuffix(llvm::Type *ty) {
  if (ty->isFloatTy())
    return ".f32";
  if (ty->isHalfTy())
    return ".f16";
  if (auto *it = llvm::dyn_cast<llvm::IntegerType>(ty)) {
    switch (it->getBitWidth()) {
    case 8:
      return ".u.i8";
    case 16:
      return ".u.i16";
    case 32:
      return ".u.i32";
    }
  }
  if (auto *vt = llvm::dyn_cast<llvm::FixedVectorType>(ty)) {
    if (auto inner = airTypeSuffix(vt->getElementType())) {
      std::string s = *inner;
      // ".f16" -> ".v2f16" style; ".u.i32" -> ".u.v2i32"
      size_t lastDot = s.rfind('.');
      return s.substr(0, lastDot + 1) + "v" +
             std::to_string(vt->getNumElements()) + s.substr(lastDot + 1);
    }
  }
  return std::nullopt;
}

void mangleAirOps(llvm::Module &m) {
  static const llvm::StringRef stems[] = {
      "air.simd_shuffle_xor", "air.simd_shuffle_down", "air.simd_shuffle_up",
      "air.simd_shuffle"};
  llvm::SmallVector<llvm::CallInst *, 16> calls;
  for (llvm::Function &fn : m)
    for (llvm::BasicBlock &bb : fn)
      for (llvm::Instruction &inst : bb)
        if (auto *call = llvm::dyn_cast<llvm::CallInst>(&inst))
          if (llvm::Function *callee = call->getCalledFunction())
            for (llvm::StringRef stem : stems)
              if (callee->getName() == stem) {
                calls.push_back(call);
                break;
              }
  for (llvm::CallInst *call : calls) {
    auto suffix = airTypeSuffix(call->getArgOperand(0)->getType());
    if (!suffix)
      continue; // leaves the bare stem; fails loudly with a clear label
    std::string mangled =
        (call->getCalledFunction()->getName() + *suffix).str();
    llvm::FunctionCallee target = m.getOrInsertFunction(
        mangled, call->getFunctionType());
    call->setCalledFunction(target);
  }
}

// Full-module AIR legalization.
llvm::Error legalizeModule(llvm::Module &m) {
  llvm::LLVMContext &c = m.getContext();
  m.setTargetTriple(llvm::Triple(kAirTriple));
  mangleAirOps(m);
  remapAddressSpaces(m);

  // Metal has no 64-bit floats anywhere (MSL has no `double`); emitting the
  // type produces bitcode the AIR reader rejects opaquely. Diagnose cleanly.
  for (llvm::Function &fn : m) {
    if (fn.isDeclaration())
      continue;
    for (llvm::BasicBlock &bb : fn)
      for (llvm::Instruction &inst : bb) {
        auto usesF64 = [](llvm::Type *ty) {
          return ty->isDoubleTy() ||
                 (ty->isVectorTy() &&
                  ty->getScalarType()->isDoubleTy());
        };
        bool bad = usesF64(inst.getType());
        for (llvm::Value *operand : inst.operands())
          bad |= usesF64(operand->getType());
        if (bad)
          return llvm::createStringError(
              llvm::inconvertibleErrorCode(),
              "float64 is not supported on Metal/AIR (kernel '%s'); Metal "
              "has no double type — use Float32 in device code",
              fn.getName().str().c_str());
      }
  }

  // Kernels: defined, externally-visible functions.
  llvm::SmallVector<llvm::Function *, 4> kernels;
  for (llvm::Function &fn : m)
    if (!fn.isDeclaration() && !fn.hasLocalLinkage())
      kernels.push_back(&fn);

  llvm::NamedMDNode *airKernels = m.getOrInsertNamedMetadata("air.kernel");
  for (llvm::Function *fn : kernels) {
    llvm::SmallVector<llvm::Metadata *, 8> argMD;
    llvm::Function *legal = legalizeKernel(*fn, argMD);
    legal->setCallingConv(llvm::CallingConv::C);
    airKernels->addOperand(llvm::MDNode::get(
        c, {llvm::ConstantAsMetadata::get(legal), llvm::MDNode::get(c, {}),
            llvm::MDNode::get(c, argMD)}));
  }

  // Module flags and AIR identification, per the golden sample.
  auto addFlag = [&](llvm::StringRef name, uint32_t value, uint32_t behavior) {
    m.addModuleFlag(static_cast<llvm::Module::ModFlagBehavior>(behavior), name,
                    value);
  };
  if (!m.getModuleFlag("wchar_size"))
    addFlag("wchar_size", 4, llvm::Module::Error);
  if (!m.getModuleFlag("frame-pointer"))
    addFlag("frame-pointer", 2, llvm::Module::Max);
  addFlag("air.max_device_buffers", 31, llvm::Module::Max);
  addFlag("air.max_constant_buffers", 31, llvm::Module::Max);
  addFlag("air.max_threadgroup_buffers", 31, llvm::Module::Max);
  addFlag("air.max_textures", 128, llvm::Module::Max);
  addFlag("air.max_read_write_textures", 8, llvm::Module::Max);
  addFlag("air.max_samplers", 16, llvm::Module::Max);
  if (!m.getModuleFlag("SDK Version")) {
    llvm::SmallVector<uint32_t, 2> sdk = {14, 2};
    m.addModuleFlag(llvm::Module::Warning, "SDK Version",
                    llvm::ConstantDataArray::get(c, sdk));
  }

  auto setVersionMD = [&](llvm::StringRef name,
                          llvm::ArrayRef<llvm::Metadata *> elts) {
    llvm::NamedMDNode *node = m.getOrInsertNamedMetadata(name);
    if (node->getNumOperands() == 0)
      node->addOperand(llvm::MDNode::get(c, elts));
  };
  setVersionMD("air.version", {mdI32(c, 2), mdI32(c, 6), mdI32(c, 0)});
  setVersionMD("air.language_version",
               {mdStr(c, "Metal"), mdI32(c, 3), mdI32(c, 1), mdI32(c, 0)});
  setVersionMD("air.compile_options",
               {mdStr(c, "air.compile.denorms_disable")});
  setVersionMD("air.source_file_name", {mdStr(c, "mojo-kernel")});
  llvm::NamedMDNode *ident = m.getOrInsertNamedMetadata("llvm.ident");
  if (ident->getNumOperands() == 0)
    ident->addOperand(llvm::MDNode::get(
        c, {mdStr(c, "MacVegaFork AIR backend (KGEN)")}));

  // The module is handed to Apple's clang-17-era `metal -x ir` as TEXT;
  // strip attributes whose llvm-22 textual spelling that parser rejects
  // (e.g. nocapture now prints as `captures(none)`, `range(...)` is new).
  auto scrub = [](llvm::Function &fn) {
    // Host-side target attributes are meaningless (and fatal) to the
    // driver's AIR->GCN compiler; the golden sample carries neither.
    fn.removeFnAttr("target-cpu");
    fn.removeFnAttr("target-features");
    fn.removeFnAttr("tune-cpu");
    fn.setDSOLocal(false);
    for (llvm::Argument &arg : fn.args()) {
      arg.removeAttr(llvm::Attribute::Captures);
      arg.removeAttr(llvm::Attribute::Range);
      arg.removeAttr(llvm::Attribute::Initializes);
      arg.removeAttr(llvm::Attribute::DeadOnUnwind);
      arg.removeAttr(llvm::Attribute::Writable);
    }
    fn.removeRetAttr(llvm::Attribute::Range);
  };
  for (llvm::Function &fn : m)
    scrub(fn);
  return llvm::Error::success();
}

//===----------------------------------------------------------------------===//
// Backend
//===----------------------------------------------------------------------===//

class AirBackend final : public TargetBackend {
public:
  const TargetTraits *traits() const override { return &AirTraits::get(); }

  SplitStrategy splitStrategy(const CompilationOptions &) const override {
    return SplitStrategy::PerExported;
  }
  bool isOffload() const override { return true; }
  bool isBaseTarget() const override { return false; }

  /// The stdlib reaches AIR builtins through `llvm.call_intrinsic` ops named
  /// `llvm.air.*`, which are not real LLVM intrinsics and fail MLIR->LLVM
  /// translation. Rewrite them into plain calls to `air.*`-named external
  /// functions (legal names); the AIR legalizer converts those calls into
  /// trailing kernel parameters later.
  void
  prepareModuleForLowering(mlir::Operation *module,
                           const CompilationOptions &options) const override {
    auto moduleOp = llvm::dyn_cast<mlir::ModuleOp>(module);
    if (!moduleOp)
      return;
    mlir::SymbolTable symtab(moduleOp);
    llvm::SmallVector<mlir::LLVM::CallIntrinsicOp, 8> worklist;
    moduleOp.walk([&](mlir::LLVM::CallIntrinsicOp op) {
      if (op.getIntrin().starts_with("llvm.air."))
        worklist.push_back(op);
    });
    for (mlir::LLVM::CallIntrinsicOp op : worklist) {
      llvm::StringRef airName = op.getIntrin().drop_front(strlen("llvm."));
      mlir::OpBuilder b(op);
      auto fn = symtab.lookup<mlir::LLVM::LLVMFuncOp>(airName);
      if (!fn) {
        mlir::OpBuilder declBuilder(moduleOp.getBodyRegion());
        auto fnType = mlir::LLVM::LLVMFunctionType::get(
            op.getNumResults() ? op.getResult(0).getType()
                               : mlir::LLVM::LLVMVoidType::get(
                                     moduleOp.getContext()),
            llvm::to_vector(op.getArgs().getTypes()));
        fn = declBuilder.create<mlir::LLVM::LLVMFuncOp>(op.getLoc(), airName,
                                                        fnType);
        symtab.insert(fn);
      }
      auto call =
          b.create<mlir::LLVM::CallOp>(op.getLoc(), fn, op.getArgs());
      if (op.getNumResults())
        op.getResult(0).replaceAllUsesWith(call.getResult());
      op.erase();
    }
  }

  /// AIR has no LLVM codegen target. The TargetMachine (opt pipeline only —
  /// emission goes through emitObject/emitBitcode) is built for arm64, the
  /// same convention the upstream comment in CompilationOptions describes.
  CompilationOptions
  adjustOptionsForTargetMachine(const CompilationOptions &options,
                                llvm::StringRef moduleTriple) const override {
    CompilationOptions adjusted = options;
    adjusted.targetTriple = AirTraits::get().codegenTriple(moduleTriple);
    adjusted.targetCpu = "generic";
    adjusted.targetFeatures = "";
    return adjusted;
  }

protected:
  std::optional<unsigned> sharedMemoryAddressSpace() const override {
    return 3; // AIR threadgroup memory
  }

public:
  void emitBitcode(llvm::Module &module,
                   llvm::raw_pwrite_stream &os) const override {
    M::KGEN::LLVM::WriteBitcode17ToFile(module, os,
                               /*ShouldPreserveUseListOrder=*/false,
                               /*Index=*/nullptr, /*GenerateHash=*/false,
                               /*ModHash=*/nullptr);
  }

  ErrorOr<BufferRef> emitAssembly(llvm::Module &module,
                                  EmitContext &ctx) const override {
    // Legalized textual IR: the debugging/`--emit=asm` view of the AIR.
    if (llvm::Error err = legalizeModule(module))
      return Error("AIR legalization failed");
    WriteableBufferRef buf = WriteableBuffer::get();
    module.print(*buf, nullptr); // WriteableBuffer is a raw_pwrite_stream
    return buf;
  }

  ErrorOr<BufferRef> emitObject(llvm::Module &module,
                                EmitContext &ctx) const override {
    if (llvm::Error err = legalizeModule(module))
      return Error("AIR legalization failed");

    // Downgrade modern IR constructs to what the LLVM-17-era AIR reader
    // accepts (in-tree pass, built for exactly this).
    {
      llvm::PassBuilder pb;
      llvm::LoopAnalysisManager lam;
      llvm::FunctionAnalysisManager fam;
      llvm::CGSCCAnalysisManager cgam;
      llvm::ModuleAnalysisManager mam;
      pb.registerModuleAnalyses(mam);
      pb.registerCGSCCAnalyses(cgam);
      pb.registerFunctionAnalyses(fam);
      pb.registerLoopAnalyses(lam);
      pb.crossRegisterProxies(lam, fam, cgam, mam);
      llvm::ModulePassManager mpm;
      // The published Metal emission machinery, by its own declarations:
      // BitcodeWriter17.cpp:15 — "for writing Metal bitcode"; Apple's AIR
      // reader is LLVM-18-based (BitcodeWriter17.cpp ~1765) and requires
      // typed POINTER records (opaque record code 25 presents as "Failed to
      // upgrade function bitcode" at pipeline creation).
      // LLVMIRDowngradePass is the published MetalAIRPass skeleton
      // (LLVMIRDowngradePass.cpp:184) — lifetime-intrinsic downgrading
      // today; our legalizeModule above supplies the body that upstream
      // kept closed. PointerRewriter un-opaques for the writer.
      mpm.addPass(LLVMIRDowngradePass());
      mpm.addPass(PointerRewriter());
      mpm.run(module, mam);
    }

    // Emission: AIR bitcode via the cooperating PointerRewriter +
    // BitcodeWriter17 pair (typed POINTER records), wrapped in the bitcode
    // wrapper header, packaged by `xcrun metallib`.
    llvm::SmallVector<char, 0> bc;
    {
      llvm::raw_svector_ostream bcos(bc);
      M::KGEN::LLVM::WriteBitcode17ToFile(module, bcos,
                                          /*ShouldPreserveUseListOrder=*/false,
                                          /*Index=*/nullptr,
                                          /*GenerateHash=*/false,
                                          /*ModHash=*/nullptr);
    }
    // WriteBitcode17ToFile's wrapper size field can undercount by the
    // trailing alignment words on some modules; Apple's loader requires the
    // header to match the file exactly ("Unexpected bitcode file"). Patch
    // the size field to the real payload length.
    if (bc.size() >= 20) {
      uint32_t magic = 0;
      memcpy(&magic, bc.data(), 4);
      if (magic == 0x0B17C0DE) {
        uint32_t realSize = static_cast<uint32_t>(bc.size() - 20);
        memcpy(bc.data() + 12, &realSize, 4);
      }
    }
    llvm::SmallString<128> llPath, libPath;
    if (llvm::sys::fs::createTemporaryFile("vega-kernel", "air", llPath))
      return Error("failed to create temporary .air file");
    if (llvm::sys::fs::createTemporaryFile("vega-kernel", "metallib", libPath))
      return Error("failed to create temporary .metallib file");
    {
      std::error_code ec;
      llvm::raw_fd_ostream out(llPath, ec);
      if (ec)
        return Error("failed to open temporary .air for writing");
      // WriteBitcode17ToFile emits the bitcode wrapper header itself.
      out.write(bc.data(), bc.size());
    }

    llvm::ErrorOr<std::string> xcrun = llvm::sys::findProgramByName("xcrun");
    if (!xcrun)
      return Error("xcrun not found; the AIR emitter needs Xcode");
    llvm::SmallString<128> errPath;
    if (llvm::sys::fs::createTemporaryFile("vega-metal", "err", errPath))
      return Error("failed to create temporary stderr file");
    llvm::SmallVector<llvm::StringRef, 12> args = {
        *xcrun, "-sdk", "macosx", "metallib", llPath, "-o", libPath};
    std::optional<llvm::StringRef> redirects[3] = {
        std::nullopt, std::nullopt, llvm::StringRef(errPath)};
    std::string errMsg;
    int rc = llvm::sys::ExecuteAndWait(*xcrun, args, std::nullopt, redirects,
                                       0, 0, &errMsg);
    if (rc != 0) {
      std::string toolErr;
      if (auto buf = llvm::MemoryBuffer::getFile(errPath))
        toolErr = (*buf)->getBuffer().str();
      llvm::sys::fs::remove(errPath);
      llvm::sys::fs::remove(libPath);
      // Keep the rejected .ll for postmortem.
      return Error(Twine("xcrun metallib failed (rc=") + Twine(rc) +
                   ") on " + llPath + ": " + toolErr + errMsg);
    }
    llvm::sys::fs::remove(errPath);

    // Debug escape hatch: VEGA_KEEP_AIR=<dir> keeps the .ll and .metallib.
    if (const char *keep = ::getenv("VEGA_KEEP_AIR")) {
      llvm::sys::fs::copy_file(llPath,
                               (std::string(keep) + "/vega-kernel.air"));
      llvm::sys::fs::copy_file(
          libPath, (std::string(keep) + "/vega-kernel.metallib"));
    }
    auto libBufOr = llvm::MemoryBuffer::getFile(libPath);
    llvm::sys::fs::remove(llPath);
    if (!libBufOr) {
      llvm::sys::fs::remove(libPath);
      return Error("failed to read packed metallib");
    }
    llvm::sys::fs::remove(libPath);

    WriteableBufferRef out = WriteableBuffer::get();
    *out << (*libBufOr)->getBuffer();
    return out;
  }

  ErrorOr<BufferRef> createArchive(llvm::MutableArrayRef<BufferRef>,
                                   llvm::StringRef,
                                   EmitContext &) const override {
    return Error("AirBackend::createArchive is not wired");
  }
};

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wglobal-constructors"
RegisterTargetBackend<AirBackend> registerAirBackend;
#pragma GCC diagnostic pop

} // namespace
} // namespace M::KGEN
