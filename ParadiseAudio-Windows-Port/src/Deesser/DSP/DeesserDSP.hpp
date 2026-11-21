//
//  DeesserDSP.hpp
//  Split-band de-esser.
//
//  Signal path (per channel):
//    in --> Linkwitz-Riley 4th-order crossover at the de-ess frequency
//             |-> low band (passes through untouched)
//             |-> high band --> (a) feeds a band-emphasised sidechain detector
//                                (b) gets attenuated by the detected gain reduction
//    out = low + (high * gainReduction)
//
//  Detector: the high band is further band-passed/emphasised around the sibilance
//  region, a fast-attack / medium-release peak follower tracks its level, and any
//  level above threshold drives a soft-knee, ratio-based gain reduction limited by
//  the Range control. Because only the HIGH band is ducked, the body of the voice
//  is left intact and we can attenuate hard (audibly) without dulling the source.
//

#pragma once
#include "DSPCommon.hpp"
#include <complex>

namespace dsr {

// ---- One biquad section (Transposed Direct Form II), stereo state. ----
class Biquad {
public:
    void prepare(float sr) { sr_ = sr; reset(); }
    void reset()           { z1_[0]=z1_[1]=z2_[0]=z2_[1]=0; }

    // Bandpass (constant skirt gain, peak = Q), used by the detector.
    void setBandpass(float fHz, float q) {
        const float w0 = 2.0f * kPi * clamp(fHz, 20.0f, 0.49f * sr_) / sr_;
        const float cw = std::cos(w0), sw = std::sin(w0);
        const float a  = sw / (2.0f * std::max(0.1f, q));
        const float b0 = a, b1 = 0.0f, b2 = -a;
        const float a0 = 1.0f + a, a1 = -2.0f * cw, a2 = 1.0f - a;
        normalise(b0, b1, b2, a0, a1, a2);
    }
    // Low-pass / high-pass building blocks for the crossover (RBJ biquads).
    void setLowpass(float fHz, float q) {
        const float w0 = 2.0f * kPi * clamp(fHz, 20.0f, 0.49f * sr_) / sr_;
        const float cw = std::cos(w0), sw = std::sin(w0);
        const float a  = sw / (2.0f * std::max(0.1f, q));
        const float b1 = 1.0f - cw, b0 = b1 * 0.5f, b2 = b0;
        const float a0 = 1.0f + a, a1 = -2.0f * cw, a2 = 1.0f - a;
        normalise(b0, b1, b2, a0, a1, a2);
    }
    void setHighpass(float fHz, float q) {
        const float w0 = 2.0f * kPi * clamp(fHz, 20.0f, 0.49f * sr_) / sr_;
        const float cw = std::cos(w0), sw = std::sin(w0);
        const float a  = sw / (2.0f * std::max(0.1f, q));
        const float b1 = -(1.0f + cw), b0 = -b1 * 0.5f, b2 = b0;
        const float a0 = 1.0f + a, a1 = -2.0f * cw, a2 = 1.0f - a;
        normalise(b0, b1, b2, a0, a1, a2);
    }
    inline float process(int ch, float x) {
        const float out = b0_ * x + z1_[ch];
        z1_[ch] = b1_ * x - a1_ * out + z2_[ch];
        z2_[ch] = b2_ * x - a2_ * out;
        return out;
    }
private:
    void normalise(float b0, float b1, float b2, float a0, float a1, float a2) {
        const float inv = 1.0f / a0;
        b0_ = b0 * inv; b1_ = b1 * inv; b2_ = b2 * inv;
        a1_ = a1 * inv; a2_ = a2 * inv;
    }
    float sr_ = 48000;
    float b0_ = 1, b1_ = 0, b2_ = 0, a1_ = 0, a2_ = 0;
    float z1_[2] = {0, 0}, z2_[2] = {0, 0};
};

// ---- Linkwitz-Riley 4th order (two cascaded Butterworth biquads, Q=0.7071). ----
// Low + High recombine flat (allpass-summed), so when no reduction is applied the
// de-esser is transparent.
class LR4Crossover {
public:
    void prepare(float sr) { sr_ = sr; reset(); }
    void reset() { lp1_.reset(); lp2_.reset(); hp1_.reset(); hp2_.reset(); }
    void set(float fHz) {
        const float q = 0.70710678f;
        lp1_.setLowpass(fHz, q);  lp2_.setLowpass(fHz, q);
        hp1_.setHighpass(fHz, q); hp2_.setHighpass(fHz, q);
    }
    inline void split(int ch, float x, float& low, float& high) {
        low  = lp2_.process(ch, lp1_.process(ch, x));
        high = hp2_.process(ch, hp1_.process(ch, x));
    }
private:
    float sr_ = 48000;
    Biquad lp1_, lp2_, hp1_, hp2_;
};

class Deesser {
public:
    void prepare(float sr) {
        sr_ = sr;
        xover_[0].prepare(sr); xover_[1].prepare(sr);
        det_[0].prepare(sr);   det_[1].prepare(sr);
        applyFreq(freq_);
        env_ = 0; gr_ = 0;
        atkCoeff_ = timeToCoeff(0.5f, sr);   // very fast attack catches "ss" transients
        relCoeff_ = timeToCoeff(relMs_, sr);
    }
    void reset() {
        env_ = 0; gr_ = 0;
        xover_[0].reset(); xover_[1].reset();
        det_[0].reset();   det_[1].reset();
    }

