#!/bin/bash
#
# Build + run the headless engine harness: links ALL of MixerEngine/Sources with
# tests/engine_harness/main.swift into one CLI binary, so it drives the real
# MixEngine / MacSoundLane / MicSoundLane capture code without the GUI app.
#
#   tests/engine_harness.sh mac [seconds]            # isolated system-audio tap
#   tests/engine_harness.sh engine [seconds]         # full MixEngine (+ driver ring)
#   tests/engine_harness.sh mic [seconds] <micUID>   # isolated mic capture
#
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
OUT="$ROOT/dist"
BIN="$OUT/engine_harness"

mkdir -p "$OUT"
set -e
swiftc -O \
    "$ROOT"/MixerEngine/Sources/*.swift \
    "$DIR"/engine_harness/main.swift \
    -framework CoreAudio -framework AudioToolbox -framework Accelerate \
    -framework AVFAudio -framework AppKit -framework Foundation \
    -o "$BIN"
set +e

echo "==> built $BIN"
"$BIN" "$@"
