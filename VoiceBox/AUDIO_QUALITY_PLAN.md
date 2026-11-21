# VoiceBox: Audio Quality Plan (AUTOTUNE and the other pitch effects)

Date: 2026-11-20. Status: audit and research only. No source file was changed.

> **Update 2026-11-21 — sound-quality pass.** The plan below was implemented on 2026-11-20
> (MPM + PSOLA). On 2026-11-21 the result was measured on glottal-pulse test voices and on real
> vocal stems and several defects were fixed (grain pile-up bursts, period jitter from the
> pitch marks, tracker stuck on a wrong octave, vocoder / STFT-fallback / reverb gain staging,
> the tanh output knee, hard effect switches). Harness: `Tests/sq/run_sq.sh`, table:
> `python3 Tests/sq/table.py`, end-to-end AU test: `Tests/sq/run_e2e.sh`. Summary in
> `HANDOFF.md` (2026-11-21 section). §1 below describes the code BEFORE both passes.

Scope: `VoiceBoxExtension/DSP/*` and `VoiceBoxExtension/VoiceBoxAudioUnit.mm`.
Licence constraint: closed binary, so only MIT / BSD / Apache-2.0 / zlib / ISC / Boost / public domain.
Every licence below was read from the repository's own LICENSE file on 2026-11-20 (via `gh api repos/<repo>/license`
or the raw file on Codeberg).

---

## 0. Summary

The poor sound has three main causes. Two of them are plain bugs, not limits of the algorithm.

1. **A phase-accumulator precision bug in the shared phase-vocoder shifter.** It affects AUTOTUNE, the HiFi
   harmonizer and LOW TUNER. `sumPhase_` is a `float` that grows without bound (`PitchShifterHQ.hpp:114, 201`).
   Within seconds the high bins lose phase precision, and the output turns noisy, rough and "phasey". It gets
   worse the longer the transport runs. Measured: the harmonic-to-noise ratio (HNR) of a clean 200 Hz tone at
   ratio 1.0 falls from 50 dB (t=2 s) to 18 dB (30 s) and 11 dB (3 min). With the accumulator wrapped it stays at
   about 89 dB. This is a one-line fix and the single biggest quick win.
2. **The AUTOTUNE control law is wrong for music.** Scales are always rooted on C, because there is no key
   parameter (`VoiceBoxEngine.hpp:289`). Note decisions have no hysteresis, so a singer near a semitone boundary
   with vibrato flips between two notes twice per vibrato cycle (measured: output pitch SD 41 cents, range −6…+102
   cents). The retune-speed knob only spans 0–26 ms, and 80 % of its travel is under 7 ms, so the knob is
   effectively "robotic" everywhere and vibrato is flattened even at 0.5. Unvoiced sounds (s, sh, breaths) are
   shifted by the last voiced ratio.
3. **The shifter type is wrong for a monophonic voice.** A 1024-point Bernsee phase vocoder with 4× overlap, no
   phase locking, and bin-rounding that collapses or overwrites bins (`PitchShifterHQ.hpp:89-95`) is inherently
   phasey and smeared. Even with the bug fixed, HNR is only about 24 dB at −5 st. Professional monophonic vocal
   tools use pitch-synchronous time-domain processing (PSOLA family). PSOLA keeps formants for free, has no
   phasiness, and runs at low latency and very low CPU.

There are also rack-level bugs: a doubled latency when AUTOTUNE feeds LOW TUNER or the HiFi harmony, stale
buffers and clicks when an effect is engaged, the right channel dropped by AUTOTUNE, and an always-on tanh stage
that adds about −30 to −40 dB of 3rd-harmonic distortion on loud vocals.

**Recommended stack (all permissive):**

| Effect | Pitch detector | Shifter | Formants | Latency @48k |
|---|---|---|---|---|
| AUTOTUNE | McLeod (MPM/NSDF) on vDSP, ported from **sevagh/pitch-detection** (MIT) + in-house tracker (voicing, median, hysteresis) | **In-house TD-PSOLA**, fractional resampling via **Signalsmith DSP** `delay.h` (MIT) | inherent to PSOLA | 768 samples (16 ms, unchanged) |
| HARMONIZER | shared with AUTOTUNE | extra PSOLA synthesis voice (shared pitch marks); STFT fallback for >12 st or unvoiced | inherent / cepstral in fallback | 768 |
| LOW TUNER | shared | PSOLA for 0…−12 st; fixed STFT shifter below −12 st | inherent / cepstral | 768 |
| PITCH-SKIP | shared | PSOLA voice (clean jumps); keep old delay-line shifter only as "LO-FI" | inherent | 768 |
| STFT fallback | – | fixed `PitchShifterHQ` (phase wrap, vDSP, envelope-first, interpolated bin map, phase locking), using **stftPitchShift** (MIT) as the reference or vendored core | cepstral, envelope-first | 768 |

---

## 1. Audit findings

### 1.1 Signal flow today

`VoiceBoxAudioUnit.mm:276-287` calls `VoiceBoxEngine::processFrame()` once per sample. The order is:
AUTOTUNE (mono, from L) → LOW TUNER → VOCODER → HARMONIZER → PITCH-SKIP → DELAY → CHOP → tanh glue + 15 kHz LP →
REVERB → clamp (`VoiceBoxEngine.hpp:432-539`). The reported latency is a constant 768 samples
(`VoiceBoxEngine.hpp:430`, `VoiceBoxAudioUnit.mm:218-221`).

Three objects use the same `PitchShifterHQ` (Bernsee phase vocoder): `autotune_.shifter`, `hq_` (harmony) and
`low_` (LOW TUNER). PITCH-SKIP, and the harmonizer's unused fallback, use the cheap two-tap delay-line
`PitchShifter`.

