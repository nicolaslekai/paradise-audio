//
//  DelayLine.hpp
//  Mono delay line with linear interpolation. Maximum 2 s at any sample rate.
//

#pragma once
#include "DSPCommon.hpp"

namespace dly {

class DelayLine {
public:
    void prepare(float sr, float maxMs = 2000.0f) {
        sr_ = sr;
        const int maxN = (int)std::ceil(maxMs * 0.001f * sr) + 4;
        buf_.assign(maxN, 0.0f);
        writeIdx_ = 0;
    }
    void reset() { std::fill(buf_.begin(), buf_.end(), 0.0f); writeIdx_ = 0; }

    /// Write a sample, then read at a given delay in samples.
    /// 4-point Hermite interpolation: a fractional delay (e.g. 375 ms at
    /// 44.1 kHz = 16537.5 samples) no longer costs the repeats their top end the
    /// way the old 2-point linear read did (−2.4 dB at 10 kHz per pass there),
    /// so the echoes sound the same at every sample rate.
    inline float tap(float delaySamples, float input) {
        if (buf_.empty()) return input;
        buf_[writeIdx_] = input;
        const int N = (int)buf_.size();
        const float d = clamp(delaySamples, 2.0f, (float)(N - 3));
        const int   i0 = (int)d;
        const float frac = d - i0;
        int r0 = writeIdx_ - i0; if (r0 < 0) r0 += N;        // delay i0
        float y;
        if (frac == 0.0f) {
            y = buf_[r0];
        } else {
            int rm = r0 + 1; if (rm >= N) rm -= N;             // delay i0-1
            int r1 = r0 - 1; if (r1 < 0) r1 += N;              // delay i0+1
            int r2 = r1 - 1; if (r2 < 0) r2 += N;              // delay i0+2
            const float xm = buf_[rm], x0 = buf_[r0], x1 = buf_[r1], x2 = buf_[r2];
            const float c1 = 0.5f * (x1 - xm);
            const float c2 = xm - 2.5f * x0 + 2.0f * x1 - 0.5f * x2;
            const float c3 = 0.5f * (x2 - xm) + 1.5f * (x0 - x1);
            y = ((c3 * frac + c2) * frac + c1) * frac + x0;
        }
        if (++writeIdx_ >= N) writeIdx_ = 0;
        return y;
    }

