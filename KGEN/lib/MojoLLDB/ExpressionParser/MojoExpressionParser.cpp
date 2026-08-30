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

#include "MojoExpressionParser.h"
#include "../Logging/MojoExpressionLogger.h"
#include "../TypeSystem/MojoTypeSystem.h"
#include "../Utils/Binary.h"
#include "JITExecutionUnit.h"
#include "Logging.h"
#include "MojoDiagnostic.h"
#include "MojoExpressionVariable.h"

#include "KGEN/Compiler/KGENCompiler.h"
#include "KGEN/Compiler/ObjectCompiler.h"
#include "KGEN/KGENDialect/KGENOps.h"
#include "KGEN/LITDialect/LITOps.h"
#include "KGEN/MojoParser/EntryPoint.h"
#include "KGEN/MojoTooling/ParserDriver.h"
#include "KGEN/MojoTooling/PublicASTDecl.h"
#include "KGEN/POPDialect/POPOps.h"
#include "KGEN/Support/Constants.h"
#include "KGEN/ToolCommon/KGENPasses.h"
#include "KGEN/TransformUtils/SlicingUtils.h"
#include "lldb/Expression/DiagnosticManager.h"
#include "lldb/Expression/IRExecutionUnit.h"
#include "lldb/Expression/Materializer.h"
#include "lldb/Target/ExecutionContextScope.h"
#include "lldb/Target/StackFrame.h"
#include "lldb/Symbol/Type.h"
#include "lldb/Symbol/Variable.h"
#include "lldb/Symbol/VariableList.h"
#include "lldb/Target/Target.h"
#include "lldb/Utility/LLDBLog.h"
#include "mlir/IR/IRMapping.h"
#include "mlir/IR/ImplicitLocOpBuilder.h"
#include "mlir/IR/Verifier.h"
#include "mlir/Pass/PassManager.h"
#include "llvm/ADT/ScopeExit.h"
#include "llvm/Object/Archive.h"
#include "llvm/Support/Process.h"
#include "llvm/Target/TargetMachine.h"

using namespace M;
using namespace M::KGEN;
using namespace M::KGEN::Mojo;
using namespace lldb_private;

//===----------------------------------------------------------------------===//
// MojoExpressionParser::Impl
//===----------------------------------------------------------------------===//

struct MojoExpressionParser::Impl {
  Impl(ExecutionContextScope *exeScope, MojoUserExpression &expr,
       const EvaluateExpressionOptions &options);

  /// The expression being parsed.
  MojoUserExpression &expr;

  /// The scope the expression is evaluated in -- the stopped FRAME, when
  /// there is one. Kept rather than only its target, because the frame is
  /// what holds the local variables an expression wants to name.
  ExecutionContextScope *exeScope = nullptr;

  /// The type system associated with the evaluation of the current expression.
  MojoTypeSystem *typeSystem = nullptr;

  /// The compilation options to use when compiling.
  const KGEN::CompilationOptions *compilationOptions = nullptr;

  /// The ObjectCompiler instance to use when parsing.
  std::unique_ptr<KGEN::ObjectCompiler> objCompiler;

  /// The parsed Mojo module.
  OwningOpRef<ModuleOp> mlirModule;

  /// The compiled object.
  OwningBinary<llvm::object::Binary> object;

  /// The options to use when evaluating the expression.
  EvaluateExpressionOptions options;

  /// A set of new persistent variables to be added to the persistent expression
  /// state if compilation of the expression succeeds.
  SmallVector<std::pair<StringRef, mlir::Type>> newPersistentVariables;

  /// The target on which expressions will be evaluated.
  lldb::TargetSP target;

  /// The expression logger for the current target.
  MojoExpressionLogger *expressionLogger;
};

