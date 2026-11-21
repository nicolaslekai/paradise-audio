//
//  ReverseProcessor.hpp — Ultra Reverse mode engine (2026-11-20, REVERSE_PLAN.md §3)
//
//  Four modes on one processor:
//
//    BLOOM (0)     legacy engine, unchanged (UltraReverseEngine, wet only)
//    ECHO (1)      x ─▶ SegmentReverser ─▶ reversed-repeat feedback loop        zero latency
//    REVERB (2)    x ─▶ FDN tank (100 % wet) ─▶ SegmentReverser                 zero latency
//    PRE-VERB (3)  x ─▶ convolution with the TIME-REVERSED tank impulse          latency = LOOKAHEAD
//                  dry ─▶ delay(LOOKAHEAD) so the swell crests ON the note
//
//  SegmentReverser: segment k = input [b_k, b_k+1). At b_k+1 a head starts that
//  reads that segment BACKWARDS at unity speed, so a note on a boundary swells
//  across the next segment and CUTS on its own attack exactly one segment later.
//  Boundaries follow the host bar grid (division) or run free (REVERSE secs).
//  Flat-top window: SMOOTH fade-in at playback start, CUT fade-out after the
//  reversed attack, unity gain in between (no Hann).
//
//  LOOKAHEAD (Off / 0.5 / 1 / 2 s) is the ONLY thing that sets the reported
//  latency. When it is on, every mode's wet is delayed by it too, so host
//  compensation stays correct in all modes; the dry is always delayed by it.
//
//  Threading: everything here runs on the audio thread except renderIR*(),
//  which renders + initialises the INACTIVE convolver slot on a background
//  queue and hands it over through an atomic state flag (no locks, no
//  allocation on the audio thread). The audio thread crossfades 50 ms into it.
//
#pragma once
#include "UltraReverse.hpp"
#include "third_party/FFTConvolver/TwoStageFFTConvolver.h"
#include <atomic>
#include <cmath>
#include <cstring>
#include <memory>
#include <vector>

namespace urv {

enum Mode : int { kModeBloom = 0, kModeEcho = 1, kModeReverb = 2, kModePreverb = 3, kNumModes = 4 };

struct HostTime {
    bool   hasTempo = false;   // host delivered a tempo
    bool   hasBeat  = false;   // host delivered a beat position
    bool   playing  = false;   // transport moving
    double tempo = 120.0;      // quarter notes per minute
    double beatPos = 0.0;      // quarter-note position of the block's first sample
    double beatsPerBar = 4.0;  // in quarter notes
};

/// Division index → length in quarter-note beats.
inline double divisionBeats(int d, double beatsPerBar) {
    switch (d) {
        case 0: return 0.25;  case 1: return 0.5;  case 2: return 0.75; case 3: return 1.0;
        case 4: return 1.5;   case 5: return 2.0;  case 6: return beatsPerBar;
        case 7: return 2.0 * beatsPerBar;
    }
    return 1.0;
}
inline const char* divisionName(int d) {
    static const char* n[] = {"1/16", "1/8", "1/8.", "1/4", "1/4.", "1/2", "1 BAR", "2 BAR"};
    return (d >= 0 && d < 8) ? n[d] : "1/4";
}
inline float lookaheadSeconds(int idx) {
    static const float s[] = {0.0f, 0.5f, 1.0f, 2.0f};
    return s[std::max(0, std::min(3, idx))];
}

// ── Stereo integer delay (latency compensation lines) ──────────────────────
class LatencyLine {
public:
    void prepare(int maxDelay) { N_ = std::max(1, maxDelay) + 1; l_.assign(N_, 0.0f); r_.assign(N_, 0.0f); w_ = 0; }
    void reset() { std::fill(l_.begin(), l_.end(), 0.0f); std::fill(r_.begin(), r_.end(), 0.0f); w_ = 0; }
    void setDelay(int d) { d_ = std::max(0, std::min(N_ - 1, d)); }
    int  delay() const { return d_; }
    inline void process(float& L, float& R) {
        l_[w_] = L; r_[w_] = R;
        int rd = w_ - d_; if (rd < 0) rd += N_;
        L = l_[rd]; R = r_[rd];
        if (++w_ >= N_) w_ = 0;
    }
private:
    std::vector<float> l_, r_; int N_ = 1, w_ = 0, d_ = 0;
};

// ── Segment reverser (stereo) ──────────────────────────────────────────────
class SegmentReverser {
public:
    static constexpr int kHeads = 4;

