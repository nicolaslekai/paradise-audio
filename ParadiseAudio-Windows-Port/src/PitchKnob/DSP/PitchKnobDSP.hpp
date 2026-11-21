//
//  PitchKnobDSP.hpp
//
//  One big knob = real-time PITCH SHIFT (±12 semitones, 12 o'clock = unison),
//  with a small FILTER knob in the centre (same DJ-style sweep as Big Knob:
//  0.5 = open, below = low-pass down, above = high-pass up).
//
//  Pitch shifter: classic 2-grain granular delay line. Two read taps half a
//  buffer apart, cross-faded with a triangular window so the wrap-around is
//  inaudible. Cheap, real-time-safe, no FFT.
//

#pragma once
#include <algorithm>
#include <cmath>

namespace pkn {

constexpr float kPi = 3.14159265358979323846f;
inline float clamp(float v, float lo, float hi) { return std::max(lo, std::min(hi, v)); }

// ── Topology-preserving SVF (LP or HP) — the centre filter knob ──────────
class SVF {
public:
    void prepare(float sr) { sr_ = sr; reset(); }
    void reset() { z1_ = z2_ = 0.0f; }
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
    float sr_ = 48000, fc_ = 1000, R_ = 0.7f, g_ = 0.5f, h_ = 1.0f, z1_ = 0, z2_ = 0;
    int mode_ = 0;
};

// ── Granular pitch shifter (one channel) ─────────────────────────────────
class PitchShifter {
public:
    void prepare(float sr) { sr_ = sr; reset(); }
    void reset() { for (int i = 0; i < N; ++i) buf_[i] = 0.0f; w_ = 0; d_ = 0.0f; }
    void setRatio(float r) { ratio_ = r; }

    inline float process(float x) {
        buf_[w_] = x;
        // At unison there is nothing to shift — pass the input straight through.
        // (Otherwise the two fixed-offset taps comb-filter the dry signal and,
        // worse, a frozen window can sit on a wrap point and tick.)
        if (ratio_ == 1.0f) { w_ = (w_ + 1) % N; return x; }
        float rp1 = (float)w_ - d_;
        while (rp1 < 0) rp1 += N;  while (rp1 >= N) rp1 -= N;
        float rp2 = rp1 + (N * 0.5f);
        while (rp2 >= N) rp2 -= N;
        const float s1 = lerp(rp1), s2 = lerp(rp2);
        const float frac = d_ / (float)N;               // 0..1 as the read offset sweeps
        // Each tap must be faded to ZERO as it crosses the buffer wrap (the
        // click source). Tap 1 wraps at the ends (frac 0/1) so its window is 0
        // there and 1 in the middle; tap 2 (half a buffer away) is the mirror.
        // The previous code had these swapped, so the wrapping tap was at full
        // gain exactly when it discontinued → the audible click.
        const float w1 = 1.0f - std::fabs(2.0f * frac - 1.0f); // 0 at ends, 1 at middle
        const float w2 = std::fabs(2.0f * frac - 1.0f);        // 1 at ends, 0 at middle
        const float y = s1 * w1 + s2 * w2;
        // Pitch up (ratio>1) reads faster → delay shrinks; down → delay grows.
        d_ -= (ratio_ - 1.0f);
        while (d_ >= N) d_ -= N;  while (d_ < 0) d_ += N;
        w_ = (w_ + 1) % N;
        return y;
    }
private:
    inline float lerp(float idx) {
        int i0 = (int)idx; int i1 = i0 + 1; if (i1 >= N) i1 = 0;
        const float f = idx - (float)i0;
        return buf_[i0] + (buf_[i1] - buf_[i0]) * f;
    }
    static constexpr int N = 1536;   // ~32 ms grain — shorter = tighter, less latency
    float buf_[N] = {0};
    int   w_ = 0;
    float d_ = 0.0f, ratio_ = 1.0f, sr_ = 48000.0f;
};

// ── Engine ───────────────────────────────────────────────────────────────
class PitchKnobEngine {
public:
    void prepare(float sr) {
        sr_ = sr;
        psL_.prepare(sr); psR_.prepare(sr);
        fL_.prepare(sr);  fR_.prepare(sr);
        setPitch(0.5f); setFilter(0.5f);
    }
    void reset() { psL_.reset(); psR_.reset(); fL_.reset(); fR_.reset(); }

    // Big knob 0..1 → ±12 semitones (0.5 = unison).
    void setPitch(float v) {
        pitch_ = clamp(v, 0.0f, 1.0f);
        const float semi  = (pitch_ - 0.5f) * 24.0f;
        const float ratio = std::pow(2.0f, semi / 12.0f);
        psL_.setRatio(ratio); psR_.setRatio(ratio);
    }
    float pitch() const     { return pitch_; }
    float semitones() const { return (pitch_ - 0.5f) * 24.0f; }
    bool  isUnison() const  { return std::fabs(pitch_ - 0.5f) < 0.005f; }

    // Centre knob 0..1 → DJ filter (0.5 open, <0.5 LP down, >0.5 HP up).
    void setFilter(float v) {
        filt_ = clamp(v, 0.0f, 1.0f);
        if (filt_ < 0.5f) {
            const float t = (0.5f - filt_) * 2.0f;
            const float fc = 18000.0f * std::pow(80.0f / 18000.0f, t);
            const float R  = 0.7f - t * 0.55f;
            fL_.set(fc, R, 0); fR_.set(fc, R, 0); fLP_ = true;  fHP_ = false;
        } else if (filt_ > 0.5f) {
            const float t = (filt_ - 0.5f) * 2.0f;
            const float fc = 20.0f * std::pow(8000.0f / 20.0f, t);
            const float R  = 0.7f - t * 0.55f;
            fL_.set(fc, R, 1); fR_.set(fc, R, 1); fLP_ = false; fHP_ = true;
        } else { fLP_ = false; fHP_ = false; }
    }
    float filter() const { return filt_; }

    inline void processFrame(float& L, float& R) {
        L = psL_.process(L); R = psR_.process(R);
        if (fLP_ || fHP_) { L = fL_.process(L); R = fR_.process(R); }
    }

private:
    float sr_ = 48000.0f, pitch_ = 0.5f, filt_ = 0.5f;
    bool  fLP_ = false, fHP_ = false;
    PitchShifter psL_, psR_;
    SVF fL_, fR_;
};

} // namespace pkn
