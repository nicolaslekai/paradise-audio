# Paradise Audio — Parameter Reference

Auto-extracted from the macOS AU sources. These are the exact IDs, ranges and defaults
the JUCE `AudioProcessorValueTreeState` is generated from — they match the Mac plugins 1:1.
**157 automatable parameters across 15 plugins.** (SynthThing and StringThing expose none — see below.)


## Compressor  (effect, VST3 code `Cmp1`)

| # | ID | Name | Min | Max | Default | Unit |
|---|----|------|-----|-----|---------|------|
| 0 | `threshold` | Threshold | -60 | 0 | -18 | dB |
| 1 | `ratio` | Ratio | 1 | 20 | 4 | ratio |
| 2 | `attack` | Attack | 0.1 | 100 | 5 | ms |
| 3 | `release` | Release | 5 | 2000 | 80 | ms |
| 4 | `knee` | Knee | 0 | 24 | 6 | dB |
| 5 | `mix` | Mix | 0 | 1 | 1 | gain |
| 6 | `duckOn` | Duck | 0 | 1 | 0 | bool |
| 7 | `duckRate` | Duck Rate | 1 | 12 | 3 | indexed |
| 8 | `duckDepth` | Duck Depth | 0 | 36 | 9 | dB |
| 9 | `duckAttack` | Duck Attack | 0.1 | 50 | 3 | ms |

## EQ  (effect, VST3 code `PEq1`)

| # | ID | Name | Min | Max | Default | Unit |
|---|----|------|-----|-----|---------|------|
| 0 | `hp` | HP | 20 | 1000 | 40 | Hz |
| 1 | `loFreq` | Lo Freq | 40 | 800 | 120 | Hz |
| 2 | `loGain` | Lo Gain | -18 | 18 | 0 | dB |
| 3 | `hiFreq` | Hi Freq | 1000 | 16000 | 6000 | Hz |
| 4 | `hiGain` | Hi Gain | -18 | 18 | 0 | dB |
| 5 | `lp` | LP | 2000 | 20000 | 18000 | Hz |
| 6 | `lmFreq` | LM Freq | 200 | 2000 | 500 | Hz |
| 7 | `lmGain` | LM Gain | -18 | 18 | 0 | dB |
| 8 | `hmFreq` | HM Freq | 1000 | 8000 | 2500 | Hz |
| 9 | `hmGain` | HM Gain | -18 | 18 | 0 | dB |
| 10 | `loQ` | Lo Q | 0.2 | 8 | 0.9 | — |
| 11 | `lmQ` | LM Q | 0.2 | 8 | 1.2 | — |
| 12 | `hmQ` | HM Q | 0.2 | 8 | 1.2 | — |
| 13 | `hiQ` | Hi Q | 0.2 | 8 | 0.9 | — |
| 14 | `hpSlope` | HP Slope | 0 | 1 | 0 | indexed |
| 15 | `lpSlope` | LP Slope | 0 | 1 | 0 | indexed |

## Reverb  (effect, VST3 code `Rvb1`)

| # | ID | Name | Min | Max | Default | Unit |
|---|----|------|-----|-----|---------|------|
| 0 | `size` | Size | 0 | 1 | 0.65 | gain |
| 1 | `decay` | Decay | 0.5 | 8 | 2.1 | s |
| 2 | `damping` | Damping | 0 | 1 | 0.4 | gain |
| 3 | `predelay` | Predelay | 0 | 200 | 12 | ms |
| 4 | `loCut` | EQ Lo | 20 | 1000 | 80 | Hz |
| 5 | `hiCut` | EQ Hi | 1000 | 18000 | 9000 | Hz |
| 6 | `mix` | Mix | 0 | 1 | 0.35 | gain |

## Saturation  (effect, VST3 code `Sat1`)

| # | ID | Name | Min | Max | Default | Unit |
|---|----|------|-----|-----|---------|------|
| 0 | `drive` | Drive | -12 | 24 | 8 | dB |
| 1 | `bias` | Bias | -1 | 1 | 0.15 | gain |
| 2 | `tone` | Tone | -1 | 1 | 0 | gain |
| 3 | `mix` | Mix | 0 | 1 | 1 | gain |
| 4 | `out` | Output | -12 | 12 | -2 | dB |

