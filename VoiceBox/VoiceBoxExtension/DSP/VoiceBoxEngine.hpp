//
//  VoiceBoxEngine.hpp
//
//  Vocal effects rack — effect "rows" in series, each independently
//  switchable, laid out to mirror the drum-machine UI:
//
//      AUTOTUNE → VOCODER → HARMONIZER → PITCH-SKIP → DELAY → CHOP → REVERB
//
//  Pitch effects (2026-11-20 rewrite, VoiceBox/AUDIO_QUALITY_PLAN.md):
//  ONE shared analysis — McLeod pitch tracker + pitch marks (Psola.hpp) —
//  drives four PSOLA synthesis voices, all read from the RAW input so every
//  path comes out exactly `latencySamples()` late:
//    voice 0 AUTOTUNE (stereo) · 1 HARMONIZER · 2 LOW TUNER · 3 PITCH-SKIP.
//  Shifts beyond ±12 st (harmony) / below −12 st (LOW) use the fixed STFT
//  shifter (PitchShifterHQ) as a fallback, delayed to the same latency.
//  AUTOTUNE: key root + scale, note hysteresis, retune time 0…399 ms, humanize;
//  consonants and breaths pass through (unvoiced marks are never shifted).
//  Effects fade in/out over 10 ms (no stale buffers, no clicks). The output
//  stage is linear up to −3 dBFS with a soft knee above it (no always-on
//  saturation, no 15 kHz low-pass).
//
//  2026-11-21 sound-quality pass (Tests/sq/run_sq.sh, HANDOFF §0):
//   • Output: the tanh knee at −3 dBFS (it sat BEFORE the reverb and bent every
//     hot vocal, even with all effects off) and the hard ±1.5 clamp are gone.
//     The rack is linear; one stereo-linked safety limiter (instant attack,
//     10 ms hold, 120 ms release, ceiling 0 dBFS) sits at the very end and does
//     nothing below 0 dBFS — "all off" is bit-exact.
//   • VOCODER: carrier and envelopes are level-independent (the old one was a
//     2:1 expander into a tanh: +10 dB on a normal vocal, −7 dB on a quiet
//     one), band envelopes are 12 ms RMS followers (instead of 0.04 / 1.4 ms,
//     which tracked single cycles → grit), consonants pass above the top band.
//   • REVERB: buffer lengths and damping scale with the sample rate, long rooms
//     are no longer louder than short ones.
//   • DELAY / CHOP / VOCODER / REVERB fade in and out and start from clean
//     buffers (they were hard switches that replayed stale tails); the delay
//     time glides; all mix knobs are smoothed (10 ms).
//   • Harmony / pitch-skip voices attenuate consonants so an "s" is not doubled.
//

#pragma once
#include "DSPCommon.hpp"
#include "PitchShifterHQ.hpp"
#include "Psola.hpp"
#include <vector>

