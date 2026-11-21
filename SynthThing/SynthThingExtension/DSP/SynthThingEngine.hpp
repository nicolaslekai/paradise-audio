//
//  SynthThingEngine.hpp
//
//  "Synth Thing" — a hybrid arpeggiator / step sequencer / Berlin-mode
//  phrase player driving a 2-oscillator subtractive synth voice.
//
//  Modes:
//   • ARP    — held chord arpeggiated (up/down/up-down/random/as-played)
//   • SEQ    — fixed 16-step pattern, rooted at C, plays continuously
//   • BERLIN — fixed 16-step pattern, transposed by the lowest held note
//
//  Voice:
//   • Saw + square + sub-octave saw, mixed
//   • Ladder-style 4-pole LP with resonance
//   • ADSR amp envelope, ADSR filter envelope
//   • Gentle tanh soft-clip at the output
//
//  Scale snap (post-arp, pre-voice):
//   • Chromatic, Major Pent, Minor Pent, Raga Jog, Chinese Pent, Phrygian, Locrian, Dorian
//
//  Optional drone: sustained tonic + perfect 5th below current root.
//

#pragma once
#include <climits>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <algorithm>
#include <vector>

namespace synthk {

constexpr int kMaxVoices = 8;
constexpr int kMaxChordNotes = 8;
constexpr int kStepCount = 16;
// ── Melodic step-grid (the "Drums machine for keys" rebuild) ─────────
//   kGridRows  : 8 note rows ("8 lines across, one for each note") = one
//                octave of the current scale, row 0 = root rising upward.
//                Mapped to MIDI through the scale so every cell is in-key;
//                a global OCTAVE button + HALF-TONE (♯) switch reach the rest.
//   kPatternSlots : A/B/C/D pattern banks, mirroring the Drums machine.
constexpr int kGridRows     = 16;   // two octaves of scale-degree rows (was 8)
constexpr int kPatternSlots = 4;
constexpr int kMaxChain     = 32;   // max entries in a pattern chain (song mode)
// Grid length is switchable 16 / 32 / 64 steps; the array is sized for the max.
constexpr int kMaxGridSteps = 64;
constexpr float kPi = 3.14159265358979323846f;

inline float clampf(float x, float a, float b) { return std::min(std::max(x, a), b); }

// Mode enum — ARP removed; kept as a synonym for kSeq so any persisted
// state with the old value (0 = ARP) automatically falls into kSeq.
enum ArpMode : int   { kSeq = 0, kBerlin = 1, kDubstep = 2, kArp = 0 };
enum ArpDir : int    { kDirUp = 0, kDirDown = 1, kDirUpDown = 2, kDirRandom = 3, kDirAsPlayed = 4 };
enum ScaleId : int   {
    kScaleChromatic = 0, kScaleMajPent = 1, kScaleMinPent = 2,
    kScaleRagaJog = 3,   kScaleChinaPent = 4,
    kScalePhrygian = 5,  kScaleLocrian = 6, kScaleDorian = 7,
    kScaleCount = 8
};
/// Voice character. Each mode reconfigures osc mix / FM / unison / PWM + ADSR.
///   SYNTH = 2-osc subtractive (default) + subtle FM
///   PLUCK = short FM-ping attack, no sustain
///   BASS  = dark sub-led + 1:1 FM growl
///   BELL  = inharmonic FM bell, long ring
///   SUPER = supersaw — 6 detuned saws, big EDM lead/chord
///   REESE = wide-detuned dual saw + sub + FM = DnB/dubstep bass
///   PWM   = pulse-width-modulated square lead
///   DIGI  = hard high-index digital FM lead
enum VoiceMode : int {
    kVoiceSynth = 0,
    kVoicePluck = 1,
    kVoiceBass  = 2,
    kVoiceBell  = 3,
    kVoiceSuper = 4,
    kVoiceReese = 5,
    kVoicePWM   = 6,
    kVoiceDigi  = 7
};

/// 8 wild MOTION presets — the old note-division rates were scrapped. Each is
/// a 16-step pattern of {semi offset, octave shift, ratchet}. `semi == 127` is
/// a REST. `ratchet` is the number of fast sub-hits on that step (1 = normal,
/// 2-4 = rolls/stutters) — that, plus octave leaps + chromatic colour, is what
/// makes these crazy instead of straight 8ths/16ths.
struct PhraseEntry { int semi; int oct; int rat; };
static constexpr int kRest = 127;
inline const PhraseEntry* phrasePresetById(int id, int &lengthOut) {
    // GALLOP — dotted, galloping ratchets.
    static const PhraseEntry kGallop[16] = {
        {0,0,1},{0,0,2},{kRest,0,1},{7,0,1},{7,0,3},{kRest,0,1},{0,0,1},{12,0,2},
        {kRest,0,1},{5,0,1},{5,0,2},{kRest,0,1},{3,0,1},{10,0,3},{kRest,0,1},{0,0,1}
    };
    // STUTTER — heavy 4-hit ratchet rolls punching against rests.
    static const PhraseEntry kStutter[16] = {
        {0,0,4},{kRest,0,1},{0,0,1},{3,0,4},{kRest,0,1},{7,0,1},{0,1,4},{kRest,0,1},
        {5,0,1},{5,0,4},{kRest,0,1},{3,0,1},{0,0,4},{kRest,0,1},{10,0,1},{0,0,2}
    };
    // ACID — 303-ish: busy, octave jumps, accents.
    static const PhraseEntry kAcid[16] = {
        {0,0,1},{0,1,1},{3,0,1},{0,0,2},{7,0,1},{0,0,1},{10,0,1},{0,1,1},
        {5,0,1},{3,0,2},{0,0,1},{7,0,1},{0,1,1},{3,0,1},{10,0,2},{0,0,1}
    };
    // EUCLID — euclidean 5-over-16, evenly-spread hits + octave colour.
    static const PhraseEntry kEuclid[16] = {
        {0,0,1},{kRest,0,1},{kRest,0,1},{7,0,1},{kRest,0,1},{kRest,0,1},{0,1,1},{kRest,0,1},
        {kRest,0,1},{3,0,2},{kRest,0,1},{kRest,0,1},{10,0,1},{kRest,0,1},{kRest,0,1},{5,0,1}
    };
    // GLITCH — random-feeling ratchet bursts + wide jumps + gaps.
    static const PhraseEntry kGlitch[16] = {
        {0,0,3},{kRest,0,1},{12,0,1},{kRest,0,1},{3,0,4},{0,-1,1},{kRest,0,1},{7,0,2},
        {kRest,0,1},{10,0,4},{0,1,1},{kRest,0,1},{5,0,1},{kRest,0,1},{0,0,3},{kRest,0,1}
    };
    // BOUNCE — bouncing octaves, syncopated.
    static const PhraseEntry kBounce[16] = {
        {0,0,1},{0,1,1},{0,0,1},{kRest,0,1},{7,0,1},{7,1,1},{kRest,0,1},{5,0,1},
        {0,0,1},{0,1,1},{kRest,0,1},{3,0,1},{3,1,1},{kRest,0,1},{10,0,1},{0,0,1}
    };
    // CHAOS — everything at once: dense ratchets, chromatic, octave chaos.
    static const PhraseEntry kChaos[16] = {
        {0,0,2},{1,0,1},{3,0,3},{0,1,1},{6,0,1},{0,0,4},{10,0,1},{7,0,2},
        {0,-1,1},{3,0,1},{12,0,3},{5,0,1},{0,0,1},{8,0,4},{0,1,1},{0,0,2}
    };
    // RAVE — hoover/rave stabs, octave jumps + ratchet hits.
    static const PhraseEntry kRave[16] = {
        {0,0,1},{kRest,0,1},{0,0,2},{0,1,1},{kRest,0,1},{7,0,1},{7,0,2},{kRest,0,1},
        {0,0,1},{12,0,1},{kRest,0,1},{5,0,2},{3,0,1},{kRest,0,1},{10,0,1},{0,0,1}
    };
    switch (id) {
        case 0: lengthOut = 16; return kGallop;
        case 1: lengthOut = 16; return kStutter;
        case 2: lengthOut = 16; return kAcid;
        case 3: lengthOut = 16; return kEuclid;
        case 4: lengthOut = 16; return kGlitch;
        case 5: lengthOut = 16; return kBounce;
        case 6: lengthOut = 16; return kChaos;
        case 7: lengthOut = 16; return kRave;
        default: lengthOut = 0; return nullptr;
    }
}
inline const char* phraseName(int id) {
    switch (id) {
        case 0: return "Gallop";
        case 1: return "Stutter";
        case 2: return "Acid";
        case 3: return "Euclid";
        case 4: return "Glitch";
        case 5: return "Bounce";
        case 6: return "Chaos";
        case 7: return "Rave";
        default: return "—";
    }
}

// Scale intervals (semitones from root, ascending; -1 sentinel ends list).
inline const int* scaleIntervals(int id) {
    static const int chromatic [13] = {0,1,2,3,4,5,6,7,8,9,10,11,-1};
    static const int majPent  [6]  = {0,2,4,7,9,-1};
    static const int minPent  [6]  = {0,3,5,7,10,-1};
    // Raga Jog (S G M P n S' — ascending in some interpretations)
    static const int ragaJog  [7]  = {0,3,4,5,7,10,-1};
    // Hirajōshi / Chinese pent variant (sounds asian, hypnotic)
    static const int chinaPent[6]  = {0,2,3,7,8,-1};
    static const int phrygian [8]  = {0,1,3,5,7,8,10,-1};
    static const int locrian  [8]  = {0,1,3,5,6,8,10,-1};
    static const int dorian   [8]  = {0,2,3,5,7,9,10,-1};
    switch (id) {
        case kScaleChromatic: return chromatic;
        case kScaleMajPent:   return majPent;
        case kScaleMinPent:   return minPent;
        case kScaleRagaJog:   return ragaJog;
        case kScaleChinaPent: return chinaPent;
        case kScalePhrygian:  return phrygian;
        case kScaleLocrian:   return locrian;
        case kScaleDorian:    return dorian;
        default:              return chromatic;
    }
}

// Snap a MIDI note to the nearest in-scale note above or equal to it.
inline int snapToScale(int note, int rootKey, int scaleId) {
    if (scaleId == kScaleChromatic) return note;
    const int* ints = scaleIntervals(scaleId);
    int interval = ((note - rootKey) % 12 + 12) % 12;
    int octave = (note - rootKey - interval) / 12;
    // Find closest interval
    int best = ints[0]; int bestDist = std::abs(interval - ints[0]);
    for (int i = 1; ints[i] >= 0; ++i) {
        int d = std::abs(interval - ints[i]);
        if (d < bestDist) { bestDist = d; best = ints[i]; }
    }
    return rootKey + octave * 12 + best;
}

// PolyBLEP saw oscillator (cheap anti-aliased).
inline float polyBLEPSaw(float &phase, float incr) {
    auto poly = [](float t, float dt) {
        if (t < dt)         { t /= dt; return t + t - t*t - 1.0f; }
        if (t > 1.0f - dt)  { t = (t - 1.0f) / dt; return t*t + t + t + 1.0f; }
        return 0.0f;
    };
    float v = 2.0f * phase - 1.0f - poly(phase, incr);
    phase += incr; if (phase >= 1.0f) phase -= 1.0f;
    return v;
}
inline float polyBLEPSquare(float &phase, float incr) {
    auto poly = [](float t, float dt) {
        if (t < dt)         { t /= dt; return t + t - t*t - 1.0f; }
        if (t > 1.0f - dt)  { t = (t - 1.0f) / dt; return t*t + t + t + 1.0f; }
        return 0.0f;
    };
    float v = phase < 0.5f ? 1.0f : -1.0f;
    v += poly(phase, incr) - poly(std::fmod(phase + 0.5f, 1.0f), incr);
    phase += incr; if (phase >= 1.0f) phase -= 1.0f;
    return v;
}
// Variable-width pulse (for PWM lead). width in (0,1).
inline float polyBLEPPulse(float &phase, float incr, float width) {
    auto poly = [](float t, float dt) {
        if (t < dt)         { t /= dt; return t + t - t*t - 1.0f; }
        if (t > 1.0f - dt)  { t = (t - 1.0f) / dt; return t*t + t + t + 1.0f; }
        return 0.0f;
    };
    float v = phase < width ? 1.0f : -1.0f;
    v += poly(phase, incr);
    float p2 = phase - width; if (p2 < 0.0f) p2 += 1.0f;
    v -= poly(p2, incr);
    phase += incr; if (phase >= 1.0f) phase -= 1.0f;
    return v;
}

// Simple 4-pole ladder filter (Moog-ish, no oversampling — fine for monophonic synth).
class Ladder {
public:
    void prepare(float sr) {
        sr_ = sr;
        // (48k/sr)^0.65: fitted so held notes and the sequencer come out at the
        // same level at 44.1 / 48 / 96 kHz (the squeeze interacts with the
        // stage feedback, so it is not strictly proportional to the period).
        satK_ = std::pow(48000.0f / std::max(8000.0f, sr), 0.65f);
        reset();
    }
    void reset() { for (int i = 0; i < 4; ++i) s_[i] = 0; }
    // Stage coefficient. The old one, f = 2·sin(π·fc/sr), is only a one-pole
    // low-pass while f < 1; once the filter envelope opened the cutoff past
    // sr/6 it went above 1 and each stage BOOSTED the top of the spectrum
    // (+7 dB per stage at Nyquist at the default patch, 48 kHz). That was the
    // ultrasonic hash that sat as loud as the whole audible band at 44.1/48 kHz
    // (true peak 10 dB over the sample peak, chords over 0 dBFS) and was absent
    // at 96 kHz, where the same patch was 4–5 dB "quieter".
    // Now: the coefficient the 48 kHz build used for this cutoff (so nothing
    // changes there while it was a real low-pass), capped just below 1, and
    // converted to the running rate as the same analogue corner frequency.
    void setCutoff(float hz) {
        cutoff_ = clampf(hz, 20.0f, 20000.0f);
        const float f48 = std::min(0.93f, 2.0f * std::sin(kPi * std::min(cutoff_, 12000.0f) / 48000.0f));
        g_ = (sr_ == 48000.0f) ? f48 : 1.0f - std::pow(1.0f - f48, 48000.0f / sr_);
    }
    void setReso(float q)    { reso_ = clampf(q, 0.0f, 4.0f); }
    inline float process(float x) {
        const float f = g_;
        float input = x - reso_ * s_[3];
        // 4-pole cascade with tanh saturation. The outer tanh squeezes each
        // stage's STATE once per sample — a loss that accumulates per sample,
        // so at 96 kHz it acted twice as often per second and the same patch
        // came out about 1 dB quieter. sat() applies that squeeze in proportion
        // to the sample period (exactly tanh at 48 kHz).
        s_[0] = sat(s_[0] + f * (std::tanh(input) - std::tanh(s_[0])));
        s_[1] = sat(s_[1] + f * (std::tanh(s_[0]) - std::tanh(s_[1])));
        s_[2] = sat(s_[2] + f * (std::tanh(s_[1]) - std::tanh(s_[2])));
        s_[3] = sat(s_[3] + f * (std::tanh(s_[2]) - std::tanh(s_[3])));
        return s_[3];
    }
private:
    float sr_ = 48000;
    float cutoff_ = 5000.0f, reso_ = 0.3f;
    float g_ = 0.6f, satK_ = 1.0f;
    float s_[4] = {0,0,0,0};
    inline float sat(float v) const {
        const float t = std::tanh(v);
        return (sr_ == 48000.0f) ? t : v + satK_ * (t - v);
    }
};

class ADSR {
public:
    enum Stage { Idle, Atk, Dec, Sus, Rel };
    void prepare(float sr) { sr_ = sr; reset(); }
    void reset() { stage_ = Idle; out_ = 0; }
    void setADSR(float a, float d, float s, float r) {
        atkCoef_ = std::exp(-1.0f / std::max(0.0001f, a * sr_));
        decCoef_ = std::exp(-1.0f / std::max(0.0001f, d * sr_));
        sustain_ = clampf(s, 0.0f, 1.0f);
        relCoef_ = std::exp(-1.0f / std::max(0.0001f, r * sr_));
    }
    void noteOn()  { stage_ = Atk; }
    void noteOff() { stage_ = Rel; }
    inline float process() {
        switch (stage_) {
            case Atk:
                out_ = 1.0f + (out_ - 1.0f) * atkCoef_;
                if (out_ > 0.999f) { out_ = 1.0f; stage_ = Dec; }
                break;
            case Dec:
                out_ = sustain_ + (out_ - sustain_) * decCoef_;
                if (std::abs(out_ - sustain_) < 0.001f) { out_ = sustain_; stage_ = Sus; }
                break;
            case Sus: break;
            case Rel:
                out_ = out_ * relCoef_;
                if (out_ < 0.001f) { out_ = 0; stage_ = Idle; }
                break;
            case Idle: out_ = 0; break;
        }
        return out_;
    }
    bool isIdle() const { return stage_ == Idle; }
    bool isReleasing() const { return stage_ == Rel; }
private:
    float sr_ = 48000;
    Stage stage_ = Idle;
    float out_ = 0;
    float atkCoef_ = 0.99f, decCoef_ = 0.99f, sustain_ = 0.7f, relCoef_ = 0.99f;
};

// One synth voice: 2 oscillators + sub + filter + ADSR.
class Voice {
public:
    void prepare(float sr) { sr_ = sr; filt_.prepare(sr); ampEnv_.prepare(sr); filtEnv_.prepare(sr); reset(); }
    void reset() { active_ = false; p1_ = 0; p2_ = 0; ps_ = 0; pc_ = 0; pfm_ = 0; vibPhase_ = 0; pwmPhase_ = 0; for (auto &u : uph_) u = 0; ampEnv_.reset(); filtEnv_.reset(); filt_.reset(); }
    void noteOn(int midi, float vel) {
        active_ = true;
        note_ = midi;
        vel_ = vel;
        freq_ = 440.0f * std::pow(2.0f, (midi - 69) / 12.0f);
        ampEnv_.noteOn();
        filtEnv_.noteOn();
    }
    void noteOff() { ampEnv_.noteOff(); filtEnv_.noteOff(); }
    bool isActive() const { return active_ && !ampEnv_.isIdle(); }
    bool isReleasing() const { return ampEnv_.isReleasing(); }
    int  note() const { return note_; }