### 1.2 AUTOTUNE (`VoiceBoxEngine.hpp:255-372`)

| # | What it does now | Why it sounds bad | Where |
|---|---|---|---|
| A1 | YIN-style CMND on a 1536-sample window, recomputed every 256 samples, with a direct O(N·lag) difference function | Detection is accurate on clean vowels (my test had 0 gross errors from 80 Hz to 1 kHz), so it is **not** the main problem. It costs about **7 % of one core** for one mono voice (measured), and it returns no confidence value that could drive voiced/unvoiced logic. | 302-349, loop 315-319 |
| A2 | Fallback: if no trough is below 0.15, it takes the global minimum and accepts it up to 0.4 | Weakly periodic frames (breath, reverb tails, consonant onsets) are accepted as pitched, so the correction jumps on garbage | 333-337 |
| A3 | Unvoiced or silent frames: `analyze()` returns early and **holds the last ratio** | s, sh, t and breaths are pitch-shifted by the previous note's correction, giving a phasey, metallic sibilance. Nothing fades the correction toward 0 when the voice stops. | 307, 353 |
| A4 | `snapToScale()` builds candidates as `(n/12+oct)*12 + degree` | **Scales are always C major or C minor.** There is no key-root parameter (`VoiceBoxAudioUnit.mm:28-55`, UI pill `VoiceBoxParameterView.swift:249` cycles only CHROM/MAJ/MIN). In any other key, MAJ/MIN pull notes to wrong pitches. | 280-297 (289) |
| A5 | Nearest-note snap with no hysteresis, every 5.3 ms | Near a boundary, vibrato makes the target flip back and forth (warble or yodel). Measured with input +30 c ±30 c vibrato, hard tune: output mean +31 c, SD 41 c, range −6…+102 c. Centred input (0 c ±30 c) is fine (SD 3.8 c). | 281, 292-293, 366 |
| A6 | Retune speed: `glide = 0.5·0.0016^speed` per sample, applied to the ratio | Time constant: speed 0 → 0.03 ms, 0.3 (default) → 0.3 ms, 0.5 → 1 ms, 0.8 → 7 ms, 1.0 → 26 ms. Pro tools span 0–400 ms, with "natural" around 20–100 ms. So the knob is a switch, and vibrato is flattened even at 0.5 (measured output SD 5.5 c for 21 c-RMS input vibrato). The phase vocoder also reads the ratio only once per 256-sample hop, so the glide is stepped. | 368-369, PV reads ratio at frame boundary `PitchShifterHQ.hpp:54-55` |
| A7 | No humanize, no note-transition handling, no formant or throat control | Long notes sound frozen and "robotic" even when the user wants natural correction | – |
| A8 | Mono: `autotune_.process(L)`, then L=R=corrected | The right channel is discarded. A stereo vocal or an off-centre source loses content. | 436-439 |
| A9 | Shifter = `PitchShifterHQ` (see 1.3) | Every flaw in 1.3 applies | 264, 370 |

### 1.3 `PitchShifterHQ` (shared phase vocoder, `PitchShifterHQ.hpp`)

| # | Finding | Effect | Where |
|---|---|---|---|
| P1 | **`sumPhase_` is `float` and never wrapped.** Bin k advances about k·π/2 rad per hop, so bin 512 gains about 150 000 rad/s. Float resolution at 2^20 rad is 0.125 rad and at 2^22 rad it is 0.5 rad. | Progressive phase noise in mid and high bins: the output gets rough and noisy within seconds and keeps degrading. Measured HNR at ratio 1.0 (no formant step): 50 → 32 → 18 → 11 dB at 2 / 10 / 30 / 180 s. At 0.75 with formants: 23.7 → 14.1 → 3.6 dB. After wrapping (`remainder(sum+tmp, 2π)`): 90 → 86 dB and a flat 23.8 dB. | 114, 201 |
| P2 | Bin mapping `idx = round(k·ratio)`: magnitudes are summed but `synFreq_[idx]` is **overwritten** by the last bin | For ratio < 1 several bins collapse and keep the wrong frequency (roughness, beating). For ratio > 1 there are empty bins (holes). Even with P1 fixed, HNR is only about 24 dB at −5 st and −12 st. | 89-95 (90, 93) |
| P3 | Formant correction is computed on the **shifted** spectrum (`shiftEnv_`), divided into the original envelope, and clamped to ±12 dB. `log(max(mag,1e-6))` puts −13.8 into every empty bin. | The holes from P2 drag the cepstral envelope down, so the correction over-boosts (clamped at 4×) and adds noise. Shifts beyond about ±12 dB of envelope change are only partly corrected. The correct order is to remove the envelope first, shift the excitation, then re-apply the envelope (as stftPitchShift does). | 98-104, 102, 148 |
| P4 | No phase locking (vertical phase coherence) | The classic phase-vocoder "phasiness" or "reverberant" voice, and smeared consonant transients | 107-118 |
| P5 | Fixed sizes in samples: frame 1024, 4× overlap, lifter of 40 samples | At 96 kHz the frame is 10.7 ms and the bins are 94 Hz wide (low male voices smear). The lifter cutoff is 0.83 ms at 48 kHz but changes with sample rate. 4× is the minimum overlap. | 28-31, 151 |
| P6 | Home-made radix-2 FFT with bit reversal and `cos/sin` on every call, 5 complex FFTs per hop (analysis, 2 for each cepstrum, synthesis) | CPU about 1.1 % per instance (measured), while Accelerate is already linked. Not a quality problem, but it limits the overlap. | 160-193 |
| P7 | Symmetric Hann `(kFrame-1)` instead of periodic | A small constant-overlap-add (COLA) ripple (minor) | 139 |
| P8 | Header says "public-domain" | Bernsee's smbPitchShift is under the **Wide Open License (WOL)**: "provided that the above copyright notice and this license appear in all source copies" (verified at blogs.zynaptiq.com/bernsee/repo/smbPitchShift.cpp). Add the notice to the source. | 5-6 |

