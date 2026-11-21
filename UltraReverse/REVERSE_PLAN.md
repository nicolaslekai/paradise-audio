# Ultra Reverse — real reverse: audit, research, implementation plan

Status: plan only, nothing in the source has been changed. Written 2026-11-20.

---

## 1. Audit: what the current "reverse" actually does

Files read: `UltraReverseExtension/DSP/UltraReverse.hpp` (453 lines) and
`UltraReverseExtension/UltraReverseAudioUnit.mm` (171 lines).

### 1.1 Signal flow today

```
in L/R ─▶ mono ─▶ loCut 85 Hz ─▶ preDelay ─▶ ReverseEngine ─┐                     (hpp:297-302)
                                                            │
        src = (1-tex)·mono + tex·2.6·rev ─▶ 6 allpasses ─▶ 8-line FDN (decay 0.3-30 s) + shimmer
                                                            │                     (hpp:306-331)
        wet = FDN taps ─▶ output allpasses ─▶ + 1.8·tex·rev (direct) ─▶ + shimmer ─▶ tilt EQ
                                                                                   (hpp:334-369)
        out = (1-mix)·dry + mix·wet                                                (hpp:371-372)
```

### 1.2 The reverse grain engine (`ReverseEngine`, hpp:124-172)

- Ring buffer of 8.8 s (hpp:132). Two read heads ("grains"), phase-offset by 50 % (hpp:136).
- Per sample, head g reads `wr - (2 + 2·G·p)` (hpp:153). Because `readBehind` grows by
  2 samples per sample while the write head grows by 1, the read head really does walk
  backwards at unity speed. Each grain started at time t0 plays input `[t0-G, t0]` reversed,
  with a delay that sweeps from 0 to 2G across the grain.
- Each grain gets a Hann window over its whole length (hpp:160), and the two grains are summed
  (Hann at 50 % overlap sums to 1).
- The grain clock runs freely from `prepare()`/`reset()`. It knows nothing about tempo, the
  bar grid or note onsets.
- `setReverse()` is called on every render block (mm:156) and changes `grainSamps_` in the
  middle of a grain (hpp:139-141). `readBehind` then jumps, which gives a click or pitch blip
  whenever the REVERSE knob moves.

This is mathematically a correct causal **short-time time reversal (STTR)** with 50 % OLA and a
Hann window: the same structure that Kim & Smith analyse in DAFx-14 (see §2.1). So the audio
*is* reversed. It sounds fake because of everything around the reversal.

### 1.3 Measured behaviour (offline harness, current code compiled unchanged)

Test signal: 440 Hz pluck (60 ms decay), REVERSE = 0.6 s, defaults otherwise.
RMS in 50 ms bins (dB), onset at 1000 ms:

| t (ms) | input | ReverseEngine alone | full wet (Texture .7) | full wet (Texture 0) |
|---|---|---|---|---|
| 1000 | -6.1 | silent | silent | silent |
| 1200 | -35 | -55.8 | -32.4 | -21.8 |
| 1300 | -50 | -20.9 | -19.2 | -24.7 |
| 1350 | -57 | **-9.7** (swell peak, then cut) | -12.5 | -28.9 |
| 1400 | -64 | silent | -28.9 | -29.6 |
| 1600 | -93 | -64 | -23.1 | -27.4 |
| 1900-1950 | silent | **-15.4** (second copy) | -15.6 | -32 |
| 2000-2900 | silent | ≈ silent | -20 … -40 (FDN wash) | -40 … -57 |

Next, the onset was moved through the grain cycle (same pluck):

| onset at | reversed copy 1 (delay / level) | reversed copy 2 (delay / level) |
|---|---|---|
| 1.0 s | 390 ms / -6.8 dB | 980 ms / -14.9 dB |
| 1.1 s | 189 ms / -16.9 dB | 790 ms / -6.6 dB |
| 1.2 s | 589 ms / -4.2 dB | 1080 ms / -29.4 dB |

### 1.4 Why it doesn't sound reversed

1. **The swell never comes before the note.** The reversed copy always lands 190-1090 ms *after*
   the onset. Nothing is reported to the host as latency (no `latency` override in the .mm;
   README:59-62 says this is deliberate), so there is no lookahead. README:59-62 claims the swell
   "appears to anticipate the note". It does not, and causally it cannot.
2. **The reverse has the wrong order for "reverse reverb".** The code does reverb(reverse(x))
   (hpp:302-331): it reverses the *dry* signal and then puts a *forward*, decaying 4 s FDN wash
   plus shimmer after it. A reverse-reverb swell is the *reverb tail* reversed, i.e.
   reverse(reverb(x)), ideally re-aligned so that it ends on the note. On drums the dry reversal is
   only a 50-100 ms swoosh, and the forward wash then smears it straight back into a normal decay.
