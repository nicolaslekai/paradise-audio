//
//  Voice.hpp
//  RoarBass
//
//  One voice = 2 detuned bandlimited oscillators (saws by default) + sine sub
//  + FM "growl" + filtered noise -> ladder filter -> amp env. Filter env modulates cutoff.
//

#pragma once
#include "DSPCommon.hpp"
#include "Oscillator.hpp"
#include "FMOperator.hpp"
#include "NoiseSource.hpp"
#include "LadderFilter.hpp"
#include "Envelope.hpp"

namespace roarbass {

struct VoiceParams {
    int   osc1Octave   = 0;
    int   osc2Octave   = 0;
    float osc2Cents    = 7.0f;
    float oscMix       = 0.5f;
    float subLevel     = 0.7f;
    float fmAmount     = 0.0f;
    float fmRatio      = 1.0f;
    float fmFeedback   = 0.0f;
    float noiseLevel   = 0.0f;
    float noiseColour  = 0.5f;
    float cutoffHz     = 800.0f;
    float resonance    = 0.2f;
    float drive        = 0.1f;
    float filterEnvAmt = 0.5f;
    float ampA = 0.005f, ampD = 0.2f, ampS = 0.85f, ampR = 0.3f;
    float fltA = 0.005f, fltD = 0.4f, fltS = 0.4f, fltR = 0.3f;
    float glide = 0.0f;
};

class Voice {
public:
    void reset(float sr) {
        sr_ = sr;
        osc1_.reset(sr);   osc1_.setShape(OscShape::Saw);
        osc2_.reset(sr);   osc2_.setShape(OscShape::Saw);
        sub_.reset(sr);    sub_.setShape(OscShape::Sine);
        fm_.reset(sr);
        noise_.reset(sr);
        filter_.reset(sr);
        ampEnv_.reset(sr);
        fltEnv_.reset(sr);
        glideTargetHz_ = 0.0f;
        currentHz_     = 0.0f;
        glideCoef_     = 1.0f;
        velocity_      = 0.0f;
        midiNote_      = -1;
        active_        = false;
    }

    void noteOn(int midiNote, float velocity01, const VoiceParams& p, bool legato) {
        midiNote_ = midiNote;
        velocity_ = velocity01;
        float baseHz = midiToHz((float)midiNote);
        glideTargetHz_ = baseHz;
        if (!legato || currentHz_ <= 0.0f) {
            currentHz_ = baseHz;
        }
        // glide coef: 0 means instant
        float t = std::max(0.0001f, p.glide);
        glideCoef_ = 1.0f - std::exp(-1.0f / (t * sr_));

        applyParams(p);
        if (!legato) {
            ampEnv_.noteOn();
            fltEnv_.noteOn();
            osc1_.resetPhase();
            osc2_.resetPhase();
            sub_.resetPhase();
            fm_.resetPhase();
        } else {
            // legato: keep envs going
        }
        active_ = true;
    }

    void noteOff() {
        ampEnv_.noteOff();
        fltEnv_.noteOff();
    }

    bool isActive() const { return active_; }
    int  note() const     { return midiNote_; }

    inline float tick(const VoiceParams& p) {
        // glide
        currentHz_ += (glideTargetHz_ - currentHz_) * glideCoef_;

        // pitches
        float o1Hz = currentHz_ * std::pow(2.0f, (float)p.osc1Octave);
        float o2Hz = currentHz_ * std::pow(2.0f, (float)p.osc2Octave) * std::pow(2.0f, p.osc2Cents / 1200.0f);
        float subHz = currentHz_ * 0.5f;

        osc1_.setFrequency(o1Hz);
        osc2_.setFrequency(o2Hz);
        sub_.setFrequency(subHz);
        fm_.setFrequency(currentHz_);
        fm_.setRatio(p.fmRatio);
        fm_.setIndex(p.fmAmount * 6.0f * (0.5f + 0.5f * velocity_));
        fm_.setFeedback(p.fmFeedback);
        noise_.setColour(p.noiseColour);

        // sources
        float s1 = osc1_.tick();
        float s2 = osc2_.tick();
        float mixOsc = lerp(s1, s2, p.oscMix);
        float subv   = sub_.tick() * p.subLevel * 1.2f;
        float fmv    = fm_.tick()  * p.fmAmount * 1.5f;
        float nz     = noise_.tick() * p.noiseLevel * 0.6f;

        float mix = mixOsc * (1.0f - 0.4f * p.fmAmount) + subv + fmv + nz;

        // envelopes
        float ampE = ampEnv_.tick();
        float fltE = fltEnv_.tick();

        // filter cutoff with envelope (semitones: +/- 7 octaves max at full amt)
        float octShift = p.filterEnvAmt * fltE * 7.0f;
        float cutoff = p.cutoffHz * std::pow(2.0f, octShift);
        filter_.setCutoff(cutoff);
        filter_.setResonance(p.resonance);
        filter_.setDrive(p.drive);

        float filtered = filter_.process(mix);

        // amp
        float out = filtered * ampE * (0.4f + 0.6f * velocity_);

        if (ampEnv_.isIdle()) active_ = false;
        return out;
    }

    void applyParams(const VoiceParams& p) {
        osc1_.setShape(OscShape::Saw);
        osc2_.setShape(OscShape::Saw);
        sub_.setShape(OscShape::Sine);

        ampEnv_.setAttack(p.ampA);
        ampEnv_.setDecay(p.ampD);
        ampEnv_.setSustain(p.ampS);
        ampEnv_.setRelease(p.ampR);

        fltEnv_.setAttack(p.fltA);
        fltEnv_.setDecay(p.fltD);
        fltEnv_.setSustain(p.fltS);
        fltEnv_.setRelease(p.fltR);
    }

private:
    float sr_ = kDefaultSR;
    Oscillator   osc1_, osc2_, sub_;
    FMOperator   fm_;
    NoiseSource  noise_;
    LadderFilter filter_;
    ADSR         ampEnv_, fltEnv_;

    float currentHz_     = 0.0f;
    float glideTargetHz_ = 0.0f;
    float glideCoef_     = 1.0f;
    float velocity_      = 0.0f;
    int   midiNote_      = -1;
    bool  active_        = false;
};

} // namespace roarbass
