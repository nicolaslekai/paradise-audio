//
//  BMSDSP.hpp
//  Compact bass synth: PolyBLEP saw + sub + 2-op FM growl + noise → ladder
//  filter → amp env. 8-voice poly + mono/legato modes.
//

#pragma once
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <vector>

// Signalsmith Stretch (MIT) — pitch/time engine behind STRETCH / WARP.
// Header-only, vendored in DSP/third_party/signalsmith-stretch (see
// THIRD_PARTY_NOTICES.txt). FFTs on vDSP when building for Apple.
#if defined(__APPLE__) && !defined(SIGNALSMITH_USE_ACCELERATE)
#define SIGNALSMITH_USE_ACCELERATE 1
#endif
#include "third_party/signalsmith-stretch/signalsmith-stretch.h"

namespace bms {

constexpr float kPi = 3.14159265358979323846f;
constexpr int   kMaxVoices = 8;

inline float clamp(float v, float lo, float hi) { return std::max(lo, std::min(hi, v)); }
inline float noteToHz(float midi) { return 440.0f * std::pow(2.0f, (midi - 69.0f) / 12.0f); }

inline float polyBlepSaw(float& phase, float dt) {
    auto blep = [](float t, float dt) {
        if (t < dt) { t /= dt; return t + t - t * t - 1.0f; }
        if (t > 1.0f - dt) { t = (t - 1.0f) / dt; return t * t + t + t + 1.0f; }
        return 0.0f;
    };
    float v = 2.0f * phase - 1.0f - blep(phase, dt);
    phase += dt; if (phase >= 1.0f) phase -= 1.0f;
    return v;
}

class ADSR {
public:
    void setSR(float sr) { sr_ = sr; }
    void set(float a, float d, float s, float r) { a_ = a; d_ = d; s_ = s; r_ = r; }
    void gate(bool on) {
        if (on) { stage_ = 0; if (out_ <= 0.001f) out_ = 0.0f; }
        else    { stage_ = 3; }
    }
    inline float process() {
        switch (stage_) {
            case 0: { // attack
                const float k = 1.0f - std::exp(-1.0f / (std::max(0.001f, a_) * sr_));
                out_ += k * (1.05f - out_);
                if (out_ >= 1.0f) { out_ = 1.0f; stage_ = 1; }
                break;
            }
            case 1: { // decay
                const float k = 1.0f - std::exp(-1.0f / (std::max(0.001f, d_) * sr_));
                out_ += k * (s_ - out_);
                if (std::fabs(out_ - s_) < 0.001f) stage_ = 2;
                break;
            }
            case 2: { // sustain
                out_ = s_;
                break;
            }
            case 3: { // release
                const float k = 1.0f - std::exp(-1.0f / (std::max(0.001f, r_) * sr_));
                out_ += k * (0.0f - out_);
                if (out_ < 0.0005f) { out_ = 0; stage_ = 4; }
                break;
            }
            default: break;
        }
        return out_;
    }
    bool isIdle() const { return stage_ == 4 && out_ < 0.001f; }
private:
    float sr_ = 48000;
    float a_ = 0.005f, d_ = 0.18f, s_ = 0.7f, r_ = 0.32f;
    float out_ = 0;
    int   stage_ = 4;
};

class Ladder {
public:
    void setSR(float sr) { sr_ = sr; }
    void set(float fc, float res) { fc_ = clamp(fc, 20.0f, 0.45f * sr_); k_ = res * 4.0f; }
    void reset() { z_[0] = z_[1] = z_[2] = z_[3] = 0; }
    inline float process(float x) {
        const float g = std::tan(kPi * fc_ / sr_);
        const float G = g / (1.0f + g);
        const float feedback = k_ * z_[3];
        float u = x - feedback; u = std::tanh(u);
        for (int i = 0; i < 4; ++i) {
            const float v = (u - z_[i]) * G;
            const float y = v + z_[i];
            z_[i] = y + v;
            u = y;
        }
        return u;
    }
private:
    float sr_ = 48000, fc_ = 1000, k_ = 1.0f;
    float z_[4] = {0,0,0,0};
};

/// Vintage analog character presets. Engine maps each one to a tuple of
/// (drift_amount_cents, pre-filter drive, max_resonance, env_shape_bias,
///  output_saturation, sub_amt_bias).
///
/// CLEAN   — modern subtractive (current behaviour, drift OFF)
/// MOOG    — Minimoog flavour: fat ladder, mild drift, gentle drive, smooth env
/// 303     — TB-303 flavour: aggressive ladder Q, exponential env, accent boost
/// SH101   — Roland SH-101: slightly drifty, light saturation, snappy env
/// JUNO    — Juno-60: chorusy, slow drift, soft drive
enum BassCharacter : int {
    kCharClean = 0, kCharMoog = 1, kChar303 = 2, kCharSH101 = 3, kCharJuno = 4
};

class Voice {
public:
    void setSR(float sr) { sr_ = sr; ampEnv_.setSR(sr); fltEnv_.setSR(sr); flt_.setSR(sr); }
    void reset() {
        active_ = false; phaseSaw_ = 0; phaseSub_ = 0; phaseFM_ = 0; flt_.reset();
        driftState_ = 0;
    }

    /// Apply a character preset. Tweaks drift amount, pre-filter drive, max
    /// resonance, envelope shape, and output saturation in one go. Voices set
    /// their own per-voice seed so polyphonic chords sound naturally detuned.
    void setCharacter(int c) {
        character_ = std::max(0, std::min(4, c));
        switch (character_) {
            case kCharMoog:
                driftCents_ = 1.5f; drive_ = 1.3f; resBoost_ = 0.15f;
                outSat_ = 0.20f; envShape_ = 1.0f; break;
            case kChar303:
                driftCents_ = 0.4f; drive_ = 1.8f; resBoost_ = 0.45f;
                outSat_ = 0.35f; envShape_ = 1.4f; break;
            case kCharSH101:
                driftCents_ = 2.5f; drive_ = 1.15f; resBoost_ = 0.10f;
                outSat_ = 0.12f; envShape_ = 0.9f; break;
            case kCharJuno:
                driftCents_ = 3.0f; drive_ = 1.10f; resBoost_ = 0.05f;
                outSat_ = 0.10f; envShape_ = 0.85f; break;
            case kCharClean:
            default:
                driftCents_ = 0.0f; drive_ = 1.0f; resBoost_ = 0.0f;
                outSat_ = 0.0f; envShape_ = 1.0f; break;
        }
    }
    int  character() const { return character_; }
    /// Per-voice seed so chord voices drift independently (real analog VCOs
    /// each had their own tuning ICs and noise paths).
    void setVoiceSeed(uint32_t s) { driftRng_ = s ? s : 0xA5A5A5A5u; rng_ = s ^ 0xDEADBEEFu; }

