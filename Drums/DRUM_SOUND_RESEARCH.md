# Contemporary Trap / Dance / 808 Drum Synthesis — Research for the Drums rework

> Goal: kill the "too digital / low-bit" character. Three root causes, in order of impact:
> 1. **Aliasing** in oscillators & (esp.) saturation/waveshaping.
> 2. **Missing harmonic saturation** on the 808 (pure sine → vanishes on small speakers, sounds sterile).
> 3. **Raw click/white-noise transients** with no band-limiting/shaping.
> Also: **the bit-crush `std::round(x*N)/N` we added to DMX kick + LINN snare/hat/tom IS the "low-bit" sound — remove it.**

## 1. Modern 808 (sine + pitch env + long amp env + click + SATURATION)
- Tuning (end) freq: 30–65 Hz, note-mapped `f = 440*2^((midi-69)/12)` (C1=32.7, A1=55).
- Peak (start) freq: ~1 octave above target; bigger bend = "zappy", smaller = "mellow drone". Make it a param.
- Pitch decay: **exponential**, 40–200 ms (expose as param).
- Amp decay: long, 0.3–3 s (our DECAY knob), sustain 0.
- Click: **band-limited** — LP-filtered noise (~3 kHz) + short sine blip, ~5–30 ms exp env. NOT a raw impulse (raw = aliased fizz).
- **SATURATION (biggest warmth win):** `tanh(drive*x)` soft-clip; **asymmetric** (`tanh(drive*(x+0.15))-tanh(drive*0.15)`) adds even/2nd harmonics = warmth. Harmonics at 80/120/160 Hz let the ear reconstruct the missing 40 Hz fundamental on laptops/phones. Ideally **multiband**: clean sub <120 Hz, saturate >120 Hz. **Anti-alias the saturator** (ADAA/oversample).

## 2. Trap kick vs 808 (layer them)
- Kick = short/tight/punchy, owns attack, 80–200 Hz, ~80–200 ms decay, click on top.
- 808 = long body + sub (30–65 Hz).
- Sequence: kick transient first, 808 fades under. Reduce 808 attack if kick provides punch. HP the kick around 808 fundamental so they don't pile up / phase-cancel.

## 3. Claps / snares / hats — crisp, not harsh
- **Hats (808 method):** 6 square oscillators, fund 40 Hz × ratios [2,3,4.16,5.43,6.79,8.21] → bandpass ~10 kHz → highpass ~7 kHz → env (20 ms up, fast drop, ~300 ms open / ~50–80 ms closed). Metallic shimmer, NOT white-noise fizz. (We already use these 6 ratios — keep, ensure band-limited.) Trap rolls: retrigger at 1/32–1/64 with per-hit pitch/decay/vel variation.
- **Claps:** bandpass white noise ~1 kHz × multi-burst env: 3 bursts ~10–11 ms apart + ~150–200 ms tail. Randomize burst timing/level per hit.
- **Snares:** noise (1–8 kHz, LP→HP, own env) + 1–2 tuned osc body (150–250 Hz); velocity raises noise/body ratio.

## 4. Why it sounds digital/low-bit + fixes
- **Aliasing #1 culprit:** nonlinear stages create >Nyquist harmonics that fold back as metallic grit. Fixes: band-limited osc (PolyBLEP/wavetable, not `sign(sin)`); **2×–4× oversampling** around saturators; or **ADAA** (1st order: `y=(F1(x)-F1(x1))/(x-x1)`, fallback `f((x+x1)/2)` when |Δx|<1e-5; for tanh `F1=log(cosh x)`, run bookkeeping in double).
- **Bit-crush/SR-reduction = lo-fi** → REMOVE all `std::round()` crushing from voices; keep 32-bit float, never decimate without filtering.
- **Analog warmth:** subtle bus + per-voice saturation; even-harmonic asymmetric shaping; gentle HF rolloff (−1..−3 dB >12–16 kHz); tiny noise floor + per-hit drift (±few cents pitch, ±decay/amp); **exponential** envelopes (linear = synthetic).
- **Layer & separate bands:** sub/808 30–65, kick punch 80–200, snare/clap body 150–250 + crack 1–4k, hats 7k+.

## 5. Reference targets
| Voice | Freq | Pitch env | Amp env | Processing |
|---|---|---|---|---|
| 808 | 30–65 Hz note-mapped | start +1 oct, exp 40–200 ms | A 0–5 ms, decay 0.3–3 s | tanh/asym sat, multiband, clicked attack |
| Trap kick | body 80–200 Hz | start high, exp ~50 ms | A ~1 ms, decay 80–200 ms | LP-noise click ~3k + blip; HP above 808 |
| Snare | 150–250 Hz body | short/none | body 150–300 ms; noise own env | noise 1–8k LP→HP; mix by velocity |
| Clap | BP ~1 kHz | — | 3 bursts ~10 ms + ~180 ms tail | randomize bursts |
| Hat | 6 squares ×ratios | — | A 20 ms, fast drop, 50–80/300 ms | BP ~10k → HP ~7k |

### Top 3 changes
1. Anti-aliased saturation on 808/sub (warmth + small-speaker translation).
2. Remove bit-crush; band-limit click/noise transients (no raw impulses/broadband noise).
3. Anti-alias every nonlinear stage; never decimate unfiltered; add exponential envelopes + tiny per-hit drift.

### Sources
Perfect Circuit (kick synthesis), McGill Nord Modular Book Ch.5 (percussion), joesul.li (808 hats / Gordon Reid SOS), Chowdhury ADAA, Parker et al. DAFx 2016, Unison 808 design, ModeAudio drum synth, SoundOracle 808 saturation, Icon Collective 808 mixing, ADSR anatomy of an 808, KVR 808 clap thread.
