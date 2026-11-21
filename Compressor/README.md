# Compressor

A clean, OP-1-inflected AUv3 compressor for Logic Pro (and any AU host on
macOS). Feedforward design with peak detector, soft knee, smooth one-pole
attack/release envelope, auto makeup gain, and parallel-mix (dry/wet).

```
in ─► [HPF sidechain] ─► detector ─► gain computer ─► env (atk/rel) ─┐
                                                                      │
in ────────────────────────────► × gain reduction ─► makeup ────► out ◄┘
                                                       │
                                              dry/wet mix
```

## Look & feel

Cream OP-1-style faceplate. Single row of six small dark encoder-style knobs
across the top — Threshold, Ratio, Attack, Release, Knee, Mix. To the right of
the knob row sits a vertical gain-reduction meter (red fill, gray track). Tiny
ALL-CAPS screen-printed labels under each knob. Bottom-left corner: a small
red square brand mark + the word "COMPRESSOR" in tiny condensed type. Bottom
right: a small "BYPASS" toggle (red square when active).

## Parameter reference

| Param      | Range                | Default |
|------------|----------------------|---------|
| Threshold  | -60 .. 0 dB          | -18 dB  |
| Ratio      | 1 .. 20 : 1          | 4 : 1   |
| Attack     | 0.1 .. 100 ms        | 5 ms    |
| Release    | 5 .. 2000 ms         | 80 ms   |
| Knee       | 0 .. 24 dB           | 6 dB    |
| Mix        | 0 .. 1 (dry/wet)     | 1.0     |

Makeup gain is computed automatically from threshold + ratio
(`makeup = -threshold * (1 - 1/ratio) * 0.5`).

## Build & install

```bash
cd Compressor
./Installer/build_installer.sh
cp -R build/DerivedData/Build/Products/Release/Compressor.app /Applications/
open /Applications/Compressor.app   # first launch registers the AU
```

In Logic: **AU Effects ▸ Paradise Audio ▸ Compressor**.

## Layout

```
Compressor/
├── project.yml                       # XcodeGen spec
├── CompressorApp/                    # host app shell
├── CompressorExtension/
│   ├── CompressorAudioUnit.{h,mm}    # AUAudioUnit subclass, param tree, render
│   ├── AudioUnitViewController.swift
│   ├── DSP/                          # header-only C++ engine
│   │   ├── DSPCommon.hpp
│   │   ├── EnvelopeFollower.hpp
│   │   └── CompressorDSP.hpp
│   └── UI/
│       ├── KnobView.swift            # cream-on-dark OP-1 style knob
│       ├── GainReductionMeter.swift  # vertical red GR meter
│       └── CompressorParameterView.swift
└── Installer/                        # build / sign / package scripts
```