    void setAmpADSR(float a, float d, float s, float r) { ampEnv_.set(a, d, s, r); }
    void setFltADSR(float a, float d, float s, float r) { fltEnv_.set(a, d, s, r); }
    void setOct(int o) { oct_ = o; }
    void setDetuneCents(float c) { detune_ = std::pow(2.0f, c / 1200.0f); }
    void setSub(float s) { subAmt_ = s; }
    void setFM(float g, float ratio) { fmAmt_ = g; fmRatio_ = ratio; }
    void setNoise(float n) { noiseAmt_ = n; }
    void setFilter(float cutoff, float res, float envAmt) { baseCutoff_ = cutoff; res_ = res; envAmt_ = envAmt; }
    void setGlideMs(float ms) { glideMs_ = ms; }

    void noteOn(int n, float vel) {
        active_ = true; note_ = n; vel_ = vel;
        ampEnv_.gate(true); fltEnv_.gate(true);
        const float target = noteToHz(float(n + oct_ * 12));
        if (currentHz_ <= 0 || glideMs_ < 1.0f) currentHz_ = target;
        targetHz_ = target;
    }
    void noteOff() { ampEnv_.gate(false); fltEnv_.gate(false); }
    bool isActive() const { return active_ && !ampEnv_.isIdle(); }
    int  midiNote() const { return note_; }

    inline float process() {
        if (!isActive()) return 0.0f;
        // Glide
        const float glideCoeff = glideMs_ < 1.0f ? 1.0f : 1.0f - std::exp(-1.0f / (glideMs_ * 0.001f * sr_));
        currentHz_ += glideCoeff * (targetHz_ - currentHz_);

        // ── Analog VCO drift ────────────────────────────────────────────
        // White-noise → very-slow lowpass = lazy random LFO. Scale to
        // ±driftCents_, exponentiate into a pitch multiplier. Each voice has
        // its own seed so polyphonic notes drift independently — that's the
        // beating you hear on a Juno or Prophet.
        driftRng_ = driftRng_ * 1664525u + 1013904223u;
        const float driftNoise = (((driftRng_ >> 8) & 0x00FFFFFF) / 8388608.0f - 1.0f);
        const float driftLpCoeff = 1.0f - std::exp(-1.0f / (0.7f * sr_));   // ~1.4s τ
        driftState_ += driftLpCoeff * (driftNoise - driftState_);
        const float driftMul = std::pow(2.0f, driftState_ * driftCents_ / 1200.0f);

        const float hzMod = currentHz_ * driftMul;
        const float f1 = hzMod * detune_;
        const float f2 = hzMod / detune_;
        const float dt1 = f1 / sr_, dt2 = f2 / sr_;
        const float saw1 = polyBlepSaw(phaseSaw_, dt1);
        const float saw2 = polyBlepSaw(phaseSub_, dt2 * 0.5f); // 1 oct down used as sub
        phaseFM_ += 2.0f * kPi * hzMod * 0.5f / sr_; if (phaseFM_ > 2.0f * kPi) phaseFM_ -= 2.0f * kPi;
        const float sub = std::sin(phaseFM_);
        const float fm = std::sin(phaseFM_ * fmRatio_) * fmAmt_;
        rng_ = rng_ * 1664525u + 1013904223u;
        const float n = (((rng_ >> 8) & 0x00FFFFFF) / 8388608.0f - 1.0f) * noiseAmt_;

        float mix = (saw1 * 0.4f + saw2 * 0.3f + sub * subAmt_ + fm + n) * 0.6f;
        // Pre-filter drive — character-dependent. Pushes the ladder's tanh
        // feedback path into saturation, which is what gives Moog/303 their
        // signature thickness.
        if (drive_ > 1.0001f) mix *= drive_;

        const float fenv = fltEnv_.process();
        // Envelope shape bias — 303-style env curves harder near release.
        const float fenvShaped = (envShape_ > 1.0f)
            ? std::pow(fenv, envShape_)
            : fenv;
        // resBoost_ lifts the max resonance — 303 self-oscillates around the
        // peak. Voice's resonance setter clamps to 1.0; we boost beyond when
        // the character calls for it.
        const float resWithBoost = std::min(1.2f, res_ + resBoost_);
        const float fc = baseCutoff_ * std::pow(2.0f, envAmt_ * fenvShaped * 4.0f);
        flt_.set(fc, resWithBoost);
        float filtered = flt_.process(mix);

        // Output VCA saturation — transistor warmth on the way out. Soft
        // tanh, amount controlled by character preset.
        if (outSat_ > 0.001f) {
            const float driven = filtered * (1.0f + outSat_ * 2.0f);
            filtered = std::tanh(driven) / (1.0f + outSat_);
        }

        const float aenv = ampEnv_.process();
        return filtered * aenv * vel_;
    }
private:
    float sr_ = 48000;
    bool  active_ = false;
    int   note_ = 60;
    float vel_ = 1.0f;
    int   oct_ = 0;
    float detune_ = 1.0f;
    float subAmt_ = 0.7f, fmAmt_ = 0, fmRatio_ = 1.5f, noiseAmt_ = 0;
    float baseCutoff_ = 600, res_ = 0.25f, envAmt_ = 0.4f;
    float glideMs_ = 45;
    float currentHz_ = -1, targetHz_ = 0;
    float phaseSaw_ = 0, phaseSub_ = 0, phaseFM_ = 0;
    uint32_t rng_ = 0xBADC0FFEu;
    // Analog character state
    int      character_ = kCharClean;
    float    driftCents_ = 0.0f;   // ± cents of pitch drift
    float    drive_ = 1.0f;        // pre-filter overdrive
    float    resBoost_ = 0.0f;     // boost to max resonance
    float    outSat_ = 0.0f;       // output VCA saturation
    float    envShape_ = 1.0f;     // filter env curve bias (>1 = exponential)
    float    driftState_ = 0.0f;
    uint32_t driftRng_ = 0xCAFEF00Du;
    ADSR ampEnv_, fltEnv_;
    Ladder flt_;
};

// ----------------------------------------------------------------------------
// VocalLayer — loads a bundled vocal sample (loaded at AU init time via Swift),
// plays it underneath every bass note. Per-note retrigger, varispeed pitch shift
// (semitones), optional follow-note tuning, loop/one-shot/hold modes, mix.
// Audio-thread-safe: buffer pointer is swapped atomically; the buffer itself is
// owned by the audio unit (which guarantees lifetime past last render).
// ----------------------------------------------------------------------------
class VocalLayer {
public:
    void prepare(float sr) {
        sr_ = sr;
        position_ = 0.0;
        playing_  = false;
        env_      = 0.0f;
        lpZ_ = airZ_ = 0.0f;
        for (int i = 0; i < kShimmerLen; ++i) dly_[i] = 0.0f;
        dlyW_ = 0;
        revLen_ = std::min(kRevMax - 1, (int)(sr_ * 0.037f));
        apLen_  = std::min(kApMax  - 1, (int)(sr_ * 0.005f));
        revIdx_ = apIdx_ = 0; revLp_ = 0.0f;
        for (int i = 0; i < kRevMax; ++i) revBuf_[i] = 0.0f;
        for (int i = 0; i < kApMax;  ++i) apBuf_[i]  = 0.0f;
        recomputeCoeffs();
        // WARP engine: 120 ms blocks / 30 ms hop (Signalsmith's default
        // preset — the voice-quality setting). Allocates, so only here, never
        // on the render path. Split computation off: its extra interval of
        // latency would make legato retunes lag more.
        stretch_.presetDefault(1, sr_, false);
        warpOn_ = false; chunkPos_ = kChunk; inAcc_ = 0.0; vpos_ = 0;
        lastTranspose_ = -1.0f; lastFormant_ = -1;
    }
    void reset() {
        warpOn_ = false; chunkPos_ = kChunk; inAcc_ = 0.0;
        position_ = 0.0; playing_ = false; env_ = 0.0f;
        lpZ_ = airZ_ = 0.0f;
        for (int i = 0; i < kShimmerLen; ++i) dly_[i] = 0.0f;
        dlyW_ = 0;
        revIdx_ = apIdx_ = 0; revLp_ = 0.0f;
        for (int i = 0; i < kRevMax; ++i) revBuf_[i] = 0.0f;
        for (int i = 0; i < kApMax;  ++i) apBuf_[i]  = 0.0f;
    }

