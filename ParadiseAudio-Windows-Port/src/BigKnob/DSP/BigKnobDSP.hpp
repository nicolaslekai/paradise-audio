//
//  BigKnobDSP.hpp
//
//  One-knob DJ-style filter. Knob position 0..1 mapped so that 0.5 = bypass
//  (wide open), values below 0.5 sweep a LOW-PASS down from ~18 kHz to ~80 Hz,
//  values above 0.5 sweep a HIGH-PASS up from ~20 Hz to ~8 kHz. Resonance
//  rises slightly toward the extremes for that classic filter-knob "swoosh".
//

#pragma once
#include <algorithm>
#include <cmath>

namespace bkn {

constexpr float kPi = 3.14159265358979323846f;
inline float clamp(float v, float lo, float hi) { return std::max(lo, std::min(hi, v)); }

// Topology-preserving SVF — single instance per channel, returns LP or HP
// depending on `mode` (0=LP, 1=HP). Mild resonance scales with how far the
// knob is from the centre.
class SVF {
public:
    void prepare(float sr) { sr_ = sr; reset(); }
    void reset() { z1_ = z2_ = 0.0f; }
    // fcHz in Hz, R in (0..1) where 0=highly resonant, 1=flat damped
    void set(float fcHz, float R, int mode) {
        fc_ = clamp(fcHz, 10.0f, 0.49f * sr_);
        R_  = clamp(R, 0.05f, 1.0f);
        mode_ = mode;
        const float wd = 2.0f * kPi * fc_;
        const float T  = 1.0f / sr_;
        const float wa = (2.0f / T) * std::tan(wd * T * 0.5f);
        g_  = wa * T * 0.5f;
        h_  = 1.0f / (1.0f + 2.0f * R_ * g_ + g_ * g_);
    }
    inline float process(float x) {
        const float yHP = (x - 2.0f * R_ * z1_ - g_ * z1_ - z2_) * h_;
        const float yBP = g_ * yHP + z1_;
        const float yLP = g_ * yBP + z2_;
        z1_ = g_ * yHP + yBP;
        z2_ = g_ * yBP + yLP;
        return (mode_ == 0) ? yLP : yHP;
    }
private:
    float sr_ = 48000;
    float fc_ = 1000, R_ = 0.7f, g_ = 0.5f, h_ = 1.0f;
    float z1_ = 0, z2_ = 0;
    int mode_ = 0; // 0=LP, 1=HP
};

class BigKnobEngine {
public:
    void prepare(float sr) {
        sr_ = sr;
        lpL_.prepare(sr); lpR_.prepare(sr);
        hpL_.prepare(sr); hpR_.prepare(sr);
        setKnob(0.5f);
    }
    void reset() {
        lpL_.reset(); lpR_.reset(); hpL_.reset(); hpR_.reset();
    }

    // knob 0..1 (0.5 = bypass). UI-friendly setter; recomputes filter coefs.
    void setKnob(float v) {
        knob_ = clamp(v, 0.0f, 1.0f);
        if (knob_ < 0.5f) {
            // LOW-PASS sweep: knob=0 → 80 Hz, knob=0.5 → 18 kHz (bypass-ish)
            const float t = (0.5f - knob_) * 2.0f; // 0..1
            const float fc = 18000.0f * std::pow(80.0f / 18000.0f, t);
            const float R  = 0.7f - t * 0.55f; // more resonance near extremes
            lpL_.set(fc, R, 0); lpR_.set(fc, R, 0);
            lpActive_ = true;  hpActive_ = false;
        } else if (knob_ > 0.5f) {
            // HIGH-PASS sweep: knob=0.5 → 20 Hz (bypass-ish), knob=1 → 8 kHz
            const float t = (knob_ - 0.5f) * 2.0f; // 0..1
            const float fc = 20.0f * std::pow(8000.0f / 20.0f, t);
            const float R  = 0.7f - t * 0.55f;
            hpL_.set(fc, R, 1); hpR_.set(fc, R, 1);
            lpActive_ = false; hpActive_ = true;
        } else {
            lpActive_ = false; hpActive_ = false;
        }
    }
    float knob() const { return knob_; }
    // Returns the current cutoff for the UI display.
    float currentCutoffHz() const {
        if (knob_ < 0.5f) {
            const float t = (0.5f - knob_) * 2.0f;
            return 18000.0f * std::pow(80.0f / 18000.0f, t);
        } else if (knob_ > 0.5f) {
            const float t = (knob_ - 0.5f) * 2.0f;
            return 20.0f * std::pow(8000.0f / 20.0f, t);
        }
        return 0.0f;
    }
    bool isLowPass() const  { return lpActive_; }
    bool isHighPass() const { return hpActive_; }
    bool isBypass()  const  { return !lpActive_ && !hpActive_; }

    // Centre knob — DISTORTION amount 0..1 (tanh waveshaper). 0 = clean.
    void  setDist(float d) { dist_ = clamp(d, 0.0f, 1.0f); }
    float dist() const     { return dist_; }

    inline void processFrame(float& L, float& R) {
        if (lpActive_)      { L = lpL_.process(L); R = lpR_.process(R); }
        else if (hpActive_) { L = hpL_.process(L); R = hpR_.process(R); }
        // else bypass — pass through untouched
        if (dist_ > 0.001f) {
            const float drive = 1.0f + dist_ * 24.0f;
            const float comp  = 1.0f / std::tanh(drive);          // keep peak ≈ unity
            const float trim  = 1.0f - 0.30f * dist_;             // tame the level lift
            L = std::tanh(L * drive) * comp * trim;
            R = std::tanh(R * drive) * comp * trim;
        }
    }
private:
    float sr_ = 48000;
    float knob_ = 0.5f;
    float dist_ = 0.0f;
    SVF lpL_, lpR_, hpL_, hpR_;
    bool lpActive_ = false, hpActive_ = false;
};

} // namespace bkn