namespace vbx {

// ── Crossfading delay-line pitch shifter (LO-FI character, currently unused) ─
// Two read taps half a window apart, triangular-windowed, so the buffer wrap
// is masked. ratio = 2^(semitones/12). Comb + warble by design — kept as an
// optional "LO-FI" colour; the clean path is the PSOLA engine.
struct PitchShifter {
    std::vector<float> buf;
    int   wpos = 0;
    int   len  = 0;
    float phase = 0.0f;
    float lpZ_  = 0.0f;   // output de-aliasing low-pass state
    void prepare(float sr) { len = (int)(0.060f * sr); buf.assign(len + 4, 0.0f); wpos = 0; phase = 0.0f; lpZ_ = 0.0f; }
    void reset() { std::fill(buf.begin(), buf.end(), 0.0f); wpos = 0; phase = 0.0f; lpZ_ = 0.0f; }
    inline float process(float x, float ratio) {
        if (buf.empty()) return x;
        const int N = (int)buf.size();
        buf[wpos] = x;
        phase += (1.0f - ratio) / (float)len;     // delay shrinks → pitch rises
        while (phase >= 1.0f) phase -= 1.0f;
        while (phase < 0.0f)  phase += 1.0f;
        float out = 0.0f;
        for (int k = 0; k < 2; ++k) {
            float ph = phase + (k ? 0.5f : 0.0f);
            if (ph >= 1.0f) ph -= 1.0f;
            const float delaySamp = ph * (float)(len - 1);
            float rp = (float)wpos - delaySamp;
            while (rp < 0) rp += (float)N;
            const int i0 = (int)rp;
            const int i1 = (i0 + 1) % N;
            const float fr = rp - (float)i0;
            const float s = buf[i0] + fr * (buf[i1] - buf[i0]);
            const float w = 0.5f * (1.0f - std::cos(2.0f * kPi * ph));  // raised-cosine crossfade (click-free)
            out += s * w;
        }
        if (++wpos >= N) wpos = 0;
        // Gentle LP tames the cheap shifter's aliasing grit (the "digital" edge).
        lpZ_ += 0.7f * (out - lpZ_);
        return lpZ_;
    }
};

// ── 16-band channel vocoder ─────────────────────────────────────────────
// Splits the voice (modulator) into log-spaced bands, follows each band's
// envelope, and imprints those envelopes onto the SAME bands of a carrier.
// The carrier is a saturated copy of the voice, so the vocoder tracks the
// singer's own pitch (robotic / Daft-Punk vowel sound) with no MIDI needed.
//
// 2026-11-21: gain staging. The carrier is made from the voice normalised to
// unit level (so its buzz is the same at −40 and at 0 dBFS), and every carrier
// band is divided by its own envelope before the voice's band envelope is put
// on it. The wet level therefore follows the input level 1:1 — before, the
// output went with the SQUARE of the input (carrier ∝ x, envelope ∝ x) into a
// tanh. The band envelopes are RMS followers with a 12 ms time constant at any
// sample rate (the old ones — 0.04 ms attack / 1.4 ms release at 48 kHz, half
// that at 96 kHz — followed single cycles, which is intermodulation = grit).
// The voice above the top band (≈ 6 kHz) passes straight through, so "s" and
// "t" stay intelligible and the wet signal keeps its air.
struct Vocoder {
    static const int N = 16;
    float sr = 48000.0f;
    struct Band { float mB=0,mL=0, cB=0,cL=0, env=0, cenv=0, g=0, k=0.18f, wDark=1, wFlat=1, wBright=1; } band[N];
    float env_ = 0.0017f, lvlAtt_ = 0.002f, lvlRel_ = 0.0001f;
    float lvl2_ = 0.0f, sB_ = 0.0f, sL_ = 0.0f, sG_ = 0.45f;
    void prepare(float s) {
        sr = s;
        const float lo = 150.0f, hi = 6500.0f;
        for (int i = 0; i < N; ++i) {
            const float t = (float)i / (float)(N - 1);
            const float fc = lo * std::pow(hi / lo, t);
            band[i].g = std::tan(kPi * fc / sr);
            band[i].k = 0.18f;                      // fairly narrow bands
            // TONE tilts the wet spectrum around 1 kHz: 0 = −3 dB/oct (dark), 0.5 = flat, 1 = +3 dB/oct (bright).
            // (Because every band is level-matched, the carrier's own brightness no longer sets the tone.)
            const float oct = std::log2(fc / 1000.0f);
            const float flat = 1.0f + 0.33f * clampf(std::log2(fc / 1500.0f), 0.0f, 1.0f);   // evens out the measured −2.5 dB dip above 3 kHz
            band[i].wFlat = flat; band[i].wDark = 0.66f * flat * std::pow(10.0f, -3.0f * oct / 20.0f); band[i].wBright = flat * std::pow(10.0f, 3.0f * oct / 20.0f);   // 0.66: same loudness when dark
        }
        env_ = 1.0f - std::exp(-1.0f / (0.012f * sr));
        lvlAtt_ = 1.0f - std::exp(-1.0f / (0.010f * sr)); lvlRel_ = 1.0f - std::exp(-1.0f / (0.250f * sr));
        sG_ = std::tan(kPi * std::min(6000.0f, 0.40f * sr) / sr);
        reset();
    }
    void reset() {
        for (int i = 0; i < N; ++i) band[i].mB = band[i].mL = band[i].cB = band[i].cL = band[i].env = band[i].cenv = 0;
        lvl2_ = 0.0f; sB_ = sL_ = 0.0f;
    }
    static inline float svfBP(float x, float& bp, float& lp, float g, float k) {
        const float hp = (x - (2.0f * k + g) * bp - lp) / (1.0f + 2.0f * k * g + g * g);
        const float b = g * hp + bp; const float l = g * b + lp;
        bp = g * hp + b; lp = g * b + l; return b;
    }
    /// Returns the WET signal only (the engine blends it with the dry voice).
    /// `tone` opens the carrier: 0 = soft, close to the voice … 1 = bright, buzzy.
    inline float process(float x, float tone) {
        // Carrier: the voice at unit level through a soft saturator.
        const float e2 = x * x;
        lvl2_ += (e2 > lvl2_ ? lvlAtt_ : lvlRel_) * (e2 - lvl2_);
        const float u = x / std::max(std::sqrt(lvl2_), 1e-4f);
        const float carrier = std::tanh(u * (0.30f + 0.70f * tone));
        const float tD = clampf(1.0f - 2.0f * tone, 0.0f, 1.0f), tB = clampf(2.0f * tone - 1.0f, 0.0f, 1.0f);
        float out = 0.0f;
        for (int i = 0; i < N; ++i) {
            Band& b = band[i];
            const float m = svfBP(x,       b.mB, b.mL, b.g, b.k);
            const float c = svfBP(carrier, b.cB, b.cL, b.g, b.k);
            b.env  += env_ * (m * m - b.env);         // band power of the voice …
            b.cenv += env_ * (c * c - b.cenv);        // … and of the carrier (12 ms, RMS-true)
            const float w = b.wFlat + tD * (b.wDark - b.wFlat) + tB * (b.wBright - b.wFlat);
            out += c * w * std::sqrt(b.env / (b.cenv + 1e-7f));   // carrier band at the voice band's level
        }
        // Consonants / air: the voice above the top band, untouched (2-pole high-pass).
        const float kq = 0.7071f;
        const float hp = (x - (2.0f * kq + sG_) * sB_ - sL_) / (1.0f + 2.0f * kq * sG_ + sG_ * sG_);
        const float bb = sG_ * hp + sB_, ll = sG_ * bb + sL_;
        sB_ = sG_ * hp + bb; sL_ = sG_ * bb + ll;
        return out * kMakeup + hp * (1.25f - 0.5f * tD + 0.6f * tB);
    }
    static constexpr float kMakeup = 0.182f;         // wet ≈ dry level on voice (measured: Tests/sq "samplerate … vocoder")
};

// ── Smooth stereo reverb (Freeverb-style: 8 damped combs + 4 allpass/ch) ──
// 2026-11-21: 8 combs / 4 all-passes (the classic Freeverb set; the first four
// combs and two all-passes are the old ones) instead of 4 / 2. With only four
// combs a held, hard-tuned note that sat on a comb resonance rang up to 5 dB
// louder in one channel than in the other ("metallic"); eight halve that.
// 2026-11-21: delay lengths and the damping filter are defined at 48 kHz and
// scaled to the session rate (at 96 kHz the room used to be half the size:
// RT60 0.32 s instead of 0.65 s). Above SIZE 0.5 half of the comb gain
// (1/√(1−fb²)) is taken back: SIZE 1 used to be 5–8 dB louder than 0.5.
struct Reverb {
    float sr = 48000.0f, fb = 0.84f, damp = 0.28f;
    struct Comb { std::vector<float> buf; int idx = 0; float lp = 0; };
    struct AP   { std::vector<float> buf; int idx = 0; };
    static const int kCombs = 8, kAPs = 4;
    Comb comb_[2][kCombs];
    AP   ap_[2][kAPs];
    void prepare(float s) {
        sr = s;
        const double k = (double)s / 48000.0;
        const int cl[kCombs] = {1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617};
        const int al[kAPs] = {556, 441, 341, 225};
        for (int ch = 0; ch < 2; ++ch) {
            for (int i = 0; i < kCombs; ++i) { comb_[ch][i].buf.assign((size_t)std::max(8L, std::lround((cl[i] + (ch ? 23 : 0)) * k)), 0.0f); comb_[ch][i].idx = 0; comb_[ch][i].lp = 0; }
            for (int i = 0; i < kAPs; ++i) { ap_[ch][i].buf.assign((size_t)std::max(4L, std::lround((al[i] + (ch ? 7 : 0)) * k)), 0.0f);   ap_[ch][i].idx = 0; }
        }
        damp = 1.0f - std::exp(-2.0f * kPi * 2510.0f / sr);      // = 0.28 at 48 kHz
    }
    void reset() {
        for (int ch = 0; ch < 2; ++ch) {
            for (auto& c : comb_[ch]) { std::fill(c.buf.begin(), c.buf.end(), 0.0f); c.idx = 0; c.lp = 0; }
            for (auto& a : ap_[ch])   { std::fill(a.buf.begin(), a.buf.end(), 0.0f); a.idx = 0; }
        }
    }
    /// Wet signal only (the engine blends it with the dry voice).
    inline void process(float inL, float inR, float size, float& wetL, float& wetR) {
        fb = 0.70f + clampf(size, 0.0f, 1.0f) * 0.275f;
        const float norm = std::min(1.0f, std::sqrt(std::sqrt((1.0f - fb * fb) * 3.3495f)));   // half (in dB) of the comb gain above SIZE 0.5; 3.3495 = 1/(1 − fb(0.5)²)
        const float in[2] = { inL, inR };
        float wet[2] = { 0, 0 };
        for (int ch = 0; ch < 2; ++ch) {
            float s = 0.0f;
            for (auto& c : comb_[ch]) {
                const int N = (int)c.buf.size();
                const float o = c.buf[c.idx];
                c.lp += damp * (o - c.lp);
                c.buf[c.idx] = in[ch] + c.lp * fb;
                if (++c.idx >= N) c.idx = 0;
                s += o;
            }
            s *= kCombGain;
            for (auto& a : ap_[ch]) {
                const int N = (int)a.buf.size();
                const float bo = a.buf[a.idx];
                const float y = -s + bo;
                a.buf[a.idx] = s + bo * 0.5f;
                if (++a.idx >= N) a.idx = 0;
                s = y;
            }
            wet[ch] = s * norm;
        }
        wetL = wet[0]; wetR = wet[1];
    }
    static constexpr float kCombGain = 0.089f;       // same wet level on voice as the old 4-comb set at SIZE 0.5 (measured)
};

// ── Key / scale helpers ─────────────────────────────────────────────────
namespace scales {
    static const int kMaj[7] = {0, 2, 4, 5, 7, 9, 11};
    static const int kMin[7] = {0, 2, 3, 5, 7, 8, 10};
    /// Nearest in-scale MIDI note. scale 0 chromatic, 1 major, 2 minor; key 0 = C … 11 = B.
    inline int snap(float midiF, int scale, int key) {
        const int n = (int)std::lround(midiF);
        if (scale <= 0) return n;
        const int* sc = scale == 2 ? kMin : kMaj;
        int best = n; float bestErr = 1e9f;
        for (int cand = n - 3; cand <= n + 3; ++cand) {
            const int rel = ((cand - key) % 12 + 12) % 12;
            bool in = false; for (int d = 0; d < 7; ++d) if (sc[d] == rel) in = true;
            if (!in) continue;
            const float e = std::fabs(midiF - (float)cand);
            if (e < bestErr) { bestErr = e; best = cand; }
        }
        return best;
    }
    /// Diatonic note `steps` scale-degrees above `midi` in key/scale.
    inline int diatonicUp(int midi, int steps, int key, bool minor) {
        const int* sc = minor ? kMin : kMaj;
        const int rel = ((midi - key) % 12 + 12) % 12;
        const int oct = (midi - key - rel) / 12;
        int deg = 0, bestd = 99;
        for (int d = 0; d < 7; ++d) { const int diff = std::abs(sc[d] - rel); if (diff < bestd) { bestd = diff; deg = d; } }
        int nd = deg + steps, addOct = 0;
        while (nd >= 7) { nd -= 7; ++addOct; }
        while (nd < 0)  { nd += 7; --addOct; }
        return key + (oct + addOct) * 12 + sc[nd];
    }
}

// ── AUTOTUNE control law (cents domain) ─────────────────────────────────
// Evaluated once per tracker hop. Target note with hysteresis:
//   • fast path — the raw pitch is > 35 c past the midpoint between the held
//     note and the new candidate (a real note change: switch at once);
//   • slow path — a vibrato-averaged pitch (one-pole, 50 ms) sits past the
//     midpoint for > 30 ms.
// So vibrato that brushes a semitone boundary no longer flips the target.
// Retune time τ = 400^speed − 1 ms (0 → hard … 0.3 → 5 ms … 0.7 → 65 ms … 1 → 399 ms);
// humanize lengthens τ on sustained notes: τ·(1 + 4·humanize·sustain).
// Unvoiced: the correction releases to 0 over 10 ms and the next note starts fresh.
struct TuneControl {
    float sr = 48000.0f; int hop = 128;
    int   scale = 0, key = 0;
    float speed = 0.3f, amount = 1.0f, humanize = 0.0f;
    bool  haveTarget = false; int target = 0;
    float slowMidi = 0.0f, pendingS = 0.0f, noteAge = 0.0f, corr = 0.0f;
    void prepare(float s, int h) { sr = s; hop = h; reset(); }
    void reset() { haveTarget = false; target = 0; slowMidi = 0; pendingS = 0; noteAge = 0; corr = 0; }
    void update(const TrackState& st) {
        const float dt = (float)hop / sr;
        if (!st.voiced) {
            haveTarget = false; noteAge = 0.0f; pendingS = 0.0f;
            corr += (0.0f - corr) * (1.0f - std::exp(-dt / 0.010f));
            return;
        }
        const float m = st.midi;
        if (!haveTarget) { target = scales::snap(m, scale, key); haveTarget = true; slowMidi = m; noteAge = 0; pendingS = 0; }
        slowMidi += (m - slowMidi) * (1.0f - std::exp(-dt / 0.050f));
        const int cand = scales::snap(m, scale, key);
        if (cand != target) {
            const float mid = 0.5f * (float)(target + cand);
            const float pastRaw  = cand > target ? m - mid : mid - m;
            const float pastSlow = cand > target ? slowMidi - mid : mid - slowMidi;
            if (pastRaw > 0.35f) { target = cand; noteAge = 0; pendingS = 0; }
            else if (pastSlow > 0.0f) { pendingS += dt; if (pendingS > 0.030f) { target = scales::snap(slowMidi, scale, key); noteAge = 0; pendingS = 0; } }
            else pendingS = 0.0f;
        } else pendingS = 0.0f;
        noteAge += dt;
        const float desired = ((float)target - m) * 100.0f * amount;
        float tauMs = std::pow(400.0f, speed) - 1.0f;
        const float sustain = clampf((noteAge - 0.120f) / 0.200f, 0.0f, 1.0f);
        tauMs *= 1.0f + 4.0f * humanize * sustain;
        if (tauMs < 0.05f) corr = desired;
        else corr += (desired - corr) * (1.0f - std::exp(-dt * 1000.0f / tauMs));
    }
};

// ── 10 ms engage/disengage ramp ─────────────────────────────────────────
struct Fade {
    float g = 0.0f, step = 1.0f / 480.0f;
    int   warm = 0;                       // hold at 0 until a freshly reset path has output
    void prepare(float sr, float seconds = 0.010f) { step = 1.0f / (seconds * sr); }
    inline void tick(bool want) {
        if (want && warm > 0) { --warm; return; }
        g = want ? std::min(1.0f, g + step) : std::max(0.0f, g - step);
    }
    bool live() const { return g > 0.0f; }
};

// ── Output safety limiter ───────────────────────────────────────────────
// Stereo-linked, instant attack, 10 ms hold, 120 ms release, ceiling 0 dBFS.
// Below the ceiling the gain is exactly 1 (bit-transparent). It replaces the
// tanh knee + hard clamp: gain reduction instead of wave-shaping, so sums that
// go over (harmony + delay + reverb on a hot vocal) stay clean.
struct SafetyLimiter {
    float g = 1.0f, rel = 0.00017f; int hold = 0, holdN = 480;
    void prepare(float sr) { holdN = std::max(1, (int)(0.010f * sr)); rel = 1.0f - std::exp(-1.0f / (0.120f * sr)); reset(); }
    void reset() { g = 1.0f; hold = 0; }
    inline void process(float& L, float& R) {
        const float pk = std::max(std::fabs(L), std::fabs(R));
        if (!(pk < 1.0e6f)) { L = R = 0.0f; return; }            // NaN / inf can never leave the plug-in
        if (pk * g > 1.0f) { g = 1.0f / pk; hold = holdN; }
        else if (g < 1.0f) {
            if (pk * g > 0.995f) hold = holdN;                   // still riding the ceiling: keep the gain steady
            else if (hold > 0) --hold;
            else { g += (1.0f - g) * rel; if (g > 0.99999f) g = 1.0f; }
        }
        if (g < 1.0f) { L *= g; R *= g; }
    }
};

// Fixed delay line (the STFT fallback is 1024 samples late; pad it to L).
struct DelayLine {
    std::vector<float> buf; int w = 0;
    void prepare(int n) { buf.assign((size_t)std::max(1, n), 0.0f); w = 0; }
    void reset() { std::fill(buf.begin(), buf.end(), 0.0f); w = 0; }
    inline float push(float v) { if (buf.size() <= 1) return v; const float o = buf[w]; buf[w] = v; if (++w >= (int)buf.size()) w = 0; return o; }
};

class VoiceBoxEngine {
public:
    enum { kVAuto = 0, kVHarm = 1, kVLow = 2, kVSkip = 3 };