    void prepare(float sr, float maxSegSec) {
        sr_ = sr;
        Lmax_ = std::max(64, (int)std::ceil(maxSegSec * sr));
        Fmax_ = (int)std::ceil(0.1f * sr) + 2;              // fades ≤ 80 ms (+ margin)
        N_ = 2 * Lmax_ + 2 * Fmax_ + 64;
        bufL_.assign(N_, 0.0f); bufR_.assign(N_, 0.0f);
        M_ = Lmax_ + 8;
        fbL_.assign(M_, 0.0f); fbR_.assign(M_, 0.0f);
        reset();
    }
    void reset() {
        std::fill(bufL_.begin(), bufL_.end(), 0.0f); std::fill(bufR_.begin(), bufR_.end(), 0.0f);
        std::fill(fbL_.begin(), fbL_.end(), 0.0f);   std::fill(fbR_.begin(), fbR_.end(), 0.0f);
        t_ = 0; lastB_ = 0; nextB_ = -1; fbW_ = 0; fbLen_ = 0; lpL_ = lpR_ = 0.0f;
        for (auto& h : heads_) h.active = false;
    }
    /// Fade lengths in samples (latched per head when it starts).
    void setFades(int fin, int fout) { fin_ = std::max(1, std::min(Fmax_, fin)); fout_ = std::max(1, std::min(Fmax_, fout)); }
    /// Repeats: gain 0…0.95, one-pole LP in the loop, every repeat stays reversed.
    void setFeedback(float g, float lpHz) {
        fbGt_ = std::max(0.0f, std::min(0.95f, g));          // target; fbG_ glides per sample (5 ms)
        fbK_ = 1.0f - std::exp(-1.0f / (0.005f * sr_));
        const float w = k2Pi * std::max(200.0f, std::min(0.45f * sr_, lpHz)) / sr_;
        fbA_ = 1.0f - std::exp(-w);
    }
    /// Call once per block before process(). Grid: boundary `gridOffset` samples
    /// into the block, recurring every `gridLen` samples. Free: contiguous
    /// segments of `freeLen` samples (latched at each boundary).
    void beginBlock(bool grid, double gridOffset, double gridLen, int freeLen) {
        grid_ = grid;
        freeLen_ = std::max(64, std::min(Lmax_, freeLen));
        if (grid) {
            gridLen_ = std::max(64.0, std::min((double)Lmax_, gridLen));
            long long nb = t_ + (long long)std::llround(gridOffset);
            // Don't double-fire a boundary we just passed (rounding at block edges).
            if (nb - lastB_ < 32) nb += (long long)std::llround(gridLen_);
            nextB_ = nb;
        } else if (nextB_ < 0) {
            lastB_ = t_; nextB_ = t_ + freeLen_;
        }
    }
    /// Read-only position for the UI: 0…1 through the current segment.
    float phase() const {
        const long long len = std::max<long long>(1, nextB_ - lastB_);
        return (float)std::max(0.0, std::min(1.0, (double)(t_ - lastB_) / (double)len));
    }
    float segmentSeconds() const { return (float)std::max<long long>(0, nextB_ - lastB_) / sr_; }

