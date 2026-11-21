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

// ── Topology-preserving SVF — the centre filter knob. LP and HP outputs;
//    coefficients ramp linearly to a target over a control block. ──────────
class SVF {
public:
    void prepare(float sr) { sr_ = sr; reset(); }
    void reset() { z1_ = z2_ = 0.0f; }
    static float gFor(float fcHz, float sr) {
        const float fc = clamp(fcHz, 10.0f, 0.49f * sr);
        return std::tan(kPi * fc / sr);
    }
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
    float sr_ = 48000, g_ = 0.5f, R_ = 0.7f, dg_ = 0.0f, dR_ = 0.0f, z1_ = 0, z2_ = 0;
};

// ── Granular pitch shifter (one channel) ─────────────────────────────────
class PitchShifter {
public:
    // The grain is a TIME (32 ms), so its length in samples follows the rate.
    // It used to be a fixed 1536 samples: 35 ms at 44.1 kHz but only 16 ms at
    // 96 kHz, where the shifter sounded audibly rougher (twice the grain rate).
    void prepare(float sr) {
        sr_ = sr;
        n_ = std::max(256, std::min(kMaxN, 2 * (int)std::lround(0.016f * sr)));   // even; 1536 at 48 kHz
        uniCoef_ = 1.0f - std::exp(-1.0f / (0.02f * sr));
        rCoef_   = 1.0f - std::exp(-1.0f / (0.010f * sr));   // ratio glide: the knob no longer steps the pitch
        ratioS_  = ratio_;
        reset();
    }
    void reset() { for (int i = 0; i < kMaxN; ++i) buf_[i] = 0.0f; w_ = 0; d_ = 0.0f; uni_ = 1.0f; }
    int  latencySamples() const { return n_ / 2; }
    void setRatio(float r) { ratio_ = r; }

    inline float process(float x) {
        const int   N  = n_;
        const float Nf = (float)N;
        buf_[w_] = x;
        ratioS_ += rCoef_ * (ratio_ - ratioS_);
        if (std::fabs(ratio_ - ratioS_) < 1e-6f) ratioS_ = ratio_;
        float rp1 = (float)w_ - d_;
        while (rp1 < 0) rp1 += Nf;  while (rp1 >= Nf) rp1 -= Nf;
        float rp2 = rp1 + (Nf * 0.5f);
        while (rp2 >= Nf) rp2 -= Nf;
        const float s1 = interp(rp1), s2 = interp(rp2);
        const float frac = d_ / Nf;                     // 0..1 as the read offset sweeps
        // Each tap must be faded to ZERO as it crosses the buffer wrap (the
        // click source). Tap 1 wraps at the ends (frac 0/1) so its window is 0
        // there and 1 in the middle; tap 2 (half a buffer away) is the mirror.
        // The previous code had these swapped, so the wrapping tap was at full
        // gain exactly when it discontinued → the audible click.
        const float w1 = 1.0f - std::fabs(2.0f * frac - 1.0f); // 0 at ends, 1 at middle
        const float w2 = std::fabs(2.0f * frac - 1.0f);        // 1 at ends, 0 at middle
        const float y = s1 * w1 + s2 * w2;
        // Pitch up (ratio>1) reads faster → delay shrinks; down → delay grows.
        d_ -= (ratioS_ - 1.0f);
        while (d_ >= Nf) d_ -= Nf;  while (d_ < 0) d_ += Nf;
        // Unison: crossfade (~20 ms) to a single fixed tap half a buffer back —
        // the delay the shifter is centred on. No comb filter from two frozen
        // taps, no tick from a window parked on the wrap, and no hard switch
        // between dry and a 16 ms-late signal when the knob crosses 12 o'clock
        // (that switch used to click on every crossing).
        int iu = w_ - N / 2; if (iu < 0) iu += N;
        const float u = buf_[iu];
        const float target = (std::fabs(ratio_ - 1.0f) < 1e-4f) ? 1.0f : 0.0f;
        uni_ += (target - uni_) * uniCoef_;
        if (++w_ >= N) w_ = 0;
        return y + (u - y) * uni_;
    }
private:
    // 4-point Hermite read (the old 2-point linear read rolled off the top end
    // of the shifted signal and added interpolation noise).
    inline float interp(float idx) const {
        const int N = n_;
        const int i0 = (int)idx; const float f = idx - (float)i0;
        int im = i0 - 1; if (im < 0) im += N;
        int i1 = i0 + 1; if (i1 >= N) i1 -= N;
        int i2 = i1 + 1; if (i2 >= N) i2 -= N;
        const float xm = buf_[im], x0 = buf_[i0 < N ? i0 : i0 - N], x1 = buf_[i1], x2 = buf_[i2];
        const float c1 = 0.5f * (x1 - xm);
        const float c2 = xm - 2.5f * x0 + 2.0f * x1 - 0.5f * x2;
        const float c3 = 0.5f * (x2 - xm) + 1.5f * (x0 - x1);
        return ((c3 * f + c2) * f + c1) * f + x0;
    }
    static constexpr int kMaxN = 8192;   // 32 ms up to 192 kHz
    float buf_[kMaxN] = {0};
    int   n_ = 1536;                     // ~32 ms grain — shorter = tighter, less latency
    int   w_ = 0;
    float d_ = 0.0f, ratio_ = 1.0f, ratioS_ = 1.0f, sr_ = 48000.0f;
    float uni_ = 1.0f, uniCoef_ = 0.001f, rCoef_ = 0.002f;   // unison crossfade / ratio glide
};

