#!/usr/bin/env bash
# Build a complete CocoaMojo release from a clean checkout.
#
#   ./tools/release.sh              build, assemble and verify
#   ./tools/release.sh --no-verify  skip the verification pass
#
# Three steps: bazel builds the compiler and its shared libraries, make-dist.sh
# assembles a distribution that does not need bazel again, and check-dist.sh
# proves the result works. See RELEASE.md for why each flag is there, and
# IDE-EMBEDDING.md for what the shared libraries are for.
set -euo pipefail
cd "$(dirname "$0")/.."

verify=1
[ "${1:-}" = "--no-verify" ] && verify=0

# The SDK database is checked here rather than left to make-dist's warning,
# which scrolls past in a long build log. Without it the compiler builds fine
# and then cannot elaborate a single Cocoa program, which is a confusing way to
# discover a missing file.
KB="${COCOAKB:-/Volumes/S/CocoaBaseMCP/cocoa.sqlite}"
if [ ! -f "$KB" ]; then
  echo "no cocoa.sqlite at $KB"
  echo
  echo "It is generated, not checked in. Build it with:"
  echo "  python3 /Volumes/S/CocoaBaseMCP/build.py        # ~12s"
  echo
  echo "or point COCOAKB at an existing one."
  exit 1
fi

echo "== 1/3  building (this is the long one) =="
# Everything make-dist.sh needs. The compiler target alone produces none of the
# shared libraries and not CompilerRT.
./bazelw build --config=build-mojo --config=release \
    //KGEN/tools/mojo:mojo \
    //KGEN:CompilerRT \
    //KGEN:MojoCompilerShared \
    //KGEN/tools/mojo-lsp-server:mojo-lsp-server \
    //KGEN:MojoLLDB \
    @llvm-project//lldb:lldb @llvm-project//lldb:lldb-dap \
    @llvm-project//lldb:lldb-argdumper \
    //bazel/llvm-shared:LLVM \
    //bazel/mlir-shared:MLIR

echo
echo "== 2/3  assembling dist/MojoMacX64 =="
COCOAKB="$KB" ./tools/make-dist.sh

if [ "$verify" -eq 1 ]; then
  echo
  echo "== 3/3  verifying =="
  MODULAR_MOJO_MAX_COCOAKB_PATH="$KB" ./tools/check-dist.sh
else
  echo
  echo "Verify with:  ./tools/check-dist.sh"
fi
