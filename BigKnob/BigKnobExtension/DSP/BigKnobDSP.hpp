//
//  BigKnobDSP.hpp
//
//  One-knob DJ-style filter. Knob position 0..1 mapped so that 0.5 = bypass
//  (wide open), values below 0.5 sweep a LOW-PASS down from ~18 kHz to ~80 Hz,
//  values above 0.5 sweep a HIGH-PASS up from ~20 Hz to ~8 kHz. Resonance
//  rises slightly toward the extremes for that classic filter-knob "swoosh".
//
//  Sound-quality pass 2026-11-21 (Tools/sound_audit):
//   • the knob is smoothed (15 ms) and the filter coefficients ramp per sample,
//     so sweeps / automation no longer step once per host buffer (zipper);
//   • both filters always run and the output crossfades dry ↔ LP ↔ HP, so
//     crossing 12 o'clock no longer switches a cold filter in with a click;
//   • DIST runs 8x oversampled (4x at 88.2 kHz and up) — its near-square-wave
//     harmonics used to fold back as loud inharmonic aliases. The oversampler's
//     constant delay (36 / 35 samples) is applied to the whole signal and
//     reported as latency.
//  Static knob positions sound the same as before.
//

#pragma once
#include <algorithm>
#include <cmath>
#include "HalfbandOS.hpp"

namespace bkn {

constexpr float kPi = 3.14159265358979323846f;
inline float clamp(float v, float lo, float hi) { return std::max(lo, std::min(hi, v)); }

// Topology-preserving SVF — one instance per channel, LP and HP outputs.
// Coefficients ramp linearly to a target over a control block.
class SVF {
public:
    void prepare(float sr) { sr_ = sr; reset(); }
    void reset() { z1_ = z2_ = 0.0f; }
    static float gFor(float fcHz, float sr) {
        const float fc = clamp(fcHz, 10.0f, 0.49f * sr);
        return std::tan(kPi * fc / sr);
    }
    // fcHz in Hz, R in (0..1) where 0=highly resonant, 1=flat damped
    void setNow(float fcHz, float R) { g_ = gFor(fcHz, sr_); R_ = clamp(R, 0.05f, 1.0f); dg_ = dR_ = 0.0f; }
    void setTarget(float fcHz, float R, int steps) {
        const float inv = 1.0f / (float)std::max(1, steps);
        dg_ = (gFor(fcHz, sr_) - g_) * inv;
        dR_ = (clamp(R, 0.05f, 1.0f) - R_) * inv;
    }
    inline void process(float x, float& lp, float& hp) {
        g_ += dg_; R_ += dR_;
        const float h   = 1.0f / (1.0f + 2.0f * R_ * g_ + g_ * g_);
        const float yHP = (x - 2.0f * R_ * z1_ - g_ * z1_ - z2_) * h;
        const float yBP = g_ * yHP + z1_;
        const float yLP = g_ * yBP + z2_;
        z1_ = g_ * yHP + yBP;
        z2_ = g_ * yBP + yLP;
        lp = yLP; hp = yHP;
    }
private:
    float sr_ = 48000;
    float g_ = 0.5f, R_ = 0.7f, dg_ = 0.0f, dR_ = 0.0f;
    float z1_ = 0, z2_ = 0;
};

class BigKnobEngine {
public:
    void prepare(float sr) {
        sr_ = sr;
        const int factor = (sr >= 80000.0f) ? 4 : 8;
        for (int ch = 0; ch < 2; ++ch) {
            lp_[ch].prepare(sr); hp_[ch].prepare(sr);
            os_[ch].prepare(factor); dly_[ch].prepare(os_[ch].latency());
        }
        kCtl_  = 1.0f - std::exp(-(float)kCtlBlock / (0.015f * sr_));   // knob smoothing per control block
        kFade_ = 1.0f - std::exp(-1.0f / (0.005f * sr_));               // LP/HP/dry crossfade
        kDist_ = 1.0f - std::exp(-1.0f / (0.015f * sr_));               // DIST smoothing
        // start settled on the current values (no fade-in from defaults)
        knobS_ = knob_; distS_ = dist_;
        wLP_ = (knob_ < 0.5f) ? 1.0f : 0.0f;
        wHP_ = (knob_ > 0.5f) ? 1.0f : 0.0f;
        float fl, rl, fh, rh; mapKnob(knobS_, fl, rl, fh, rh);
        for (int ch = 0; ch < 2; ++ch) { lp_[ch].setNow(fl, rl); hp_[ch].setNow(fh, rh); }
        ctl_ = 0; osActive_ = false;
        reset();
    }
    void reset() {
        for (int ch = 0; ch < 2; ++ch) { lp_[ch].reset(); hp_[ch].reset(); os_[ch].reset(); dly_[ch].reset(); }
    }
    /// Constant processing delay in samples (the DIST oversampler; reported to the host).
    int latencySamples() const { return os_[0].latency(); }

