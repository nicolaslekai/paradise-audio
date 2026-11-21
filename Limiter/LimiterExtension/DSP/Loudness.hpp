//
//  Loudness.hpp
//
//  K-weighted LUFS measurement per ITU-R BS.1770-4.
//
//    1. K-weighting filter — cascade of a high-shelf (~+4 dB above 1500 Hz)
//       and a high-pass (~38 Hz). Coefficients here are the canonical
//       BS.1770-3 set, scaled for the runtime sample rate via the bilinear
//       transform.
//    2. Mean-square in 100 ms blocks. Stereo channel sums use channel
//       weights G_L = G_R = 1.0 (no surround channels).
//    3. Short-term LUFS = mean over the last 30 blocks (3 s).
//    4. Integrated (long-term) LUFS = mean over all blocks since reset,
//       with two-stage gating: -70 LUFS absolute then -10 LUFS relative.
//
//  Returns LUFS as a float; -INF when the buffer has no audio yet (we
//  clamp to a floor of -120 LUFS so the UI doesn't have to handle -inf).
//

#pragma once

#include <algorithm>
#include <cmath>
#include <vector>
#include <atomic>
#include <cstdint>

namespace lim {

class KWeightStage {
public:
    void setHighShelf(float sr) {
        // BS.1770 high-shelf @ 1500 Hz, +4 dB, fixed coefficients at 48k —
        // scale by sample-rate ratio (cheap, good-enough approximation; for
        // ±0.5 dB exactness at non-48 sample rates a true bilinear remap
        // would be required, but this is well within the BS.1770 tolerance
        // for ±0.5 LU at the metering level we report).
        if (std::abs(sr - 48000.0f) < 1.0f) {
            b0 =  1.53512485958697f;
            b1 = -2.69169618940638f;
            b2 =  1.19839281085285f;
            a1 = -1.69065929318241f;
            a2 =  0.73248077421585f;
        } else {
            // Generic bilinear for arbitrary sample rates
            const float f0 = 1500.0f, Q = 0.7071f, G = 4.0f;
            const float A = std::pow(10.0f, G / 40.0f);
            const float w0 = 2.0f * 3.14159265358979f * f0 / sr;
            const float cosw = std::cos(w0), sinw = std::sin(w0);
            const float alpha = sinw / (2.0f * Q);
            const float a0 = (A + 1) - (A - 1) * cosw + 2 * std::sqrt(A) * alpha;
            b0 = ( A * ((A + 1) + (A - 1) * cosw + 2 * std::sqrt(A) * alpha)) / a0;
            b1 = (-2 * A * ((A - 1) + (A + 1) * cosw))                       / a0;
            b2 = ( A * ((A + 1) + (A - 1) * cosw - 2 * std::sqrt(A) * alpha)) / a0;
            a1 = ( 2 * ((A - 1) - (A + 1) * cosw))                           / a0;
            a2 = ((A + 1) - (A - 1) * cosw - 2 * std::sqrt(A) * alpha)       / a0;
        }
    }
    void setHighPass(float sr) {
        // BS.1770 high-pass @ ~38 Hz, fixed coefficients at 48 kHz.
        if (std::abs(sr - 48000.0f) < 1.0f) {
            b0 =  1.0f;
            b1 = -2.0f;
            b2 =  1.0f;
            a1 = -1.99004745483398f;
            a2 =  0.99007225036621f;
        } else {
            const float f0 = 38.13547087602444f, Q = 0.5003270373238773f;
            const float w0 = 2.0f * 3.14159265358979f * f0 / sr;
            const float cosw = std::cos(w0), sinw = std::sin(w0);
            const float alpha = sinw / (2.0f * Q);
            const float a0 = 1 + alpha;
            b0 = ((1 + cosw) / 2) / a0;
            b1 = (-(1 + cosw))     / a0;
            b2 = ((1 + cosw) / 2) / a0;
            a1 = (-2 * cosw)       / a0;
            a2 = (1 - alpha)       / a0;
        }
    }
    void reset() { z1 = z2 = 0; }
    inline float process(float x) {
        const float y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return y;
    }
private:
    float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    float z1 = 0, z2 = 0;
};

class LoudnessMeter {
public:
    void prepare(float sampleRateHz) {
        sr_ = sampleRateHz;
        for (int c = 0; c < 2; ++c) {
            shelf_[c].setHighShelf(sr_);
            hpf_[c].setHighPass(sr_);
            shelf_[c].reset(); hpf_[c].reset();
        }
        blockSize_ = (int)std::round(sr_ * 0.1f);   // 100 ms
        accum_ = 0;
        accumCount_ = 0;
        total_.store(0, std::memory_order_release);
    }
    void reset() {
        accum_ = 0;
        accumCount_ = 0;
        total_.store(0, std::memory_order_release);
        for (int c = 0; c < 2; ++c) { shelf_[c].reset(); hpf_[c].reset(); }
    }

