#pragma once
#include <algorithm>
#include <cmath>
#include <vector>
namespace dly {
constexpr float kPi = 3.14159265358979323846f;
inline float clamp(float v, float lo, float hi) { return std::max(lo, std::min(hi, v)); }
}
