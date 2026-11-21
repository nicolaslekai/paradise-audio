//
//  LadderFilter.hpp
//  RoarBass
//
//  Zero-delay-feedback 4-pole ladder filter (Huovilainen-style),
//  with internal tanh saturation for warmth and a drive control.
//

#pragma once
#include "DSPCommon.hpp"

namespace roarbass {

class LadderFilter {
public:
    void reset(float sr) {
        sr_ = sr;
        for (int i = 0; i < 4; ++i) { z_[i] = 0.0f; zd_[i] = 0.0f; }
        setCutoff(1000.0f);
        setResonance(0.0f);
    }

    void setCutoff(float hz) {
        cutoff_ = clampf(hz, 20.0f, std::min(sr_ * 0.45f, 18000.0f));
        // pre-warped coefficient
        float wd = kTwoPi * cutoff_;
        float T  = 1.0f / sr_;
        float wa = (2.0f / T) * std::tan(wd * T * 0.5f);
        g_       = wa * T * 0.5f;
        G_       = g_ / (1.0f + g_);
    }

    void setResonance(float r) {
        // 0..1 mapped to 0..4 internal feedback; allows self-oscillation near 1.
        res_ = clamp01(r) * 4.0f;
    }

    void setDrive(float d) {
        // 0..1 mapped to 1..6 linear pre-gain
        drive_ = 1.0f + clamp01(d) * 5.0f;
    }

    inline float process(float x) {
        // Drive into the filter
        float u = fastTanh(x * drive_);

        // feedback estimate from previous outputs (ZDF approx)
        float fb = res_ * z_[3];
        float input = u - fb;

        // 4 cascaded one-poles with non-linearity per stage
        float y0 = G_ * (input - zd_[0]) + zd_[0];
        zd_[0]   = G_ * (input - zd_[0]) + y0;
        y0       = fastTanh(y0);

        float y1 = G_ * (y0 - zd_[1]) + zd_[1];
        zd_[1]   = G_ * (y0 - zd_[1]) + y1;

        float y2 = G_ * (y1 - zd_[2]) + zd_[2];
        zd_[2]   = G_ * (y1 - zd_[2]) + y2;

        float y3 = G_ * (y2 - zd_[3]) + zd_[3];
        zd_[3]   = G_ * (y2 - zd_[3]) + y3;

        z_[3] = y3;
        return y3;
    }

private:
    float sr_     = kDefaultSR;
    float cutoff_ = 1000.0f;
    float res_    = 0.0f;
    float drive_  = 1.0f;
    float g_ = 0.0f, G_ = 0.0f;
    float z_[4]   = {0,0,0,0};
    float zd_[4]  = {0,0,0,0};
};

} // namespace roarbass
