#pragma once
#include <algorithm>
#include <cmath>
#include <vector>
#include <atomic>
namespace hdy {
constexpr float kPi = 3.14159265358979323846f;
inline float clamp(float v, float lo, float hi) { return std::max(lo, std::min(hi, v)); }
inline float dbToLin(float db) { return std::pow(10.0f, db * 0.05f); }
inline float linToDb(float v)  { return v > 1e-9f ? 20.0f * std::log10(v) : -180.0f; }
inline float timeToCoeff(float ms, float sr) {
    return ms <= 0.0001f ? 1.0f : 1.0f - std::exp(-1.0f / (0.001f * ms * sr));
}
}
