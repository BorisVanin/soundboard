#!/bin/bash
#
# Gain-applying algorithm test. Two stages:
#   1. swiftc-built generator (gain_tests.swift) emits dist/gain_sweep_*.wav for a
#      knob swept min→max→min — the OLD block-constant algorithm, the SHIPPED
#      one-pole de-zipper, and click-free references (exact / per-buffer ramp).
#   2. The authoritative click verdict comes from ffmpeg's research-backed `adeclick`
#      (NOT a home-grown detector): residual = original − adeclick(original) isolates
#      the clicks, then click_analysis.py counts the periodic bursts.
#
# Gate: the shipped (smoothed) sweep must be click-free; the old block-constant sweep
# must show clicks (negative control proving the detector actually fires). Needs
# ffmpeg + python3/numpy on PATH.
#
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
OUT="$ROOT/dist"
BIN="$OUT/gain_tests"

mkdir -p "$OUT"
set -e
swiftc -O "$DIR/gain_tests.swift" -o "$BIN"
"$BIN" "$OUT"
set +e

detect() {  # <wav> <label> <max-bursts>
    ffmpeg -y -v error -i "$OUT/$1" -af adeclick "$OUT/declicked_$1" || return 2
    python3 "$DIR/click_analysis.py" "$OUT/$1" "$OUT/declicked_$1" "$2" --max-bursts "$3"
}

echo
echo "==== ffmpeg adeclick click detection ===="
rc=0
detect gain_sweep_smoothed.wav       "SHIPPED one-pole de-zipper (must be click-free)" 2 || rc=1
echo
detect gain_sweep_block_constant.wav "OLD block-constant (negative control: expect clicks)" 2
[ $? -eq 1 ] || { echo "  !! detector did not fire on the known-bad signal"; rc=1; }

echo
[ $rc -eq 0 ] && echo "==== gain tests: PASS ====" || echo "==== gain tests: FAIL ===="
exit $rc