// ── Engine ───────────────────────────────────────────────────────────────
class PitchKnobEngine {
public:
    void prepare(float sr) {
        sr_ = sr;
        psL_.prepare(sr); psR_.prepare(sr);
        for (int ch = 0; ch < 2; ++ch) { lp_[ch].prepare(sr); hp_[ch].prepare(sr); }
        kCtl_  = 1.0f - std::exp(-(float)kCtlBlock / (0.015f * sr_));
        kFade_ = 1.0f - std::exp(-1.0f / (0.005f * sr_));
        setPitch(pitch_);
        psL_.prepare(sr); psR_.prepare(sr);          // settle the ratio glide on the current value
        filtS_ = filt_;
        wLP_ = (filt_ < 0.5f) ? 1.0f : 0.0f;
        wHP_ = (filt_ > 0.5f) ? 1.0f : 0.0f;
        float fl, rl, fh, rh; mapFilter(filtS_, fl, rl, fh, rh);
        for (int ch = 0; ch < 2; ++ch) { lp_[ch].setNow(fl, rl); hp_[ch].setNow(fh, rh); }
        ctl_ = 0;
    }
    void reset() { psL_.reset(); psR_.reset(); for (int ch = 0; ch < 2; ++ch) { lp_[ch].reset(); hp_[ch].reset(); } }
    /// Processing delay in samples (half a grain = 16 ms at every rate).
    int latencySamples() const { return psL_.latencySamples(); }

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
    // Smoothed in processFrame (the cutoff used to step once per host buffer and
    // the filter was switched in cold when the knob left 12 o'clock).
    void setFilter(float v) { filt_ = clamp(v, 0.0f, 1.0f); }
    float filter() const { return filt_; }

    inline void processFrame(float& L, float& R) {
        L = psL_.process(L); R = psR_.process(R);
        if (ctl_ == 0) {
            filtS_ += kCtl_ * (filt_ - filtS_);
            if (std::fabs(filt_ - filtS_) < 1e-5f) filtS_ = filt_;
            float fl, rl, fh, rh; mapFilter(filtS_, fl, rl, fh, rh);
            for (int ch = 0; ch < 2; ++ch) { lp_[ch].setTarget(fl, rl, kCtlBlock); hp_[ch].setTarget(fh, rh, kCtlBlock); }
        }
        if (++ctl_ >= kCtlBlock) ctl_ = 0;
        wLP_ += kFade_ * (((filt_ < 0.5f) ? 1.0f : 0.0f) - wLP_);
        wHP_ += kFade_ * (((filt_ > 0.5f) ? 1.0f : 0.0f) - wHP_);
        const float wl = (wLP_ < 1e-5f) ? 0.0f : wLP_, wh = (wHP_ < 1e-5f) ? 0.0f : wHP_;
        float in[2] = { L, R };
        for (int ch = 0; ch < 2; ++ch) {
            float lpo, hpo, d0, d1;
            lp_[ch].process(in[ch], lpo, d0);
            hp_[ch].process(in[ch], d1, hpo);
            in[ch] = in[ch] + wl * (lpo - in[ch]) + wh * (hpo - in[ch]);
        }
        L = in[0]; R = in[1];
    }

private:
    static void mapFilter(float k, float& fcLP, float& rLP, float& fcHP, float& rHP) {
        const float tl = clamp((0.5f - k) * 2.0f, 0.0f, 1.0f);
        fcLP = 18000.0f * std::pow(80.0f / 18000.0f, tl);
        rLP  = 0.7f - tl * 0.55f;
        const float th = clamp((k - 0.5f) * 2.0f, 0.0f, 1.0f);
        fcHP = 20.0f * std::pow(8000.0f / 20.0f, th);
        rHP  = 0.7f - th * 0.55f;
    }
    static constexpr int kCtlBlock = 16;
    float sr_ = 48000.0f, pitch_ = 0.5f, filt_ = 0.5f, filtS_ = 0.5f;
    float wLP_ = 0.0f, wHP_ = 0.0f, kCtl_ = 0.02f, kFade_ = 0.004f;
    int   ctl_ = 0;
    PitchShifter psL_, psR_;
    SVF lp_[2], hp_[2];
};

} // namespace pkn
