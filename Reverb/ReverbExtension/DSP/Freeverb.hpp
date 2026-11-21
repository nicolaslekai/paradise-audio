//
//  Freeverb.hpp
//
//  Lush analogue reverb — rebuilt from a parallel-comb Freeverb into an
//  8-line Feedback Delay Network (FDN). FDNs reach "perceptually white" echo
//  density within tens of ms (vs. the sparse, metallic comb response), and
//  with a unitary Householder feedback matrix the decay is set purely by the
//  per-line gains. Warmth/lushness come from: per-line one-pole damping
//  (tail darkens naturally), slow DECORRELATED modulation of the delay reads
//  (kills fixed comb resonances), input allpass diffusion (smears transients),
//  and a gentle feedback saturator (tape/plate glue).
//
//  Class name + public API kept identical so the AU layer is unchanged.
//  References: Dattorro "Effect Design Pt.1", J.O.Smith CCRMA FDN, Valhalla.
//

#pragma once
#include <algorithm>
#include <cmath>
#include <vector>

namespace rvb {

constexpr float kPi = 3.14159265358979323846f;
constexpr int   kFDN = 8;

// Fractional delay line (linear interp) for modulated reads.
class FracDelay {
public:
    void prepare(int maxLen) { N_ = std::max(4, maxLen); buf_.assign(N_, 0.0f); wr_ = 0; }
    void reset() { std::fill(buf_.begin(), buf_.end(), 0.0f); wr_ = 0; }
    inline void write(float x) { buf_[wr_] = x; if (++wr_ >= N_) wr_ = 0; }
    inline float read(float delay) const {
        float rp = (float)wr_ - delay;
        while (rp < 0.0f) rp += (float)N_;
        int i0 = (int)rp; float fr = rp - (float)i0;
        int i1 = i0 + 1; if (i1 >= N_) i1 -= N_;
        if (i0 >= N_) i0 -= N_;
        return buf_[i0] + fr * (buf_[i1] - buf_[i0]);
    }
private:
    std::vector<float> buf_; int wr_ = 0, N_ = 4;
};

class Allpass {  // Schroeder allpass — input diffusion
public:
    void prepare(int sizeSamples) { buf_.assign(std::max(1, sizeSamples), 0.0f); idx_ = 0; }
    void reset() { std::fill(buf_.begin(), buf_.end(), 0.0f); idx_ = 0; }
    void setFeedback(float f) { feedback_ = f; }
    inline float process(float x) {
        const float d = buf_[idx_];
        const float v = x + feedback_ * d;
        buf_[idx_] = v;
        if (++idx_ >= (int)buf_.size()) idx_ = 0;
        return -feedback_ * v + d;
    }
private:
    std::vector<float> buf_; int idx_ = 0; float feedback_ = 0.5f;
};

class OnePole {
public:
    void setLP(float fc, float sr) { const float w = 2.0f * kPi * std::max(20.0f, std::min(0.49f * sr, fc)) / sr; a_ = 1.0f - std::exp(-w); hp_ = false; }
    void setHP(float fc, float sr) { const float w = 2.0f * kPi * std::max(5.0f,  std::min(0.49f * sr, fc)) / sr; a_ = 1.0f - std::exp(-w); hp_ = true; }
    void setCoeff(float a) { a_ = std::max(0.0f, std::min(0.999f, a)); hp_ = false; }
    void reset() { z_ = 0.0f; }
    inline float process(float x) { z_ += a_ * (x - z_); return hp_ ? (x - z_) : z_; }
private:
    float a_ = 0.5f, z_ = 0.0f; bool hp_ = false;
};

class PreDelay {
public:
    void prepare(float sr) {
        sr_ = sr; buf_.assign((int)std::ceil(0.5f * sr) + 4, 0.0f); widx_ = 0;
        fadeInc_ = 1.0f / (0.020f * sr); curTap_ = -1; nextTap_ = -1; fade_ = 0.0f;
    }
    void reset() { std::fill(buf_.begin(), buf_.end(), 0.0f); widx_ = 0; curTap_ = -1; nextTap_ = -1; fade_ = 0.0f; }
    void setMs(float ms) { delaySamps_ = std::max(1.0f, std::min((float)(buf_.size() - 2), ms * 0.001f * sr_)); }
    inline float process(float x) {
        if (buf_.empty()) return x;
        buf_[widx_] = x;
        const int N = (int)buf_.size();
        // A new PREDELAY is reached by crossfading (20 ms) from the old tap to
        // the new one — no click, no pitch glide. The tap used to hop once per
        // host buffer, a click on every knob move. At rest: the same
        // whole-sample tap as before.
        const int tgt = (int)delaySamps_;
        if (curTap_ < 0) curTap_ = tgt;
        if (fade_ <= 0.0f && tgt != curTap_) { nextTap_ = tgt; fade_ = fadeInc_; }
        int r = widx_ - curTap_; if (r < 0) r += N;
        float out = buf_[r];
        if (fade_ > 0.0f) {
            int r2 = widx_ - nextTap_; if (r2 < 0) r2 += N;
            out += fade_ * (buf_[r2] - out);
            fade_ += fadeInc_;
            if (fade_ >= 1.0f) { curTap_ = nextTap_; fade_ = 0.0f; }
        }
        if (++widx_ >= N) widx_ = 0;
        return out;
    }
private:
    float sr_ = 48000; std::vector<float> buf_; int widx_ = 0; float delaySamps_ = 480;
    int   curTap_ = -1, nextTap_ = -1;
    float fade_ = 0.0f, fadeInc_ = 0.001f;
};

class Freeverb {  // (name kept for API compatibility — now an FDN)
public:
    void prepare(float sr) {
        sr_ = sr;
        // Coprime (prime) base delay lengths @48k, ~24–91 ms; scaled to sr.
        const int base48[kFDN] = {1153, 1559, 2017, 2503, 2917, 3389, 3797, 4357};
        const float srScl = sr / 48000.0f;
        for (int i = 0; i < kFDN; ++i) {
            baseLen_[i] = base48[i] * srScl;
            line_[i].prepare((int)std::ceil(baseLen_[i] * 2.2f) + 64);   // headroom for size×2 + mod
            // Decorrelated slow LFOs (Stautner/Puckette): each line gets its own
            // irrational rate so no two LFO periods ever line up → the comb
            // resonances never sit still and the tail stays glassy, never metallic.
            // Primary rate spread 0.13–1.45 Hz; a second, slower detuned LFO per
            // line (≈0.61× rate, golden-ratio offset) sums in for a non-periodic,
            // "breathing" Valhalla-style evolution. Per-line depth is staggered too.
            static const float rateHz[kFDN] = {0.131f, 0.273f, 0.452f, 0.617f,
                                               0.829f, 1.013f, 1.231f, 1.447f};
            modInc_[i]  = 2.0f * kPi * rateHz[i] / sr;
            modInc2_[i] = 2.0f * kPi * rateHz[i] * 0.618f / sr;   // detuned partner
            modPhase_[i]  = (float)i * 0.7f;
            modPhase2_[i] = (float)i * 1.37f + 0.5f;
            // Depth is a TIME (4.5–9 samples at 48 kHz), so scale it with the rate —
            // it used to be a fixed sample count, i.e. half the chorus depth at 96 kHz.
            modDepth_[i]  = kModDepth * srScl * (0.7f + 0.3f * std::sin(2.3f * (float)i));
        }
        // Input diffusion — 4 series allpasses, coprime, Dattorro-ish coeffs.
        const int dl[4] = {229, 173, 613, 449};
        const float dg[4] = {0.75f, 0.75f, 0.625f, 0.625f};
        for (int i = 0; i < 4; ++i) {
            diffL_[i].prepare((int)(dl[i] * srScl));      diffL_[i].setFeedback(dg[i]);
            diffR_[i].prepare((int)((dl[i] + 13) * srScl)); diffR_[i].setFeedback(dg[i]);
        }
        pd_.prepare(sr);
        loCut_.setHP(90.0f, sr); hiCut_.setLP(9000.0f, sr);
        kSize_ = 1.0f - std::exp(-1.0f / (0.060f * sr));   // SIZE glide
        kMix_  = 1.0f - std::exp(-1.0f / (0.010f * sr));   // MIX smoothing
        snap_ = true;
        dampSr_ = 0.0f;              // force the damping coefficients to be recomputed for this rate
        setDamping(dampParam_);
        reset();
        updateGains();
    }
    void reset() {
        for (int i = 0; i < kFDN; ++i) { line_[i].reset(); damp_[i].reset(); modPhase_[i] = (float)i * 0.7f; modPhase2_[i] = (float)i * 1.37f + 0.5f; }
        for (int i = 0; i < 4; ++i) { diffL_[i].reset(); diffR_[i].reset(); }
        pd_.reset(); loCut_.reset(); hiCut_.reset(); satState_ = 0.0f;
    }

