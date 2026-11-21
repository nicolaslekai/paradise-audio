//
//  DrumVoices.hpp
//  Ten procedural TR-808-flavored drum voices. Each voice exposes trigger()
//  and process() (returns one sample). Output is mono (panned to mono at the
//  engine level for simplicity).
//

#pragma once
#include "DSPCommon.hpp"
#include <cstdint>

namespace drm {

inline float fastNoise(uint32_t &state) {
    state = state * 1664525u + 1013904223u;
    return ((state >> 8) & 0x00FFFFFF) / 8388608.0f - 1.0f;
}

/// ── Shared building blocks ──────────────────────────────────────────
/// TPT state-variable filter (Zavalishin). One process() call yields the
/// low-, band- and high-pass outputs simultaneously — needed for the hat's
/// resonant band-pass colouring plus its output high-pass.
class SVF {
public:
    void reset() { ic1_ = ic2_ = 0.0f; lp_ = bp_ = hp_ = 0.0f; }
    void set(float fcHz, float q, float sr) {
        const float g = std::tan(kPi * clamp(fcHz, 10.0f, sr * 0.45f) / sr);
        k_  = 1.0f / std::max(0.05f, q);
        a1_ = 1.0f / (1.0f + g * (g + k_));
        a2_ = g * a1_;
        a3_ = g * a2_;
    }
    inline void process(float x) {
        const float v3 = x - ic2_;
        const float v1 = a1_ * ic1_ + a2_ * v3;
        const float v2 = ic2_ + a2_ * ic1_ + a3_ * v3;
        ic1_ = 2.0f * v1 - ic1_;
        ic2_ = 2.0f * v2 - ic2_;
        lp_ = v2; bp_ = v1; hp_ = x - k_ * v1 - v2;
    }
    inline float lp() const { return lp_; }
    inline float bp() const { return bp_; }
    inline float hp() const { return hp_; }
private:
    float k_ = 1, a1_ = 0, a2_ = 0, a3_ = 0;
    float ic1_ = 0, ic2_ = 0, lp_ = 0, bp_ = 0, hp_ = 0;
};

/// Analog drum oscillators (bridged-T networks) do not put out pure sines —
/// they put out a soft-clipped triangle. That extra harmonic content is what
/// makes an 808/909 body cut through a mix where a plain sin() disappears.
inline float distortedSine(float phase01) {
    const float tri = (phase01 < 0.5f ? phase01 : 1.0f - phase01) * 4.0f - 1.0f;
    return 2.0f * tri / (1.0f + std::fabs(tri));
}

/// Transistor VCA — the asymmetric soft-saturating output stage of the 808 /
/// 909 voice cards. Adds even harmonics and a little envelope-following DC
/// (removed downstream by the voice's DC blocker / high-pass).
inline float transistorVCA(float s, float gain) {
    s = (s - 0.6f) * gain;
    return 3.0f * s / (2.0f + std::fabs(s)) + gain * 0.3f;
}

/// The 808's asymmetric "swing" VCA — squashes the negative half far harder
/// than the positive one. This is where the 808 cymbal's grit comes from.
inline float swingVCA(float s, float gain) {
    s *= (s > 0.0f) ? 10.0f : 0.1f;
    s = s / (1.0f + std::fabs(s));
    return (s + 1.0f) * gain;
}

/// Six free-running square (Schmitt-trigger) oscillators summed — the actual
/// TR-808 / TR-909 hi-hat and cymbal "metallic noise" architecture. Two ratio
/// sets ship with it:
///   kRatios808 — the measured TR-808 oscillator bank
///                (205.3 / 304.4 / 369.6 / 522.7 / 540 / 800 Hz), normalised
///                on 205.3 Hz.
///   kRatiosMI  — Mutable Instruments' Plaits set (nominal f0 414 Hz): denser
///                beating, better suited to brighter modern hats.
/// The oscillators are never phase-reset on trigger — exactly like the
/// hardware. That free-running relationship is why no two hats in a 16th run
/// are identical, and why resetting them (as the old voice did) machine-gunned.
static constexpr float kRatios808[6] = {1.0000f, 1.4827f, 1.8003f, 2.5461f, 2.6303f, 3.8967f};
static constexpr float kRatiosMI[6]  = {1.0000f, 1.3040f, 1.4660f, 1.7870f, 1.9320f, 2.5360f};

class SquareNoise {
public:
    void reset() { for (int i = 0; i < 6; ++i) phase_[i] = 0x2545F491u * (uint32_t)(i + 1); }
    /// f0Norm = fundamental / sampleRate (must stay below 0.5 after ratios).
    inline float process(float f0Norm, const float* ratios) {
        uint32_t sum = 0;
        for (int i = 0; i < 6; ++i) {
            float f = f0Norm * ratios[i];
            if (f > 0.499f) f = 0.499f;
            if (f < 0.0f)   f = 0.0f;
            phase_[i] += (uint32_t)(f * 4294967296.0f);
            sum += (phase_[i] >> 31);
        }
        return 0.33f * (float)sum - 1.0f;
    }
private:
    uint32_t phase_[6] = {0, 0, 0, 0, 0, 0};
};

/// Ring-modulated metallic source: three square x saw pairs. Not an 808
/// circuit at all — it is the FM / KR-55 flavour of metallic noise, and it is
/// what gets close to the bright digital sizzle of a sampled 909 hat.
class RingModNoise {
public:
    void prepare(float sr) { sr_ = sr; reset(); }
    void reset() { for (int i = 0; i < 6; ++i) ph_[i] = 0.0f; }
    inline float process(float ratio) {
        static constexpr float kF[6] = {200.0f, 7530.0f, 510.0f, 8075.0f, 730.0f, 10500.0f};
        float out = 0.0f;
        for (int p = 0; p < 3; ++p) {
            const int a = p * 2, b = a + 1;
            // Proper wrap: at +24 st the 10.5 kHz oscillator advances > 1 per
            // sample and a single subtract let the phase run away to a
            // full-scale blast.
            ph_[a] += kF[a] * ratio / sr_; ph_[a] -= std::floor(ph_[a]);
            ph_[b] += kF[b] * ratio / sr_; ph_[b] -= std::floor(ph_[b]);
            const float sq  = (ph_[a] < 0.5f) ? 1.0f : -1.0f;
            const float saw = 2.0f * ph_[b] - 1.0f;
            out += sq * saw;
        }
        return out * 0.5f;
    }
private:
    float sr_ = 48000.0f;
    float ph_[6] = {0, 0, 0, 0, 0, 0};
};

/// Kick with 5 character voicings (reference-modelled):
///   0 = 808   — long pitch envelope, baseHz 38, tiny click
///   1 = 909   — short deep pitch env, hard bright attack click, saturated
///   2 = LINN  — punchy sampled-feel kick, mid-focused
///   3 = DMX   — boomy lo-fi 8-bit kick (Oberheim DMX), bit-quantized grit
///   4 = ACOUS — acoustic, medium env, big transient
///
/// Three things changed from the first version of this voice, and all three
/// are about the body rather than the numbers:
///   • The body is a soft-clipped triangle (distortedSine), not a pure sine.
///     A bridged-T analog oscillator never put out a sine, and a sine kick
///     vanishes the moment anything else is in the mix.
///   • The click is a real band-passed noise transient with its own ~3 ms
///     envelope, not sin(phase*6). The old trick tracked the body's pitch,
///     so the "click" moved around and never read as a beater hit.
///   • The output runs through the transistor VCA stage, which is where the
///     even harmonics and the 909's characteristic push come from. A DC
///     blocker follows it because that stage is deliberately asymmetric.
class Kick {
public:
    static constexpr int kNumChars = 5;
    static const char* charName(int c) {
        switch (c) { case 1: return "909"; case 2: return "LINN";
                     case 3: return "DMX"; case 4: return "ACOUS"; default: return "808"; }
    }
    void prepare(float sr) { sr_ = sr; reset(); }
    void reset() {
        active_ = false; phase_ = 0; env_ = 0; pitchEnv_ = 0; vel_ = 0;
        clickEnv_ = 0; clickBp_.reset(); dcX_ = 0; dcY_ = 0;
    }
    void trigger(float v) {
        active_ = true; phase_ = 0; env_ = 1.0f; pitchEnv_ = 1.0f;
        vel_ = clamp(v, 0.0f, 1.0f);
        clickEnv_ = 1.0f;
        // Click band centre per character — where the beater lives.
        float clickHz, clickQ;
        switch (character_) {
            case 1: clickHz = 3200; clickQ = 0.9f; break;  // 909 — bright, aggressive
            case 2: clickHz = 2200; clickQ = 1.0f; break;  // LINN
            case 3: clickHz = 1400; clickQ = 1.1f; break;  // DMX
            case 4: clickHz = 2600; clickQ = 0.8f; break;  // ACOUS — broad, woody
            case 0: default: clickHz = 1800; clickQ = 1.2f; break;  // 808
        }
        clickBp_.set(clickHz, clickQ, sr_);
        clickDecay_ = 1.0f - 1.0f / (0.0032f * sr_);
    }
    void setPitch(float scale) { pitchScale_ = clamp(scale, 0.0625f, 16.0f); }
    void setCharacter(int c) { character_ = std::max(0, std::min(kNumChars - 1, c)); }
    int  character() const { return character_; }
    inline float process() {
        if (!active_) return 0.0f;
        float baseHz, peakHz, envDecay, pitchDecay, clickAmt, drive, dirt;
        bool lofi = false;
        switch (character_) {
            case 1: // 909 — deep fast sweep, hard attack, pushed output stage
                baseHz = 48; peakHz = 185; envDecay = 0.99950f; pitchDecay = 0.99560f;
                clickAmt = 0.85f; drive = 1.15f; dirt = 0.55f; break;
            case 2: // LINN — punchy, mid-focused sampled kick
                baseHz = 70; peakHz = 180; envDecay = 0.99955f; pitchDecay = 0.99600f;
                clickAmt = 0.55f; drive = 1.05f; dirt = 0.30f; break;
            case 3: // DMX — boomy lo-fi, bit-quantized
                baseHz = 50; peakHz = 150; envDecay = 0.99970f; pitchDecay = 0.99750f;
                clickAmt = 0.40f; drive = 0.95f; dirt = 0.20f; lofi = true; break;
            case 4: // ACOUS — acoustic, big broad transient
                baseHz = 55; peakHz = 170; envDecay = 0.99955f; pitchDecay = 0.99650f;
                clickAmt = 1.00f; drive = 1.00f; dirt = 0.45f; break;
            case 0: // 808 — long tail, barely any beater
            default:
                baseHz = 38; peakHz = 120; envDecay = 0.99978f; pitchDecay = 0.99880f;
                clickAmt = 0.22f; drive = 0.90f; dirt = 0.12f; break;
        }
        baseHz *= pitchScale_;
        peakHz *= pitchScale_;

        // ── Body ────────────────────────────────────────────────────────
        const float f = baseHz + (peakHz - baseHz) * pitchEnv_ * pitchEnv_;
        phase_ += f / sr_;
        if (phase_ >= 1.0f) phase_ -= 1.0f;
        // "dirt" crossfades between a clean sine and the soft-clipped
        // triangle: 808 stays nearly clean, 909 leans on the harmonics.
        const float dirty = distortedSine(phase_);
        const float clean = std::sin(2.0f * kPi * phase_);
        float body = clean + dirt * (dirty - clean);
        body = transistorVCA(body, env_ * vel_ * drive);

        // ── Beater click — band-passed noise with its own short envelope ─
        clickBp_.process(fastNoise(rng_));
        const float click = clickBp_.bp() * clickEnv_ * clickEnv_ * clickAmt * vel_ * 1.6f;
        clickEnv_ *= clickDecay_;
        if (clickEnv_ < 0.0f) clickEnv_ = 0.0f;

        float out = body + click;
        if (lofi) out = std::round(out * 128.0f) / 128.0f;

        // DC blocker — the transistor VCA stage is asymmetric on purpose.
        const float dc = out - dcX_ + 0.9985f * dcY_;
        dcX_ = out; dcY_ = dc;

        env_      *= envDecay;
        pitchEnv_ *= pitchDecay;
        if (env_ < 0.0008f) active_ = false;
        return dc * 0.72f;
    }
private:
    float sr_ = 48000;
    float pitchScale_ = 1.0f;
    int   character_ = 0;
    bool  active_ = false;
    float phase_ = 0, env_ = 0, pitchEnv_ = 0, vel_ = 0;
    float clickEnv_ = 0, clickDecay_ = 0.99f;
    float dcX_ = 0, dcY_ = 0;
    SVF   clickBp_;
    uint32_t rng_ = 0xCAFEBABEu;
};

/// Snare voice.
///
/// Character 1 (909) runs a completely different engine from the rest: it is
/// the coupled two-oscillator model of the TR-909 snare circuit. The 909's
/// two shell oscillators sit at a ratio of 1 : 1.47 and are cross-reset
/// through Q40's collector, so they intermodulate instead of just summing —
/// that grinding, slightly unstable core is the whole character of a 909
/// snare and no amount of tuning a pair of independent sines gets you there.
/// The noise side gets a hold stage (~40-70 ms at full level before it starts
/// decaying), which is what gives the 909 its flat, wide "shhk" instead of an
/// immediate exponential fade.
///
/// The other four characters use the two-partial body model, but their noise
/// now runs through a real band (resonant low-pass into a high-pass) rather
/// than a single 1-pole high-pass, so SNAPPY-style tuning actually changes
/// the colour of the wires instead of only their brightness.
///   0 STD, 1 909, 2 CLAP (808 clappy), 3 LINN (bright gated), 4 AMEN (break)
class Snare {
public:
    static constexpr int kNumChars = 5;
    static const char* charName(int c) {
        switch (c) { case 1: return "909"; case 2: return "CLAP";
                     case 3: return "LINN"; case 4: return "AMEN"; default: return "STD"; }
    }
    void prepare(float sr) { sr_ = sr; reset(); }
    void reset() {
        active_ = false; p1_ = 0; p2_ = 0;
        envBody_ = 0; envNoise_ = 0; pitchEnv_ = 0; vel_ = 0;
        hpY_ = 0; hpX_ = 0; dcX_ = 0; dcY_ = 0; noiseLp_.reset();
        fm_ = 0; holdCounter_ = 0;
    }
    void trigger(float v) {
        active_ = true; p1_ = 0; p2_ = 0;
        envBody_ = 1.0f; envNoise_ = 1.0f; pitchEnv_ = 1.0f;
        vel_ = clamp(v, 0.0f, 1.0f);
        fm_ = 1.0f;
        // 909 hold stage — the noise sits at full level for ~55 ms first.
        holdCounter_ = (character_ == 1) ? (int)(0.055f * sr_) : 0;
    }
    void setPitch(float scale) { pitchScale_ = clamp(scale, 0.0625f, 16.0f); }
    void setCharacter(int c) { character_ = std::max(0, std::min(kNumChars - 1, c)); }
    int  character() const { return character_; }