    void prepare(float sr) {
        sr_ = sr;
        // Latency: one full STFT frame of the fallback shifter (1024 @ 44.1/48 kHz,
        // 2048 @ 88.2/96 kHz, 4096 above) so EVERY path can be aligned to it.
        L_ = std::max(PitchShifterHQ::frameFor(sr), (int)std::ceil(1024.0 * sr / 48000.0));
        core_.prepare(sr, L_);
        core_.setVoiceStereo(kVAuto, true);
        core_.setVoiceUnvoicedGain(kVHarm, 0.25f);    // a harmony does not double every "s"
        core_.setVoiceUnvoicedGain(kVSkip, 0.35f);
        tune_.prepare(sr, hopFor(sr));
        for (int ch = 0; ch < 2; ++ch) {
            delayBuf_[ch].assign((int)std::ceil(sr * 1.0f) + 4, 0.0f);
            delayW_[ch] = 0;
            voc_[ch].prepare(sr);
        }
        rev_.prepare(sr);
        hqHarm_.prepare(sr); hqHarm_.setFormantPreserve(true);
        hqLow_.prepare(sr);  hqLow_.setFormantPreserve(true);
        hqHarmDly_.prepare(L_ - hqHarm_.trueLatency());
        hqLowDly_.prepare(L_ - hqLow_.trueLatency());
        for (Fade* f : { &fAuto_, &fLowP_, &fLowH_, &fHarmP_, &fHarmH_, &fSkip_ }) { f->prepare(sr); f->g = 0.0f; f->warm = 0; }
        fVoc_.prepare(sr); fDly_.prepare(sr, 0.030f); fRev_.prepare(sr, 0.030f);
        for (Fade* f : { &fVoc_, &fDly_, &fRev_ }) { f->g = 0.0f; f->warm = 0; }
        vocClean_ = dlyClean_ = revClean_ = true;
        lim_.prepare(sr);
        smoothA_  = 1.0f - std::exp(-1.0f / (0.010f * sr));      // mix knobs: 10 ms
        dlyA_     = 1.0f - std::exp(-1.0f / (0.080f * sr));      // delay time glide: 80 ms
        chopA_    = 1.0f - std::exp(-1.0f / (0.00173f * sr));    // = 0.012 / sample at 48 kHz
        snap_ = true;
        lowHqRun_ = harmHqRun_ = false;
        chopPhase_ = 0; skipPhase_ = 0; skipCents_ = 0; skipTarget_ = 0; harmCents_ = 0;
        chopGain_ = 1.0f;
        rng_ = 0x1234abcdu;
        for (float& p : pc_) p = 0.0f;
    }
    void reset() {
        for (int ch = 0; ch < 2; ++ch) {
            std::fill(delayBuf_[ch].begin(), delayBuf_[ch].end(), 0.0f); delayW_[ch] = 0;
            voc_[ch].reset();
        }
        core_.reset(); tune_.reset();
        rev_.reset();
        hqHarm_.reset(); hqLow_.reset(); hqHarmDly_.reset(); hqLowDly_.reset();
        for (Fade* f : { &fAuto_, &fLowP_, &fLowH_, &fHarmP_, &fHarmH_, &fSkip_, &fVoc_, &fDly_, &fRev_ }) { f->g = 0.0f; f->warm = 0; }
        vocClean_ = dlyClean_ = revClean_ = true;
        lim_.reset(); snap_ = true;
        lowHqRun_ = harmHqRun_ = false;
        chopPhase_ = skipPhase_ = 0; skipCents_ = skipTarget_ = harmCents_ = 0; chopGain_ = 1.0f;
        for (float& p : pc_) p = 0.0f;
    }

