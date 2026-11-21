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
#include "HalfbandOS.hpp"
#include <array>

namespace roarbass {

class Engine {
public:
    // Up to 50 kHz the whole voice path (oscillators, FM, ladder + drive, output
    // shaper) runs at TWICE the host rate and comes back down through a
    // linear-phase halfband filter. At the host rate the FM sidebands and the
    // tanh stages folded back as inharmonic aliases on higher notes (E7: −20 dB
    // below the note). The decimator's 15-sample delay is reported as latency.
    // At 88.2 kHz and up the engine already has that headroom and runs 1:1.
    static bool oversampled(float hostRate) { return hostRate < 80000.0f; }
    static constexpr int kLatencySamples = 15;      // when oversampled
    int latencySamples() const { return os2_ ? kLatencySamples : 0; }

    void prepare(float sampleRate) {
        hostSr_ = sampleRate;
        os2_ = oversampled(sampleRate);
        sr_ = os2_ ? sampleRate * 2.0f : sampleRate;   // internal rate: everything below runs at it
        down_.init(pos::kHB63, 32);
        for (auto& v : voices_) { v.reset(sr_); v.setNoiseHold(os2_ ? 2 : 1); }
        // The patch survives prepare(). It used to be wiped here (params_ =
        // defaults, gain 1, drive 0) and the AU's "re-apply" then read those
        // wiped values straight back through the parameter tree's value
        // provider — so every re-allocate (buffer-size / sample-rate change,
        // bounce) silently reset RoarBass to hidden defaults.
        masterGainSmooth_.reset(sr_, 5.0f, masterGain_);
        driveOutSmooth_.reset(sr_, 5.0f, driveOut_);
        kSmooth_ = 1.0f - std::exp(-1.0f / (0.015f * sr_));   // 15 ms control smoothing
        snap_ = true;
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
            case kParam_MasterGain:   masterGain_ = std::max(0.0f, value); masterGainSmooth_.setTarget(masterGain_); break;
            case kParam_DriveOut:     driveOut_ = clamp01(value); driveOutSmooth_.setTarget(driveOut_); break;
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
            case kParam_MasterGain:   return masterGain_;     // the set value, not the ramp
            case kParam_DriveOut:     return driveOut_;
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
                // All 8 busy: take the same note if it is still sounding, else the
                // QUIETEST voice (usually one deep in its release). It used to be
                // voice 0 every time — often a held note at full level, cut with a
                // click.
                target = &voices_[0];
                for (auto& vc : voices_) if (vc.ampLevel() < target->ampLevel()) target = &vc;
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
        // Param updates once per block (this ran per SAMPLE — six ADSR
        // recalcs with exp() per voice-sample, ~5 M transcendentals a second).
        for (auto& vc : voices_) if (vc.isActive()) vc.applyParams(params_);
        // The continuous sound controls glide (15 ms) instead of stepping once per
        // host buffer: a CUTOFF sweep used to zipper at −33 dBFS. `live_` is the
        // parameter set the voices actually hear.
        if (snap_) { live_ = params_; snap_ = false; }
        {   // everything that is not smoothed follows immediately
            const float c = live_.cutoffHz, r = live_.resonance, d = live_.drive, e = live_.filterEnvAmt,
                        m = live_.oscMix, sb = live_.subLevel, fa = live_.fmAmount, nl = live_.noiseLevel;
            live_ = params_;
            live_.cutoffHz = c; live_.resonance = r; live_.drive = d; live_.filterEnvAmt = e;
            live_.oscMix = m; live_.subLevel = sb; live_.fmAmount = fa; live_.noiseLevel = nl;
        }
        for (int i = 0; i < frames; ++i) {
            float y;
            if (os2_) { const float a = tickInternal(); const float b = tickInternal(); y = down_.down(a, b); }
            else      { y = tickInternal(); }
            outL[i] = y;
            outR[i] = y;
        }
    }
private:
    /// One sample at the internal rate.
    inline float tickInternal() {
            // cutoff glides in the log domain (equal musical steps), the rest linearly
            live_.cutoffHz     *= std::exp(kSmooth_ * std::log(params_.cutoffHz / live_.cutoffHz));
            live_.resonance    += kSmooth_ * (params_.resonance    - live_.resonance);
            live_.drive        += kSmooth_ * (params_.drive        - live_.drive);
            live_.filterEnvAmt += kSmooth_ * (params_.filterEnvAmt - live_.filterEnvAmt);
            live_.oscMix       += kSmooth_ * (params_.oscMix       - live_.oscMix);
            live_.subLevel     += kSmooth_ * (params_.subLevel     - live_.subLevel);
            live_.fmAmount     += kSmooth_ * (params_.fmAmount     - live_.fmAmount);
            live_.noiseLevel   += kSmooth_ * (params_.noiseLevel   - live_.noiseLevel);
            float mix = 0.0f;
            for (auto& vc : voices_) {
                if (!vc.isActive()) continue;
                mix += vc.tick(live_);
            }
            // output drive (final shaping) + master gain
            float drive = driveOutSmooth_.next();
            float gain  = masterGainSmooth_.next();
            float shaped = fastTanh(mix * (1.0f + drive * 4.0f)) * (1.0f / (1.0f + drive * 1.5f));
            return shaped * gain;
    }
public:

    int activeVoiceCount() const {
        int n = 0;
        for (auto& v : voices_) if (v.isActive()) ++n;
        return n;
    }

private:
    float hostSr_ = kDefaultSR;
    float sr_ = kDefaultSR;              // internal rate (2x the host rate when oversampled)
    bool  os2_ = false;
    pos::Halfband2x down_;
    std::array<Voice, kMaxVoices> voices_;
    VoiceParams params_;
    VoiceParams live_;              // params_ with the continuous controls smoothed
    float kSmooth_ = 0.0014f;
    bool  snap_ = true;
    OnePoleSmoother masterGainSmooth_;
    OnePoleSmoother driveOutSmooth_;
    float masterGain_ = 1.0f, driveOut_ = 0.0f;   // targets (what the host set)
    bool polyMode_ = true;
};

} // namespace roarbass