3. **Random timing, random level.** Every hit is reversed twice, by two overlapping grains. Their
   delay and level (up to 25 dB apart, table above) depend only on where the hit falls in a
   free-running 0.6 s grain clock. The result follows neither tempo nor onsets, so it reads as
   "reverb with wobble" and not as a reverse echo.
4. **Hann windows destroy the gesture.** A reverse is recognisable by its rise and its hard cut on
   the reversed attack. A full-length Hann window fades out right where the attack should hit,
   unless the onset happens to land mid-grain.
5. **It is buried in the mix.** At the defaults (Mix 0.4, Texture 0.7) the reversed direct path is
   1.26·rev·0.4 under 0.6·dry, on top of a continuous FDN wash only about 7-10 dB below the reversed
   peaks (column 4).
6. Minor: the knob changes the grain length mid-grain (hpp:139, mm:156), which clicks. It is mono
   only (hpp:297).

Side findings (not reverse-related, but real bugs):
- `_ownOutBuf` is never sized (declared mm:23, used mm:134, missing in
  `allocateRenderResources` mm:107). A host that passes `mData == NULL` gets
  `kAudioUnitErr_TooManyFramesToProcess` on every render. The Limiter does it right
  (`Limiter/LimiterExtension/LimiterAudioUnit.mm:213`).
- There is no `tailTime` override, although Decay goes up to 30 s, so some hosts may cut tails
  when bouncing.
- All nine setters (pow/exp) are called on every block (mm:156-160), even when nothing changed.
- The README's ranges have drifted from the code: Reverse is "0.10-2.0 s" in the README and
  0.1-4.0 s in code; Decay is "0.3-12 s" in the README and 0.3-30 s in code.

---

## 2. Research: how real reverse effects are built

### 2.1 Reverse delay (zero latency, the reverse comes *after* the note)

The common recipe (KVR "How does reverse delay effect work?", posts by earlevel and Urs Heckmann;
CCRMA EE264 Zhang & Chen 2018; DAFx-14 Kim & Smith) goes like this:
- **Keep your own long buffer and read it backwards.** earlevel (Line 6 DL4 / Echo Farm): the
  read head has to "step two samples to go the same rate in reverse", and "it takes twice as much
  memory per second of delay time".
- **Splice segments together.** Urs Heckmann: reverse delays are "two or more parallel delay lines
  which take turns in filling their buffers in quiet, then play them back backwards aloud …
  two delay lines are sufficient, even when doing some crossfading." The wrap of the read head
  clicks, so earlevel says "crossfade the start/end boundary". Zhang & Chen use a parabolic gain
  `G = 4·d/dmax·(1-d/dmax)`, which is effectively what UltraReverse does now.
- **Long windows sound like reversal, short ones sound like texture** (Kim & Smith, DAFx-14,
  "Short-Time Time-Reversal on Audio Signals"). Their measured perception: under 1 ms you get
  metallic overtones; 1-30 ms gives detune; 30-100 ms gives flutter or chorus-reverb; "Beyond
  100 ms, we hear the time reversal." In their 50 % OLA structure, the first sample of a window
  is rendered "two window lengths later". So the inherent delay of a reverse delay is between L
  and 2L for a segment length L.
- **Splice crossfades are a parameter.** In Eventide TimeFactor, "the audio segments are read
  backwards and must be spliced. TimeFactor performs a crossfade at the splice point … Xnob sets
  the rate of the crossfade". The LADSPA "Reverse Delay (5s max)" exposes a crossfade of
  1250 samples by default (max 5000).
- **Segment length equals delay time, often tempo-synced.** Eventide H90: "Reverse Delay Buffer
  A/B set the length of each reverse time buffer … can be sync'd to the tempo". Eventide forum:
  "reverses each amount of time … determined by the delay amount"; a phrase longer than that is
  not reversed as a whole. Boss DD-8 REVERSE: 300-5000 ms. Mirror (United Plugins / JMG) works
  in "tempo-related blocks of an eighth, quarter, half or a whole bar" (Sound On Sound review).
- **Onset-triggered segments make it predictable.** Strymon TimeLine Reverse: "The input signal
  triggers the delay so the reverse signal is always predictable, musical and repeatable."
  Its SMEAR param "softens the attack of the repeats". This is the key improvement over
  free-running grains.
- **Granular reverse uses a negative playback rate.** Mutable Instruments Beads (MIT) starts a
  delay grain with rate `(reverse ? -1 : 1) · pitch` and keeps a "head crossing safety zone"
  from the write head (`beads/dsp/delay_granular_player.h`). Valhalla FutureVerb's Reverse echo
  mode is described as detuned reversed granular delays (the page returned 403 to fetch, so this
  is from a search summary only).