MojoExpressionParser::Impl::Impl(ExecutionContextScope *exeScope,
                                 MojoUserExpression &expr,
                                 const EvaluateExpressionOptions &options)
    : expr(expr), exeScope(exeScope), options(options) {
  // Bail out if we don't have a valid execution context.
  target = exeScope ? exeScope->CalculateTarget() : nullptr;
  if (!target)
    return;

  expressionLogger = &MojoExpressionLogger::getLoggerForTarget(*target);

  // Grab the type system from the target, bailing out if we can't.
  auto typeSystemOr =
      target->GetScratchTypeSystemForLanguage(lldb::eLanguageTypeMojo);
  if (!typeSystemOr) {
    llvm::consumeError(typeSystemOr.takeError());
    return;
  }
  typeSystem = llvm::cast<MojoTypeSystem>(typeSystemOr.get().get());
  compilationOptions = &typeSystem->getParserContext().getCompilationOptions();
  MLIRContext *ctx = typeSystem->getMLIRContext();

  // TODO(#33931) HACK, HACK, HACK!!!
  // To make CompilationOptions being properly passed to KGEN compiler
  // without breaking existing tests.
  // TODO(MOTO-247) workaround to LLVM Module splitting which works
  // for ORC JIT but not always for MCJIT.
  // Disable splitting and parallelize LLC pipeline
  // (which is based on splitting) for REPL.
  KGEN::CompilationOptions hackCompilationOptions = *compilationOptions;
  hackCompilationOptions.enableLLVMPerFunctionSplitting = false;
  hackCompilationOptions.enableParallelLLC = false;

  PassManagerConfigOptions pmOptions;
  pmOptions.operationName = ModuleOp::getOperationName();

  // Create the compiler instance.
  auto compilerOr =
      ObjectCompiler::create(kMojoCacheBaseDirName, hackCompilationOptions,
                             /*isJIT=*/true, *ctx, pmOptions);

  if (failed(compilerOr))
    return;

  objCompiler = std::move(*compilerOr);
}

//===----------------------------------------------------------------------===//
// Diagnostics
//===----------------------------------------------------------------------===//

namespace {
/// This class defines a simple raw ostream that can be used to emit colors when
/// processing diagnostic messages.
struct DiagnosticStream : public llvm::raw_string_ostream {
  DiagnosticStream(std::string &msg, bool supportsColors)
      : llvm::raw_string_ostream(msg) {
    enable_colors(supportsColors);
  }

  bool is_displayed() const override { return colors_enabled(); }
  bool has_colors() const override { return colors_enabled(); }
};
} // namespace

/// Format the given diagnostic into a string.
static std::string formatSMDiagnostic(const llvm::SMDiagnostic &diag,
                                      bool showColors) {
  std::string msg;
  DiagnosticStream msgOS(msg, showColors);

  // Set the default colors for the diagnostic printing. This ensures we use the
  // correct corresponding color for the diagnostic type.
  llvm::HighlightColor color(llvm::HighlightColor::Error);
  switch (diag.getKind()) {
  case llvm::SourceMgr::DK_Error:
    color = llvm::HighlightColor::Error;
    break;
  case llvm::SourceMgr::DK_Warning:
    color = llvm::HighlightColor::Warning;
    break;
  case llvm::SourceMgr::DK_Note:
    color = llvm::HighlightColor::Note;
    break;
  case llvm::SourceMgr::DK_Remark:
    color = llvm::HighlightColor::Remark;
    break;
  }
  llvm::WithColor colorOS(msgOS, color);

  diag.print("", msgOS, showColors, /*ShowKindLabel=*/false);
  return msg;
}

//===----------------------------------------------------------------------===//
// LLDBMojoREPLListener
//===----------------------------------------------------------------------===//

namespace {
/// This class implements a parser listener that communicates between the Mojo
/// parser and the repl.
class LLDBMojoREPLListener : public MojoParserREPLListener {
public:
  LLDBMojoREPLListener(
      StringRef currentModuleName, MojoUserExpression &expr,
      DiagnosticManager &diagnosticManager,
      const EvaluateExpressionOptions &options,
      SmallVectorImpl<std::pair<StringRef, mlir::Type>> &newPersistentVariables,
      MojoExpressionLogger &expressionLogger)
      : currentModuleName(currentModuleName), expr(expr),
        diagnosticManager(diagnosticManager), options(options),
        newPersistentVariables(newPersistentVariables),
        expressionLogger(expressionLogger) {}
  ~LLDBMojoREPLListener() override = default;

  //===--------------------------------------------------------------------===//
  // Notifications

  void notifyWrappedExpr(StringRef wrappedExpr) override {
    expressionLogger.debugLog("Parsing the following code:\n{0}",
                              wrappedExpr.data());
  }

  void notifyFixedExpr(StringRef fixedExpr) override {
    expr.setFixedText(fixedExpr);
  }