    inline void process(float inL, float inR, float& outL, float& outR) {
        const int wi = (int)(t_ % N_);
        bufL_[wi] = inL; bufR_[wi] = inR;
        if (nextB_ >= 0 && t_ >= nextB_) boundary();

        float yl = 0.0f, yr = 0.0f;
        for (auto& h : heads_) {
            if (!h.active) continue;
            const long long rel = t_ - h.start;
            float g;
            if (rel < h.fin)                 g = std::sin(0.5f * kPi * ((float)rel + 0.5f) / (float)h.fin);
            else if (rel < h.len)            g = 1.0f;
            else if (rel < h.len + h.fout)   g = std::cos(0.5f * kPi * ((float)(rel - h.len) + 0.5f) / (float)h.fout);
            else { h.active = false; continue; }
            long long r = h.seg + h.len - 1 - rel;          // walks backwards, unity speed
            int ri = (int)(((r % N_) + N_) % N_);
            yl += g * bufL_[ri]; yr += g * bufR_[ri];
        }
        // Reversed repeats: delay the reversed output by one segment, filter,
        // soft-clip, feed back AFTER the reverser, so every repeat stays backwards.
        fbG_ += fbK_ * (fbGt_ - fbG_);
        if (fbG_ > 0.0005f && fbLen_ > 0) {
            int rd = fbW_ - fbLen_; if (rd < 0) rd += M_;
            yl += fbL_[rd]; yr += fbR_[rd];
            lpL_ += fbA_ * (yl - lpL_); lpR_ += fbA_ * (yr - lpR_);
            fbL_[fbW_] = std::tanh(fbG_ * lpL_); fbR_[fbW_] = std::tanh(fbG_ * lpR_);
        } else {
            fbL_[fbW_] = 0.0f; fbR_[fbW_] = 0.0f;
        }
        if (++fbW_ >= M_) fbW_ = 0;
        outL = yl; outR = yr;
        ++t_;
    }

private:
    struct Head { bool active = false; long long start = 0, seg = 0; int len = 0, fin = 1, fout = 1; };

    void boundary() {
        const long long t = t_;
        long long seg = lastB_;
        long long len = t - seg;
        if (len > Lmax_) { seg = t - Lmax_; len = Lmax_; }
        if (len >= 32) {
            Head* slot = nullptr;
            for (auto& h : heads_) if (!h.active) { slot = &h; break; }
            if (!slot) {                                    // all busy: replace the oldest
                slot = &heads_[0];
                for (auto& h : heads_) if (h.start < slot->start) slot = &h;
            }
            slot->active = true; slot->start = t; slot->seg = seg; slot->len = (int)len;
            slot->fin  = std::max(1, std::min(fin_,  (int)len / 2));
            slot->fout = std::max(1, std::min(fout_, (int)len / 2));
            fbLen_ = (int)std::min<long long>(len, M_ - 1);
        }
        lastB_ = t;
        nextB_ = grid_ ? t + (long long)std::llround(gridLen_) : t + freeLen_;
    }

    float sr_ = 48000.0f;
    std::vector<float> bufL_, bufR_, fbL_, fbR_;
    int N_ = 1, M_ = 1, Lmax_ = 64, Fmax_ = 2;
    long long t_ = 0, lastB_ = 0, nextB_ = -1;
    bool grid_ = false; double gridLen_ = 48000; int freeLen_ = 28800;
    int fin_ = 720, fout_ = 144;
    float fbG_ = 0.0f, fbGt_ = 0.0f, fbK_ = 0.004f, fbA_ = 0.5f, lpL_ = 0.0f, lpR_ = 0.0f;
    int fbW_ = 0, fbLen_ = 0;
    Head heads_[kHeads];
};

// ── Parameter snapshot handed in once per block ───────────────────────────
struct Params {
    float reverse = 0.6f, size = 0.7f, decay = 4.0f, shimmer = 0.3f, diffusion = 0.6f;
    float texture = 0.7f, predelay = 20.0f, tone = 0.5f, mix = 0.4f;
    int   mode = kModeEcho, sync = 1, division = 3;
    float smoothMs = 15.0f, cutMs = 3.0f, feedback = 0.3f, fbToneHz = 6000.0f;
    int   lookahead = 2;
    float lengthSec = 0.8f, gapMs = 0.0f;
};

/// Everything the Pre-Verb kernel depends on (re-render when any changes).
struct IRParams {
    float size = 0.7f, decay = 4.0f, diffusion = 0.6f, tone = 0.5f, lengthSec = 0.8f, gapMs = 0.0f;
    int   latencySamples = 48000;
    bool operator==(const IRParams& o) const {
        return size == o.size && decay == o.decay && diffusion == o.diffusion && tone == o.tone &&
               lengthSec == o.lengthSec && gapMs == o.gapMs && latencySamples == o.latencySamples;
    }
};

class ReverseProcessor {
public:
    static constexpr float kMaxSegSec = 8.0f;
    static constexpr float kMaxLookSec = 2.0f;

