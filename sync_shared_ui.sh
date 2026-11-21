#!/bin/bash
# sync_shared_ui.sh — copy the canonical shared UI files from Shared/UI/ into
# every plug-in extension's UI folder. Run after editing anything in Shared/UI.
#
#   Palette.swift · KnobView.swift · BrandStrip.swift · BrandLogo.swift ·
#   FaceTexture.swift  — plus Shared/UI/Resources/* (faceplate, keys, knob bodies)
#   into every extension's Resources/ folder.
#
# Drums keeps its own compact KnobView (28 px per-voice variant) on purpose,
# and plug-ins without a KnobView (BigKnob, PitchKnob, StringThing, SynthThing)
# don't get one forced on them. Everything else is overwritten 1:1.
cd "$(dirname "$0")"
SRC=Shared/UI
KEEP_OWN_KNOB=(Drums)
changed=0
for dir in */*Extension/UI; do
    plugin="${dir%%/*}"
    for f in Palette BrandLogo FaceTexture BrandStrip KnobView; do
        src="$SRC/$f.swift"; dst="$dir/$f.swift"
        [ -f "$src" ] || continue
        if [ "$f" = "KnobView" ]; then
            [ -f "$dst" ] || continue                       # never force-add a knob
            for k in "${KEEP_OWN_KNOB[@]}"; do [ "$plugin" = "$k" ] && continue 2; done
        fi
        if ! cmp -s "$src" "$dst"; then
            cp "$src" "$dst"; echo "  updated $dst"; changed=$((changed+1))
        fi
    done
    # Shared bitmaps (analog scheme 2026-11-20): faceplate, rubber keys, knob
    # bodies → every extension's Resources/ (xcodegen bundles them).
    res="${dir%/UI}/Resources"
    if [ -d "$SRC/Resources" ] && [ -d "$res" ]; then
        for a in "$SRC"/Resources/*; do
            dst="$res/$(basename "$a")"
            if ! cmp -s "$a" "$dst"; then
                cp "$a" "$dst"; changed=$((changed+1))
            fi
        done
    fi
done
echo "sync_shared_ui: $changed file(s) updated."