## Deesser  (effect, VST3 code `Dsr1`)

| # | ID | Name | Min | Max | Default | Unit |
|---|----|------|-----|-----|---------|------|
| 0 | `freq` | Frequency | 1000 | 12000 | 6500 | Hz |
| 1 | `threshold` | Threshold | -60 | 0 | -32 | dB |
| 2 | `range` | Range | -36 | 0 | -18 | dB |
| 3 | `release` | Release | 10 | 500 | 80 | ms |
| 4 | `listen` | Listen | 0 | 1 | 0 | bool |

## Delay  (effect, VST3 code `Dly1`)

| # | ID | Name | Min | Max | Default | Unit |
|---|----|------|-----|-----|---------|------|
| 0 | `timeL` | Time L | 1 | 2000 | 250 | ms |
| 1 | `timeR` | Time R | 1 | 2000 | 375 | ms |
| 2 | `feedback` | Feedback | 0 | 0.95 | 0.42 | gain |
| 3 | `filter` | Filter | 200 | 18000 | 3200 | Hz |
| 4 | `mix` | Mix | 0 | 1 | 0.28 | gain |
| 5 | `pingpong` | Ping-Pong | 0 | 1 | 1 | bool |
| 6 | `bass` | Bass Cut | 20 | 1200 | 120 | Hz |
| 7 | `wobble` | Wobble | 0 | 1 | 0 | gain |
| 8 | `wobrate` | Wob Rate | 0.02 | 12 | 1 | Hz |
| 9 | `warmth` | Warmth | 0 | 1 | 0.35 | gain |

## Drums  (instrument, VST3 code `Drm1`)

| # | ID | Name | Min | Max | Default | Unit |
|---|----|------|-----|-----|---------|------|
| 0 | `gain` | Gain | -24 | 12 | 0 | dB |

## BassMitStimme  (instrument, VST3 code `Bms1`)

| # | ID | Name | Min | Max | Default | Unit |
|---|----|------|-----|-----|---------|------|
| 0 | `oct` | OSC Oct | -2 | 2 | 0 | — |
| 1 | `det` | Detune | -50 | 50 | 6 | — |
| 2 | `sub` | Sub | 0 | 1 | 0.7 | — |
| 3 | `fmA` | FM Growl | 0 | 1 | 0 | — |
| 4 | `fmR` | FM Ratio | 0.25 | 8 | 1.5 | — |
| 5 | `noi` | Noise | 0 | 1 | 0 | — |
| 6 | `cut` | Cutoff | 20 | 18000 | 600 | — |
| 7 | `res` | Reso | 0 | 1 | 0.25 | — |
| 8 | `env` | Env Amt | -1 | 1 | 0.4 | — |
| 9 | `aA` | Amp A | 0.001 | 4 | 0.005 | — |
| 10 | `aD` | Amp D | 0.001 | 4 | 0.18 | — |
| 11 | `aS` | Amp S | 0 | 1 | 0.7 | — |
| 12 | `aR` | Amp R | 0.001 | 4 | 0.32 | — |
| 13 | `fA` | Filt A | 0.001 | 4 | 0.002 | — |
| 14 | `fD` | Filt D | 0.001 | 4 | 0.2 | — |
| 15 | `fS` | Filt S | 0 | 1 | 0.5 | — |
| 16 | `fR` | Filt R | 0.001 | 4 | 0.4 | — |
| 17 | `gain` | Gain | 0 | 2 | 1 | — |
| 18 | `glide` | Glide | 0 | 1000 | 45 | — |
| 19 | `mode` | Mode | 0 | 2 | 1 | — |
| 20 | `stmOn` | Stimme | 0 | 1 | 1 | — |
| 21 | `stmPitch` | Pitch | -24 | 24 | 0 | — |
| 22 | `stmMix` | Mix | 0 | 1 | 0.55 | — |
| 23 | `stmFollow` | Follow | 0 | 1 | 1 | — |
| 24 | `stmMode` | Mode | 0 | 2 | 2 | — |
| 25 | `stmDrive` | Drive | 0 | 1 | 0 | — |
| 26 | `stmTone` | Tone | 0 | 1 | 0.5 | — |
| 27 | `stmAir` | Air | 0 | 1 | 0 | — |
| 28 | `stmShimmer` | Shimmer | 0 | 1 | 0 | — |
| 29 | `stmReverb` | Reverb | 0 | 1 | 0 | — |
| 30 | `stmDist` | Distortion | 0 | 1 | 0 | — |

