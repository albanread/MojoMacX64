#!/bin/sh
# S1 runner: builds and runs the probe; adds the offline-metallib leg when the
# Metal toolchain (full Xcode) is installed.
set -e
cd "$(dirname "$0")"

clang -fobjc-arc -framework Metal -framework Foundation -o s1 s1_metal_smoke.m

METALLIB=""
if xcrun --find metal >/dev/null 2>&1; then
  cat > /tmp/s1k.metal <<'MSL'
#include <metal_stdlib>
using namespace metal;
kernel void offline_vadd(device const float *a [[buffer(0)]],
                         device float *c [[buffer(1)]],
                         uint id [[thread_position_in_grid]]) {
  c[id] = a[id] * 2.0f;
}
MSL
  xcrun -sdk macosx metal -c /tmp/s1k.metal -o /tmp/s1k.air
  xcrun -sdk macosx metallib /tmp/s1k.air -o /tmp/s1k.metallib
  METALLIB=/tmp/s1k.metallib
  echo "offline metallib built: $METALLIB"
  xcrun -sdk macosx air-objdump --version 2>/dev/null | head -2 || true
else
  echo "NOTE: 'metal' tool not found (CommandLineTools only) — skipping the"
  echo "      offline metallib leg. Install full Xcode + Metal toolchain, rerun."
fi

./s1 $METALLIB 2>&1 | tee "RESULTS-$(sysctl -n hw.model | tr ',' '-')-$(date +%Y%m%d).txt"