- **Product reality check:**
  - Soundtoys **EchoBoy** has *no audio reversal*. Its "Reverse" is a Rhythm-Echo **Shape**:
    "Progressive echoes get louder … used to make those classic '80s backwards echo sounds"
    (EchoBoy v5 manual p.27). It is a rising tap envelope, the same "fake" family that Urs
    describes for old hardware reverse reverbs: "taps of the delay start very quiet and then get
    louder" in front of a short reverb.
  - Soundtoys **Crystallizer** (from the Eventide H3000 Reverse Shift) does real reversal:
    "When the switch is set to 'Reverse', the effect signal is played back in reverse", with
    Splice (segment length, ≥300 ms to hear phrases) and Recycle (feedback through the reverser).
  - **Feedback:** on the DL4, the delay line is "a normal delay, with feedback … but read out in
    reverse". Recirculating through the reverser re-reverses every pass, so the repeats alternate
    between backwards and forwards. Crystallizer recycles through the reverser too. The other
    option keeps every repeat reversed by putting the feedback loop *after* the reverser.

### 2.2 Reverse reverb, with the swell *before* the note

The tape trick is flip → reverb → record wet → flip back (KVR, mystran: "The audio itself is
not reversed, rather just the effect"). Mathematically, for a reverb IR h of length T:

    y = R( h * R(x) )  =  x * h(-t)          (anti-causal)
    y(t - T) = Σ_{τ=0..T} h(T-τ) · x(t-τ)    (causal after delaying everything by T)

So a true pre-verb is convolution with the time-reversed IR, with the dry path delayed by T and T
reported as latency. mystran: "reverse the impulse response (and add latency to dry signal so it
aligns)". Kim & Smith: time reversal "is generally not covered because the system becomes
non-causal … it is possible to add a short delay to the output". Vicanek ("ReverseIIR"): for FIR,
"simply reverse the order of the impulse response and add a total delay".

There are three ways to do it in a live AU:

| | method | latency | swell before note? | notes |
|---|---|---|---|---|
| (a) | lookahead + onset-triggered "reverse reverb of the next segment", reported as latency (Wake, Preverb, Mirror) | = swell length (Wake "High (1.5 s)" default) or 2× buffer (Mirror) | yes, crest on the hit | needs onset detection; overlapping notes are hard |
| (b) | **convolution with a time-reversed IR**, dry delayed by T | = T (IR length) | yes, exact, every note independently (LTI) | no detection, no grain artefacts; the IR can be rendered from our own FDN |
| (c) | reverb first, then reverse the *wet* per segment (reverse(reverb(x)), segment reverser) | 0 | no, the swell rises *after* the note and ends on the next grid point | live-playable; the classic "reverse reverb into the next bar" |

Product data points:
- **Wake** (KVR): "uses look-ahead, so it's not for live tracking"; Low/Medium/High latency
  setting, "lower settings reduce latency at the cost of a shorter maximum swell"; default
  "High (1.5 s)". It has a Direction control (Before / After / Both).
- **Mirror**: "It records the audio into a buffer, adds reverb, reverses everything and then plays
  it back before the original sound … reporting a fake latency to the DAW, which then
  compensates." The reported latency is double the buffer. "Logic, Bitwig, Pro Tools Hybrid have a
  latency limit … with longer buffers, particularly one bar, dry and wet can fall out of sync."
  Sound On Sound (Logic 10.5): "the one quarter setting runs fine at 120bpm or above", i.e. about
  1.0 s of reported latency worked. With the negative mode off it is a zero-latency reverse delay
  that "can be played live".
- **Low End Candy Preverb**: "the swell crests exactly as the sound hits"; the article doesn't
  give a latency figure.

What the host allows (AUAudioUnit.h / Apple docs):
- `latency` is "the audio unit's processing latency, in seconds … a latency that varies with
  parameter settings, including bypass, is generally not useful to hosts … it should be adjusted
  upwards to some fixed latency." The latency should therefore be **fixed** and only change from
  an explicit non-realtime setting. It is bridged to `kAudioUnitProperty_Latency`, so a change is
  announced with `willChangeValueForKey:/didChangeValueForKey:@"latency"`.
- Logic's Low Latency Mode bypasses any plug-in that pushes the path above its Limit, which is up
  to 30 ms on a record-enabled track. A pre-verb is therefore mix-only by nature. Logic's PDC
  ceiling is not documented. Mirror and the SOS review suggest about 1 s is safe and that a full
  bar at low tempo (several seconds) fails. **This needs measuring** (§6, test T9).

Acceptable values: 0.5 s / 1.0 s / 2.0 s steps, with **1.0 s as the default**. That covers vocal
and pad swells and stays inside the range Mirror shows working in Logic.

### 2.3 Permissive open-source code (licence read from each repo's own file)