## Handy  (instrument, VST3 code `Hnd1`)

| # | ID | Name | Min | Max | Default | Unit |
|---|----|------|-----|-----|---------|------|
| 0 | `hf` | HF Restore | 0 | 1 | 0.65 | gain |
| 1 | `nr` | Noise Rdx | -40 | 0 | -18 | dB |
| 2 | `tr` | Transient | -1 | 1 | 0.3 | gain |
| 3 | `wa` | Warmth | 0 | 1 | 0.4 | gain |
| 4 | `lv` | Level | -24 | 12 | 0 | dB |
| 5 | `mx` | Mix | 0 | 1 | 1 | gain |
| 6 | `pt` | Pitch | -24 | 24 | 0 | — |

## BigKnob  (effect, VST3 code `Bgk1`)

| # | ID | Name | Min | Max | Default | Unit |
|---|----|------|-----|-----|---------|------|
| 0 | `knob` | Big Knob | 0 | 1 | 0.5 | gain |
| 1 | `dist` | Distortion | 0 | 1 | 0 | gain |

## SynthThing  (instrument, VST3 code `Snt1`)

**No host-automatable parameters.** All state lives in the sequencer grid / preset system,
persisted via the AU's `fullState`. See PORTING.md § Known gaps.

## Limiter  (effect, VST3 code `Lim1`)

| # | ID | Name | Min | Max | Default | Unit |
|---|----|------|-----|-----|---------|------|
| 0 | `inputGain` | Input Gain | -12 | 24 | 0 | dB |
| 1 | `ceiling` | Ceiling | -12 | 0 | -1 | dB |
| 2 | `release` | Release | 1 | 1000 | 80 | ms |

## VoiceBox  (effect, VST3 code `Vbx1`)

| # | ID | Name | Min | Max | Default | Unit |
|---|----|------|-----|-----|---------|------|
| 0 | `atOn` | Tune On | 0 | 1 | 0 | — |
| 1 | `atSpeed` | Retune Spd | 0 | 1 | 0.3 | — |
| 2 | `atAmt` | Tune Amount | 0 | 1 | 1 | — |
| 3 | `hmOn` | Harm On | 0 | 1 | 0 | — |
| 4 | `hmSemi` | Harm Semis | -24 | 24 | 7 | — |
| 5 | `hmMix` | Harm Mix | 0 | 1 | 0.4 | — |
| 6 | `skOn` | Skip On | 0 | 1 | 0 | — |
| 7 | `skRate` | Skip Rate | 0.5 | 16 | 4 | — |
| 8 | `skAmt` | Skip Amt | 0 | 1 | 0.5 | — |
| 9 | `dlOn` | Delay On | 0 | 1 | 0 | — |
| 10 | `dlTime` | Delay Time | 1 | 1000 | 250 | — |
| 11 | `dlFb` | Delay FB | 0 | 0.95 | 0.35 | — |
| 12 | `chOn` | Chop On | 0 | 1 | 0 | — |
| 13 | `chRate` | Chop Rate | 0.1 | 24 | 8 | — |
| 14 | `chDepth` | Chop Depth | 0 | 1 | 0.8 | — |
| 15 | `vcOn` | Vocoder On | 0 | 1 | 0 | — |
| 16 | `vcTone` | Voc Tone | 0 | 1 | 0.5 | — |
| 17 | `vcMix` | Voc Mix | 0 | 1 | 0.7 | — |
| 18 | `rvOn` | Reverb On | 0 | 1 | 0 | — |
| 19 | `rvSize` | Verb Size | 0 | 1 | 0.5 | — |
| 20 | `rvMix` | Verb Mix | 0 | 1 | 0.3 | — |
| 21 | `hmAuto` | Harm Auto | 0 | 1 | 0 | — |
| 22 | `atScale` | Tune Scale | 0 | 2 | 0 | — |