    float sampleRate() const { return sr_; }

private:
    float sr_ = 48000;
    int   writeIdx_ = 0;
    std::vector<float> buf_;
};

class OnePoleLP {
public:
    void set(float fc, float sr) {
        const float w = 2.0f * kPi * clamp(fc, 20.0f, 0.49f * sr) / sr;
        a_ = 1.0f - std::exp(-w);
    }
    void setCoeff(float a) { a_ = a; }
    inline float process(float x) { z_ += a_ * (x - z_); return z_; }
    void reset() { z_ = 0.0f; }
private:
    float a_ = 0.5f;
    float z_ = 0.0f;
};

// One-pole highpass = input minus its lowpass. Used in the dub feedback path
// to roll off low bass so repeats don't pile up into mud.
class OnePoleHP {
public:
    void set(float fc, float sr) {
        const float w = 2.0f * kPi * clamp(fc, 5.0f, 0.49f * sr) / sr;
        a_ = 1.0f - std::exp(-w);
    }
    inline float process(float x) { z_ += a_ * (x - z_); return x - z_; }
    void reset() { z_ = 0.0f; }
private:
    float a_ = 0.1f;
    float z_ = 0.0f;
};

// Warm, self-limiting saturator for the feedback loop — the BBD/tape "degrade
// into a nice saturated mess" character. `warm` (0..1) blends clean→driven.
inline float dubSaturate(float x, float warm) {
    // tanh(k·x)/k has exactly unity slope at zero, so the loop's small-signal
    // gain is the FEEDBACK knob and nothing more: repeats always die away.
    // (The previous make-up term pushed the small-signal gain to 1.8–7×, so
    // with FEEDBACK above ~0.25 the TAPE / AMBIENT presets rang forever.)
    // Loud repeats get squashed tape-style; quiet ones decay cleanly.
    const float k = 1.8f + 3.2f * warm;
    const float driven = std::tanh(k * x) / k;
    return (1.0f - warm) * x + warm * driven;
}

// Dub-style stereo delay. The feedback path is, in order:
//   highpass (bass cut) → lowpass (high tame, wobble-modulated) → warm saturator
// which is the classic filtered-feedback dub/echo chain — repeats lose lows,
// get progressively darker, and saturate gently so the loop self-limits.
class StereoDelay {
public:
    void prepare(float sr) {
        sr_ = sr;
        dl_[0].prepare(sr); dl_[1].prepare(sr);
        fbLP_[0].set(baseLP_, sr); fbLP_[1].set(baseLP_, sr);
        fbHP_[0].set(bassHz_, sr); fbHP_[1].set(bassHz_, sr);
        fbLP_[0].reset(); fbLP_[1].reset(); fbHP_[0].reset(); fbHP_[1].reset();
        lfoPhase_ = 0.0f;
        lastL_ = lastR_ = 0.0f;
        glide_  = 1.0f - std::exp(-1.0f / (0.025f * sr_));
        kFast_  = 1.0f - std::exp(-1.0f / (0.010f * sr_));   // MIX / FEEDBACK smoothing
        kSlow_  = 1.0f - std::exp(-1.0f / (0.050f * sr_));   // WOBBLE depth (moves the read head)
        snap_ = true;
    }
    void reset() {
        dl_[0].reset(); dl_[1].reset();
        fbLP_[0].reset(); fbLP_[1].reset(); fbHP_[0].reset(); fbHP_[1].reset();
        lfoPhase_ = 0.0f; lastL_ = lastR_ = 0.0f;
        curL_ = curR_ = -1.0f;
    }

    void setTimes(float ms_L, float ms_R) { msL_ = ms_L; msR_ = ms_R; }
    void setFeedback(float f)             { fb_  = clamp(f, 0.0f, 0.98f); }
    void setFilterFreq(float hz)          { baseLP_ = clamp(hz, 200.0f, 18000.0f); }   // "HIGH" tame
    void setBass(float hz)                { bassHz_ = clamp(hz, 20.0f, 1200.0f); fbHP_[0].set(bassHz_, sr_); fbHP_[1].set(bassHz_, sr_); } // "BASS" cut
    void setWobble(float depth)           { wobDepth_ = clamp(depth, 0.0f, 1.0f); }     // tone-band wobble depth
    void setWobbleRate(float hz)          { wobRate_ = clamp(hz, 0.02f, 12.0f); }
    void setWarmth(float w)               { warm_ = clamp(w, 0.0f, 1.0f); }
    void setMix(float m)                  { mix_ = clamp(m, 0.0f, 1.0f); }
    void setPingPong(bool p)              { pingPong_ = p; }

