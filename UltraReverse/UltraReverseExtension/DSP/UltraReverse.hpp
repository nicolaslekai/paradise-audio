//
//  UltraReverse.hpp — Paradise Audio "Ultra Reverse"
//
//  A reverse-reverb TEXTURE engine. Where a plain reverb adds a decaying tail
//  AFTER the note, Ultra Reverse blooms a reversed swell INTO and AROUND it,
//  then pours that swell through a lush 8-line FDN reverb with an octave-up
//  shimmer feedback path and a long ambient wash. It's an always-on overlay,
//  not a transient-triggered one-shot, so it works on sustained pads, vocals,
//  guitars and drones without any host automation.
//
//  Signal flow (mono internal, decorrelated-stereo out):
//
//      dry ─┬──────────────────────────────────────────────┐
//           │                                               │ (1-mix)
//      mono ┴─▶ preDelay ─▶ reverseEngine ─┐                ▼
//                              (windowed     ├─▶ inputDiffuse ─▶ FDN ─▶ tone ─▶ × mix ─▶ + ─▶ out
//                               reversed      │      ▲                 │
//                               grains)       │      └─ octaveUp ◀─────┘  (shimmer feedback)
//                  texture blends rev vs. dry ┘
//
//  Building blocks (FracDelay / Allpass / OnePole / PreDelay) and the FDN
//  topology are shared lineage with the suite's Reverb (Freeverb.hpp) so the
//  two plug-ins sound like siblings. The reverse grain engine, the granular
//  octave-up shimmer, and the tilt tone control are unique to Ultra Reverse.
//
//  References: Dattorro "Effect Design Pt.1" (diffusion + tank), J.O.Smith
//  CCRMA FDN notes, classic "reverse reverb" tape technique, granular
//  overlap-add pitch shifting (two 50%-overlapped Hann grains).
//

#pragma once
#include <algorithm>
#include <cmath>
#include <vector>
#include <atomic>