    // ── Public API (unchanged) ───────────────────────────────────────────
    void setSize(float s)        { s = std::max(0.0f, std::min(1.0f, s)); if (s == size_) return; size_ = s; sizeScale_ = 0.5f + size_ * 1.5f; updateGains(); }
    void setDecaySec(float t)    { t = std::max(0.1f, t); if (t == decayS_) return; decayS_ = t; updateGains(); }
    void setDamping(float d) {
        d = std::max(0.0f, std::min(1.0f, d));
        if (d == dampParam_ && sr_ == dampSr_) return;
        dampParam_ = d; dampSr_ = sr_;
        // map 0..1 → one-pole coeff 0.05..0.6 AT 48 kHz, then convert that to the
        // same cutoff at the running rate. The raw coefficient used to be applied
        // at every rate, so the tail was an octave brighter at 96 kHz.
        const float a48 = 0.05f + d * 0.55f;
        const float fc  = -std::log(1.0f - a48) * 48000.0f / (2.0f * kPi);
        const float a   = 1.0f - std::exp(-2.0f * kPi * fc / sr_);
        for (int i = 0; i < kFDN; ++i) damp_[i].setCoeff(a);
    }
    void setPredelayMs(float ms) { pd_.setMs(ms); }
    void setLoCut(float hz)      { loCut_.setHP(hz, sr_); }
    void setHiCut(float hz)      { hiCut_.setLP(hz, sr_); }
    void setMix(float m)         { mix_ = std::max(0.0f, std::min(1.0f, m)); }