    // Hand the engine a pointer + length to a mono Float32 buffer at sample rate
    // `srcSR`. Caller retains ownership; pointer must outlive future renders.
    // `onset` < 0 = compute it here (O(n) — callers on the render thread pass
    // the value they precomputed off-thread with computeOnset()).
    void setSample(const float* data, int length, float srcSR, int onset = -1) {
        data_   = data;
        length_ = length;
        srcSR_  = srcSR > 0 ? srcSR : sr_;
        onsetIndex_ = onset >= 0 ? std::min(onset, std::max(0, length - 2))
                                 : computeOnset(data, length, srcSR_);   // skip any leading silence
        // A new buffer under a sounding note: restart it from the onset.
        if (playing_) { position_ = (double)onsetIndex_; if (warpOn_) warpStart(onsetIndex_); }
    }

    // Find the first "loud" sample so every note begins at the body of the
    // recording instead of the silence/breath before it. Uses a short
    // moving-average of |x| crossing 8% of the sample's peak (with an absolute
    // floor), then backs off ~1 ms so we don't clip the attack transient.
    static int computeOnset(const float* data, int length, float srcSR) {
        if (!data || length < 2) return 0;
        float peak = 0.0f;
        for (int i = 0; i < length; ++i) { const float a = std::fabs(data[i]); if (a > peak) peak = a; }
        if (peak < 1e-6f) return 0;
        const float thr = std::max(peak * 0.08f, 0.004f);
        int win = (int)(srcSR * 0.003f); if (win < 1) win = 1;     // ~3 ms smoothing
        if (win >= length) return 0;
        float acc = 0.0f;
        for (int k = 0; k < win; ++k) acc += std::fabs(data[k]);
        for (int i = 0; i + win < length; ++i) {
            if (acc / (float)win > thr) {
                int start = i - (int)(srcSR * 0.001f);              // keep ~1 ms of attack
                return start < 0 ? 0 : start;
            }
            acc += std::fabs(data[i + win]) - std::fabs(data[i]);  // slide the window
        }
        return 0;
    }
    int onsetIndex() const { return onsetIndex_; }
    bool hasSample() const { return data_ != nullptr && length_ > 1; }
    int  sampleLength() const { return length_; }
    const float* sampleData() const { return data_; }

    void setMix(float m)        { mix_ = clamp(m, 0.0f, 1.0f); }
    void setEnabled(bool on)    { enabled_ = on; if (!on) { playing_ = false; env_ = 0.0f; } }
    bool isEnabled() const      { return enabled_; }
    void setPitchSemi(float st) { pitchSemi_ = clamp(st, -24.0f, 24.0f); }
    void setFollow(bool f)      { follow_ = f; }
    // mode: 0=oneshot, 1=loop, 2=hold-until-noteoff (loops while held)
    void setMode(int m)         { mode_ = (m < 0 ? 0 : (m > 2 ? 2 : m)); }

