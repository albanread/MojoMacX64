#!/bin/bash
set -euxo pipefail
D=/Volumes/S/toolchain-build
mkdir -p $D && cd $D
[ -f llvm-src.tar.gz ] || curl -fL -o llvm-src.tar.gz https://github.com/llvm/llvm-project/archive/refs/tags/llvmorg-22.1.4.tar.gz
[ -d llvm-project-llvmorg-22.1.4 ] || tar -xzf llvm-src.tar.gz
mkdir -p build && cd build
cmake -G Ninja ../llvm-project-llvmorg-22.1.4/llvm \
  -DCMAKE_BUILD_TYPE=Release -DLLVM_ENABLE_ASSERTIONS=OFF \
  -DLLVM_ENABLE_PROJECTS="clang;lld" \
  -DLLVM_ENABLE_RUNTIMES="compiler-rt" \
  -DLLVM_TARGETS_TO_BUILD=X86 \
  -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
  -DCOMPILER_RT_ENABLE_IOS=OFF -DCOMPILER_RT_ENABLE_WATCHOS=OFF -DCOMPILER_RT_ENABLE_TVOS=OFF \
  -DDARWIN_osx_ARCHS=x86_64 \
  -DLLVM_INSTALL_UTILS=ON \
  -DCMAKE_INSTALL_PREFIX=$D/pkg
ninja -j24
ninja install
cd $D && XZ_OPT=-T0 tar -cJf llvm-macos-x86_64-22.1.4.tar.xz -C pkg .
shasum -a 256 llvm-macos-x86_64-22.1.4.tar.xz > llvm-macos-x86_64-22.1.4.tar.xz.sha256
echo TOOLCHAIN-DONE