    // ── Parameter setters ───────────────────────────────────────────────
    /// speed 0 hard … 1 slow (τ = 400^speed − 1 ms); scale 0 chrom/1 maj/2 min; key 0 = C … 11 = B.
    void setAutotune(bool on, float speed, float amount, float scale, float key = 0.0f, float humanize = 0.0f) {
        autoOn_ = on;
        tune_.speed = clampf(speed, 0.0f, 1.0f); tune_.amount = clampf(amount, 0.0f, 1.0f);
        tune_.scale = (int)(scale + 0.5f); tune_.key = ((int)(key + 0.5f) % 12 + 12) % 12;
        tune_.humanize = clampf(humanize, 0.0f, 1.0f);
    }
    /// LOW TUNER — 0…−12 st PSOLA (formants kept by construction), below −12 st the STFT fallback.
    void setLow(bool on, float semis, float mix) { lowOn_ = on; lowSemis_ = clampf(semis, -24.0f, 0.0f); lowMix_ = clampf(mix, 0.0f, 1.0f); }
    void setHarmonizer(bool on, float semis, float mix, bool autoKey) { harmOn_ = on; harmSemis_ = clampf(semis, -24.0f, 24.0f); harmMix_ = clampf(mix, 0.0f, 1.0f); harmAuto_ = autoKey; }
    void setDelay(bool on, float ms, float fb)          { delayOn_ = on; delayMs_ = clampf(ms, 1.0f, 1000.0f); delayFb_ = clampf(fb, 0.0f, 0.95f); }
    void setChop(bool on, float rateHz, float depth)    { if (on && !chopOn_) chopPhase_ = 0.0f; chopOn_ = on; chopRate_ = clampf(rateHz, 0.1f, 24.0f); chopDepth_ = clampf(depth, 0.0f, 1.0f); }
    void setSkip(bool on, float rateHz, float amount)   { skipOn_ = on; skipRate_ = clampf(rateHz, 0.5f, 16.0f); skipAmount_ = clampf(amount, 0.0f, 1.0f); }
    void setVocoder(bool on, float tone, float mix)     { vocOn_ = on; vocTone_ = clampf(tone, 0.0f, 1.0f); vocMix_ = clampf(mix, 0.0f, 1.0f); }
    void setReverb(bool on, float size, float mix)      { revOn_ = on; revSize_ = clampf(size, 0.0f, 1.0f); revMix_ = clampf(mix, 0.0f, 1.0f); }

