#!/bin/bash
# build_all_paradise.sh — build & install all 9 Paradise Audio plug-ins.
#
# Each plug-in builds independently. A failure in one doesn't stop the rest.
# At the end you get a ✅/❌ summary.
#
# Requires: full Xcode + `brew install xcodegen`.
# Compatible with macOS default bash (3.2) — no associative arrays / set -u.

cd "$(dirname "$0")"

PLUGINS=(Compressor EQ Reverb Saturation Deesser Delay Drums BassMitStimme Handy BigKnob SynthThing Limiter VoiceBox UltraReverse StringThing PitchKnob RoarBass)

SUCCESS=()
FAILED=()

for p in "${PLUGINS[@]}"; do
    echo ""
    echo "========================================"
    echo "Building $p"
    echo "========================================"

    LOG="/tmp/paradise_build_${p}.log"

    # Wipe stale .xcodeproj so xcodegen re-scans and picks up any new source files
    rm -rf "$p/$p.xcodeproj"

    (
        cd "$p" || exit 99
        ./Installer/build_installer.sh
    ) > "$LOG" 2>&1
    BUILD_STATUS=$?

    APP="$p/build/DerivedData/Build/Products/Release/${p}.app"

    if [ $BUILD_STATUS -ne 0 ] || [ ! -d "$APP" ]; then
        echo "  FAIL $p (status=$BUILD_STATUS)"
        FAILED+=("$p")
        grep -E "error:" "$LOG" | head -3 | sed 's/^/      /'
        continue
    fi

    echo "  OK $p built — installing to /Applications/"

    rm -rf "/Applications/${p}.app" 2>/dev/null
    cp -R "$APP" /Applications/

    LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
    if [ -x "$LSREG" ]; then
        "$LSREG" -f -R "/Applications/${p}.app" 2>/dev/null
    fi

    # Launch briefly to register the embedded .appex via PluginKit
    open -gj "/Applications/${p}.app" 2>/dev/null
    sleep 2
    osascript -e "tell application \"${p}\" to quit" 2>/dev/null
    pkill -f "/Applications/${p}.app/Contents/MacOS/${p}" 2>/dev/null

    SUCCESS+=("$p")
done

echo ""
echo "Restarting AudioComponentRegistrar..."
killall -9 AudioComponentRegistrar 2>/dev/null
sleep 1

echo ""
echo "========================================"
echo "BUILD SUMMARY"
echo "========================================"
echo "Shipped (${#SUCCESS[@]}/${#PLUGINS[@]}):"
for p in "${SUCCESS[@]}"; do echo "  + $p"; done
if [ ${#FAILED[@]} -gt 0 ]; then
    echo ""
    echo "Failed (${#FAILED[@]}/${#PLUGINS[@]}):"
    for p in "${FAILED[@]}"; do
        echo "  - $p   (full log: /tmp/paradise_build_${p}.log)"
    done
fi
echo ""
echo "Now open Logic Pro (quit + reopen if it was already running) and look under:"
echo "  AU Effects ▸ Paradise Audio"
echo "  AU Instruments ▸ Paradise Audio"
