#!/bin/bash
# Build a plug-in's extension code as a plain executable (CLT toolchain, no
# Xcode licence needed) and render its UI offscreen.
#   Tools/au_offline/render.sh <Plugin> <out.png> [aufx|aumu]
set -e
ROOT="/Users/nicolaslekai/Documents/Claude/Projects/AUDIO SYNTH"
P="$1"; OUT="$2"; HARN="$(cd "$(dirname "$0")" && pwd)"
EXT="$ROOT/$P/${P}Extension"
B="${TMPDIR:-/tmp}/paradise_au_offline/$P"; rm -rf "$B"; mkdir -p "$B"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
SDK="$DEVELOPER_DIR/SDKs/MacOSX.sdk"
objs=()
while IFS= read -r src; do
    o="$B/$(basename "$src").o"
    clang++ -c -isysroot "$SDK" -target arm64-apple-macos13.0 -std=c++17 -fobjc-arc -fmodules -O1 \
        -I "$EXT" -I "$EXT/DSP" -w "$src" -o "$o"
    objs+=("$o")
done < <(find "$EXT" \( -name '*.mm' -o -name '*.cpp' -o -name '*.m' \) -not -path '*/build/*')
swifts=()
while IFS= read -r f; do swifts+=("$f"); done < <(find "$EXT" -name '*.swift' -not -path '*/build/*')
hdr=$(ls "$EXT"/*Bridging-Header.h | head -1)
swiftc -sdk "$SDK" -target arm64-apple-macos13.0 -O -I "$EXT" -import-objc-header "$hdr" \
    "${swifts[@]}" "$HARN/main.swift" "${objs[@]}" -lc++ \
    -framework AudioToolbox -framework AVFoundation -framework CoreAudioKit -framework AppKit -framework Accelerate \
    -o "$B/aurender" 2>&1 | grep -E "error|Undefined|_vDSP|referenced" | head -6 || true
cp "$EXT"/Resources/* "$B/" 2>/dev/null || true
cd "$B" && shift 2 && ./aurender "$OUT" "$@"
