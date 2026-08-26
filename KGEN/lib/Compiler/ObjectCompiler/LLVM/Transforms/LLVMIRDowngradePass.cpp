//===----------------------------------------------------------------------===//
// Copyright (c) 2026, Modular Inc. All rights reserved.
//
// Licensed under the Apache License v2.0 with LLVM Exceptions:
// https://llvm.org/LICENSE.txt
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//
//
// LLVM IR Downgrade Pass - Transform LLVM IR for backend compilation
// that takes older version of LLVM IR.
//
//===----------------------------------------------------------------------===//

#include "LLVMIRDowngradePass.h"
#include "TransformUtils.h"

#include "llvm/ADT/SmallSet.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/Analysis/LazyCallGraph.h"
#include "llvm/IR/Attributes.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InstrTypes.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/PassManager.h"
#include "llvm/IR/Verifier.h"
#include "llvm/Pass.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Transforms/Utils/BasicBlockUtils.h"

#define KGEN_DEBUG_TYPE "llvm-ir-downgrade-pass"

using namespace llvm;
using namespace M::KGEN;

static bool isLifetimeIntrinsic(Function &f) {
  SmallSet<StringRef, 2> lifetimeIntrinsicNames{"llvm.lifetime.end",
                                                "llvm.lifetime.start"};
  for (auto name : lifetimeIntrinsicNames) {
    if (f.getName().contains(name))
      return true;
  }
  return false;
}
namespace {

/// ----------------------------------------------------------
/// Downgrade Lifetime intrinsics to older version:
/// From:
/// declare void @llvm.lifetime.end.p0(ptr captures(none))
/// to (add i64 value which is the size of the memory ptr is pointing):
/// declare void @llvm.lifetime.end.p0(i64, ptr captures(none))
/// and
/// From:
/// declare void @llvm.lifetime.start.p0(ptr captures(none))
/// to (add i64 value which is the size of the memory ptr is pointing):
/// declare void @llvm.lifetime.start.p0(i64, ptr captures(none))
///
/// Newer LLVM IR doesn't require this value anymore since it can be
/// inferred from the alloca size where ptr is assigned.
/// https://github.com/llvm/llvm-project/pull/149310
/// The updater here also update the callsite of the intrinsics to
/// with the alloca size.

class LifetimeIntrinsicUpdater : public CallGraphUpdater {
  const DataLayout &dataLayout;
  llvm::LLVMContext &ctx;

public:
  explicit LifetimeIntrinsicUpdater(llvm::Module &module,
                                    llvm::ModuleAnalysisManager &mam)
      : CallGraphUpdater(module, mam), dataLayout(module.getDataLayout()),
        ctx(module.getContext()) {}

  /// Analyze entire call graph to find functions that requires update
  virtual bool analyze() final {
    for (llvm::Function &f : module) {
      if (!f.isDeclaration())
        continue;

      if (isLifetimeIntrinsic(f))
        functionsToUpdate.insert(&f);
    }

    auto hasLifetimeMarker = [&](llvm::Function &f) {
      for (llvm::BasicBlock &bb : f) {
        for (llvm::Instruction &inst : bb) {
          if (llvm::CallInst *callInst =
                  llvm::dyn_cast<llvm::CallInst>(&inst)) {
            llvm::Function *callee = callInst->getCalledFunction();
            if (callee && (functionsToUpdate.contains(callee) ||
                           isLifetimeIntrinsic(*callee))) {
              return true;
            }
          }
        }
      }
      return false;
    };

    SmallVector<llvm::Function *, 8> worklist;
    for (llvm::Function &f : module) {
      if (isLifetimeIntrinsic(f) || hasLifetimeMarker(f)) {
        functionsToUpdate.insert(&f);
        worklist.push_back(&f);
      }
    }

    return !functionsToUpdate.empty();
  }

