//
//  Limiter.hpp
//
//  Lookahead brick-wall limiter. Standard topology:
//    1. Apply input gain.
//    2. Compute instantaneous peak (max abs L/R) across a small lookahead
//       window. The lookahead lets the gain reduction "see" peaks before
//       they hit so attack can be effectively instantaneous without clicks.
//    3. Convert peak → required gain reduction so post-limit output stays
//       under the ceiling.
//    4. Smooth gain reduction with an asymmetric envelope: the attack is a
//       fast ramp spread over the lookahead window (so the gain has fully
//       arrived by the time the peak is output — no one-sample step, no
//       click on the audio that precedes the transient), exponential release.
//    5. Apply the smoothed gain to the delayed (lookahead-aligned) sample
//       so the gain reduction is applied at the right moment.
//
//  K-weighting / true integrated LUFS is out of scope here; instead the
//  UI ships two presets that combine input GAIN + CEILING with values that
//  push typical material to roughly broadcast (-23 LUFS) and streaming
//  (-14 LUFS) loudness targets.
//

#pragma once

#include <algorithm>
#include <atomic>
#include <cmath>
#include <vector>
#include "Loudness.hpp"

namespace lim {

class Limiter {
public:
    void prepare(float sampleRateHz) {
        sr_ = sampleRateHz;
        // 5 ms lookahead — long enough to catch transients, short enough
        // to feel inaudible in a mix bus context.
        lookSamples_ = std::max(2, (int)std::round(0.005f * sr_));
        bufL_.assign(lookSamples_ + 4, 0.0f);
        bufR_.assign(lookSamples_ + 4, 0.0f);
        peakBuf_.assign(lookSamples_ + 4, 0.0f);
        writeIdx_ = 0;
        winMax_ = 0.0f; winMaxAge_ = 0;
        currentGain_ = 1.0f;
        targetGain_ = 1.0f;
        peakProbe_ = 0.0f;
        grProbe_ = 0.0f;
        loudness_.prepare(sr_);
        // Waveform ring — show ~2 seconds of post-limit signal.
        waveCap_ = (int)std::round(sr_ * 2.0f);
        waveBuf_.assign(waveCap_, 0.0f);
        waveWrite_.store(0);
        // Attack ramp: reaches ~99.8 % of the target within the lookahead.
        attackCoef_ = 1.0f - std::exp(-6.0f / (float)std::max(1, lookSamples_));
        updateReleaseCoef();
    }

    void reset() {
        std::fill(bufL_.begin(), bufL_.end(), 0.0f);
        std::fill(bufR_.begin(), bufR_.end(), 0.0f);
        std::fill(peakBuf_.begin(), peakBuf_.end(), 0.0f);
        writeIdx_ = 0;
        winMax_ = 0.0f; winMaxAge_ = 0;
        currentGain_ = 1.0f;
        targetGain_ = 1.0f;
        peakProbe_ = 0.0f;
        grProbe_ = 0.0f;
        loudness_.reset();
        std::fill(waveBuf_.begin(), waveBuf_.end(), 0.0f);
        waveWrite_.store(0);
    }
    /// Reset the integrated-loudness accumulator (UI "reset I" button).
    void resetIntegrated() { loudness_.reset(); }

    void setInputGainDB(float db)   { inputGainLin_ = std::pow(10.0f, db / 20.0f); }
    void setCeilingDB(float db) {
        ceilingDB_ = std::min(0.0f, db);
        ceilingLin_ = std::pow(10.0f, ceilingDB_ / 20.0f);
        // Auto make-up: lowering the ceiling drives the signal INTO the limiter
        // so the ceiling actually limits (and the output is pushed up to it),
        // instead of doing nothing until the source already exceeds it.
        autoMakeupLin_ = std::pow(10.0f, (-ceilingDB_) / 20.0f);
    }
    void setReleaseMs(float ms) { releaseMs_ = std::max(1.0f, ms); updateReleaseCoef(); }

    /// Current gain reduction in dB (positive number = how many dB the
    /// signal is being attenuated). UI reads this for the meter.
    float currentGainReductionDB() const { return grProbe_; }
    /// Smoothed input peak in dB (for the input meter).
    float currentInputPeakDB() const {
        return peakProbe_ > 0.00001f ? 20.0f * std::log10(peakProbe_) : -80.0f;
    }
    /// Short-term LUFS (rolling 3 s window) — for the live meter.
    float shortTermLUFS()  const { return loudness_.shortTermLUFS(); }
    /// Integrated LUFS (gated mean since last reset) — long-term target.
    float integratedLUFS() const { return loudness_.integratedLUFS(); }

    /// Drain `n` of the most-recent post-limit samples into `out`, newest
    /// first. Used by the waveform visualizer. Returns the count copied.
    int readWaveformLast(float* out, int n) const {
        if (!out || n <= 0 || waveCap_ <= 0) return 0;
        const int cap = waveCap_;
        const int w = waveWrite_.load(std::memory_order_relaxed);
        const int count = std::min(n, cap);
        for (int i = 0; i < count; ++i) {
            const int idx = (w - 1 - i + cap) % cap;
            out[i] = waveBuf_[idx];
        }
        return count;
    }