    void setMix(float saw, float sq, float sub) { mSaw_ = saw; mSq_ = sq; mSub_ = sub; }
    // FM operator: a sine carrier phase-modulated by a sine modulator at
    // `ratio` × pitch with modulation `index`, mixed in at `level`. Inharmonic
    // ratios (e.g. 3.51, 1.41) give metallic bell/mallet tone; this is what was
    // missing — the 6 voices were all the same subtractive engine.
    void setFM(float level, float ratio, float index) { mFM_ = level; fmRatio_ = ratio; fmIndex_ = index; }
    // Vibrato: ±`semis` at `hz` — adds life to reed/sustained voices.
    void setVibrato(float semis, float hz) { vibSemis_ = semis; vibInc_ = 2.0f * kPi * hz / sr_; }
    // Unison saw bank: `n` detuned saws spread ±`cents`, mixed at `level`.
    // n>1 = supersaw (EDM); n=2 wide = reese.
    void setUnison(int n, float cents, float level) { uniN_ = (n < 0) ? 0 : (n > 6 ? 6 : n); uniDet_ = cents; mUni_ = level; }
    // PWM: the square slot becomes a pulse whose width is LFO-modulated.
    void setPWM(float depth, float hz, float level) { pwmDepth_ = depth; pwmInc_ = 2.0f * kPi * hz / sr_; mPWM_ = level; }
    void setFilter(float cutoffHz, float reso, float envAmt) {
        baseCutoff_ = cutoffHz; filt_.setReso(reso); fenvAmt_ = envAmt;
    }
    void setEnvAmp(float a, float d, float s, float r)  { ampEnv_.setADSR(a, d, s, r); }
    void setEnvFlt(float a, float d, float s, float r)  { filtEnv_.setADSR(a, d, s, r); }

    inline float process() {
        if (!active_) return 0.0f;
        // Vibrato — gentle pitch wobble for life/movement.
        float f = freq_;
        if (vibSemis_ > 0.0f) {
            vibPhase_ += vibInc_; if (vibPhase_ > 2.0f * kPi) vibPhase_ -= 2.0f * kPi;
            f *= std::pow(2.0f, (std::sin(vibPhase_) * vibSemis_) / 12.0f);
        }
        const float dt1 = f / sr_;
        const float dt2 = f * 1.005f / sr_;   // tiny detune for body
        const float dts = f * 0.5f / sr_;     // sub octave
        float saw = polyBLEPSaw(p1_, dt1);
        // Square slot → PWM pulse when enabled.
        float sqr;
        if (mPWM_ > 0.0f) {
            pwmPhase_ += pwmInc_; if (pwmPhase_ > 2.0f * kPi) pwmPhase_ -= 2.0f * kPi;
            const float w = clampf(0.5f + pwmDepth_ * std::sin(pwmPhase_), 0.1f, 0.9f);
            sqr = polyBLEPPulse(p2_, dt2, w);
        } else {
            sqr = polyBLEPSquare(p2_, dt2);
        }
        float sub = polyBLEPSaw(ps_, dts);
        // Unison saw bank — supersaw / reese.
        float uni = 0.0f;
        if (mUni_ > 0.0f && uniN_ > 0) {
            for (int u = 0; u < uniN_; ++u) {
                const float spread = (uniN_ > 1) ? ((float)u / (float)(uniN_ - 1) - 0.5f) * 2.0f : 0.0f;
                const float du = (f * std::pow(2.0f, (uniDet_ * spread) / 1200.0f)) / sr_;
                uni += polyBLEPSaw(uph_[u], du);
            }
            uni *= (1.0f / (float)uniN_);
        }
        // FM operator — sine carrier phase-modulated by an inharmonic sine.
        float fmOut = 0.0f;
        if (mFM_ > 0.0f) {
            pc_  += dt1;            if (pc_  >= 1.0f) pc_  -= 1.0f;
            pfm_ += dt1 * fmRatio_; if (pfm_ >= 1.0f) pfm_ -= 1.0f;
            fmOut = std::sin(2.0f * kPi * pc_ + fmIndex_ * std::sin(2.0f * kPi * pfm_));
        }
        float mix = saw * mSaw_ + sqr * mSq_ + sub * mSub_ + fmOut * mFM_ + uni * mUni_;
        // Filter envelope modulates cutoff up to 4 octaves
        const float fenv = filtEnv_.process();
        const float cutoff = clampf(baseCutoff_ * std::pow(2.0f, fenv * fenvAmt_ * 4.0f),
                                     30.0f, 20000.0f);
        filt_.setCutoff(cutoff);
        float y = filt_.process(mix);
        return y * ampEnv_.process() * vel_;
    }
private:
    float sr_ = 48000;
    bool active_ = false;
    int note_ = 60;
    float vel_ = 1.0f, freq_ = 440.0f;
    float p1_ = 0, p2_ = 0, ps_ = 0;
    float mSaw_ = 0.6f, mSq_ = 0.4f, mSub_ = 0.5f;
    float mFM_ = 0.0f, fmRatio_ = 2.0f, fmIndex_ = 0.0f, pc_ = 0.0f, pfm_ = 0.0f;
    float vibSemis_ = 0.0f, vibInc_ = 0.0f, vibPhase_ = 0.0f;
    int   uniN_ = 0; float uniDet_ = 0.0f, mUni_ = 0.0f; float uph_[6] = {0,0,0,0,0,0};
    float mPWM_ = 0.0f, pwmDepth_ = 0.0f, pwmInc_ = 0.0f, pwmPhase_ = 0.0f;
    float baseCutoff_ = 1500.0f, fenvAmt_ = 0.6f;
    Ladder filt_;
    ADSR ampEnv_, filtEnv_;
};

// Compact Freeverb-style reverb (mono): 4 lowpass-feedback combs + 2 allpass.
// Tuned at the classic 44.1k constants; close enough at 48k.
class MiniVerb {
public:
    // The comb / allpass lengths are the classic Freeverb constants IN SAMPLES,
    // i.e. a room that halved in size (and in decay time) at 96 kHz. They are
    // the 48 kHz sizes now and scale with the rate; the damping pole is
    // converted the same way. 48 kHz is unchanged.
    void prepare(float sr) {
        const float k = std::max(0.5f, std::min((float)kMaxScale, sr / 48000.0f));
        rate_ = 48000.0f / std::max(8000.0f, sr);
        l0_ = (int)std::lround(kL0 * k); l1_ = (int)std::lround(kL1 * k);
        l2_ = (int)std::lround(kL2 * k); l3_ = (int)std::lround(kL3 * k);
        la0_ = (int)std::lround(kA0 * k); la1_ = (int)std::lround(kA1 * k);
        setParams(fbSet_, dampSet_);
        reset();
    }
    void reset() {
        for (auto &b : c0_) b = 0; for (auto &b : c1_) b = 0;
        for (auto &b : c2_) b = 0; for (auto &b : c3_) b = 0;
        for (auto &b : a0_) b = 0; for (auto &b : a1_) b = 0;
        i0_ = i1_ = i2_ = i3_ = ia0_ = ia1_ = 0;
        lp0_ = lp1_ = lp2_ = lp3_ = 0;
    }
    // Reverb character — feedback (size/tail) + damping (brightness).
    void setParams(float fb, float damp) {
        if (fb == fbSet_ && damp == dampSet_ && rate_ == dampRate_) return;
        fbSet_ = fb; dampSet_ = damp; dampRate_ = rate_;
        fb_ = fb;
        damp_ = (rate_ == 1.0f) ? damp : std::pow(std::max(1e-6f, damp), rate_);
    }
    inline float process(float x) {
        float out = 0.0f;
        out += comb(c0_, l0_, i0_, lp0_, x);
        out += comb(c1_, l1_, i1_, lp1_, x);
        out += comb(c2_, l2_, i2_, lp2_, x);
        out += comb(c3_, l3_, i3_, lp3_, x);
        out *= 0.25f;
        out = allpass(a0_, la0_, ia0_, out);
        out = allpass(a1_, la1_, ia1_, out);
        return out;
    }
private:
    static constexpr int kL0 = 1116, kL1 = 1188, kL2 = 1277, kL3 = 1356, kA0 = 556, kA1 = 441;
    static constexpr int kMaxScale = 4;                 // up to 192 kHz
    float fb_ = 0.84f, damp_ = 0.2f;
    float fbSet_ = 0.84f, dampSet_ = 0.2f, rate_ = 1.0f, dampRate_ = 1.0f;
    int   l0_ = kL0, l1_ = kL1, l2_ = kL2, l3_ = kL3, la0_ = kA0, la1_ = kA1;
    float c0_[kL0 * kMaxScale] = {0}, c1_[kL1 * kMaxScale] = {0}, c2_[kL2 * kMaxScale] = {0}, c3_[kL3 * kMaxScale] = {0};
    float a0_[kA0 * kMaxScale] = {0}, a1_[kA1 * kMaxScale] = {0};
    int i0_ = 0, i1_ = 0, i2_ = 0, i3_ = 0, ia0_ = 0, ia1_ = 0;
    float lp0_ = 0, lp1_ = 0, lp2_ = 0, lp3_ = 0;
    inline float comb(float* buf, int len, int& idx, float& lp, float x) {
        const float y = buf[idx];
        lp = y * (1.0f - damp_) + lp * damp_;
        buf[idx] = x + lp * fb_;
        if (++idx >= len) idx = 0;
        return y;
    }
    inline float allpass(float* buf, int len, int& idx, float x) {
        const float y = buf[idx];
        const float out = -x + y;
        buf[idx] = x + y * 0.5f;
        if (++idx >= len) idx = 0;
        return out;
    }
};

class SynthThingEngine {
public:
    void prepare(float sr) {
        sr_ = sr;
        for (auto &v : voices_) v.prepare(sr);
        // Dubstep wobble — engine-level resonant LP on the mix bus, only used
        // when mode == kDubstep. Sweep cutoff with a synced LFO for the
        // characteristic "wob wob wob" filter motion.
        dubWobble_.prepare(sr);
        dubWobble_.setReso(3.2f);
        // Per-sample smoothing constants were tuned at 48 kHz; convert them so
        // gates, the chopper and the noise colour are the same at every rate.
        const float rr = 48000.0f / std::max(8000.0f, sr);
        kDubGate_  = 1.0f - std::pow(1.0f - 0.06f, rr);
        kChopGain_ = 1.0f - std::pow(1.0f - 0.04f, rr);
        kNoiseLp_  = 1.0f - std::pow(1.0f - 0.35f, rr);
        noiseHold_ = (sr >= 160000.0f) ? 4 : (sr >= 80000.0f ? 2 : 1);   // hiss keeps its 48 kHz level per Hz
        kNoiseLp_  = 1.0f - std::pow(1.0f - 0.35f, rr * (float)noiseHold_);
        dlyLimit_  = std::min(kDlyMax - 1, (int)sr);                     // 1 s, as at 48 kHz
        verb_.prepare(sr);
        // First prepare only: a re-allocate (sample-rate / buffer change, or a
        // host that restores state before allocating) must not wipe the
        // user's four grids and repaint the starter motifs.
        if (!prepared_) {
            defaultEnvs();
            defaultSeq();
            defaultGrid();
            clearChord();
            prepared_ = true;
        }
    }
    void reset() {
        for (auto &v : voices_) v.reset();
        sampleAccum_ = 0;
        stepIdx_ = 0;
        directionUp_ = true;
        lastArpNote_ = -1;
        dubWobble_.reset(); dubGate_ = 1.0f; dubHeldSteps_ = 0;
        dubLfoPhase_ = 0;
        for (int i = 0; i < kDlyMax; ++i) { dlyL_[i] = 0; dlyR_[i] = 0; }
        dlyW_ = 0; verb_.reset(); chopPhase_ = 0; chopGain_ = 1.0f;
    }