  void notifyDiagnostics(ArrayRef<llvm::SMDiagnostic> diagnostics) override {
    expressionLogger.debugLog("Found {0} diagnostic{1}\n", diagnostics.size(),
                              diagnostics.size() == 1 ? "" : "s");

    for (const llvm::SMDiagnostic &diag : diagnostics) {
      expressionLogger.debugLog("Diagnostic with fixits: {0}, message:\n{1}",
                                diag.getFixIts().size(), diag.getMessage());

      // If this is a warning or remark from a previous module, ignore it. This
      // removes problems with emitting multiple diagnostics for the same
      // expression.
      llvm::SourceMgr::DiagKind diagKind = diag.getKind();
      if (diagKind == llvm::SourceMgr::DK_Warning ||
          diagKind == llvm::SourceMgr::DK_Remark) {
        if (MojoPersistentExpressionState::isExpressionModuleName(
                diag.getFilename()) &&
            !diag.getFilename().ends_with(currentModuleName)) {
          lastDiagnosticIgnored = true;
          continue;
        }
      }

      // If this is a note and the previous diagnostic was ignored, ignore this
      // as well.
      if (diagKind == llvm::SourceMgr::DK_Note && lastDiagnosticIgnored)
        continue;
      lastDiagnosticIgnored = false;

      // Turn the diagnostic severity into LLDB's severity.
      lldb::Severity severity;
      switch (diagKind) {
      case llvm::SourceMgr::DK_Error:
        severity = lldb::eSeverityError;
        break;
      case llvm::SourceMgr::DK_Warning:
        severity = lldb::eSeverityWarning;
        break;
      case llvm::SourceMgr::DK_Remark:
        LLVM_FALLTHROUGH;
      case llvm::SourceMgr::DK_Note:
        severity = lldb::eSeverityInfo;
        break;
      }

      std::string msg = formatSMDiagnostic(diag, options.GetColorizeErrors());
      diagnosticManager.AddDiagnostic(std::make_unique<MojoDiagnostic>(
          msg, severity, !diag.getFixIts().empty()));
    }
  }

  //===--------------------------------------------------------------------===//
  // Queries

  bool shouldPersistVariable(StringRef name, mlir::Type type) override {
    auto canPersist = [&] {
      // We always persist internal repl variables used for execution state.
      if (MojoParserContext::isHiddenPersistentVariable(name))
        return true;
      // Check if we were requested not to persist anything.
      if (options.GetSuppressPersistentResult())
        return false;
      // Only consider variables that were written by users, not those
      // generated by LLDB, which start with __lldb.
      if (name.starts_with("__lldb"))
        return false;
      // TODO: For now, we only persist variables in REPL mode. We should
      // define a policy for non-REPL mode (e.g. clang/swift using leading
      // $ for variable names to indicate persistence).
      if (!options.GetREPLEnabled())
        return false;
      return true;
    };

    if (canPersist()) {
      newPersistentVariables.emplace_back(name, type);
      return true;
    }
    return false;
  }

private:
  StringRef currentModuleName;
  MojoUserExpression &expr;
  DiagnosticManager &diagnosticManager;
  const EvaluateExpressionOptions &options;
  SmallVectorImpl<std::pair<StringRef, mlir::Type>> &newPersistentVariables;
  MojoExpressionLogger &expressionLogger;

  /// A flag indicating if that the last processed diagnostic was ignored.
  bool lastDiagnosticIgnored = false;
};
} // namespace

//===----------------------------------------------------------------------===//
// MojoExpressionParser
//===----------------------------------------------------------------------===//

MojoExpressionParser::MojoExpressionParser(
    ExecutionContextScope *exeScope, MojoUserExpression &expr,
    const EvaluateExpressionOptions &options)
    : impl(std::make_unique<Impl>(exeScope, expr, options)) {}

MojoExpressionParser::~MojoExpressionParser() = default;