### 1.4 HARMONIZER and SmartHarmony (`VoiceBoxEngine.hpp:178-243, 467-484`)

- The HiFi path (`harmHiFi_ = true`, line 555) uses `hq_`, so P1–P7 apply.
- **Double latency with AUTOTUNE on:** `hq_.process(autoOn_ ? x : rawIn[0], ratio)` (478). With AUTOTUNE on, `x` is
  already 768 samples late, so the harmony comes out 1536 samples late. That is 16 ms behind the lead voice and
  not reported to the host.
- SmartHarmony's pitch is a **raw (unnormalised) autocorrelation with integer lag** (214-221). On clean synthetic
  vowels it was mostly right (2 % wrong notes for 90–180 Hz with F1=700 Hz, all of them too high). The integer lag
  quantises the pitch, though: up to ±11 c at 600 Hz, so the auto-harmony lands up to that much out of tune.
- It analyses only every 2048 samples (43 ms) over a 43 ms window (190), then glides (191). At every note change
  the harmony sits on the wrong interval for roughly 40–90 ms. It has no voicing gate beyond an energy threshold.
- The key is detected (Krumhansl, 229-238), but AUTOTUNE does not use it (see A4).

### 1.5 LOW TUNER (`VoiceBoxEngine.hpp:419-421, 457-460`)

- It uses `low_` (PitchShifterHQ), so P1–P7 apply. P2 is worst here because ratios down to 0.25 (−24 st)
  collapse 4 bins into 1.
- **Double latency with AUTOTUNE on** (458), same as the harmony. With `lowMix < 1`, the dry signal (768 samples
  late) is mixed with the shifted signal (1536 samples late), which gives a 16 ms flam or comb.
- Unvoiced sounds are shifted down too, which gives "muddy" sibilants.

### 1.6 PITCH-SKIP (`VoiceBoxEngine.hpp:32-66, 487-499`)

- It uses a two-tap crossfading delay line with a 60 ms window. The two taps are about 30 ms apart and summed,
  which produces comb filtering and doubling, plus a tremolo or warble at |1−ratio|/60 ms (for example 16.7 Hz at
  +12 st). A one-pole LP with a = 0.7 (about 9 kHz) dulls the top end (63). It is fine as a "lo-fi" character
  effect, but it is not clean.

### 1.7 Rack-level issues

| # | Finding | Where |
|---|---|---|
| R1 | **Stale state on engage.** Shifters and detectors run only while their effect is on. Re-engaging replays the old FIFO contents (up to 768 samples of old audio plus stale phase), and the switch between `latDly_` and the processed path is hard, with no crossfade, so you hear clicks. `setAutotune/setLow/setHarmonizer` never reset anything. | 411-422, 436-448, 457, 478 |
| R2 | Latency is constant at 768 samples regardless of sample rate, and the LatDelay is a fixed 768-sample array | 430, 545-549 |
| R3 | Always-on `tanh(0.7x)/0.7`. Third harmonic: about −40 dB at −6 dBFS peak, about −30 dB at −1 dBFS. That is audible grit on loud vocals. | 529 |
| R4 | Always-on one-pole LP at 15 kHz: −1.1 dB at 10 kHz, −2 dB at 16 kHz. It takes the "air" out of the voice. | 383, 530 |
| R5 | Per-sample `processFrame` with branches for each effect, which prevents block or SIMD processing (CPU only) | `.mm` 276-287 |

### 1.8 Non-pitch side notes (outside the licence question, for completeness)

- VOCODER: the envelope follower has an attack coefficient of 0.40 and a release of 0.015 per sample, which is a
  release time constant of about **1.4 ms** (108). It follows individual cycles in the low bands, giving AM buzz
  and grit. The carrier is `tanh(voice)` (100), not a real oscillator, and there is no noise carrier for unvoiced
  bands, so consonants are unintelligible. Fix: 2–5 ms attack and 20–60 ms release, and a saw/pulse carrier at the
  tracker's f0 plus a noise carrier gated by the new voicing flag.
- REVERB is a minimal Freeverb (4 combs and 2 all-passes per channel). If it is upgraded later,
  Signalsmith-Audio/basics `reverb.h` and `limiter.h` (MIT, "Copyright 2022-2025 Signalsmith Audio / Geraint
  Luff") are drop-in candidates.

### 1.9 Measurements (offline harness, 48 kHz, Apple-silicon CLT clang -O2)

| Test | Current | Fixed / candidate |
|---|---|---|
| HQ shifter, ratio 1.0, harmonic tone, HNR at 2 s / 30 s / 180 s | 50.2 / 18.1 / 11.2 dB | phase wrapped: 90.0 / 89.8 / 86.0 dB |
| HQ shifter, ratio 0.75 + formants, HNR at 2 s / 60 s / 180 s | 23.7 / 8.4 / 3.6 dB | phase wrapped: 23.7 / 23.8 / 23.8 dB |
| HQ shifter, ratio 1.10 + formants, HNR at 2 s / 45 s | 38.6 / 8.7 dB | phase wrapped: 39.3 dB steady |
| Autotune hard, input +30 c ±30 c vibrato: output SD / range | 41 c / −6…+102 c (note flipping) | target: < 5 c with hysteresis |
| Autotune YIN + HQ CPU, one mono voice | 7.98 % of one core (YIN about 7 %) | target < 1 % (MPM on vDSP + PSOLA) |
| stftPitchShift 2.0, sine pitch error, ratios 0.5–1.1 | – | ±0.3 c (accurate) |
| stftPitchShift HNR, frame 1024/hop 256 at 0.75 | – | 15.1 dB (frame 2048/256: 28.6 dB, at 0.5: 31.1 dB) |
| Signalsmith Stretch 1.3.2, sine pitch error | – | **+27 c** (ratio 0.75, block 2048), **+32 c** (+1 st), +14 c with `presetDefault` |

The harness source is in Appendix A so the numbers can be reproduced.

---

## 2. Recommended stack per effect

### 2.1 AUTOTUNE (priority 1)

**Pitch detector: McLeod Pitch Method (NSDF), ported from sevagh/pitch-detection to Accelerate vDSP.**
- Repo: https://github.com/sevagh/pitch-detection (`src/mpm.cpp` 4.5 KB, `src/autocorrelation.cpp` 1.7 KB,
  `src/parabolic_interpolation.cpp` 1 KB, `include/pitch_detection.h`).
