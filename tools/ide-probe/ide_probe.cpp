// Stands in for an out-of-tree consumer -- an IDE, a language server -- linking
// the distribution's LLVM.
//
// check-dist.sh compiles and runs this against dist/CocoaMojo alone: its
// headers, its libLLVM.dylib, no bazel and no LLVM source tree. It builds a
// module, verifies it, and prints the registered targets, which is the part
// worth watching: the list comes from the generated llvm/Config/Targets.def, so
// it is proof that the header staging shipped the *generated* config rather than
// the source .in templates. It should name only the AArch64 family. If it names
// X86, the headers and the dylib disagree about what LLVM this is.
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Verifier.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/TargetParser/Host.h"

int main() {
  llvm::InitializeAllTargets();
  llvm::InitializeAllTargetInfos();

  llvm::LLVMContext ctx;
  auto mod = std::make_unique<llvm::Module>("ide_probe", ctx);
  auto *fty = llvm::FunctionType::get(llvm::Type::getInt32Ty(ctx), false);
  auto *fn = llvm::Function::Create(fty, llvm::Function::ExternalLinkage,
                                    "answer", mod.get());
  llvm::IRBuilder<> b(llvm::BasicBlock::Create(ctx, "entry", fn));
  b.CreateRet(b.getInt32(42));

  if (llvm::verifyModule(*mod, &llvm::errs())) return 1;
  llvm::outs() << "host triple: " << llvm::sys::getDefaultTargetTriple() << "\n";
  llvm::outs() << "registered targets:";
  for (const auto &t : llvm::TargetRegistry::targets())
    llvm::outs() << " " << t.getName();
  llvm::outs() << "\n";
  mod->print(llvm::outs(), nullptr);
  return 0;
}