  virtual llvm::Value *updateCall(llvm::CallInst &call, llvm::Function &newFunc,
                                  llvm::Function &callerFunc) final {
    if (!isLifetimeIntrinsic(*call.getCalledFunction()))
      return &call;

    Value *ptr = call.args().begin()->get();
    if (auto alloca = dyn_cast<llvm::AllocaInst>(ptr)) {
      SmallVector<llvm::Value *> args;
      // Infer the ptr memory size from alloca.
      args.push_back(ConstantInt::get(Type::getInt64Ty(ctx),
                                      *alloca->getAllocationSize(dataLayout)));

      for (auto &arg : call.args())
        args.push_back(arg);
      return CallInst::Create(&newFunc, args);
    }

    return &call;
  }

  /// Create a new function with the "i64 size" parameter.
  /// func function into it.
  virtual llvm::Function *updateFunction(llvm::Function &func) final {
    if (!isLifetimeIntrinsic(func))
      return &func;

    FunctionType *oldFT = func.getFunctionType();
    SmallVector<Type *> newParams;
    newParams.push_back(IntegerType::get(ctx, 64));
    newParams.append(oldFT->param_begin(), oldFT->param_end());
    FunctionType *newFT =
        FunctionType::get(oldFT->getReturnType(), newParams, oldFT->isVarArg());

    // Store the original name before creating new function
    std::string originalName = func.getName().str();

    // Create new function with void return type
    Function *newFunc = Function::Create(newFT, func.getLinkage(),
                                         originalName + ".temp", &module);

    // Update the arg attribute.
    AttributeSet originalAttr = func.getAttributes().getParamAttrs(0);
    newFunc->setAttributes(func.getAttributes().removeParamAttributes(ctx, 0));

    AttrBuilder builder(ctx, originalAttr);
    newFunc->addParamAttrs(1, builder);

    return newFunc;
  }
};
} // namespace

static void downgradeLifetimeIntrinsics(Module &module,
                                        llvm::ModuleAnalysisManager &mam) {

  LifetimeIntrinsicUpdater updater(module, mam);
  if (updater.analyze()) {
    updater.update();
  }
}

