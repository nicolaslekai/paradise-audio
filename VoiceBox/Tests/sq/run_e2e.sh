#!/bin/bash
# Build VoiceBoxAudioUnit.mm + DSP into a test executable (Command Line Tools, no
# Xcode build, nothing installed) and drive the real AU class's render block.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"; EXT="$HERE/../../VoiceBoxExtension"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
SDK="$DEVELOPER_DIR/SDKs/MacOSX.sdk"
B="${TMPDIR:-/tmp}/vbx_sq/e2e"; mkdir -p "$B"
{ grep -m1 '^static constexpr int kNumParams' "$EXT/VoiceBoxAudioUnit.mm"
  awk '/^namespace \{$/{f=1} f{print} /^\}$/{if(f){exit}}' "$EXT/VoiceBoxAudioUnit.mm"; } > "$B/au_tables.inc"
FLAGS=(-isysroot "$SDK" -target arm64-apple-macos12.0 -std=c++17 -fobjc-arc -O2 -w -I "$EXT" -I "$EXT/DSP" -I "$HERE" -I "$B")
clang++ -c "${FLAGS[@]}" -fmodules "$EXT/VoiceBoxAudioUnit.mm" -o "$B/au.o"
clang++ -c "${FLAGS[@]}" -x objective-c++ "$HERE/au_e2e.mm" -o "$B/e2e.o"
clang++ -isysroot "$SDK" -target arm64-apple-macos12.0 "$B/au.o" "$B/e2e.o" -framework Foundation -framework AudioToolbox -framework AVFoundation -framework Accelerate -o "$B/au_e2e"
"$B/au_e2e"
