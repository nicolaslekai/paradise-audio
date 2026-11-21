//
//  PitchTracker.hpp — monophonic voice pitch tracker for VoiceBox.
//
//  McLeod Pitch Method (NSDF, third_party/sevagh-mpm, MIT) on Accelerate,
//  plus the tracker layer from AUDIO_QUALITY_PLAN.md §2.1:
//   • voicing gate with hysteresis — voiced when clarity > 0.85 on two agreeing
//     hops and the level is above about −64 dBFS; unvoiced once clarity stays
//     < 0.70 for > 15 ms (or the level drops below about −70 dBFS);
//   • median of 3 on the pitch (in semitones) — the plan suggested 5; 3 halves
//     the lag (1 hop ≈ 2.7 ms) so hard tune follows fast vibrato (bench T3);
//   • octave guard — a jump of more than 5 st between two hops is only accepted
//     when it persists (16 ms if very clear, else 80 ms); then the median
//     restarts on the new pitch.
//  Window 32 ms (1536 samples @ 48 kHz), hop about 2.7 ms.
//
#pragma once
#include "third_party/sevagh-mpm/MpmVdsp.hpp"
#include <vector>
#include <cmath>
#include <algorithm>

namespace vbx {

struct TrackState {
    bool  voiced  = false;
    float midi    = 0.0f;   // median-filtered pitch (MIDI, fractional)
    float hz      = 0.0f;
    float clarity = 0.0f;   // NSDF peak 0…1
    float rms     = 0.0f;
};

class PitchTracker {
public:
    void prepare(float sr) {
        sr_ = sr;
        // 32 ms window: two periods down to 62 Hz. Its centre (n − W/2) then sits
        // about one pitch period after the output time n − L, i.e. on the centre
        // of the grain being synthesised — corrections line up with the audio.
        W_   = (int)std::lround(1536.0 * sr / 48000.0);
        hop_ = sr <= 50000.0f ? 128  : (sr <= 100000.0f ? 256  : 512);
        det_.prepare(W_);
        jumpFast_ = std::max(3, (int)std::lround(0.016 * sr / hop_));
        jumpSlow_ = std::max(3, (int)std::lround(0.080 * sr / hop_));
        reset();
    }
    void reset() { st_ = TrackState(); medN_ = 0; medW_ = 0; unvSamples_ = 0; jumpHops_ = 0; lastMidi_ = 0.0f; jumpMidi_ = 0.0f; hintHz_ = 0.0f; hintAge_ = 1000; }
    int window() const { return W_; }
    int hop() const { return hop_; }
    const TrackState& state() const { return st_; }

    /// x: the newest W samples, oldest first. Updates and returns the state.
    const TrackState& analyze(const float* x) {
        float ms = 0.0f; vDSP_measqv(x, 1, &ms, W_);
        const float rms = std::sqrt(ms);
        float clar = 0.0f;
        // Continuity hint: the previous raw estimate, while it is fresh (see MpmVdsp.hpp).
        const float hz = det_.detect(x, sr_, 70.0f, 1100.0f, clar, hintAge_ < 4 ? hintHz_ : 0.0f);
        const float rawMidi = hz > 0 ? 69.0f + 12.0f * std::log2(hz / 440.0f) : 0.0f;
        const bool agrees = hz > 0 && hintAge_ < 4 && hintHz_ > 0 && std::fabs(rawMidi - (69.0f + 12.0f * std::log2(hintHz_ / 440.0f))) < 1.0f;
        if (hz > 0 && clar > 0.5f) { hintHz_ = hz; hintAge_ = 0; } else if (hintAge_ < 1000) ++hintAge_;
        // Gate about −64 / −70 dBFS RMS (was −52 / −58: a quietly recorded take was never tuned);
        // the clarity test is what keeps noise out.
        const bool loud = rms > 0.0006f, silent = rms < 0.0003f;
        if (!st_.voiced) {
            // A note starts when two consecutive hops agree — a single (often octave-off) first guess does not.
            if (hz > 0 && clar > 0.85f && loud && agrees) { st_.voiced = true; unvSamples_ = 0; medN_ = 0; medW_ = 0; jumpHops_ = 0; }
        } else {
            if (silent) st_.voiced = false;
            else if (hz <= 0 || clar < 0.70f) { unvSamples_ += hop_; if (unvSamples_ > (int)(0.015f * sr_)) st_.voiced = false; }
            else unvSamples_ = 0;
        }
        if (st_.voiced && hz > 0 && clar > 0.5f) {
            float m = 69.0f + 12.0f * std::log2(hz / 440.0f);
            if (medN_ > 0 && std::fabs(m - lastMidi_) > kJumpSemis) {      // octave guard
                // A jump (> 5 st inside one 2.7 ms hop — no singer does that; real leaps glide or pass
                // through a consonant) must agree with itself and persist: 16 ms when the new pitch is
                // very clear (clarity ≥ 0.95 — e.g. a scooped onset that first read an octave high),
                // 80 ms otherwise (octave / twelfth flips on breathy, doubled or wet vocals are
                // shorter and are ridden out on the old pitch). When it is accepted the
                // median restarts on the new pitch — before 2026-11-21 the accepted value was
                // out-voted by the two old ones, the guard re-armed, and a wrong first estimate
                // (typical at a note onset) kept the whole note an octave off.
                if (jumpHops_ > 0 && std::fabs(m - jumpMidi_) > 1.0f) jumpHops_ = 0;
                jumpMidi_ = m;
                if (++jumpHops_ < (clar >= 0.95f ? jumpFast_ : jumpSlow_)) m = lastMidi_; else { jumpHops_ = 0; medN_ = 0; medW_ = 0; }
            } else jumpHops_ = 0;
            med_[medW_] = m; medW_ = (medW_ + 1) % kMed; medN_ = std::min(kMed, medN_ + 1);
            float tmp[kMed]; std::copy(med_, med_ + medN_, tmp); std::sort(tmp, tmp + medN_);
            const float med = tmp[medN_ / 2];
            lastMidi_ = med;
            st_.midi = med;
            st_.hz = 440.0f * std::pow(2.0f, (med - 69.0f) / 12.0f);
        }
        st_.clarity = clar; st_.rms = rms;
        return st_;
    }

private:
    float sr_ = 48000.0f;
    int   W_ = 1536, hop_ = 128;
    mpm::Detector det_;
    TrackState st_;
    static constexpr int kMed = 3;
    static constexpr float kJumpSemis = 5.0f;
    int   jumpFast_ = 6, jumpSlow_ = 30;
    float med_[kMed] = {}; int medN_ = 0, medW_ = 0;
    int   unvSamples_ = 0, jumpHops_ = 0;
    float lastMidi_ = 0.0f, jumpMidi_ = 0.0f, hintHz_ = 0.0f;
    int   hintAge_ = 1000;
};

} // namespace vbx
