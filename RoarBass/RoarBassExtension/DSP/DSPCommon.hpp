//
//  DSPCommon.hpp
//  RoarBass
//
//  Shared constants, helpers, parameter IDs.
//

#pragma once

#include <cmath>
#include <algorithm>
#include <cstdint>

namespace roarbass {

constexpr float kPi          = 3.14159265358979323846f;
constexpr float kTwoPi       = 6.28318530717958647692f;
constexpr int   kMaxVoices   = 8;
constexpr float kDefaultSR   = 44100.0f;

// Parameter addresses (kept stable — used by AU param tree, presets, and host automation)
enum ParamAddress : uint64_t {
    kParam_Osc1Octave    = 0,   // -2 .. +2 (int)
    kParam_Osc2Octave    = 1,   // -2 .. +2 (int)
    kParam_Osc2Detune    = 2,   // -50 .. +50 cents
    kParam_OscMix        = 3,   // 0 .. 1 (osc1 -> osc2)
    kParam_SubLevel      = 4,   // 0 .. 1 (parallel sine sub)
    kParam_FMAmount      = 5,   // 0 .. 1 (the "roar")
    kParam_FMRatio       = 6,   // 0.25 .. 8 (modulator ratio vs carrier)
    kParam_FMFeedback    = 7,   // 0 .. 1 (self-feedback on modulator)
    kParam_NoiseLevel    = 8,   // 0 .. 1
    kParam_NoiseColor    = 9,   // 0 white .. 1 brown
    kParam_FilterCutoff  = 10,  // 20 .. 18000 Hz (log)
    kParam_FilterReso    = 11,  // 0 .. 1
    kParam_FilterDrive   = 12,  // 0 .. 1 (tanh saturation pre-filter)
    kParam_FilterEnvAmt  = 13,  // -1 .. +1 (env to cutoff modulation)
    kParam_AmpAttack     = 14,  // 0.001 .. 4 s
    kParam_AmpDecay      = 15,
    kParam_AmpSustain    = 16,
    kParam_AmpRelease    = 17,
    kParam_FilterAttack  = 18,
    kParam_FilterDecay   = 19,
    kParam_FilterSustain = 20,
    kParam_FilterRelease = 21,
    kParam_Glide         = 22,  // 0 .. 1 s — only used in mono mode
    kParam_VoiceMode     = 23,  // 0 = poly, 1 = mono-legato
    kParam_MasterGain    = 24,  // 0 .. 2 (linear)
    kParam_DriveOut      = 25,  // 0 .. 1 (final stage tanh)
    kParamCount
};

// fast helpers
inline float clamp01(float x)               { return std::max(0.0f, std::min(1.0f, x)); }
inline float clampf(float x, float lo, float hi) { return std::max(lo, std::min(hi, x)); }
inline float lerp(float a, float b, float t){ return a + (b - a) * t; }
inline float dbToLin(float db)              { return std::pow(10.0f, db * 0.05f); }

// One-pole smoothing for parameter ramps (avoids zipper noise).
class OnePoleSmoother {
public:
    void reset(float sr, float timeMs, float initial = 0.0f) {
        float tc = timeMs * 0.001f * sr;
        a_ = (tc > 0.0f) ? std::exp(-1.0f / tc) : 0.0f;
        y_ = initial;
        target_ = initial;
    }
    void setTarget(float t) { target_ = t; }
    void setImmediate(float v) { y_ = target_ = v; }
    float next() { y_ = target_ + a_ * (y_ - target_); return y_; }
    float value() const { return y_; }
private:
    float a_ = 0.0f, y_ = 0.0f, target_ = 0.0f;
};

// 12-TET midi -> Hz
inline float midiToHz(float note) {
    return 440.0f * std::pow(2.0f, (note - 69.0f) / 12.0f);
}

// tanh approximation — cheap saturation
inline float fastTanh(float x) {
    // The Padé form runs off to x/9 for |x| > 3, so the "soft clipper" could
    // put out ±2 or more with 8 voices + SUB + FM. Pin the input where the
    // approximation still is a tanh (≈ ±1 at ±3).
    x = (x > 3.0f) ? 3.0f : (x < -3.0f ? -3.0f : x);
    float x2 = x * x;
    float n = x * (27.0f + x2);
    float d = 27.0f + 9.0f * x2;
    return n / d;
}

} // namespace roarbass