    // ---- Parameters ----
    void setBPM(float bpm)          { bpm_ = std::max(20.0f, bpm); }
    // Host beat position. Called once per render block, AFTER setBPM/setPlaying.
    // Locks stepIdx_ to Logic's clock. Old behaviour only re-synced on a
    // backward loop, so hitting play from an arbitrary bar left the sequencer
    // out of phase. Now we hard-snap on (re)start OR any transport
    // discontinuity (loop, or dropping the playhead at a new bar), detected by
    // comparing Logic's actual beat advance against the advance expected from
    // elapsed samples. During continuous playback the two agree, so we leave
    // the free-running step alone and never stutter.
    void setHostBeatPosition(double beatPos) {
        const float bps = stepBeats(rate_);
        const int wrap = gridMode_ ? gridSteps_ : kStepCount;
        int target = (int)std::floor(beatPos / bps);
        target %= wrap;
        if (target < 0) target += wrap;

        const double ranBpm = lastBlockBpm_ > 0.0 ? lastBlockBpm_ : (double)bpm_;   // tempo the samples RAN at
        const double expected = (double)samplesSinceHostBeat_ / (double)sr_ * ranBpm / 60.0;
        const double actual   = beatPos - lastHostBeat_;
        const bool jumped = std::fabs(actual - expected) > 0.03;  // < a 64th note

        if (needsHostResync_ || jumped) {
            stepIdx_ = target;
            sampleAccum_ = 0;
            lastAbsStep_ = LLONG_MIN;   // refire at the new position on the next frame
            releaseSeqVoices();
            // Song mode follows Logic's absolute position (which loop of the
            // chain this bar sits in), so a jump lands in the right pattern.
            if (chainLen_ > 0 && gridMode_) {
                const long long absStep = (long long)std::floor(beatPos / bps);
                const long long loops = (long long)std::floor((double)absStep / (double)wrap);
                chainPos_ = (int)(((loops % chainLen_) + chainLen_) % chainLen_);
                gridCycleStep_ = (int)(((absStep % wrap) + wrap) % wrap);
                if (!isolate_) setPlaySlot(chain_[chainPos_]);
            }
            needsHostResync_ = false;
        }
        lastBlockBpm_ = (double)bpm_;
        hostLocked_ = true;
        samplesSinceHostBeat_ = 0;
        lastHostBeat_ = beatPos;
    }
    void setPlaying(bool p) {
        if (p && !playing_) needsHostResync_ = true;
        if (playing_ == p) return;
        playing_ = p;
        for (int i = 0; i < kMaxVoices; ++i) liveNote_[i] = -1;   // sequencer owns the voices from here
        if (!p) {
            for (auto &v : voices_) if (v.isActive()) v.noteOff();
            droneV1_.noteOff(); droneV2_.noteOff();
            sampleAccum_ = 0;
        }
    }
    bool isPlaying() const          { return playing_; }
    void setRate(int rate)          { rate_ = clampr(rate, 1, 7); }  // 1=1/4 ... 6=1/16T, 7=1/64
    void setMode(int m)             { mode_ = clampr(m, (int)kSeq, (int)kDubstep); }
    // DUBSTEP wobble pattern editor — 8 steps, each step picks a wobble
    // division (0=1/2, 1=1/4, 2=1/8, 3=1/16, 4=1/8T, 5=STOP,
    // 6=1/16 CHOP, 7=1/32 CHOP). The CHOP divisions are gate-style: the
    // filter stays wide open and a hard tempo-synced amplitude gate stutters
    // the bus at 16ths / 32nds instead of sweeping the cutoff.
    static constexpr int kDubPatternLen    = 8;
    static constexpr int kDubDivisionCount = 8;
    static constexpr int kDubChop16 = 6, kDubChop32 = 7;
    void setDubstepStep(int step, int division) {
        if (step < 0 || step >= kDubPatternLen) return;
        dubPattern_[step] = clampr(division, 0, kDubDivisionCount - 1);
    }
    int  dubstepStep(int step) const {
        return (step >= 0 && step < kDubPatternLen) ? dubPattern_[step] : 0;
    }
    int  dubstepPatternLen() const { return kDubPatternLen; }
    static const char* dubstepDivisionName(int d) {
        switch (d) {
            case 0: return "1/2";
            case 1: return "1/4";
            case 2: return "1/8";
            case 3: return "1/16";
            case 4: return "1/8T";
            case 5: return "STOP";
            case 6: return "1/16 CHOP";
            case 7: return "1/32 CHOP";
            default: return "1/4";
        }
    }
    // Pattern step the wobble sequencer is currently on (0..7) — UI playhead.
    int dubstepCurrentStep() const {
        const int s = (int)std::floor(dubBeatPos_) % kDubPatternLen;
        return s < 0 ? s + kDubPatternLen : s;
    }
    // DUBSTEP "long slowed-down notes": how long a fired grid column rings.
    //   0 = 1× (normal: gated at the next step)
    //   1 = 2× (holds for two steps)      2 = 4× (holds for four steps)
    //   3 = HOLD (sustains until the next column that has a note fires)
    void setDubNoteLen(int n)       { dubNoteLen_ = clampr(n, 0, 3); }
    int  dubNoteLen() const         { return dubNoteLen_; }
    static const char* dubNoteLenName(int n) {
        switch (n) { case 1: return "2×"; case 2: return "4×"; case 3: return "HOLD"; default: return "1×"; }
    }
    void setDirection(int d)        { dir_ = clampr(d, (int)kDirUp, (int)kDirAsPlayed); }
    void setOctaveRange(int oct)    { octRange_ = clampr(oct, 1, 4); }
    void setGate(float g)           { gate_ = clampf(g, 0.05f, 1.0f); }
    void setSwing(float s)          { swing_ = clampf(s, 0.0f, 0.5f); }
    void setScale(int id)           { scale_ = clampr(id, 0, kScaleCount - 1); }
    void setRootKey(int midi)       { rootKey_ = ((midi % 12) + 12) % 12; }
    void setDroneOn(bool on)        { droneOn_ = on; }
    // Extended drone controls — user wanted to build on the feature.
    //   level    : 0..1.5 — drone mix relative to arp voices
    //   octave   : -3..+1 — octave shift applied to the drone root
    //   interval : 0 = root only, 1 = +5th, 2 = +5th + octave up,
    //              3 = octave double (root + root+12)
    void setDroneLevel(float lv)    { droneLevel_ = clampf(lv, 0.0f, 1.5f); }
    void setDroneOctave(int oct)    { droneOctave_ = clampr(oct, -3, 1); }
    void setDroneInterval(int i)    { droneInterval_ = clampr(i, 0, 3); }
    int  droneOctave() const        { return droneOctave_; }
    int  droneInterval() const      { return droneInterval_; }
    float droneLevel() const        { return droneLevel_; }
    // Output level — multiplies the whole engine mix. Range 0..2 so the user
    // can boost as well as cut. Was previously stuck at 1.0 (LVL knob did
    // nothing — fixed now).
    void setLevel(float lv)         { outputLevel_ = clampf(lv, 0.0f, 2.0f); }
    float level() const             { return outputLevel_; }

    // ── Universal output FX — work for every voice character ─────────
    //   MOD   : chorus/flanger via LFO-modulated delay line (0..1 amount,
    //           0 = off, 1 = lush flange)
    //   DIRT  : pre-output tanh drive (0..1 → unity..hard clip)
    //   NOISE : analog noise floor (0..1)
    void setMod(float v)   { modAmt_ = clampf(v, 0.0f, 1.0f); }
    void setDirt(float v)  { dirtAmt_ = clampf(v, 0.0f, 1.0f); }
    void setNoise(float v) { noiseAmt_ = clampf(v, 0.0f, 1.0f); }
    float mod() const   { return modAmt_; }
    float dirt() const  { return dirtAmt_; }
    float noise() const { return noiseAmt_; }
    //   DELAY  : tempo-synced 1/8 feedback delay (0..1 wet)
    //   REVERB : compact Freeverb send (0..1 wet)
    //   CHOP   : tempo-synced 1/16 amplitude gate (0..1 depth)
    void setDelay(float v)  { delayAmt_  = clampf(v, 0.0f, 1.0f); }
    void setReverb(float v) { reverbAmt_ = clampf(v, 0.0f, 1.0f); }
    void setChop(float v)   { chopAmt_   = clampf(v, 0.0f, 1.0f); }
    float delayFx() const  { return delayAmt_; }
    float reverbFx() const { return reverbAmt_; }
    float chop() const     { return chopAmt_; }
    // FX type/mode selectors (the little "settings" above each knob).
    void setDelayType(int t)  { delayType_  = clampr(t, 0, 5); }
    void setReverbType(int t) { reverbType_ = clampr(t, 0, 3); }
    void setChopType(int t)   { chopType_   = clampr(t, 0, 9); }
    int  delayType() const  { return delayType_; }
    int  reverbType() const { return reverbType_; }
    int  chopType() const   { return chopType_; }