| library | use | licence (verified) | pinned |
|---|---|---|---|
| **HiFi-LoFi/FFTConvolver** | uniform and two-stage partitioned convolution, zero added latency, RT-safe `process()` | MIT. `COPYING.txt`: "Copyright (c) 2017 HiFi-LoFi / Permission is hereby granted, free of charge, to any person obtaining a copy of this software … The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software." The same header is in every .h/.cpp. | commit `f2cdeb04c4` |
| **Signalsmith-Audio/dsp** v1.7.0 | optional: `envelopes.h` (BoxFilter, PeakHold) for the onset detector; `delay.h` interpolators; `windows.h` | MIT. `LICENSE.txt`: "MIT License / Copyright (c) 2021 Geraint Luff / Signalsmith Audio Ltd. / Permission is hereby granted, free of charge …" README: "This code is MIT licensed." | commit `ca390d28c4` |
| Apple **Accelerate** (vDSP) | FFT backend for FFTConvolver (`AUDIOFFT_APPLE_ACCELERATE`) | system framework, nothing vendored | — |
| pichenettes/eurorack, `beads/` | reference only (reverse grain with head-crossing safety zone) | README: "Code (STM32F projects): MIT license." File header: "Copyright 2017 Emilie Gillet … Permission is hereby granted, free of charge …" | `f4cfa76970` |
| justinfrankel/WDL `convoengine.h` | alternative convolver (reference only) | zlib: "Permission is granted to anyone to use this software for any purpose, including commercial applications, and to alter it and redistribute it freely, subject to the following restrictions …" | — |

Do **not** use these: davemollen/dm-Reverse, brummer10/GxReverseDelay.lv2, olidacombe/OdReverseDelay,
FuzzyLotus/Phantasmagoria (all GPL-3.0); Signalsmith reverb-example-code (no licence file); DaisySP
and chowdsp_utils (mixed licences per module, GitHub shows NOASSERTION); eurorack AVR projects (GPL3).

The core segment reverser is about 150 lines and should be written in-house. Only the convolver
is worth vendoring.

---

## 3. Recommended design

Four modes on a new MODE parameter. Modes 1 and 2 are live-playable with zero latency. Mode 3 is
the true pre-note swell and needs reported latency.

```
MODE 0  BLOOM (legacy)      current engine, unchanged (keeps old sessions sounding the same)
MODE 1  REVERSE ECHO        x ─▶ SegmentReverser ─▶ [repeat loop] ─▶ (light space) ─▶ mix
MODE 2  REVERSE REVERB      x ─▶ FDN (wet only) ─▶ SegmentReverser ─▶ mix          (method c)
MODE 3  PRE-VERB            x ─▶ ReversedIR convolver ─┐                            (method b)
                            x ─▶ dry delay T ──────────┴▶ mix   (latency T reported)
```

### 3.1 SegmentReverser (modes 1 and 2), the core

Segment k is the input span `[s_k, s_k+L)`. Its reversed playback runs in `[s_k+L, s_k+2L)`:

```
input   |== seg k-1 ==|== seg k ===|== seg k+1 ==|
                      s_k          s_k+L        s_k+2L
output                |  rev(k-1)  |  rev(k)    |  rev(k+1) ...
                                    ^ starts with the newest sample of seg k (delay≈1)
                                                 ^ ends with the OLDEST sample of seg k = its attack
read index for head of seg k:   r(t) = 2(s_k+L) - 1 - t       (delay = 2(t - s_k - L) + 1, 1…2L)
```

A note that starts at a segment start `s_k` is heard as a swell rising across `[s_k+L, s_k+2L)`
and **cut right after its own attack**, exactly on the grid point `s_k+2L`. That is the gesture
people mean by "reverse".

**Segment boundaries (TRIGGER):**
- `GRID` (default when the host has a transport): `s_k` on multiples of the Division, computed
  from `musicalContextBlock` (`currentBeatPosition`, tempo) at the start of each block. The
  Delay plug-in already does this (`Delay/DelayExtension/DelayAudioUnit.mm:187-195`). The
  segments are contiguous.
- `ONSET` (Strymon style): an onset starts a capture `[o, o+L)`. Further onsets are locked out
  until `o+L`, and the reversed playback runs `[o+L, o+2L)`. With no onsets the output is silent,
  so every reverse is predictable. The detector is a fast/slow envelope ratio on the HP-filtered
  mono sum, with Sensitivity as the threshold and a 30 ms hold (Signalsmith `BoxFilter`/`PeakHold`
  or two one-poles).
- `FREE`: contiguous segments of the REVERSE seconds, for when there is no host tempo.

**Heads and splices.** There are two heads (A/B ping-pong) plus a short overhang. A new head
starts exactly at the playback boundary. The old head keeps reading backwards for `F_out` samples
past the boundary while it fades out. The fade-out begins *at* the boundary, never before it, so
the reversed attack plays at full gain.
- Window per head, asymmetric and flat-top (not Hann): **fade-in = SMOOTH (1-80 ms, default
  15 ms)** at the start of playback, where the reversed audio starts mid-sustain, and **fade-out =
  CUT (0.5-20 ms, default 3 ms)** after the attack. Gain is 1.0 in between.