    void prepare(float sr, int maxFrames) {
        sr_ = sr; maxFrames_ = std::max(16, maxFrames);
        bloom_.prepare(sr); tank_.prepare(sr);
        echoRev_.prepare(sr, kMaxSegSec); verbRev_.prepare(sr, kMaxSegSec);
        const int maxD = (int)std::ceil(kMaxLookSec * sr) + 4;
        dryDelay_.prepare(maxD);
        for (auto& d : wetDelay_) d.prepare(maxD);
        auto sz = [&](std::vector<float>& v) { v.assign(maxFrames_, 0.0f); };
        sz(inL_); sz(inR_); sz(mono_); sz(cA_L_); sz(cA_R_); sz(cB_L_); sz(cB_R_);
        for (int m = 0; m < kNumModes; ++m) { sz(wL_[m]); sz(wR_[m]); }
        running_[0] = running_[1] = running_[2] = running_[3] = false;
        haveParams_ = false; firstBlock_ = true;
        mixCoef_ = 1.0f - std::exp(-1.0f / (0.010f * sr));          // 10 ms mix glide
        reset();
    }

    void reset() {
        bloom_.reset(); tank_.reset(); echoRev_.reset(); verbRev_.reset();
        dryDelay_.reset(); for (auto& d : wetDelay_) d.reset();
        // The Pre-Verb convolvers are NOT reset: in FFTConvolver reset() discards
        // the impulse response. Their state is ≤ LOOKAHEAD of past input and plays out.
        modeFade_ = -1;
    }

    // ── Pre-Verb kernel (background thread) ─────────────────────────────
    /// Render the reversed kernel into the INACTIVE slot and mark it ready.
    /// Returns false if a previous kernel is still being handed over (retry later).
    bool renderIR(const IRParams& p) {
        int expected = 0;
        if (!irState_.compare_exchange_strong(expected, 1)) return false;
        const int target = 1 - activeSlot_.load();
        buildKernel(p, slots_[target]);
        irState_.store(2);
        return true;
    }
    /// Synchronous first kernel (allocateRenderResources, no audio running).
    void renderIRNow(const IRParams& p) {
        buildKernel(p, slots_[0]);
        slots_[1].valid = false;
        activeSlot_.store(0); irState_.store(0); slotFade_ = -1;
    }

    // ── Audio thread ─────────────────────────────────────────────────────
    void setLatencySamples(int d) {
        if (d == latency_) return;
        latency_ = d;
        dryDelay_.setDelay(d); for (auto& w : wetDelay_) w.setDelay(d);
    }
    int latencySamples() const { return latency_; }