    void setVoiceMode(int m) {
        voiceMode_ = clampr(m, 0, 7);
        applyVoiceMode();
    }
    int  voiceMode() const { return voiceMode_; }
    /// Load one of the 5 hard-coded phrase presets into the step grid.
    /// All steps become ON; semi/oct copied from the preset.
    void loadPhrase(int phraseId) {
        int len = 0;
        const PhraseEntry *p = phrasePresetById(phraseId, len);
        if (!p || len <= 0) return;
        for (int i = 0; i < kStepCount; ++i) {
            const int j = i % len;
            const bool rest = (p[j].semi == kRest);
            seq_[i].on      = !rest;              // semi==127 → rest (step off)
            seq_[i].semi    = rest ? 0 : p[j].semi;
            seq_[i].oct     = p[j].oct;
            seq_[i].ratchet = (p[j].rat < 1) ? 1 : p[j].rat;
        }
    }
    // The setters below capture user values, then re-apply through
    // applyVoiceMode() so the PLUCK / MALLET overrides take precedence when
    // those modes are active.
    void setMix(float saw, float sq, float sub) {
        userMixSaw_ = saw; userMixSq_ = sq; userMixSub_ = sub;
        applyVoiceMode();
    }
    void setFilter(float cutHz, float reso, float envAmt) {
        baseCutoff_ = cutHz; reso_ = reso; fenvAmt_ = envAmt;
        userCutoff_ = cutHz; userReso_ = reso; userFenv_ = envAmt;
        applyVoiceMode();
    }
    void setEnvAmp(float a, float d, float s, float r)  {
        userAmpA_ = a; userAmpD_ = d; userAmpS_ = s; userAmpR_ = r;
        applyVoiceMode();
    }
    void setEnvFlt(float a, float d, float s, float r)  {
        userFltA_ = a; userFltD_ = d; userFltS_ = s; userFltR_ = r;
        applyVoiceMode();
    }

    // Step grid editing (SEQ + BERLIN modes use this)
    void setStep(int i, bool on, int semiOffset = 0, int oct = 0) {
        if (i < 0 || i >= kStepCount) return;
        seq_[i].on = on; seq_[i].semi = semiOffset; seq_[i].oct = oct;
    }
    bool stepOn(int i) const { return (i >= 0 && i < kStepCount) ? seq_[i].on : false; }
    int  stepSemi(int i) const { return (i >= 0 && i < kStepCount) ? seq_[i].semi : 0; }
    int  stepOct(int i) const { return (i >= 0 && i < kStepCount) ? seq_[i].oct : 0; }

    // ─────────────────────────────────────────────────────────────────
    //  MELODIC STEP-GRID  ("Drums machine for keys")
    //  An 8-row × 16-step polyphonic grid per pattern slot. A lit cell at
    //  (row,step) fires that row's in-scale note when the playhead hits the
    //  column. This is the primary sequencer when gridMode_ is on (default).
    // ─────────────────────────────────────────────────────────────────
    void setGridMode(bool on)        { gridMode_ = on; }
    bool gridMode() const            { return gridMode_; }
    int  numGridRows() const         { return kGridRows; }

    // Step count — 16 / 32 / 64. Snaps the playhead in range.
    void setGridSteps(int n) {
        gridSteps_ = (n >= 64) ? 64 : (n >= 32 ? 32 : 16);
        if (stepIdx_ >= gridSteps_) stepIdx_ = 0;
    }
    int  gridSteps() const           { return gridSteps_; }

    // Cell edit / query on the EDIT slot (the PATTERN button the user picked).
    void setCell(int row, int step, bool on) {
        if (row < 0 || row >= kGridRows || step < 0 || step >= kMaxGridSteps) return;
        grid_[editSlot_][row][step] = on;
        if (!on) gridLen_[editSlot_][row][step] = 0;
    }
    bool cell(int row, int step) const {
        if (row < 0 || row >= kGridRows || step < 0 || step >= kMaxGridSteps) return false;
        return grid_[editSlot_][row][step];
    }
    // Note length (steps) of the note STARTING at row/step on the edit slot.
    int  cellLength(int row, int step) const { return cellLengthIn(editSlot_, row, step); }
    void setCellLength(int row, int step, int len) { setCellLengthIn(editSlot_, row, step, len); }
    int  cellLengthIn(int slot, int row, int step) const {
        if (slot < 0 || slot >= kPatternSlots || row < 0 || row >= kGridRows || step < 0 || step >= kMaxGridSteps) return 1;
        return gridLen_[slot][row][step] < 1 ? 1 : gridLen_[slot][row][step];
    }
    void setCellLengthIn(int slot, int row, int step, int len) {
        if (slot < 0 || slot >= kPatternSlots || row < 0 || row >= kGridRows || step < 0 || step >= kMaxGridSteps) return;
        gridLen_[slot][row][step] = (uint8_t)clampr(len, 1, kMaxGridSteps);
    }
    void clearGrid() {
        for (int r = 0; r < kGridRows; ++r)
            for (int s = 0; s < kMaxGridSteps; ++s) { grid_[editSlot_][r][s] = false; gridLen_[editSlot_][r][s] = 0; }
        for (int s = 0; s < kMaxGridSteps; ++s) { colSwing_[editSlot_][s] = 0; recRoot_[editSlot_][s] = -1; }
    }

    // Slot-addressed variants for state save / load: they never touch
    // the edit or play slot, which the render thread is reading (flipping it
    // during a save fired cells from the wrong pattern).
    bool cellIn(int slot, int row, int step) const {
        if (slot < 0 || slot >= kPatternSlots || row < 0 || row >= kGridRows || step < 0 || step >= kMaxGridSteps) return false;
        return grid_[slot][row][step];
    }
    void setCellIn(int slot, int row, int step, bool on) {
        if (slot < 0 || slot >= kPatternSlots || row < 0 || row >= kGridRows || step < 0 || step >= kMaxGridSteps) return;
        grid_[slot][row][step] = on;
        if (!on) gridLen_[slot][row][step] = 0;
    }
    int  colSwingIn(int slot, int step) const {
        if (slot < 0 || slot >= kPatternSlots || step < 0 || step >= kMaxGridSteps) return 0;
        return colSwing_[slot][step];
    }
    void setColSwingIn(int slot, int step, int lvl) {
        if (slot < 0 || slot >= kPatternSlots || step < 0 || step >= kMaxGridSteps) return;
        colSwing_[slot][step] = (int8_t)clampr(lvl, 0, 4);
    }
    int  recRootIn(int slot, int step) const {
        if (slot < 0 || slot >= kPatternSlots || step < 0 || step >= kMaxGridSteps) return -1;
        return recRoot_[slot][step];
    }
    void setRecRootIn(int slot, int step, int midi) {
        if (slot < 0 || slot >= kPatternSlots || step < 0 || step >= kMaxGridSteps) return;
        recRoot_[slot][step] = (int16_t)((midi < 0 || midi > 127) ? -1 : midi);
    }

    // Pattern slots A/B/C/D. Two cursors:
    //   editSlot_ — the PATTERN button the user selected; every UI read/write
    //               (cells, swing dots, clear, copy) goes here and it never
    //               moves on its own, so you can edit B while the song plays.
    //   playSlot_ — what the render thread fires. With no chain it simply
    //               follows the edit slot (select A → hear A). With a LINK
    //               chain it is driven by the chain and leaves editSlot_ alone.
    void setSlot(int slot) {
        editSlot_ = clampr(slot, 0, kPatternSlots - 1);
        if (!chainActive()) playSlot_ = editSlot_;
    }
    int  currentSlot() const         { return editSlot_; }
    int  playSlot() const            { return playSlot_; }

    // Copy the EDIT pattern (cells + per-column swing + recorded roots) into
    // another slot — the UI's shift-click-a-slot "save current pattern to
    // A/B/C/D" action. Source = edit slot; dst clamped to A..D.
    void copyCurrentPatternToSlot(int dst) {
        dst = clampr(dst, 0, kPatternSlots - 1);
        if (dst == editSlot_) return;
        for (int r = 0; r < kGridRows; ++r)
            for (int s = 0; s < kMaxGridSteps; ++s) {
                grid_[dst][r][s] = grid_[editSlot_][r][s];
                gridLen_[dst][r][s] = gridLen_[editSlot_][r][s];
            }
        for (int s = 0; s < kMaxGridSteps; ++s) {
            colSwing_[dst][s] = colSwing_[editSlot_][s];
            recRoot_[dst][s]  = recRoot_[editSlot_][s];
        }
    }

    // ── Pattern chaining (song mode) — mirrors the Drums machine. A chain is
    // an ordered list of slots (e.g. A→B→A→C); the grid sequencer advances to
    // the next chain entry each time the grid loop wraps. Empty = off.
    void setChain(const int* slots, int n) {
        if (n < 0) n = 0; if (n > kMaxChain) n = kMaxChain;
        chainLen_ = n;
        for (int i = 0; i < n; ++i) {
            int s = slots[i]; if (s < 0) s = 0; if (s >= kPatternSlots) s = kPatternSlots - 1;
            chain_[i] = s;
        }
        if (chainPos_ >= chainLen_) chainPos_ = 0;
        if (chainLen_ > 0 && !playing_) { chainPos_ = 0; gridCycleStep_ = 0; if (!isolate_) setPlaySlot(chain_[0]); }
        if (!chainActive()) playSlot_ = editSlot_;
    }
    // Chain off → the pattern you are looking at is the one that plays again.
    void clearChain()                { chainLen_ = 0; chainPos_ = 0; playSlot_ = editSlot_; }
    int  chainLength() const         { return chainLen_; }
    int  chainSlotAt(int i) const    { return (i >= 0 && i < chainLen_) ? chain_[i] : -1; }
    int  chainPosition() const       { return chainPos_; }

    // ISOLATE (mirrors Engine 909) — the pattern on the grid (edit slot) loops
    // on its own; the LINK chain stays stored and takes over again when ISOLATE
    // is switched off (host-locked: at the entry Logic's bar count implies, at
    // the next loop wrap; stopped: straight back to the current chain entry).
    void setIsolate(bool on) {
        if (on == isolate_) return;
        isolate_ = on;
        if (on || chainLen_ == 0) playSlot_ = editSlot_;
        else if (!playing_)       setPlaySlot(chain_[chainPos_ < chainLen_ ? chainPos_ : 0]);
    }
    bool isolate() const             { return isolate_; }
    bool chainActive() const         { return chainLen_ > 0 && !isolate_; }

    // Row copy / swap for the per-row drag crosshair (mirrors the 909's
    // copyRow / swapRows): the note starts + their lengths of one note row on
    // the EDIT slot. Columns (swing, recorded roots) are shared by all rows and
    // stay. Called from the main thread like every other grid edit.
    void copyGridRow(int src, int dst) {
        if (src < 0 || src >= kGridRows || dst < 0 || dst >= kGridRows || src == dst) return;
        const int sl = editSlot_;
        for (int s = 0; s < kMaxGridSteps; ++s) { grid_[sl][dst][s] = grid_[sl][src][s]; gridLen_[sl][dst][s] = gridLen_[sl][src][s]; }
    }
    void swapGridRows(int a, int b) {
        if (a < 0 || a >= kGridRows || b < 0 || b >= kGridRows || a == b) return;
        const int sl = editSlot_;
        for (int s = 0; s < kMaxGridSteps; ++s) { std::swap(grid_[sl][a][s], grid_[sl][b][s]); std::swap(gridLen_[sl][a][s], gridLen_[sl][b][s]); }
    }

    // Global pitch placement of the 8-row window.
    void setGridOctave(int oct)      { gridOctave_ = clampr(oct, -2, 2); }
    int  gridOctave() const          { return gridOctave_; }
    void setHalfTone(bool on)        { halfTone_ = on; }
    bool halfTone() const            { return halfTone_; }

    // Per-column swing (0..4 ticks, mirrors the Drums per-cell swing UI).
    void setColSwing(int step, int level) {
        if (step < 0 || step >= kMaxGridSteps) return;
        colSwing_[editSlot_][step] = (uint8_t)clampr(level, 0, 4);
    }
    int  colSwing(int step) const {
        return (step >= 0 && step < kMaxGridSteps) ? colSwing_[editSlot_][step] : 0;
    }

    // MIDI note for a grid row given a base-root MIDI note (row 0 = root).
    // Wraps octaves through the scale so any scale maps onto the 8 rows.
    int gridRowMidiBase(int row, int baseRootMidi) const {
        const int* ints = scaleIntervals(scale_);
        int nDeg = 0; while (ints[nDeg] >= 0) nDeg++;
        if (nDeg <= 0) nDeg = 12;
        const int oct = row / nDeg;
        const int idx = row % nDeg;
        return baseRootMidi + gridOctave_ * 12 + oct * 12 + ints[idx] + (halfTone_ ? 1 : 0);
    }
    // UI/label root = the panel ROOT setting (C4-based).
    int gridRowMidi(int row) const { return gridRowMidiBase(row, 60 + rootKey_); }

    // ── Live root via MIDI keyboard ─────────────────────────────────
    //   • Hold a key → the whole grid transposes to that note (lowest held).
    //   • Arm REC → the held root is captured per-step into the slot's root
    //     track; playback then follows it hands-free. Steps with no recorded
    //     root fall back to the panel ROOT.
    void setRecordArmed(bool on) { recordArmed_ = on; }
    bool recordArmed() const     { return recordArmed_; }
    // Effective root MIDI for a given step (records when armed).
    int effectiveRootMidi(int step) {
        if (liveRootMidi_ >= 0) {
            if (recordArmed_ && playing_ && step >= 0 && step < kMaxGridSteps)
                recRoot_[playSlot_][step] = (int16_t)liveRootMidi_;
            return liveRootMidi_;
        }
        if (step >= 0 && step < kMaxGridSteps) {
            const int rec = recRoot_[playSlot_][step];
            if (rec >= 0) return rec;
        }
        return 60 + rootKey_;
    }

