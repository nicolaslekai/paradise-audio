# VOICE BOX — Analogue Warmth: Code-Level Implementation Guide

> Research compiled for the VOICE BOX vocal-effect plugin (AUv3, per-sample C++, 48 kHz).
> Use this for the "warming" effect row and the overall analogue character.

## Signal chain (modular, each block bypassable)
```
input → [drive] → [tube/tape waveshaper] → [DC blocker]
      → [tape: hysteresis + head bump + HF rolloff] → [wow/flutter delay-mod]
      → [HF damping] → [noise floor + drift] → [stereo decorrelation] → [out gain]
```
Two principles:
1. **Warmth = low-order harmonics dominated by the 2nd (even).** Even harmonics are octave-related → fuse → "warm/full." Odd (3rd/5th) → "harsh/transistor." Symmetric transfer funcs make only odd; **asymmetry adds the warm even harmonics.**
2. **Every nonlinearity aliases** → must mitigate (ADAA and/or oversampling).

## 1. Saturation transfer functions
- **tanh soft-clip (symmetric → odd):** `y = tanh(drive*x)/tanh(drive)`
- **arctan (gentler, odd):** `y = (2/π)*atan(drive*x)`
- **cubic soft-clip (cheap, odd):** linear then `y = x - x³/3`, clamp to ±2/3 outside ±1
- **ASYMMETRIC = warm even harmonics (the key):**
  - Route A: bias before symmetric shaper → `y = tanh(drive*(x+bias))`, bias 0.05–0.2, **then DC-block**
  - Route B: different slope per polarity, e.g. `x>=0 ? tanh(x) : tanh(0.7*x)`
  - Tube dial: `tubeShape(x,drive,asym) = tanh(drive*x + asym) - tanh(asym)`
- Always add output makeup gain.

## 2. Harmonics + mandatory DC blocker
- Chebyshev for surgical harmonic design: `T2=2x²-1` (pure 2nd), `T3=4x³-3x` (3rd). `y = x + 0.20*T2 + 0.05*T3` = warm.
- **DC blocker after ANY asymmetric stage:** `y = x - x1 + R*y1`. At 48 kHz use **R ≈ 0.9995–0.9997** (~5–12 Hz). (R=0.995 is a 44.1k value, too high.)

## 3. Tape specifics
- **Hysteresis** (stateful B-H loop) = the "real" tape nonlinearity → CHOW Tape Model uses Jiles-Atherton solved per-sample. Pragmatic fake: asymmetric tanh + a one-pole lag on drive.
- **Wow** (slow): 0.1–2 Hz (~0.5 Hz), ±cents..±30 cents. **Flutter** (fast): 4–20 Hz (~6 Hz), ±1–8 cents. Implement as fractional modulated delay line (delay-mod = pitch-mod); sum detuned sines so it isn't a clean chorus.
- **Hiss:** `out += whiteNoise()*~0.0003` (~-70 dBFS), lightly LP'd.
- **Head bump:** peaking EQ fc 40–120 Hz, +1..+4 dB, Q 0.7–1.5.
- **HF rolloff:** LP ~10–16 kHz or high-shelf -1..-4 dB > 8 kHz.

## 4. Anti-aliasing
- **Oversampling:** 2×–4× around the shaper (JUCE dsp::Oversampling). 2–4× enough for gentle tanh/cubic.
- **ADAA (cheaper), 1st order:** `y[n] = (F1(x[n]) - F1(x[n-1])) / (x[n]-x[n-1])`, fallback `f((x[n]+x[n-1])/2)` when `|Δx|<1e-5`. **For tanh: `F1(x)=log(cosh(x))`** (guard large |x| with `≈|x|-log2`). 1st-order ADAA + 2× OS is the sweet spot. Adds 0.5-sample delay (irrelevant feedforward).
  - NOTE: this same log(cosh) ADAA must run the bookkeeping in **double** to avoid float cancellation noise on loud low-freq signals (we hit exactly this bug in the Drums output clipper).

## 5. Analogue imperfections
- Noise floor -75..-90 dBFS (optional faint 50/60 Hz hum at -90).
- Component drift: `drift = drift*0.9999 + noise*0.0001; drive *= (1 + 0.01*drift)` (±0.1–1%).
- Stereo decorrelation: independent noise/drift seeds, independent W&F phase, few-cents detune, sub-ms delay diff per channel. Keep subtle for mono-compat.
- Soft HF damping: high-shelf -1..-3 dB > 10–12 kHz, or one-pole LP `a=exp(-2π fc/fs); y += a*(x-y)`.

## Minimal vocal-warmth build
1. Asymmetric tanh (bias≈0.1) wrapped in 1st-order ADAA (double bookkeeping), optional 2× OS.
2. DC blocker R≈0.9996.
3. Head-bump bell (~80 Hz +2 dB) + HF high-shelf (-2 dB >10 kHz).
4. Subtle W&F (wow 0.5 Hz / flutter 6 Hz, low depth) via fractional delay.
5. Noise floor ~-80 dBFS + per-channel drift + few-cents stereo detune.

## Key sources
- ADAA: Chowdhury (Medium) https://jatinchowdhury18.medium.com/practical-considerations-for-antiderivative-anti-aliasing-d5847167f510 · Parker/Zavalishin/Le Bivic DAFx 2016 http://dafx16.vutbr.cz/dafxpapers/20-DAFx-16_paper_41-PN.pdf · repo https://github.com/jatinchowdhury18/ADAA
- Tape model: CHOW DeepWiki https://deepwiki.com/jatinchowdhury18/AnalogTapeModel · DAFx 2019 http://dafx2019.bcu.ac.uk/papers/DAFx2019_paper_3.pdf
- Saturation/harmonics: gDSP http://gdsp.hf.ntnu.no/lessons/3/18/ · KERN https://kernaudio.io/guides/saturation/what-is-saturation · Waves https://www.waves.com/add-harmonic-distortion-for-analog-warmth
- DC blocker: CCRMA https://ccrma.stanford.edu/~jos/fp/DC_Blocker.html
- W&F/hiss: https://en.wikipedia.org/wiki/Wow_and_flutter_measurement · https://babyaud.io/blog/wow-and-flutter
- Warmth overview: Sound On Sound https://www.soundonsound.com/techniques/analogue-warmth