## UltraReverse  (effect, VST3 code `Urv1`)

| # | ID | Name | Min | Max | Default | Unit |
|---|----|------|-----|-----|---------|------|
| 0 | `reverse` | Reverse | 0.1 | 4 | 0.6 | s |
| 1 | `size` | Size | 0 | 1 | 0.7 | gain |
| 2 | `decay` | Decay | 0.3 | 30 | 4 | s |
| 3 | `shimmer` | Shimmer | 0 | 1 | 0.3 | gain |
| 4 | `diffusion` | Diffusion | 0 | 1 | 0.6 | gain |
| 5 | `texture` | Texture | 0 | 1 | 0.7 | gain |
| 6 | `predelay` | Predelay | 0 | 300 | 20 | ms |
| 7 | `tone` | Tone | 0 | 1 | 0.5 | gain |
| 8 | `mix` | Mix | 0 | 1 | 0.4 | gain |

## StringThing  (instrument, VST3 code `Str1`)

**No host-automatable parameters.** All state lives in the sequencer grid / preset system,
persisted via the AU's `fullState`. See PORTING.md § Known gaps.

## PitchKnob  (effect, VST3 code `Ptk1`)

| # | ID | Name | Min | Max | Default | Unit |
|---|----|------|-----|-----|---------|------|
| 0 | `knob` | Pitch | 0 | 1 | 0.5 | gain |
| 1 | `filter` | Filter | 0 | 1 | 0.5 | gain |

## RoarBass  (instrument, VST3 code `Roar`)

| # | ID | Name | Min | Max | Default | Unit |
|---|----|------|-----|-----|---------|------|
| 0 | `osc1Oct` | OSC1 Octave | -2 | 2 | 0 | oct |
| 1 | `osc2Oct` | OSC2 Octave | -2 | 2 | 0 | oct |
| 2 | `osc2Det` | OSC2 Detune | -50 | 50 | 7 | cents |
| 3 | `oscMix` | OSC Mix | 0 | 1 | 0.5 | — |
| 4 | `sub` | Sub Level | 0 | 1 | 0.7 | gain |
| 5 | `fmAmt` | FM Growl | 0 | 1 | 0.25 | gain |
| 6 | `fmRatio` | FM Ratio | 0.25 | 8 | 1 | ratio |
| 7 | `fmFb` | FM Feedback | 0 | 1 | 0.2 | gain |
| 8 | `nz` | Noise Level | 0 | 1 | 0 | gain |
| 9 | `nzColor` | Noise Colour | 0 | 1 | 0.7 | — |
| 10 | `cut` | Filter Cutoff | 20 | 18000 | 700 | Hz |
| 11 | `res` | Resonance | 0 | 1 | 0.25 | gain |
| 12 | `drv` | Filter Drive | 0 | 1 | 0.2 | gain |
| 13 | `fEnv` | Filter Env Amt | -1 | 1 | 0.4 | gain |
| 14 | `aA` | Amp Attack | 0.001 | 4 | 0.005 | s |
| 15 | `aD` | Amp Decay | 0.001 | 4 | 0.2 | s |
| 16 | `aS` | Amp Sustain | 0 | 1 | 0.85 | gain |
| 17 | `aR` | Amp Release | 0.001 | 4 | 0.3 | s |
| 18 | `fA` | Filter Attack | 0.001 | 4 | 0.005 | s |
| 19 | `fD` | Filter Decay | 0.001 | 4 | 0.4 | s |
| 20 | `fS` | Filter Sustain | 0 | 1 | 0.4 | gain |
| 21 | `fR` | Filter Release | 0.001 | 4 | 0.3 | s |
| 22 | `glide` | Glide | 0 | 1 | 0 | s |
| 23 | `vmode` | Voice Mode | 0 | 1 | 0 | indexed |
| 24 | `mg` | Master Gain | 0 | 2 | 0.9 | gain |
| 25 | `dOut` | Output Drive | 0 | 1 | 0.1 | gain |