    /// outR == nullptr → mono host: outL receives the L/R average.
    void process(const Params& p, const HostTime& ht, const float* inLp, const float* inRp,
                 float* outL, float* outR, int n) {
        if (n <= 0) return;
        if (n > maxFrames_) {                               // defensive: split oversized blocks
            int done = 0;
            while (done < n) { const int c = std::min(maxFrames_, n - done);
                process(p, ht, inLp + done, inRp + done, outL + done, outR ? outR + done : nullptr, c); done += c; }
            return;
        }
        std::memcpy(inL_.data(), inLp, sizeof(float) * n);   // in-place safe
        std::memcpy(inR_.data(), inRp, sizeof(float) * n);
        applyParams(p, n);

        // Mode switch → 30 ms equal-power crossfade between the two modes.
        // The very first block starts straight in the session's mode.
        if (firstBlock_) { curMode_ = prevMode_ = std::max(0, std::min(3, p.mode)); modeFade_ = -1; firstBlock_ = false; }
        if (p.mode != curMode_) {
            prevMode_ = curMode_; curMode_ = std::max(0, std::min(3, p.mode));
            modeFade_ = 0; modeFadeLen_ = std::max(1, (int)(0.03f * sr_));
        }
        bool need[kNumModes] = {false, false, false, false};
        need[curMode_] = true; if (modeFade_ >= 0) need[prevMode_] = true;
        for (int m = 0; m < kNumModes; ++m) {
            if (need[m] && !running_[m]) startMode(m);
            running_[m] = need[m];
        }

        // Segment grid for ECHO / REVERB.
        beginSegments(p, ht, n);

        // Wet per mode.
        for (int i = 0; i < n; ++i) mono_[i] = 0.5f * (inL_[i] + inR_[i]);
        for (int m = 0; m < kNumModes; ++m) {
            float* wl = wL_[m].data(); float* wr = wR_[m].data();
            if (m == kModePreverb) renderPreverb(wl, wr, n);        // always: keeps its state continuous
            else if (!running_[m]) { std::memset(wl, 0, sizeof(float) * n); std::memset(wr, 0, sizeof(float) * n); }
            else renderMode(m, wl, wr, n);
            if (m != kModePreverb) for (int i = 0; i < n; ++i) wetDelay_[m].process(wl[i], wr[i]);
        }

        // Dry (always latency-aligned) + crossfaded wet.
        for (int i = 0; i < n; ++i) {
            mixSm_ += mixCoef_ * (mix_ - mixSm_);
            const float mix = mixSm_;
            float dl = inL_[i], dr = inR_[i];
            dryDelay_.process(dl, dr);
            float wl, wr;
            if (modeFade_ >= 0) {
                const float x = (float)modeFade_ / (float)modeFadeLen_;
                const float gIn = std::sin(0.5f * kPi * x), gOut = std::cos(0.5f * kPi * x);
                wl = gIn * wL_[curMode_][i] + gOut * wL_[prevMode_][i];
                wr = gIn * wR_[curMode_][i] + gOut * wR_[prevMode_][i];
                if (++modeFade_ >= modeFadeLen_) modeFade_ = -1;
            } else { wl = wL_[curMode_][i]; wr = wR_[curMode_][i]; }
            const float oL = (1.0f - mix) * dl + mix * wl, oR = (1.0f - mix) * dr + mix * wr;
            if (outR) { outL[i] = oL; outR[i] = oR; }
            else      { outL[i] = 0.5f * (oL + oR); }           // mono host
            probe(dl, dr, wl, wr);
        }
        uiPhase_.store(curMode_ == kModeReverb ? verbRev_.phase() : echoRev_.phase(), std::memory_order_relaxed);
        uiSegSec_.store(curMode_ == kModeReverb ? verbRev_.segmentSeconds() : echoRev_.segmentSeconds(), std::memory_order_relaxed);
    }

    // ── UI probes ────────────────────────────────────────────────────────
    static constexpr int probeSize() { return kProbeSize; }
    void readProbe(float* dryOut, float* wetOut, int count) const {
        const int n = std::min(count, kProbeSize);
        const int w = probeW_.load(std::memory_order_relaxed);
        for (int i = 0; i < n; ++i) { const int idx = (w - n + i) & kProbeMask; dryOut[i] = probeDry_[idx]; wetOut[i] = probeWet_[idx]; }
    }
    float segmentPhase() const { return uiPhase_.load(std::memory_order_relaxed); }
    float segmentSeconds() const { return uiSegSec_.load(std::memory_order_relaxed); }

private:
    struct Slot {
        fftconvolver::TwoStageFFTConvolver L, R;
        bool valid = false;
    };

