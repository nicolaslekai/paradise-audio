//
//  CompressorDSP.hpp
//
//  Feedforward compressor with soft knee, exponential attack/release,
//  automatic makeup, and a parallel dry/wet mix.
//

#pragma once

#include <cmath>
#include <atomic>
#include <algorithm>
#include "DSPCommon.hpp"
#include "EnvelopeFollower.hpp"

namespace cmp {

// ----------------------------------------------------------------------------
// DuckEngine — internal "phantom sidechain". Generates a percussive gain-
// reduction envelope locked to the host BPM. No real sidechain audio needed;
// the compressor adds the duck's extra GR (dB) on top of its own.
//
// Rate now selects from 12 rhythmic patterns — straight subdivisions plus
// genre grooves (house, ragga, dubstep, reggae, trap, etc.). Each pattern is
// a 16-step bar at 16th-note resolution.
// Depth: extra dB of attenuation injected per trigger.
// Shape: instant attack, exponential release (release time controllable).
// ----------------------------------------------------------------------------
enum DuckPattern : int {
    kDuck_1_1   = 1,
    kDuck_1_2   = 2,
    kDuck_1_4   = 3,
    kDuck_1_8   = 4,
    kDuck_1_16  = 5,
    kDuck_DotQ  = 6,    // dotted-quarter
    kDuck_Swing = 7,    // 8th swing
    kDuck_House = 8,    // 4-on-floor with hat ghost
    kDuck_Trap  = 9,    // half-time trap kick + lift
    kDuck_Dub   = 10,   // dubstep half-time wub
    kDuck_Ragga = 11,   // dancehall 3-3-3-3 syncopation
    kDuck_Reg   = 12    // reggae skank — off-beats only
};

class DuckEngine {
public:
    void prepare(float sr) {
        sr_ = sr;
        phase16_ = 0.0;
        lastStep_ = -1;
        envDB_ = 0.0f;
        targetDB_ = 0.0f;
        setReleaseMs(relMs_);
        setAttackMs(atkMs_);
    }
    void reset() { phase16_ = 0.0; lastStep_ = -1; envDB_ = 0.0f; targetDB_ = 0.0f; }

    void setEnabled(bool on)     { enabled_ = on; if (!on) { envDB_ = 0.0f; targetDB_ = 0.0f; } }
    bool isEnabled() const       { return enabled_; }
    void setBPM(float bpm)       { bpm_ = std::max(20.0f, std::min(300.0f, bpm)); }
    // Pattern index 1..12 — see DuckPattern enum. Out-of-range falls back to
    // 1/4 (kDuck_1_4) for safety.
    void setRate(int pat) {
        pattern_ = (pat >= 1 && pat <= 12) ? pat : kDuck_1_4;
    }
    int  pattern() const { return pattern_; }

    void setDepthDB(float d)     { depthDB_ = std::max(0.0f, std::min(36.0f, d)); }
    void setReleaseMs(float ms) {
        relMs_ = std::max(5.0f, std::min(2000.0f, ms));
        relCoeff_ = std::exp(-1.0f / (sr_ * 0.001f * relMs_));
    }
    // Duck-specific attack — a short smoothed rise on the gain-reduction onset.
    // The duck used to slam the GR up in a single sample (instant attack), which
    // clicked; this slews the rise over a few ms so it's a clean pump.
    void setAttackMs(float ms) {
        atkMs_ = std::max(0.05f, std::min(50.0f, ms));
        atkCoeff_ = 1.0f - std::exp(-1.0f / (sr_ * 0.001f * atkMs_));
    }

    // Manual fire (UI key press). Phase rewinds so the next pattern step is
    // one full bar from now.
    void manualTrigger() { targetDB_ = depthDB_; phase16_ = 0.0; lastStep_ = -1; }

    // Per-sample tick. Returns extra GR in dB (always positive) to add to
    // the compressor's own GR. The pattern grid is 16 sixteenth-notes per bar;
    // step transitions are what fire the duck — re-firing on the same step is
    // suppressed by lastStep_ to handle weird host buffer sizes.
    inline float processSample() {
        if (!enabled_) return 0.0f;
        // 16 sixteenth-notes per bar. Period of one 16th in seconds.
        const float sixteenthSec = (60.0f / bpm_) * 0.25f;
        phase16_ += 1.0 / (double)(sixteenthSec * sr_);
        if (phase16_ >= 16.0) phase16_ -= 16.0;
        const int step = (int)phase16_ & 15;
        if (step != lastStep_) {
            lastStep_ = step;
            if (kDuckPatterns[pattern_][step]) {
                targetDB_ = depthDB_;
            }
        }
        targetDB_ *= relCoeff_;   // the fired target releases exponentially
        // Smoothed rise (de-click) on the way up; follow the target straight
        // down on release so the pump still feels snappy.
        if (targetDB_ > envDB_) envDB_ += atkCoeff_ * (targetDB_ - envDB_);
        else                    envDB_ = targetDB_;
        return envDB_;
    }