- Licence (verified, `LICENSE`): **MIT**: "MIT License / Copyright (c) 2018 Sevag Hanssian / Permission is hereby
  granted, free of charge, to any person obtaining a copy of this software…"
- Port only MPM and its helpers. Replace FFTS with `vDSP_fft_zrip` (Accelerate is already linked in
  `project.yml`). Use the `pitch_alloc::Mpm` pattern (buffers preallocated in `prepare()`). Do **not** take the
  pYIN path, because it pulls in mlpack/armadillo and allocates.
- Settings: window 2048 at 48 kHz (scales with sr, at least 2 periods at 60 Hz), hop 128 (2.7 ms), range
  75–1100 Hz. Output: f0 plus clarity (NSDF peak, 0–1) as the voicing confidence.
- CPU estimate: 2 real FFTs of 4096 points per 128 samples, about 0.3–0.8 % of one M1 core. The current code
  measures about 7 %.
- Alternative (if lower latency or better robustness is needed): **cycfi/q** `q/pitch/pitch_detector.hpp`
  (bitstream autocorrelation, per-sample streaming, built-in periodicity and octave handling). Licence verified
  (`LICENSE`): **MIT**: "MIT License / Copyright (c) 2014-2026 Joel de Guzman". Its dependency cycfi/infra has no
  LICENSE file, but its headers state "Distributed under the MIT License". Needs **C++20** (`std::span`); the
  project is set to `c++17` in `project.yml`. About 25 headers, roughly 150 KB.

**Tracker layer (in-house, about 150 lines, no licence issue):**
- Voicing gate with hysteresis: voiced when clarity > 0.85 and RMS > −50 dBFS; unvoiced when clarity < 0.7 for
  more than 15 ms.
- Median of 5 on f0 in cents. Reject octave jumps (> ±10 st) unless they persist for 3 hops.
- Note decision with hysteresis: change the target only when the input is more than 15 c past the midpoint, or
  past it for more than 30 ms.
- Scale and key: root 0–11 × {chromatic, major, minor} (more modes later).
- The correction lives in cents: `corr = amount · smooth_τ(target − input)`, `ratio = 2^(corr/1200)`.
- On unvoiced frames the correction glides to 0 c over 10 ms, so consonants and breaths pass through untouched.

**Shifter: in-house TD-PSOLA (pitch-synchronous overlap-add), about 400 lines.**
- No maintained, permissively licensed, real-time C++ PSOLA library exists (checked: GitHub "psola" search. The
  C++ hits are unlicensed or unrelated, `maxrmorrison/psola` is GPL-3.0, and the rest are Python). The algorithm
  itself is free to implement: Moulines & Charpentier 1990, with the PSOLA patents from 1989–90 long expired.
- Structural reference: https://github.com/sannawag/TD-PSOLA (Python, about 100 lines). Licence verified
  (`LICENSE`): **MIT**: "MIT License / Copyright (c) 2019 Sanna Wager". If any code is transcribed, keep that
  notice.
- Method:
  - Find pitch marks (epochs) per voiced period: the largest-magnitude extremum within ±T/2 of the predicted
    mark, refined by the tracker's T.
  - Analysis grains: Hann window, 2T long, centred on each mark.
  - Synthesis marks spaced T/ratio, with the position kept in **double** and **fractional**. A grain at a
    fractional offset is read with an interpolator. Without this, integer-period quantisation at 400 Hz
    (T=120 samples) is a 14 c step, which kills small corrections.
  - Pick the nearest analysis grain for each synthesis mark (repeat or skip), overlap-add, and normalise by the
    window sum.
  - Unvoiced frames: fixed 5 ms grains at ratio 1, so the signal passes through.
- Fractional reads: **Signalsmith DSP** `delay.h` interpolators (Kaiser-sinc or cubic), header-only, C++11.
  Repo: https://github.com/Signalsmith-Audio/dsp (v1.7.3, `delay.h` 23 KB, `windows.h` 8 KB, `common.h`).
  Licence verified (`LICENSE.txt`): **MIT**: "MIT License / Copyright (c) 2021 Geraint Luff / Signalsmith Audio
  Ltd."
- Formants: preserved by construction, since each grain keeps the vocal-tract response, which is ideal for the
  ±1–3 st autotune moves. An optional "throat" or formant control can resample each grain by a factor φ before
  overlap-add, at negligible cost.
