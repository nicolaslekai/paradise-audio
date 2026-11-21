#!/bin/bash
# VoiceBox sound-quality harness (2026-11-21). Command Line Tools only.
#   Tests/sq/run_sq.sh [before|after|both] [test names… | all]
# before = DSP frozen in Tests/sq/before_dsp, after = live VoiceBoxExtension/DSP.
# Metrics → Tests/sq/out/metrics_<tag>.txt ; table → python3 Tests/sq/table.py
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
SDK="$DEVELOPER_DIR/SDKs/MacOSX.sdk"
OUT="$HERE/out"; mkdir -p "$OUT"
BIN="${TMPDIR:-/tmp}/vbx_sq"; mkdir -p "$BIN/before" "$BIN/after"
WHICH="${1:-both}"; shift || true
TESTS="${*:-all}"
gen_tables() {   # $1 = .mm file, $2 = output dir
    { grep -m1 '^static constexpr int kNumParams' "$1"
      awk '/^namespace \{$/{f=1} f{print} /^\}$/{if(f){exit}}' "$1"; } > "$2/au_tables.inc"
}
build_run() {
    local tag="$1" inc="$2" mm="$3" def="$4"
    gen_tables "$mm" "$BIN/$tag"
    clang++ -std=c++17 -O2 -isysroot "$SDK" $def -I "$BIN/$tag" -I "$inc" -I "$HERE" "$HERE/sq_harness.cpp" \
        -framework Accelerate -o "$BIN/sq_$tag"
    if [ "$TESTS" = all ]; then
        "$BIN/sq_$tag" "$tag" "$HERE" all | tee "$OUT/metrics_$tag.txt"
    else
        "$BIN/sq_$tag" "$tag" "$HERE" $TESTS
    fi
}
if [ "$WHICH" = before ] || [ "$WHICH" = both ]; then
    build_run before "$HERE/before_dsp" "$HERE/before_dsp/VoiceBoxAudioUnit.mm.snapshot" "-DSQ_BEFORE"
fi
if [ "$WHICH" = after ] || [ "$WHICH" = both ]; then
    build_run after "$HERE/../../VoiceBoxExtension/DSP" "$HERE/../../VoiceBoxExtension/VoiceBoxAudioUnit.mm" ""
fi
exit 0