    // ── Live keys ────────────────────────────────────────────────────
    // The keyboard plays the synth directly whenever the grid sequencer is
    // not sounding: Logic's transport stopped, or the playing pattern is
    // empty. While the sequencer runs a pattern the keys steer its root
    // instead (effectiveRootMidi). Before this, a stopped Logic swallowed
    // every key press — "SynthThing / StringThing don't receive MIDI".
    bool gridSlotHasNotes() const {
        for (int r = 0; r < kGridRows; ++r)
            for (int st = 0; st < gridSteps_ && st < kMaxGridSteps; ++st)
                if (grid_[playSlot_][r][st]) return true;
        return false;
    }
    bool liveKeysPlayDirect() const {
        if (!playing_) return true;
        return gridMode_ && !gridSlotHasNotes();
    }
    bool isLiveVoice(int i) const { return liveNote_[i] >= 0 && voices_[i].note() == liveNote_[i]; }
    // Sequencer-side release: every sounding voice except the ones a held key owns.
    void releaseSeqVoices() {
        for (int i = 0; i < kMaxVoices; ++i) {
            if (voices_[i].isActive() && !voices_[i].isReleasing() && !isLiveVoice(i)) voices_[i].noteOff();
            if (!isLiveVoice(i)) seqHold_[i] = 0;
        }
    }
    // Grid step boundary: long notes keep ringing until their length runs out.
    // A one-step note (hold 1) is released here exactly like before.
    void tickGridHolds() {
        for (int i = 0; i < kMaxVoices; ++i) {
            if (isLiveVoice(i)) { seqHold_[i] = 0; continue; }
            if (!voices_[i].isActive() || voices_[i].isReleasing()) { seqHold_[i] = 0; continue; }
            if (seqHold_[i] > 1) { --seqHold_[i]; continue; }
            voices_[i].noteOff(); seqHold_[i] = 0;
        }
    }
    // GATE < 100 %: only notes in their LAST step are cut early.
    void releaseEndingVoices() {
        for (int i = 0; i < kMaxVoices; ++i) {
            if (isLiveVoice(i) || seqHold_[i] > 1) continue;
            if (voices_[i].isActive() && !voices_[i].isReleasing()) voices_[i].noteOff();
            seqHold_[i] = 0;
        }
    }
    void armEndingGate() {
        gateCountdown_ = 0;
        if (gate_ >= 0.995f) return;
        bool ending = false;
        for (int i = 0; i < kMaxVoices && !ending; ++i)
            ending = !isLiveVoice(i) && seqHold_[i] == 1 && voices_[i].isActive() && !voices_[i].isReleasing();
        if (!ending) return;
        const float samplesPerStep = sr_ * 60.0f * stepBeats(rate_) / bpm_;
        gateCountdown_ = std::max(1, (int)(gate_ * samplesPerStep));
    }

    // ---- MIDI ----
    void noteOn(int n, int vel) {
        if (chordCount_ >= kMaxChordNotes) return;
        // Don't add duplicates
        for (int i = 0; i < chordCount_; ++i) if (chord_[i] == n) return;
        chord_[chordCount_++] = n;
        std::sort(chord_, chord_ + chordCount_);
        lowestHeld_ = chord_[0];
        liveRootMidi_ = lowestHeld_;     // play the root live from the keyboard
        if (liveKeysPlayDirect()) {
            int idx = -1;
            for (int i = 0; i < kMaxVoices && idx < 0; ++i) if (!voices_[i].isActive()) idx = i;
            for (int i = 0; i < kMaxVoices && idx < 0; ++i) if (voices_[i].isReleasing()) idx = i;
            if (idx < 0) idx = (int)((liveSteal_++) % (unsigned)kMaxVoices);
            voices_[idx].noteOn(n, std::max(0.05f, (float)vel / 127.0f));
            liveNote_[idx] = n;
            seqHold_[idx] = 0;
            const int w = noteRingW_.load(std::memory_order_relaxed);
            noteRing_[w & (kNoteRing - 1)] = { n, sampleCount_ };
            noteRingW_.store(w + 1, std::memory_order_relaxed);
        }
    }
    void noteOff(int n) {
        for (int i = 0; i < kMaxVoices; ++i)
            if (liveNote_[i] == n) {
                if (voices_[i].isActive() && voices_[i].note() == n) voices_[i].noteOff();
                liveNote_[i] = -1;
            }
        for (int i = 0; i < chordCount_; ++i) {
            if (chord_[i] == n) {
                for (int j = i; j < chordCount_ - 1; ++j) chord_[j] = chord_[j+1];
                chordCount_--; break;
            }
        }
        lowestHeld_ = chordCount_ > 0 ? chord_[0] : -1;
        liveRootMidi_ = lowestHeld_;     // -1 when all keys released → back to recorded/panel root
        // (No voice cut when the last key is released: the keys only steer the
        // live root; ARP mode is gone and its `kArp` alias equals kSeq, so the
        // old guard chopped every sequencer note on key-up.)
    }
    int  chordCount() const { return chordCount_; }
    int  currentStep() const { return lastFiredStep_ >= 0 ? lastFiredStep_ : stepIdx_; }   // the SOUNDING column (stepIdx_ is already the next one)

    // ── Comet-field probe ────────────────────────────────────────────
    // The UI draws every recent fired note as a comet drifting from the
    // right edge to the left. Engine writes (midi note, sample age) into a
    // ring buffer; UI reads it lock-free at ~30 Hz.
    static constexpr int kNoteRing = 64;
    struct NoteHit { int midi; int64_t bornSample; };
    void readNoteHistory(int *midiOut, double *ageSecondsOut, int *countOut, int cap) const {
        const int w = noteRingW_.load(std::memory_order_relaxed);
        const int avail = std::min(cap, kNoteRing);
        int produced = 0;
        for (int i = 0; i < avail; ++i) {
            const int idx = (w - 1 - i) & (kNoteRing - 1);
            const NoteHit &h = noteRing_[idx];
            if (h.midi < 0) break;
            const double ageSec = (double)(sampleCount_ - h.bornSample) / (double)sr_;
            if (ageSec > 6.0) break;  // anything older than 6s isn't drawn
            midiOut[produced]      = h.midi;
            ageSecondsOut[produced] = ageSec;
            produced++;
        }
        *countOut = produced;
    }
    int chordNote(int i) const { return (i >= 0 && i < chordCount_) ? chord_[i] : -1; }
    // Smoothed master amplitude (0..1) for the background pulse.
    float amplitudeEnv() const { return ampProbe_; }