    // knob 0..1 (0.5 = bypass). Smoothed inside processFrame.
    void setKnob(float v) { knob_ = clamp(v, 0.0f, 1.0f); }
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
    bool isLowPass() const  { return knob_ < 0.5f; }
    bool isHighPass() const { return knob_ > 0.5f; }
    bool isBypass()  const  { return knob_ == 0.5f; }

    // Centre knob — DISTORTION amount 0..1 (tanh waveshaper). 0 = clean.
    void  setDist(float d) { dist_ = clamp(d, 0.0f, 1.0f); }
    float dist() const     { return dist_; }

    inline void processFrame(float& L, float& R) {
        // ── control rate: smooth the knob, aim the filters ──
        if (ctl_ == 0) {
            knobS_ += kCtl_ * (knob_ - knobS_);
            if (std::fabs(knob_ - knobS_) < 1e-5f) knobS_ = knob_;
            float fl, rl, fh, rh; mapKnob(knobS_, fl, rl, fh, rh);
            for (int ch = 0; ch < 2; ++ch) { lp_[ch].setTarget(fl, rl, kCtlBlock); hp_[ch].setTarget(fh, rh, kCtlBlock); }
        }
        if (++ctl_ >= kCtlBlock) ctl_ = 0;

        // ── filter: both always run (warm state); crossfade dry ↔ LP ↔ HP ──
        wLP_ += kFade_ * (((knob_ < 0.5f) ? 1.0f : 0.0f) - wLP_);
        wHP_ += kFade_ * (((knob_ > 0.5f) ? 1.0f : 0.0f) - wHP_);
        float in[2] = { L, R }, f[2];
        for (int ch = 0; ch < 2; ++ch) {
            float lpo, hpo, d0, d1;
            lp_[ch].process(in[ch], lpo, d0);
            hp_[ch].process(in[ch], d1, hpo);
            const float wl = (wLP_ < 1e-5f) ? 0.0f : wLP_, wh = (wHP_ < 1e-5f) ? 0.0f : wHP_;
            f[ch] = in[ch] + wl * (lpo - in[ch]) + wh * (hpo - in[ch]);
        }

        // ── DIST (oversampled) ──
        distS_ += kDist_ * (dist_ - distS_);
        if (distS_ < 1e-5f && dist_ <= 0.0f) distS_ = 0.0f;
        if (distS_ > 0.0f) {
            if (!osActive_) { os_[0].reset(); os_[1].reset(); osActive_ = true; }
            const float drive = 1.0f + distS_ * 24.0f;
            const float comp  = 1.0f / std::tanh(drive);          // keep peak ≈ unity
            const float trim  = 1.0f - 0.30f * distS_;            // tame the level lift
            // Blend in over the first 5 % of the knob so there is no +2.5 dB
            // level step at the first non-zero value (automation 0 → 0.05).
            const float mixD  = std::min(1.0f, distS_ * 20.0f);
            const float gain  = comp * trim;
            for (int ch = 0; ch < 2; ++ch) {
                const float dry = dly_[ch].process(f[ch]);
                const float wet = os_[ch].process(f[ch], [drive, gain](float v) { return std::tanh(v * drive) * gain; });
                f[ch] = dry + mixD * (wet - dry);
            }
        } else {
            osActive_ = false;
            f[0] = dly_[0].process(f[0]);
            f[1] = dly_[1].process(f[1]);
        }
        L = f[0]; R = f[1];
    }
private:
    // Same mapping as before; the inactive filter parks at its "open" end.
    static void mapKnob(float k, float& fcLP, float& rLP, float& fcHP, float& rHP) {
        const float tl = clamp((0.5f - k) * 2.0f, 0.0f, 1.0f);   // LOW-PASS: 18 kHz → 80 Hz
        fcLP = 18000.0f * std::pow(80.0f / 18000.0f, tl);
        rLP  = 0.7f - tl * 0.55f;                                 // more resonance near extremes
        const float th = clamp((k - 0.5f) * 2.0f, 0.0f, 1.0f);   // HIGH-PASS: 20 Hz → 8 kHz
        fcHP = 20.0f * std::pow(8000.0f / 20.0f, th);
        rHP  = 0.7f - th * 0.55f;
    }
    static constexpr int kCtlBlock = 16;
    float sr_ = 48000;
    float knob_ = 0.5f, dist_ = 0.0f;         // targets
    float knobS_ = 0.5f, distS_ = 0.0f;       // smoothed
    float wLP_ = 0.0f, wHP_ = 0.0f;
    float kCtl_ = 0.02f, kFade_ = 0.004f, kDist_ = 0.0014f;
    int   ctl_ = 0;
    bool  osActive_ = false;
    SVF lp_[2], hp_[2];
    pos::Oversampler os_[2];
    pos::DryDelay    dly_[2];
};

} // namespace bkn
