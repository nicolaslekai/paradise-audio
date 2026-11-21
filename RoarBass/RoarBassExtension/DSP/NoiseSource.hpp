//
//  NoiseSource.hpp
//  RoarBass
//
//  White / brown noise with a colour control (lerps from white to brown).
//

#pragma once
#include "DSPCommon.hpp"
#include <random>

namespace roarbass {

class NoiseSource {
public:
    void reset(float sr) {
        sr_ = sr;
        rng_.seed(0xC0FFEEu ^ (uint32_t)(uintptr_t)this);
        brown_ = 0.0f;
    }

    void setColour(float c) { colour_ = clamp01(c); }

    inline float tick() {
        // white in [-1, 1)
        // minstd_rand yields [1, 2^31-2] — always positive, so the old
        // int32 cast never went negative and NOISE was a DC offset of ~+4
        // (the brown integrator pinned at +1 × 6). Map to (-1, 1) properly.
        uint32_t r = rng_();
        float w = (float)r * (2.0f / 2147483646.0f) - 1.0f;

        // brown via leaky integrator; clamp to avoid DC runaway
        brown_ = 0.998f * brown_ + 0.02f * w;
        if (brown_ >  1.0f) brown_ =  1.0f;
        if (brown_ < -1.0f) brown_ = -1.0f;

        // crossfade white -> brown (boost brown to match perceived loudness)
        float out = lerp(w, brown_ * 6.0f, colour_);
        return out;
    }

private:
    float sr_ = kDefaultSR;
    float colour_ = 0.5f;
    float brown_  = 0.0f;
    std::minstd_rand rng_;
};

} // namespace roarbass
