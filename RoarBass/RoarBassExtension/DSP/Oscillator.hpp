//
//  Oscillator.hpp
//  RoarBass
//
//  Bandlimited oscillators (PolyBLEP saw/square) and a clean sine for the sub layer.
//

#pragma once
#include "DSPCommon.hpp"

namespace roarbass {

enum class OscShape : int {
    Sine = 0,
    Triangle = 1,
    Saw = 2,
    Square = 3
};

class Oscillator {
public:
    void reset(float sr) {
        sr_ = sr;
        phase_ = 0.0f;
        setFrequency(110.0f);
    }
    void setFrequency(float hz) {
        freq_ = hz;
        inc_ = freq_ / sr_; // normalized 0..1
    }
    void setShape(OscShape s) { shape_ = s; }

    inline float tick() {
        float t = phase_;
        float out = 0.0f;
        switch (shape_) {
            case OscShape::Sine:
                out = std::sin(t * kTwoPi);
                break;
            case OscShape::Triangle:
                // naive triangle from phase
                out = 4.0f * std::fabs(t - 0.5f) - 1.0f;
                break;
            case OscShape::Saw: {
                out = 2.0f * t - 1.0f;
                out -= polyBLEP(t, inc_);
                break;
            }
            case OscShape::Square: {
                out = (t < 0.5f) ? 1.0f : -1.0f;
                out += polyBLEP(t, inc_);
                float t2 = t + 0.5f;
                if (t2 >= 1.0f) t2 -= 1.0f;
                out -= polyBLEP(t2, inc_);
                break;
            }
        }
        phase_ += inc_;
        if (phase_ >= 1.0f) phase_ -= 1.0f;
        return out;
    }

    inline float tickPhaseMod(float phaseOffset) {
        // FM/PM helper — adds phase offset for this sample without disturbing inc.
        float t = phase_ + phaseOffset;
        t -= std::floor(t);
        float out;
        switch (shape_) {
            case OscShape::Sine:
                out = std::sin(t * kTwoPi);
                break;
            case OscShape::Triangle:
                out = 4.0f * std::fabs(t - 0.5f) - 1.0f;
                break;
            case OscShape::Saw:
                out = 2.0f * t - 1.0f - polyBLEP(t, inc_);
                break;
            case OscShape::Square: {
                out = (t < 0.5f) ? 1.0f : -1.0f;
                out += polyBLEP(t, inc_);
                float t2 = t + 0.5f; if (t2 >= 1.0f) t2 -= 1.0f;
                out -= polyBLEP(t2, inc_);
                break;
            }
        }
        phase_ += inc_;
        if (phase_ >= 1.0f) phase_ -= 1.0f;
        return out;
    }

    float frequency() const { return freq_; }
    float phase()     const { return phase_; }
    void  resetPhase()      { phase_ = 0.0f; }

private:
    // PolyBLEP residual to remove aliasing at discontinuities.
    static inline float polyBLEP(float t, float dt) {
        if (t < dt) {
            t /= dt;
            return t + t - t * t - 1.0f;
        } else if (t > 1.0f - dt) {
            t = (t - 1.0f) / dt;
            return t * t + t + t + 1.0f;
        }
        return 0.0f;
    }

    float sr_   = kDefaultSR;
    float freq_ = 110.0f;
    float inc_  = 0.0f;
    float phase_= 0.0f;
    OscShape shape_ = OscShape::Saw;
};

} // namespace roarbass