    /// Constant latency of the whole rack in samples (report this to the host).
    int latencySamples() const { return L_; }

    // ── Read-only meter taps for the UI (2026-11-21, call from the audio thread
    //    once per block; the AU publishes them through atomics) ──────────────
    bool  meterVoiced() const { return core_.track().voiced; }
    /// Detected input pitch (fractional MIDI note, median-filtered).
    float meterMidi() const { return core_.track().midi; }
    /// AUTOTUNE target note (MIDI) or −1 when there is none.
    int   meterTarget() const { return tune_.haveTarget ? tune_.target : -1; }
    /// Correction currently applied to the lead voice, in cents (0 when AUTOTUNE is off).
    float meterCorrCents() const { return autoOn_ ? tune_.corr : 0.0f; }

    inline void processFrame(float& L, float& R) {
        core_.push(L, R);
        if (core_.frameReady()) updateControls();

        // Which pitch paths want to sound, and through which shifter.
        const bool lowHQ  = lowSemis_ < -12.0f;
        const bool harmHQ = !harmAuto_ && std::fabs(harmSemis_) > 12.0f;
        stepFade(fAuto_, autoOn_, kVAuto);
        stepFade(fLowP_, lowOn_ && !lowHQ, kVLow);
        stepFade(fHarmP_, harmOn_ && !harmHQ, kVHarm);
        stepFade(fSkip_, skipOn_, kVSkip);
        stepHQ(fLowH_, lowOn_ && lowHQ, hqLow_, hqLowDly_);
        stepHQ(fHarmH_, harmOn_ && harmHQ, hqHarm_, hqHarmDly_);

        // Smoothed mix controls (10 ms) — a knob move or host automation must not zipper.
        if (snap_) {
            lowMixS_ = lowMix_; harmMixS_ = harmMix_; skipAmtS_ = skipAmount_; vocMixS_ = vocMix_; vocToneS_ = vocTone_;
            revMixS_ = revMix_; revSizeS_ = revSize_; delayFbS_ = delayFb_; chopDepthS_ = chopDepth_;
            delaySampS_ = delayMs_ * 0.001f * sr_; snap_ = false;
        }
        lowMixS_   += smoothA_ * (lowMix_ - lowMixS_);     harmMixS_ += smoothA_ * (harmMix_ - harmMixS_);
        skipAmtS_  += smoothA_ * (skipAmount_ - skipAmtS_); vocMixS_  += smoothA_ * (vocMix_ - vocMixS_);
        vocToneS_  += smoothA_ * (vocTone_ - vocToneS_);    revMixS_  += smoothA_ * (revMix_ - revMixS_);
        revSizeS_  += smoothA_ * (revSize_ - revSizeS_);    delayFbS_ += smoothA_ * (delayFb_ - delayFbS_);
        chopDepthS_ += smoothA_ * (chopDepth_ - chopDepthS_);

        // Engage / disengage of the non-pitch effects: fade, and start from clean buffers.
        if (vocOn_ && !fVoc_.live() && !vocClean_) { voc_[0].reset(); voc_[1].reset(); vocClean_ = true; }
        fVoc_.tick(vocOn_); if (fVoc_.live()) vocClean_ = false;
        if (delayOn_ && !fDly_.live()) { if (!dlyClean_) { for (int ch = 0; ch < 2; ++ch) std::fill(delayBuf_[ch].begin(), delayBuf_[ch].end(), 0.0f); dlyClean_ = true; } delaySampS_ = delayMs_ * 0.001f * sr_; }
        fDly_.tick(delayOn_); if (fDly_.live()) dlyClean_ = false;
        if (revOn_ && !fRev_.live() && !revClean_) { rev_.reset(); revClean_ = true; }
        fRev_.tick(revOn_); if (fRev_.live()) revClean_ = false;
        if (fDly_.live()) delaySampS_ += dlyA_ * (delayMs_ * 0.001f * sr_ - delaySampS_);
        // Chop gate (one LFO for both channels); when switched off the gain glides back to 1.
        const bool chopLive = chopOn_ || chopGain_ < 0.9999f;
        if (chopLive) {
            float target = 1.0f;
            if (chopOn_) {
                chopPhase_ += chopRate_ / sr_;
                if (chopPhase_ >= 1.0f) chopPhase_ -= 1.0f;
                target = (chopPhase_ < 0.5f) ? 1.0f : (1.0f - chopDepthS_);
            }
            chopGain_ += chopA_ * (target - chopGain_);
        } else chopGain_ = 1.0f;

        // Lead voice: dry (delayed by L) ↔ autotuned, crossfaded.
        float io[2] = { core_.dryL(), core_.dryR() };
        if (fAuto_.live()) {
            float al, ar; core_.renderStereo(kVAuto, al, ar);
            io[0] += (al - io[0]) * fAuto_.g; io[1] += (ar - io[1]) * fAuto_.g;
        }
        // Mono pitch voices (all aligned to the same latency).
        float lowOut = 0.0f, lowW = 0.0f;
        if (fLowP_.live()) { lowOut += fLowP_.g * core_.renderMono(kVLow); lowW += fLowP_.g; }
        if (fLowH_.live() || (lowOn_ && lowHQ)) { const float h = hqLowDly_.push(hqLow_.process(core_.newestM(), centsToRatio(lowCents_))); lowOut += fLowH_.g * h; lowW += fLowH_.g; }
        float harmOut = 0.0f, harmW = 0.0f;
        if (fHarmP_.live()) { harmOut += fHarmP_.g * core_.renderMono(kVHarm); harmW += fHarmP_.g; }
        if (fHarmH_.live() || (harmOn_ && harmHQ)) { const float h = hqHarmDly_.push(hqHarm_.process(core_.newestM(), centsToRatio(harmFixedCents_))); harmOut += fHarmH_.g * h; harmW += fHarmH_.g; }
        float skipOut = fSkip_.live() ? core_.renderMono(kVSkip) : 0.0f;

        const int dN = (int)delayBuf_[0].size();
        const float dSamp = std::max(1.0f, std::min((float)(dN - 3), delaySampS_));
        const int   dInt = (int)dSamp; const float dFr = dSamp - (float)dInt;
        for (int ch = 0; ch < 2; ++ch) {
            float x = io[ch];
            // 1.2) LOW TUNER — replace (mix 1) or blend the lead with the lowered voice.
            if (lowW > 0.0f) x += (lowOut - lowW * x) * lowMixS_;
            // 1.5) VOCODER — wet/dry blend, faded in and out over 10 ms.
            if (fVoc_.live()) { const float wet = voc_[ch].process(x, vocToneS_); x += (wet - x) * (vocMixS_ * fVoc_.g); }
            // 2) HARMONIZER — add the harmony voice (same mixing law as before).
            if (harmW > 0.0f) x = x * (1.0f - 0.4f * harmMixS_ * harmW) + harmOut * harmMixS_;
            // 3) PITCH-SKIP — sample-and-hold pitch jumps, blended in.
            if (fSkip_.live()) { const float a = skipAmtS_ * 0.8f * fSkip_.g; x = x * (1.0f - a) + skipOut * a; }
            // 5) DELAY — the time glides (interpolated read), the echo level fades with the switch.
            if (fDly_.live()) {
                std::vector<float>& b = delayBuf_[ch];
                int r0 = delayW_[ch] - dInt; if (r0 < 0) r0 += dN;
                int r1 = r0 - 1; if (r1 < 0) r1 += dN;
                const float wet = b[r0] + dFr * (b[r1] - b[r0]);
                b[delayW_[ch]] = x * fDly_.g + wet * delayFbS_;      // the feed fades too: no echo of a hard start
                if (++delayW_[ch] >= dN) delayW_[ch] = 0;
                x = x + wet * 0.7f * fDly_.g;
            }
            // 6) CHOP
            if (chopLive) x *= chopGain_;
            io[ch] = x;
        }
        // 7) REVERB — wet/dry blend, faded with the switch.
        if (fRev_.live()) {
            float wl, wr; rev_.process(io[0] * fRev_.g, io[1] * fRev_.g, revSizeS_, wl, wr);   // the send fades too
            const float m = revMixS_ * fRev_.g;
            io[0] += (wl - io[0]) * m; io[1] += (wr - io[1]) * m;
        }
        // Output: linear; the safety limiter only acts above 0 dBFS.
        lim_.process(io[0], io[1]);
        L = io[0];
        R = io[1];
    }

private:
    static int hopFor(float sr) { return sr <= 50000.0f ? 128 : (sr <= 100000.0f ? 256 : 512); }
    static inline float centsToRatio(float c) { return std::exp2(c / 1200.0f); }

