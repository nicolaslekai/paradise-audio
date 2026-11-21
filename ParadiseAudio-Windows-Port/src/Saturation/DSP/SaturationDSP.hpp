//
//  SaturationDSP.hpp
//
//  Drive → bias → tanh waveshaper → tilt EQ → mix → output trim.
//  The tilt EQ is one-pole low-shelf coupled to a one-pole high-shelf
//  driven by the same control value: positive tone = bright, negative = dark.
//

#pragma once
#include "DSPCommon.hpp"

namespace sat {

class Tilt {
public:
    void prepare(float sr) { sr_ = sr; reset(); }
    void reset()           { z_[0] = z_[1] = 0.0f; }
    void setTone(float t)  { tone_ = clamp(t, -1.0f, 1.0f); recalc(); }

    inline float process(int ch, float x) {
        // One-pole tilt: low-pass branch * loGain + high-pass branch * hiGain
        const float lp = z_[ch] + a_ * (x - z_[ch]);
        z_[ch] = lp;
        const float hp = x - lp;
        return lp * loGain_ + hp * hiGain_;
    }

private:
    void recalc() {
        // Pivot ~1 kHz; a chosen for that.
        const float fc = 1000.0f;
        const float w  = 2.0f * kPi * fc / sr_;
        a_ = 1.0f - std::exp(-w);
        // Map tone → ±6 dB shelves
        const float dbBoost = 6.0f * tone_;
        loGain_ = std::pow(10.0f, -dbBoost * 0.05f);
        hiGain_ = std::pow(10.0f,  dbBoost * 0.05f);
    }
    float sr_ = 48000.0f;
    float a_ = 0.1f;
    float tone_ = 0.0f;
    float loGain_ = 1.0f, hiGain_ = 1.0f;
    float z_[2] = {0, 0};
};

class Saturation {
public:
    void prepare(float sr) { sr_ = sr; tilt_.prepare(sr); }
    void reset()           { tilt_.reset(); }

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
        L = step(0, L);
        R = step(1, R);
    }

private:
    inline float step(int ch, float x) {
        const float dry = x;
        // Drive + bias → tanh → un-bias
        const float pre = x * drive_ + bias_;
        const float shaped = std::tanh(pre) - std::tanh(bias_);
        // Post tilt EQ
        const float toned = tilt_.process(ch, shaped);
        // Mix wet/dry
        const float mixed = (1.0f - mix_) * dry + mix_ * toned;
        return mixed * outGain_;
    }

    float sr_ = 48000.0f;
    float drive_ = 1.0f;
    float bias_  = 0.0f;
    float mix_   = 1.0f;
    float outGain_ = 1.0f;
    Tilt  tilt_;
};

} // namespace sat
