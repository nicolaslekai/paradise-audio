//
//  RoarBassDSP.hpp
//  RoarBass
//
//  Top-level engine: voice manager + global gain/drive. Exposes a render entry
//  point the AU's render block calls (one buffer at a time).
//

#pragma once
#include "DSPCommon.hpp"
#include "Voice.hpp"
#include <array>

namespace roarbass {

class Engine {
public:
    void prepare(float sampleRate) {
        sr_ = sampleRate;
        for (auto& v : voices_) v.reset(sr_);
        masterGainSmooth_.reset(sr_, 5.0f, 1.0f);
        driveOutSmooth_.reset(sr_, 5.0f, 0.0f);
        params_ = VoiceParams{};
        polyMode_ = true;
    }

    // Called by the AU when host changes a parameter.
    void setParameter(uint64_t address, float value) {
        switch (address) {
            case kParam_Osc1Octave:   params_.osc1Octave  = (int)std::round(value); break;
            case kParam_Osc2Octave:   params_.osc2Octave  = (int)std::round(value); break;
            case kParam_Osc2Detune:   params_.osc2Cents   = value; break;
            case kParam_OscMix:       params_.oscMix      = clamp01(value); break;
            case kParam_SubLevel:     params_.subLevel    = clamp01(value); break;
            case kParam_FMAmount:     params_.fmAmount    = clamp01(value); break;
            case kParam_FMRatio:      params_.fmRatio     = clampf(value, 0.25f, 8.0f); break;
            case kParam_FMFeedback:   params_.fmFeedback  = clamp01(value); break;
            case kParam_NoiseLevel:   params_.noiseLevel  = clamp01(value); break;
            case kParam_NoiseColor:   params_.noiseColour = clamp01(value); break;
            case kParam_FilterCutoff: params_.cutoffHz    = clampf(value, 20.0f, 18000.0f); break;
            case kParam_FilterReso:   params_.resonance   = clamp01(value); break;
            case kParam_FilterDrive:  params_.drive       = clamp01(value); break;
            case kParam_FilterEnvAmt: params_.filterEnvAmt= clampf(value, -1.0f, 1.0f); break;
            case kParam_AmpAttack:    params_.ampA = value; break;
            case kParam_AmpDecay:     params_.ampD = value; break;
            case kParam_AmpSustain:   params_.ampS = value; break;
            case kParam_AmpRelease:   params_.ampR = value; break;
            case kParam_FilterAttack: params_.fltA = value; break;
            case kParam_FilterDecay:  params_.fltD = value; break;
            case kParam_FilterSustain:params_.fltS = value; break;
            case kParam_FilterRelease:params_.fltR = value; break;
            case kParam_Glide:        params_.glide = std::max(0.0f, value); break;
            case kParam_VoiceMode:    polyMode_ = (value < 0.5f); break;
            case kParam_MasterGain:   masterGainSmooth_.setTarget(std::max(0.0f, value)); break;
            case kParam_DriveOut:     driveOutSmooth_.setTarget(clamp01(value)); break;
            default: break;
        }
    }

    float getParameter(uint64_t address) const {
        switch (address) {
            case kParam_Osc1Octave:   return (float)params_.osc1Octave;
            case kParam_Osc2Octave:   return (float)params_.osc2Octave;
            case kParam_Osc2Detune:   return params_.osc2Cents;
            case kParam_OscMix:       return params_.oscMix;
            case kParam_SubLevel:     return params_.subLevel;
            case kParam_FMAmount:     return params_.fmAmount;
            case kParam_FMRatio:      return params_.fmRatio;
            case kParam_FMFeedback:   return params_.fmFeedback;
            case kParam_NoiseLevel:   return params_.noiseLevel;
            case kParam_NoiseColor:   return params_.noiseColour;
            case kParam_FilterCutoff: return params_.cutoffHz;
            case kParam_FilterReso:   return params_.resonance;
            case kParam_FilterDrive:  return params_.drive;
            case kParam_FilterEnvAmt: return params_.filterEnvAmt;
            case kParam_AmpAttack:    return params_.ampA;
            case kParam_AmpDecay:     return params_.ampD;
            case kParam_AmpSustain:   return params_.ampS;
            case kParam_AmpRelease:   return params_.ampR;
            case kParam_FilterAttack: return params_.fltA;
            case kParam_FilterDecay:  return params_.fltD;
            case kParam_FilterSustain:return params_.fltS;
            case kParam_FilterRelease:return params_.fltR;
            case kParam_Glide:        return params_.glide;
            case kParam_VoiceMode:    return polyMode_ ? 0.0f : 1.0f;
            case kParam_MasterGain:   return masterGainSmooth_.value();
            case kParam_DriveOut:     return driveOutSmooth_.value();
            default: return 0.0f;
        }
    }

    void noteOn(int midi, int velocity) {
        float v = clamp01(velocity / 127.0f);
        if (polyMode_) {
            // first try retrigger same note, else steal idle, else steal oldest
            Voice* target = nullptr;
            for (auto& vc : voices_) if (!vc.isActive()) { target = &vc; break; }
            if (!target) {
                target = &voices_[0];
                for (auto& vc : voices_) if (vc.note() == midi) { target = &vc; break; }
            }
            target->noteOn(midi, v, params_, /*legato=*/false);
        } else {
            // mono legato — always voice 0
            bool legato = false;
            for (auto& vc : voices_) if (vc.isActive()) { legato = true; break; }
            voices_[0].noteOn(midi, v, params_, legato);
        }
    }

    void noteOff(int midi) {
        for (auto& vc : voices_) {
            if (vc.isActive() && vc.note() == midi) vc.noteOff();
        }
    }

    void allNotesOff() { for (auto& vc : voices_) vc.noteOff(); }

    // Render `frames` samples into stereo out. Mono engine -> dupes to both channels.
    void render(int frames, float* outL, float* outR) {
        for (int i = 0; i < frames; ++i) {
            // apply param updates to active voices each block (cheap)
            float mix = 0.0f;
            for (auto& vc : voices_) {
                if (!vc.isActive()) continue;
                vc.applyParams(params_);
                mix += vc.tick(params_);
            }
            // output drive (final shaping) + master gain
            float drive = driveOutSmooth_.next();
            float gain  = masterGainSmooth_.next();
            float shaped = fastTanh(mix * (1.0f + drive * 4.0f)) * (1.0f / (1.0f + drive * 1.5f));
            float y = shaped * gain;
            outL[i] = y;
            outR[i] = y;
        }
    }

    int activeVoiceCount() const {
        int n = 0;
        for (auto& v : voices_) if (v.isActive()) ++n;
        return n;
    }

private:
    float sr_ = kDefaultSR;
    std::array<Voice, kMaxVoices> voices_;
    VoiceParams params_;
    OnePoleSmoother masterGainSmooth_;
    OnePoleSmoother driveOutSmooth_;
    bool polyMode_ = true;
};

} // namespace roarbass