    // ── STRETCH / WARP (2026-11-21) ─────────────────────────────────────
    // Ableton-style: WARP OFF plays the sample the classic way (varispeed —
    // PITCH and FOLLOW change speed AND pitch, exactly as before). Any other
    // WARP setting, or a STRETCH away from 1.00x, routes the voice through
    // Signalsmith Stretch in real time: length and pitch become independent.
    //   warp 0 = OFF · 1 = FREE (STRETCH knob) · 2..8 = SYNC to the host tempo
    //   (1/4 beat, 1/2 beat, 1 beat, 2 beats, 1 bar, 2 bars, 4 bars)
    //   stretchLog2: length factor as log2 (-2..+2 = 0.25x..4x)
    //   formant: keep the voice's formants when transposing (no chipmunk)
    static constexpr int kWarpModes = 9;
    /// Target length of a SYNC mode in beats (<0 = bars).
    static float warpBeats(int m) {
        static const float kB[kWarpModes] = {0, 0, 0.25f, 0.5f, 1.0f, 2.0f, -1.0f, -2.0f, -4.0f};
        return (m >= 0 && m < kWarpModes) ? kB[m] : 0.0f;
    }
    void setWarp(int mode, float stretchLog2, bool formant) {
        warpMode_    = std::max(0, std::min(kWarpModes - 1, mode));
        stretchLog2_ = clamp(stretchLog2, -2.0f, 2.0f);
        formant_     = formant;
    }
    /// Host tempo (BPM) and bar length in quarter-note beats (4 in 4/4).
    void setTempo(float bpm, float barBeats) {
        if (bpm > 1.0f) bpm_ = clamp(bpm, 20.0f, 999.0f);
        if (barBeats > 0.0f) barBeats_ = clamp(barBeats, 0.5f, 32.0f);
    }
    /// True when the warp engine (not varispeed) plays the voice.
    bool warpWanted() const { return warpMode_ != 0 || std::fabs(stretchLog2_) > 1e-4f; }
    /// Length factor the warp engine is applying (1 = original length).
    float effectiveStretch() const {
        if (!warpWanted()) return 1.0f;
        if (warpMode_ >= 2 && hasSample()) {
            float beats = warpBeats(warpMode_);
            if (beats < 0) beats = -beats * barBeats_;
            const double targetSec = beats * 60.0 / bpm_;
            const double srcSec = (double)std::max(1, length_ - onsetIndex_) / (double)srcSR_;
            return (float)std::max(0.125, std::min(8.0, targetSec / srcSec));
        }
        return std::pow(2.0f, stretchLog2_);
    }

    // ── Vocal FX (replace the old envelope-shape controls — those all felt
    // like the same thing). These are real effectors applied to the vocal
    // layer as it plays underneath the bass:
    //   DRIVE   — tanh saturation, fattens the breath/consonants
    //   TONE    — one-knob tilt EQ: 0=dark, 0.5=neutral, 1=bright
    //   AIR     — high-shelf boost above ~6 kHz (sibilance/presence)
    //   SHIMMER — short octave-up echo, ghosts a high voice over the bass
    void setDrive(float d)   { drive_ = clamp(d, 0.0f, 1.0f); }
    void setDistortion(float d) { dist_ = clamp(d, 0.0f, 1.0f); }
    void setTone(float t)    { tone_  = clamp(t, 0.0f, 1.0f); recomputeTone(); }
    void setAir(float a)     { air_   = clamp(a, 0.0f, 1.0f); }
    void setShimmer(float s) { shimmer_ = clamp(s, 0.0f, 1.0f); }
    void setReverb(float r)  { reverb_ = clamp(r, 0.0f, 1.0f); }

    /// Two filters on the front of the vocal chain, plus a bypass.
    ///   HP 0..1 -> 20 Hz .. 2 kHz  (1-pole, clears rumble and chest)
    ///   LP 0..1 -> 200 Hz .. 18 kHz (2-pole, tames sibilance / fizz)
    /// FILT off bypasses both without having to re-dial them, so you can A/B
    /// the filtered and unfiltered voice on one click.
    void setFilters(float hp01, float lp01, bool on) {
        fHp01_  = clamp(hp01, 0.0f, 1.0f);
        fLp01_  = clamp(lp01, 0.0f, 1.0f);
        filtOn_ = on;
        recomputeFilters();
    }
    float filterHP() const { return fHp01_; }
    float filterLP() const { return fLp01_; }
    bool  filtersOn() const { return filtOn_; }

    /// Retune the sustaining texture to a new note WITHOUT restarting playback
    /// (so holding/changing keys keeps one continuous voice).
    void retune(int midiNote) { currentNote_ = midiNote; }

    // Called on every synth note-on. midiNote = currently played note (for
    // follow-pitch mode; we tune so MIDI 36 = original pitch).
    void noteOn(int midiNote) {
        if (!enabled_ || !hasSample()) return;
        // Start at the loud onset (skips the leading silence/breath) so every
        // note begins on the body of the sample.
        position_ = (double)onsetIndex_;
        playing_  = true;
        env_      = 1.0f;
        holdReleasing_ = false;   // a retrigger inside the release tail used to keep fading the NEW note
        currentNote_ = midiNote;
        warpOn_ = warpWanted();
        if (warpOn_) warpStart(onsetIndex_);
    }
    void noteOff() {
        // In one-shot mode we let it finish; in hold mode we fade out; in loop
        // mode we also fade out so released notes don't keep ringing.
        if (mode_ != 0) { holdReleasing_ = true; }
    }