    inline void processFrame(float& L, float& R) {
        const float dryL = L, dryR = R;
        // Delay time glides toward the knob / sync value (~25 ms), tape-style,
        // instead of hopping the read head per buffer (clicks on TIME drags,
        // on the SYNC toggle and on tempo changes — repeated by the feedback).
        const float tgtL = msL_ * 0.001f * sr_, tgtR = msR_ * 0.001f * sr_;
        if (curL_ < 0.0f) { curL_ = tgtL; curR_ = tgtR; }
        if (curL_ != tgtL) { curL_ += (tgtL - curL_) * glide_; if (std::fabs(tgtL - curL_) < 1e-3f) curL_ = tgtL; }
        if (curR_ != tgtR) { curR_ += (tgtR - curR_) * glide_; if (std::fabs(tgtR - curR_) < 1e-3f) curR_ = tgtR; }
        const float dL = curL_;
        const float dR = curR_;
        // MIX, FEEDBACK and WOBBLE depth are smoothed: they used to step once
        // per host buffer (zipper on MIX, clicks from the read head jumping when
        // WOBBLE moved).
        if (snap_) { mixS_ = mix_; fbS_ = fb_; wobS_ = wobDepth_; snap_ = false; }
        mixS_ += kFast_ * (mix_ - mixS_);
        fbS_  += kFast_ * (fb_ - fbS_);
        wobS_ += kSlow_ * (wobDepth_ - wobS_);
        if (wobS_ < 1e-6f && wobDepth_ == 0.0f) wobS_ = 0.0f;

        // Wobble: an LFO sweeps the feedback lowpass ± up to ~an octave, the
        // signature dub tone-band movement. Update the shared LP coefficient.
        lfoPhase_ += 2.0f * kPi * wobRate_ / sr_;
        if (lfoPhase_ > 2.0f * kPi) lfoPhase_ -= 2.0f * kPi;
        const float lfo   = std::sin(lfoPhase_);
        const float lpFc  = clamp(wobS_ > 0.0f ? baseLP_ * std::pow(2.0f, wobS_ * lfo) : baseLP_, 80.0f, 0.49f * sr_);
        const float w     = 2.0f * kPi * lpFc / sr_;
        const float aLP   = 1.0f - std::exp(-w);
        fbLP_[0].setCoeff(aLP); fbLP_[1].setCoeff(aLP);

        // Feedback chain: HP (bass cut) → LP (high tame + wobble) → warm sat.
        float fbSrcL = pingPong_ ? lastR_ : lastL_;
        float fbSrcR = pingPong_ ? lastL_ : lastR_;
        fbSrcL = dubSaturate(fbLP_[0].process(fbHP_[0].process(fbSrcL)), warm_);
        fbSrcR = dubSaturate(fbLP_[1].process(fbHP_[1].process(fbSrcR)), warm_);

        // Tape-style TIME wobble: the same LFO also warps the read position so
        // pitch sags/rises on the repeats — the classic, obviously-audible
        // wow/flutter. Up to ~2% of the delay time at full WOBBLE.
        const float wobSampL = wobS_ * 0.020f * dL * lfo;
        const float wobSampR = wobS_ > 0.0f ? wobS_ * 0.020f * dR * std::sin(lfoPhase_ + 1.7f) : 0.0f;
        const float inL = dryL + fbSrcL * fbS_;
        const float inR = dryR + fbSrcR * fbS_;
        const float outL = dl_[0].tap(std::max(1.0f, dL + wobSampL), inL);
        const float outR = dl_[1].tap(std::max(1.0f, dR + wobSampR), inR);
        lastL_ = outL; lastR_ = outR;
        L = (1.0f - mixS_) * dryL + mixS_ * outL;
        R = (1.0f - mixS_) * dryR + mixS_ * outR;
    }

private:
    float sr_ = 48000;
    float msL_ = 250, msR_ = 375;
    float curL_ = -1.0f, curR_ = -1.0f;   // glided delay times (samples); <0 = unset
    float fb_ = 0.42f, mix_ = 0.28f;
    float baseLP_ = 3200.0f, bassHz_ = 120.0f;
    float wobDepth_ = 0.0f, wobRate_ = 1.0f, warm_ = 0.3f;
    float lfoPhase_ = 0.0f;
    bool  pingPong_ = true;
    float lastL_ = 0, lastR_ = 0;
    float glide_ = 0.001f, kFast_ = 0.002f, kSlow_ = 0.0004f;
    float mixS_ = 0.28f, fbS_ = 0.42f, wobS_ = 0.0f;
    bool  snap_ = true;
    DelayLine dl_[2];
    OnePoleLP fbLP_[2];
    OnePoleHP fbHP_[2];
};

}