    // ---- Public setters: names/signatures preserved for the .mm and UI ----
    void setFrequency(float hz) {
        if (std::fabs(hz - freq_) < 1.0f) return;
        freq_ = hz;
        applyFreq(hz);
    }
    void setThresholdDB(float db) { thrDB_ = db; }
    void setRangeDB(float db)     { rangeDB_ = db; }   // negative — max attenuation of high band
    void setReleaseMs(float ms)   { relMs_ = ms; relCoeff_ = timeToCoeff(ms, sr_); }
    void setListen(bool b)        { listen_ = b; }

    float currentGainReductionDB() const { return gr_; }

    inline void processFrame(float& L, float& R) {
        // 1) Split each channel into low + high at the de-ess frequency.
        float loL, hiL, loR, hiR;
        xover_[0].split(0, L, loL, hiL);
        xover_[1].split(1, R, loR, hiR);

        // 2) Detector: emphasise the sibilance region inside the high band.
        const float dL = det_[0].process(0, hiL);
        const float dR = det_[1].process(1, hiR);
        const float det = std::max(std::fabs(dL), std::fabs(dR));

        // 3) Fast-attack / medium-release peak follower.
        const float c = (det > env_) ? atkCoeff_ : relCoeff_;
        env_ += c * (det - env_);
        const float envDB = linToDb(env_);

        // 4) Soft-knee, ratio-based gain reduction, clamped to Range.
        //    High ratio (8:1) makes this behave like a hard sibilance limiter.
        const float over = envDB - thrDB_;
        float reduceDB = 0.0f;
        if (over > 0.0f) {
            constexpr float ratio = 8.0f;
            constexpr float knee  = 4.0f;       // dB
            if (over < knee) {
                // quadratic soft knee
                const float x = over / knee;
                reduceDB = (over * (1.0f - 1.0f / ratio)) * (x * 0.5f);
            } else {
                reduceDB = over * (1.0f - 1.0f / ratio);
            }
        }
        const float maxRed = -rangeDB_;          // rangeDB_ is negative -> positive dB cap
        reduceDB = clamp(reduceDB, 0.0f, maxRed);
        gr_ = reduceDB;
        const float g = dbToLin(-reduceDB);

        if (listen_) {
            // Monitor exactly what the detector hears (the sibilant high band).
            L = hiL; R = hiR;
            return;
        }
        // 5) Recombine: low band untouched, high band ducked.
        L = loL + hiL * g;
        R = loR + hiR * g;
    }

private:
    void applyFreq(float hz) {
        xover_[0].set(hz); xover_[1].set(hz);
        // Detector emphasis sits a bit above the split, broad enough (Q~1.1) to
        // catch the whole 5-9 kHz sibilance spread rather than one narrow spot.
        const float detF = clamp(hz * 1.15f, 1000.0f, 0.45f * sr_);
        det_[0].setBandpass(detF, 1.1f);
        det_[1].setBandpass(detF, 1.1f);
    }

    float sr_ = 48000;
    float freq_ = 6500;
    // Defaults chosen so the stock setting audibly tames sibilance:
    //   threshold low enough to engage on normal vocals, deep range, fast follower.
    float thrDB_ = -32, rangeDB_ = -18, relMs_ = 80;
    float atkCoeff_ = 0.9f, relCoeff_ = 0.05f;
    float env_ = 0, gr_ = 0;
    bool  listen_ = false;
    LR4Crossover xover_[2];
    Biquad       det_[2];
};

}