    void stepFade(Fade& f, bool want, int voice) {
        if (want && !f.live() && !core_.voiceActive(voice)) core_.setVoiceActive(voice, true);
        f.tick(want);
        if (!want && !f.live() && core_.voiceActive(voice)) core_.setVoiceActive(voice, false);
    }
    void stepHQ(Fade& f, bool want, PitchShifterHQ& hq, DelayLine& dl) {
        if (want && !f.live() && f.warm == 0 && !hqRunning(f)) { hq.reset(); dl.reset(); f.warm = L_; setHqRunning(f, true); }
        f.tick(want);
        if (!want && !f.live()) setHqRunning(f, false);
    }
    bool hqRunning(const Fade& f) const { return &f == &fLowH_ ? lowHqRun_ : harmHqRun_; }
    void setHqRunning(const Fade& f, bool on) { if (&f == &fLowH_) lowHqRun_ = on; else harmHqRun_ = on; }

    // Once per tracker hop: autotune law, then every voice's correction (cents).
    void updateControls() {
        const TrackState& st = core_.track();
        tune_.update(st);
        const float atC = tune_.corr * fAuto_.g;      // follows the 10 ms engage fade
        const float dt = (float)hopFor(sr_) / sr_;
        // Auto key (Krumhansl) from the voiced pitch-class histogram.
        if (st.voiced) {
            for (float& p : pc_) p *= std::exp(-dt / 0.8f);
            pc_[(((int)std::lround(st.midi)) % 12 + 12) % 12] += dt;
            static const float MAJ[12] = {6.35f,2.23f,3.48f,2.33f,4.38f,4.09f,2.52f,5.19f,2.39f,3.66f,2.29f,2.88f};
            static const float MIN[12] = {6.33f,2.68f,3.52f,5.38f,2.60f,3.53f,2.54f,4.75f,3.98f,2.69f,3.34f,3.17f};
            float best = -1e9f;
            for (int root = 0; root < 12; ++root) {
                float cM = 0, cm = 0;
                for (int i = 0; i < 12; ++i) { const float h = pc_[(i + root) % 12]; cM += h * MAJ[i]; cm += h * MIN[i]; }
                if (cM > best) { best = cM; autoKey_ = root; autoMinor_ = false; }
                if (cm > best) { best = cm; autoKey_ = root; autoMinor_ = true; }
            }
        }
        // Harmony: in-key third above (AUTO) or a fixed interval, relative to the raw input.
        if (harmAuto_ && st.voiced) {
            const bool userKey = tune_.scale == 1 || tune_.scale == 2;
            const int key = userKey ? tune_.key : autoKey_;
            const bool minor = userKey ? tune_.scale == 2 : autoMinor_;
            const int ref = (autoOn_ && tune_.haveTarget) ? tune_.target : (int)std::lround(st.midi);
            const float target = ((float)scales::diatonicUp(ref, 2, key, minor) - st.midi) * 100.0f;
            harmCents_ += (target - harmCents_) * (1.0f - std::exp(-dt / 0.008f));
        } else if (!harmAuto_) {
            harmCents_ = harmSemis_ * 100.0f + atC;
        }
        harmFixedCents_ = harmSemis_ * 100.0f + atC;
        lowCents_ = lowSemis_ * 100.0f + atC;
        // Pitch-skip: sample-and-hold steps, 5 ms ramp.
        skipPhase_ += skipRate_ * dt;
        if (skipPhase_ >= 1.0f) {
            skipPhase_ -= 1.0f;
            static const float steps[7] = {-12, -7, -5, 0, 5, 7, 12};
            skipTarget_ = steps[(unsigned)(fastNoise(rng_) * 3.5f + 3.5f) % 7] * skipAmount_ * 100.0f;
        }
        skipCents_ += (skipTarget_ - skipCents_) * (1.0f - std::exp(-dt / 0.005f));
        core_.setVoiceCents(kVAuto, atC);
        core_.setVoiceCents(kVHarm, harmCents_);
        core_.setVoiceCents(kVLow, lowCents_);
        core_.setVoiceCents(kVSkip, skipCents_ + atC);
    }

