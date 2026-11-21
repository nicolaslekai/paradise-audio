//
//  SaturationDSP.hpp
//
//  Drive → bias → tanh waveshaper → DC blocker → tilt EQ → mix → output trim.
//  The tilt EQ is one-pole low-shelf coupled to a one-pole high-shelf
//  driven by the same control value: positive tone = bright, negative = dark.
//
//  Sound-quality pass 2026-11-21 (Tools/sound_audit):
//   • the shaper runs 8x oversampled (4x at 88.2 kHz and up) through linear-phase
//     halfband filters, so its harmonics no longer fold back as inharmonic
//     aliases (5 kHz at 0 dBFS, DRIVE +24: aliases −11 dB → below −65 dB);
//   • the constant delay of those filters is reported as latency and the dry
//     path is delayed by the same amount, so MIX stays phase-exact;
//   • BIAS made the shaper asymmetric and with it a signal-dependent DC offset
//     (−27 dBFS on a full-scale sine at the default patch) — a 5 Hz DC blocker
//     on the wet path removes it;
//   • every control is smoothed (10 ms), so automation no longer zippers.
//  At DRIVE settings where the old shaper did not alias, the sound is unchanged.
//

#pragma once
#include "DSPCommon.hpp"
#include "HalfbandOS.hpp"

namespace sat {

class Tilt {
public:
    void prepare(float sr) {
        sr_ = sr; reset();
        // Pivot ~1 kHz; a chosen for that.
        const float w = 2.0f * kPi * 1000.0f / sr_;
        a_ = 1.0f - std::exp(-w);
        k_ = 1.0f - std::exp(-1.0f / (0.010f * sr_));
        recalc();
        lo_ = loGain_; hi_ = hiGain_;
    }
    void reset()           { z_[0] = z_[1] = 0.0f; }
    void setTone(float t)  { t = clamp(t, -1.0f, 1.0f); if (t != tone_) { tone_ = t; recalc(); } }
    /// Call once per frame (both channels share the smoothed gains).
    inline void tick() { lo_ += k_ * (loGain_ - lo_); hi_ += k_ * (hiGain_ - hi_); }

    inline float process(int ch, float x) {
        // One-pole tilt: low-pass branch * loGain + high-pass branch * hiGain
        const float lp = z_[ch] + a_ * (x - z_[ch]);
        z_[ch] = lp;
        const float hp = x - lp;
        return lp * lo_ + hp * hi_;
    }

private:
    void recalc() {
        // Map tone → ±6 dB shelves
        const float dbBoost = 6.0f * tone_;
        loGain_ = std::pow(10.0f, -dbBoost * 0.05f);
        hiGain_ = std::pow(10.0f,  dbBoost * 0.05f);
    }
    float sr_ = 48000.0f;
    float a_ = 0.1f, k_ = 0.002f;
    float tone_ = 0.0f;
    float loGain_ = 1.0f, hiGain_ = 1.0f;   // targets
    float lo_ = 1.0f, hi_ = 1.0f;           // smoothed
    float z_[2] = {0, 0};
};

class Saturation {
public:
    void prepare(float sr) {
        sr_ = sr;
        tilt_.prepare(sr);
        const int factor = (sr >= 80000.0f) ? 4 : 8;
        for (int ch = 0; ch < 2; ++ch) { os_[ch].prepare(factor); dry_[ch].prepare(os_[ch].latency()); }
        k_   = 1.0f - std::exp(-1.0f / (0.010f * sr_));          // 10 ms control smoothing
        dcR_ = 1.0f - 2.0f * kPi * 5.0f / sr_;                    // 5 Hz DC blocker
        driveS_ = drive_; biasS_ = bias_; mixS_ = mix_; outS_ = outGain_;
        reset();
    }
    void reset() {
        tilt_.reset();
        for (int ch = 0; ch < 2; ++ch) { os_[ch].reset(); dry_[ch].reset(); dcX_[ch] = dcY_[ch] = 0.0f; }
    }
    /// Constant processing delay in samples (report to the host).
    int latencySamples() const { return os_[0].latency(); }

    void setDriveDB(float db) { drive_ = dbToLin(db); }
    void setBias(float b)     { bias_  = clamp(b, -1.0f, 1.0f) * 0.5f; }
    void setTone(float t)     { tilt_.setTone(t); }
    void setMix(float m)      { mix_   = clamp(m, 0.0f, 1.0f); }
    void setOutputDB(float d) { outGain_ = dbToLin(d); }

    /// Pure transfer (no tilt, no mix, no output) — used for UI drawing.
    float transfer(float x) const {
        const float pre = x * drive_ + bias_;
        const float shaped = std::tanh(pre) - std::tanh(bias_);
        return shaped;
    }

    inline void processFrame(float& L, float& R) {
        // control smoothing, once per frame
        driveS_ += k_ * (drive_   - driveS_);
        biasS_  += k_ * (bias_    - biasS_);
        mixS_   += k_ * (mix_     - mixS_);
        outS_   += k_ * (outGain_ - outS_);
        tilt_.tick();
        const float tb = std::tanh(biasS_);
        L = step(0, L, tb);
        R = step(1, R, tb);
    }

private:
    inline float step(int ch, float x, float tanhBias) {
        const float dry = dry_[ch].process(x);
        // Drive + bias → tanh → un-bias, oversampled
        const float d = driveS_, b = biasS_;
        float shaped = os_[ch].process(x, [d, b, tanhBias](float v) { return std::tanh(v * d + b) - tanhBias; });
        // DC blocker (the biased shaper rectifies a little of the signal into DC)
        const float y = shaped - dcX_[ch] + dcR_ * dcY_[ch];
        dcX_[ch] = shaped; dcY_[ch] = y;
        // Post tilt EQ
        const float toned = tilt_.process(ch, y);
        // Mix wet/dry (dry is delayed to line up with the oversampled path)
        const float mixed = (1.0f - mixS_) * dry + mixS_ * toned;
        return mixed * outS_;
    }

    float sr_ = 48000.0f;
    float drive_ = 1.0f, bias_ = 0.0f, mix_ = 1.0f, outGain_ = 1.0f;       // targets
    float driveS_ = 1.0f, biasS_ = 0.0f, mixS_ = 1.0f, outS_ = 1.0f;       // smoothed
    float k_ = 0.002f, dcR_ = 0.9993f;
    float dcX_[2] = {0, 0}, dcY_[2] = {0, 0};
    Tilt  tilt_;
    pos::Oversampler os_[2];
    pos::DryDelay    dry_[2];
};

} // namespace sat