/// The frame's own variables, as (name, type) pairs the REPL wrapper can
/// take as arguments.
///
/// This is what makes `total + 41` mean something at a breakpoint. The REPL
/// wrapper has always been able to receive variables -- that is how a
/// notebook's `a` survives from one cell to the next -- but the only source
/// ever wired to it was the persistent-variable state, which a debugger
/// stopped in someone else's function has nothing in. The frame has them all
/// along; nobody was asking.
///
/// One real condition, and one thing that is NOT a check although an earlier
/// version of this comment claimed it was.
///
/// The condition: the variable's type must be a Mojo type. A Mojo frame can
/// hold a C global whose type came from Clang, and handing that opaque
/// pointer to the Mojo parser is a crash rather than a diagnostic. The test
/// is the type system's KIND, not its identity -- a variable's type belongs
/// to the type system of the MODULE whose DWARF declared it, while the
/// expression compiles in the target's scratch instance, and those are
/// legitimately different objects. One shared MLIR context makes that safe.
///
/// The non-check: `Materializer::AddVariable` validates nothing. It inserts
/// an entity and returns its struct offset, and never touches the `Status`
/// it is handed -- a variable with no location at this PC fails LATER,
/// during materialization. So its success proves nothing about readability
/// and this loop must not be read as a filter. The honest preflight is
/// `GetValueObjectForFrameVariable(..., eNoDynamicValues)` and its error;
/// that is not done yet.
///
/// Shadowing, stated as it BEHAVES rather than as it should: persistent
/// variables are collected first and seed `alreadyPresent`, so a persistent
/// variable of the same name currently wins. That is backwards -- the frame
/// is what the user is looking at -- and it is a known wrong behaviour to
/// fix deliberately, with a test, rather than by reordering two loops and
/// hoping.
static void collectFrameVariables(
    ExecutionContextScope *exeScope, Materializer *materializer,
    SmallVectorImpl<std::pair<StringRef, mlir::Type>> &variables,
    MojoExpressionLogger &logger) {
  if (!materializer)
    return;
  auto *frame = exeScope ? exeScope->CalculateStackFrame().get() : nullptr;
  if (!frame)
    return;

  lldb::VariableListSP frameVars = frame->GetInScopeVariableList(
      /*get_file_globals=*/false);
  if (!frameVars)
    return;

  DenseSet<StringRef> alreadyPresent;
  for (auto &[name, type] : variables)
    alreadyPresent.insert(name);

  for (size_t i = 0, e = frameVars->GetSize(); i != e; ++i) {
    lldb::VariableSP var = frameVars->GetVariableAtIndex(i);
    if (!var)
      continue;
    llvm::StringRef name = var->GetName().GetStringRef();
    if (name.empty() || !alreadyPresent.insert(name).second)
      continue;

    // Ours, or another language's? A CompilerType carries the type system
    // that made it; anything but ours is not a Mojo type and cannot be
    // named in a Mojo expression.
    lldb_private::CompilerType compilerType = var->GetType()
                                                  ? var->GetType()->GetFullCompilerType()
                                                  : lldb_private::CompilerType();
    if (!compilerType)
      continue;
    // Ours, or another language's? The test is the type system's KIND, not
    // its identity: a variable's type is created by the type system of the
    // MODULE whose DWARF declared it, while the expression is compiled by
    // the target's scratch instance, and those are legitimately different
    // objects. Comparing pointers rejected every frame variable in the
    // program. What must hold is that the type is a Mojo type at all --
    // a C global whose type came from Clang cannot be named in a Mojo
    // expression, and handing that opaque pointer to the parser is a crash
    // rather than a diagnostic.
    //
    // Sharing one MLIR context across instances is what makes this safe,
    // and it is not incidental: `MojoTypeSystem::Impl` takes the context
    // from `getOrCreateGlobalContext()`, so every instance in the process
    // interns types in the same place and a type from one is a valid type
    // in another.
    if (!compilerType.GetTypeSystem().isa_and_nonnull<MojoTypeSystem>())
      continue;

    mlir::Type mojoType =
        mlir::Type::getFromOpaquePointer(compilerType.GetOpaqueQualType());
    if (!mojoType)
      continue;

    // Materializable? If lldb cannot arrange to move the value in and out,
    // the expression must not be able to mention it -- an unmaterialized
    // argument is a wild pointer at JIT time.
    Status err;
    materializer->AddVariable(var, err);
    if (err.Fail()) {
      logger.debugLog("frame variable '{0}' is not materializable: {1}", name,
                      err.AsCString());
      alreadyPresent.erase(name);
      continue;
    }
    variables.emplace_back(name, mojoType);
  }
}