    inline float process() {
        if (!enabled_ || !playing_ || !hasSample()) return 0.0f;
        float y;
        // WARP switched while a note sounds: change engines in place, from
        // the current playhead.
        const bool want = warpWanted();
        if (want != warpOn_) {
            warpOn_ = want;
            if (want) warpStart((long long)std::max(0.0, position_));
        }
        if (warpOn_) {
            // Real-time stretch: pull from a 64-sample chunk the stretcher
            // renders ahead (no added latency — a chunk is made the moment
            // its first sample is needed).
            if (chunkPos_ >= kChunk && !warpFill()) { playing_ = false; return 0.0f; }
            y = chunk_[chunkPos_++];
        } else {
            // Classic varispeed (unchanged): pitch ratio combines user
            // semitones + (optional) note follow, so pitch also sets speed.
            float noteOffsetSemi = 0.0f;
            if (follow_) noteOffsetSemi = (float)(currentNote_ - 36);
            const double ratio = (double)srcSR_ / (double)sr_ * std::pow(2.0, (double)(pitchSemi_ + noteOffsetSemi) / 12.0);

            const int endIdx = length_;
            const int i0 = (int)position_;
            if (i0 < 0 || i0 + 1 >= endIdx) {
                // Either past end or out of bounds: handle by mode
                if (mode_ == 1 || (mode_ == 2 && !holdReleasing_)) {
                    position_ = (double)onsetIndex_;   // loop back to the loud onset, not the silence
                } else {
                    playing_ = false;
                    return 0.0f;
                }
            }
            const int idx = (int)position_;
            const float frac = (float)(position_ - (double)idx);
            const float s0 = data_[idx];
            const float s1 = data_[idx + 1];
            y = s0 + (s1 - s0) * frac;
            position_ += ratio;
        }

        // Release envelope when hold is releasing (kept; fixed 60ms tail
        // smoothes note-off — no UI knob, this is just there to avoid clicks)
        if (holdReleasing_) {
            env_ *= relCoef_;
            if (env_ < 0.001f) { playing_ = false; holdReleasing_ = false; env_ = 0.0f; }
        }
        y *= env_;

        // ── 0. Two-filter front end (bypassable) ────────────────────────
        // Deliberately ahead of DRIVE/DISTORTION: filtering before the
        // saturation decides which harmonics get generated, which is a far
        // more useful place for these than a tone control on the output.
        if (filtOn_) {
            hpZ_ += hpCoef_ * (y - hpZ_);       // 1-pole LP state...
            y -= hpZ_;                          // ...subtracted = high-pass
            lp1Z_ += lpCoef_ * (y - lp1Z_);     // 2-pole low-pass
            lp2Z_ += lpCoef_ * (lp1Z_ - lp2Z_);
            y = lp2Z_;
        }

        // ── Vocal FX chain ──────────────────────────────────────────────
        // 1. DRIVE — tanh on the dry signal. Subtle at low amounts; bites at high.
        if (drive_ > 0.001f) {
            const float pre = 1.0f + drive_ * 5.0f;
            y = std::tanh(y * pre) * (1.0f - 0.4f * drive_);
        }
        // 1b. DISTORTION — harder, hard-clipping drive (grittier than DRIVE's
        //     soft tanh). Dry→clipped blend so 0 = clean, 1 = full hard clip.
        if (dist_ > 0.001f) {
            const float pre = 1.0f + dist_ * 20.0f;
            float wet = std::max(-1.0f, std::min(1.0f, y * pre)) * (1.0f - 0.5f * dist_);
            y = y * (1.0f - dist_) + wet * dist_;
        }

        // 2. TONE — one-knob tilt. One-pole LP gives us the low half, and we
        //    crossfade between the LP'd signal (dark) and the original (bright).
        //    0 = all low-pass (dark), 0.5 = neutral, 1 = original + a touch of HF.
        lpZ_ += toneLpCoef_ * (y - lpZ_);
        if (tone_ < 0.5f) {
            // dark side: more LP, less hi
            const float k = (0.5f - tone_) * 2.0f; // 0..1
            y = y * (1.0f - k) + lpZ_ * k;
        } else if (tone_ > 0.5f) {
            // bright side: subtract a bit of the LP'd to lift highs
            const float k = (tone_ - 0.5f) * 2.0f; // 0..1
            y = y + (y - lpZ_) * (0.6f * k);
        }

        // 3. AIR — high-shelf above ~6 kHz. Cheap: y_air = y - LPF(y, 6k).
        airZ_ += airLpCoef_ * (y - airZ_);
        if (air_ > 0.001f) {
            y = y + (y - airZ_) * (1.5f * air_);
        }

        // 4. SHIMMER — short octave-up echo. Read the delay line at 2× rate to
        //    pitch-up; write current sample with feedback. Ghosts a high voice.
        if (shimmer_ > 0.001f) {
            const int rIdx = (dlyW_ - 2400) & (kShimmerLen - 1); // ~50ms @ 48k
            // Read at 2x speed for octave-up effect, accumulating two taps.
            const int rIdx2 = (dlyW_ - 1200) & (kShimmerLen - 1);
            const float tap1 = dly_[rIdx];
            const float tap2 = dly_[rIdx2];
            const float oct = (tap1 + tap2) * 0.5f;
            dly_[dlyW_] = y + oct * 0.5f; // feedback
            dlyW_ = (dlyW_ + 1) & (kShimmerLen - 1);
            y = y + oct * shimmer_ * 0.8f;
        }

        // 5. REVERB — damped feedback comb + allpass diffuser. Gives the
        //    sustained texture a roomy tail (the "wash" the bass sits in).
        if (reverb_ > 0.001f && revLen_ > 1) {
            float rout = revBuf_[revIdx_];
            revLp_ += (rout - revLp_) * 0.35f;                       // HF damping
            revBuf_[revIdx_] = y + revLp_ * (0.55f + 0.40f * reverb_);
            revIdx_ = (revIdx_ + 1) % revLen_;
            float ab = apBuf_[apIdx_];
            float ao = -rout + ab;                                   // allpass diffusion
            apBuf_[apIdx_] = rout + ab * 0.5f;
            apIdx_ = (apIdx_ + 1) % apLen_;
            y += ao * reverb_ * 0.7f;
        }

        // 6. Output mix
        return y * mix_;
    }

    /// Map the two 0..1 filter knobs onto one-pole coefficients.
    void recomputeFilters() {
        const float hpHz = 20.0f   * std::pow(100.0f, fHp01_);   // 20 Hz .. 2 kHz
        const float lpHz = 200.0f  * std::pow(90.0f,  fLp01_);   // 200 Hz .. 18 kHz
        hpCoef_ = 1.0f - std::exp(-2.0f * 3.14159265f * hpHz / std::max(1.0f, sr_));
        lpCoef_ = 1.0f - std::exp(-2.0f * 3.14159265f * std::min(lpHz, sr_ * 0.45f) / std::max(1.0f, sr_));
    }

