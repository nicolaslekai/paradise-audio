#!/bin/bash
# Build + run the STRETCH / WARP offline test against the real BMS DSP.
#   Tests/run_stretch_test.sh [outdir]   (outdir: where the audio examples go)
# Uses the bundled Stimme.m4a as the real-voice case (converted with afconvert).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${TMPDIR:-/tmp}/bms_stretch_test"; mkdir -p "$BIN"
OUT="${1:-}"
afconvert -f WAVE -d LEF32 "$HERE/../BassMitStimmeExtension/Resources/Stimme.m4a" "$BIN/stimme.wav"
clang++ -std=c++17 -O2 -I "$HERE/../BassMitStimmeExtension/DSP" "$HERE/stretch_test.cpp" -framework Accelerate -o "$BIN/stretch_test"
"$BIN/stretch_test" "$BIN/stimme.wav" ${OUT:+"$OUT"}