M::LogicalResult
MojoExpressionParser::parse(MojoPersistentExpressionState &state,
                            DiagnosticManager &diagnosticManager) {
  if (!impl->objCompiler) {
    impl->expressionLogger->errorLog("No ObjectCompiler");
    return failure();
  }

  MojoParserContext &parserContext = impl->typeSystem->getParserContext();
  MLIRContext *ctx = impl->typeSystem->getMLIRContext();
  llvm::SourceMgr &sourceMgr = parserContext.getSourceMgr();

  // Register the source manager diagnostic handler so we get all the MLIR
  // diagnostics through the handler we already have and so it's all forwarded
  // to the LLDB streams. If the handler can't use the source manager for an
  // error, it'll print to errStream, which we will flush if it's non-empty on
  // scope exit.
  std::string errs;
  llvm::raw_string_ostream errStream(errs);
  mlir::SourceMgrDiagnosticHandler handler(sourceMgr, ctx, errStream);

  // On scope exit, if we've printed any errors make sure to log them.
  auto printOnError = llvm::scope_exit([&]() {
    if (errs.empty())
      return;
    impl->expressionLogger->errorLog("{0}", errs);
  });

  // Collect the current persistent variables, then the stopped frame's own.
  SmallVector<std::pair<StringRef, mlir::Type>> variables;
  state.collectPersistentVariables(variables);
  // Frame locals, behind a switch until they can EXECUTE.
  //
  // Collection works: set MOJO_LLDB_FRAME_LOCALS=1 and `total + 41` at a
  // breakpoint stops saying "use of unknown declaration" -- the name
  // resolves, because the frame's variables reach the REPL wrapper as
  // arguments.
  //
  // What does not work is READING the value, and the shapes are specific:
  //
  //     persistent variable:  context -> reference cell -> T
  //     frame local:          context -> T
  //
  // A persistent variable has an extra allocated reference cell, so the
  // wrapper declares `Pointer[Pointer[T]]` and dereferences twice. What
  // `AddVariable` puts in the context is ONE pointer-sized slot holding the
  // frame variable's address -- so a frame local needs `Pointer[T]` and one
  // dereference. A `(name, type)` pair cannot carry that distinction, which
  // is why the wrapper generator cannot tell them apart today.
  //
  // Behind that sits an ordering bug that appears once both kinds coexist:
  // the wrapper emits persistent fields first and frame locals after, while
  // the materializer receives frame locals HERE (during parsing) and
  // persistent entities later, in prepareForExecution. Two independently
  // ordered lists -- and the offset `AddVariable` returns is discarded
  // rather than checked against the field it is meant to match.
  //
  // The fix for both is one explicit contract instead of two implicit ones:
  // an ordered list of bindings, each carrying its capture kind
  //
  //     struct ExpressionBinding {
  //       StringRef name;
  //       mlir::Type type;
  //       CaptureKind kind;          // PersistentIndirect | FrameAddress
  //       lldb::VariableSP frameVariable;
  //     };
  //
  // used to generate the field AND its dereference depth, to register
  // materializer entities in exactly that order after compilation, and to
  // assert each returned offset equals the field the wrapper expects.
  //
  // Default off because half of it is worse than none: with collection on,
  // an expression that used to fail with "unknown declaration" now fails
  // without a diagnostic at all, and an unreadable error is a worse thing
  // to ship than a missing feature.
  if (const char *on = ::getenv("MOJO_LLDB_FRAME_LOCALS"))
    if (StringRef(on) == "1")
      collectFrameVariables(impl->exeScope, impl->expr.GetMaterializer(),
                            variables, *impl->expressionLogger);

  // Parse the expression.
  auto [expressionId, exprModuleName] = state.getNextExpressionModuleName();
  LLDBMojoREPLListener listener(exprModuleName, impl->expr, diagnosticManager,
                                impl->options, impl->newPersistentVariables,
                                *impl->expressionLogger);
  // Create a function name for the expression. This string must be a valid Mojo
  // identifier.
  std::string exprFnName = ("__lldb_expr__" + Twine(expressionId)).str();
  int exprFileId = sourceMgr.AddNewSourceBuffer(
      llvm::MemoryBuffer::getMemBufferCopy(impl->expr.Text(), exprModuleName),
      llvm::SMLoc());
  impl->expr.setFunctionName(exprFnName);
  MojoParserContext::ParsedREPLExpr result = parserContext.parseREPLExpression(
      listener, exprFileId, exprFnName, variables);

  // If the parser supplied a fixed expression, abort processing and use that
  // expression instead.
  if (!impl->expr.GetFixedText().empty() &&
      impl->options.GetAutoApplyFixIts()) {
    impl->expressionLogger->debugLog(
        "Rewrote the input, next parse will be the fixed code:\n{0}",
        impl->expr.GetFixedText());

    // If we have a fixed expression string, we're going to fail here to let
    // LLDB retry execution with the fixed expression. Before then, we need to
    // emit all of the fixed diagnostics that were collected, given that these
    // won't be shown on the next parse.
    // Same rule as MojoUserExpression::Parse: hand the diagnostics over only
    // when somebody is listening. Jupyter listens and renders them itself,
    // so clearing avoids a double report; lldb and lldb-dap do not, and
    // clearing there turned a fix-it into "expression failed to parse (no
    // further compiler diagnostics)" -- a message that names nothing.
    if (impl->expressionLogger->EventTypeHasListeners(
            MojoExpressionLogger::eBroadcastUserMessage)) {
      auto filterFn = [](MojoDiagnostic &diag) { return diag.hadFixits(); };
      impl->expressionLogger->broadcastDiagnostics(diagnosticManager, filterFn);
      diagnosticManager.Clear();
    }

    // If the parser was actually successful, make sure to reset it so that we
    // don't include the un-fixed module in the REPL history.
    if (result.isValid())
      parserContext.removeLastREPLExpression();
    return failure();
  }

  if (!result.isValid()) {
    // Do not fail mutely. A fix-it is the common reason to land here -- the
    // parser rewrites a bare `total + 41` into `_ = total + 41`, because the
    // wrapper's body takes statements -- and a client that does not re-run
    // fixed text (lldb-dap does not; `target.auto-apply-fixits` governs the
    // CLI and is off there) would otherwise report "expression failed to
    // parse (no further compiler diagnostics)". That sentence names neither
    // the problem nor the remedy when both are in hand.
    if (diagnosticManager.Diagnostics().empty() &&
        !impl->expr.GetFixedText().empty())
      diagnosticManager.PutString(
          lldb::eSeverityError,
          ("this expression has to be written as a statement: " +
           impl->expr.GetFixedText().str())
              .c_str());
    return failure();
  }
  impl->expressionLogger->debugLog("Parsed module successfully");

  // Setup a diagnostic handler to process diagnostics emitted during lowering.
  struct MLIRDiagnosticHandlerContext {
    LLDBMojoREPLListener &listener;
    MojoParserContext &parserContext;
  };
  MLIRDiagnosticHandlerContext handlerContext{listener, parserContext};
  sourceMgr.setDiagHandler(
      [](const llvm::SMDiagnostic &diag, void *context) {
        auto *ctx = static_cast<MLIRDiagnosticHandlerContext *>(context);
        ctx->listener.notifyDiagnostics(
            ctx->parserContext.getREPLLocMapper().mapDiagnostic(diag));
      },
      &handlerContext);

  // Functor containing various cleanup performed in the case of an error.
  auto returnErrorCleanup = [&] {
    // If we encounter an error anywhere during compilation, make sure the
    // parser doesn't include this expression in the REPL history.
    parserContext.removeLastREPLExpression();
    return failure();
  };

  // Create a clone of the parser module so that we can compile it without
  // thrashing on the current parser state.
  auto exprFn = cast<LIT::FnOp>(result.exprFnDecl.getIfOperation());
  exprFn.setLinkageNameAttr(
      LinkageNameAttr::get(exprFn->getContext(), exprFnName));
  mlir::IRMapping mapping;
  OwningOpRef<ModuleOp> module =
      KGEN::LIT::cloneDeclModuleForCompilation(*result.moduleDecl, mapping);
#ifndef MODULAR_PRODUCTION
  if (failed(mlir::verify(*module)))
    return returnErrorCleanup();
#endif // MODULAR_PRODUCTION

  // Set the environment (defines) for the module.
  extendWithModularEnvAttr(*module, nullptr);

  // Ensure the expression function in the cloned module gets c-exported.
  auto clonedExprFn = cast<LIT::FnOp>(mapping.lookup(&*exprFn));
  clonedExprFn.setExported();
  // Set the C ABI effect
  auto sigGen = clonedExprFn.getFuncTypeGenerator();
  auto body = sigGen.getBody();
  auto newBody = body.getWithFnEffects(body.getFnEffects().setCABI(true));
  clonedExprFn.setFuncTypeGenerator(LIT::FnTypeGeneratorType::get(
      sigGen.getInputParamTypes(), newBody, sigGen.getParamListAttrs()));

  // Log the pre-elaboration module.
  Log *logChannel = GetLog(LLDBLog::Expressions);
  bool isVerboseLoggingEnabled = logChannel && logChannel->GetVerbose();

  std::string preElaborationModuleLog;
  llvm::raw_string_ostream preElaborationLogStream(preElaborationModuleLog);

  PassManagerConfigOptions pmOptions;
  if (isVerboseLoggingEnabled) {
    pmOptions.irPrintingOptions.enable = true;
    pmOptions.irPrintingOptions.passName = "ElaborateGenerators";
    pmOptions.irPrintingOptions.out = &preElaborationLogStream;
  }
  pmOptions.operationName = ModuleOp::getOperationName();

  KGEN::KGENCompiler kgenCompiler(*impl->typeSystem->getMLIRContext(),
                                  *impl->compilationOptions, pmOptions);

  //// Get the target info to use for compilation.
  TargetInfoAttr targetInfo = impl->typeSystem->GetTargetInfo();
  if (!targetInfo)
    return failure();

  // Run the elaboration pipeline.
  ErrorOrSuccess compilerResult = kgenCompiler.runKGENPipeline(
      *module, targetInfo, impl->objCompiler->getTransformCache().copy(),
      AsyncValueRef<Chain>::createReady(impl->typeSystem->getCPUDevice()));
  if (compilerResult.isError())
    return returnErrorCleanup();

  if (isVerboseLoggingEnabled) {
    impl->expressionLogger->dumpIR("Pre-elaboration module:\n{0}",
                                   preElaborationModuleLog);
    impl->expressionLogger->dumpIR("Elaborated module:\n{0}", *module);
  }

  // Compile the module to a standalone archive.
  SymbolTable symbolTable(*module);
  ExportMap exportedSymbols;
  exportedSymbols.insert({StringAttr::get(module->getContext(), exprFnName),
                          ExportKind::Exported});
  OwningOpRef<ModuleOp> sliceModule =
      produceStandaloneModule(symbolTable, exportedSymbols);
  auto bufferOr = impl->objCompiler->emitArchive(std::move(sliceModule));
  if (bufferOr.isError()) {
    impl->expressionLogger->errorLog(
        "Failed to produce standalone archive: {0}", bufferOr.getError());
    return returnErrorCleanup();
  }

  auto objectOr = toModularErrorOr(
      llvm::object::createBinary((*bufferOr)->getMemBufferRef()));

  if (objectOr.isError()) {
    impl->expressionLogger->errorLog("Failed to create the binary object: {0}",
                                     objectOr.getError());
    return returnErrorCleanup();
  }

  impl->mlirModule = std::move(module);
  impl->object = OwningBinary<llvm::object::Binary>(std::move(*objectOr),
                                                    std::move(*bufferOr));

  return success();
}

