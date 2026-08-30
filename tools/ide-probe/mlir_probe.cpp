// An out-of-tree consumer building MLIR IR against the distribution.
//
// The companion to ide_probe.cpp: that one proves LLVM is linkable, this one
// proves MLIR is, which is what an editor needs to embed compiler phases
// rather than shell out. Compiled and run by check-dist.sh.
#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/MLIRContext.h"
#include "llvm/Support/raw_ostream.h"

int main() {
  mlir::MLIRContext ctx;
  mlir::OpBuilder b(&ctx);
  auto mod = mlir::ModuleOp::create(b.getUnknownLoc(), "probe");
  llvm::outs() << "mlir context ok, module: " << mod.getName().value_or("?") << "\n";
  mod->print(llvm::outs());
  llvm::outs() << "\n";
  return 0;
}