namespace urv {

constexpr float kPi  = 3.14159265358979323846f;
constexpr float k2Pi = 6.28318530717958647692f;
constexpr int   kFDN = 8;

// ── Fractional delay line (linear interp) for modulated reads. ──────────────
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

// ── Schroeder allpass — diffusion / smear. ──────────────────────────────────
class Allpass {
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

// ── One-pole LP/HP — damping + tone shelves. ────────────────────────────────
class OnePole {
public:
    void setLP(float fc, float sr) { const float w = k2Pi * std::max(20.0f, std::min(0.49f * sr, fc)) / sr; a_ = 1.0f - std::exp(-w); hp_ = false; }
    void setHP(float fc, float sr) { const float w = k2Pi * std::max(5.0f,  std::min(0.49f * sr, fc)) / sr; a_ = 1.0f - std::exp(-w); hp_ = true; }
    void setCoeff(float a) { a_ = std::max(0.0f, std::min(0.999f, a)); hp_ = false; }
    void reset() { z_ = 0.0f; }
    inline float process(float x) { z_ += a_ * (x - z_); return hp_ ? (x - z_) : z_; }
    inline float lp() const { return z_; }
private:
    float a_ = 0.5f, z_ = 0.0f; bool hp_ = false;
};

// ── Pre-delay (up to 0.5 s). ────────────────────────────────────────────────
class PreDelay {
public:
    void prepare(float sr) { sr_ = sr; buf_.assign((int)std::ceil(0.5f * sr) + 4, 0.0f); widx_ = 0; }
    void reset() { std::fill(buf_.begin(), buf_.end(), 0.0f); widx_ = 0; }
    void setMs(float ms) { delaySamps_ = std::max(1.0f, std::min((float)(buf_.size() - 2), ms * 0.001f * sr_)); }
    inline float process(float x) {
        if (buf_.empty()) return x;
        buf_[widx_] = x;
        const int N = (int)buf_.size();
        const int r = (widx_ - (int)delaySamps_ + N) % N;
        float out = buf_[r];
        if (++widx_ >= N) widx_ = 0;
        return out;
    }
private:
    float sr_ = 48000; std::vector<float> buf_; int widx_ = 0; float delaySamps_ = 480;
};

// ── Reverse grain engine ─────────────────────────────────────────────────────
//  Continuously writes the (pre-delayed) input into a circular buffer and reads
//  it BACKWARDS in overlapping Hann-windowed grains. Two grains run 50% out of
//  phase and are summed, so the output is a seamless, time-reversed stream of
//  the recent past — the "blooming reversed" source. Grain length = REVERSE
//  knob; longer = slower, more dramatic swells (and more latency-into-the-past,
//  which is musically the point: the swell appears to anticipate the note).
//
//  Each grain starts its read head one grain-length behind the write head and
//  walks it FORWARD through the buffer while the window fades in/out — because
//  the head was placed in the past and the buffer holds time-ordered samples,
//  walking forward replays that window… we instead walk the read head BACKWARD
//  from the present to reverse it. Implemented below by decrementing the read
//  offset across the grain.
class ReverseEngine {
public:
    void prepare(float sr) {
        sr_ = sr;
        // Max grain = 4.0 s — matches the REVERSE param's full 0.1..4.0 s travel.
        // Was 2.0 s, which left the top ~45% of the REVERSE knob dead (grains
        // clamped at ~2.2 s). Buffer holds 2× the max grain + headroom for the
        // two overlapping grains, so the whole sweep is now live and dramatic.
        bufLen_ = (int)std::ceil(4.0f * sr_ * 2.2f) + 64;
        buf_.assign(bufLen_, 0.0f); wr_ = 0;
        setGrainSec(0.6f);
        for (int g = 0; g < 2; ++g) { grainLen_[g] = pendingGrain_; inc_[g] = 1.0f / grainLen_[g]; }
        // Two grains, 50% offset.
        phase_[0] = 0.0f; phase_[1] = 0.5f;
    }
    void reset() {
        std::fill(buf_.begin(), buf_.end(), 0.0f); wr_ = 0; phase_[0] = 0.0f; phase_[1] = 0.5f;
        for (int g = 0; g < 2; ++g) { grainLen_[g] = pendingGrain_; inc_[g] = 1.0f / grainLen_[g]; }
    }
    /// The new length is LATCHED per grain at that grain's own wrap (2026-11-20).
    /// Changing it mid-grain used to jump readBehind and click on every REVERSE
    /// knob move; with a constant knob the output is unchanged.
    void setGrainSec(float s) {
        pendingGrain_ = std::max(64.0f, std::min((float)(bufLen_ / 2 - 8), s * sr_));
    }
    /// Apply the pending length to both grains right now (only when silent:
    /// after prepare/reset, before audio flows).
    void snapGrain() { for (int g = 0; g < 2; ++g) { grainLen_[g] = pendingGrain_; inc_[g] = 1.0f / grainLen_[g]; } }
    inline float process(float x) {
        buf_[wr_] = x;
        float out = 0.0f;
        for (int g = 0; g < 2; ++g) {
            float p = phase_[g];                 // 0..1 across the grain
            // Reversed read. The write head advances one sample per sample, so
            // for the read head to travel BACKWARDS through time it has to fall
            // behind by TWO samples per sample: readBehind grows 2·G over the
            // grain. (The old form, G·(1−p), only fell behind by −1/sample and
            // therefore played the window FORWARDS at double speed, an octave up.)
            float readBehind = 2.0f + 2.0f * grainLen_[g] * p;
            float rp = (float)wr_ - readBehind;
            while (rp < 0.0f) rp += (float)bufLen_;
            int i0 = (int)rp; float fr = rp - (float)i0;
            int i1 = i0 + 1; if (i1 >= bufLen_) i1 -= bufLen_;
            float s = buf_[i0] + fr * (buf_[i1] - buf_[i0]);
            // Hann window — equal-power-ish sum of two 50%-offset grains.
            float w = 0.5f * (1.0f - std::cos(k2Pi * p));
            out += s * w;
            p += inc_[g];
            if (p >= 1.0f) {                     // grain wrap: window is ~0 here, safe to latch
                p -= 1.0f;
                if (grainLen_[g] != pendingGrain_) { grainLen_[g] = pendingGrain_; inc_[g] = 1.0f / grainLen_[g]; }
            }
            phase_[g] = p;
        }
        if (++wr_ >= bufLen_) wr_ = 0;
        return out;
    }
private:
    float sr_ = 48000;
    std::vector<float> buf_; int bufLen_ = 0, wr_ = 0;
    float pendingGrain_ = 28800;
    float grainLen_[2] = {28800, 28800}, inc_[2] = {0.0f, 0.0f}, phase_[2] = {0.0f, 0.5f};
};

// ── Granular octave-up shifter (for shimmer feedback) ───────────────────────
//  Two 50%-overlapped Hann grains read at 2× the write rate → +1 octave.
//  Fixed ~80 ms grain. Kept deliberately simple/cheap; artefacts are masked by
//  the reverb wash it feeds back into.
class OctaveUp {
public:
    void prepare(float sr) {
        sr_ = sr;
        grain_ = std::max(256, (int)(0.080f * sr_));
        bufLen_ = grain_ * 4 + 16;
        buf_.assign(bufLen_, 0.0f); wr_ = 0;
        phase_[0] = 0.0f; phase_[1] = (float)grain_ * 0.5f;
    }
    void reset() { std::fill(buf_.begin(), buf_.end(), 0.0f); wr_ = 0; phase_[0] = 0.0f; phase_[1] = (float)grain_ * 0.5f; }
    inline float process(float x) {
        buf_[wr_] = x;
        float out = 0.0f;
        for (int g = 0; g < 2; ++g) {
            float ph = phase_[g];                       // 0..grain_
            float readBehind = (float)grain_ - ph;      // start old, catch up
            float rp = (float)wr_ - readBehind;
            while (rp < 0.0f) rp += (float)bufLen_;
            int i0 = (int)rp; float fr = rp - (float)i0;
            int i1 = i0 + 1; if (i1 >= bufLen_) i1 -= bufLen_;
            float s = buf_[i0] + fr * (buf_[i1] - buf_[i0]);
            float wp = ph / (float)grain_;
            float w = 0.5f * (1.0f - std::cos(k2Pi * wp));
            out += s * w;
            ph += 1.0f;                                  // write 1 + read 1 = 2× → +1 octave (2.0 gave 3×, a twelfth)
            if (ph >= (float)grain_) ph -= (float)grain_;
            phase_[g] = ph;
        }
        if (++wr_ >= bufLen_) wr_ = 0;
        return out;
    }
private:
    float sr_ = 48000;
    std::vector<float> buf_; int bufLen_ = 0, wr_ = 0, grain_ = 3840;
    float phase_[2] = {0.0f, 0.0f};
};

// ── The Ultra Reverse engine ────────────────────────────────────────────────
class UltraReverseEngine {
public:
    void prepare(float sr) {
        sr_ = sr;
        const int base48[kFDN] = {1153, 1559, 2017, 2503, 2917, 3389, 3797, 4357};
        const float srScl = sr / 48000.0f;
        for (int i = 0; i < kFDN; ++i) {
            baseLen_[i] = base48[i] * srScl;
            // 3.3× headroom so SIZE can stretch the lines up to ×3.0 (plus mod)
            // without wrapping — see the widened setSize() range below.
            line_[i].prepare((int)std::ceil(baseLen_[i] * 3.3f) + 64);
            damp_[i].setCoeff(0.25f);
            modInc_[i] = k2Pi * (0.5f + 0.10f * i) / sr;   // 0.5–1.3 Hz decorrelated
            modPhase_[i] = (float)i * 0.7f;
        }
        // Input diffusion (heavier than Reverb — Ultra leans diffuse/atmospheric).
        const int dl[6]   = {229, 173, 613, 449, 887, 1051};
        const float dg[6] = {0.78f, 0.78f, 0.70f, 0.70f, 0.62f, 0.62f};
        for (int i = 0; i < 6; ++i) {
            diff_[i].prepare((int)(dl[i] * srScl)); dgBase_[i] = dg[i];
        }
        // Actual feedbacks are set by setDiffusion() (called at the end of
        // prepare) so the DIFFUSION knob can drive the input smear, not just
        // the output.
        // Output smear allpasses (extra DIFFUSION on the wet, stereo-split).
        const int ol[4] = {331, 461, 251, 379};
        for (int i = 0; i < 4; ++i) { outAP_[i].prepare((int)(ol[i] * srScl)); outAP_[i].setFeedback(0.5f); }

        pd_.prepare(sr);
        rev_.prepare(sr);
        shimmer_.prepare(sr);
        loCut_.setHP(85.0f, sr);
        shimDamp_.setCoeff(0.35f);     // rolls highs off the shimmer feedback loop
        reset();
        updateGains();
        setTone(0.5f);
        setDiffusion(0.6f);
    }