namespace {

// VEGA-FORK: the AIR encoding is LLVM-5-vintage while our LLVM is 22, so
// constructs newer than the reader must be lowered away here (this is the
// published MetalAIRPass; upstream downgrades lifetime intrinsics only):
//   - `freeze` (LLVM 10) and unary `fneg` (LLVM 8) hard-crash
//     BitcodeWriter17 with llvm_unreachable
//   - GEP no-wrap flags (LLVM 19) survive into AIR and break the driver's
//     GCN compiler
// Standard downgrade practice, cf. Julia's llvm-downgrade.
// `poison` (LLVM 12) is newer than the AMD Metal plugin's LLVM fork, which
// emits none of its own; Apple's shader compiler crashes on modules that use
// it. `undef` is the classic equivalent and is what older readers expect.
llvm::Constant *depoison(llvm::Constant *c) {
  if (llvm::isa<llvm::PoisonValue>(c))
    return llvm::UndefValue::get(c->getType());
  auto *agg = llvm::dyn_cast<llvm::ConstantAggregate>(c);
  if (!agg)
    return c;
  bool changed = false;
  llvm::SmallVector<llvm::Constant *, 8> elems;
  for (unsigned i = 0, e = agg->getNumOperands(); i != e; ++i) {
    llvm::Constant *elem = agg->getOperand(i);
    llvm::Constant *fixed = depoison(elem);
    changed |= fixed != elem;
    elems.push_back(fixed);
  }
  if (!changed)
    return c;
  if (llvm::isa<llvm::ConstantVector>(agg))
    return llvm::ConstantVector::get(elems);
  if (auto *at = llvm::dyn_cast<llvm::ArrayType>(agg->getType()))
    return llvm::ConstantArray::get(at, elems);
  if (auto *st = llvm::dyn_cast<llvm::StructType>(agg->getType()))
    return llvm::ConstantStruct::get(st, elems);
  return c;
}

void downgradePoison(llvm::Module &module) {
  for (llvm::Function &fn : module)
    for (llvm::BasicBlock &bb : fn)
      for (llvm::Instruction &inst : bb)
        for (llvm::Use &use : inst.operands())
          if (auto *c = llvm::dyn_cast<llvm::Constant>(use.get())) {
            llvm::Constant *fixed = depoison(c);
            if (fixed != c)
              use.set(fixed);
          }
}

// Expand llvm.vector.reduce.* into explicit element-wise operations.
//
// Third member of the family that includes llvm.vector.interleave2: AIR has
// never heard of the symbol, metallib accepts the module, and the failure
// surfaces only at pipeline creation. On the Vega II that reads "SC
// compilation failure: There is a call to an undefined label"; on Apple
// silicon the compiler service dies naming nothing.
//
// They arrive from ordinary Mojo -- SIMD.reduce_add / reduce_max, and any
// `comptime for` the optimiser recognises as a reduction. The sibling port
// found these the hard way: a pure-FMA benchmark failed at 4 and 8 accumulator
// chains while 1, 2, 16 and 32 passed, because the optimiser only forms the
// reduction at some widths.
//
// fadd and fmul are ORDERED: the intrinsic takes a start value and the result
// is (((start op v[0]) op v[1]) ...). Emitting a reduction tree instead would
// be a different answer in floating point, so the sequential form is used.
void expandVectorReduce(llvm::Module &module) {
  llvm::SmallVector<llvm::CallInst *, 8> dead;
  for (llvm::Function &fn : module)
    for (llvm::BasicBlock &bb : fn)
      for (llvm::Instruction &inst : bb) {
        auto *call = llvm::dyn_cast<llvm::CallInst>(&inst);
        if (!call || !call->getCalledFunction())
          continue;
        llvm::Intrinsic::ID id = call->getCalledFunction()->getIntrinsicID();

        bool ordered = id == llvm::Intrinsic::vector_reduce_fadd ||
                       id == llvm::Intrinsic::vector_reduce_fmul;
        unsigned vecArg = ordered ? 1 : 0;
        bool known =
            ordered || id == llvm::Intrinsic::vector_reduce_add ||
            id == llvm::Intrinsic::vector_reduce_mul ||
            id == llvm::Intrinsic::vector_reduce_and ||
            id == llvm::Intrinsic::vector_reduce_or ||
            id == llvm::Intrinsic::vector_reduce_xor ||
            id == llvm::Intrinsic::vector_reduce_smax ||
            id == llvm::Intrinsic::vector_reduce_smin ||
            id == llvm::Intrinsic::vector_reduce_umax ||
            id == llvm::Intrinsic::vector_reduce_umin ||
            id == llvm::Intrinsic::vector_reduce_fmax ||
            id == llvm::Intrinsic::vector_reduce_fmin;
        if (!known)
          continue;
        auto *vt = llvm::dyn_cast<llvm::FixedVectorType>(
            call->getArgOperand(vecArg)->getType());
        if (!vt)
          continue; // scalable: no fixed element count to unroll to

        llvm::IRBuilder<> b(call);
        b.setFastMathFlags(call->getFastMathFlags());
        llvm::Value *vec = call->getArgOperand(vecArg);
        unsigned n = vt->getNumElements();

        llvm::Value *acc = ordered ? call->getArgOperand(0)
                                   : b.CreateExtractElement(vec, uint64_t(0));
        for (unsigned e = ordered ? 0 : 1; e != n; ++e) {
          llvm::Value *x = b.CreateExtractElement(vec, e);
          switch (id) {
          case llvm::Intrinsic::vector_reduce_fadd:
            acc = b.CreateFAdd(acc, x);
            break;
          case llvm::Intrinsic::vector_reduce_fmul:
            acc = b.CreateFMul(acc, x);
            break;
          case llvm::Intrinsic::vector_reduce_add:
            acc = b.CreateAdd(acc, x);
            break;
          case llvm::Intrinsic::vector_reduce_mul:
            acc = b.CreateMul(acc, x);
            break;
          case llvm::Intrinsic::vector_reduce_and:
            acc = b.CreateAnd(acc, x);
            break;
          case llvm::Intrinsic::vector_reduce_or:
            acc = b.CreateOr(acc, x);
            break;
          case llvm::Intrinsic::vector_reduce_xor:
            acc = b.CreateXor(acc, x);
            break;
          case llvm::Intrinsic::vector_reduce_smax:
            acc = b.CreateSelect(b.CreateICmpSGT(acc, x), acc, x);
            break;
          case llvm::Intrinsic::vector_reduce_smin:
            acc = b.CreateSelect(b.CreateICmpSLT(acc, x), acc, x);
            break;
          case llvm::Intrinsic::vector_reduce_umax:
            acc = b.CreateSelect(b.CreateICmpUGT(acc, x), acc, x);
            break;
          case llvm::Intrinsic::vector_reduce_umin:
            acc = b.CreateSelect(b.CreateICmpULT(acc, x), acc, x);
            break;
          // An ordered select chain drops NaN, which is llvm.maxnum/minnum
          // semantics -- what the reduce intrinsic specifies, not
          // maximum/minimum.
          case llvm::Intrinsic::vector_reduce_fmax:
            acc = b.CreateSelect(b.CreateFCmpOGT(acc, x), acc, x);
            break;
          case llvm::Intrinsic::vector_reduce_fmin:
            acc = b.CreateSelect(b.CreateFCmpOLT(acc, x), acc, x);
            break;
          default:
            break;
          }
        }
        call->replaceAllUsesWith(acc);
        dead.push_back(call);
      }
  for (llvm::CallInst *call : dead)
    call->eraseFromParent();
  // Stranded declarations are swept by eraseDeadIntrinsicDeclarations, which
  // runs last over every llvm.* decl rather than just this family.
}

// Expand llvm.vector.interleave2 / deinterleave2 to shufflevector.
//
// These come from our own stdlib (SIMD.interleave / .deinterleave), not from
// the optimiser. Our LLVM spells them `llvm.vector.interleave2`; the
// LLVM-17-era reader Apple ships knows the construct only as
// `llvm.experimental.vector.interleave2`, so what arrives is an unresolved
// external -- which survives metallib and only fails at pipeline creation
// ("SC compilation failure: There is a call to an undefined label", measured
// on the Vega II; on Apple silicon the same thing kills the compiler service
// with no diagnostic at all).
//
// The expansion is exact:
//   interleave2(a, b)  -> shuffle, mask[2i] = i, mask[2i+1] = N + i
//   deinterleave2(v)   -> even[i] = v[2i], odd[i] = v[2i+1], packed as {even, odd}
void expandVectorInterleave(llvm::Module &module) {
  llvm::SmallVector<llvm::CallInst *, 8> calls;
  for (llvm::Function &fn : module)
    for (llvm::BasicBlock &bb : fn)
      for (llvm::Instruction &inst : bb)
        if (auto *call = llvm::dyn_cast<llvm::CallInst>(&inst))
          if (llvm::Function *callee = call->getCalledFunction()) {
            llvm::StringRef n = callee->getName();
            if (n.starts_with("llvm.vector.interleave2") ||
                n.starts_with("llvm.experimental.vector.interleave2") ||
                n.starts_with("llvm.vector.deinterleave2") ||
                n.starts_with("llvm.experimental.vector.deinterleave2"))
              calls.push_back(call);
          }

  for (llvm::CallInst *call : calls) {
    llvm::IRBuilder<> b(call);
    bool isInterleave =
        call->getCalledFunction()->getName().contains("vector.interleave2");
    if (isInterleave) {
      llvm::Value *lhs = call->getArgOperand(0);
      llvm::Value *rhs = call->getArgOperand(1);
      auto *vt = llvm::dyn_cast<llvm::FixedVectorType>(lhs->getType());
      if (!vt)
        continue; // scalable vectors: leave alone rather than mis-expand
      unsigned n = vt->getNumElements();
      llvm::SmallVector<int, 32> mask;
      for (unsigned i = 0; i < n; ++i) {
        mask.push_back(static_cast<int>(i));
        mask.push_back(static_cast<int>(n + i));
      }
      llvm::Value *woven = b.CreateShuffleVector(lhs, rhs, mask);
      call->replaceAllUsesWith(woven);
      call->eraseFromParent();
      continue;
    }

    llvm::Value *src = call->getArgOperand(0);
    auto *vt = llvm::dyn_cast<llvm::FixedVectorType>(src->getType());
    if (!vt)
      continue;
    unsigned half = vt->getNumElements() / 2;
    llvm::SmallVector<int, 16> evenMask, oddMask;
    for (unsigned i = 0; i < half; ++i) {
      evenMask.push_back(static_cast<int>(2 * i));
      oddMask.push_back(static_cast<int>(2 * i + 1));
    }
    llvm::Value *poison = llvm::PoisonValue::get(src->getType());
    llvm::Value *even = b.CreateShuffleVector(src, poison, evenMask);
    llvm::Value *odd = b.CreateShuffleVector(src, poison, oddMask);
    llvm::Value *packed = llvm::UndefValue::get(call->getType());
    packed = b.CreateInsertValue(packed, even, {0});
    packed = b.CreateInsertValue(packed, odd, {1});
    call->replaceAllUsesWith(packed);
    call->eraseFromParent();
  }
}

// Erase unused llvm.* declarations left behind by the expansions above.
//
// Measured on the Vega II: a dead declare is harmless here -- a module still
// declaring llvm.vector.interleave2 with no call to it compiles, links and
// runs correctly. On Apple silicon the sibling port measured the opposite:
// the declaration alone is enough to fail. We are not relying on our driver
// staying lenient, and an unused declaration is by definition free to drop.
//
// Restricted to the `llvm.` prefix: those names never appear in the kernel
// metadata, so use_empty() is the whole story for them. Host externals are
// left alone -- they resolve at link, not here.
void eraseDeadIntrinsicDeclarations(llvm::Module &module) {
  llvm::SmallVector<llvm::Function *, 8> dead;
  for (llvm::Function &fn : module)
    if (fn.isDeclaration() && fn.use_empty() && fn.getName().starts_with("llvm."))
      dead.push_back(&fn);
  for (llvm::Function *fn : dead)
    fn->eraseFromParent();
}

void downgradeModernConstructs(llvm::Module &module) {
  downgradePoison(module);
  expandVectorInterleave(module);
  expandVectorReduce(module);
  for (llvm::Function &fn : module) {
    for (llvm::BasicBlock &bb : fn) {
      for (llvm::Instruction &inst : llvm::make_early_inc_range(bb)) {
        if (auto *freeze = llvm::dyn_cast<llvm::FreezeInst>(&inst)) {
          freeze->replaceAllUsesWith(freeze->getOperand(0));
          freeze->eraseFromParent();
          continue;
        }
        if (auto *gep = llvm::dyn_cast<llvm::GetElementPtrInst>(&inst)) {
          // GEP no-wrap flags (nusw/nuw) are LLVM 19+; the AIR reader knows
          // only `inbounds`. Apple's own air-as rejects the text form
          // ("expected type" on `getelementptr inbounds nuw`), and the
          // encoded flag bits make the driver's GCN compiler bail with
          // "Compilation failed due to an interrupted compilation".
          gep->setNoWrapFlags(gep->isInBounds()
                                  ? llvm::GEPNoWrapFlags::inBounds()
                                  : llvm::GEPNoWrapFlags::none());
          continue;
        }
        auto *unary = llvm::dyn_cast<llvm::UnaryOperator>(&inst);
        if (unary && unary->getOpcode() == llvm::Instruction::FNeg) {
          llvm::IRBuilder<> builder(unary);
          llvm::Value *sub = builder.CreateFSub(
              llvm::ConstantFP::getNegativeZero(unary->getType()),
              unary->getOperand(0));
          if (auto *subInst = llvm::dyn_cast<llvm::Instruction>(sub))
            subInst->copyFastMathFlags(unary);
          unary->replaceAllUsesWith(sub);
          unary->eraseFromParent();
        }
      }
    }
  }
  eraseDeadIntrinsicDeclarations(module);
}

} // namespace

namespace M::KGEN {

// Implementation of MetalAIRPass::run
PreservedAnalyses LLVMIRDowngradePass::run(Module &module,
                                           ModuleAnalysisManager &mam) {

  downgradeLifetimeIntrinsics(module, mam);
  downgradeModernConstructs(module);
  return PreservedAnalyses::all();
}

} // namespace M::KGEN
