#!/bin/bash
# Validate the x86-64 Cocoa port end to end.
#
# Ported from the sister fork's runner; only the launcher paths differ, because
# the two forks ship their toolchains differently. The structure -- and above
# all the must_fail half -- is theirs and deliberately unchanged.
#
# The must_fail spikes are the interesting half: the design's whole claim is
# that a name the database does not know becomes a COMPILE ERROR rather than a
# wrong answer, so a run where they quietly succeed is a FAILED run.
set -uo pipefail
cd "$(dirname "$0")/.."

MOJO=${MOJO:-vega-sdk/bin/mojo}
export MODULAR_MOJO_MAX_COCOAKB_PATH=${MODULAR_MOJO_MAX_COCOAKB_PATH:-\
"/Volumes/S/CocoaBaseMCP/cocoa.sqlite"}
export MODULAR_CACHE_DIR=${MODULAR_CACHE_DIR:-$(mktemp -d /tmp/cocoachecks.XXXXXX)}

[ -x "$MOJO" ] || { echo "no compiler at $MOJO -- build it with:"; \
  echo "  ./bazelw build //KGEN/tools/mojo:mojo"; exit 1; }
[ -f "$MODULAR_MOJO_MAX_COCOAKB_PATH" ] || { \
  echo "no cocoa.sqlite at $MODULAR_MOJO_MAX_COCOAKB_PATH"; \
  echo "  build it with: python3 /Volumes/S/CocoaBaseMCP/build.py"; exit 1; }

echo "compiler: $MOJO"
echo "database: $MODULAR_MOJO_MAX_COCOAKB_PATH"
echo

pass=0; fail=0; missing=0
bin=$(mktemp -d /tmp/cocoabin.XXXXXX)
trap 'rm -rf "$bin"' EXIT

run_ok() {   # must compile AND run
  printf '  %-26s ' "$1"
  if [ ! -f "spikes/s5-cocoakb/$1" ]; then
    echo "NOT PORTED"; missing=$((missing+1)); return
  fi
  if out=$("$MOJO" build -o "$bin/${1%.mojo}" "spikes/s5-cocoakb/$1" 2>&1) &&
     out=$("$bin/${1%.mojo}" 2>&1); then
    echo "PASS"; pass=$((pass+1))
  else
    echo "FAIL"; fail=$((fail+1)); sed 's/^/      /' <<<"$out" | grep -v Crashpad | head -10
  fi
}

run_mustfail() {   # must FAIL TO COMPILE, and say why
  printf '  %-26s ' "$1"
  if [ ! -f "spikes/s5-cocoakb/$1" ]; then
    echo "NOT PORTED"; missing=$((missing+1)); return
  fi
  if out=$("$MOJO" build -o "$bin/${1%.mojo}" "spikes/s5-cocoakb/$1" 2>&1); then
    echo "FAIL (compiled, but must not)"; fail=$((fail+1))
  else
    echo "PASS (rejected at comptime)"; pass=$((pass+1))
    sed 's/^/      /' <<<"$out" | grep -iE "cocoa|metadata|unknown|no |'fn'|'let'" | head -2
  fi
}

echo "must compile and run:"
for f in check.mojo objc_smoke.mojo foundation_demo.mojo typecheck_test.mojo \
         ownership_test.mojo stret_test.mojo callback_probe.mojo \
         weakref_test.mojo nserror_test.mojo fn_test.mojo dispatch_test.mojo let_test.mojo \
         registrar_test.mojo class_test.mojo struct_arg_test.mojo \
         struct_ret_test.mojo box_test.mojo class_field_test.mojo \
         objc_decorator_test.mojo dealloc_test.mojo field_init_test.mojo inherit_test.mojo class_method_test.mojo box_ref_test.mojo typed_result_test.mojo \
         typed_test.mojo; do run_ok "$f"; done

# The one test with clang on the other end. Everything above has Mojo at both
# ends and so proves only self-consistency; this links a dylib built by the
# compiler that built AppKit, and lets it send the messages.
echo
echo "must agree with clang about the C ABI:"
printf '  %-26s ' "abi_oracle_test.mojo"
if clang -dynamiclib -fobjc-arc -o /tmp/libabioracle.dylib \
      spikes/abi-oracle/abi_oracle.m -framework Foundation -framework AppKit \
      2>"$bin/cc.log" &&
   out=$("$MOJO" build -o "$bin/abi_oracle" spikes/abi-oracle/abi_oracle_test.mojo 2>&1 &&
         "$bin/abi_oracle" 2>&1); then
  echo "PASS"; pass=$((pass+1))
else
  echo "FAIL"; fail=$((fail+1)); sed 's/^/      /' <<<"$out" | grep -v Crashpad | head -10
fi

echo
echo "must be rejected at compile time:"
for f in must_fail.mojo must_fail_argcount.mojo must_fail_fn_raises.mojo \
         must_fail_let_assign.mojo; do run_mustfail "$f"; done

# Not in their runner, and the reason it is in ours: this fork exists to behave
# like theirs, so a divergence is a test failure like any other.
echo
echo "must not have drifted from MojoCocoa:"
printf '  %-26s ' "check-parity.sh"
if out=$(./tools/check-parity.sh 2>&1); then
  echo "PASS"; pass=$((pass+1))
else
  echo "FAIL"; fail=$((fail+1)); sed 's/^/      /' <<<"$out" | head -12
fi

echo
echo "$pass passed, $fail failed, $missing not ported"
exit $(( fail > 0 ))
