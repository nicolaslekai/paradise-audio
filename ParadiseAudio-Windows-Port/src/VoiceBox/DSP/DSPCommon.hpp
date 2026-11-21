//
//  DSPCommon.hpp — small shared DSP helpers for VoiceBox.
//
#pragma once
#include <cmath>
#include <algorithm>
#include <cstdint>

namespace vbx {

static constexpr float kPi = 3.14159265358979323846f;

inline float clampf(float x, float lo, float hi) { return std::max(lo, std::min(hi, x)); }

// Cheap white noise in [-1, 1).
inline float fastNoise(uint32_t& state) {
    state = state * 1664525u + 1013904223u;
    return ((state >> 8) & 0x00FFFFFF) / 8388608.0f - 1.0f;
}

// One-pole DC blocker (high-pass). R≈0.9996 ≈ 7 Hz @ 48 kHz — see warmth research.
struct DCBlocker {
    float x1 = 0, y1 = 0, R = 0.9996f;
    inline float process(float x) { float y = x - x1 + R * y1; x1 = x; y1 = y; return y; }
    void reset() { x1 = y1 = 0; }
};

// One-pole low-pass smoother (for soft HF damping / parameter glides).
struct OnePoleLP {
    float z = 0, a = 0.2f;
    void setCutoff(float fc, float sr) { a = 1.0f - std::exp(-2.0f * kPi * fc / sr); }
    inline float process(float x) { z += a * (x - z); return z; }
    void reset() { z = 0; }
};

} // namespace vbx
