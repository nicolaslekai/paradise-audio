//
//  FMOperator.hpp
//  RoarBass
//
//  Two-operator FM/PM "growl" generator. Carrier is a sine. Modulator is a sine
//  with self-feedback (creates saw-like harmonic content as feedback rises).
//  Modulator frequency = carrier frequency * ratio.
//

#pragma once
#include "DSPCommon.hpp"

namespace roarbass {

class FMOperator {
public:
    void reset(float sr) {
        sr_ = sr;
        carrierPhase_ = 0.0f;
        modPhase_     = 0.0f;
        modZ1_        = 0.0f;
        setFrequency(110.0f);
    }
    void setFrequency(float hz) {
        carrierHz_ = hz;
        carrierInc_ = hz / sr_;
        modInc_     = (hz * ratio_) / sr_;
    }
    void setRatio(float r)        { ratio_ = std::max(0.0625f, r); modInc_ = (carrierHz_ * ratio_) / sr_; }
    void setIndex(float index)    { index_ = std::max(0.0f, index); }
    void setFeedback(float fb)    { feedback_ = clamp01(fb); }

    inline float tick() {
        // modulator with self-feedback (PM via previous output averaged with current)
        float modPhaseMod = feedback_ * modZ1_;
        float mt = modPhase_ + modPhaseMod;
        mt -= std::floor(mt);
        float modOut = std::sin(mt * kTwoPi);

        // simple 1-pole average to tame zipper at high feedback
        modZ1_ = 0.5f * (modZ1_ + modOut);

        // carrier phase-modulated by modulator
        float ct = carrierPhase_ + index_ * modOut;
        ct -= std::floor(ct);
        float carOut = std::sin(ct * kTwoPi);

        carrierPhase_ += carrierInc_;
        if (carrierPhase_ >= 1.0f) carrierPhase_ -= 1.0f;
        modPhase_ += modInc_;
        if (modPhase_ >= 1.0f) modPhase_ -= 1.0f;

        return carOut;
    }

    void resetPhase() { carrierPhase_ = modPhase_ = 0.0f; modZ1_ = 0.0f; }

private:
    float sr_ = kDefaultSR;
    float carrierHz_  = 110.0f;
    float carrierInc_ = 0.0f, modInc_ = 0.0f;
    float carrierPhase_ = 0.0f, modPhase_ = 0.0f;
    float ratio_ = 1.0f;
    float index_ = 0.0f;
    float feedback_ = 0.0f;
    float modZ1_ = 0.0f;
};

} // namespace roarbass