    float currentDuckDB() const { return envDB_; }
    // UI phase = position within the bar 0..1
    float phase()        const { return (float)(phase16_ / 16.0); }

private:
    // 16-step patterns — one bar at sixteenth resolution. true = fire duck.
    // Designed by ear for each genre, then tuned so the accent placement
    // reads as that genre's groove at a glance.
    static constexpr bool kDuckPatterns[13][16] = {
        // idx 0 unused
        {0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0},
        // 1/1   — one duck per bar
        {1,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0},
        // 1/2   — halves
        {1,0,0,0, 0,0,0,0, 1,0,0,0, 0,0,0,0},
        // 1/4   — every quarter
        {1,0,0,0, 1,0,0,0, 1,0,0,0, 1,0,0,0},
        // 1/8   — every eighth
        {1,0,1,0, 1,0,1,0, 1,0,1,0, 1,0,1,0},
        // 1/16  — every sixteenth (machine-gun)
        {1,1,1,1, 1,1,1,1, 1,1,1,1, 1,1,1,1},
        // DotQ  — dotted quarter (3+3+3+3 with one extra hit)
        {1,0,0,0, 0,0,1,0, 0,0,0,0, 1,0,0,0},
        // SWING — quarters with a lift on the swung &
        {1,0,0,0, 0,1,0,0, 1,0,0,0, 0,1,0,0},
        // HOUSE — 4-on-floor + ghost off-beat
        {1,0,0,1, 1,0,0,1, 1,0,0,1, 1,0,0,1},
        // TRAP  — half-time kick + 2 trap rolls
        {1,0,0,0, 0,0,0,0, 1,0,0,0, 0,0,1,0},
        // DUB   — half-time with the wub on "the &" of 3
        {1,0,0,0, 0,0,0,0, 0,0,1,0, 0,0,0,0},
        // RAGGA — dancehall 3-3-3-3-4 syncopation
        {1,0,0,1, 0,0,1,0, 0,1,0,0, 1,0,0,1},
        // REGGAE — skank on beats 2 and 4 (off-pulse)
        {0,0,0,0, 1,0,0,0, 0,0,0,0, 1,0,0,0}
    };

    float  sr_       = 48000.0f;
    bool   enabled_  = false;
    float  bpm_      = 120.0f;
    int    pattern_  = kDuck_1_4;
    float  depthDB_  = 9.0f;
    float  relMs_    = 180.0f;
    float  relCoeff_ = 0.999f;
    float  atkMs_    = 3.0f;    // duck de-click attack (short smoothed rise)
    float  atkCoeff_ = 0.01f;
    double phase16_  = 0.0;     // position in 16ths within the bar
    int    lastStep_ = -1;
    float  envDB_    = 0.0f;    // smoothed gain-reduction (what's output)
    float  targetDB_ = 0.0f;    // instant-fired target that releases
};

// Define the static pattern table (C++17 allows constexpr static member
// definition out-of-class; some toolchains still need an explicit def).
constexpr bool DuckEngine::kDuckPatterns[13][16];

class Compressor {
public:
    void prepare(float sampleRateHz) {
        sr_ = sampleRateHz;
        det_.prepare(sampleRateHz);
        duck_.prepare(sampleRateHz);
        gainReductionDB_ = 0.0f;
        // Control smoothing (20 ms). THRESHOLD and RATIO also set the automatic
        // make-up gain, so an unsmoothed knob move / automation ramp stepped the
        // output level once per host buffer (zipper noise, measured −37 dBFS).
        smooth_ = timeToCoeff(20.0f, sampleRateHz);
        snap_ = true;            // first frame after prepare: jump to the current values
    }

    void reset() {
        det_.reset();
        duck_.reset();
        gainReductionDB_ = 0.0f;
    }

    // Parameters
    void setThresholdDB(float v) { thresholdDB_ = v; }
    void setRatio(float v)       { ratio_ = std::max(1.0f, v); }
    void setAttackMs(float v)    { det_.setAttackMs(v); }
    void setReleaseMs(float v)   { det_.setReleaseMs(v); }
    void setKneeDB(float v)      { kneeDB_ = std::max(0.0f, v); }
    void setMix(float v)         { mix_ = clamp(v, 0.0f, 1.0f); }

    // Duck access — set by AU each render block from host BPM + params,
    // and triggered on demand from UI key presses.
    DuckEngine& duck() { return duck_; }

    // Live gain reduction read-out (positive dB of attenuation). Includes duck.
    float currentGainReductionDB() const { return gainReductionDB_; }
    float currentDuckDB()         const { return duck_.currentDuckDB(); }