    void reset() {
        for (int i = 0; i < kFDN; ++i) { line_[i].reset(); damp_[i].reset(); modPhase_[i] = (float)i * 0.7f; }
        for (int i = 0; i < 6; ++i) diff_[i].reset();
        for (int i = 0; i < 4; ++i) outAP_[i].reset();
        pd_.reset(); rev_.reset(); shimmer_.reset();
        loCut_.reset(); toneLoL_.reset(); toneHiL_.reset(); toneLoR_.reset(); toneHiR_.reset();
        shimDamp_.reset();
        shimFb_ = 0.0f;
    }

    // ── Parameters ──────────────────────────────────────────────────────────
    void setReverse(float sec)   { rev_.setGrainSec(std::max(0.1f, std::min(4.0f, sec))); }
    void snapReverse()           { rev_.snapGrain(); }
    // SIZE now spans ×0.35 (tight box) … ×3.0 (cavernous) — a ~8.5:1 sweep, up
    // from the old ×0.5…×2.0 (4:1), so the knob travels from small room to vast
    // cathedral. Buffer headroom widened to 3.3× in prepare() to match.
    void setSize(float s)        { size_ = std::max(0.0f, std::min(1.0f, s)); sizeScale_ = 0.35f + size_ * 2.65f; updateGains(); }
    void setDecaySec(float t)    { decayS_ = std::max(0.3f, std::min(30.0f, t)); updateGains(); }
    void setShimmer(float s)     { shimmer01_ = std::max(0.0f, std::min(1.0f, s)); }
    void setDiffusion(float d) {
        diffusion_ = std::max(0.0f, std::min(1.0f, d));
        // Drive BOTH the input diffusers and the output smear so the knob goes
        // from sparse/grainy/echoey (low) to liquid-glassy wash (high) — a far
        // wider, more obvious effect than smearing only the output tail.
        for (int i = 0; i < 6; ++i) diff_[i].setFeedback(dgBase_[i] * (0.30f + 0.70f * diffusion_));
        for (int i = 0; i < 4; ++i) outAP_[i].setFeedback(0.10f + diffusion_ * 0.78f);
    }
    void setTexture(float t)     { texture_ = std::max(0.0f, std::min(1.0f, t)); }
    void setPredelayMs(float ms) { pd_.setMs(std::max(0.0f, std::min(300.0f, ms))); }
    void setTone(float t) {
        // 0 = dark, 1 = bright. Tilt: blend a low-passed "body" against a
        // high-passed "air" version of the wet. Coeffs are computed here (not
        // per-sample) onto the four per-channel tilt filters.
        tone_ = std::max(0.0f, std::min(1.0f, t));
        const float lpHz = 600.0f  + tone_ * 1200.0f;   // 600..1800
        const float hpHz = 2000.0f + tone_ * 6000.0f;   // 2k..8k
        toneLoL_.setLP(lpHz, sr_); toneLoR_.setLP(lpHz, sr_);
        toneHiL_.setLP(hpHz, sr_); toneHiR_.setLP(hpHz, sr_);
    }
    void setMix(float m)         { mix_ = std::max(0.0f, std::min(1.0f, m)); }

