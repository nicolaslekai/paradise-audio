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

    void reset() { x1_ = x2_ = y1_ = y2_ = 0.0; }

    // Double-precision recursion. In 32-bit float a direct-form biquad tuned
    // far below the sample rate (the 20–40 Hz high-pass, worse at 96 kHz) rounds
    // its feedback state so coarsely that it adds a noise floor around
    // −95 dBFS under any signal (measured: THD+N −76 dB at −18 dBFS with HP at
    // 20 Hz). In double that floor drops below −150 dB at no audible CPU cost.
    inline float process(float x) {
        const double xd = (double)x;
        const double y = b0_ * xd + b1_ * x1_ + b2_ * x2_ - a1_ * y1_ - a2_ * y2_;
        x2_ = x1_; x1_ = xd;
        y2_ = y1_; y1_ = y;
        return (float)y;
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
        const double w = 2.0 * 3.14159265358979323846 * (double)f / (double)sr_;
        std::complex<double> z = std::polar(1.0, -w);
        std::complex<double> num = b0_ + b1_ * z + b2_ * z * z;
        std::complex<double> den = 1.0 + a1_ * z + a2_ * z * z;
        return (float)std::abs(num / den);
    }

private:
    void recalc() {
        const double pi = 3.14159265358979323846;
        const double w0 = 2.0 * pi * (double)fc_ / (double)sr_;
        const double cw = std::cos(w0), sw = std::sin(w0);
        const double A  = std::pow(10.0, (double)gain_ * 0.025);   // shelf amp factor (sqrt of linear gain)
        const double alpha = sw / (2.0 * (double)q_);

        double b0=0, b1=0, b2=0, a0=1, a1=0, a2=0;

        switch (type_) {
            case kHighPass: {
                b0 = (1.0 + cw) * 0.5;
                b1 = -(1.0 + cw);
                b2 = (1.0 + cw) * 0.5;
                a0 = 1.0 + alpha;
                a1 = -2.0 * cw;
                a2 = 1.0 - alpha;
                break;
            }
            case kLowPass: {
                b0 = (1.0 - cw) * 0.5;
                b1 = 1.0 - cw;
                b2 = (1.0 - cw) * 0.5;
                a0 = 1.0 + alpha;
                a1 = -2.0 * cw;
                a2 = 1.0 - alpha;
                break;
            }
            case kLowShelf: {
                const double beta = 2.0 * std::sqrt(A) * alpha;
                b0 =      A * ((A + 1.0) - (A - 1.0) * cw + beta);
                b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cw);
                b2 =      A * ((A + 1.0) - (A - 1.0) * cw - beta);
                a0 =           (A + 1.0) + (A - 1.0) * cw + beta;
                a1 =   -2.0 * ((A - 1.0) + (A + 1.0) * cw);
                a2 =           (A + 1.0) + (A - 1.0) * cw - beta;
                break;
            }
            case kHighShelf: {
                const double beta = 2.0 * std::sqrt(A) * alpha;
                b0 =       A * ((A + 1.0) + (A - 1.0) * cw + beta);
                b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cw);
                b2 =       A * ((A + 1.0) + (A - 1.0) * cw - beta);
                a0 =            (A + 1.0) - (A - 1.0) * cw + beta;
                a1 =     2.0 * ((A - 1.0) - (A + 1.0) * cw);
                a2 =            (A + 1.0) - (A - 1.0) * cw - beta;
                break;
            }
            case kPeaking: {
                // RBJ peaking EQ — symmetric bell around fc, ±gainDB at peak.
                // Q controls width: lower Q = wider bell. We use a moderate
                // default (set from EQEngine).
                b0 = 1.0 + alpha * A;
                b1 = -2.0 * cw;
                b2 = 1.0 - alpha * A;
                a0 = 1.0 + alpha / A;
                a1 = -2.0 * cw;
                a2 = 1.0 - alpha / A;
                break;
            }
            case kBypass:
                b0 = 1.0; b1 = 0.0; b2 = 0.0;
                a0 = 1.0; a1 = 0.0; a2 = 0.0;
                break;
        }
        const double invA0 = 1.0 / a0;
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
    double b0_ = 1, b1_ = 0, b2_ = 0;
    double a1_ = 0, a2_ = 0;

    // State
    double x1_ = 0, x2_ = 0, y1_ = 0, y2_ = 0;
};

} // namespace eq
