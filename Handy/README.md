# Handy — MP3/AAC Sampler

Paradise Audio AUv3 sampler instrument (**HBY-1**). Loads compressed and
uncompressed audio files (MP3, M4A, AAC, WAV, AIFF, CAF — anything `AVAudioFile`
can decode) into **2 large sample zones**, stacked vertically. Zone 1 spans the
first 16 keys (C2–D#3), zone 2 the next 16 keys (E3–G4). Each zone auto-spreads
its sample across its 16-note span and plays it pitch-shifted via varispeed, so
a single dropped sample becomes chromatically playable. A global **PITCH** knob
transposes the whole instrument, and everything runs through a warming /
restoration chain.

```
MIDI note ─► zone (16-key span) ─► range window ─► varispeed voice (+ global pitch)
          ─► HF restore → noise reduce → transient → warmth → level → mix ─► out
```

## Sample zones

Each zone is a large horizontal box showing the loaded sample's **waveform**,
the file name, and a **RANGE** selector — two draggable red handles over the
waveform that pick which portion of the sample actually plays (in-window samples
draw red, the rest dim). Load a zone by dragging an audio file onto it,
**Shift-clicking**, or **right-clicking** for a menu (Load…, Clear, Reset Range,
Recent Files). The `LOAD` / `CLEAR` toolbar buttons act on the highlighted zone
(shown by the `SELECTED ▸ ZONE n` readout).

| Zone interaction | Action |
|---|---|
| Click | Audition (also selects the zone) |
| Shift-click | Open file picker for that zone |
| Option-click | Clear that zone |
| Drag & drop | Load a dropped audio file |
| Drag a RANGE handle | Trim the start / end of the playing window |
| Right-click | Context menu |

### Per-zone controls

| Control | Range / values | Interaction |
|---|---|---|
| **RANGE** | start / end (0–100%) | Drag the two handles over the waveform |
| **CHOP** | FWD / REV / STUT / HALF | Click a segment in the strip |
| **KEY-TRIG** | GATE ↔ 1-SHOT | Click the pill (GATE = plays only while key held) |

### Global pitch

A dedicated **PITCH** knob (param `pt`, **−24 .. +24 st**, automatable) sits at
the right of the knob bank and transposes every zone.

## Restoration chain (knob bank)

Grouped **TONE · CLEAN-UP · OUTPUT** for clarity. (Display order is regrouped;
the underlying parameters are unchanged.)

| Param | Range | Default | Group | Note |
|---|---|---|---|---|
| HF Restore | 0 .. 1 | 0.65 | TONE | High-band tilt + saturation |
| Warmth | 0 .. 1 | 0.40 | TONE | Light tube-style saturation |
| Noise Rdx | -40 .. 0 dB | -18 dB | CLEAN-UP | Downward expander threshold |
| Transient | -1 .. +1 | +0.30 | CLEAN-UP | Transient enhance / soften |
| Level | -24 .. +12 dB | 0 dB | OUTPUT | Output trim |
| Mix | 0 .. 1 | 1.0 | OUTPUT | Wet/dry (dry = untouched zone) |
| Pitch | -24 .. +24 st | 0 st | PITCH | Global transpose (`pt`) |

Knobs: vertical drag (⌥ = fine), scroll wheel, double-click = default. The
header also has **SAVE / LOAD** named presets and **undo / redo** (10 steps).

Build: `./Installer/build_installer.sh` (or `../build_changed.sh`).
Logic: **AU Instruments ▸ Paradise Audio ▸ Handy**.