    float currentPosition() const { return hasSample() ? (float)(position_ / (double)length_) : 0.0f; }
    bool  warpActive() const { return warpOn_; }
    bool  isPlaying() const { return playing_; }

private:
    // ── WARP engine internals ───────────────────────────────────────────
    // The stretcher reads the sample through these proxies (no copies): a
    // virtual, unwrapped input index is mapped onto the buffer, looping back
    // to the onset in LOOP / HOLD and reading silence past the end in
    // ONE-SHOT, so the stretcher sees one continuous stream.
    inline long long mapIndex(long long v) const {
        if (v < 0) return 0;
        if (v < length_) return v;
        const long long span = (long long)length_ - onsetIndex_;
        if (mode_ != 0 && span > 1) return onsetIndex_ + (v - length_) % span;
        return length_ - 1;
    }
    inline float srcAt(long long v) const {
        if (!data_ || v < 0) return 0.0f;
        if (v < length_) return data_[v];
        const long long span = (long long)length_ - onsetIndex_;
        if (mode_ != 0 && span > 1) return data_[onsetIndex_ + (v - length_) % span];
        return 0.0f;
    }
    struct WarpIn {
        const VocalLayer* L; long long base;
        struct Ch { const VocalLayer* L; long long base; float operator[](int i) const { return L->srcAt(base + i); } };
        Ch operator[](int) const { return Ch{L, base}; }
    };
    struct WarpOut { float* p; float* operator[](int) const { return p; } };

    /// Input samples consumed per output sample (time rate).
    double timeRate() const { return (double)srcSR_ / (double)sr_ / (double)effectiveStretch(); }
    /// Push pitch (PITCH + FOLLOW, independent of length) and formant mode.
    void updateWarpParams() {
        const float semi = pitchSemi_ + (follow_ ? (float)(currentNote_ - 36) : 0.0f);
        const float srcRatio = srcSR_ / sr_;   // a 44.1k sample in a 48k session
        const float tr = std::pow(2.0f, semi / 12.0f) * srcRatio;
        if (tr != lastTranspose_) { stretch_.setTransposeFactor(tr); lastTranspose_ = tr; }
        const int f = formant_ ? 1 : 0;
        if (f != lastFormant_ || srcRatio != lastSrcRatio_) {
            // compensatePitch keeps the formants where they were; the factor
            // undoes the sample-rate mismatch so they land at the right Hz.
            stretch_.setFormantFactor(formant_ ? srcRatio : 1.0f, formant_);
            lastFormant_ = f; lastSrcRatio_ = srcRatio;
        }
    }
    /// (Re)start the stretcher at buffer index `startIdx`. outputSeek pre-rolls
    /// the stretcher so the very next output sample IS the start of the sound
    /// — no onset latency on note-on. No allocation (buffers sized in prepare).
    void warpStart(long long startIdx) {
        updateWarpParams();
        const float rate = (float)timeRate();
        const int seekLen = std::max(1, stretch_.outputSeekLength(rate));
        WarpIn in{this, startIdx};
        stretch_.outputSeek(in, seekLen);
        vpos_ = startIdx + seekLen; inAcc_ = 0.0; chunkPos_ = kChunk;
    }
    /// Render the next kChunk output samples. false = one-shot finished.
    bool warpFill() {
        const float rate = (float)timeRate();
        const int lead = stretch_.outputSeekLength(rate);
        if (mode_ == 0 && vpos_ >= (long long)length_ + lead) return false;
        updateWarpParams();
        inAcc_ += (double)rate * kChunk;
        const int nIn = (int)inAcc_; inAcc_ -= nIn;
        WarpIn in{this, vpos_};
        WarpOut out{chunk_};
        stretch_.process(in, nIn, out, kChunk);
        vpos_ += nIn;
        position_ = (double)mapIndex(vpos_ - lead);   // what is sounding now (UI playhead)
        chunkPos_ = 0;
        return true;
    }
    signalsmith::stretch::SignalsmithStretch<float> stretch_{0x5EED};
    static constexpr int kChunk = 64;
    float     chunk_[kChunk] = {0};
    int       chunkPos_ = kChunk;
    double    inAcc_ = 0.0;
    long long vpos_ = 0;
    bool      warpOn_ = false;
    int       warpMode_ = 0;
    float     stretchLog2_ = 0.0f;
    bool      formant_ = true;
    float     bpm_ = 120.0f, barBeats_ = 4.0f;
    float     lastTranspose_ = -1.0f, lastSrcRatio_ = -1.0f;
    int       lastFormant_ = -1;

    // Front-end filters (see setFilters).
    float fHp01_ = 0.0f, fLp01_ = 1.0f;
    bool  filtOn_ = true;
    float hpCoef_ = 0.01f, lpCoef_ = 0.9f;
    float hpZ_ = 0.0f, lp1Z_ = 0.0f, lp2Z_ = 0.0f;
    void recomputeCoeffs() {
        relCoef_ = std::exp(-1.0f / (sr_ * 0.001f * relMs_));
        recomputeTone();
        recomputeFilters();
        airLpCoef_ = 1.0f - std::exp(-2.0f * kPi * 6000.0f / sr_);
    }
    void recomputeTone() {
        toneLpCoef_ = 1.0f - std::exp(-2.0f * kPi * 1200.0f / sr_);
    }

    float sr_ = 48000;
    const float* data_ = nullptr;
    int   length_ = 0;
    int   onsetIndex_ = 0;     // first loud sample (leading silence trimmed)
    float srcSR_ = 48000;

    bool  enabled_ = true;
    float mix_ = 0.55f;
    float pitchSemi_ = 0.0f;
    bool  follow_ = true;
    int   mode_ = 2;        // hold by default
    float relMs_ = 60.0f;   // fixed click-killer, no UI knob
    float relCoef_ = 0.999f;

    // Vocal FX state
    float drive_   = 0.0f;
    float dist_    = 0.0f;
    float tone_    = 0.5f;
    float air_     = 0.0f;
    float shimmer_ = 0.0f;
    float lpZ_     = 0.0f;
    float airZ_    = 0.0f;
    float toneLpCoef_ = 0.15f;
    float airLpCoef_  = 0.45f;
    static constexpr int kShimmerLen = 4096; // power of two
    float dly_[kShimmerLen] = {0};
    int   dlyW_ = 0;

