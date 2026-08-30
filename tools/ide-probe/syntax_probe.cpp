// Syntax-checking a Mojo buffer in-process, the way an editor would.
//
// This is the phase an IDE wants first and the one with the cleanest seam.
// M::MojoParserContext takes an llvm::SourceMgr you own and a
// LIT::ParserConfig, and every diagnostic arrives through SourceMgr's ordinary
// setDiagHandler hook as an llvm::SMDiagnostic carrying kind, location,
// message, ranges and fix-its. There is no MLIR diagnostic plumbing to stand
// up and no compilation pipeline to configure.
//
// Three orderings are load-bearing, and each is a real bug if you get it wrong:
//
//   1. Add the buffer to the SourceMgr BEFORE constructing MojoParserContext.
//      Its shared state snapshots the existing buffers into an
//      identifier -> id map used to reuse open buffers during import
//      resolution.
//   2. Install the diagnostic handler before parsing and clear it before the
//      handler's context object dies, or a later operation dereferences a
//      dangling pointer.
//   3. Destroy the MojoParserContext before the MLIRContext and the SourceMgr;
//      its destructor finalizes imported bytecode modules.
//
// parseFileForLSP, not parseFile: it body-resolves only what descends from the
// root and signature-resolves the rest, where parseFile body-resolves the whole
// transitive stdlib closure. At keystroke rates that is the difference between
// usable and not.
//
//   syntax_probe <file.mojo> [-I dir]...

#include "KGEN/MojoParser/EntryPoint.h"   // LIT::ParserConfig
#include "KGEN/MojoTooling/ParserDriver.h"
#include "KGEN/ToolCommon/CompilationOptions.h"
#include "Init/Init.h"

#include "mlir/IR/MLIRContext.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/raw_ostream.h"

#include <string>
#include <vector>

namespace {
struct DiagSink {
  unsigned errors = 0;
  unsigned warnings = 0;
};

void onDiagnostic(const llvm::SMDiagnostic &diag, void *context) {
  auto *sink = static_cast<DiagSink *>(context);
  llvm::StringRef kind;
  switch (diag.getKind()) {
  case llvm::SourceMgr::DK_Error:   kind = "error";   ++sink->errors;   break;
  case llvm::SourceMgr::DK_Warning: kind = "warning"; ++sink->warnings; break;
  case llvm::SourceMgr::DK_Note:    kind = "note";    break;
  case llvm::SourceMgr::DK_Remark:  kind = "remark";  break;
  }
  llvm::outs() << diag.getFilename() << ":" << diag.getLineNo() << ":"
               << diag.getColumnNo() << ": " << kind << ": "
               << diag.getMessage() << "\n";
}
} // namespace

int main(int argc, char **argv) {
  if (argc < 2) {
    llvm::errs() << "usage: syntax_probe <file.mojo> [-I dir]...\n";
    return 2;
  }
  std::vector<std::string> includeDirs;
  for (int i = 2; i + 1 < argc; ++i)
    if (llvm::StringRef(argv[i]) == "-I")
      includeDirs.push_back(argv[++i]);

  // Holds init and runtime state the parser depends on. getOrCreateContext,
  // not createContext: the latter aborts if a context already exists, which an
  // editor creating one per session would hit.
  auto contextOr = M::Init::getOrCreateContext("syntax_probe");
  if (contextOr.isError()) {
    llvm::errs() << "cannot create the Mojo context\n";
    return 1;
  }

  auto buffer = llvm::MemoryBuffer::getFile(argv[1]);
  if (!buffer) {
    llvm::errs() << "cannot read " << argv[1] << ": "
                 << buffer.getError().message() << "\n";
    return 1;
  }

  DiagSink sink;
  llvm::SourceMgr sourceMgr;
  sourceMgr.setIncludeDirs(includeDirs);
  sourceMgr.setDiagHandler(onDiagnostic, &sink);
  unsigned fileId =
      sourceMgr.AddNewSourceBuffer(std::move(*buffer), llvm::SMLoc());

  mlir::MLIRContext mlirContext;
  M::KGEN::CompilationOptions options;
  M::KGEN::LIT::ParserConfig parserConfig(&mlirContext, options);

  {
    M::MojoParserContext parser(sourceMgr, parserConfig);
    M::MojoASTDeclRef module = parser.parseFileForLSP(fileId);
    llvm::outs() << "parsed: " << (module ? "yes" : "no")
                 << ", errors: " << sink.errors
                 << ", warnings: " << sink.warnings << "\n";
  }
  // Handler cleared before the sink it points at goes out of scope.
  sourceMgr.setDiagHandler(nullptr, nullptr);
  return sink.errors ? 1 : 0;
}