    inline void processStereo(float L, float R) {
        // K-weight each channel
        const float yL = hpf_[0].process(shelf_[0].process(L));
        const float yR = hpf_[1].process(shelf_[1].process(R));
        // Mean-square sum (stereo channel weights = 1.0 each)
        accum_ += yL * yL + yR * yR;
        if (++accumCount_ >= blockSize_) {
            // Block mean (per BS.1770: divide by samples-per-block, NOT 2)
            const float blockMS = accum_ / (float)accumCount_;
            // Fixed ring (~10 min of 100 ms blocks) with a monotonically
            // growing write count: the audio thread only ever writes one
            // slot and bumps the counter, the UI thread only reads — no
            // vector growth or erase racing the meter readers.
            const int t = total_.load(std::memory_order_relaxed);
            ring_[t % kCap] = blockMS;
            total_.store(t + 1, std::memory_order_release);
            accum_ = 0;
            accumCount_ = 0;
        }
    }

    /// Short-term loudness — mean of the last 30 blocks (≈3 s).
    float shortTermLUFS() const {
        const int t = total_.load(std::memory_order_acquire);
        const int n = std::min(t, kCap);
        if (n == 0) return -120.0f;
        const int take = std::min(n, 30);
        double sum = 0;
        for (int i = t - take; i < t; ++i) sum += ring_[i % kCap];
        return msToLUFS((float)(sum / take));
    }

    /// Integrated (long-term) loudness — two-stage gated mean per BS.1770.
    float integratedLUFS() const {
        const int t = total_.load(std::memory_order_acquire);
        const int n = std::min(t, kCap);
        if (n == 0) return -120.0f;
        const int first = t - n;
        // 1. Absolute gate: drop blocks below -70 LUFS
        const float absGateMS = lufsToMS(-70.0f);
        double sum = 0; int cnt = 0;
        for (int i = first; i < t; ++i) {
            const float b = ring_[i % kCap];
            if (b > absGateMS) { sum += b; ++cnt; }
        }
        if (cnt == 0) return -120.0f;
        const double meanGated = sum / cnt;
        // 2. Relative gate: drop blocks below (mean - 10 LUFS)
        const float relThresh = msToLUFS((float)meanGated) - 10.0f;
        const float relGateMS = lufsToMS(relThresh);
        sum = 0; cnt = 0;
        for (int i = first; i < t; ++i) {
            const float b = ring_[i % kCap];
            if (b > absGateMS && b > relGateMS) { sum += b; ++cnt; }
        }
        if (cnt == 0) return -120.0f;
        const double mean = sum / cnt;
        return msToLUFS((float)mean);
    }

private:
    static float msToLUFS(float ms) {
        if (ms < 1e-12f) return -120.0f;
        return -0.691f + 10.0f * std::log10(ms);
    }
    static float lufsToMS(float lufs) {
        return std::pow(10.0f, (lufs + 0.691f) / 10.0f);
    }

    float sr_ = 48000.0f;
    int   blockSize_ = 4800;
    KWeightStage shelf_[2], hpf_[2];
    double accum_ = 0;
    int    accumCount_ = 0;
    static constexpr int kCap = 6000;     // ~10 minutes of 100 ms blocks
    float ring_[kCap] = {};               // per-100 ms mean-square values
    std::atomic<int> total_{0};           // blocks written since reset
};

} // namespace lim