- Crossfades are equal-power (`sin/cos` quarter-wave), because adjacent segments are
  uncorrelated.
- L is latched at boundaries only. A knob move takes effect at the next segment, so there are no
  mid-segment jumps (this fixes hpp:139).
- Buffer = `2·Lmax + F_max + maxFrames`, per channel, in **stereo**. Clamp Lmax at 8 s, which
  is 3 MB per channel at 48 kHz.
- Reads are integer for normal playback. The fractional read (FracDelay) is only needed if a
  pitch/speed option is added later.

**Repeats (FEEDBACK, FB MODE):**
```
REVERSE repeats (default):  y_rev ─▶ (+) ─▶ out
                                     ▲  │
                                     └─ g · LP/HP · softclip · delay(L) ◀┘   every repeat stays reversed,
                                                                           lands in the next grid slot
FLIP (DL4 / Crystallizer):  write (x + g·y_rev) into the reverser buffer  → repeats alternate
                                                                           backwards / forwards
```
Feedback ranges from 0 to 0.95, and the soft clip keeps the loop bounded.

**Inherent delay (not reported).** The first reversed sound arrives L after the segment start and
the cut lands 2L after it. That delay *is* the effect (Apple: latency is for processing, "not
as an effect"), so it is not reported.

### 3.2 Mode 2, REVERSE REVERB live (method c)

`x → FdnTank (existing FDN, 100 % wet, its own predelay/size/decay/diffusion/tone) →
SegmentReverser`. A chord on beat 1 with Division = 1 bar gives a reverb that swells across bar 2
and stops dead on the downbeat of bar 3. This is the correct order, reverse(reverb(x)), and it
replaces hpp:302-331 for this mode. Shimmer can remain in the tank.

### 3.3 Mode 3, PRE-VERB (method b, true swell into the note)

```
                 ┌──────── offline (background queue) ─────────┐
params ─debounce─▶ render FdnTank impulse, L and R taps, length T
   (size, decay, │ apply SWELL curve, normalise energy, apply GAP
    diff, tone)  │ reverse in time: h_rev[n] = h[T-1-n]
                 │ init fftconvolver::TwoStageFFTConvolver (head 128, tail 4096)
                 └─▶ atomic swap into the inactive slot B, then a 50 ms crossfade A→B on the audio thread

audio thread:  mono x ─▶ conv_L, conv_R ─▶ wetL/R      (an impulse at t0 swells t0…t0+T)
               x ─▶ DryDelay(T_lat) ─▶ dryL/R          (the dry onset lands at t0+T, on the crest)
               out = mix(dry, wet) ; + optional POST (forward FDN tail) for "Both"
```

- **T_lat** is a fixed LOOKAHEAD setting: Off / 0.5 / 1.0 / 2.0 s, default 1.0 s. It is flagged
  `kAudioUnitParameterFlag_NonRealTime` (AudioUnitProperties.h:1592) so it is not automatable.
  The swell LENGTH knob (0.1 s … T_lat) only changes the IR, which is zero-padded at the far end,
  so the latency stays constant as Apple requires.
- GAP (0-200 ms) shifts the reversed IR so the swell stops just *before* the hit (Preverb's GAP,
  Mirror's Trim). LENGTH + GAP must be ≤ T_lat.
- SWELL shape multiplies the IR by `env(n)^curve` before reversing: linear, exponential, or
  "suck" (steep end).
- The FDN has a soft saturator (hpp:329) and the shimmer is nonlinear. The IR is rendered at
  -40 dBFS with shimmer either baked from one linear pass or excluded. This is good enough and
  keeps the plug-in's sibling character.
- Cost: T = 1 s means 48k taps × 2 channels with a two-stage convolver plus Accelerate, which is
  a low single-digit % of one Apple-silicon core (measure in T10). `init()` allocates, so it must
  never run on the audio thread.
- **Lookahead applies in every mode.** When LOOKAHEAD ≠ Off, modes 0-2 also delay their whole
  output by T_lat so the host compensation stays correct. An optional ALIGN switch in mode 1
  delays only the dry by 2L (when 2L ≤ T_lat): this is Mirror's "negative delay", where the
  reversed segment cuts exactly when the dry attack plays.

### 3.4 Parameters

Keep addresses 0-8 with their current meaning so saved states and automation stay valid.
New addresses are appended:

| addr | id | range / values | default | notes |
|---|---|---|---|---|
| 0 | reverse | 0.05-8.0 s | 0.6 | free segment length (TRIGGER = FREE or no host tempo) |
| 1-8 | size, decay, shimmer, diffusion, texture, predelay, tone, mix | unchanged | | texture is used only by BLOOM |
| 9 | mode | Bloom / Reverse Echo / Reverse Reverb / Pre-Verb | Reverse Echo* | indexed |
| 10 | sync | off / on | on | |
| 11 | division | 1/16, 1/8, 1/8., 1/4, 1/4., 1/2, 1 bar, 2 bars | 1/4 | |
| 12 | trigger | Grid / Onset / Free | Grid | |
| 13 | smooth | 1-80 ms | 15 | fade-in |
| 14 | cut | 0.5-20 ms | 3 | fade-out after the reversed attack |
| 15 | feedback | 0-95 % | 30 % | |
| 16 | fbmode | Reverse / Flip | Reverse | |
| 17 | fbtone | 500 Hz-16 kHz LP | 6 kHz | in the loop |
| 18 | sensitivity | 0-1 | 0.5 | onset threshold |
| 19 | lookahead | Off / 0.5 / 1 / 2 s | 1.0 s in Pre-Verb, else Off | NonRealTime |
| 20 | length | 0.1 s … lookahead | 0.8 s | Pre-Verb swell length |
| 21 | swell | 0-1 (curve) | 0.5 | |
| 22 | gap | 0-200 ms | 0 | |
| 23 | post | 0-100 % | 0 | forward tail mixed in (Wake "Both") |
| 24 | align | off / on | off | Reverse Echo "negative delay" if 2L ≤ lookahead |

\* Default MODE: parameters missing from a restored state keep the tree default, so a default of
Reverse Echo changes how old sessions sound. Either accept that (it is an in-house plug-in) or
make Bloom the tree default and set Reverse Echo in the factory "Init" preset. **Decision for the
owner.**

### 3.5 Latency and tail reporting (UltraReverseAudioUnit.mm)

```objc
- (NSTimeInterval)latency { return _latencySamples.load() / _sampleRate; }  // exact sample count
- (NSTimeInterval)tailTime { return max(decay, 2*Lmax*feedbackTailFactor, T_lat) + 1.0; }
// when LOOKAHEAD changes (implementorValueObserver, main thread, not the audio thread):
[self willChangeValueForKey:@"latency"]; _latencySamples = lrint(T_lat*sr); [self didChangeValueForKey:@"latency"];
```
- The dry delay inside the render block must be exactly `_latencySamples`.
- Bypass: implement `shouldBypassEffect` internally as a latency-delayed dry pass (Mirror's
  "smart bypass"), so toggling bypass doesn't jump in time.
- In Logic, PDC changes may only apply after a transport stop or reinsert. Note this in the
  UI/README.

---

## 4. Files and functions to change

| file | change |
|---|---|
| `UltraReverseExtension/DSP/UltraReverse.hpp` | Extract the FDN (hpp:216-451: prepare/setters/processFrame tank part) into a `FdnTank` class that can run live **and** be instantiated offline to render IRs. Keep `ReverseEngine` (hpp:124-172) as the legacy BLOOM source. Change `UltraReverseEngine` to a mode dispatcher with `processBlock(const float* inL, const float* inR, float* outL, float* outR, int n, const HostTime&)`, because the convolver wants blocks. Only call setters when a value changed (fixes mm:156-160). |
| `UltraReverseExtension/DSP/SegmentReverser.hpp` (new) | §3.1: `prepare(sr, Lmax, maxFrames)`, `setSegment(L)` (latched), `setTrigger(Grid/Onset/Free)`, `setFades(in,out)`, `setFeedback(g, mode, tone)`, `beginBlock(beatPos, tempo, playing)`, `process(L,R)`. Stereo. |
| `UltraReverseExtension/DSP/OnsetDetector.hpp` (new) | fast/slow envelope ratio + hold + lockout |
| `UltraReverseExtension/DSP/PreVerb.hpp/.cpp` (new) | IR render (from FdnTank), reverse, shape, double-buffered `TwoStageFFTConvolver` L/R, lock-free swap (atomic pointer + retire queue drained on the background thread), dry `LatencyLine` |
| `UltraReverseExtension/DSP/third_party/FFTConvolver/` (new) | vendored FFTConvolver.h/.cpp, TwoStageFFTConvolver.h/.cpp, AudioFFT.h/.cpp, Utilities.h/.cpp, COPYING.txt |
| `UltraReverseExtension/UltraReverseAudioUnit.mm` | enum (mm:13-15) +16 addresses; `build()` (mm:44-105) new params incl. indexed valueStrings; atomics (mm:27); `allocateRenderResources` (mm:107): size `_ownOutBuf` from `maximumFramesToRender` (bug fix), prepare reverser/convolver with maxFrames, kick the first IR render; `latency`/`tailTime` overrides; `internalRenderBlock` (mm:121-170): cache `musicalContextBlock`/`transportStateBlock` before render, read beat pos + tempo + playing per block, call `processBlock`; `implementorValueObserver` (mm:65-78): debounce and schedule IR rebuilds on a serial background queue; KVO on latency |
| `UltraReverseExtension/UI/UltraReverseParameterView.swift` | `rebind()` (56-76) formatters for new params; mode/division/trigger selectors; visualiser (116+) draws the swell *before* the onset marker in Pre-Verb and per segment in Echo/Reverb |
| `UltraReverseExtension/UI/PresetStore.swift`, `PresetUI.swift` | factory presets per mode (e.g. "Quarter Reverse Echo", "Bar Reverse Verb", "Vocal Pre-Verb 1s", "Snare Suck 0.5s") |
| `project.yml` | `dependencies: - sdk: Accelerate.framework` on the extension; `GCC_PREPROCESSOR_DEFINITIONS: AUDIOFFT_APPLE_ACCELERATE=1`; header search path `UltraReverseExtension/DSP/third_party` (sources are picked up automatically from the extension folder) |
| `README.md` | correct README:59-62 (no anticipation without lookahead), the ranges, add modes/latency/live-tracking notes |
| `Installer/` + app bundle | ship `THIRD_PARTY_NOTICES.txt` with the MIT notices (FFTConvolver, Signalsmith if used), as the licence requires |

Suggested order: (1) SegmentReverser + Reverse Echo + offline tests T1-T5. (2) Reverse Reverb mode.
(3) Pre-Verb + latency + T6-T9. (4) UI/presets. (5) Bug fixes from §1.4 along the way.

---

## 5. Notes for the implementer

- Equal-power fades for splices between different segments. Linear fades only within one head.
- Sample-accurate grid. Convert `currentBeatPosition` at block start to a sample offset
  `(nextGridBeat - beatPos) * 60/tempo * sr`. Several boundaries can fall in one block. On a
  transport jump or loop (`reset` or a beat-position discontinuity), clear the heads and start a
  fresh segment at the next grid point.
- With no host tempo (standalone, auval), fall back to FREE.
- Everything that allocates (`FFTConvolver::init`, IR render, vector resizes) goes on the
  background queue or in `allocateRenderResources`, never in the render block.
- Denormal flushing is already in place (mm:149-153). Keep it.

---

## 6. Test plan (offline first, then Logic)

Harness: a standalone C++ CLI that includes the DSP headers, reads a WAV, writes a WAV, and has
flags for mode, params and fake tempo/beat position. Build it with the Command Line Tools,
because the Xcode licence is not accepted on this Mac (`xcodebuild` fails):
`DEVELOPER_DIR=/Library/Developer/CommandLineTools clang++ -isysroot $DEVELOPER_DIR/SDKs/MacOSX.sdk -std=c++17 -O2 …`
(this is how `Tools/au_offline/render.sh` does it, and the audit harness used it too). Analysis
uses numpy (installed, 2.5.2) plus ffmpeg/sox (installed). scipy is not installed, so use numpy
FFTs or `sox … spectrogram`.

Test material:
- Drum loop: `AUDIO SYNTH/samples/wa_sample_140bpm.wav` (17.2 s, 140 bpm) and an Apple Loop from
  `/Library/Audio/Apple Loops/Apple/10 Vintage Breaks/`.
- Vocal: a dry vocal stem from the owner, or `/Library/Audio/Apple Loops/Apple/01 Hip Hop/City of
  Angeles Choir.caf` as a stand-in.
- Synthetic: an impulse train, a 2 s linear chirp 100 Hz→8 kHz, a 440 Hz sine, and a pluck.

Renders go to `UltraReverse/tests/renders/` (a permanent location, not /tmp), named
`<test>_<mode>_KJ_v###.wav` per the house rule.

| # | test | pass criterion |
|---|---|---|
| T1 | **Impulse position**, Reverse Echo, Grid, L = 1/4 @ 120 bpm, smooth = cut = minimum | An impulse at `s_k + j` appears at exactly `s_k + 2L - 1 - j` (±0 samples) with gain 1.0 ± 0.01 outside the fades. Copy count = 1 + repeats. |
| T2 | **Per-segment null test** on the drum loop and the vocal | Reference in numpy: split the input on the same grid, `np.flip` each segment, shift by L. Residual ≤ -40 dB relative to the reference outside ±(smooth+cut) of each boundary. |
| T3 | **Chirp spectrogram** | Each L-long block of the output shows a *descending* sweep where the input rose (`sox out.wav -n spectrogram -o …png`). No mirror images or overtone ghosts (those would mean L is too short, see Kim & Smith). |
| T4 | **Pitch preserved** on the vocal | The autocorrelation f0 of matching reversed frames is within ±1 cent of the input. No octave or speed error (the old pre-bugfix code played forwards at 2×). |
| T5 | **Clicks**: 440 Hz sine through Reverse Echo | Energy above 8 kHz in 2 ms windows at boundaries is ≤ 6 dB above the noise floor with default fades. Repeat with knob sweeps of Division and Reverse during playback: no NaN/Inf, no spikes. |
| T6 | **Onset mode** on the drum loop | Every detected onset gives exactly one reversed swell ending 2L after it (±1 ms). No swell starts from a hit that falls inside the lockout window. |
| T7 | **Pre-Verb alignment**, impulse at t0, LOOKAHEAD 1.0 s | The dry impulse is at t0 + 48000 samples exactly (at 48 kHz). The wet RMS envelope (10 ms bins) rises monotonically over [t0, t0+T], peaks in the last 10 ms bin before the dry, and is ≥ 50 dB down 20 ms after it (GAP = 0). |
| T8 | **Pre-Verb against an offline reference** | Offline reference: reverse the whole file, run the FdnTank (same seed/params, shimmer off), reverse back, align by T. Null against the plug-in output ≤ -45 dB. |
| T9 | **Logic**: auval, then an audio track with a click and the vocal, Pre-Verb 1.0 s, then 2.0 s | Bounce in place. The swell crest lines up with the transient (≤ 1 ms) and parallel tracks stay in phase (null against an unprocessed duplicate at Mix 0). Note whether 2.0 s still compensates, and whether a LOOKAHEAD change applies only after transport stop or reinsert. Check that Low Latency Mode bypasses it cleanly. |
| T10 | **CPU / RT safety** | 192 kHz, block 32 … 4096, all modes: no allocations in the render block (Instruments → Allocations filtered to the render thread). Pre-Verb 2 s under 5 % of one core. |
| T11 | **Regression** | Mode 0 (Bloom) renders bit-identically to the current build on the pluck and the drum loop. |

Also listen to each case against a DAW "reverse region + reverb + reverse" render of the same
loop: the Pre-Verb should be indistinguishable apart from the reverb character.

---

## 7. Sources

- KVR, "How does reverse delay effect work?" (earlevel, Urs Heckmann, mystran):
  https://www.kvraudio.com/forum/viewtopic.php?p=8711938
- H.-S. Kim, J. O. Smith, "Short-Time Time-Reversal on Audio Signals", DAFx-14:
  https://dafx14.fau.de/papers/dafx14_hyung-suk_kim_short_time_time_reversal_.pdf
- J. Zhang, Z. Chen, "A Pitch Shifting Reverse Echo Audio Effect", CCRMA EE264 (2018):
  https://ccrma.stanford.edu/~jingjiez/portfolio/echoing-harmonics/pdfs/A%20Pitch%20Shifting%20Reverse%20Echo%20Audio%20Effect.pdf
- M. Vicanek, "Reverse IIR filtering": https://www.vicanek.de/articles/ReverseIIR.pdf
- Strymon TimeLine manual (Reverse machine): https://www.strymon.net/manuals/TimeLine_UserManual_Mobile_RevH.pdf
- Boss DD-8 reference manual: https://static.roland.com/assets/media/pdf/DD-8_Reference_eng03_W.pdf
- Eventide H90 algorithm guide (Reverse): https://cdn.eventideaudio.com/manuals/h90/1.9.7/_static/141385_EventideH90Manual_v1.9.7.pdf ;
  TimeFactor manual: https://www.manualslib.com/manual/755990/Eventide-Timefactor.html ;
  forum: https://www.eventideaudio.com/?p=105407
- Soundtoys EchoBoy v5 manual (Rhythm Echo, Reverse shape): https://www.soundtoys.com/wp-content/uploads/EchoBoy-Manual.pdf
- Soundtoys Crystallizer manual: https://www.soundtoys.com/wp-content/uploads/Crystallizer-Manual.pdf
- United Plugins Mirror: https://unitedplugins.com/Mirror ; SOS review: https://www.soundonsound.com/reviews/jmg-sound-mirror
- Wake (KVR thread): https://www.kvraudio.com/forum/viewtopic.php?p=9259572
- Low End Candy Preverb (Sonicstate): https://sonicstate.com/news/2026/07/20/plug-in-promises-reverse-reverb-in-real-time/
- Valhalla FutureVerb echo modes (fetch returned 403, so this is from a search summary): https://valhalladsp.com/?p=843209
- Apple, AUAudioUnit.latency: https://developer.apple.com/documentation/audiotoolbox/auaudiounit/latency ;
  Logic low-latency mode: https://support.apple.com/105040
- Cycling '74 thread on reverse-delay clicks: https://cycling74.com/forums/reverse-delay-refining-weird-clicking
- Code: https://github.com/HiFi-LoFi/FFTConvolver · https://github.com/Signalsmith-Audio/dsp ·
  https://github.com/pichenettes/eurorack (beads) · https://github.com/justinfrankel/WDL
