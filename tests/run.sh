#!/bin/bash
#
# Build + run the driver ring/protocol unit tests, then print an llvm-cov report.
# No coreaudiod, no HAL, no install — pure in-process logic + real POSIX shm.
#
DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$DIR/../LoopbackDriver/Sources"
OUT="$DIR/../dist"
BIN="$OUT/ring_tests"
PROF="$OUT/ring_tests.profraw"
PROFDATA="$OUT/ring_tests.profdata"

set -e
mkdir -p "$OUT"
c++ -std=c++17 -g -O0 -fprofile-instr-generate -fcoverage-mapping -I "$SRC" \
    "$DIR/ring_tests.cpp" "$SRC/RingOwner.cpp" "$DIR/RingClient.cpp" -o "$BIN"
set +e

LLVM_PROFILE_FILE="$PROF" "$BIN"
RC=$?

xcrun llvm-profdata merge -sparse "$PROF" -o "$PROFDATA" 2>/dev/null && {
    echo
    echo "==== coverage (RingOwner.cpp / RingClient.cpp) ===="
    xcrun llvm-cov report "$BIN" -instr-profile="$PROFDATA" "$SRC/RingOwner.cpp" "$DIR/RingClient.cpp"
}
exit $RC