    // Reverb (damped feedback comb + allpass diffuser).
    float reverb_ = 0.0f;
    static constexpr int kRevMax = 4096;
    static constexpr int kApMax  = 512;
    float revBuf_[kRevMax] = {0};
    float apBuf_[kApMax]   = {0};
    int   revLen_ = 1764, apLen_ = 240, revIdx_ = 0, apIdx_ = 0;
    float revLp_  = 0.0f;

    int    currentNote_ = 36;
    double position_ = 0.0;
    bool   playing_ = false;
    bool   holdReleasing_ = false;
    float  env_ = 0.0f;
};

class Engine {
public:
    void prepare(float sr) {
        sr_ = sr;
        uint32_t seed = 0x12345671u;
        for (auto &v : voices_) {
            v.setSR(sr); v.reset();
            // Give every voice a different seed so drift and noise don't
            // correlate across the polyphonic voices.
            v.setVoiceSeed(seed); seed += 0x9E3779B1u;
        }
        stimme_.prepare(sr);
        updateAll();
    }
    void reset() { for (auto &v : voices_) v.reset(); stimme_.reset(); heldCount_ = 0; }
    /// CC 120 / 123 and transport panic: release everything, rebalance the
    /// held-key count so the vocal layer can't drone on.
    void allNotesOff() {
        for (auto &v : voices_) if (v.isActive()) v.noteOff();
        heldCount_ = 0;
        stimme_.noteOff();
    }

    // Expose the vocal layer so the AU can configure the bundled sample.
    VocalLayer& stimme() { return stimme_; }

    void setOct(int o)               { oct_ = o; updateAll(); }
    void setDetune(float c)          { detune_ = c; updateAll(); }
    void setSub(float s)             { subAmt_ = s; updateAll(); }
    void setFM(float g, float r)     { fmAmt_ = g; fmRatio_ = r; updateAll(); }
    void setNoise(float n)           { noiseAmt_ = n; updateAll(); }
    void setFilter(float c, float q, float ea) { fc_ = c; res_ = q; envAmt_ = ea; updateAll(); }
    void setAmpADSR(float a, float d, float s, float r) { ampA_ = a; ampD_ = d; ampS_ = s; ampR_ = r; updateAll(); }
    void setFltADSR(float a, float d, float s, float r) { fltA_ = a; fltD_ = d; fltS_ = s; fltR_ = r; updateAll(); }
    void setGain(float g)            { gain_ = g; }
    void setGlideMs(float ms)        { glide_ = ms; updateAll(); }
    void setMode(int m)              { mode_ = m; } // 0 = poly, 1 = mono, 2 = legato

    /// Apply a vintage analog CHARACTER preset to every voice in one go.
    /// 0=Clean  1=Moog  2=303  3=SH-101  4=Juno
    void setCharacter(int c) {
        character_ = c;
        for (auto &v : voices_) v.setCharacter(c);
    }
    int character() const { return character_; }

    // ── HARMONIZER (2026-11-20) ─────────────────────────────────────
    // Every played note (on-screen keys, KEYS sequencer, MIDI in) can also
    // sound diatonic harmony voices in KEY/SCALE: a 3rd is major or minor as
    // the scale degree demands. Harmony voices are flagged, sit at -6 dB, may
    // only take idle voices or other harmony voices, and never steal a main
    // voice (mono/legato keeps voice 0 for the played note).
    // mode: 0 = 3rd+5th · 1 = 3rd · 2 = 5th · 3 = 3rd+5th+octave
    // scale: 0 PENTA · 1 MAJOR · 2 MINOR · 3 DORIAN · 4 CHROM (matches KEYS)
    void setHarmonizer(bool on, int mode, bool sub, int key, int scale) {
        harmOn_ = on; harmMode_ = std::max(0, std::min(3, mode)); harmSub_ = sub;
        harmKey_ = ((key % 12) + 12) % 12; harmScale_ = std::max(0, std::min(4, scale));
    }
    /// Harmony note `steps` scale degrees above `n` in the KEY/SCALE. A note
    /// outside the scale keeps its chromatic offset (parallel harmony).
    int harmonyNote(int n, int steps) const {
        // 7-note reference per KEYS scale: pentatonic + chromatic harmonise in major.
        static const int kRef[5][7] = {
            {0, 2, 4, 5, 7, 9, 11}, {0, 2, 4, 5, 7, 9, 11}, {0, 2, 3, 5, 7, 8, 10},
            {0, 2, 3, 5, 7, 9, 10}, {0, 2, 4, 5, 7, 9, 11} };
        const int* sc = kRef[harmScale_];
        const int rel = n - harmKey_;
        const int oct = (rel >= 0) ? rel / 12 : -((11 - rel) / 12);
        const int pc  = rel - oct * 12;
        int d = 0; for (int i = 0; i < 7; ++i) if (sc[i] <= pc) d = i;
        const int off = pc - sc[d];
        const int nd = d + steps;
        return harmKey_ + (oct + nd / 7) * 12 + sc[nd % 7] + off;
    }

    void noteOn(int n, int vel) {
        const float v = vel / 127.0f;
        if (mode_ == 0) {
            const int idx = allocVoice(false, 0);
            startVoice(idx, n, v, false, -1);
        } else {
            // Mono / legato: voice 0 is the played note. A new note replaces
            // the old one, so the old note's harmonies go too.
            releaseHarmonies(-999);
            startVoice(0, n, v, false, -1);
        }
        if (harmOn_) {
            static const int kSteps[4][3] = { {2, 4, -1}, {2, -1, -1}, {4, -1, -1}, {2, 4, 7} };
            const int first = (mode_ == 0) ? 0 : 1;
            for (int k = 0; k < 3; ++k) {
                if (kSteps[harmMode_][k] < 0) break;
                const int h = harmonyNote(n, kSteps[harmMode_][k]);
                if (h < 0 || h > 127) continue;
                const int idx = allocVoice(true, first);
                if (idx >= 0) startVoice(idx, h, v * 0.5f, true, n);     // -6 dB
            }
            if (harmSub_ && n - 12 >= 0) {
                const int idx = allocVoice(true, first);
                if (idx >= 0) startVoice(idx, n - 12, v * 0.5f, true, n);
            }
        }
        // Vocal texture: start on the FIRST held key, then just retune on
        // subsequent keys (no re-attack) so it sustains continuously like the
        // bass — a held drone, not a one-shot per note.
        if (heldCount_ <= 0) { heldCount_ = 0; stimme_.noteOn(n); }
        else                 { stimme_.retune(n); }
        heldCount_++;
    }
    void noteOff(int n) {
        // Release the played note's main voice(s) and ITS harmonies only — a
        // harmony that happens to share the pitch of another held key stays.
        for (int i = 0; i < kMaxVoices; ++i) {
            Voice& vo = voices_[i];
            if (!vo.isActive()) continue;
            if ((!isHarm_[i] && vo.midiNote() == n) || (isHarm_[i] && harmParent_[i] == n)) vo.noteOff();
        }
        if (--heldCount_ <= 0) { heldCount_ = 0; stimme_.noteOff(); }  // release only when ALL keys up
    }

