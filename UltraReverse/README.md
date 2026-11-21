# Ultra Reverse — Paradise Audio

A real reverse effect for vocals, drums, pads and guitars, with four modes
(rebuilt 2026-11-20, see `REVERSE_PLAN.md`):

| Mode | What you hear | Latency |
|---|---|---|
| **ECHO** | The input is cut into segments (synced to the bar grid, or free). Each segment plays **backwards** in the next one and cuts hard on its own attack. REPEATS feed the reversed audio back, so every repeat stays reversed. | none |
| **REVERB** | The reverb first, then each segment of the reverb is reversed: the reverb **swells up and stops dead** on the next grid line. | none |
| **PRE-VERB** | A real reverse-reverb **into** the note: convolution with the time-reversed impulse response of the plug-in's own reverb. The dry signal is delayed by the LOOKAHEAD so the swell crests exactly on the hit. | = LOOKAHEAD |
| **BLOOM** | The original Ultra Reverse texture (reversed grains poured into a long shimmer wash), unchanged. | none |

## Parameters

| Control | Range | Default | Notes |
|---|---|---|---|
| Mode | Echo / Reverb / Pre-Verb / Bloom | Echo | |
| Sync | Free / Sync | Sync | Sync follows the host bar grid while the transport runs |
| Division | 1/16 … 2 bars | 1/4 | Segment length when synced |
| Reverse | 0.10–4.0 s | 0.60 s | Free segment length (Echo/Reverb with Sync off) · grain length (Bloom) |
| Repeats | 0–95 % | 30 % | Echo feedback, repeats stay reversed |
| Repeat Tone | 0.5–16 kHz | 6 kHz | Low-pass in the repeat loop |
| Smooth | 1–80 ms | 15 ms | Fade-in where a reversed segment starts |
| Cut | 0.5–20 ms | 3 ms | Fade-out right after the reversed attack (keep it short for the hard cut) |
| Lookahead | Off / 0.5 / 1 / 2 s | 1 s | Reported to the host as latency; mixing only |
| Swell | 0.1–2.0 s | 0.8 s | Pre-Verb swell length (capped at Lookahead − Gap) |
| Gap | 0–200 ms | 0 ms | Pre-Verb: end the swell this much before the hit |
| Size, Decay, Diffusion, Tone, Shimmer, Predelay | as before (Decay 0.3–30 s) | | The reverb tank (Reverb, Pre-Verb, Bloom) |
| Texture | 0–100 % | 70 % | Bloom only |
| Mix | 0–100 % | 40 % | Dry/wet |

## Latency and Logic

- **LOOKAHEAD is the only thing that changes the reported latency.** When it is on,
  every mode's wet is delayed by it too, so Logic's compensation keeps everything
  in time; changing the mode never changes the latency.
- Pre-Verb with a lookahead is for **mixing**: Logic's Low Latency Mode bypasses
  plug-ins like this while recording. With Lookahead OFF, Pre-Verb has no latency
  but its swell follows the note instead of leading into it.
- After changing Lookahead, Logic may only apply the new compensation after the
  transport stops (or the plug-in is re-inserted). 2 s still needs checking in Logic.
- Sessions saved before this version load in **BLOOM with Lookahead Off**, so
  they sound exactly as before.

## Tests (offline, no Xcode needed)

```bash
UltraReverse/tests/build.sh && python3 UltraReverse/tests/run_tests.py
UltraReverse/tests/render_ui.sh out.png <mode 0-3>     # real UI, offscreen
```

Checks: exact per-segment reversal (chirp + clicks, correlation and null residual),
impulse position, chirp spectrograms per mode, Pre-Verb swell alignment against
the latency-compensated hit, knob/mode sweeps with concurrent kernel rebuilds
(no NaN/denormals/clicks), and BLOOM bit-identical to the previous engine. Demos:
`_sound_previews/reverse_<mode>_KJ_v001.wav` (+ `.m4a`).

## Build

Requires full Xcode + `brew install xcodegen`. From the suite root:
`./build_changed.sh`, or `cd UltraReverse && ./Installer/build_installer.sh`.
The extension links **Accelerate** (Pre-Verb FFT).

## AU identity

- Type `aufx`, subtype `Urv1`, manufacturer `Para`
- Bundle `com.paradise.UltraReverse`

## Third-party code

Pre-Verb uses **FFTConvolver** by HiFi-LoFi (MIT), vendored in
`UltraReverseExtension/DSP/third_party/FFTConvolver/` with its `COPYING.txt`.
The notice is repeated in `THIRD_PARTY_NOTICES.txt`, which has to ship with the plug-in.