    inline void processFrame(float& L, float& R) {
        // SIZE glides (tape-style) and MIX is smoothed; both used to step once
        // per host buffer (clicks / zipper on automation).
        if (snap_) { sizeCur_ = sizeScale_; mixCur_ = mix_; snap_ = false; }
        sizeCur_ += kSize_ * (sizeScale_ - sizeCur_);
        mixCur_  += kMix_  * (mix_ - mixCur_);
        const float dryL = L, dryR = R;
        // Input: sum to mono, bandwidth-limit, pre-delay.
        float mono = 0.5f * (L + R) * gain_;
        mono = hiCut_.process(loCut_.process(mono));
        mono = pd_.process(mono);
        // Input diffusion (use the L chain for the injected mono; R chain
        // gives a decorrelated copy that widens the very early reflections).
        float dInj = mono, dWide = mono;
        for (int i = 0; i < 4; ++i) { dInj = diffL_[i].process(dInj); dWide = diffR_[i].process(dWide); }

        // FDN read + damp.
        float s[kFDN];
        for (int i = 0; i < kFDN; ++i) {
            modPhase_[i] += modInc_[i];
            if (modPhase_[i] > 6.28318530718f) modPhase_[i] -= 6.28318530718f;
            modPhase2_[i] += modInc2_[i];
            if (modPhase2_[i] > 6.28318530718f) modPhase2_[i] -= 6.28318530718f;
            // Sum two decorrelated LFOs (primary + detuned partner) → non-periodic
            // delay-length wander that smears comb resonances without audible vibrato.
            const float mod = modDepth_[i] *
                (0.72f * std::sin(modPhase_[i]) + 0.28f * std::sin(modPhase2_[i]));
            const float d = baseLen_[i] * sizeCur_ + mod;
            s[i] = damp_[i].process(line_[i].read(d));
        }
        // Householder mix: A = I − (2/N)·11ᵀ  →  y_i = s_i − (2/N)·Σs.
        float sum = 0.0f; for (int i = 0; i < kFDN; ++i) sum += s[i];
        sum *= (2.0f / (float)kFDN);
        // Inject input + per-line gain + gentle feedback saturation, write back.
        for (int i = 0; i < kFDN; ++i) {
            float v = (s[i] - sum) * g_[i] + dInj * 0.30f;
            v = v / (1.0f + 0.20f * v * v);          // soft saturator (tape/plate glue)
            line_[i].write(v);
        }
        // Decorrelated stereo taps.
        float wetL = (s[0] - s[2] + s[4] - s[6]) * 0.5f + dWide * 0.10f;
        float wetR = (s[1] - s[3] + s[5] - s[7]) * 0.5f + dInj  * 0.10f;

        L = (1.0f - mixCur_) * dryL + mixCur_ * wetL;
        R = (1.0f - mixCur_) * dryR + mixCur_ * wetR;
    }

private:
    void updateGains() {
        // Per-line feedback gain from RT60: g = 10^(−3·delaySec/RT60), clamped
        // for stability. Longer lines need higher gain for the same RT60.
        for (int i = 0; i < kFDN; ++i) {
            const float delaySec = (baseLen_[i] * sizeScale_) / sr_;
            float g = std::pow(10.0f, -3.0f * delaySec / decayS_);
            g_[i] = std::min(0.985f, g);
        }
    }

    static constexpr float kModDepth = 9.0f;   // max samples (per-line depth scales this)
    float sr_ = 48000;
    float size_ = 0.65f, sizeScale_ = 1.475f, decayS_ = 2.1f, mix_ = 0.35f;
    float gain_ = 0.5f;
    FracDelay line_[kFDN];
    OnePole   damp_[kFDN];
    float     baseLen_[kFDN] = {0};
    float     g_[kFDN] = {0};
    float     modInc_[kFDN] = {0}, modPhase_[kFDN] = {0};
    float     modInc2_[kFDN] = {0}, modPhase2_[kFDN] = {0};
    float     modDepth_[kFDN] = {0};
    Allpass   diffL_[4], diffR_[4];
    PreDelay  pd_;
    OnePole   loCut_, hiCut_;
    float     satState_ = 0.0f;
    // smoothing state
    float     sizeCur_ = 1.475f, mixCur_ = 0.35f, kSize_ = 0.0004f, kMix_ = 0.002f;
    float     dampParam_ = 0.4f, dampSr_ = 0.0f;
    bool      snap_ = true;
};

}
