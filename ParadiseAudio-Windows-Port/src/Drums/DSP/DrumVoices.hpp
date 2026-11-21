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

/// Kick with 5 character voicings (reference-modelled):
///   0 = 808   — long pitch envelope, baseHz 35, peakHz 130, tiny click
///   1 = 909   — short pitch env, baseHz 60, peakHz 200, bright click
///   2 = LINN  — punchy sampled-feel kick, mid-focused, moderate click
///   3 = DMX   — boomy lo-fi 8-bit kick (Oberheim DMX), bit-quantized grit
///   4 = ACOUS — acoustic, medium env, big transient
class Kick {
public:
    static constexpr int kNumChars = 5;
    static const char* charName(int c) {
        switch (c) { case 1: return "909"; case 2: return "LINN";
                     case 3: return "DMX"; case 4: return "ACOUS"; default: return "808"; }
    }
    void prepare(float sr) { sr_ = sr; reset(); }
    void reset() { active_ = false; phase_ = 0; env_ = 0; pitchEnv_ = 0; vel_ = 0; clickLp_ = 0; }
    void trigger(float v) { active_ = true; phase_ = 0; env_ = 1.0f; pitchEnv_ = 1.0f; vel_ = v; clickLp_ = 0; }
    void setPitch(float scale) { pitchScale_ = clamp(scale, 0.0625f, 16.0f); }
    void setCharacter(int c) { character_ = std::max(0, std::min(kNumChars - 1, c)); }
    int  character() const { return character_; }
    inline float process() {
        if (!active_) return 0.0f;
        float baseHz, peakHz, envDecay, pitchDecay, clickAmt;
        bool lofi = false;
        switch (character_) {
            case 1: // 909
                baseHz = 60; peakHz = 200; envDecay = 0.99950f; pitchDecay = 0.9955f; clickAmt = 0.55f; break;
            case 2: // LINN — punchy, mid-focused sampled kick
                baseHz = 70; peakHz = 180; envDecay = 0.99955f; pitchDecay = 0.9960f; clickAmt = 0.45f; break;
            case 3: // DMX — boomy lo-fi, bit-quantized
                baseHz = 50; peakHz = 150; envDecay = 0.99970f; pitchDecay = 0.9975f; clickAmt = 0.35f; lofi = true; break;
            case 4: // ACOUS — acoustic
                baseHz = 55; peakHz = 170; envDecay = 0.99955f; pitchDecay = 0.9965f; clickAmt = 0.85f; break;
            case 0: // 808 (default)
            default:
                baseHz = 35; peakHz = 130; envDecay = 0.99975f; pitchDecay = 0.9985f; clickAmt = 0.25f; break;
        }
        baseHz *= pitchScale_;
        peakHz *= pitchScale_;
        const float f = baseHz + (peakHz - baseHz) * pitchEnv_ * pitchEnv_;
        phase_ += 2.0f * kPi * f / sr_;
        if (phase_ > 2.0f * kPi) phase_ -= 2.0f * kPi;
        // Click transient — deterministic pitch-envelope WHACK (no noise
        // source, so no hiss tail): amplifies a high-frequency sub-cycle of
        // the body during the first few samples.
        const float clickGate = (env_ > 0.985f) ? (env_ - 0.985f) * 66.0f : 0.0f;
        const float click = clickGate * clickAmt * vel_ * std::sin(phase_ * 6.0f);
        const float body  = std::sin(phase_) * env_ * vel_;
        float out = body + click;
        // DMX lo-fi: ~8-bit quantize for that gritty Oberheim sampled flavour.
        if (lofi) out = std::round(out * 128.0f) / 128.0f;
        env_      *= envDecay;
        pitchEnv_ *= pitchDecay;
        if (env_ < 0.001f) { active_ = false; }
        return out * 0.85f;
    }
private:
    float sr_ = 48000;
    float pitchScale_ = 1.0f;
    int   character_ = 0;
    bool active_ = false; float phase_ = 0, env_ = 0, pitchEnv_ = 0, vel_ = 0;
    float clickLp_ = 0;        // 1-pole LP state for the click noise
    uint32_t rng_ = 0xCAFEBABEu;
};