    // ---- Render ----
    inline void processFrame(float& outL, float& outR) {
        // Count elapsed frames so setHostBeatPosition can tell continuous
        // playback from a transport jump (see that function).
        ++samplesSinceHostBeat_;
        // Host-locked musical time for this frame (beats): the last beat
        // position Logic handed us plus the samples elapsed since. The grid
        // clock, the WOB pattern and the CHOP all read this instead of
        // free-running, so nothing drifts against the project.
        if (hostLocked_)
            hostBeatNow_ = lastHostBeat_ + (double)(samplesSinceHostBeat_ - 1) / (double)sr_ * (double)bpm_ / 60.0;
        // ── GRID clock — even step length; per-column swing delays each
        // column's fire by a fraction of a step (the "4 lateness dots").
        if (playing_ && gridMode_) {
            const float beatsPerStep = stepBeats(rate_);
            const float samplesPerStep = sr_ * 60.0f * beatsPerStep / bpm_;
            // GATE: release the column after its fraction of the step.
            if (gateCountdown_ > 0 && --gateCountdown_ == 0)
                releaseEndingVoices();
            // Fire a column that's been waiting out its swing delay.
            if (gridPendingFire_) {
                gridFireDelay_ -= 1.0f;
                if (gridFireDelay_ <= 0.0f) {
                    fireGridColumn(gridPendingStep_);
                    handleDrone();
                    gridPendingFire_ = false;
                }
            }
            // Step boundary: host-locked (absolute step from Logic's beat
            // position, sample-accurate, no drift) or free-running fallback.
            bool boundary = false;
            if (hostLocked_) {
                const long long absStep = (long long)std::floor(hostBeatNow_ / (double)beatsPerStep);
                if (absStep != lastAbsStep_) {
                    lastAbsStep_ = absStep; boundary = true;
                    // UP: the playhead IS Logic's position. Other directions keep
                    // their own order — only the timing is locked.
                    if (dir_ == kDirUp) { const int wrap = gridSteps_; stepIdx_ = (int)(((absStep % wrap) + wrap) % wrap); }
                }
            } else if (sampleAccum_ >= samplesPerStep) { sampleAccum_ -= samplesPerStep; boundary = true; }
            if (boundary) {
                // Gate the previous column. In DUBSTEP with a NOTE length
                // above 1× the column keeps ringing: for N× it is released
                // after N steps, for HOLD only when the next note arrives.
                ++dubHeldSteps_;
                bool releasePrev = true;
                if (mode_ == kDubstep && dubNoteLen_ > 0) {
                    const int  holdSteps = (dubNoteLen_ == 1) ? 2 : (dubNoteLen_ == 2) ? 4 : 1 << 20;
                    releasePrev = gridColumnHasNotes(stepIdx_) || dubHeldSteps_ >= holdSteps;
                }
                if (mode_ == kDubstep && dubNoteLen_ > 0) {
                    if (releasePrev) releaseSeqVoices();
                } else {
                    tickGridHolds();        // long notes ring on; ended ones release
                    armEndingGate();        // GATE for long notes entering their last step
                }
                gridPendingStep_ = stepIdx_;
                static const float kSwingFrac[5] = {0.0f, 0.09f, 0.18f, 0.30f, 0.42f};
                const int lvl = colSwing_[playSlot_][gridPendingStep_ % kMaxGridSteps];
                // Per-column lateness dots + the global SWING knob (delays every
                // second step — the knob and the randomizer's swing used to do nothing).
                const float frac = std::min(0.9f, kSwingFrac[lvl < 0 ? 0 : (lvl > 4 ? 4 : lvl)] + ((gridPendingStep_ & 1) ? swing_ : 0.0f));
                gridFireDelay_ = frac * samplesPerStep;
                gridPendingFire_ = true;
                if (gridFireDelay_ <= 0.0f) {       // no swing → fire immediately
                    fireGridColumn(gridPendingStep_);
                    handleDrone();
                    gridPendingFire_ = false;
                }
                stepIdx_ = gridNextStep(stepIdx_);
                // Song mode: after a full grid loop, step to the next chain slot.
                if (chainLen_ > 0 && ++gridCycleStep_ >= gridSteps_) {
                    gridCycleStep_ = 0;
                    if (hostLocked_ && dir_ == kDirUp) {
                        // Absolute: which loop of the chain Logic's bar sits in, so
                        // pattern B really starts at its top (the host lock used to
                        // override the `stepIdx_ = 0` restart mid-pattern).
                        const long long loops = (long long)std::floor((double)(lastAbsStep_ + 1) / (double)gridSteps_);
                        chainPos_ = (int)(((loops % chainLen_) + chainLen_) % chainLen_);
                    } else if (!isolate_) {
                        chainPos_ = (chainPos_ + 1) % chainLen_;
                    }
                    // ISOLATE: the edit slot keeps looping; the chain position
                    // still follows Logic's bar count so it resumes in place.
                    if (!isolate_) {
                        setPlaySlot(chain_[chainPos_]);
                        stepIdx_ = 0;   // restart the new pattern from the top
                    }
                }
            }
            sampleAccum_ += 1.0f;
        }
        // Sequencer clock (legacy mono SEQ/BERLIN) — only when grid is off.
        else if (playing_) {
            const float beatsPerStep = stepBeats(rate_);
            const float samplesPerStep = sr_ * 60.0f / (bpm_ * (1.0f / beatsPerStep));
            float thisStepSamples = samplesPerStep;
            if ((stepIdx_ & 1) == 0) thisStepSamples *= (1.0f + swing_);
            else                     thisStepSamples *= (1.0f - swing_);

            if (sampleAccum_ >= thisStepSamples) {
                sampleAccum_ -= thisStepSamples;
                pendingRatchet_ = 1;
                advanceStep();                  // sets pendingRatchet_ + ratchetNote_/Vel_
                if (pendingRatchet_ > 1) {
                    ratchetLeft_ = pendingRatchet_ - 1;
                    ratchetInterval_ = thisStepSamples / (float)pendingRatchet_;
                    ratchetAcc_ = 0.0f;
                } else {
                    ratchetLeft_ = 0;
                }
            }
            // Fire ratchet sub-hits within the current step (rolls / stutters).
            if (ratchetLeft_ > 0) {
                ratchetAcc_ += 1.0f;
                if (ratchetAcc_ >= ratchetInterval_) {
                    ratchetAcc_ -= ratchetInterval_;
                    retriggerRatchet();
                    ratchetLeft_--;
                }
            }
            sampleAccum_ += 1.0f;
        }

        // Mix all voices
        float s = 0;
        for (auto &v : voices_) s += v.process();
        // Drone voices — sum, then scale by drone level. V2 is silenced when
        // interval == 0 (root only) but we let it process to settle envelopes.
        if (droneOn_) {
            float dSum = droneV1_.process();
            if (droneInterval_ != 0) dSum += droneV2_.process();
            s += dSum * droneLevel_;
        }

        // ── DUBSTEP wobble — engine-level resonant LP swept by a pattern
        // sequencer. dubPattern_[step] picks the wobble division for the
        // current beat (0=1/2, 1=1/4, 2=1/8, 3=1/16, 4=1/8T, 5=STOP).
        // That makes the classic "wa-wa-woop-wa-waooop-wop-wop" — rate
        // switches per beat without phase resetting.
        if (mode_ == kDubstep) {
            const double bps = (double)bpm_ / 60.0;
            if (hostLocked_) dubBeatPos_ = hostBeatNow_;      // WOB pattern rides Logic's bars
            else             dubBeatPos_ += bps / (double)sr_;
            // Loop within the pattern (8 steps = 2 bars at 4/4)
            const int patternStep = ((int)std::floor(dubBeatPos_) % kDubPatternLen + kDubPatternLen) % kDubPatternLen;
            const int division = dubPattern_[patternStep];
            float cyclesPerBeat = 1.0f;
            bool wobbleOn = true;
            switch (division) {
                case 0: cyclesPerBeat = 0.5f; break;   // 1/2
                case 1: cyclesPerBeat = 1.0f; break;   // 1/4
                case 2: cyclesPerBeat = 2.0f; break;   // 1/8
                case 3: cyclesPerBeat = 4.0f; break;   // 1/16
                case 4: cyclesPerBeat = 3.0f; break;   // 1/8T (3 per beat)
                case 5: wobbleOn = false;   break;     // STOP — filter wide open
                case 6: wobbleOn = false;   break;     // 1/16 CHOP — gate, see below
                case 7: wobbleOn = false;   break;     // 1/32 CHOP — gate, see below
                default: cyclesPerBeat = 1.0f; break;
            }
            // Gate-style choppers: square gate locked to the beat counter so
            // it never drifts against the grid. 50% duty, de-clicked with a
            // short one-pole so each stutter still has a hard edge.
            float gateTarget = 1.0f;
            if (division == kDubChop16 || division == kDubChop32) {
                const double perBeat = (division == kDubChop16) ? 4.0 : 8.0;
                const double ph = dubBeatPos_ * perBeat;
                gateTarget = ((ph - std::floor(ph)) < 0.5) ? 1.0f : 0.0f;
            }
            dubGate_ += kDubGate_ * (gateTarget - dubGate_);
            if (wobbleOn) {
                const float wobbleHz = (float)(bps * cyclesPerBeat);
                dubLfoPhase_ += wobbleHz / sr_;
                if (dubLfoPhase_ >= 1.0f) dubLfoPhase_ -= 1.0f;
                float tri = 4.0f * std::fabs(dubLfoPhase_ - 0.5f) - 1.0f;
                const float minHz = 120.0f, maxHz = 2400.0f;
                const float t = 0.5f + 0.5f * tri;
                const float cutoff = minHz * std::pow(maxHz / minHz, t);
                dubWobble_.setCutoff(cutoff);
                s = dubWobble_.process(s) * 1.4f;
            } else {
                // STOP step: hold filter wide open so the signal passes clean,
                // but still process through ladder to keep state in sync (no
                // click when the wobble resumes on the next step).
                dubWobble_.setCutoff(8000.0f);
                s = dubWobble_.process(s);
            }
            s *= dubGate_;
        }

        // ── Output FX chain — runs after voice sum, before level ───────
        // 1) MOD: LFO-modulated short delay = chorus/flanger. Two delay
        //    reads at slightly different LFO phases give a stereo image.
        if (modAmt_ > 0.001f) {
            // Write current sample to the mod buffer.
            modBuf_[modW_ & (kModBufMask)] = s;
            modLfo_ += 2.0f * kPi * 0.6f / sr_;  // ~0.6 Hz
            if (modLfo_ > 2.0f * kPi) modLfo_ -= 2.0f * kPi;
            const float swingMs = 3.0f + 4.5f * modAmt_;          // 3..7.5 ms swing
            const float baseMs  = 4.0f + 4.0f * modAmt_;          // 4..8 ms base
            const float dlySampL = sr_ * 0.001f * (baseMs + swingMs * std::sin(modLfo_));
            const float dlySampR = sr_ * 0.001f * (baseMs + swingMs * std::sin(modLfo_ + kPi * 0.5f));
            auto readDelay = [&](float ds) -> float {
                const int idx = ((int)modW_ - (int)ds) & kModBufMask;
                return modBuf_[idx];
            };
            const float wetL = readDelay(dlySampL);
            const float wetR = readDelay(dlySampR);
            // Mix: blend wet on top of dry; higher modAmt_ adds feedback for flange.
            const float fb = modAmt_ * 0.4f;
            modBuf_[modW_ & kModBufMask] = s + 0.5f * (wetL + wetR) * fb;
            const float mix = 0.5f * modAmt_;
            outL = s * (1.0f - mix) + wetL * mix * 1.2f;
            outR = s * (1.0f - mix) + wetR * mix * 1.2f;
            modW_++;
            s = 0.5f * (outL + outR);  // collapsed for downstream
        } else {
            outL = s; outR = s;
        }

        // 2) DIRT: tanh drive — pushes the signal into soft clipping.
        if (dirtAmt_ > 0.001f) {
            const float drive = 1.0f + dirtAmt_ * 6.0f;
            outL = std::tanh(outL * drive) * (1.0f - 0.35f * dirtAmt_);
            outR = std::tanh(outR * drive) * (1.0f - 0.35f * dirtAmt_);
        }

        // 3) NOISE: analog hiss floor — lightly LP'd white noise with the
        //    same trick the Drums use (decorrelated L/R taps).
        if (noiseAmt_ > 0.001f) {
            if (++noiseTick_ >= noiseHold_) {
                noiseTick_ = 0;
                noiseRng_ = noiseRng_ * 1664525u + 1013904223u;
                const float wn  = (((noiseRng_ >> 8) & 0x00FFFFFF) / 8388608.0f - 1.0f);
                noiseLpZ_ += kNoiseLp_ * (wn - noiseLpZ_);
                noiseRng_ = noiseRng_ * 1664525u + 1013904223u;
                noiseW2_ = (((noiseRng_ >> 8) & 0x00FFFFFF) / 8388608.0f - 1.0f);
            }
            const float wn2 = noiseW2_;
            const float n   = noiseLpZ_ * 0.5f + wn2 * 0.15f;
            const float amt = noiseAmt_ * 0.20f;
            outL += n * amt;
            outR += (n * 0.9f + wn2 * 0.05f) * amt;
        }

        // 4) CHOPPER — tempo-synced amplitude shaper. Type sets rate AND shape,
        //    from plain gates to stutters, random gates, sample&hold and glitch.
        //    0=1/16 · 1=1/8 · 2=TRIP · 3=SAW · 4=REV · 5=STUT(1/32) · 6=RAND
        //    7=S&H · 8=SINE · 9=GLCH
        if (chopAmt_ > 0.001f) {
            float cyclesPerBeat = 4.0f; int shape = 0;  // shape: 0 sq,1 sawDn,2 sawUp,3 sine,4 randGate,5 s&h,6 glitch
            switch (chopType_) {
                case 0: cyclesPerBeat = 4.0f;  shape = 0; break;  // 1/16
                case 1: cyclesPerBeat = 2.0f;  shape = 0; break;  // 1/8
                case 2: cyclesPerBeat = 3.0f;  shape = 0; break;  // 1/8 triplet
                case 3: cyclesPerBeat = 2.0f;  shape = 1; break;  // SAW down
                case 4: cyclesPerBeat = 2.0f;  shape = 2; break;  // REV (saw up)
                case 5: cyclesPerBeat = 8.0f;  shape = 0; break;  // STUTTER 1/32
                case 6: cyclesPerBeat = 4.0f;  shape = 4; break;  // RANDOM gate
                case 7: cyclesPerBeat = 4.0f;  shape = 5; break;  // SAMPLE&HOLD
                case 8: cyclesPerBeat = 6.0f;  shape = 3; break;  // SINE tremolo
                case 9: cyclesPerBeat = 4.0f;  shape = 6; break;  // GLITCH
                default: break;
            }
            const float hz = (bpm_ / 60.0f) * cyclesPerBeat;
            bool wrapped = false;
            if (hostLocked_) {                                  // phase from Logic's beat
                const double cyc = hostBeatNow_ * (double)cyclesPerBeat;
                const float np = (float)(cyc - std::floor(cyc));
                wrapped = np < chopPhase_;
                chopPhase_ = np;
            } else {
                chopPhase_ += hz / sr_;
                if (chopPhase_ >= 1.0f) { chopPhase_ -= 1.0f; wrapped = true; }
            }
            if (wrapped) {                                  // fresh random each cycle
                chopRng_ = chopRng_ * 1664525u + 1013904223u;
                chopRand_ = (float)((chopRng_ >> 8) & 0xFFFF) / 65535.0f;
            }
            float gTarget = 1.0f;
            switch (shape) {
                case 0: gTarget = (chopPhase_ < 0.5f) ? 1.0f : 0.0f; break;            // square gate
                case 1: gTarget = 1.0f - chopPhase_; break;                            // saw down
                case 2: gTarget = chopPhase_; break;                                   // saw up
                case 3: gTarget = 0.5f + 0.5f * std::sin(2.0f * kPi * chopPhase_); break; // sine
                case 4: gTarget = (chopRand_ > 0.5f) ? 1.0f : 0.0f; break;             // random gate
                case 5: gTarget = chopRand_; break;                                    // sample & hold level
                case 6:                                                                // glitch
                    if (chopRand_ < 0.20f)      gTarget = 0.0f;                        // dropout
                    else if (chopRand_ < 0.40f) gTarget = 1.0f;                        // hold open
                    else                        gTarget = (chopPhase_ < 0.5f) ? 1.0f : 0.0f;
                    break;
                default: break;
            }
            chopGain_ += kChopGain_ * (gTarget - chopGain_);     // de-click smoothing
            const float gain = 1.0f - chopAmt_ * (1.0f - chopGain_);
            outL *= gain; outR *= gain;
        }
        // 5) DELAY — type sets time/feedback/ping-pong.
        //    0=1/8 · 1=1/4 · 2=dotted-1/8 · 3=triplet · 4=slapback · 5=ping-pong
        if (delayAmt_ > 0.001f) {
            float beats = 0.5f, fb = 0.45f; bool ping = false; bool slap = false;
            switch (delayType_) {
                case 0: beats = 0.5f;        fb = 0.45f; break;  // 1/8
                case 1: beats = 1.0f;        fb = 0.45f; break;  // 1/4
                case 2: beats = 0.75f;       fb = 0.45f; break;  // dotted 1/8
                case 3: beats = 1.0f / 3.0f; fb = 0.40f; break;  // 1/8 triplet
                case 4: beats = 0.0f;        fb = 0.18f; slap = true; break; // slapback
                case 5: beats = 0.5f;        fb = 0.45f; ping = true; break; // ping-pong
                default: break;
            }
            int dlySamp = slap ? (int)(sr_ * 0.11f) : (int)(sr_ * 60.0f / bpm_ * beats);
            if (dlySamp < 1) dlySamp = 1;
            if (dlySamp > dlyLimit_) dlySamp = dlyLimit_;
            int rd = dlyW_ - dlySamp; if (rd < 0) rd += kDlyMax;
            const float dl = dlyL_[rd], dr = dlyR_[rd];
            if (ping) {
                // Cross-feed L↔R for the bouncing stereo image.
                dlyL_[dlyW_] = outL + dr * fb;
                dlyR_[dlyW_] = outR + dl * fb;
            } else {
                dlyL_[dlyW_] = outL + dl * fb;
                dlyR_[dlyW_] = outR + dr * fb;
            }
            if (++dlyW_ >= kDlyMax) dlyW_ = 0;
            const float mix = delayAmt_ * 0.5f;
            outL += dl * mix; outR += dr * mix;
        }
        // 6) REVERB — type sets size/brightness. 0=ROOM 1=HALL 2=PLATE 3=AMBI
        if (reverbAmt_ > 0.001f) {
            switch (reverbType_) {
                case 0: verb_.setParams(0.74f, 0.36f); break;  // room
                case 1: verb_.setParams(0.88f, 0.20f); break;  // hall
                case 2: verb_.setParams(0.84f, 0.08f); break;  // plate (bright)
                case 3: verb_.setParams(0.60f, 0.45f); break;  // ambience (short)
                default: break;
            }
            const float w = verb_.process(0.5f * (outL + outR));
            const float mix = reverbAmt_ * 0.6f;
            outL += w * mix; outR += w * mix;
        }

        // Gentle output saturation, then user-controlled output level.
        outL = std::tanh(outL * 0.45f) * 1.4f * outputLevel_;
        outR = std::tanh(outR * 0.45f) * 1.4f * outputLevel_;
        s = 0.5f * (outL + outR);  // for the amplitude probe below

        // Sample-clock + amplitude probe for the visualizer.
        sampleCount_++;
        const float abs_s = s < 0 ? -s : s;
        // Asymmetric envelope follower: snappy attack, slow release.
        const float coeff = (abs_s > ampProbe_) ? 0.15f : 0.001f;
        ampProbe_ += coeff * (abs_s - ampProbe_);
    }

private:
    struct Step { bool on = false; int semi = 0; int oct = 0; int ratchet = 1; };

