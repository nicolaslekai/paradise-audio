#pragma once
#include <algorithm>
#include <cmath>

namespace eq {

constexpr float kPi = 3.14159265358979323846f;

inline float clamp(float v, float lo, float hi) { return std::max(lo, std::min(hi, v)); }
inline float dbToLin(float db)  { return std::pow(10.0f, db * 0.05f); }
inline float linToDb(float lin) { return lin > 1e-9f ? 20.0f * std::log10(lin) : -180.0f; }

} // namespace eq