/// New snare voice with two body partials and a separate noise HP filter.
///   • Body 1: fundamental at 180 Hz × pitch — thump
///   • Body 2: detuned partial at 330 Hz × pitch — crack/snap
///   • Body pitch envelope drops both partials over the first ~15 ms (gives
///     that "snap" attack character)
///   • Noise: white through a 1-pole HP, cutoff scales with pitch
///   • Body : noise ratio is now 0.7 : 0.7 so the body is much more present
///     than the prior 0.5 : 1.0 (which made the snare sound nearly all noise)
class Snare {
public:
    void prepare(float sr) { sr_ = sr; reset(); }
    void reset() {
        active_ = false; p1_ = 0; p2_ = 0;
        envBody_ = 0; envNoise_ = 0; pitchEnv_ = 0; vel_ = 0;
        hpY_ = 0; hpX_ = 0;
    }
    void trigger(float v) {
        active_ = true; p1_ = 0; p2_ = 0;
        envBody_ = 1.0f; envNoise_ = 1.0f; pitchEnv_ = 1.0f; vel_ = v;
    }
    void setPitch(float scale) { pitchScale_ = clamp(scale, 0.0625f, 16.0f); }
    /// Snare character (5): 0 STD, 1 TIGHT (909), 2 CLAP (808 clappy),
    /// 3 LINN (bright gated sampled), 4 AMEN (breakbeat — long bright rattle).
    static constexpr int kNumChars = 5;
    static const char* charName(int c) {
        switch (c) { case 1: return "TIGHT"; case 2: return "CLAP";
                     case 3: return "LINN"; case 4: return "AMEN"; default: return "STD"; }
    }
    void setCharacter(int c) { character_ = std::max(0, std::min(kNumChars - 1, c)); }
    int  character() const { return character_; }
    inline float process() {
        if (!active_) return 0.0f;
        float f1Base, f2Base, hpBase, bodyDecay, noiseDecay, bodyAmp, noiseAmp;
        switch (character_) {
            case 1: // TIGHT 909
                f1Base = 240; f2Base = 410; hpBase = 1200;
                bodyDecay = 0.9970f; noiseDecay = 0.9982f;
                bodyAmp = 0.8f; noiseAmp = 0.55f;
                break;
            case 2: // CLAP 808
                f1Base = 150; f2Base = 250; hpBase = 500;
                bodyDecay = 0.9988f; noiseDecay = 0.9995f;
                bodyAmp = 0.55f; noiseAmp = 0.95f;
                break;
            case 3: // LINN — bright gated sampled snare, crisp mid body
                f1Base = 200; f2Base = 450; hpBase = 900;
                bodyDecay = 0.9974f; noiseDecay = 0.9986f;
                bodyAmp = 0.7f; noiseAmp = 0.75f;
                break;
            case 4: // AMEN — breakbeat snare: bright, long noise rattle
                f1Base = 190; f2Base = 360; hpBase = 1000;
                bodyDecay = 0.9980f; noiseDecay = 0.9992f;
                bodyAmp = 0.5f; noiseAmp = 0.9f;
                break;
            case 0: // STD
            default:
                f1Base = 180; f2Base = 330; hpBase = 700;
                bodyDecay = 0.9978f; noiseDecay = 0.9990f;
                bodyAmp = 0.7f; noiseAmp = 0.7f;
                break;
        }
        const float pitchMod = 1.0f + pitchEnv_ * 0.5f;
        const float f1 = f1Base * pitchScale_ * pitchMod;
        const float f2 = f2Base * pitchScale_ * pitchMod;
        p1_ += 2.0f * kPi * f1 / sr_; if (p1_ > 2.0f * kPi) p1_ -= 2.0f * kPi;
        p2_ += 2.0f * kPi * f2 / sr_; if (p2_ > 2.0f * kPi) p2_ -= 2.0f * kPi;
        const float body = (std::sin(p1_) * 0.7f + std::sin(p2_) * 0.5f) * envBody_;
        const float raw = fastNoise(rng_) * envNoise_;
        const float fc = clamp(hpBase * pitchScale_, 80.0f, 14000.0f);
        const float a = std::exp(-2.0f * kPi * fc / sr_);
        const float hp = a * (hpY_ + raw - hpX_);
        hpY_ = hp; hpX_ = raw;
        envBody_  *= bodyDecay;
        envNoise_ *= noiseDecay;
        pitchEnv_ *= 0.9920f;
        if (envBody_ < 0.001f && envNoise_ < 0.001f) active_ = false;
        return (body * bodyAmp + hp * noiseAmp) * vel_ * 0.75f;
    }
private:
    float sr_ = 48000;
    float pitchScale_ = 1.0f;
    int   character_ = 0;
    bool active_ = false;
    float p1_ = 0, p2_ = 0;
    float envBody_ = 0, envNoise_ = 0, pitchEnv_ = 0, vel_ = 0;
    float hpY_ = 0, hpX_ = 0;
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

class Hat {
public:
    void prepare(float sr) { sr_ = sr; reset(); }
    void setOpen(bool o) { open_ = o; decayOverride_ = -1.0f; }
    void setDecay(float d) { decayOverride_ = d; }
    void setPitch(float scale) { pitchScale_ = clamp(scale, 0.0625f, 16.0f); }
    /// Hat character (5): 0 WHT (noise), 1 MET (metallic clang), 2 PED
    /// (pedal, very short), 3 LINN (bright sampled, gritty), 4 808 (metallic
    /// 6-partial dominant).
    static constexpr int kNumChars = 5;
    static const char* charName(int c) {
        switch (c) { case 1: return "MET"; case 2: return "PED";
                     case 3: return "LINN"; case 4: return "808"; default: return "WHT"; }
    }
    void setCharacter(int c) { character_ = std::max(0, std::min(kNumChars - 1, c)); }
    int  character() const { return character_; }
    void reset() {
        active_ = false; env_ = 0; vel_ = 0; hpY_ = 0; hpX_ = 0;
        for (int i = 0; i < 6; ++i) phases_[i] = 0;
    }
    void trigger(float v) {
        active_ = true; env_ = 1.0f; vel_ = v;
        for (int i = 0; i < 6; ++i) phases_[i] = 0;
    }
    inline float process() {
        if (!active_) return 0.0f;

        // ── Noise component — broadband "shhh" ──────────────────────────
        const float raw = fastNoise(rng_);
        const float fc = clamp(6000.0f * pitchScale_, 200.0f, 18000.0f);
        const float a = std::exp(-2.0f * kPi * fc / sr_);
        const float hp = a * (hpY_ + raw - hpX_);
        hpY_ = hp; hpX_ = raw;

        // ── Metallic partials — six inharmonic sines (TR-808/909-style) ─
        // Without this, "pitch" only moved the HPF cutoff which isn't pitch
        // at all. With the partials the hat actually has tonal content that
        // pitches up/down. Ratios chosen for non-musical metallic clang.
        static constexpr float kRatios[6] = {2.0f, 3.0f, 4.16f, 5.43f, 6.79f, 8.21f};
        const float baseHz = clamp(318.0f * pitchScale_, 40.0f, 6000.0f);
        float metallic = 0.0f;
        for (int i = 0; i < 6; ++i) {
            phases_[i] += 2.0f * kPi * baseHz * kRatios[i] / sr_;
            if (phases_[i] > 2.0f * kPi) phases_[i] -= 2.0f * kPi;
            metallic += std::sin(phases_[i]);
        }
        metallic *= (1.0f / 6.0f);   // normalize

        // Character — was being stored but completely ignored, so all three
        // CHR settings (WHT / MET / PED) sounded identical. Now each picks
        // a different mix of noise vs. metallic, and PED forces a very fast
        // pedal-hat decay.
        //
        //   0 WHT — white-noise-dominant; classic open/closed hat character
        //   1 MET — metallic-dominant; ride-cymbal-style clang
        //   2 PED — pedal hat; short choked "tch", noise-dominant, slammed
        //
        float noiseMix, metalMix;
        float decay;
        bool  lofi = false;
        switch (character_) {
            case 1: // MET — metallic-heavy
                noiseMix = 0.30f;
                metalMix = open_ ? 0.65f : 0.55f;
                decay = (decayOverride_ > 0.0f) ? decayOverride_ : (open_ ? 0.9995f : 0.9978f);
                break;
            case 2: // PED — pedal hat (very short)
                noiseMix = 0.85f;
                metalMix = 0.15f;
                decay = 0.9945f;            // ~30 ms tail regardless of open/closed
                break;
            case 3: // LINN — bright sampled hat, short, gritty
                noiseMix = 0.80f;
                metalMix = open_ ? 0.30f : 0.22f;
                decay = (decayOverride_ > 0.0f) ? decayOverride_ : (open_ ? 0.9990f : 0.9960f);
                lofi = true;
                break;
            case 4: // 808 — metallic 6-partial clang dominant
                noiseMix = 0.22f;
                metalMix = open_ ? 0.70f : 0.60f;
                decay = (decayOverride_ > 0.0f) ? decayOverride_ : (open_ ? 0.9994f : 0.9974f);
                break;
            case 0: // WHT — default
            default:
                noiseMix = 0.70f;
                metalMix = open_ ? 0.35f : 0.28f;
                decay = (decayOverride_ > 0.0f) ? decayOverride_ : (open_ ? 0.9994f : 0.9970f);
                break;
        }
        env_ *= decay;
        if (env_ < 0.001f) active_ = false;
        float out = hp * noiseMix + metallic * metalMix;
        if (lofi) out = std::round(out * 64.0f) / 64.0f;   // LINN sampled grit
        return out * env_ * vel_ * 0.6f;
    }
private:
    int   character_ = 0;
    float sr_ = 48000;
    float pitchScale_ = 1.0f;
    float decayOverride_ = -1.0f;
    bool open_ = false;
    bool active_ = false; float env_ = 0, vel_ = 0;
    float hpY_ = 0, hpX_ = 0;
    float phases_[6] = {0,0,0,0,0,0};
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

}