    /// Pushes per-voice ADSR + mix based on the current voiceMode_.
    /// SYNTH uses the user's current settings (kept in user* fields).
    /// PLUCK and MALLET override with hand-picked envelopes/mixes.
    void applyVoiceMode() {
        for (auto &v : voices_) {
            // Reset all character modulators each call so modes never bleed.
            v.setUnison(0, 0.0f, 0.0f);
            v.setPWM(0.0f, 0.0f, 0.0f);
            v.setFM(0.0f, 2.0f, 0.0f);
            v.setVibrato(0.0f, 0.0f);
            switch (voiceMode_) {
                case kVoicePluck:
                    v.setEnvAmp(0.0008f, 0.060f, 0.0f, 0.040f);
                    v.setEnvFlt(0.0008f, 0.030f, 0.0f, 0.025f);
                    v.setMix(0.80f, 0.18f, 0.10f);
                    v.setFM(0.22f, 4.0f, 1.3f);      // bright FM ping on the attack
                    v.setFilter(userCutoff_ * 1.1f, std::max(userReso_, 0.4f), 0.9f);
                    break;
                case kVoiceBass:
                    // Berlin-school sub bass: dark, long sustain + 1:1 FM growl.
                    v.setEnvAmp(0.005f, 0.10f, 0.9f, 0.25f);
                    v.setEnvFlt(0.012f, 0.20f, 0.6f, 0.40f);
                    v.setMix(0.35f, 0.0f, 0.95f);
                    v.setFM(0.10f, 1.0f, 0.7f);
                    v.setFilter(std::min(userCutoff_, 900.0f), userReso_, 0.4f);
                    break;
                case kVoiceBell:
                    // Inharmonic FM bell: strong operator + fast strike + long ring.
                    v.setEnvAmp(0.0006f, 2.0f, 0.0f, 1.5f);
                    v.setEnvFlt(0.0006f, 0.30f, 0.0f, 0.50f);
                    v.setMix(0.0f, 0.20f, 0.18f);
                    v.setFM(0.80f, 3.51f, 3.2f);
                    {
                        const float bellReso = std::min(std::max(userReso_, 0.5f), 1.1f);
                        v.setFilter(3500.0f, bellReso, 0.2f);
                    }
                    break;
                case kVoiceSuper:
                    // SUPER — 6 detuned saws, bright, big EDM lead/chord.
                    v.setEnvAmp(0.010f, 0.20f, 0.85f, 0.30f);
                    v.setEnvFlt(0.020f, 0.30f, 0.7f, 0.30f);
                    v.setMix(0.18f, 0.0f, 0.12f);
                    v.setUnison(6, 22.0f, 0.85f);    // ±22 cents spread
                    v.setFilter(std::max(userCutoff_, 3000.0f), std::max(userReso_, 0.2f), 0.5f);
                    break;
                case kVoiceReese:
                    // REESE — two wide-detuned saws + heavy sub + FM growl, dark.
                    v.setEnvAmp(0.006f, 0.15f, 0.9f, 0.25f);
                    v.setEnvFlt(0.010f, 0.20f, 0.65f, 0.35f);
                    v.setMix(0.18f, 0.0f, 0.55f);
                    v.setUnison(2, 30.0f, 0.70f);    // wide detune = beating growl
                    v.setFM(0.15f, 1.0f, 0.8f);
                    v.setFilter(std::min(userCutoff_, 1400.0f), std::max(userReso_, 0.5f), 0.55f);
                    break;
                case kVoicePWM:
                    // PWM — pulse-width-modulated square lead, moving + hollow.
                    v.setEnvAmp(0.008f, 0.18f, 0.85f, 0.25f);
                    v.setEnvFlt(0.012f, 0.18f, 0.7f, 0.30f);
                    v.setMix(0.15f, 0.85f, 0.20f);
                    v.setPWM(0.35f, 3.5f, 1.0f);     // width LFO at 3.5 Hz
                    v.setFilter(userCutoff_, std::max(userReso_, 0.3f), 0.55f);
                    break;
                case kVoiceDigi:
                    // DIGI — hard high-index digital FM lead, aggressive.
                    v.setEnvAmp(0.002f, 0.20f, 0.7f, 0.20f);
                    v.setEnvFlt(0.002f, 0.15f, 0.6f, 0.20f);
                    v.setMix(0.10f, 0.10f, 0.10f);
                    v.setFM(0.90f, 2.0f, 6.0f);      // high index = bright digital sidebands
                    v.setFilter(std::max(userCutoff_, 2500.0f), std::max(userReso_, 0.2f), 0.6f);
                    break;
                case kVoiceSynth:
                default:
                    v.setEnvAmp(userAmpA_, userAmpD_, userAmpS_, userAmpR_);
                    v.setEnvFlt(userFltA_, userFltD_, userFltS_, userFltR_);
                    v.setMix(userMixSaw_, userMixSq_, userMixSub_);
                    v.setFM(0.12f, 1.0f, 0.7f);      // subtle FM warmth on the base voice
                    v.setFilter(userCutoff_, userReso_, userFenv_);
                    break;
            }
        }
    }

    void defaultEnvs() {
        for (auto &v : voices_) {
            v.setEnvAmp(0.005f, 0.12f, 0.6f, 0.18f);
            v.setEnvFlt(0.002f, 0.10f, 0.4f, 0.15f);
            v.setFilter(2200.0f, 0.6f, 0.6f);
            v.setMix(0.6f, 0.4f, 0.4f);
        }
        droneV1_.prepare(sr_);
        droneV2_.prepare(sr_);
        droneV1_.setEnvAmp(0.3f, 0.5f, 0.85f, 1.5f);
        droneV2_.setEnvAmp(0.3f, 0.5f, 0.85f, 1.5f);
        droneV1_.setFilter(1500.0f, 0.3f, 0.0f);
        droneV2_.setFilter(1500.0f, 0.3f, 0.0f);
        droneV1_.setMix(0.5f, 0.2f, 0.5f);
        droneV2_.setMix(0.5f, 0.2f, 0.5f);
    }
    void defaultSeq() {
        // Simple ascending 8-step + rest pattern
        const int demo[16] = {1,0,1,0,1,0,1,0, 1,0,0,1,0,1,0,1};
        const int semis[16] = {0,0,4,0,7,0,12,0, 5,0,0,3,0,9,0,2};
        for (int i = 0; i < kStepCount; ++i) {
            seq_[i].on = demo[i] != 0;
            seq_[i].semi = semis[i];
            seq_[i].oct = 0;
        }
    }
    void defaultGrid() {
        for (int sl = 0; sl < kPatternSlots; ++sl) {
            for (int r = 0; r < kGridRows; ++r)
                for (int s = 0; s < kMaxGridSteps; ++s) { grid_[sl][r][s] = false; gridLen_[sl][r][s] = 0; }
            for (int s = 0; s < kMaxGridSteps; ++s) { colSwing_[sl][s] = 0; recRoot_[sl][s] = -1; }
        }
        // Each slot ships with a distinct starter motif so A/B/C/D all have
        // something audible out of the box (B/C/D used to be blank).
        // Slot A: a gentle rising motif.
        const int aStep[8] = {0, 2, 4, 6, 8, 10, 12, 14};
        const int aRow [8] = {0, 2, 4, 2, 7,  4,  2,  0};
        for (int i = 0; i < 8; ++i) grid_[0][aRow[i]][aStep[i]] = true;
        // Slot B: a syncopated tresillo-style stab.
        const int bStep[8] = {0, 3, 6, 8, 11, 12, 14, 15};
        const int bRow [8] = {0, 4, 2, 7,  4,  0,  5,  2};
        for (int i = 0; i < 8; ++i) grid_[1][bRow[i]][bStep[i]] = true;
        // Slot C: an ascending arpeggio run (one row per step, climbing).
        for (int i = 0; i < 8; ++i) grid_[2][i % kGridRows][i * 2] = true;
        // Slot D: an octave bounce — root and top row trading on the beats.
        const int dStep[8] = {0, 2, 4, 6, 8, 10, 12, 14};
        for (int i = 0; i < 8; ++i) grid_[3][(i % 2 == 0) ? 0 : (kGridRows - 1)][dStep[i]] = true;
    }
    void clearChord() {
        chordCount_ = 0; lowestHeld_ = -1; lastArpNote_ = -1;
    }
    static int clampr(int v, int lo, int hi) { return std::max(lo, std::min(hi, v)); }

    // Direction-aware step advance. Used by SEQ and BERLIN modes.
    int nextStepIdx(int cur) {
        switch (dir_) {
            case kDirDown:
                return (cur - 1 + kStepCount) % kStepCount;
            case kDirRandom:
                rng_ = rng_ * 1664525u + 1013904223u;
                return (int)((rng_ >> 8) % (uint32_t)kStepCount);
            case kDirUpDown: {
                // Up to 15, then back down to 0, bouncing.
                if (directionUp_) {
                    if (cur >= kStepCount - 1) { directionUp_ = false; return cur - 1; }
                    return cur + 1;
                } else {
                    if (cur <= 0) { directionUp_ = true; return cur + 1; }
                    return cur - 1;
                }
            }
            case kDirAsPlayed:
            case kDirUp:
            default:
                return (cur + 1) % kStepCount;
        }
    }
    // Maps rate slot to step length in beats. 1=quarter, 2=8th, 3=16th, 4=32nd, 5=8T, 6=16T
    static float stepBeats(int r) {
        switch (r) {
            case 1: return 1.0f;
            case 2: return 0.5f;
            case 3: return 0.25f;
            case 4: return 0.125f;
            case 5: return 1.0f / 3.0f;       // 8th triplet
            case 6: return 1.0f / 6.0f;       // 16th triplet
            case 7: return 0.0625f;           // 1/64 (¼ of a 1/16 step)
            default: return 0.25f;
        }
    }

    // Direction-aware advance within the grid's step count (16/32/64).
    int gridNextStep(int cur) {
        const int n = gridSteps_;
        switch (dir_) {
            case kDirDown:   return (cur - 1 + n) % n;
            case kDirRandom: rng_ = rng_ * 1664525u + 1013904223u; return (int)((rng_ >> 8) % (uint32_t)n);
            case kDirUpDown:
                if (directionUp_) { if (cur >= n - 1) { directionUp_ = false; return cur - 1; } return cur + 1; }
                else              { if (cur <= 0)     { directionUp_ = true;  return cur + 1; } return cur - 1; }
            default:         return (cur + 1) % n;
        }
    }

    // Fire every lit cell in one grid column as a chord (polyphonic).
    // True when any of the 8 rows is lit in this column (for NOTE length).
    bool gridColumnHasNotes(int step) const {
        if (step < 0 || step >= kMaxGridSteps) return false;
        for (int row = 0; row < kGridRows; ++row) if (grid_[playSlot_][row][step]) return true;
        return false;
    }

    void fireGridColumn(int step) {
        int fired = 0;
        const float baseVel = (step % 4 == 0) ? 1.0f : 0.80f;   // accent downbeats
        const int baseRoot = effectiveRootMidi(step);           // live key / recorded / panel
        for (int row = 0; row < kGridRows && fired < kMaxVoices; ++row) {
            if (!grid_[playSlot_][row][step]) continue;
            const int midi = gridRowMidiBase(row, baseRoot);
            Voice *t = nullptr;
            for (auto &v : voices_) if (!v.isActive()) { t = &v; break; }
            if (!t) t = &voices_[fired % kMaxVoices];
            liveNote_[(int)(t - voices_)] = -1;
            rng_ = rng_ * 1664525u + 1013904223u;
            const float vv = baseVel * (0.93f + 0.07f * (float)((rng_ >> 8) & 0xFF) / 255.0f);
            t->noteOn(midi, vv);
            seqHold_[(int)(t - voices_)] = cellLengthIn(playSlot_, row, step);
            fired++;
            lastArpNote_ = midi;
            // Comet-field ring (UI reads this for the visualizer).
            const int w = noteRingW_.load(std::memory_order_relaxed);
            noteRing_[w & (kNoteRing - 1)] = { midi, sampleCount_ };
            noteRingW_.store(w + 1, std::memory_order_relaxed);
        }
        if (fired > 0) dubHeldSteps_ = 0;
        lastFiredStep_ = step;
        // GATE (< 100 %) releases the column after that fraction of a step;
        // DUBSTEP NOTE lengths above 1× own the release instead.
        const bool dubHold = (mode_ == kDubstep && dubNoteLen_ > 0);
        if (!dubHold) armEndingGate();
        else gateCountdown_ = 0;
    }

    // Drone start/stop — shared by the grid + legacy mono paths.
    void handleDrone() {
        const int defaultRootMidi = 60 + rootKey_;
        if (droneOn_) {
            const int baseRoot = (chordCount_ > 0 ? lowestHeld_ : defaultRootMidi) + droneOctave_ * 12;
            if (!droneV1_.isActive()) droneV1_.noteOn(baseRoot, 0.6f);
            int upper = baseRoot;
            switch (droneInterval_) {
                case 0: upper = -1; break;
                case 1: upper = baseRoot + 7; break;
                case 2: upper = baseRoot + 7 + 12; break;
                case 3: upper = baseRoot + 12; break;
            }
            if (upper >= 0) { if (!droneV2_.isActive()) droneV2_.noteOn(upper, 0.5f); }
            else            { if (droneV2_.isActive()) droneV2_.noteOff(); }
        } else {
            if (droneV1_.isActive()) droneV1_.noteOff();
            if (droneV2_.isActive()) droneV2_.noteOff();
        }
    }