- Latency: needs one maximum period of lookahead (sr/75 Hz = 640 samples). The **reported latency stays 768
  samples at 48 kHz** (16 ms), so there is no change for hosts or sessions. Make it sample-rate aware:
  `L = ceil(0.016·sr)`.
- CPU estimate: about 4–8 multiply-adds per sample plus interpolation, about 0.1–0.3 % of a core per voice.

### 2.2 HARMONIZER

- Shares the detector, tracker and **pitch-mark list** with AUTOTUNE. Each harmony is just another PSOLA synthesis
  pass over the same analysis grains (about 0.2 % CPU per voice).
- Fixed interval: `ratio_h = 2^(semis/12) · ratio_autotune` (product of ratios), applied to the **raw** input
  grains. Do not chain it after the corrected signal. This removes the 1536-sample double latency.
- AUTO (in-key): SmartHarmony's ACF is replaced by the shared tracker, which gives interpolated f0, a voicing flag
  and 2.7 ms updates instead of 43 ms. The harmony target is computed per note from the key root and scale
  (shared with AUTOTUNE). Optional auto-key keeps the Krumhansl correlation, fed once per detected note.
- For |interval| > 12 st, or when clarity is low (breathy, polyphonic or noisy input), crossfade over 10 ms to the
  STFT fallback (2.5). It runs at the same latency.

### 2.3 LOW TUNER

- 0…−12 st: a PSOLA voice. A clean octave-down with formants intact; this is how vocal octavers work.
- −12…−24 st: PSOLA output gets buzzy because grains are spaced 4T apart, so use the fixed STFT fallback (2.5),
  envelope-first, with a 1 ms lifter. Alternatively, clamp the parameter to −12 (an existing session with values
  below −12 would then be clipped; decide with the owner).
- Unvoiced: keep the consonant dry rather than shifting noise down. Use `lowMix` only on voiced frames, or duck
  the shifted path when clarity is low.

### 2.4 PITCH-SKIP

- Default: a PSOLA voice driven by the sample-and-hold ratio, which gives clean pitch jumps. Use a 5 ms ratio
  ramp at each step to avoid grain-boundary clicks.
- Keep the old `PitchShifter` as an optional "LO-FI" character. Its comb and warble are a sound, not a bug, once
  it is labelled.

### 2.5 STFT fallback shifter: fix `PitchShifterHQ` (also Phase 1 quick wins)

These fixes are in-house and need no new licence. They help immediately, before PSOLA exists:
1. **Wrap the phase accumulator** (P1). Measured +40 to +75 dB of HNR after 30–180 s.
2. Use vDSP real FFTs (P6), then raise the overlap to 8× (hop 128) for the same CPU.
3. Envelope-first formant handling: take the cepstral envelope of the original only, divide it out to get the
   excitation, shift the excitation, then multiply by the original envelope. Set the lifter in ms (1.0–1.5 ms),
   not in samples (P3, P5).
4. Interpolated bin mapping: linearly interpolate both magnitude and true frequency (`k/ratio`). When bins
   collide, keep the frequency of the strongest magnitude (P2).
5. Identity phase locking (Laroche & Dolson 1999): lock the bins around each spectral peak to that peak's phase
   (P4).
6. Periodic Hann window, frame and hop sizes defined in ms (P5, P7).

Reference or vendoring option for steps 3–4: **jurihock/stftPitchShift** v2.0,
https://github.com/jurihock/stftPitchShift (`cpp/StftPitchShift/StftPitchShiftCore.h` with `Vocoder.h`,
`Pitcher.h`, `Cepster.h`, `Resampler.h`, about 20 KB; it accepts a custom FFT through `std::shared_ptr<FFT>`,
which can wrap vDSP). Licence verified (`LICENSE`): **MIT**: "MIT License / Copyright (c) 2022 Juergen Hock".
Measured pitch accuracy is ±0.3 c. Notes:
- It needs **C++20** (`<span>`, `<bit>`).
- `factors(std::vector)` copies a vector, so preallocate and reuse it to stay allocation-free on the audio thread.
- At frame 1024/hop 256 its HNR (about 15 dB at 0.75) is no better than the fixed in-house HQ (about 24 dB). The
  in-house fix list above is therefore the primary route, and stftPitchShift is the reference implementation of
  the envelope-first and resampling steps.

---

## 3. Integration plan

### 3.1 Files

```
VoiceBoxExtension/DSP/
  third_party/
    signalsmith-dsp/        delay.h windows.h common.h (+ LICENSE.txt, VERSION: v1.7.3, commit hash)
    sevagh-mpm/             mpm.cpp→mpm_vdsp.hpp (ported), parabolic_interpolation, LICENSE (MIT, 2018 Sevag Hanssian)
    [optional] cycfi-q/     q/pitch/*, q/utility/{bitset,bitstream_acf,zero_crossing_collector}.hpp,
                            q/fx/{envelope,median,moving_average,signal_conditioner}.hpp, q/support/*, infra/support.hpp
                            + LICENSE (MIT, 2014-2026 Joel de Guzman). Requires C++20.
    [optional] stftpitchshift/ StftPitchShiftCore.h Vocoder.h Pitcher.h Cepster.h Resampler.h Normalizer.h FFT.h
                            + LICENSE (MIT, 2022 Juergen Hock). Requires C++20.
  PitchTracker.hpp          NEW: MPM(vDSP) + voicing + median + octave guard + note hysteresis + key/scale
  Psola.hpp                 NEW: pitch marks, analysis-grain ring, N synthesis voices (autotune/harmony/low/skip)
  PitchShifterHQ.hpp        FIX: §2.5 items 1-6 (keep class name; becomes the STFT fallback)
  VoiceBoxEngine.hpp        REWIRE (below)
VoiceBox/THIRD_PARTY_NOTICES.txt   NEW: all MIT notices, plus the WOL notice for the Bernsee-derived code
VoiceBox/Tests/                    NEW: offline harness (§3.5)
```

