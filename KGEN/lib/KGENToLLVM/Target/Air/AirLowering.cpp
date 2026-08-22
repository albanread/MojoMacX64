//===----------------------------------------------------------------------===//
// VEGA-FORK: MLIR-lowering policy for the AIR (Metal GPU) target.
//
// Owns the lowering of `llvm.air.*` builtin "intrinsics": those names are
// not real LLVM intrinsics, so they lower to calls of `air.*`-named external
// functions which the AIR backend later converts to kernel parameters /
// mangled AIR runtime calls. The conversion creates module-level function
// declarations, so it MUST run in the module-scoped, single-threaded
// LowerGlobalPOPToLLVM pass — doing it from the per-function LowerPOPToLLVM
// pass raced sibling function conversions on the symbol table (triage
// finding: duplicate declarations / crashes when several kernels share a
// builtin).
//===----------------------------------------------------------------------===//

#include "KGEN/POPDialect/POPOps.h"
#include "Target/Air/AirTraits.h"
#include "Target/TargetLowering.h"

#include "mlir/Conversion/LLVMCommon/Pattern.h"
#include "mlir/Conversion/LLVMCommon/TypeConverter.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/SymbolTable.h"

namespace M::KGEN {
namespace {

// AIR runtime functions are type-suffixed (air.simd_shuffle_xor.u.i32,
// .f32, .f16 — golden MSL probes). Mangle at declaration time so each
// payload type gets its own correctly-typed declaration; a shared bare stem
// asserts "bad signature" at translation when payload types differ.
std::optional<std::string> airSuffixFor(mlir::Type ty) {
  if (ty.isF32())
    return std::string(".f32");
  if (ty.isF16())
    return std::string(".f16");
  if (auto it = llvm::dyn_cast<mlir::IntegerType>(ty)) {
    switch (it.getWidth()) {
    case 8:
      return std::string(".u.i8");
    case 16:
      return std::string(".u.i16");
    case 32:
      return std::string(".u.i32");
    case 64:
      return std::string(".u.i64");
    }
  }
  if (auto vt = llvm::dyn_cast<mlir::VectorType>(ty)) {
    if (auto inner = airSuffixFor(vt.getElementType())) {
      std::string s = *inner;
      size_t lastDot = s.rfind('.');
      return s.substr(0, lastDot + 1) + "v" +
             std::to_string(vt.getNumElements()) + s.substr(lastDot + 1);
    }
  }
  return std::nullopt;
}

class ConvertAirIntrinsicToCall
    : public mlir::ConvertOpToLLVMPattern<POP::CallLLVMIntrinsicOp> {
public:
  ConvertAirIntrinsicToCall(mlir::LLVMTypeConverter &converter,
                            mlir::SymbolTable &symtab)
      : ConvertOpToLLVMPattern(converter, /*benefit=*/10), symtab(symtab) {}

  mlir::LogicalResult
  matchAndRewrite(POP::CallLLVMIntrinsicOp op, OpAdaptor adaptor,
                  mlir::ConversionPatternRewriter &rewriter) const override {
    llvm::StringRef intrin =
        llvm::cast<mlir::StringAttr>(op.getIntrin()).getValue();
    if (!intrin.starts_with("llvm.air."))
      return mlir::failure();

    llvm::SmallVector<mlir::Type> resultTypes;
    if (mlir::failed(getTypeConverter()->convertTypes(op.getResultTypes(),
                                                      resultTypes)))
      return mlir::failure();
    mlir::Type resType =
        resultTypes.empty()
            ? mlir::LLVM::LLVMVoidType::get(rewriter.getContext())
            : resultTypes[0];

    std::string fnName = intrin.drop_front(strlen("llvm.")).str();
    // KGEN packs multi-operand intrinsic args into a struct; AIR runtime
    // functions take flat scalar arguments — unpack at the LLVM level (the
    // module-scope analogue of LowerPOPToLLVM's expandOperands).
    llvm::SmallVector<mlir::Value> operands;
    for (mlir::Value v : adaptor.getOperands()) {
      if (auto st = llvm::dyn_cast<mlir::LLVM::LLVMStructType>(v.getType())) {
        for (auto [idx, elemTy] : llvm::enumerate(st.getBody()))
          operands.push_back(rewriter.createOrFold<mlir::LLVM::ExtractValueOp>(
              op.getLoc(), v, idx));
      } else {
        operands.push_back(v);
      }
    }
    llvm::SmallVector<mlir::Type> argTypes;
    for (mlir::Value v : operands)
      argTypes.push_back(v.getType());

    if (llvm::StringRef(fnName).starts_with("air.simd_shuffle") &&
        !operands.empty()) {
      if (auto suffix = airSuffixFor(operands[0].getType()))
        fnName += *suffix;
    }
    auto fn = symtab.lookup<mlir::LLVM::LLVMFuncOp>(fnName);
    if (!fn) {
      auto module = llvm::cast<mlir::ModuleOp>(symtab.getOp());
      mlir::OpBuilder::InsertionGuard guard(rewriter);
      rewriter.setInsertionPointToStart(module.getBody());
      fn = mlir::LLVM::LLVMFuncOp::create(
          rewriter, op.getLoc(), fnName,
          mlir::LLVM::LLVMFunctionType::get(resType, argTypes));
      symtab.insert(fn); // single-threaded pass: safe by construction
    }
    rewriter.replaceOpWithNewOp<mlir::LLVM::CallOp>(op, fn, operands);
    return mlir::success();
  }

private:
  mlir::SymbolTable &symtab;
};

class AirLowering final : public TargetLowering {
public:
  const TargetTraits *traits() const override { return &AirTraits::get(); }
  bool isBaseTarget() const override { return false; }

  bool isLoweredInGlobalPOPPass(mlir::Operation *op) const override {
    auto call = llvm::dyn_cast<POP::CallLLVMIntrinsicOp>(op);
    if (!call)
      return false;
    auto name = llvm::dyn_cast<mlir::StringAttr>(call.getIntrin());
    return name && name.getValue().starts_with("llvm.air.");
  }

  void populateLowerGlobalPOPToLLVMPatterns(
      mlir::RewritePatternSet &patterns, mlir::LLVMTypeConverter &converter,
      mlir::SymbolTable &symtab, TargetInfoAttr target) const override {
    patterns.insert<ConvertAirIntrinsicToCall>(converter, symtab);
  }
};

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wglobal-constructors"
RegisterTargetLowering<AirLowering> registerAirLowering;
#pragma GCC diagnostic pop

} // namespace
} // namespace M::KGEN