    void advanceStep() {
        // Stop the previously-triggered voice (key-trigger style gate). In the
        // grid, long notes keep ringing until their length runs out.
        if (gridMode_) tickGridHolds(); else releaseSeqVoices();

        // ── MELODIC GRID PATH (default) — fire every lit row in the column.
        if (gridMode_) {
            const int playStep = stepIdx_;
            fireGridColumn(playStep);
            handleDrone();
            stepIdx_ = gridNextStep(stepIdx_);
            pendingRatchet_ = 1;   // grid mode has no ratchets — the cells are the pattern
            return;
        }

        // Default root note when no MIDI chord is held — C4 (60) transposed by
        // the ROOT key selection. Without this, the ROOT row only re-snapped
        // the scale but never moved the actual pitch, so changing ROOT did
        // nothing audible across melody / berlin / drone voices.
        const int defaultRootMidi = 60 + rootKey_;

        const int playStep = stepIdx_;   // captured before nextStepIdx advances it
        int playNote = -1;
        if (mode_ == kSeq) {
            const Step &st = seq_[stepIdx_];
            if (st.on) playNote = defaultRootMidi + st.semi + st.oct * 12;
            stepIdx_ = nextStepIdx(stepIdx_);
        } else { // kBerlin
            const Step &st = seq_[stepIdx_];
            if (st.on) {
                int rootHeld = (chordCount_ > 0) ? lowestHeld_ : defaultRootMidi;
                playNote = rootHeld + st.semi + st.oct * 12;
            }
            stepIdx_ = nextStepIdx(stepIdx_);
        }
        if (playNote < 0) return;

        playNote = snapToScale(playNote, rootKey_, scale_);

        // Drone — start once if enabled. Octave + interval are user-controlled.
        if (droneOn_) {
            const int baseRoot = (chordCount_ > 0 ? lowestHeld_ : defaultRootMidi) + droneOctave_ * 12;
            if (!droneV1_.isActive()) droneV1_.noteOn(baseRoot, 0.6f);
            int upper = baseRoot;
            switch (droneInterval_) {
                case 0: upper = -1; break;            // root only — silence V2
                case 1: upper = baseRoot + 7; break;  // +5th
                case 2: upper = baseRoot + 7 + 12; break; // +5th + octave
                case 3: upper = baseRoot + 12; break; // octave double
            }
            if (upper >= 0) {
                if (!droneV2_.isActive()) droneV2_.noteOn(upper, 0.5f);
            } else {
                if (droneV2_.isActive()) droneV2_.noteOff();
            }
        } else {
            if (droneV1_.isActive()) droneV1_.noteOff();
            if (droneV2_.isActive()) droneV2_.noteOff();
        }

        // Find a free voice
        Voice *target = nullptr;
        for (auto &v : voices_) if (!v.isActive()) { target = &v; break; }
        if (!target) target = &voices_[0];
        // Groove: accent the downbeats (every 4th step) and humanize the rest
        // so even straight grids don't sound robotic.
        float vel = (playStep % 4 == 0) ? 1.0f : 0.78f;
        rng_ = rng_ * 1664525u + 1013904223u;
        vel *= 0.93f + 0.07f * (float)((rng_ >> 8) & 0xFF) / 255.0f;
        target->noteOn(playNote, vel);
        pendingRatchet_ = seq_[playStep].ratchet;   // step's roll count → clock schedules sub-hits
        ratchetNote_ = playNote;
        ratchetVel_  = vel;
        lastArpNote_ = playNote;

        // Push to the comet-field ring so the UI can draw a new comet.
        const int w = noteRingW_.load(std::memory_order_relaxed);
        noteRing_[w & (kNoteRing - 1)] = { playNote, sampleCount_ };
        noteRingW_.store(w + 1, std::memory_order_relaxed);
    }

    // Retrigger the current note as a fast ratchet sub-hit (rolls/stutters).
    void retriggerRatchet() {
        if (ratchetNote_ < 0) return;
        releaseSeqVoices();
        Voice *t = nullptr;
        for (auto &v : voices_) if (!v.isActive()) { t = &v; break; }
        if (!t) t = &voices_[0];
        t->noteOn(ratchetNote_, ratchetVel_ * 0.92f);   // slightly softer sub-hits
        const int w = noteRingW_.load(std::memory_order_relaxed);
        noteRing_[w & (kNoteRing - 1)] = { ratchetNote_, sampleCount_ };
        noteRingW_.store(w + 1, std::memory_order_relaxed);
    }

    int pickArpNote() {
        // Apply octave range expansion
        std::vector<int> notes; notes.reserve(chordCount_ * octRange_);
        for (int o = 0; o < octRange_; ++o)
            for (int i = 0; i < chordCount_; ++i)
                notes.push_back(chord_[i] + o * 12);
        if (notes.empty()) return -1;

        switch (dir_) {
            case kDirUp: {
                int idx = arpStep_ % (int)notes.size();
                arpStep_ = (arpStep_ + 1) % (int)notes.size();
                return notes[idx];
            }
            case kDirDown: {
                int idx = (int)notes.size() - 1 - (arpStep_ % (int)notes.size());
                arpStep_ = (arpStep_ + 1) % (int)notes.size();
                return notes[idx];
            }
            case kDirUpDown: {
                int n = (int)notes.size();
                if (n == 1) return notes[0];
                int cycle = 2 * (n - 1);
                int idx = arpStep_ % cycle;
                if (idx >= n) idx = cycle - idx;
                arpStep_ = (arpStep_ + 1) % cycle;
                return notes[idx];
            }
            case kDirRandom: {
                rng_ = rng_ * 1664525u + 1013904223u;
                return notes[(rng_ >> 8) % notes.size()];
            }
            case kDirAsPlayed:
            default: {
                int idx = arpStep_ % (int)notes.size();
                arpStep_ = (arpStep_ + 1) % (int)notes.size();
                return notes[idx];
            }
        }
    }

    float sr_ = 48000;
    Voice voices_[kMaxVoices];
    static_assert(kMaxVoices == 8, "liveNote_ initialiser assumes 8 voices");
    int      liveNote_[kMaxVoices] = { -1, -1, -1, -1, -1, -1, -1, -1 };   // MIDI note a held key owns per voice
    unsigned liveSteal_ = 0;
    Voice droneV1_, droneV2_;

    // ── DUBSTEP mode state — engine-level resonant LP wobble on the mix bus
    Ladder dubWobble_;
    float  dubLfoPhase_ = 0.0f;
    int    dubPattern_[8] = {1,1,1,1,1,1,1,1};
    double dubBeatPos_ = 0.0;     // continuous beat counter for pattern lookup
    float  dubGate_ = 1.0f;       // smoothed CHOP gate gain
    int    dubNoteLen_ = 0;       // 0=1× 1=2× 2=4× 3=HOLD (see setDubNoteLen)
    int    dubHeldSteps_ = 0;     // grid steps since the last column fired

    int   chord_[kMaxChordNotes] = {0};
    int   chordCount_ = 0;
    int   lowestHeld_ = -1;
    int   lastArpNote_ = -1;
    int   arpStep_ = 0;
    int   stepIdx_ = 0;
    bool  directionUp_ = true;
    // Ratchet (sub-hit) state — drives the wild MOTION rolls/stutters.
    int   pendingRatchet_ = 1, ratchetLeft_ = 0, ratchetNote_ = -1;
    float ratchetAcc_ = 0.0f, ratchetInterval_ = 0.0f, ratchetVel_ = 0.9f;
    bool  playing_ = true;       // transport gate; set false to halt sequencer
    float sampleAccum_ = 0;
    double lastHostBeat_ = 0.0;
    bool  needsHostResync_ = true;   // force a hard snap on the next host update
    bool  prepared_ = false;         // musical defaults loaded once
    double lastBlockBpm_ = 0.0;      // tempo the previous block ran at (jump detection)
    int   gateCountdown_ = 0;        // samples until the GATE releases the column (0 = off)
    int   lastFiredStep_ = -1;       // column that is sounding (for the playhead)
    int   samplesSinceHostBeat_ = 0; // elapsed frames since last setHostBeatPosition
    bool      hostLocked_  = false;      // true once Logic has fed a beat position
    double    hostBeatNow_ = 0.0;        // musical time of the current frame (beats)
    long long lastAbsStep_ = LLONG_MIN;  // last grid step fired under host lock

    // Visualizer state
    mutable NoteHit noteRing_[kNoteRing] = {};
    mutable std::atomic<int> noteRingW_{0};
    int64_t sampleCount_ = 0;
    float   ampProbe_ = 0.0f;

    // ── Output FX state (MOD / DIRT / NOISE) ───────────────────────
    float modAmt_ = 0.0f, dirtAmt_ = 0.0f, noiseAmt_ = 0.0f;
    static constexpr int kModBufSize = 4096;        // ~85ms @ 48k — plenty for chorus/flange
    static constexpr int kModBufMask = kModBufSize - 1;
    float modBuf_[kModBufSize] = {0};
    int   modW_ = 0;
    float modLfo_ = 0.0f;
    uint32_t noiseRng_ = 0xC0DEFEE5u;
    float noiseLpZ_ = 0.0f;

    // ── DELAY / REVERB / CHOP state ─────────────────────────────────
    float delayAmt_ = 0.0f, reverbAmt_ = 0.0f, chopAmt_ = 0.0f;
    int   delayType_ = 0, reverbType_ = 1, chopType_ = 0;
    float pingState_ = 0.0f;                         // ping-pong cross-feed
    static constexpr int kDlyMax = 192000;           // 1 s up to 192 kHz (was 48000 samples: half a second at 96 kHz)
    int   dlyLimit_ = 47999;
    float kDubGate_ = 0.06f, kChopGain_ = 0.04f, kNoiseLp_ = 0.35f, noiseW2_ = 0.0f;
    int   noiseHold_ = 1, noiseTick_ = 0;
    float dlyL_[kDlyMax] = {0}, dlyR_[kDlyMax] = {0};
    int   dlyW_ = 0;
    MiniVerb verb_;
    float chopPhase_ = 0.0f, chopGain_ = 1.0f;
    uint32_t chopRng_ = 0x1234567u; float chopRand_ = 1.0f;

    float bpm_ = 120.0f;
    int   rate_ = 3;             // 16th notes default
    int   mode_ = kArp;
    int   dir_  = kDirUp;
    int   octRange_ = 1;
    float gate_ = 0.5f;
    float swing_ = 0.0f;
    int   scale_ = kScaleChromatic;
    int   rootKey_ = 0;          // C
    bool  droneOn_ = false;
    float droneLevel_ = 0.7f;
    int   droneOctave_ = -1;       // one octave below root by default
    int   droneInterval_ = 1;      // root + 5th by default
    float outputLevel_ = 1.0f;

    float baseCutoff_ = 2200.0f, reso_ = 0.6f, fenvAmt_ = 0.6f;
    int   voiceMode_ = kVoiceSynth;

    // User-set voice params (captured so SYNTH mode can restore them after
    // PLUCK / MALLET have overridden the per-voice values).
    float userMixSaw_ = 0.6f, userMixSq_ = 0.4f, userMixSub_ = 0.4f;
    float userCutoff_ = 2200.0f, userReso_ = 0.6f, userFenv_ = 0.6f;
    float userAmpA_ = 0.005f, userAmpD_ = 0.12f, userAmpS_ = 0.6f, userAmpR_ = 0.18f;
    float userFltA_ = 0.002f, userFltD_ = 0.10f, userFltS_ = 0.4f, userFltR_ = 0.15f;

    Step seq_[kStepCount];

    // ── Melodic step-grid state ──────────────────────────────────────
    bool    gridMode_  = true;                               // grid is the default sequencer
    bool    grid_[kPatternSlots][kGridRows][kMaxGridSteps] = {};
    // NOTE LENGTH per start cell, in steps (0 or 1 = one step). Only the start
    // cell is "on" in grid_; the tail cells stay off and are owned by the note.
    uint8_t gridLen_[kPatternSlots][kGridRows][kMaxGridSteps] = {};
    // Steps each sequenced voice still has to ring (0 = not a grid note).
    int     seqHold_[kMaxVoices] = {};
    uint8_t colSwing_[kPatternSlots][kMaxGridSteps] = {};    // 0..4 ticks per column
    int     gridSteps_ = 32;                                 // 16 / 32 / 64 (default 32 = a 2-bar phrase)
    int     editSlot_  = 0;                                  // pattern slot the UI shows / edits (A/B/C/D)
    int     playSlot_  = 0;                                  // pattern slot the render thread fires
    void setPlaySlot(int slot)       { playSlot_ = clampr(slot, 0, kPatternSlots - 1); }

    // Pattern chain (song mode). chainLen_ == 0 means off.
    int     chain_[kMaxChain] = {};
    int     chainLen_      = 0;
    int     chainPos_      = 0;
    int     gridCycleStep_ = 0;   // steps elapsed in the current grid loop
    bool    isolate_       = false; // ISOLATE: loop the edit slot, keep (ignore) the chain
    // Deferred per-column swing fire.
    bool    gridPendingFire_ = false;
    float   gridFireDelay_   = 0.0f;
    int     gridPendingStep_ = 0;
    // Live/recorded root from the MIDI keyboard.
    int     liveRootMidi_ = -1;                              // lowest held note, or -1
    bool    recordArmed_  = false;
    int16_t recRoot_[kPatternSlots][kMaxGridSteps];          // -1 = none (init in prepare)
    int     gridOctave_ = 0;                                 // -2..+2 octave shift of the 8-row window
    bool    halfTone_  = false;                              // ♯ — nudge whole grid up a semitone

    uint32_t rng_ = 0xDEADBEEFu;
};

}
