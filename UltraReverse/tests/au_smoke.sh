#!/bin/bash
# Render the real Ultra Reverse UI offscreen in a given mode (CLT toolchain).
#   tests/render_ui.sh <out.png> <mode 0-3> [sync 0/1]
set -e
cd "$(dirname "$0")"
EXT=../UltraReverseExtension
B="${TMPDIR:-/tmp}/urv_au_smoke"; rm -rf "$B"; mkdir -p "$B"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
SDK="$DEVELOPER_DIR/SDKs/MacOSX.sdk"
objs=()
while IFS= read -r src; do
    o="$B/$(basename "$src").o"
    clang++ -c -isysroot "$SDK" -target arm64-apple-macos13.0 -std=c++17 -fobjc-arc -fmodules -O1 \
        -DAUDIOFFT_APPLE_ACCELERATE=1 -I "$EXT" -I "$EXT/DSP" -w "$src" -o "$o"
    objs+=("$o")
done < <(find "$EXT" \( -name '*.mm' -o -name '*.cpp' \) -not -path '*/build/*')
swifts=(); while IFS= read -r f; do swifts+=("$f"); done < <(find "$EXT" -name '*.swift')
swiftc -sdk "$SDK" -target arm64-apple-macos13.0 -O -I "$EXT" -import-objc-header "$EXT/UltraReverseExtension-Bridging-Header.h" \
    "${swifts[@]}" au_smoke/main.swift "${objs[@]}" -lc++ \
    -framework AudioToolbox -framework AVFoundation -framework CoreAudioKit -framework AppKit -framework Accelerate -o "$B/r" 2>&1 | grep -E "error|Undefined|referenced from" | head -12 || true
cp "$EXT"/Resources/* "$B/"

cd "$B" && ./r