Status MojoExpressionParser::prepareForExecution(
    lldb::addr_t &funcAddr, lldb::addr_t &funcEnd,
    std::shared_ptr<JITExecutionUnit> &executionUnit, ExecutionContext &exeCtx,
    ExecutionPolicy executionPolicy, bool keepResultInMemory) {
  // Grab the module and standalone archive built during the parse phase.
  // NOTE: impl->mlirModule and impl->archive will be nullptr after this!
  // Luckily, expressions are generally destroyed shortly after this, so we
  // don't have to be too concerned - just something to be aware of.
  OwningOpRef<ModuleOp> mlirModule = std::move(impl->mlirModule);
  if (!mlirModule)
    return Status::FromErrorString("Can't prepare a NULL module for execution");

  // Retrieve an appropriate symbol context.
  SymbolContext sc;
  if (const lldb::StackFrameSP &frame = exeCtx.GetFrameSP())
    sc = frame->GetSymbolContext(lldb::eSymbolContextEverything);
  else if (const lldb::TargetSP &target = exeCtx.GetTargetSP())
    sc.target_sp = target;

  // Extract the target features.
  SmallVector<StringRef> splitFeatures;
  StringRef(impl->compilationOptions->targetFeatures).split(splitFeatures, ",");
  std::vector<std::string> features(splitFeatures.begin(), splitFeatures.end());

  // Build the IR execution unit responsible for executing the generated IR.
  ConstString functionName(impl->expr.FunctionName());
  SymbolTable symbolTable(*mlirModule);
  ExportMap exportedSymbols;
  exportedSymbols.insert(
      {StringAttr::get(mlirModule->getContext(), functionName.GetStringRef()),
       ExportKind::Exported});
  executionUnit = std::make_shared<JITExecutionUnit>(
      symbolTable, exportedSymbols, std::move(impl->object), functionName,
      exeCtx.GetTargetSP(), sc, features);

  // Extract the function information for the expression entry point.
  Status error = executionUnit->getRunnableInfo(funcAddr, funcEnd);
  if (error.Fail() || !keepResultInMemory)
    return error;

  // Compute the target info to use for the persistent variable state.
  lldb_private::Process *process = exeCtx.GetProcessPtr();
  lldb::ByteOrder byteOrder = process->GetByteOrder();
  size_t addressByteSize = process->GetAddressByteSize();

  // If we successfully compiled the expression, we can now comfortably register
  // the persistent state variables.
  auto *persistentState = static_cast<MojoPersistentExpressionState *>(
      impl->typeSystem->GetPersistentExpressionState());

  // Register the current persistent variables with the materializer.
  DenseSet<ConstString> persistentVariableNames;
  for (int i : llvm::reverse(llvm::seq<int>(0, persistentState->GetSize()))) {
    lldb::ExpressionVariableSP var = persistentState->GetVariableAtIndex(i);
    assert(var && "expected valid variable in persistent state");

    // Skip variables that got redefined.
    if (!persistentVariableNames.insert(var->GetName()).second)
      continue;

    // Try adding the variable to the expression materializer.
    impl->expr.GetMaterializer()->AddPersistentVariable(var, nullptr, error);
    if (error.Fail())
      return error;
  }

  // Register the newly created persistent variables.
  std::vector<lldb::ExpressionVariableSP> persistentVariables;
  for (auto [name, mlirType] : impl->newPersistentVariables) {
    // All persistent variables in the REPL are references, so wrap them in a
    // reference type.
    auto ptr = LIT::REPLResultRefType::get(mlirType);
    CompilerType lldbType(impl->typeSystem->weak_from_this(),
                          const_cast<void *>(ptr.getAsOpaquePointer()));
    lldb::ExpressionVariableSP var = persistentState->CreatePersistentVariable(
        exeCtx.GetBestExecutionContextScope(), ConstString(name), lldbType,
        byteOrder, addressByteSize);
    if (!var) {
      error = Status::FromErrorString("failed to create persistent variable");
      return error;
    }

    // Mark the variable as persistent, and notify LLDB that it needs to be
    // allocated.
    var->m_frozen_sp->SetHasCompleteType();
    var->m_flags |= ExpressionVariable::EVKeepInTarget;
    var->m_flags |= ExpressionVariable::EVIsLLDBAllocated;
    var->m_flags |= ExpressionVariable::EVNeedsAllocation;

    // Adding the variable to the expression materializer.
    impl->expr.GetMaterializer()->AddPersistentVariable(var, nullptr, error);
    if (error.Fail())
      return error;
    persistentVariables.emplace_back(std::move(var));
  }

  // If a valid execution unit was produced and there is more than one external
  // function in the execution unit, it needs to keep living even if it's not
  // top level, because the result could refer to that function, register it if
  // necessary.
  //
  // In REPL mode, always persist the execution unit to keep JIT-section memory
  // alive. String literals constructed from `StringLiteral` store a raw pointer
  // into the JIT data section (via `pop.string.address`) without heap-copying,
  // so freeing the execution unit's JIT sections would leave persisted String
  // variables with dangling data pointers.
  std::shared_ptr<JITExecutionUnit> persistedExecutionUnit;
  if (executionUnit &&
      (impl->options.GetExecutionPolicy() == eExecutionPolicyTopLevel ||
       impl->options.GetREPLEnabled() ||
       executionUnit->getJittedFunctions().size() > 1)) {
    persistedExecutionUnit = executionUnit;
  }

  // Register the persisted state for this execution.
  persistentState->registerExpressionInstance(std::move(persistedExecutionUnit),
                                              std::move(persistentVariables),
                                              impl->expr.getPythonModuleName());
  return error;
}