    inline void processFrame(float& L, float& R) {
        const float dryL = L, dryR = R;
        float mono = 0.5f * (L + R);
        mono = loCut_.process(mono);
        mono = pd_.process(mono);

        // Reverse bloom: blend the reversed grain stream against the dry mono.
        const float rev = rev_.process(mono);
        // TEXTURE now drives the reverse far harder so the knob bites: at full
        // texture the reversed bloom is ~2.6× hotter than dry and the dry source
        // is fully swapped out, making the control dramatic across its travel.
        float src = (1.0f - texture_) * mono + texture_ * rev * 2.6f;

        // Heavy input diffusion → smear into a wash before the tank.
        float dInj = src;
        for (int i = 0; i < 6; ++i) dInj = diff_[i].process(dInj);

        // Octave-up shimmer fed from last frame's wet sum.
        const float shim = shimmer_.process(shimFb_) * shimmer01_;

        // FDN read + per-line damping + slow decorrelated modulation.
        float s[kFDN];
        for (int i = 0; i < kFDN; ++i) {
            modPhase_[i] += modInc_[i];
            if (modPhase_[i] > k2Pi) modPhase_[i] -= k2Pi;
            const float d = baseLen_[i] * sizeScale_ + kModDepth * std::sin(modPhase_[i]);
            s[i] = damp_[i].process(line_[i].read(d));
        }
        // Householder feedback: y_i = s_i − (2/N)·Σs (unitary, lossless mix).
        float sum = 0.0f; for (int i = 0; i < kFDN; ++i) sum += s[i];
        sum *= (2.0f / (float)kFDN);
        const float inject = dInj * 0.28f + shim * 0.62f;
        for (int i = 0; i < kFDN; ++i) {
            float v = (s[i] - sum) * g_[i] + inject;
            v = v / (1.0f + 0.18f * v * v);          // soft saturator (glue)
            line_[i].write(v);
        }

        // Decorrelated stereo taps.
        float wetL = (s[0] - s[2] + s[4] - s[6]) * 0.5f;
        float wetR = (s[1] - s[3] + s[5] - s[7]) * 0.5f;

        // Output diffusion smear (stereo).
        wetL = outAP_[0].process(outAP_[1].process(wetL));
        wetR = outAP_[2].process(outAP_[3].process(wetR));

        // ── Direct reversed-grain path ──────────────────────────────────────
        // Previously the reversed stream only entered the reverb tank, so the
        // "reverse" was buried in the wash and hard to hear. Add the backwards
        // grain stream straight into the wet output so it's audible on its own.
        // TEXTURE sets how prominent the reverse is (0 = pure reverb, 1 = heavy
        // backwards bloom). Predelayed `rev` is already the time-reversed source.
        const float revDirect = rev * texture_ * 1.8f;
        wetL += revDirect;
        wetR += revDirect;

        // Feed the mono wet sum into the shimmer for next frame (rising tail).
        // Damp + sub-unity scale so the octave-up regeneration loop always
        // decays eventually rather than self-sustaining forever, even with
        // SHIMMER and DECAY both maxed.
        shimFb_ = shimDamp_.process(0.70f * 0.5f * (wetL + wetR));

        // ── Direct shimmer sheen ────────────────────────────────────────────
        // Previously SHIMMER only trickled in through the feedback inject, so
        // the knob was faint until very high settings. Tap the octave-up grain
        // straight into the wet (scaled by shimmer01_, so it's silent at 0 and
        // a soaring octave halo at 1). Added AFTER shimFb_ is captured above, so
        // the regeneration-loop gain — and its stability — is unchanged.
        const float shimDirect = shim * 0.9f;
        wetL += shimDirect;
        wetR += shimDirect;

        // Tilt tone on the wet.
        wetL = tilt(toneLoL_, toneHiL_, wetL);
        wetR = tilt(toneLoR_, toneHiR_, wetR);

        L = (1.0f - mix_) * dryL + mix_ * wetL;
        R = (1.0f - mix_) * dryR + mix_ * wetR;

        // ── Live visual probe — two peak-bucketed streams: DRY input vs the
        // wet reverse-reverb tail. The UI draws them intertwined (dry down,
        // blooming wet up) so you watch the reversed swell rise in real time.
        const float dAbs = std::fabs(0.5f * (dryL + dryR));
        const float wAbs = std::fabs(0.5f * (wetL + wetR));
        if (dAbs > probeDryAcc_) probeDryAcc_ = dAbs;
        if (wAbs > probeWetAcc_) probeWetAcc_ = wAbs;
        if (++probeDiv_ >= kProbeDecim) {
            probeDiv_ = 0;
            const int w = probeW_.load(std::memory_order_relaxed);
            probeDry_[w & kProbeMask] = probeDryAcc_;
            probeWet_[w & kProbeMask] = probeWetAcc_;
            probeW_.store(w + 1, std::memory_order_relaxed);
            probeDryAcc_ = 0.0f; probeWetAcc_ = 0.0f;
        }
    }