    inline float process() {
        if (!active_) return 0.0f;
        return (character_ == 1) ? process909() : processClassic();
    }

private:
    /// ── TR-909: two cross-reset oscillators + held noise ────────────────
    inline float process909() {
        const float f0 = clamp(196.0f * pitchScale_ / sr_, 0.0005f, 0.12f);
        const float snappy = 0.72f;

        // Filters follow the fundamental, exactly as the circuit's do.
        noiseLp_.set(std::min(35.0f * f0, 0.45f) * sr_, 0.5f + 2.0f * snappy, sr_);

        // Oscillator coupling: the reset threshold is nudged by the two
        // oscillators' own outputs, so they pull on each other.
        float resetAmt = clamp((0.125f - f0) * 8.0f, 0.0f, 1.0f);
        resetAmt *= resetAmt * 0.55f;
        float resetNoise = (p1_ > 0.5f ? -1.0f : 1.0f) + (p2_ > 0.5f ? -1.0f : 1.0f);
        resetNoise *= resetAmt * 0.025f;

        const float f = f0 * (1.0f + 0.55f * (4.0f * fm_));
        p1_ += f;
        p2_ += f * 1.47f;
        if (resetAmt > 0.1f) {
            if (p1_ >= 1.0f + resetNoise) p1_ = 1.0f - p1_;
            if (p2_ >= 1.0f + resetNoise) p2_ = 1.0f - p2_;
        } else {
            if (p1_ >= 1.0f) p1_ -= 1.0f;
            if (p2_ >= 1.0f) p2_ -= 1.0f;
        }
        auto shell = [](float ph) {
            const float tri = (ph < 0.5f ? ph : 1.0f - ph) * 4.0f - 1.3f;
            return 2.0f * tri / (1.0f + std::fabs(tri));
        };
        float drum = -0.1f + shell(p1_) * 0.60f + shell(p2_) * 0.25f;
        drum *= envBody_ * 0.72f;

        // Noise: resonant LP into a 1-pole HP — the 909's snare-wire band.
        const float raw = fastNoise(rng_);
        noiseLp_.process(raw);
        const float lp = noiseLp_.lp();
        const float fcHp = clamp(10.0f * f0 * sr_, 80.0f, 12000.0f);
        const float a = std::exp(-2.0f * kPi * fcHp / sr_);
        const float hp = a * (hpY_ + lp - hpX_);
        hpY_ = hp; hpX_ = lp;
        const float noise = (hp + 0.1f) * (envNoise_ + fm_) * 0.85f;

        // Envelopes: body decays long, noise holds then decays.
        envBody_ *= 0.99820f;
        if (holdCounter_ > 0) --holdCounter_; else envNoise_ *= 0.99930f;
        fm_ *= 1.0f - 1.0f / (0.007f * sr_);
        if (fm_ < 0.0f) fm_ = 0.0f;
        if (envBody_ < 0.001f && envNoise_ < 0.001f) active_ = false;
        const float mix = (drum + noise) * vel_ * 0.45f;
        const float dc = mix - dcX_ + 0.9985f * dcY_;
        dcX_ = mix; dcY_ = dc;
        return dc;
    }