    float sr_ = 48000.0f;
    int   L_ = 1024;
    PsolaCore core_;
    TuneControl tune_;
    Fade  fAuto_, fLowP_, fLowH_, fHarmP_, fHarmH_, fSkip_;
    Fade  fVoc_, fDly_, fRev_;
    bool  vocClean_ = true, dlyClean_ = true, revClean_ = true;
    SafetyLimiter lim_;
    // Smoothed controls
    bool  snap_ = true;
    float smoothA_ = 0.002f, dlyA_ = 0.00026f, chopA_ = 0.012f;
    float lowMixS_ = 1.0f, harmMixS_ = 0.4f, skipAmtS_ = 0.5f, vocMixS_ = 0.7f, vocToneS_ = 0.5f;
    float revMixS_ = 0.3f, revSizeS_ = 0.5f, delayFbS_ = 0.35f, chopDepthS_ = 0.8f, delaySampS_ = 12000.0f;
    bool  lowHqRun_ = false, harmHqRun_ = false;
    // AUTOTUNE
    bool  autoOn_ = false;
    // HARMONIZER
    bool  harmOn_ = false; float harmSemis_ = 7.0f, harmMix_ = 0.4f; bool harmAuto_ = false;
    float harmCents_ = 0.0f, harmFixedCents_ = 0.0f;
    PitchShifterHQ hqHarm_; DelayLine hqHarmDly_;
    float pc_[12] = {0}; int autoKey_ = 0; bool autoMinor_ = false;
    // LOW TUNER
    bool  lowOn_ = false; float lowSemis_ = -5.0f, lowMix_ = 1.0f, lowCents_ = -500.0f;
    PitchShifterHQ hqLow_; DelayLine hqLowDly_;
    // PITCH-SKIP
    bool  skipOn_ = false; float skipRate_ = 4.0f, skipAmount_ = 0.5f;
    float skipPhase_ = 0.0f, skipCents_ = 0.0f, skipTarget_ = 0.0f;
    uint32_t rng_ = 0x1234abcdu;
    // DELAY
    bool  delayOn_ = false; float delayMs_ = 250.0f, delayFb_ = 0.35f;
    std::vector<float> delayBuf_[2]; int delayW_[2] = {0, 0};
    // CHOP
    bool  chopOn_ = false; float chopRate_ = 8.0f, chopDepth_ = 0.8f;
    float chopPhase_ = 0.0f, chopGain_ = 1.0f;
    // VOCODER (per channel)
    bool  vocOn_ = false; float vocTone_ = 0.5f, vocMix_ = 0.7f;
    Vocoder voc_[2];
    // REVERB (stereo)
    bool  revOn_ = false; float revSize_ = 0.5f, revMix_ = 0.3f;
    Reverb rev_;
};

} // namespace vbx