Show the third-party notices in the app's About box or in the installer, since MIT requires the notice in
"all copies or substantial portions", which includes the binary distribution.
If cycfi/q or stftPitchShift is taken, set `CLANG_CXX_LANGUAGE_STANDARD: "c++20"` for the extension target in
`project.yml`. Also update `Tools/au_offline/render.sh`, which hard-codes `-std=c++17`.

### 3.2 Functions to replace

| Current | Replacement |
|---|---|
| `AutoTune::detectPitch()` / `analyze()` (`VoiceBoxEngine.hpp:302-361`) | `PitchTracker::push(block)` → `{f0, clarity, voiced, noteTarget}` per 128-sample hop |
| `AutoTune::snapToScale()` (280-297) | `PitchTracker::target(midiF, keyRoot, scale)` with 15 c hysteresis |
| `AutoTune::process()` glide (364-371) | cents-domain one-pole with τ in ms (§3.3), evaluated per hop and interpolated per synthesis mark |
| `AutoTune::shifter` (`PitchShifterHQ`) | `Psola` voice 0 |
| `SmartHarmony::analyze()` (207-242) | shared `PitchTracker`; keep `diatonicUp()` and Krumhansl, fed from the tracker's notes |
| `hq_.process(autoOn_ ? x : rawIn[0], ratio)` (478) | `Psola` voice 1 with `ratio_h·ratio_at` on raw input; STFT fallback for >12 st or low clarity |
| `low_.process(autoOn_ ? x : rawIn[0], lowRatio_)` (458) | `Psola` voice 2 (0…−12 st) / `PitchShifterHQ` (−12…−24), raw input × autotune ratio |
| `skip_[ch].process()` (497) | `Psola` voice 3, with `PitchShifter` kept as the LO-FI option |
| `latDly_` (446-447, 545-549) | dry path delayed by `L = ceil(0.016·sr)` samples, sized in `prepare()` |
| on/off handling (411-422, 436-448) | engines always run (or `reset()` + 1 hop of pre-roll on engage), with a 10 ms equal-power crossfade between dry-delayed and processed |
| AUTOTUNE mono from L (437) | analyse the mid signal (L+R)/2 and apply the same grain timing to L and R (stereo PSOLA with shared marks) |
| `tanh(x·0.7)/0.7` + 15 kHz LP (529-530) | linear below −3 dBFS with a soft knee above (or Signalsmith basics `limiter.h`, MIT); LP removed or moved above 20 kHz |

### 3.3 Parameter mapping

AU parameter addresses are part of saved sessions, so **append only**. Never renumber 0–25.

| Address | ID | Range / default | Mapping |
|---|---|---|---|
| 1 | `atSpeed` | 0…1, 0.30 | retune τ = `400^s − 1` ms → 0 ms (hard), 0.3 → 5 ms, 0.5 → 19 ms, 0.7 → 65 ms, 1.0 → 399 ms |
| 2 | `atAmt` | 0…1, 1 | scales the correction in cents (unchanged meaning) |
| 22 | `atScale` | 0…2 (kept) | 0 chromatic, 1 major, 2 minor (later: extend the range for more modes, still append-only values) |
| **26** | `atKey` NEW | 0…11, 0 (C) | key root; also used by harmonizer AUTO. If "auto key" is wanted, add value 12 = AUTO (Krumhansl). |
| **27** | `atHuman` NEW | 0…1, 0 | τ_eff = τ·(1 + 4·humanize·sustain), sustain = clamp((noteAge − 120 ms)/200 ms, 0, 1). Short notes snap and long notes breathe. |
| **28** | `atFormant` NEW (optional) | −12…+12 st, 0 | PSOLA grain-resample factor (throat), shared by LOW TUNER and harmony |
| 24 | `lwSemi` | −24…0 | 0…−12 PSOLA; below −12 the STFT fallback |
| internal | – | – | note hysteresis 15 c; voicing thresholds as in §2.1; unvoiced correction release 10 ms |

- Update `kNumParams` and `kSpecs` (`VoiceBoxAudioUnit.mm:17, 28-55`), and add the new columns to every preset
  row (60-72).
- Re-voice the presets after a listening test, because the old speed values map to different times. For example,
  TUNED at 0.10 → 0.8 ms (still hard) and GHOST at 0.55 → 26 ms.
- UI: add a KEY pill next to the SCALE pill (`VoiceBoxParameterView.swift:124, 249`) and a HUMANIZE knob or
  long-press.

### 3.4 Latency reporting

- Compute `L = ceil(0.016·sr)` in `allocateRenderResourcesAndReturnError:` (`VoiceBoxAudioUnit.mm:173-179`). Return
  `L/sr` from `-latency` (218-221), replacing the hard-coded 768.
- Every path (dry, PSOLA voices, STFT fallback, vocoder-only) must come out exactly L samples late, whichever
  effects are on. This is test T7.
- If L ever changes at runtime (for example a future "HQ" mode with a 2048 frame), wrap the change in
  `willChangeValueForKey:@"latency"` and `didChangeValueForKey:@"latency"` so Logic re-reads the delay
  compensation.
- Optionally implement `tailTime` (reverb and delay tails) correctly, since it is unrelated to pitch but often
  confused with latency.

### 3.5 Test plan