    inline void processFrame(float& L, float& R) {
        // 1. Input gain (user drive × ceiling auto make-up, so the ceiling
        //    pushes the signal up to itself and limits audibly)
        L *= inputGainLin_ * autoMakeupLin_;
        R *= inputGainLin_ * autoMakeupLin_;

        // 2. Write into the lookahead ring + record this sample's peak
        const int N = (int)bufL_.size();
        bufL_[writeIdx_] = L;
        bufR_[writeIdx_] = R;
        const float instPeak = std::max(std::fabs(L), std::fabs(R));
        peakBuf_[writeIdx_] = instPeak;

        // 3. Read the SAMPLE we're about to output (delayed by lookSamples_)
        const int readIdx = (writeIdx_ - lookSamples_ + N) % N;
        const float dL = bufL_[readIdx];
        const float dR = bufR_[readIdx];

        // 4. Scan the lookahead window for the max upcoming peak so we
        //    can start reducing gain BEFORE it arrives.
        //    Running maximum: the full scan (lookahead + 1 compares on every
        //    sample — 4 % of a core at 96 kHz) only happens when the current
        //    maximum has just left the window. Same result as scanning each time.
        if (instPeak >= winMax_) {
            winMax_ = instPeak; winMaxAge_ = 0;
        } else if (++winMaxAge_ > lookSamples_) {
            winMax_ = 0.0f; winMaxAge_ = 0;
            for (int i = 0; i <= lookSamples_; ++i) {
                const int idx = (writeIdx_ - i + N) % N;
                const float p = peakBuf_[idx];
                if (p > winMax_) { winMax_ = p; winMaxAge_ = i; }
            }
        }
        const float windowPeak = winMax_;

        // 5. Required gain so windowPeak * gain <= ceiling
        float reqGain = 1.0f;
        if (windowPeak > ceilingLin_) reqGain = ceilingLin_ / windowPeak;

        // Attack: ramp over the lookahead window; release: exponential
        if (reqGain < currentGain_) {
            currentGain_ += (reqGain - currentGain_) * attackCoef_;
        } else {
            currentGain_ += (reqGain - currentGain_) * releaseCoef_;
        }
        targetGain_ = reqGain;

        // 6. Apply gain to the delayed sample and write to output
        float outL = dL * currentGain_;
        float outR = dR * currentGain_;
        // Hard-clip backstop in case of overshoot (very rare given lookahead)
        outL = std::max(-ceilingLin_, std::min(ceilingLin_, outL));
        outR = std::max(-ceilingLin_, std::min(ceilingLin_, outR));

        L = outL; R = outR;
        // LUFS meter reads the OUTPUT — what actually leaves the plug-in —
        // so GAIN / CEILING / the STREAM & BROADCAST presets move the numbers.
        loudness_.processStereo(outL, outR);

        if (++writeIdx_ >= N) writeIdx_ = 0;

        // 7. Probe updates for UI (lightly smoothed)
        const float gr = (currentGain_ < 1.0f) ? -20.0f * std::log10(currentGain_) : 0.0f;
        grProbe_   += 0.05f * (gr - grProbe_);
        peakProbe_ += 0.05f * (instPeak - peakProbe_);

        // 8. Push the output sample (mono mix) into the waveform ring
        if (waveCap_ > 0) {
            const int w = waveWrite_.load(std::memory_order_relaxed);
            waveBuf_[w] = 0.5f * (outL + outR);
            waveWrite_.store((w + 1) % waveCap_, std::memory_order_relaxed);
        }
    }

private:
    void updateReleaseCoef() {
        const float tau = releaseMs_ * 0.001f * sr_;
        releaseCoef_ = 1.0f - std::exp(-1.0f / std::max(1.0f, tau));
    }

    float sr_ = 48000.0f;
    int   lookSamples_ = 240;
    int   writeIdx_ = 0;
    std::vector<float> bufL_, bufR_, peakBuf_;
    float winMax_ = 0.0f;      // running maximum of peakBuf_ over the lookahead window
    int   winMaxAge_ = 0;      // samples since that maximum was written
    float currentGain_ = 1.0f;
    float targetGain_  = 1.0f;
    float inputGainLin_ = 1.0f;
    float ceilingDB_    = -1.0f;
    float ceilingLin_   = std::pow(10.0f, -1.0f / 20.0f);
    float autoMakeupLin_ = std::pow(10.0f, 1.0f / 20.0f);   // = 10^(-ceilingDB/20)
    float releaseMs_    = 80.0f;
    float releaseCoef_  = 0.0f;
    float attackCoef_   = 0.025f;
    // UI probes
    float grProbe_   = 0.0f;
    float peakProbe_ = 0.0f;
    // LUFS metering
    LoudnessMeter loudness_;
    // Waveform ring buffer for the visualizer (post-limit samples).
    std::vector<float> waveBuf_;
    int                waveCap_   = 0;
    mutable std::atomic<int> waveWrite_{0};
};

} // namespace lim