    void buildKernel(const IRParams& p, Slot& s) {
        // 1) Impulse response of our own tank: 100 % wet, no shimmer (keeps it
        //    linear), no predelay, low level so the soft saturator stays out.
        const int D = std::max(0, p.latencySamples);
        const int gap = std::max(0, (int)std::lround(p.gapMs * 0.001f * sr_));
        int T = std::max(64, (int)std::lround(p.lengthSec * sr_));
        if (D > 0) T = std::max(64, std::min(T, D - gap));
        const int offset = (D > 0) ? std::max(0, D - gap - T) : 0;
        UltraReverseEngine eng; eng.prepare(sr_);
        eng.setSize(p.size); eng.setDecaySec(p.decay); eng.setDiffusion(p.diffusion); eng.setTone(p.tone);
        eng.setShimmer(0.0f); eng.setTexture(0.0f); eng.setPredelayMs(0.0f); eng.setMix(1.0f);
        // Render a little longer than T: the FDN response BUILDS UP for a few
        // hundred ms before it peaks. Reversed, that build-up would become a dip
        // right before the note, so the kernel starts at the response's energy
        // peak and the reversed swell crests ON the hit.
        const int pre = (int)(0.6f * sr_);
        const int N = T + pre;
        std::vector<float> rL(N), rR(N);
        for (int i = 0; i < N; ++i) { float l = (i == 0) ? 0.01f : 0.0f, r = l; eng.processFrame(l, r); rL[i] = l * 100.0f; rR[i] = r * 100.0f; }
        const int win = std::max(8, (int)(0.005f * sr_));
        int peak = 0; double best = -1.0, acc = 0.0;
        for (int i = 0; i < pre + win; ++i) {
            acc += (double)rL[i] * rL[i] + (double)rR[i] * rR[i];
            if (i >= win) acc -= (double)rL[i - win] * rL[i - win] + (double)rR[i - win] * rR[i - win];
            if (i >= win - 1 && acc > best) { best = acc; peak = i - win + 1; }
        }
        const int start = std::max(0, std::min(pre, peak));
        std::vector<float> hL(rL.begin() + start, rL.begin() + start + T), hR(rR.begin() + start, rR.begin() + start + T);
        // 2) Reverse in time; fade the reversed START (the truncated far tail) in,
        //    so the swell rises from silence and crests on the reverb's onset.
        std::vector<float> kL(offset + T, 0.0f), kR(offset + T, 0.0f);
        const int fi = std::max(1, (int)(0.35f * T));
        double e = 0.0;
        // SWELL shape: a fixed 30 dB exponential rise across the kernel on top of
        // the reverb's own (reversed) decay — a long DECAY only falls ~12 dB per
        // second, which reversed would be a flat wash rather than a swell.
        const float riseDb = 30.0f;
        for (int i = 0; i < T; ++i) {
            const float rise = std::pow(10.0f, -riseDb / 20.0f * (1.0f - (float)i / (float)(T - 1)));
            const float w = rise * ((i < fi) ? 0.5f - 0.5f * std::cos(kPi * (float)i / (float)fi) : 1.0f);
            kL[offset + i] = hL[T - 1 - i] * w; kR[offset + i] = hR[T - 1 - i] * w;
            e += 0.5 * ((double)kL[offset + i] * kL[offset + i] + (double)kR[offset + i] * kR[offset + i]);
        }
        // 3) Energy-normalise, calibrated on drums + a sustained vocal (wet ≈ −9 dB
        //    drums, −5 dB vocal vs input). Tonal input can resonate several dB
        //    above that (a pure sine sweep peaked +7 dB), so this keeps headroom.
        const float g = e > 1e-12 ? (float)std::sqrt(0.0316 / e) : 0.0f;
        for (int i = offset; i < offset + T; ++i) { kL[i] *= g; kR[i] *= g; }
        s.L.init(128, 4096, kL.data(), kL.size());
        s.R.init(128, 4096, kR.data(), kR.size());
        s.valid = true;
    }

    void applyParams(const Params& p, int n) {
        // Setters only run when a value changed (they cost pow/exp). Tank
        // parameters that move delay lengths or filters GLIDE per block, so a
        // jumped knob or automation step never clicks; a steady knob is exact.
        const float sec = (float)n / sr_;
        auto glide = [&](float& cur, float target, float perSec) {
            if (!haveParams_) { cur = target; return true; }
            const float step = perSec * sec, d = target - cur;
            if (d == 0.0f) return false;
            cur = (std::fabs(d) <= step) ? target : cur + (d > 0 ? step : -step);
            return true;
        };
        auto ch = [](float a, float b) { return a != b; };
        if (!haveParams_ || ch(p.reverse, last_.reverse)) bloom_.setReverse(p.reverse);
        if (glide(gSize_, p.size, 2.0f))         { bloom_.setSize(gSize_); tank_.setSize(gSize_); }
        if (glide(gDecay_, p.decay, 60.0f))      { bloom_.setDecaySec(gDecay_); tank_.setDecaySec(gDecay_); }
        if (!haveParams_ || ch(p.shimmer, last_.shimmer))     { bloom_.setShimmer(p.shimmer); tank_.setShimmer(p.shimmer); }
        if (glide(gDiff_, p.diffusion, 4.0f))    { bloom_.setDiffusion(gDiff_); tank_.setDiffusion(gDiff_); }
        if (!haveParams_ || ch(p.texture, last_.texture))       bloom_.setTexture(p.texture);
        if (glide(gPre_, p.predelay, 600.0f))    { bloom_.setPredelayMs(gPre_); tank_.setPredelayMs(gPre_); }
        if (glide(gTone_, p.tone, 4.0f))         { bloom_.setTone(gTone_); tank_.setTone(gTone_); }
        if (!haveParams_) {
            bloom_.setMix(1.0f); tank_.setMix(1.0f); tank_.setTexture(0.0f);
            bloom_.snapReverse();
        }
        if (!haveParams_ || ch(p.smoothMs, last_.smoothMs) || ch(p.cutMs, last_.cutMs)) {
            const int fin = (int)std::lround(p.smoothMs * 0.001f * sr_), fout = (int)std::lround(p.cutMs * 0.001f * sr_);
            echoRev_.setFades(fin, fout); verbRev_.setFades(fin, fout);
        }
        if (!haveParams_ || ch(p.feedback, last_.feedback) || ch(p.fbToneHz, last_.fbToneHz)) {
            echoRev_.setFeedback(p.feedback, p.fbToneHz);
            verbRev_.setFeedback(0.0f, p.fbToneHz);        // the tank already provides the tail
        }
        mix_ = std::max(0.0f, std::min(1.0f, p.mix));
        if (!haveParams_) mixSm_ = mix_;
        last_ = p; haveParams_ = true;
    }

