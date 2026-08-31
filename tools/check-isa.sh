#!/usr/bin/env bash
# Does this artifact contain AVX-512 a non-AVX-512 Mac could actually hit?
#
#   ./tools/check-isa.sh <file>...
#
# The naive gate -- count first-bytes of 0x62, demand zero -- was calibrated
# on the MacBook against small local dylibs, and it correctly convicted the
# Xeon-native dist (6,342 hits, EVEX vpbroadcastb in absl's SwissTable, SIGILL
# at startup). On a full v3-built driver it still reports ~591, and every one
# of them is a false conviction, in two classes this script tells apart:
#
#   dispatched   real EVEX inside *_avx512-suffixed functions that a CPUID
#                selector (xxHash's XXH_setDispatch carries 4 cpuid/xgetbv)
#                chooses at run time. Present in every x86 build of a
#                dispatched library; unreachable on a CPU without AVX-512.
#   data         0x62 bytes in jump tables and embedded data that the
#                disassembler prints as `<unknown>` rather than a mnemonic.
#                Not instructions at all.
#
# REACHABLE is the verdict column: EVEX decoded as a real instruction, in an
# ordinary (undispatched) function. That is the class that killed the MacBook,
# and the only class that can.
set -uo pipefail
fail=0
printf '%-40s %9s %11s %6s %10s\n' artifact raw dispatched data REACHABLE
for f in "$@"; do
  [ -f "$f" ] || { printf '%-40s missing\n' "$f"; fail=1; continue; }
  xcrun llvm-objdump -d "$f" 2>/dev/null | awk -v name="$f" '
    /^[0-9a-f]+ <.*>:/ { fn = $0 }
    $2 == "62" {
      raw++
      if (fn ~ /avx512/)            { disp++ }
      else if ($NF == "<unknown>")  { data++ }
      else                          { reach++ }
    }
    END {
      printf "%-40s %9d %11d %6d %10d\n", name, raw+0, disp+0, data+0, reach+0
      exit (reach+0 > 0 ? 1 : 0)
    }' || fail=1
done
[ "$fail" = 0 ] && echo "PASS: no reachable AVX-512" || echo "FAIL: reachable AVX-512 present (or artifact missing)"
exit $fail
