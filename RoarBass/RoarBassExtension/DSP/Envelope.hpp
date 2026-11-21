//
//  Envelope.hpp
//  RoarBass
//
//  Exponential-ish ADSR. Stages computed as one-pole convergence toward a target.
//

#pragma once
#include "DSPCommon.hpp"

namespace roarbass {

class ADSR {
public:
    enum class Stage : int { Idle = 0, Attack, Decay, Sustain, Release };

    void reset(float sr) { sr_ = sr; level_ = 0.0f; stage_ = Stage::Idle; }

    void setAttack (float s) { a_s_ = std::max(0.0005f, s); recalc(); }
    void setDecay  (float s) { d_s_ = std::max(0.0005f, s); recalc(); }
    void setSustain(float v) { sus_ = clamp01(v); }
    void setRelease(float s) { r_s_ = std::max(0.0005f, s); recalc(); }

    void noteOn() {
        stage_ = Stage::Attack;
        // start from current level so retriggers don't click
    }
    void noteOff() {
        if (stage_ != Stage::Idle) stage_ = Stage::Release;
    }
    bool isIdle() const { return stage_ == Stage::Idle; }

    inline float tick() {
        switch (stage_) {
            case Stage::Idle:
                return 0.0f;
            case Stage::Attack:
                // target slightly above 1 for snappier rise
                level_ += (1.2f - level_) * aCoef_;
                if (level_ >= 1.0f) { level_ = 1.0f; stage_ = Stage::Decay; }
                break;
            case Stage::Decay:
                level_ += (sus_ - level_) * dCoef_;
                if (std::fabs(level_ - sus_) < 1e-4f) { level_ = sus_; stage_ = Stage::Sustain; }
                break;
            case Stage::Sustain:
                level_ = sus_;
                break;
            case Stage::Release:
                level_ += (0.0f - level_) * rCoef_;
                if (level_ < 1e-4f) { level_ = 0.0f; stage_ = Stage::Idle; }
                break;
        }
        return level_;
    }

    float value() const { return level_; }
    Stage stage() const { return stage_; }

private:
    void recalc() {
        // coefficient that reaches ~63% of target in stage time
        aCoef_ = 1.0f - std::exp(-1.0f / (a_s_ * sr_));
        dCoef_ = 1.0f - std::exp(-1.0f / (d_s_ * sr_));
        rCoef_ = 1.0f - std::exp(-1.0f / (r_s_ * sr_));
    }

    float sr_ = kDefaultSR;
    float a_s_ = 0.005f, d_s_ = 0.2f, sus_ = 0.8f, r_s_ = 0.3f;
    float aCoef_ = 0, dCoef_ = 0, rCoef_ = 0;
    float level_ = 0.0f;
    Stage stage_ = Stage::Idle;
};

} // namespace roarbass