    void startMode(int m) {
        switch (m) {
            case kModeBloom:   bloom_.reset(); bloom_.snapReverse(); break;
            case kModeReverb:  tank_.reset(); verbRev_.reset(); break;
            case kModeEcho:    echoRev_.reset(); break;
            case kModePreverb: break;              // its convolver runs continuously
        }
    }

    void beginSegments(const Params& p, const HostTime& ht, int /*n*/) {
        const double tempo = (ht.hasTempo && ht.tempo > 1.0) ? ht.tempo : 120.0;
        const double spb = 60.0 / tempo * sr_;               // samples per quarter beat
        const double divBeats = divisionBeats(p.division, ht.beatsPerBar > 0 ? ht.beatsPerBar : 4.0);
        const int freeLenSync = (int)std::lround(divBeats * spb);
        const int freeLenSec  = (int)std::lround(std::max(0.05f, p.reverse) * sr_);
        const bool sync = p.sync != 0;
        // Bar-grid lock needs a moving transport with a beat position.
        const bool grid = sync && ht.playing && ht.hasBeat && ht.hasTempo;
        double off = 0.0;
        if (grid) {
            const double k = std::ceil(ht.beatPos / divBeats - 1e-9);
            off = (k * divBeats - ht.beatPos) * spb;
            if (off < 0) off = 0;
        }
        const int freeLen = sync ? freeLenSync : freeLenSec;
        if (running_[kModeEcho])   echoRev_.beginBlock(grid, off, divBeats * spb, freeLen);
        if (running_[kModeReverb]) verbRev_.beginBlock(grid, off, divBeats * spb, freeLen);
    }

    void renderMode(int m, float* wl, float* wr, int n) {
        switch (m) {
            case kModeBloom:
                for (int i = 0; i < n; ++i) { float l = inL_[i], r = inR_[i]; bloom_.processFrame(l, r); wl[i] = l; wr[i] = r; }
                break;
            case kModeEcho:
                for (int i = 0; i < n; ++i) echoRev_.process(inL_[i], inR_[i], wl[i], wr[i]);
                break;
            case kModeReverb:
                for (int i = 0; i < n; ++i) {
                    float l = inL_[i], r = inR_[i]; tank_.processFrame(l, r);
                    // +8 dB make-up: the tank alone sits 10-14 dB under the input.
                    verbRev_.process(2.5f * l, 2.5f * r, wl[i], wr[i]);
                }
                break;
            case kModePreverb:
                renderPreverb(wl, wr, n);
                break;
        }
    }

