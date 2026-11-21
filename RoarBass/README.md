# RoarBass

An AUv3 instrument plug-in for Logic Pro (and any AU host on macOS) focused on
deep, roary bass sounds. Hybrid engine: two bandlimited oscillators + sine sub
+ a tunable 2-op FM "growl" + filtered noise, all running into a zero-delay
ladder filter with drive.

```
oscillators (saws) ─┐
sine sub ───────────┤
FM growl (sin/FM) ──┼──► drive ─► ladder filter ─► amp env ─► out drive ─► out
noise ──────────────┘                ▲
                                     │
                              filter env (cutoff mod)
```

## Layout

```
RoarBass/
├── project.yml                  # XcodeGen spec
├── RoarBassApp/                 # host app shell (AUv3 ships inside an app)
├── RoarBassExtension/
│   ├── RoarBassAudioUnit.{h,mm} # AUAudioUnit subclass, param tree, MIDI, render
│   ├── AudioUnitViewController.swift
│   ├── DSP/                     # header-only C++ engine
│   │   ├── DSPCommon.hpp
│   │   ├── Oscillator.hpp       # PolyBLEP saws / clean sine
│   │   ├── FMOperator.hpp       # 2-op FM with self-feedback
│   │   ├── NoiseSource.hpp      # white/brown crossfade
│   │   ├── LadderFilter.hpp     # ZDF 4-pole with tanh
│   │   ├── Envelope.hpp         # ADSR
│   │   ├── Voice.hpp            # one voice
│   │   └── RoarBassDSP.hpp      # engine / voice manager
│   └── UI/                      # Cocoa dark UI
│       ├── KnobView.swift       # custom CG-drawn rotary knob
│       └── RoarBassParameterView.swift
└── Installer/
    ├── build_installer.sh       # one-shot build + sign + package
    ├── distribution.xml         # productbuild distribution
    ├── scripts/postinstall      # registers app with Launch Services
    └── Resources/               # welcome / conclusion text
```

## Prerequisites

- macOS 11.0+ (build & runtime)
- Xcode 14+ (`xcode-select --install` then install Xcode from the App Store)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Optional, for nicer build logs: `gem install xcpretty`

## Build & install (one command)

```bash
cd RoarBass
./Installer/build_installer.sh
open dist/RoarBass-1.0.0.pkg
```

The first launch of `RoarBass.app` (from `/Applications`) registers the AU with
the system. Then Logic Pro will list it under **AU Instruments ▸ Anthropic ▸
RoarBass**.

## Signing & notarization (for distribution)

Set these environment variables before running the build script:

```bash
export DEV_ID_APP="Developer ID Application: Your Name (TEAMID)"
export DEV_ID_INSTALLER="Developer ID Installer: Your Name (TEAMID)"
export NOTARY_PROFILE="MyAppNotaryProfile"  # see: xcrun notarytool store-credentials
./Installer/build_installer.sh
```

Without those vars the script still produces an unsigned `.pkg` you can install
on your own machine (right-click the pkg → Open to bypass Gatekeeper).

## Verifying with auval

After installing and launching the app once:

```bash
auval -v aumu Roar Anth
```

`aumu` = Audio Unit Music Device (instrument), `Roar` = subtype,
`Anth` = manufacturer code. These match the `NSExtensionAttributes` in the
extension's `Info.plist`.

## Sound design quick tips

- **Earth-shaking sub-bass**: SUB Level 1.0, OSC Mix 0.5, OSC1/OSC2 Octave 0,
  Filter Cutoff ~400 Hz, FM Growl 0, Output Drive 0.1.
- **Reese / Neuro roar**: OSC2 Detune ±20c, FM Growl 0.5, FM Ratio 1.5–2.0,
  FM Feedback 0.4, Resonance 0.4, Filter Drive 0.6, Filter Env Amt +0.6 with
  short Filter Decay 0.3s.
- **Distorted dub stab**: Voice Mode MONO, Glide 0.05s, Filter Cutoff 250 Hz,
  Filter Env Amt +0.8, Output Drive 0.7.
- **Movement under a pad**: Noise Level 0.15, Noise Colour 0.8 (brown), slow
  Filter Attack 1.2s, low Resonance.

## Parameter reference

| Section     | Param          | Range            |
|-------------|----------------|------------------|
| Oscillators | OSC1 Octave    | -2 .. +2         |
|             | OSC2 Octave    | -2 .. +2         |
|             | OSC2 Detune    | -50 .. +50 c     |
|             | OSC Mix        | 0 .. 1           |
|             | Sub Level      | 0 .. 1           |
| FM Growl    | FM Growl       | 0 .. 1           |
|             | FM Ratio       | 0.25 .. 8        |
|             | FM Feedback    | 0 .. 1           |
| Noise       | Noise Level    | 0 .. 1           |
|             | Noise Colour   | 0 white–1 brown  |
| Filter      | Cutoff         | 20 Hz .. 18 kHz  |
|             | Resonance      | 0 .. 1           |
|             | Filter Drive   | 0 .. 1           |
|             | Filter Env Amt | -1 .. +1         |
| Amp Env     | A, D, S, R     | 1 ms .. 4 s      |
| Filter Env  | A, D, S, R     | 1 ms .. 4 s      |
| Global      | Glide          | 0 .. 1 s         |
|             | Voice Mode     | POLY / MONO      |
|             | Master Gain    | 0 .. 2           |
|             | Output Drive   | 0 .. 1           |

## Notes

- The engine is sample-accurate. MIDI events arrive in the AU render callback
  and split the buffer at exact event positions before rendering each segment.
- Polyphony is 8 voices. Mono mode is legato — no envelope retrigger when a
  new note starts while the previous is still held. That's what enables the
  classic 303-style slide.
- The filter is a ZDF 4-pole ladder with per-stage `tanh()`. Self-oscillates
  near Resonance 1.0.