    // Live scope probe — UI reads the most-recent `count` dry/wet peak buckets.
    static constexpr int probeSize() { return kProbeSize; }
    void readProbe(float *dryOut, float *wetOut, int count) const {
        const int n = std::min(count, kProbeSize);
        const int w = probeW_.load(std::memory_order_relaxed);
        for (int i = 0; i < n; ++i) {
            const int idx = (w - n + i) & kProbeMask;
            dryOut[i] = probeDry_[idx];
            wetOut[i] = probeWet_[idx];
        }
    }

private:
    // Per-channel tilt: blend low-passed body vs. high-passed air by `tone_`.
    // Coeffs already set in setTone(); here we only run the filters.
    inline float tilt(OnePole& lo, OnePole& hi, float x) {
        const float low  = lo.process(x);
        const float high = x - hi.process(x);          // one-pole HP
        return (1.0f - tone_) * (low * 1.1f) + tone_ * (x * 0.55f + high * 0.9f);
    }

    void updateGains() {
        for (int i = 0; i < kFDN; ++i) {
            const float delaySec = (baseLen_[i] * sizeScale_) / sr_;
            float g = std::pow(10.0f, -3.0f * delaySec / decayS_);
            g_[i] = std::min(0.991f, g);               // a touch hotter than Reverb for long washes
        }
    }