    void renderPreverb(float* wl, float* wr, int n) {
        // Hand-over of a freshly rendered kernel → 50 ms crossfade old → new.
        if (slotFade_ < 0 && irState_.load() == 2) {
            slotFrom_ = activeSlot_.load(); slotTo_ = 1 - slotFrom_;   // freshly init'ed, clean state
            slotFade_ = 0; slotFadeLen_ = std::max(1, (int)(0.05f * sr_));
        }
        Slot& A = slots_[slotFade_ >= 0 ? slotFrom_ : activeSlot_.load()];
        if (A.valid) { A.L.process(mono_.data(), cA_L_.data(), n); A.R.process(mono_.data(), cA_R_.data(), n); }
        else { std::memset(cA_L_.data(), 0, sizeof(float) * n); std::memset(cA_R_.data(), 0, sizeof(float) * n); }
        if (slotFade_ < 0) { std::memcpy(wl, cA_L_.data(), sizeof(float) * n); std::memcpy(wr, cA_R_.data(), sizeof(float) * n); return; }
        Slot& B = slots_[slotTo_];
        if (B.valid) { B.L.process(mono_.data(), cB_L_.data(), n); B.R.process(mono_.data(), cB_R_.data(), n); }
        else { std::memset(cB_L_.data(), 0, sizeof(float) * n); std::memset(cB_R_.data(), 0, sizeof(float) * n); }
        for (int i = 0; i < n; ++i) {
            const float x = std::min(1.0f, (float)slotFade_ / (float)slotFadeLen_);
            const float gB = std::sin(0.5f * kPi * x), gA = std::cos(0.5f * kPi * x);
            wl[i] = gA * cA_L_[i] + gB * cB_L_[i]; wr[i] = gA * cA_R_[i] + gB * cB_R_[i];
            if (slotFade_ < slotFadeLen_) ++slotFade_;
        }
        if (slotFade_ >= slotFadeLen_) {                    // hand-over complete
            activeSlot_.store(slotTo_); slotFade_ = -1; irState_.store(0);
        }
    }

    inline void probe(float dl, float dr, float wl, float wr) {
        const float dA = std::fabs(0.5f * (dl + dr)), wA = std::fabs(0.5f * (wl + wr));
        if (dA > pDryAcc_) pDryAcc_ = dA;
        if (wA > pWetAcc_) pWetAcc_ = wA;
        if (++pDiv_ >= kProbeDecim) {
            pDiv_ = 0;
            const int w = probeW_.load(std::memory_order_relaxed);
            probeDry_[w & kProbeMask] = pDryAcc_; probeWet_[w & kProbeMask] = pWetAcc_;
            probeW_.store(w + 1, std::memory_order_relaxed);
            pDryAcc_ = pWetAcc_ = 0.0f;
        }
    }

    static constexpr int kProbeSize = 256, kProbeMask = kProbeSize - 1, kProbeDecim = 128;
    float probeDry_[kProbeSize] = {0}, probeWet_[kProbeSize] = {0};
    std::atomic<int> probeW_{0};
    int pDiv_ = 0; float pDryAcc_ = 0.0f, pWetAcc_ = 0.0f;
    std::atomic<float> uiPhase_{0.0f}, uiSegSec_{0.0f};

    float sr_ = 48000.0f; int maxFrames_ = 4096;
    UltraReverseEngine bloom_, tank_;
    SegmentReverser echoRev_, verbRev_;
    LatencyLine dryDelay_, wetDelay_[kNumModes];
    Slot slots_[2];
    std::atomic<int> irState_{0};      // 0 idle · 1 background rendering · 2 ready / handing over
    std::atomic<int> activeSlot_{0};
    int slotFade_ = -1, slotFadeLen_ = 2400, slotFrom_ = 0, slotTo_ = 1;
    int latency_ = 0;
    int curMode_ = kModeEcho, prevMode_ = kModeEcho, modeFade_ = -1, modeFadeLen_ = 1440;
    bool running_[kNumModes] = {false, false, false, false};
    float mix_ = 0.4f, mixSm_ = 0.4f, mixCoef_ = 0.001f;
    Params last_; bool haveParams_ = false, firstBlock_ = true;
    float gSize_ = 0.7f, gDecay_ = 4.0f, gDiff_ = 0.6f, gPre_ = 20.0f, gTone_ = 0.5f;   // glided tank params
    std::vector<float> inL_, inR_, mono_, cA_L_, cA_R_, cB_L_, cB_R_;
    std::vector<float> wL_[kNumModes], wR_[kNumModes];
};

} // namespace urv