    /// ── Two-partial body + banded wire noise (all other characters) ─────
    inline float processClassic() {
        float f1Base, f2Base, hpBase, bodyDecay, noiseDecay, bodyAmp, noiseAmp, noiseQ;
        switch (character_) {
            case 2: // CLAP 808
                f1Base = 150; f2Base = 250; hpBase = 500;
                bodyDecay = 0.9988f; noiseDecay = 0.9995f;
                bodyAmp = 0.55f; noiseAmp = 0.95f; noiseQ = 0.9f;
                break;
            case 3: // LINN — bright gated sampled snare
                f1Base = 200; f2Base = 450; hpBase = 900;
                bodyDecay = 0.9974f; noiseDecay = 0.9986f;
                bodyAmp = 0.7f; noiseAmp = 0.75f; noiseQ = 1.4f;
                break;
            case 4: // AMEN — breakbeat snare: bright, long rattle
                f1Base = 190; f2Base = 360; hpBase = 1000;
                bodyDecay = 0.9980f; noiseDecay = 0.9992f;
                bodyAmp = 0.5f; noiseAmp = 0.9f; noiseQ = 1.1f;
                break;
            case 0: // STD
            default:
                f1Base = 180; f2Base = 330; hpBase = 700;
                bodyDecay = 0.9978f; noiseDecay = 0.9990f;
                bodyAmp = 0.7f; noiseAmp = 0.7f; noiseQ = 1.0f;
                break;
        }
        const float pitchMod = 1.0f + pitchEnv_ * 0.5f;
        const float f1 = f1Base * pitchScale_ * pitchMod;
        const float f2 = f2Base * pitchScale_ * pitchMod;
        p1_ += f1 / sr_; if (p1_ >= 1.0f) p1_ -= 1.0f;
        p2_ += f2 / sr_; if (p2_ >= 1.0f) p2_ -= 1.0f;
        // Soft-clipped shells rather than sines — same reason as the kick.
        const float body = (distortedSine(p1_) * 0.55f + distortedSine(p2_) * 0.38f) * envBody_;

        // Wires: resonant LP at ~4x the corner, then 1-pole HP at the corner.
        noiseLp_.set(clamp(hpBase * 4.5f * pitchScale_, 300.0f, 16000.0f), noiseQ, sr_);
        noiseLp_.process(fastNoise(rng_) * envNoise_);
        const float lp = noiseLp_.lp();
        const float fc = clamp(hpBase * pitchScale_, 80.0f, 14000.0f);
        const float a = std::exp(-2.0f * kPi * fc / sr_);
        const float hp = a * (hpY_ + lp - hpX_);
        hpY_ = hp; hpX_ = lp;

        envBody_  *= bodyDecay;
        envNoise_ *= noiseDecay;
        pitchEnv_ *= 0.9920f;
        if (envBody_ < 0.001f && envNoise_ < 0.001f) active_ = false;
        return (body * bodyAmp + hp * noiseAmp * 1.35f) * vel_ * 0.75f;
    }

