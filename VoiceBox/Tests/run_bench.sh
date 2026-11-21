#!/bin/bash
# Build + run the VoiceBox bench against the frozen baseline (old) and the
# current DSP (new). Command Line Tools only — no Xcode licence needed.
#   Tests/run_bench.sh [old|new|both] [quick]
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
SDK="$DEVELOPER_DIR/SDKs/MacOSX.sdk"
OUT="$HERE/renders"; mkdir -p "$OUT"
BIN="${TMPDIR:-/tmp}/vbx_bench"; mkdir -p "$BIN"
WHICH="${1:-both}"; MODE="${2:-}"
build_run() {
    local tag="$1" inc="$2" def="$3"
    clang++ -std=c++17 -O2 -isysroot "$SDK" $def -I "$inc" -I "$HERE" "$HERE/bench.cpp" \
        -framework Accelerate -o "$BIN/bench_$tag"
    "$BIN/bench_$tag" "$tag" "$OUT" $MODE | tee "$OUT/metrics_$tag.txt"
}
[ "$WHICH" = old ] || [ "$WHICH" = both ] && build_run old "$HERE/baseline" "-DVBX_OLD"
[ "$WHICH" = new ] || [ "$WHICH" = both ] && build_run new "$HERE/../VoiceBoxExtension/DSP" ""
exit 0
