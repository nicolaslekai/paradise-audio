//
//  Biquad.hpp
//
//  Standard direct-form-I biquad with RBJ "cookbook" coefficient calculators
//  for the four filter types we need: high-pass, low-pass, low-shelf,
//  high-shelf. Also exposes a complex magnitude-response query (for drawing
//  the EQ curve in the UI).
//

#pragma once

#include "DSPCommon.hpp"
#include <complex>

namespace eq {

class Biquad {
public:
    enum Type { kHighPass, kLowPass, kLowShelf, kHighShelf, kPeaking, kBypass };

    void reset() { x1_ = x2_ = y1_ = y2_ = 0.0f; }

    inline float process(float x) {
        const float y = b0_ * x + b1_ * x1_ + b2_ * x2_ - a1_ * y1_ - a2_ * y2_;
        x2_ = x1_; x1_ = x;
        y2_ = y1_; y1_ = y;
        return y;
    }

    void setType(Type t) { type_ = t; }
    Type type() const { return type_; }

    /// Recompute coefficients. `gainDB` is only used by the shelf types.
    void update(float sampleRate, float freqHz, float q, float gainDB) {
        sr_ = sampleRate;
        fc_ = clamp(freqHz, 5.0f, 0.49f * sampleRate);
        q_  = std::max(0.05f, q);
        gain_ = gainDB;
        recalc();
    }

    /// Magnitude (linear) at frequency f, in Hz, for current coefficients.
    float magnitudeAt(float f) const {
        const float w = 2.0f * kPi * f / sr_;
        std::complex<float> z = std::polar(1.0f, -w);
        std::complex<float> num = b0_ + b1_ * z + b2_ * z * z;
        std::complex<float> den = 1.0f + a1_ * z + a2_ * z * z;
        return std::abs(num / den);
    }

private:
    void recalc() {
        const float w0 = 2.0f * kPi * fc_ / sr_;
        const float cw = std::cos(w0), sw = std::sin(w0);
        const float A  = std::pow(10.0f, gain_ * 0.025f);   // shelf amp factor (sqrt of linear gain)
        const float alpha = sw / (2.0f * q_);

        float b0=0, b1=0, b2=0, a0=1, a1=0, a2=0;

        switch (type_) {
            case kHighPass: {
                b0 = (1.0f + cw) * 0.5f;
                b1 = -(1.0f + cw);
                b2 = (1.0f + cw) * 0.5f;
                a0 = 1.0f + alpha;
                a1 = -2.0f * cw;
                a2 = 1.0f - alpha;
                break;
            }
            case kLowPass: {
                b0 = (1.0f - cw) * 0.5f;
                b1 = 1.0f - cw;
                b2 = (1.0f - cw) * 0.5f;
                a0 = 1.0f + alpha;
                a1 = -2.0f * cw;
                a2 = 1.0f - alpha;
                break;
            }
            case kLowShelf: {
                const float beta = 2.0f * std::sqrt(A) * alpha;
                b0 =       A * ((A + 1.0f) - (A - 1.0f) * cw + beta);
                b1 = 2.0f * A * ((A - 1.0f) - (A + 1.0f) * cw);
                b2 =       A * ((A + 1.0f) - (A - 1.0f) * cw - beta);
                a0 =            (A + 1.0f) + (A - 1.0f) * cw + beta;
                a1 =    -2.0f * ((A - 1.0f) + (A + 1.0f) * cw);
                a2 =            (A + 1.0f) + (A - 1.0f) * cw - beta;
                break;
            }
            case kHighShelf: {
                const float beta = 2.0f * std::sqrt(A) * alpha;
                b0 =       A * ((A + 1.0f) + (A - 1.0f) * cw + beta);
                b1 = -2.0f * A * ((A - 1.0f) + (A + 1.0f) * cw);
                b2 =       A * ((A + 1.0f) + (A - 1.0f) * cw - beta);
                a0 =            (A + 1.0f) - (A - 1.0f) * cw + beta;
                a1 =     2.0f * ((A - 1.0f) - (A + 1.0f) * cw);
                a2 =            (A + 1.0f) - (A - 1.0f) * cw - beta;
                break;
            }
            case kPeaking: {
                // RBJ peaking EQ — symmetric bell around fc, ±gainDB at peak.
                // Q controls width: lower Q = wider bell. We use a moderate
                // default (set from EQEngine).
                const float A2 = std::pow(10.0f, gain_ * 0.025f);  // sqrt(linear)
                b0 = 1.0f + alpha * A2;
                b1 = -2.0f * cw;
                b2 = 1.0f - alpha * A2;
                a0 = 1.0f + alpha / A2;
                a1 = -2.0f * cw;
                a2 = 1.0f - alpha / A2;
                break;
            }
            case kBypass:
                b0 = 1.0f; b1 = 0.0f; b2 = 0.0f;
                a0 = 1.0f; a1 = 0.0f; a2 = 0.0f;
                break;
        }
        const float invA0 = 1.0f / a0;
        b0_ = b0 * invA0;
        b1_ = b1 * invA0;
        b2_ = b2 * invA0;
        a1_ = a1 * invA0;
        a2_ = a2 * invA0;
    }

    Type  type_ = kBypass;
    float sr_   = 48000.0f;
    float fc_   = 1000.0f;
    float q_    = 0.7071f;
    float gain_ = 0.0f;

    // Coefficients (a0 normalized to 1)
    float b0_ = 1, b1_ = 0, b2_ = 0;
    float a1_ = 0, a2_ = 0;

    // State
    float x1_ = 0, x2_ = 0, y1_ = 0, y2_ = 0;
};

} // namespace eq