    float sr_ = 48000;
    float pitchScale_ = 1.0f;
    int   character_ = 0;
    bool  active_ = false;
    float p1_ = 0, p2_ = 0;            // normalised 0..1 phases
    float envBody_ = 0, envNoise_ = 0, pitchEnv_ = 0, vel_ = 0;
    float fm_ = 0;
    int   holdCounter_ = 0;
    float hpY_ = 0, hpX_ = 0;
    float dcX_ = 0, dcY_ = 0;
    SVF   noiseLp_;
    uint32_t rng_ = 0xDEADBEEFu;
};

/// Multi-layered Clap:
///   • Four short noise bursts at 0/9/18/27 ms — imitates multiple hands hitting
///     with slight phase offsets (classic Linn/808 clap recipe).
///   • Two parallel band-passes: a high "snap" around 1.6 kHz and a low "body"
///     around 600 Hz. Mixed together gives the clap thickness and a sense of
///     pitched fundamental in addition to the noise transient.
///   • Pitch knob scales both band centers, so going up/down changes character
///     dramatically (high = brittle snap, low = woody slap).
class Clap {
public:
    void prepare(float sr) { sr_ = sr; reset(); }
    void reset() {
        active_ = false; samplesElapsed_ = 0; env_ = 0; vel_ = 0;
        bp1L_ = bp1B_ = 0; bp2L_ = bp2B_ = 0;
    }
    void trigger(float v) { active_ = true; samplesElapsed_ = 0; env_ = 1.0f; vel_ = v; }
    void setPitch(float scale) { pitchScale_ = clamp(scale, 0.0625f, 16.0f); }
    /// Clap character (5): 0 808 (4 bursts, classic tail), 1 909 (3 tight
    /// bright bursts), 2 LINN (2-burst gated/crisp), 3 STUDIO (dry/tight,
    /// more body), 4 WASH (long diffuse reverberant tail).
    static constexpr int kNumChars = 5;
    static const char* charName(int c) {
        switch (c) { case 1: return "909"; case 2: return "LINN";
                     case 3: return "STUDIO"; case 4: return "WASH"; default: return "808"; }
    }
    void setCharacter(int c) { character_ = std::max(0, std::min(kNumChars - 1, c)); }
    int  character() const { return character_; }
    inline float process() {
        if (!active_) return 0.0f;
        const int s = samplesElapsed_;
        // ── Per-character clap recipe ───────────────────────────────────
        int nBursts; float spreadMs, fHiBase, fLoBase;
        switch (character_) {
            case 1: nBursts = 3; spreadMs = 7.0f;  fHiBase = 2000; fLoBase = 700; break; // 909
            case 2: nBursts = 2; spreadMs = 6.0f;  fHiBase = 1800; fLoBase = 650; break; // LINN
            case 3: nBursts = 3; spreadMs = 8.0f;  fHiBase = 1500; fLoBase = 550; break; // STUDIO
            case 4: nBursts = 4; spreadMs = 10.0f; fHiBase = 1500; fLoBase = 600; break; // WASH
            case 0: default: nBursts = 4; spreadMs = 9.0f; fHiBase = 1600; fLoBase = 600; break; // 808
        }
        const float msSamp = sr_ * 0.001f;
        const int burstW = (int)(0.0035f * sr_);
        const int tailStart = (int)(spreadMs * (float)nBursts * msSamp);
        float gateEnv = 0.0f;
        if (s < burstW) {
            gateEnv = 1.0f;                              // initial transient
        } else {
            for (int bi = 1; bi < nBursts; ++bi) {       // subsequent hand-claps
                const int bs = (int)(spreadMs * (float)bi * msSamp);
                if (s >= bs && s < bs + burstW) { gateEnv = 1.0f - 0.12f * (float)bi; break; }
            }
            if (gateEnv == 0.0f && s >= tailStart) gateEnv = env_;
        }
        const float raw = fastNoise(rng_) * gateEnv * vel_;
        // Two band-passes via SVF-style: each yields a band-pass output from
        // (raw, lowpass state, band-pass state). 6 ops per BP — cheap.
        const float fHi = clamp(fHiBase * pitchScale_, 200.0f, 14000.0f);
        const float fLo = clamp(fLoBase * pitchScale_, 80.0f,  8000.0f);
        const float gHi = std::tan(kPi * fHi / sr_);
        const float gLo = std::tan(kPi * fLo / sr_);
        const float kQ  = 0.5f;
        // Hi band
        {
            const float hp = (raw - (2.0f * kQ + gHi) * bp1B_ - bp1L_) / (1.0f + 2.0f * kQ * gHi + gHi * gHi);
            const float bp = gHi * hp + bp1B_;
            const float lp = gHi * bp + bp1L_;
            bp1B_ = gHi * hp + bp;
            bp1L_ = gHi * bp + lp;
            snapOut_ = bp;
        }
        // Lo band
        {
            const float hp = (raw - (2.0f * kQ + gLo) * bp2B_ - bp2L_) / (1.0f + 2.0f * kQ * gLo + gLo * gLo);
            const float bp = gLo * hp + bp2B_;
            const float lp = gLo * bp + bp2L_;
            bp2B_ = gLo * hp + bp;
            bp2L_ = gLo * bp + lp;
            bodyOut_ = bp;
        }
        const float tailDecay = (character_ == 4) ? 0.99900f   // WASH   — long diffuse
                              : (character_ == 3) ? 0.99450f   // STUDIO — dry/short
                              : (character_ == 1) ? 0.99550f   // 909    — tight
                              : (character_ == 2) ? 0.99500f   // LINN   — gated
                                                  : 0.99700f;  // 808
        if (s >= tailStart) env_ *= tailDecay;
        samplesElapsed_++;
        const float maxLen = (character_ == 4) ? 1.2f : 0.5f;  // WASH rings longer
        if (samplesElapsed_ > (int)(maxLen * sr_)) active_ = false;
        // Mix: hi band carries the snap, lo band thickens it, plus a touch
        // of the raw burst for transient bite.
        return (snapOut_ * 0.7f + bodyOut_ * 0.6f + raw * 0.25f) * 0.7f;
    }
private:
    int   character_ = 0;
    float sr_ = 48000;
    float pitchScale_ = 1.0f;
    bool active_ = false; int samplesElapsed_ = 0; float env_ = 0, vel_ = 0;
    float bp1L_ = 0, bp1B_ = 0;   // hi-band SVF states
    float bp2L_ = 0, bp2B_ = 0;   // lo-band SVF states
    float snapOut_ = 0, bodyOut_ = 0;
    uint32_t rng_ = 0xFADECAFEu;
};

class Tom {
public:
    void prepare(float sr) { sr_ = sr; reset(); }
    void setHz(float hz) { baseHz_ = hz; }
    void setPitch(float scale) { pitchScale_ = clamp(scale, 0.0625f, 16.0f); }
    /// Tom character (5): 0 STD, 1 DEEP, 2 ROTO (big pitch sweep),
    /// 3 LINN (sampled grit), 4 909 (synth tom, deep env).
    static constexpr int kNumChars = 5;
    static const char* charName(int c) {
        switch (c) { case 1: return "DEEP"; case 2: return "ROTO";
                     case 3: return "LINN"; case 4: return "909"; default: return "STD"; }
    }
    void setCharacter(int c) { character_ = std::max(0, std::min(kNumChars - 1, c)); }
    int  character() const { return character_; }
    void reset() { active_ = false; phase_ = 0; env_ = 0; pitchEnv_ = 0; vel_ = 0; }
    void trigger(float v) { active_ = true; phase_ = 0; env_ = 1.0f; pitchEnv_ = 1.0f; vel_ = v; }
    inline float process() {
        if (!active_) return 0.0f;
        float envDecay, pEnvDecay, pitchDepth, freqMul; bool lofi = false;
        switch (character_) {
            case 1: envDecay = 0.9993f; pEnvDecay = 0.9982f; pitchDepth = 0.80f; freqMul = 0.80f; break; // DEEP
            case 2: envDecay = 0.9986f; pEnvDecay = 0.9990f; pitchDepth = 1.10f; freqMul = 1.00f; break; // ROTO
            case 3: envDecay = 0.9984f; pEnvDecay = 0.9975f; pitchDepth = 0.60f; freqMul = 1.05f; lofi = true; break; // LINN
            case 4: envDecay = 0.9989f; pEnvDecay = 0.9968f; pitchDepth = 0.90f; freqMul = 1.00f; break; // 909
            case 0: default: envDecay = 0.9990f; pEnvDecay = 0.9978f; pitchDepth = 0.60f; freqMul = 1.00f; break; // STD
        }
        const float f = baseHz_ * pitchScale_ * freqMul * (0.7f + pitchDepth * pitchEnv_);
        phase_ += 2.0f * kPi * f / sr_;
        if (phase_ > 2.0f * kPi) phase_ -= 2.0f * kPi;
        float s = std::sin(phase_) * env_ * vel_;
        if (lofi) s = std::round(s * 64.0f) / 64.0f;   // LINN sampled grit
        env_      *= envDecay;
        pitchEnv_ *= pEnvDecay;
        if (env_ < 0.001f) active_ = false;
        return s * 0.75f;
    }
private:
    int   character_ = 0;
    float sr_ = 48000, baseHz_ = 90.0f;
    float pitchScale_ = 1.0f;
    bool active_ = false; float phase_ = 0, env_ = 0, pitchEnv_ = 0, vel_ = 0;
};

/// Rim / Jungle voice — a tone-body + two band-passed noise streams (snare-
/// wire rattle). Five characters span the rimshot→breakbeat range by trading
/// tonal body against wire-noise and retuning:
///   0 = STD    (standard rimshot — woody click, short)
///   1 = HI     (high-tuned rimshot — sharp crack)
///   2 = WOOD   (woodblock — tonal, dry, minimal wire)
///   3 = AMEN   (canonical breakbeat snare — long bright rattle)
///   4 = THINK  ("Think" break snare — bright, snappy)
///
/// Kept under the type name "Rim" so the engine's existing voice routing
/// at slot 3 doesn't need to change — only the sound did.
class Rim {
public:
    static constexpr int kNumChars = 5;
    static const char* charName(int c) {
        switch (c) { case 1: return "HI"; case 2: return "WOOD";
                     case 3: return "AMEN"; case 4: return "THINK"; default: return "STD"; }
    }
    void prepare(float sr) { sr_ = sr; reset(); }
    void setPitch(float scale) { pitchScale_ = clamp(scale, 0.0625f, 16.0f); }
    void setCharacter(int c) { character_ = std::max(0, std::min(kNumChars - 1, c)); }
    int  character() const { return character_; }
    void reset() {
        active_ = false; samplesElapsed_ = 0; env_ = 0; vel_ = 0;
        bpHiL_ = bpHiB_ = bpMidL_ = bpMidB_ = 0;
        bodyP1_ = bodyP2_ = 0;
    }
    void trigger(float v) {
        active_ = true; samplesElapsed_ = 0; env_ = 1.0f; vel_ = v;
        bodyP1_ = bodyP2_ = 0;
    }
    inline float process() {
        if (!active_) return 0.0f;
        const float t = (float)samplesElapsed_ / sr_;

        // ── Per-character recipe: trade tonal body vs. wire-noise + retune ─
        float decayRate, bodyMix, wireMix, pitchMul;
        switch (character_) {
            case 0: decayRate = 0.9955f; bodyMix = 0.70f; wireMix = 0.30f; pitchMul = 1.30f; break; // STD
            case 1: decayRate = 0.9950f; bodyMix = 0.60f; wireMix = 0.35f; pitchMul = 1.90f; break; // HI
            case 2: decayRate = 0.9958f; bodyMix = 0.85f; wireMix = 0.15f; pitchMul = 1.50f; break; // WOOD
            case 3: decayRate = 0.9978f; bodyMix = 0.40f; wireMix = 0.90f; pitchMul = 1.00f; break; // AMEN
            case 4: decayRate = 0.9972f; bodyMix = 0.45f; wireMix = 0.85f; pitchMul = 1.10f; break; // THINK
            default:decayRate = 0.9955f; bodyMix = 0.70f; wireMix = 0.30f; pitchMul = 1.30f; break;
        }

        // ── Body — two sines with a fast pitch envelope ─────────────────
        // The natural snare body drops about an octave in the first 10-15ms
        // after the stick hits — that's what gives a snare its "smack".
        const float pEnv = std::exp(-t * 80.0f);   // ~12 ms drop
        const float f1 = (180.0f + 220.0f * pEnv) * pitchScale_ * pitchMul;
        const float f2 = (350.0f + 380.0f * pEnv) * pitchScale_ * pitchMul;
        bodyP1_ += 2.0f * kPi * f1 / sr_; if (bodyP1_ > 2.0f * kPi) bodyP1_ -= 2.0f * kPi;
        bodyP2_ += 2.0f * kPi * f2 / sr_; if (bodyP2_ > 2.0f * kPi) bodyP2_ -= 2.0f * kPi;
        const float body = std::sin(bodyP1_) * 0.55f + std::sin(bodyP2_) * 0.35f;

        // ── Snare wires — broadband noise band-passed at 5k + 2.2k ─────
        const float raw = fastNoise(rng_);
        const float fHi  = clamp(5000.0f * pitchScale_, 500.0f, 14000.0f);
        const float fMid = clamp(2200.0f * pitchScale_, 300.0f, 10000.0f);
        const float gHi  = std::tan(kPi * fHi  / sr_);
        const float gMid = std::tan(kPi * fMid / sr_);
        const float kQ = 0.5f;
        // Hi BP (the bright "shhh" of the wires)
        const float hpHi = (raw - (2.0f * kQ + gHi) * bpHiB_ - bpHiL_) / (1.0f + 2.0f * kQ * gHi + gHi * gHi);
        const float bpHi = gHi * hpHi + bpHiB_;
        const float lpHi = gHi * bpHi + bpHiL_;
        bpHiB_ = gHi * hpHi + bpHi; bpHiL_ = gHi * bpHi + lpHi;
        // Mid BP (the body-of-the-rattle)
        const float hpMid = (raw - (2.0f * kQ + gMid) * bpMidB_ - bpMidL_) / (1.0f + 2.0f * kQ * gMid + gMid * gMid);
        const float bpMid = gMid * hpMid + bpMidB_;
        const float lpMid = gMid * bpMid + bpMidL_;
        bpMidB_ = gMid * hpMid + bpMid; bpMidL_ = gMid * bpMid + lpMid;

        // ── Envelope (decayRate from the per-character recipe above) ────
        env_ *= decayRate;
        if (env_ < 0.001f) active_ = false;

        // ── Mix — body vs. wire balance set by the character ────────────
        const float mix = body * bodyMix + (bpHi * 0.55f + bpMid * 0.35f) * wireMix;
        samplesElapsed_++;
        return mix * env_ * vel_ * 0.85f;
    }
private:
    int   character_ = 0;
    float sr_ = 48000;
    float pitchScale_ = 1.0f;
    bool  active_ = false;
    int   samplesElapsed_ = 0;
    float env_ = 0, vel_ = 0;
    float bpHiL_ = 0, bpHiB_ = 0;
    float bpMidL_ = 0, bpMidB_ = 0;
    float bodyP1_ = 0, bodyP2_ = 0;
    uint32_t rng_ = 0xBEEF5A11u;
};

/// ── Hi-hat / cymbal voice ───────────────────────────────────────────
/// Rebuilt on the real 808/909 architecture rather than a stack of sines:
///
///   six free-running square oscillators  (the "metallic noise" bank)
///        -> resonant band-pass colouring (one band, or the 808's two)
///        -> blend with clocked noise
///        -> VCA (linear, or the 808's asymmetric "swing" stage)
///        -> output high-pass
///
/// Two things about that chain matter more than any knob value:
///
///  1. The oscillators are NEVER phase-reset on trigger. Real hardware lets
///     them free-run, which is why a 16th-note run of hats breathes instead
///     of machine-gunning the identical waveform 16 times. The old voice
///     reset all six phases on every hit — that alone was most of the
///     "these hats sound fake" problem.
///  2. The envelope has two stages: a fast body decay while it is above 0.5
///     and a slower tail below it. A single exponential gives you a hat that
///     is either clicky or washy; the two-stage shape gives you both, which
///     is what a real closed hat actually does.
///
/// Characters (CHR):
///   0 WHT — modern noisy hat: bright, tight, sits in a mix without EQ
///   1 MET — metallic clang, ride-ish, long
///   2 PED — pedal hat, choked ~55 ms whatever OPEN says
///   3 909 — ring-mod metallic core + light bit-quantise: the sizzly,
///           slightly digital 909 hat, with a transient tick on the front
///   4 808 — the genuine article: measured 808 oscillator bank through the
///           two 808 band-passes (7.1 kHz + 3.44 kHz), swing VCA
class Hat {
public:
    static constexpr int kNumChars = 9;
    static const char* charName(int c) {
        switch (c) { case 1: return "MET"; case 2: return "PED";
                     case 3: return "909"; case 4: return "808";
                     case 5: return "TRAP"; case 6: return "CRISP";
                     case 7: return "SHAKR"; case 8: return "LOFI"; default: return "WHT"; }
    }
    void prepare(float sr) { sr_ = sr; rm_.prepare(sr); reset(); }
    void setOpen(bool o) { open_ = o; }
    /// Legacy entry point. The engine hands the mid hat a per-sample envelope
    /// coefficient (0.9985); convert it into this voice's 0..1 DECAY so the
    /// new two-stage envelope honours the same length.
    void setDecay(float coef) {
        if (coef <= 0.0f || coef >= 1.0f) { decayOverride_ = -1.0f; return; }
        const float r = clamp((1.0f - coef) / 0.003f, 1.0e-4f, 1.0e4f);
        decayOverride_ = clamp(-std::log2(r) / 7.0f, 0.0f, 1.0f);
    }
    void setPitch(float scale) { pitchScale_ = clamp(scale, 0.0625f, 16.0f); }
    void setCharacter(int c) { character_ = std::max(0, std::min(kNumChars - 1, c)); }
    int  character() const { return character_; }
    void reset() {
        active_ = false; env_ = 0; envSm_ = 0; tickEnv_ = 0; vel_ = 0;
        noiseClock_ = 0; noiseSample_ = 0;
        sq_.reset(); rm_.reset();
        bpA_.reset(); bpB_.reset(); hp_.reset();
    }
    void trigger(float v) {
        vel_ = clamp(v, 0.0f, 1.0f);
        active_ = true;
        // NOTE: no oscillator phase reset here, deliberately. See class note.

        // ── Per-character recipe ────────────────────────────────────────
        const float* ratios = kRatiosMI;
        float f0Hz, bpHz, bpQ, bp2Hz, hpHz, noisy, dClosed, dOpen, level, tick;
        bool dualBp = false;
        float atkSec = 0.0005f;            // attack time; the shaker swells in
        useRingMod_ = false; useSwing_ = false; crush_ = 0.0f;
        switch (character_) {
            case 1: // MET — metallic clang / ride
                f0Hz = 380; bpHz = 5200; bpQ = 6.0f; bp2Hz = 0; hpHz = 3200;
                noisy = 0.10f; dClosed = 0.20f; dOpen = 0.62f; level = 0.27f; tick = 0.0f;
                useSwing_ = true;
                break;
            case 2: // PED — pedal hat, always choked
                ratios = kRatios808;
                f0Hz = 560; bpHz = 6500; bpQ = 1.6f; bp2Hz = 0; hpHz = 5500;
                noisy = 0.55f; dClosed = 0.03f; dOpen = 0.03f; level = 0.74f; tick = 0.25f;
                break;
            case 3: // 909 — ring-mod sizzle, lightly quantised
                f0Hz = 640; bpHz = 9200; bpQ = 1.1f; bp2Hz = 0; hpHz = 8200;
                noisy = 0.30f; dClosed = 0.09f; dOpen = 0.50f; level = 0.46f; tick = 0.55f;
                useRingMod_ = true;
                crush_ = 512.0f;   // ~9-bit: the sampled-hat edge, not a fizz
                break;
            case 4: // 808 — measured oscillator bank, both 808 band-passes
                ratios = kRatios808;
                f0Hz = 205.3f; bpHz = 7100; bpQ = 2.2f; bp2Hz = 3440; hpHz = 2800;
                noisy = 0.04f; dClosed = 0.015f; dOpen = 0.42f; level = 0.40f; tick = 0.0f;
                dualBp = true; useSwing_ = true;
                break;
            case 5: // TRAP — tight, bright, very short: built for 1/32 rolls
                f0Hz = 720; bpHz = 10500; bpQ = 0.9f; bp2Hz = 0; hpHz = 9500;
                noisy = 0.85f; dClosed = 0.04f; dOpen = 0.30f; level = 0.78f; tick = 0.35f;
                break;
            case 6: // CRISP — modern house / tech hat: airy noise + a metallic shimmer
                f0Hz = 560; bpHz = 11000; bpQ = 1.4f; bp2Hz = 0; hpHz = 8000;
                noisy = 0.60f; dClosed = 0.12f; dOpen = 0.55f; level = 0.70f; tick = 0.15f;
                break;
            case 7: // SHAKR — shaker-like: almost pure noise, darker band, soft swell
                f0Hz = 480; bpHz = 6000; bpQ = 0.8f; bp2Hz = 0; hpHz = 4500;
                noisy = 0.95f; dClosed = 0.07f; dOpen = 0.24f; level = 0.85f; tick = 0.0f;
                atkSec = 0.004f;
                break;
            case 8: // LOFI — dusty sampled hat: 6-bit grit (the crusher adds aliasing on top)
                f0Hz = 600; bpHz = 6500; bpQ = 1.2f; bp2Hz = 0; hpHz = 5000;
                noisy = 0.60f; dClosed = 0.08f; dOpen = 0.40f; level = 0.62f; tick = 0.20f;
                crush_ = 64.0f;
                break;
            case 0: // WHT — modern noisy hat
            default:
                f0Hz = 640; bpHz = 7800; bpQ = 1.2f; bp2Hz = 0; hpHz = 7000;
                noisy = 0.72f; dClosed = 0.10f; dOpen = 0.46f; level = 0.80f; tick = 0.20f;
                break;
        }

        ratios_  = ratios;
        dualBp_  = dualBp;
        noisy_   = noisy;
        level_   = level;
        tickAmt_ = tick;

        // DECAY: OPEN/CLOSED per character, unless the engine overrode it
        // (the mid hat sits between the two).
        float d = open_ ? dOpen : dClosed;
        if (decayOverride_ >= 0.0f && character_ != 2) d = decayOverride_;

        // Velocity opens the tone up as well as the level — a hard hat is a
        // BRIGHTER hat, not just a louder one.
        const float velBright = 0.72f + 0.28f * vel_;

        f0Norm_  = clamp(f0Hz * pitchScale_ / sr_, 0.0f, 0.24f);
        bpA_.set(bpHz  * pitchScale_ * velBright, bpQ,  sr_);
        if (dualBp_) bpB_.set(bp2Hz * pitchScale_ * velBright, 2.2f, sr_);
        hp_.set(hpHz * pitchScale_ * velBright, 0.5f, sr_);

        // Two-stage envelope coefficients (computed once per hit, not per
        // sample — pow() in the audio loop is not free).
        envDecay_ = 1.0f - 0.0030f * std::pow(2.0f, -d * 7.0f);
        cutDecay_ = 1.0f - 0.0025f * std::pow(2.0f, -d * 3.0f);
        tickDecay_ = 1.0f - 1.0f / (0.0022f * sr_);   // ~2 ms transient

        env_     = 1.5f * (0.3f + 0.7f * vel_);
        envSm_   = 0.0f;
        atkCoef_ = 1.0f - std::exp(-1.0f / (atkSec * sr_));
        tickEnv_ = tickAmt_ * (0.3f + 0.7f * vel_);
    }
    inline float process() {
        if (!active_) return 0.0f;

        // ── Metallic core ───────────────────────────────────────────────
        float out = useRingMod_ ? rm_.process(pitchScale_)
                                : sq_.process(f0Norm_, ratios_);

        // ── Band-pass colouring ─────────────────────────────────────────
        bpA_.process(out);
        if (dualBp_) {
            // The 808 runs two band-passes in parallel — 7.1 kHz carries the
            // sizzle, 3.44 kHz carries the body. Summing them (rather than
            // cascading) is what the circuit actually does.
            bpB_.process(out);
            out = bpA_.bp() * 0.75f + bpB_.bp() * 0.55f;
        } else {
            out = bpA_.bp();
        }

        // ── Clocked noise blend ─────────────────────────────────────────
        // Sample-and-hold noise clocked off the fundamental. Not an 808
        // circuit, but it is what turns a pure metallic bank into something
        // that reads as a hi-hat rather than a bell.
        float noiseF = f0Norm_ * (16.0f + 16.0f * (1.0f - noisy_));
        noiseF = clamp(noiseF, 0.0f, 0.5f);
        noiseClock_ += noiseF;
        if (noiseClock_ >= 1.0f) {
            noiseClock_ -= 1.0f;
            noiseSample_ = fastNoise(rng_) * 0.6f;
        }
        out += noisy_ * (noiseSample_ - out);

        // ── Transient tick — the stick hitting the metal ────────────────
        if (tickAmt_ > 0.0f) {
            out += fastNoise(rng_) * tickEnv_ * 0.9f;
            tickEnv_ *= tickDecay_;
            if (tickEnv_ < 0.0f) tickEnv_ = 0.0f;
        }

        // ── VCA ─────────────────────────────────────────────────────────
        env_ *= (env_ > 0.5f) ? envDecay_ : cutDecay_;
        envSm_ += (env_ - envSm_) * atkCoef_;
        out = useSwing_ ? swingVCA(out, envSm_) : (out * envSm_);

        // ── Output high-pass (also kills the swing VCA's DC offset) ─────
        hp_.process(out);
        out = hp_.hp();

        if (crush_ > 0.0f) out = std::round(out * crush_) / crush_;

        if (env_ < 0.0005f) active_ = false;
        return out * level_;
    }
private:
    int   character_ = 0;
    float sr_ = 48000;
    float pitchScale_ = 1.0f;
    float decayOverride_ = -1.0f;
    bool  open_ = false;
    bool  active_ = false;