Build with the Command Line Tools, because the Xcode licence has not been accepted on this Mac:
`DEVELOPER_DIR=/Library/Developer/CommandLineTools clang++ -O2 -std=c++17 (or c++20) -isysroot $DEVELOPER_DIR/SDKs/MacOSX.sdk …`.
Keep a frozen copy of today's DSP in `VoiceBox/Tests/baseline/` so old and new can always be rendered
side by side.

Synthetic, automated, with pass/fail:

| ID | Test | Pass criterion | Baseline today |
|---|---|---|---|
| T1 | Phase drift: 200 Hz 20-harmonic tone through each shifter at 1.0 / 0.75 / 1.1 for 180 s | HNR(180 s) within 1 dB of HNR(2 s) | 50 → 11 dB |
| T2 | Pitch accuracy: sine at ratios −24, −12, −5, −1, +1, +7, +12 st | error < 1 c (zero-crossing frequency) | – |
| T3 | Hard tune, input +30 c ±30 c vibrato, 5.5 Hz | output SD < 5 c, no target flips | SD 41 c, flips every half cycle |
| T4 | Retune step: input jumps 100 c | 63 % of correction reached at τ ±10 % for s = 0.3/0.5/0.7/1.0 | τ ≤ 26 ms only |
| T5 | Vibrato preservation at s = 0.7 | output vibrato depth ≥ 80 % of input | flattened |
| T6 | Voicing: vowel → 300 ms white noise "sss" → vowel | noise segment unchanged (band energies within 1 dB, no shift) | shifted by the held ratio |
| T7 | Latency: click train, every on/off combination (AT on + HARM, AT on + LOW, etc.) | output click at exactly L samples (±0) | harmony/LOW at 2L with AT on |
| T8 | Toggle each effect every 0.5 s on a sine | max \|Δy\| at toggles < 2× the steady-state max \|Δy\| | hard switch, stale FIFO |
| T9 | CPU: all pitch effects on, 48 kHz stereo | < 3 % of one core | AT alone about 8 % |
| T10 | T1–T7 at 44.1 / 48 / 96 kHz | same pass criteria | sizes fixed in samples |
| T11 | Optional ground truth: compare PSOLA pitch marks with google/REAPER epochs on a real vocal (offline only) | ≥ 95 % of marks within 0.5 ms | – |

Real-vocal A/B:
- Needs a **dry mono acapella** (24-bit WAV, no reverb). None is in the repo today. `AUDIO-2026-05-14-21-59-28.m4a`
  in the project root might be a usable voice memo; otherwise ask the owner for one. Ideally use one male and one
  female take with sustained notes, runs, vibrato and sibilants.
- Render presets CLEAN, TUNED, OCTAVE+, ROBOT, GHOST, FULL, plus LOW −5 / −12 / −24, through old and new into
  `VoiceBox/Tests/renders/` (a durable location, not /tmp). Name them per house rule, for example
  `voicebox_TUNED_old_KJ_v001.wav` / `voicebox_TUNED_new_KJ_v001.wav`.
- For each render also write a pitch-track CSV (from the new tracker) and a spectrogram PNG
  (`ffmpeg -i x.wav -lavfi showspectrumpic=s=1600x600:legend=1 x.png`).
- The owner does a blind A/B. Then run `auval -v aufx …` and a Logic session check (latency compensation with
  autotune on and off; T7 in a real host).

### 3.6 Order of work

1. **Phase 1 (hours, no new code from outside):** P1 phase wrap, R1 reset and crossfade on engage, the
   double-latency fix (feed LOW and harmony from raw input, times the ratio), R3/R4 output stage, `atKey`
   parameter, note hysteresis, and the new retune-speed curve. Run T1, T3, T4, T7, T8.
2. **Phase 2:** `PitchTracker` (MPM on vDSP) with voicing; SmartHarmony uses it. Run T6, T9.
3. **Phase 3:** `Psola.hpp` for AUTOTUNE, then harmonizer, LOW TUNER and PITCH-SKIP voices. `PitchShifterHQ`
   items 2–6 become the fallback. Run all tests and the A/B.
4. **Phase 4:** humanize, formant/throat, vocoder carrier and envelope fix (§1.8), preset re-voicing.

---

## 4. Rejected options