    inline void processFrame(float& outL, float& outR) {
        float bass = 0.0f;
        for (auto &v : voices_) bass += v.process();
        const float voice = stimme_.process();
        float sum = (bass + voice) * gain_;
        const float y = std::tanh(sum * 0.6f);
        outL = outR = y;

        // ── Visualizer probe ─────────────────────────────────────────────
        // Downsample to ~750 Hz so the UI scope is readable. Capture bass &
        // voice independently so the view can draw them as separate streams.
        if (++probeDiv_ >= 64) {
            probeDiv_ = 0;
            const int w = probeW_.load(std::memory_order_relaxed);
            probeBass_[w & kProbeMask] = bass;
            probeVox_[w & kProbeMask] = voice;
            probeW_.store(w + 1, std::memory_order_relaxed);
        }
    }

    // Snapshot the probe buffer into caller-provided arrays. UI uses this
    // ~30 Hz; lock-free, read-tolerant of mid-render writes.
    void readProbe(float *bassOut, float *voxOut, int count) const {
        if (!bassOut || !voxOut || count <= 0) return;
        const int w = probeW_.load(std::memory_order_relaxed);
        const int n = std::min(count, kProbeSize);
        for (int i = 0; i < n; ++i) {
            const int idx = (w - n + i) & kProbeMask;
            bassOut[i] = probeBass_[idx];
            voxOut[i]  = probeVox_[idx];
        }
    }
    static constexpr int probeSize() { return kProbeSize; }

private:
    /// Voice for a new note: an idle one, else the oldest HARMONY voice; only
    /// a main note may finally steal the oldest main voice. -1 = none free.
    int allocVoice(bool forHarmony, int first) {
        for (int i = first; i < kMaxVoices; ++i) if (!voices_[i].isActive()) return i;
        int best = -1; uint32_t oldest = 0xFFFFFFFFu;
        for (int i = first; i < kMaxVoices; ++i)
            if (isHarm_[i] && voiceStamp_[i] < oldest) { oldest = voiceStamp_[i]; best = i; }
        if (best >= 0 || forHarmony) return best;
        for (int i = first; i < kMaxVoices; ++i)
            if (voiceStamp_[i] < oldest) { oldest = voiceStamp_[i]; best = i; }
        return best;
    }
    void startVoice(int idx, int note, float vel, bool harmony, int parent) {
        if (idx < 0 || idx >= kMaxVoices) return;
        voices_[idx].noteOn(note, vel);
        isHarm_[idx] = harmony; harmParent_[idx] = parent;
        voiceStamp_[idx] = ++stampCounter_;
    }
    /// Release harmony voices (all of them when parent == -999).
    void releaseHarmonies(int parent) {
        for (int i = 0; i < kMaxVoices; ++i)
            if (isHarm_[i] && voices_[i].isActive() && (parent == -999 || harmParent_[i] == parent)) voices_[i].noteOff();
    }

    void updateAll() {
        for (auto &v : voices_) {
            v.setOct(oct_); v.setDetuneCents(detune_); v.setSub(subAmt_);
            v.setFM(fmAmt_, fmRatio_); v.setNoise(noiseAmt_);
            v.setFilter(fc_, res_, envAmt_);
            v.setAmpADSR(ampA_, ampD_, ampS_, ampR_);
            v.setFltADSR(fltA_, fltD_, fltS_, fltR_);
            v.setGlideMs(glide_);
        }
    }
    float sr_ = 48000;
    Voice voices_[kMaxVoices];
    VocalLayer stimme_;
    int heldCount_ = 0;     // number of currently-held keys (drives the vocal texture)
    uint32_t voiceStamp_[64] = {};    // trigger order per voice (oldest-voice stealing)
    uint32_t stampCounter_ = 0;
    int   oct_ = 0;
    float detune_ = 6.0f, subAmt_ = 0.7f, fmAmt_ = 0, fmRatio_ = 1.5f, noiseAmt_ = 0;
    float fc_ = 600, res_ = 0.25f, envAmt_ = 0.4f;
    float ampA_ = 0.005f, ampD_ = 0.18f, ampS_ = 0.7f, ampR_ = 0.32f;
    float fltA_ = 0.002f, fltD_ = 0.2f,  fltS_ = 0.5f, fltR_ = 0.4f;
    float gain_ = 1.0f, glide_ = 45.0f;
    int   mode_ = 1;
    int   character_ = kCharClean;
    // Harmonizer state (see setHarmonizer).
    bool  harmOn_ = false, harmSub_ = false;
    int   harmMode_ = 0, harmKey_ = 0, harmScale_ = 0;
    bool  isHarm_[kMaxVoices] = {};
    int   harmParent_[kMaxVoices] = {};

    // Visualizer probe — small power-of-two ring of bass + voice samples.
    static constexpr int kProbeSize = 512;
    static constexpr int kProbeMask = kProbeSize - 1;
    mutable float probeBass_[kProbeSize] = {0};
    mutable float probeVox_[kProbeSize]  = {0};
    mutable std::atomic<int> probeW_{0};
    int   probeDiv_ = 0;
};

}
