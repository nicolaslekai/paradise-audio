//
//  EnvelopeFollower.hpp
//
//  Peak envelope follower with independent attack / release time constants.
//  Operates in the linear amplitude domain.
//

#pragma once

#include "DSPCommon.hpp"

namespace cmp {

class EnvelopeFollower {
public:
    void prepare(float sampleRateHz) {
        sr_ = sampleRateHz;
        setAttackMs(5.0f);
        setReleaseMs(80.0f);
        env_ = 0.0f;
    }

    void setAttackMs(float ms)  { attackCoeff_  = timeToCoeff(ms, sr_); }
    void setReleaseMs(float ms) { releaseCoeff_ = timeToCoeff(ms, sr_); }

    // Feed one input sample (absolute value of the audio sample). Returns
    // the current envelope (peak-following).
    inline float process(float x) {
        const float a = std::fabs(x);
        const float c = (a > env_) ? attackCoeff_ : releaseCoeff_;
        env_ += c * (a - env_);
        return env_;
    }

    void reset() { env_ = 0.0f; }

private:
    float sr_ = 48000.0f;
    float attackCoeff_  = 0.05f;
    float releaseCoeff_ = 0.005f;
    float env_ = 0.0f;
};

} // namespace cmp