    static constexpr float kModDepth = 7.0f;           // samples

    // Live visual probe (dry + wet peak buckets). 256 × 128 ≈ 0.68 s @ 48 k.
    static constexpr int kProbeSize  = 256;
    static constexpr int kProbeMask  = kProbeSize - 1;
    static constexpr int kProbeDecim = 128;
    mutable float probeDry_[kProbeSize] = {0};
    mutable float probeWet_[kProbeSize] = {0};
    mutable std::atomic<int> probeW_{0};
    int   probeDiv_ = 0;
    float probeDryAcc_ = 0.0f, probeWetAcc_ = 0.0f;

    float sr_ = 48000;
    float size_ = 0.7f, sizeScale_ = 1.55f, decayS_ = 4.0f, mix_ = 0.4f;
    float texture_ = 0.7f, shimmer01_ = 0.3f, diffusion_ = 0.6f, tone_ = 0.5f;
    float shimFb_ = 0.0f;

    FracDelay line_[kFDN];
    OnePole   damp_[kFDN];
    float     baseLen_[kFDN] = {0};
    float     g_[kFDN] = {0};
    float     modInc_[kFDN] = {0}, modPhase_[kFDN] = {0};
    Allpass   diff_[6];
    float     dgBase_[6] = {0};                         // input-diffuser base feedbacks (scaled by DIFFUSION)
    Allpass   outAP_[4];
    PreDelay  pd_;
    ReverseEngine rev_;
    OctaveUp  shimmer_;
    OnePole   loCut_;
    OnePole   toneLoL_, toneHiL_, toneLoR_, toneHiR_;   // per-channel tilt state
    OnePole   shimDamp_;                                // shimmer feedback damping
};

} // namespace urv
