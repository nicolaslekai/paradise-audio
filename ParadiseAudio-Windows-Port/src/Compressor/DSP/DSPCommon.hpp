//
//  DSPCommon.hpp
//

#pragma once

#include <algorithm>
#include <cmath>

namespace cmp {

constexpr float kPi = 3.14159265358979323846f;

inline float clamp(float v, float lo, float hi) {
    return std::max(lo, std::min(hi, v));
}

inline float dbToLin(float db) { return std::pow(10.0f, db * 0.05f); }
inline float linToDb(float lin) {
    return lin > 1e-9f ? 20.0f * std::log10(lin) : -180.0f;
}

// Convert a time constant in milliseconds to a one-pole smoothing coefficient
// such that the filter reaches ~63% of the target in `ms` ms.
inline float timeToCoeff(float ms, float sampleRate) {
    if (ms <= 0.0001f) return 1.0f;
    return 1.0f - std::exp(-1.0f / (0.001f * ms * sampleRate));
}

} // namespace cmp