| Option | Licence (verified from the repo's own file) | Reason |
|---|---|---|
| Rubber Band (breakfastquay/rubberband) | `COPYING`: "GNU GENERAL PUBLIC LICENSE Version 2", plus a paid commercial licence | GPL: not usable in a closed binary without buying the commercial licence |
| Autotalent / TalentedHack (jeremysalwen/TalentedHack, LV2 port of Autotalent) | `LICENSE`: GPL-3.0 | GPL |
| x42/fat1.lv2 (Fons Adriaensen's AT1 autotune) | `COPYING`: "GNU GENERAL PUBLIC LICENSE Version 2" | GPL |
| aubio (pitch detection) | `LICENSE`: GPL-3.0 | GPL |
| SoundTouch (codeberg.org/soundtouch/soundtouch) | `COPYING.TXT`: "GNU LESSER GENERAL PUBLIC LICENSE Version 2.1" | LGPL is excluded by the constraint, and its WSOLA shifter is not formant-preserving anyway |
| JUCE (incl. its pitch helpers) | `LICENSE.md`: "dual-licensed under the AGPLv3 and the commercial JUCE licence" | AGPL / paid |
| maxrmorrison/psola | GPL-3.0 (repo metadata) | GPL |
| Surge XT (surge-synthesizer/surge) | GPL-3.0 (repo metadata) | GPL |
| Bungee (bungee-audio-stretch/bungee) | `LICENSE`: "Mozilla Public License Version 2.0" | MPL is not on the allowed list. It is also a polyphonic time-stretcher, not a monophonic vocal shifter. |
| **Signalsmith Stretch** 1.3.2 (Signalsmith-Audio/signalsmith-stretch + Signalsmith-Audio/linear) | `LICENSE.txt`: **MIT** ("Copyright (c) 2022 Geraint Luff / Signalsmith Audio Ltd."; Linear: "MIT License / Copyright (c) 2025 Signalsmith Audio") | **Licence OK, rejected on quality.** Measured steady-state pitch error of +27 c (ratio 0.75, block 2048) and +32 c (+1 st), +14 c with `presetDefault`. Open upstream issues #31, #32, #34 (opened Sep–Oct 2026 by a team doing vocal pitch correction) report the same sharp error and ±7 dB formant mis-levelling. Latency is 43 ms (block 2048) to 120 ms (default). Revisit if those issues are fixed upstream; it would then be the best drop-in polyphonic fallback (CPU about 0.3–0.5 % mono). |
| WORLD vocoder (mmorise/World) | `LICENSE.txt`: modified BSD ("Redistribution and use in source and binary forms … are permitted provided that…"), so **usable** | Rejected on design. DIO/Harvest + CheapTrick + D4C analyse with multi-period windows and are built for offline resynthesis. The latency and CPU don't fit a 16 ms real-time insert, and resynthesis colours the voice. Could serve as an offline reference in tests. |
| google/REAPER (epoch/pitch estimator) | `LICENSE`: Apache License 2.0, so **usable** | Rejected for real time: it is a whole-file dynamic-programming tracker. Use only as ground truth in test T11. |
| sevagh pYIN / probabilistic MPM | MIT, but depends on mlpack (+armadillo) | Heavy dependency and allocates per call. Port MPM only; port pYIN's Viterbi from librosa (ISC, `LICENSE.md`: "ISC License / Copyright (c) 2013--2026, librosa development team") only if real-vocal tests show octave flips. |
| CREPE / neural trackers | (not evaluated for licence) | Latency and CPU are too high for an AUv3 insert, and the model weights would inflate the bundle |
| Keep the current YIN unchanged | in-house | Accurate on clean vowels but costs 7 % CPU and gives no confidence or epochs. Replaced by MPM on vDSP for efficiency and voicing, not because of octave errors. |
| Two-tap delay-line shifter for harmony/skip | in-house | Comb filtering and warble by design. Kept only as the "LO-FI" option. |

---

## Appendix A: reproduction harness (phase-drift test T1)

Save as `VoiceBox/Tests/t1_phase_drift.cpp` and build with
`DEVELOPER_DIR=/Library/Developer/CommandLineTools clang++ -O2 -std=c++17 -isysroot $DEVELOPER_DIR/SDKs/MacOSX.sdk -I ../VoiceBoxExtension/DSP t1_phase_drift.cpp -o t1`.
Run it as `./t1 <ratio> <formant 0|1>`.

```cpp
#include "VoiceBoxEngine.hpp"
#include <cstdio>
#include <vector>
#include <cmath>
using namespace vbx;
// Phase-invariant metric: per 1-s window, project the output onto the expected harmonics
// (integer Hz -> orthogonal over 1 s); report harmonic-to-residual ratio (HNR) in dB.
static double hnr(const std::vector<float>& y, double fout, int H, double sr){
  int N=y.size(); std::vector<double> r(y.begin(),y.end());
  for(int h=1;h<=H;++h){ double f=fout*h; if(f>sr/2-100) break; double c=0,s=0;
    for(int n=0;n<N;++n){ double a=2*M_PI*f*n/sr; c+=r[n]*cos(a); s+=r[n]*sin(a);} c*=2.0/N; s*=2.0/N;
    for(int n=0;n<N;++n){ double a=2*M_PI*f*n/sr; r[n]-=c*cos(a)+s*sin(a);} }
  double E=0,R=0; for(int n=0;n<N;++n){E+=(double)y[n]*y[n]; R+=r[n]*r[n];} return 10*log10((E-R)/(R+1e-30));
}
int main(int argc,char**argv){
  const float sr=48000; double f0=200, ratio=argc>1?atof(argv[1]):1.0; bool form=argc>2&&atoi(argv[2]);
  PitchShifterHQ ps; ps.prepare(sr); ps.setFormantPreserve(form);
  int H=20; long total=(long)(sr*181); std::vector<float> win; win.reserve((int)sr);
  int report[]={2,5,10,20,30,45,60,90,120,180}; int ri=0;
  for(long n=0;n<total;++n){ double t=n/(double)sr,s=0; for(int h=1;h<=H;++h) s+=sin(2*M_PI*f0*h*t)/h;
    float y=ps.process((float)(0.3*s),(float)ratio);
    long sec=n/(long)sr; if(ri<10 && sec==report[ri]) { win.push_back(y); if((int)win.size()==(int)sr){
      printf("ratio %.2f formant %d  t=%3ds  HNR=%6.1f dB\n",ratio,form,report[ri],hnr(win,f0*ratio,H,sr)); win.clear(); ++ri; } } }
}
```

The one-line Phase-1 fix that the harness verifies (`PitchShifterHQ.hpp:114`):

```cpp
// was:  sumPhase_[k] += (float)tmp;
sumPhase_[k] = (float)std::remainder((double)sumPhase_[k] + tmp, 2.0 * M_PI);
```

The other harness tests (vibrato and hysteresis T3, YIN and SmartHarmony error counts, Stretch and stftPitchShift
accuracy) follow the same pattern. They use a synthetic vowel: a −12 dB/oct harmonic source through formant
resonators at 700, 1220 and 2600 Hz, with a 5.5 Hz vibrato. They should be rebuilt in `VoiceBox/Tests/` during
Phase 1.