    // Recipe, resolved once per trigger.
    const float* ratios_ = kRatiosMI;
    bool  dualBp_ = false, useRingMod_ = false, useSwing_ = false;
    float f0Norm_ = 0.01f, noisy_ = 0.7f, level_ = 0.55f, crush_ = 0.0f;
    float envDecay_ = 0.999f, cutDecay_ = 0.999f, tickDecay_ = 0.99f;
    float tickAmt_ = 0.0f, tickEnv_ = 0.0f;

    float env_ = 0, envSm_ = 0, atkCoef_ = 0.05f, vel_ = 0;
    float noiseClock_ = 0, noiseSample_ = 0;

    SquareNoise  sq_;
    RingModNoise rm_;
    SVF bpA_, bpB_, hp_;
    uint32_t rng_ = 0x12345678u;
};

class Crash {
public:
    void prepare(float sr) { sr_ = sr; reset(); }
    void setPitch(float scale) { pitchScale_ = clamp(scale, 0.0625f, 16.0f); }
    /// Crash character (5): 0 STD (broad wash), 1 CHINA (trashy/bright),
    /// 2 SPLSH (short bright splash), 3 RIDE (tonal ping + long sustain),
    /// 4 808 (metallic cymbal).
    static constexpr int kNumChars = 5;
    static const char* charName(int c) {
        switch (c) { case 1: return "CHINA"; case 2: return "SPLSH";
                     case 3: return "RIDE"; case 4: return "808"; default: return "STD"; }
    }
    void setCharacter(int c) { character_ = std::max(0, std::min(kNumChars - 1, c)); }
    int  character() const { return character_; }
    void reset() { active_ = false; env_ = 0; vel_ = 0; hpY_ = 0; hpX_ = 0; phase_ = 0; }
    void trigger(float v) { active_ = true; env_ = 1.0f; vel_ = v; phase_ = 0; }
    inline float process() {
        if (!active_) return 0.0f;
        float fcBase, decayMul, noiseAmp, pingAmp, pingHz;
        switch (character_) {
            case 1: fcBase = 3500; decayMul = 0.99970f; noiseAmp = 1.00f; pingAmp = 0.00f; pingHz = 0;   break; // CHINA
            case 2: fcBase = 4000; decayMul = 0.99940f; noiseAmp = 1.00f; pingAmp = 0.00f; pingHz = 0;   break; // SPLSH
            case 3: fcBase = 3000; decayMul = 0.99988f; noiseAmp = 0.50f; pingAmp = 0.40f; pingHz = 520; break; // RIDE
            case 4: fcBase = 2800; decayMul = 0.99965f; noiseAmp = 0.85f; pingAmp = 0.00f; pingHz = 0;   break; // 808
            case 0: default: fcBase = 2500; decayMul = 0.99975f; noiseAmp = 1.00f; pingAmp = 0.00f; pingHz = 0; break; // STD
        }
        const float raw = fastNoise(rng_);
        // Squared pitch mapping — much more dramatic than linear. At +24st
        // (scale ≈ 4) cutoff is ~16x default; at -24st (scale ≈ 0.25)
        // cutoff is ~16x lower. Plus a band-pass via additional LP.
        const float fc = clamp(fcBase * pitchScale_ * pitchScale_, 80.0f, 18000.0f);
        const float a = std::exp(-2.0f * kPi * fc / sr_);
        const float hp = a * (hpY_ + raw - hpX_);
        hpY_ = hp; hpX_ = raw;
        // RIDE adds a tonal "ping" partial over the wash.
        float ping = 0.0f;
        if (pingAmp > 0.0f) {
            phase_ += 2.0f * kPi * pingHz * pitchScale_ / sr_;
            if (phase_ > 2.0f * kPi) phase_ -= 2.0f * kPi;
            ping = std::sin(phase_) * pingAmp;
        }
        // Slower decay at lower pitch for thunkier washes; quicker at high
        // pitch for splashy character (on top of the per-character base).
        const float decay = clamp(decayMul + (1.0f - pitchScale_) * 0.0001f, 0.99940f, 0.99992f);
        env_ *= decay;
        if (env_ < 0.001f) active_ = false;
        return (hp * noiseAmp + ping) * env_ * vel_ * 0.5f;
    }
private:
    int   character_ = 0;
    float sr_ = 48000;
    float pitchScale_ = 1.0f;
    bool active_ = false; float env_ = 0, vel_ = 0;
    float hpY_ = 0, hpX_ = 0;
    float phase_ = 0;
    uint32_t rng_ = 0x87654321u;
};

/// Sub — a raw, deep sub-bass voice. Five character variants:
///   0 = DEEP   — 38 Hz base, very long release, classic 808 sub
///   1 = TIGHT  — 55 Hz, shorter envelope, punchy feel
///   2 = WARM   — 45 Hz, slight saturation, more body / harmonic content
///   3 = DROP   — 30 Hz base with a big slow downward pitch slide (the "drop")
///   4 = REESE  — two detuned oscillators beating, saturated for harmonics
class Sub {
public:
    static constexpr int kNumChars = 5;
    static const char* charName(int c) {
        switch (c) { case 1: return "TIGHT"; case 2: return "WARM";
                     case 3: return "DROP"; case 4: return "REESE"; default: return "DEEP"; }
    }
    void prepare(float sr) { sr_ = sr; reset(); }
    void reset() { active_ = false; phase_ = 0; phase2_ = 0; env_ = 0; pitchEnv_ = 0; vel_ = 0; }
    void trigger(float v) { active_ = true; phase_ = 0; phase2_ = 0; env_ = 1.0f; pitchEnv_ = 1.0f; vel_ = v; }
    void setPitch(float scale) { pitchScale_ = clamp(scale, 0.0625f, 16.0f); }
    void setCharacter(int c) { character_ = std::max(0, std::min(kNumChars - 1, c)); }
    int  character() const { return character_; }
    inline float process() {
        if (!active_) return 0.0f;
        float baseHz, peakHz, envDecay, pitchDecay;
        int   mode;  // 0 clean, 1 saturate, 2 reese
        switch (character_) {
            case 1: // TIGHT
                baseHz = 55; peakHz = 110; envDecay = 0.99955f; pitchDecay = 0.9960f; mode = 0; break;
            case 2: // WARM
                baseHz = 45; peakHz = 150; envDecay = 0.99975f; pitchDecay = 0.9980f; mode = 1; break;
            case 3: // DROP — big slow downward slide
                baseHz = 30; peakHz = 220; envDecay = 0.99980f; pitchDecay = 0.9993f; mode = 0; break;
            case 4: // REESE — detuned beating, saturated
                baseHz = 45; peakHz = 120; envDecay = 0.99980f; pitchDecay = 0.9975f; mode = 2; break;
            case 0: // DEEP
            default:
                baseHz = 38; peakHz = 90;  envDecay = 0.99985f; pitchDecay = 0.9990f; mode = 0; break;
        }
        baseHz *= pitchScale_;
        peakHz *= pitchScale_;
        const float f = baseHz + (peakHz - baseHz) * pitchEnv_ * pitchEnv_;
        phase_ += 2.0f * kPi * f / sr_;
        if (phase_ > 2.0f * kPi) phase_ -= 2.0f * kPi;
        float body;
        if (mode == 2) {
            // REESE — second oscillator detuned ~1.2% for the classic beating
            // movement, summed then saturated to grow harmonic content.
            phase2_ += 2.0f * kPi * f * 1.012f / sr_;
            if (phase2_ > 2.0f * kPi) phase2_ -= 2.0f * kPi;
            body = std::tanh((std::sin(phase_) + std::sin(phase2_)) * 1.5f);
        } else {
            body = std::sin(phase_);
            if (mode == 1) body = std::tanh(body * 1.4f);   // WARM adds harmonic content
        }
        env_      *= envDecay;
        pitchEnv_ *= pitchDecay;
        if (env_ < 0.001f) active_ = false;
        return body * env_ * vel_ * 0.95f;
    }
private:
    float sr_ = 48000;
    float pitchScale_ = 1.0f;
    int   character_ = 0;
    bool active_ = false; float phase_ = 0, phase2_ = 0, env_ = 0, pitchEnv_ = 0, vel_ = 0;
};


// ── LONG SUB (voice 11) — sustained sub-bass notes, 2–3 s tails ────────────
// The SUB voice is a short, kick-locked thump; LONG SUB is the held note under
// the groove. Five reference characters:
//   808    — classic long 808 boom: fast pitch drop 160→42 Hz, light saturation
//   PURE   — clean sine at 45 Hz, tiny dip, 3 s tail (sub-only PA weight)
//   HOLLOW — sine + a touch of 3rd harmonic: square-ish, speaks on small monitors
//   GROWL  — two detuned oscillators into tanh with a slow amplitude wobble
//   SLIDE  — long portamento from 90 Hz down to 35 Hz over ~1 s
// Retriggers cross-fade the previous note out over ~2 ms (no clicks), and a
// 3 ms attack ramp keeps the onset clean. Decays are sample-rate aware.
class LongSub {
public:
    static constexpr int kNumChars = 5;
    static const char* charName(int c) {
        switch (c) { case 1: return "PURE"; case 2: return "HOLLOW";
                     case 3: return "GROWL"; case 4: return "SLIDE"; default: return "808"; }
    }
    void prepare(float sr) { sr_ = sr; fadeStep_ = 1.0f / (0.002f * sr); cachedChar_ = -1; reset(); }
    void reset() { cur_ = Osc(); old_ = Osc(); cachedChar_ = -1; }
    void trigger(float v) {
        // Hand the sounding note to the fade-out slot — SAME waveform, same
        // phases, its own envelope — and fade it over ~2 ms. (A plain-sine
        // stand-in used to step against the 808 / HOLLOW / GROWL body and
        // click on every retrigger at musical rates.)
        if (cur_.active && cur_.env > 0.005f) { old_ = cur_; old_.fade = 1.0f; }
        cur_ = Osc(); cur_.active = true; cur_.env = 1.0f; cur_.pEnv = 1.0f; cur_.vel = v;
    }
    void setPitch(float scale) { pitchScale_ = clamp(scale, 0.0625f, 16.0f); }
    void setCharacter(int c) { character_ = std::max(0, std::min(kNumChars - 1, c)); }
    int  character() const { return character_; }
    inline float process() {
        if (character_ != cachedChar_) {
            switch (character_) {
                case 1: baseHz_ = 45; peakHz_ = 55;  decaySec_ = 3.0f; pitchTau_ = 0.03f; mode_ = 0; break;   // PURE
                case 2: baseHz_ = 40; peakHz_ = 80;  decaySec_ = 2.0f; pitchTau_ = 0.04f; mode_ = 2; break;   // HOLLOW
                case 3: baseHz_ = 48; peakHz_ = 96;  decaySec_ = 2.5f; pitchTau_ = 0.06f; mode_ = 3; break;   // GROWL
                case 4: baseHz_ = 35; peakHz_ = 90;  decaySec_ = 3.0f; pitchTau_ = 0.45f; mode_ = 4; break;   // SLIDE
                default: baseHz_ = 42; peakHz_ = 160; decaySec_ = 2.2f; pitchTau_ = 0.05f; mode_ = 1; break;  // 808
            }
            envCoef_ = std::exp(-6.9077f / (decaySec_ * sr_));   // reaches -60 dB after decaySec_
            pCoef_   = std::exp(-1.0f / (pitchTau_ * sr_));
            cachedChar_ = character_;
        }
        float out = 0.0f;
        if (old_.active) {
            out += body(old_) * old_.fade;
            old_.fade -= fadeStep_;
            if (old_.fade <= 0.0f || !old_.active) old_.active = false;
        }
        if (cur_.active) out += body(cur_);
        return out;
    }
private:
    struct Osc {
        bool  active = false;
        float phase = 0, phase2 = 0, env = 0, pEnv = 0, vel = 0, atk = 0, lfo = 0, fade = 0;
    };
    /// One sample of a note's body — advances its phases and envelopes.
    inline float body(Osc &o) {
        const float base = baseHz_ * pitchScale_, peak = peakHz_ * pitchScale_;
        // 808 uses a squared pitch env (snappy drop); SLIDE a plain one (smooth glide).
        const float pe = (mode_ == 1) ? o.pEnv * o.pEnv : o.pEnv;
        const float f = base + (peak - base) * pe;
        const float inc = 2.0f * kPi * f / sr_;
        o.phase += inc; if (o.phase > 2.0f * kPi) o.phase -= 2.0f * kPi;
        float bodyS;
        switch (mode_) {
            case 1:  bodyS = std::tanh(std::sin(o.phase) * 1.25f); break;                       // 808 — light sat
            case 2:  bodyS = std::sin(o.phase) + 0.22f * std::sin(3.0f * o.phase); break;         // HOLLOW
            case 3: {                                                                          // GROWL
                o.phase2 += inc * 1.009f; if (o.phase2 > 2.0f * kPi) o.phase2 -= 2.0f * kPi;
                o.lfo += 2.0f * kPi * 3.5f / sr_; if (o.lfo > 2.0f * kPi) o.lfo -= 2.0f * kPi;
                bodyS = std::tanh((std::sin(o.phase) + std::sin(o.phase2)) * 1.6f) * (0.8f + 0.2f * std::sin(o.lfo));
                break;
            }
            default: bodyS = std::sin(o.phase); break;                                          // PURE / SLIDE
        }
        if (o.atk < 1.0f) o.atk = std::min(1.0f, o.atk + 1.0f / (0.003f * sr_));  // 3 ms attack
        o.env  *= envCoef_;
        o.pEnv *= pCoef_;
        if (o.env < 0.001f) o.active = false;
        return bodyS * o.env * o.atk * o.vel * 0.95f;
    }
    float sr_ = 48000, fadeStep_ = 0.01f;
    float pitchScale_ = 1.0f;
    int   character_ = 0, cachedChar_ = -1, mode_ = 1;
    float baseHz_ = 42, peakHz_ = 160, decaySec_ = 2.2f, pitchTau_ = 0.05f, envCoef_ = 0.99994f, pCoef_ = 0.9996f;
    Osc   cur_, old_;
};

}