    // Process one stereo frame in-place.
    // Detector is fed the mono sum so L/R receive identical gain reduction
    // (avoids stereo image collapse from per-channel detection).
    inline void processFrame(float& left, float& right) {
        if (snap_) { thrS_ = thresholdDB_; ratioS_ = ratio_; kneeS_ = kneeDB_; mixS_ = mix_; snap_ = false; }
        thrS_   += smooth_ * (thresholdDB_ - thrS_);
        ratioS_ += smooth_ * (ratio_       - ratioS_);
        kneeS_  += smooth_ * (kneeDB_      - kneeS_);
        mixS_   += smooth_ * (mix_         - mixS_);

        const float mono = 0.5f * (left + right);
        const float envLin = det_.process(mono);
        const float envDB  = linToDb(envLin);

        // Soft-knee gain computer (Reiss & Zoelzer, Audio Effects). For an
        // input level x relative to threshold:
        //   if 2(x - T) < -W :   y = x           (no compression)
        //   if 2(x - T) >  W :   y = T + (x - T) / R
        //   else              :  smooth quadratic transition through the knee
        const float T = thrS_;
        const float R = ratioS_;
        const float W = std::max(kneeS_, 1e-3f);   // never 0: the knee branch divides by it
        const float overshoot = envDB - T;
        float yDB;
        if (2.0f * overshoot < -W) {
            yDB = envDB;
        } else if (2.0f * overshoot > W) {
            yDB = T + overshoot / R;
        } else {
            const float a = (overshoot + W * 0.5f);
            yDB = envDB + (1.0f / R - 1.0f) * a * a / (2.0f * W);
        }

        const float compGR = std::max(0.0f, envDB - yDB);   // attenuation in dB

        // Duck adds an extra dB of attenuation on top, fed from the internal
        // tempo-synced trigger. We add the dB values (multiplicative gains).
        const float duckGR = duck_.processSample();
        const float grDB   = compGR + duckGR;
        gainReductionDB_ = grDB;

        // Automatic makeup ~ half of "ideal" compensation. Keeps perceived
        // loudness roughly constant without overshooting on heavy ratios.
        const float makeupDB = -T * (1.0f - 1.0f / R) * 0.5f;
        const float gainLin = dbToLin(makeupDB - grDB);

        const float wetL = left  * gainLin;
        const float wetR = right * gainLin;
        left  = (1.0f - mixS_) * left  + mixS_ * wetL;
        right = (1.0f - mixS_) * right + mixS_ * wetR;

        // ── Visualizer probe ─────────────────────────────────────────────
        // Capture the pre- vs post-compression peak envelope so the UI can
        // draw the real signal being "smashed". We bucket-max within a small
        // window (peak-hold) so the scope shows true transients, not aliased
        // single samples. `mono` is the input (pre-gain); the post value is the
        // mix output we just wrote.
        const float inAbs  = std::fabs(mono);
        const float outAbs = std::fabs(0.5f * (left + right));
        if (inAbs  > probeInAcc_)  probeInAcc_  = inAbs;
        if (outAbs > probeOutAcc_) probeOutAcc_ = outAbs;
        if (++probeDiv_ >= kProbeDecim) {
            probeDiv_ = 0;
            const int w = probeW_.load(std::memory_order_relaxed);
            probeIn_[w & kProbeMask]  = probeInAcc_;
            probeOut_[w & kProbeMask] = probeOutAcc_;
            probeW_.store(w + 1, std::memory_order_relaxed);
            probeInAcc_ = 0.0f; probeOutAcc_ = 0.0f;
        }
    }

    // Snapshot the most-recent `count` probe buckets into caller arrays
    // (input peak + compressed-output peak). Called from the UI thread.
    void readProbe(float *inOut, float *outOut, int count) const {
        const int w = probeW_.load(std::memory_order_relaxed);
        const int n = std::min(count, kProbeSize);
        for (int i = 0; i < n; ++i) {
            const int idx = (w - n + i) & kProbeMask;
            inOut[i]  = probeIn_[idx];
            outOut[i] = probeOut_[idx];
        }
    }
    static constexpr int probeSize() { return kProbeSize; }

private:
    float sr_ = 48000.0f;

    // Params (atomic-ish: written from UI thread, read from audio thread).
    float thresholdDB_ = -18.0f;
    float ratio_       = 4.0f;
    float kneeDB_      = 6.0f;
    float mix_         = 1.0f;
    // Smoothed copies used by the audio path.
    float thrS_ = -18.0f, ratioS_ = 4.0f, kneeS_ = 6.0f, mixS_ = 1.0f;
    float smooth_ = 0.001f;
    bool  snap_ = true;

    EnvelopeFollower det_;
    DuckEngine duck_;

    // Read by the UI for the GR meter.
    float gainReductionDB_ = 0.0f;

    // ── Visualizer probe — power-of-two ring of input/output peak buckets ──
    // kProbeDecim samples per bucket → ~kProbeSize*kProbeDecim total window.
    // 512 * 96 ≈ 49k samples ≈ 1.0s @ 48k, a readable scrolling scope.
    static constexpr int kProbeSize  = 512;
    static constexpr int kProbeMask  = kProbeSize - 1;
    static constexpr int kProbeDecim = 96;
    mutable float probeIn_[kProbeSize]  = {0};
    mutable float probeOut_[kProbeSize] = {0};
    mutable std::atomic<int> probeW_{0};
    int   probeDiv_    = 0;
    float probeInAcc_  = 0.0f;
    float probeOutAcc_ = 0.0f;
};

} // namespace cmp
