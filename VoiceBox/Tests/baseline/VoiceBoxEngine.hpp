//
//  VoiceBoxEngine.hpp
//
//  Vocal effects rack — effect "rows" in series, each independently
//  switchable, laid out to mirror the drum-machine UI:
//
//      AUTOTUNE → VOCODER → HARMONIZER → PITCH-SKIP → DELAY → CHOP → REVERB
//
//  AUTOTUNE = monophonic pitch detector (autocorrelation, à la YIN) + a
//  formant-preserving phase-vocoder pitch shifter that snaps the detected
//  pitch to the nearest note in the chosen scale, with a RETUNE-SPEED control
//  (instant = robotic / T-Pain, slow = natural). Harmonizer & pitch-skip
//  share a simple crossfading delay-line pitch shifter. Everything is
//  per-sample, stereo, real-time-safe (buffers allocated in prepare()).
//
//  Distortion has been deliberately tamed throughout (gentler drive on the
//  vocoder carrier, softer always-on "glue") so the rack sounds clean rather
//  than artificial. FLANGER and WARMTH have been removed.
//

#pragma once
#include "DSPCommon.hpp"
#include "PitchShifterHQ.hpp"
#include <vector>

namespace vbx {

// ── Crossfading delay-line pitch shifter ────────────────────────────────
// Two read taps half a window apart, triangular-windowed, so the buffer wrap
// is masked. ratio = 2^(semitones/12). Cheap and characterful (not hi-fi) —
// exactly the "raw" vibe we want.
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
// The carrier is a heavily-saturated copy of the voice, so the vocoder
// tracks the singer's own pitch (robotic / Daft-Punk vowel sound) with no
// MIDI needed. More bands + smoothed envelopes = the "smooth" we want.
struct Vocoder {
    static const int N = 16;
    float sr = 48000.0f;
    struct Band { float mB=0,mL=0, cB=0,cL=0, env=0, g=0, k=0.18f; } band[N];
    void prepare(float s) {
        sr = s;
        const float lo = 150.0f, hi = 6500.0f;
        for (int i = 0; i < N; ++i) {
            const float t = (float)i / (float)(N - 1);
            const float fc = lo * std::pow(hi / lo, t);
            band[i].g = std::tan(kPi * fc / sr);
            band[i].k = 0.18f;                      // fairly narrow bands
            band[i].mB = band[i].mL = band[i].cB = band[i].cL = band[i].env = 0;
        }
    }
    void reset() { for (int i = 0; i < N; ++i) band[i].mB = band[i].mL = band[i].cB = band[i].cL = band[i].env = 0; }
    static inline float svfBP(float x, float& bp, float& lp, float g, float k) {
        const float hp = (x - (2.0f * k + g) * bp - lp) / (1.0f + 2.0f * k * g + g * g);
        const float b = g * hp + bp; const float l = g * b + lp;
        bp = g * hp + b; lp = g * b + l; return b;
    }
    inline float process(float x, float tone, float mix) {
        // Carrier = a band-limited sawtooth-ish buzz derived from the voice,
        // but driven GENTLY so the vocoder stays clean/musical rather than a
        // fizzy fuzz-box. `tone` opens the carrier's brightness, not its drive.
        const float drive = 1.6f + tone * 2.4f;       // was 3..12 (way too hot)
        const float carrier = std::tanh(x * drive) * 0.85f;
        float out = 0.0f;
        for (int i = 0; i < N; ++i) {
            Band& b = band[i];
            const float m = svfBP(x,       b.mB, b.mL, b.g, b.k);
            const float c = svfBP(carrier, b.cB, b.cL, b.g, b.k);
            const float rect = std::fabs(m);
            // Fast attack, slow release envelope follower → smooth, no buzz.
            const float coeff = (rect > b.env) ? 0.40f : 0.015f;
            b.env += coeff * (rect - b.env);
            out += c * b.env;
        }
        out *= 2.0f;                                  // makeup (was 2.6 — calmer)
        // Soft-limit only the peaks; below ~0.7 the path stays linear/clean.
        out = (out > 0.0f) ? std::tanh(out * 0.85f) / 0.85f
                           : std::tanh(out * 0.85f) / 0.85f;
        return x * (1.0f - mix) + out * mix;
    }
};

// ── Smooth stereo reverb (Freeverb-style: 4 damped combs + 2 allpass/ch) ──
struct Reverb {
    float sr = 48000.0f, fb = 0.84f, damp = 0.28f;
    struct Comb { std::vector<float> buf; int idx = 0; float lp = 0; };
    struct AP   { std::vector<float> buf; int idx = 0; };
    Comb comb_[2][4];
    AP   ap_[2][2];
    void prepare(float s) {
        sr = s;
        const int cl[4] = {1116, 1188, 1277, 1356};
        const int al[2] = {556, 441};
        for (int ch = 0; ch < 2; ++ch) {
            for (int i = 0; i < 4; ++i) { comb_[ch][i].buf.assign(cl[i] + (ch ? 23 : 0), 0.0f); comb_[ch][i].idx = 0; comb_[ch][i].lp = 0; }
            for (int i = 0; i < 2; ++i) { ap_[ch][i].buf.assign(al[i] + (ch ? 7 : 0), 0.0f);   ap_[ch][i].idx = 0; }
        }
    }
    void reset() {
        for (int ch = 0; ch < 2; ++ch) {
            for (auto& c : comb_[ch]) { std::fill(c.buf.begin(), c.buf.end(), 0.0f); c.idx = 0; c.lp = 0; }
            for (auto& a : ap_[ch])   { std::fill(a.buf.begin(), a.buf.end(), 0.0f); a.idx = 0; }
        }
    }
    inline void process(float& L, float& R, float size, float mix) {
        fb = 0.70f + clampf(size, 0.0f, 1.0f) * 0.275f;
        const float in[2] = { L, R };
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
            s *= 0.25f;
            for (auto& a : ap_[ch]) {
                const int N = (int)a.buf.size();
                const float bo = a.buf[a.idx];
                const float y = -s + bo;
                a.buf[a.idx] = s + bo * 0.5f;
                if (++a.idx >= N) a.idx = 0;
                s = y;
            }
            wet[ch] = s;
        }
        L = L * (1.0f - mix) + wet[0] * mix;
        R = R * (1.0f - mix) + wet[1] * mix;
    }
};

// ── Intelligent harmony brain ───────────────────────────────────────────
// Hop-based monophonic pitch tracker (autocorrelation) + automatic key
// detection (decaying pitch-class histogram correlated against Krumhansl
// major/minor profiles) + diatonic harmony (a third up, in key) that moves
// per note. Analysis runs once per ANALYZE-sample hop (not per sample) and is
// only driven when AUTO is engaged — so it's cheap and off-cost-free.
struct SmartHarmony {
    float sr = 48000.0f;
    static const int BUF = 2048;
    float buf[BUF]; int wpos = 0; int hop = 0;
    float pc[12] = {0};
    int   keyRoot = 0; bool keyMinor = false;
    float ratioTarget = 1.0f, ratioSmooth = 1.0f;
    void prepare(float s) { sr = s; reset(); }
    void reset() { wpos = 0; hop = 0; for (int i = 0; i < 12; ++i) pc[i] = 0; keyRoot = 0; keyMinor = false; ratioTarget = ratioSmooth = 1.0f; }
    inline float ratio() const { return ratioSmooth; }
    inline void push(float x) {
        buf[wpos] = x; if (++wpos >= BUF) wpos = 0;
        if (++hop >= 2048) { hop = 0; analyze(); }
        ratioSmooth += 0.003f * (ratioTarget - ratioSmooth);   // glide, no zipper
    }
    // Diatonic note `steps` scale-degrees above `midi` in the current key.
    int diatonicUp(int midi, int steps) const {
        static const int maj[7] = {0,2,4,5,7,9,11};
        static const int min[7] = {0,2,3,5,7,8,10};
        const int* sc = keyMinor ? min : maj;
        const int rel = ((midi - keyRoot) % 12 + 12) % 12;
        const int oct = (midi - keyRoot - rel) / 12;
        int deg = 0, bestd = 99;
        for (int d = 0; d < 7; ++d) { int diff = std::abs(sc[d] - rel); if (diff < bestd) { bestd = diff; deg = d; } }
        int nd = deg + steps, addOct = 0;
        while (nd >= 7) { nd -= 7; ++addOct; }
        while (nd < 0)  { nd += 7; --addOct; }
        return keyRoot + (oct + addOct) * 12 + sc[nd];
    }
    void analyze() {
        float w[BUF];
        for (int i = 0; i < BUF; ++i) w[i] = buf[(wpos + i) % BUF];
        float energy = 0; for (int i = 0; i < BUF; ++i) energy += w[i] * w[i];
        if (energy < 1e-4f) return;                      // silence: hold last
        const int minLag = (int)(sr / 1000.0f);
        const int maxLag = std::min(BUF - 1, (int)(sr / 80.0f));
        float bestCorr = 0; int bestLag = 0;
        for (int lag = minLag; lag <= maxLag; ++lag) {
            float c = 0;
            for (int i = 0; i + lag < BUF; ++i) c += w[i] * w[i + lag];
            if (c > bestCorr) { bestCorr = c; bestLag = lag; }
        }
        if (bestLag <= 0) return;
        const float hz = sr / (float)bestLag;
        if (hz < 70.0f || hz > 1100.0f) return;
        const float midiF = 69.0f + 12.0f * std::log2(hz / 440.0f);
        const int   inNote = (int)std::lround(midiF);
        const int   pcIdx = ((inNote % 12) + 12) % 12;
        for (int i = 0; i < 12; ++i) pc[i] *= 0.95f;
        pc[pcIdx] += 1.0f;
        // Krumhansl key estimate
        static const float MAJ[12] = {6.35f,2.23f,3.48f,2.33f,4.38f,4.09f,2.52f,5.19f,2.39f,3.66f,2.29f,2.88f};
        static const float MIN[12] = {6.33f,2.68f,3.52f,5.38f,2.60f,3.53f,2.54f,4.75f,3.98f,2.69f,3.34f,3.17f};
        float best = -1e9f; int br = 0; bool bm = false;
        for (int root = 0; root < 12; ++root) {
            float cM = 0, cm = 0;
            for (int i = 0; i < 12; ++i) { const float h = pc[(i + root) % 12]; cM += h * MAJ[i]; cm += h * MIN[i]; }
            if (cM > best) { best = cM; br = root; bm = false; }
            if (cm > best) { best = cm; br = root; bm = true; }
        }
        keyRoot = br; keyMinor = bm;
        // Diatonic third above, in key → moving ratio.
        const int harmNote = diatonicUp(inNote, 2);
        ratioTarget = clampf(std::pow(2.0f, ((float)harmNote - midiF) / 12.0f), 0.5f, 2.0f);
    }
};

// ── AUTOTUNE — monophonic pitch correction ──────────────────────────────
// Real-time recipe (confirmed against the standard YIN + PSOLA approach):
//   1) Detect the input pitch with a YIN-style cumulative-mean-normalised
//      difference function (autocorrelation family) on a sliding window.
//   2) Snap the detected MIDI note to the nearest note in the chosen scale
//      (chromatic / major / minor).
//   3) Glide the correction ratio toward the target at "retune speed"
//      (fast = robotic T-Pain, slow = transparent) and apply it with a
//      formant-preserving phase-vocoder shifter (so it never chipmunks).
// Analysis runs once per hop; the shift runs per sample. Mono (one voice).
struct AutoTune {
    float sr = 48000.0f;
    static const int BUF = 1536;          // ~32 ms @48k — enough for ~80 Hz
    float buf[BUF]; int wpos = 0; int hop = 0;
    float detectedHz = 0.0f;
    float ratioTarget = 1.0f, ratioSmooth = 1.0f;
    int   scale = 0;                       // 0 chromatic, 1 major, 2 minor
    float speed = 0.5f;                    // 0 instant .. 1 slow
    float strength = 1.0f;                 // correction amount / wet
    PitchShifterHQ shifter;                // formant-preserving, shared per voice

    void prepare(float s) { sr = s; shifter.prepare(s); shifter.setFormantPreserve(true); reset(); }
    void reset() {
        wpos = 0; hop = 0; detectedHz = 0.0f;
        ratioTarget = ratioSmooth = 1.0f;
        for (int i = 0; i < BUF; ++i) buf[i] = 0.0f;
        shifter.reset();
    }
    void setParams(float retuneSpeed, float amount, int scl) {
        speed = clampf(retuneSpeed, 0.0f, 1.0f);
        strength = clampf(amount, 0.0f, 1.0f);
        scale = scl;
    }

    // Nearest in-scale MIDI note to a (fractional) midi pitch.
    static int snapToScale(float midiF, int scale) {
        const int n = (int)std::lround(midiF);
        if (scale == 0) return n;                       // chromatic
        static const int maj[7] = {0,2,4,5,7,9,11};
        static const int min[7] = {0,2,3,5,7,8,10};
        const int* sc = (scale == 2) ? min : maj;
        // search the candidate's octave and neighbours for the closest degree
        int best = n; float bestErr = 1e9f;
        for (int oct = -1; oct <= 1; ++oct) {
            const int base = (n / 12 + oct) * 12;
            for (int d = 0; d < 7; ++d) {
                const int cand = base + sc[d];
                const float e = std::fabs(midiF - (float)cand);
                if (e < bestErr) { bestErr = e; best = cand; }
            }
        }
        return best;
    }

    // YIN-style pitch detection on the most-recent window. Returns Hz or 0.
    float yinD_[BUF/2 + 1] = {};
    float yinC_[BUF/2 + 1] = {};
    float detectPitch() {
        // Copy newest-first into a linear window.
        float w[BUF];
        for (int i = 0; i < BUF; ++i) w[i] = buf[(wpos + i) % BUF];
        float energy = 0; for (int i = 0; i < BUF; ++i) energy += w[i] * w[i];
        if (energy < 5e-4f) return 0.0f;                // silence → hold

        const int maxLag = std::min(BUF / 2, (int)(sr / 70.0f));   // down to 70 Hz
        const int minLag = std::max(2,       (int)(sr / 1000.0f)); // up to 1 kHz
        // Difference function d(tau). (Instance members — these were `static`
        // and two VoiceBoxes on parallel render threads overwrote each other.)
        float *d = yinD_;
        d[0] = 0.0f;
        for (int tau = 1; tau <= maxLag; ++tau) {
            float sum = 0.0f;
            for (int i = 0; i + tau < BUF; ++i) { const float diff = w[i] - w[i + tau]; sum += diff * diff; }
            d[tau] = sum;
        }
        // Cumulative mean normalised difference (the YIN trick).
        float *cmnd = yinC_;
        cmnd[0] = 1.0f; float run = 0.0f;
        for (int tau = 1; tau <= maxLag; ++tau) { run += d[tau]; cmnd[tau] = (run > 0) ? d[tau] * (float)tau / run : 1.0f; }
        // Absolute-threshold pick: first local min below 0.15, else global min.
        const float thresh = 0.15f;
        int bestTau = -1;
        for (int tau = minLag; tau <= maxLag; ++tau) {
            if (cmnd[tau] < thresh) {
                while (tau + 1 <= maxLag && cmnd[tau + 1] < cmnd[tau]) ++tau;
                bestTau = tau; break;
            }
        }
        if (bestTau < 0) {
            float best = 1e9f;
            for (int tau = minLag; tau <= maxLag; ++tau) if (cmnd[tau] < best) { best = cmnd[tau]; bestTau = tau; }
            if (bestTau < 0 || best > 0.4f) return 0.0f;   // unvoiced
        }
        // Parabolic interpolation around the trough for sub-sample accuracy.
        float tauF = (float)bestTau;
        if (bestTau > minLag && bestTau < maxLag) {
            const float a = cmnd[bestTau - 1], b = cmnd[bestTau], c = cmnd[bestTau + 1];
            const float denom = a + c - 2.0f * b;
            if (std::fabs(denom) > 1e-9f) {
                const float corr = 0.5f * (a - c) / denom;           // a flat trough could throw this by thousands
                tauF = (float)bestTau + std::max(-1.0f, std::min(1.0f, corr));
            }
        }
        return sr / tauF;
    }

    void analyze() {
        const float hz = detectPitch();
        if (hz < 70.0f || hz > 1100.0f) return;          // out of vocal range → hold
        detectedHz = hz;
        const float midiF  = 69.0f + 12.0f * std::log2(hz / 440.0f);
        const int   target = snapToScale(midiF, scale);
        // Correction ratio toward the snapped note, scaled by strength.
        const float fullSemis = (float)target - midiF;
        const float semis = fullSemis * strength;        // strength 0 → no shift
        ratioTarget = clampf(std::pow(2.0f, semis / 12.0f), 0.5f, 2.0f);
    }

    // Feed one sample; returns the autotuned sample.
    inline float process(float x) {
        buf[wpos] = x; if (++wpos >= BUF) wpos = 0;
        if (++hop >= 256) { hop = 0; analyze(); }        // ~5 ms refresh
        // Retune speed: instant (≈0.5 glide coeff) → slow (≈0.0008).
        const float glide = 0.5f * std::pow(0.0016f, speed);   // 0.5 .. ~0.0008
        ratioSmooth += glide * (ratioTarget - ratioSmooth);
        return shifter.process(x, ratioSmooth);
    }
};

class VoiceBoxEngine {
public:
    void prepare(float sr) {
        sr_ = sr;
        for (int ch = 0; ch < 2; ++ch) {
            delayBuf_[ch].assign((int)std::ceil(sr * 1.0f) + 4, 0.0f);  // up to 1 s
            delayW_[ch] = 0;
            harm_[ch].prepare(sr);
            skip_[ch].prepare(sr);
            glueLP_[ch].reset(); glueLP_[ch].setCutoff(15000.0f, sr);
            voc_[ch].prepare(sr);
        }
        autotune_.prepare(sr);
        rev_.prepare(sr);
        smart_.prepare(sr);
        hq_.prepare(sr); hqOut_ = 0.0f;
        low_.prepare(sr); low_.setFormantPreserve(true); lowOut_ = 0.0f;
        chopPhase_ = 0; skipPhase_ = 0; skipRatio_ = 1.0f;
        chopGain_ = 1.0f;
        rng_ = 0x1234abcdu;
    }
    void reset() {
        for (int ch = 0; ch < 2; ++ch) {
            std::fill(delayBuf_[ch].begin(), delayBuf_[ch].end(), 0.0f); delayW_[ch] = 0;
            harm_[ch].reset(); skip_[ch].reset(); glueLP_[ch].reset();
            voc_[ch].reset();
        }
        autotune_.reset();
        rev_.reset();
        smart_.reset();
        hq_.reset(); hqOut_ = 0.0f;
        low_.reset(); lowOut_ = 0.0f;
        latDly_[0].reset(); latDly_[1].reset();
        chopPhase_ = skipPhase_ = 0; skipRatio_ = 1.0f; chopGain_ = 1.0f;
    }

    // ── Parameter setters ───────────────────────────────────────────────
    void setAutotune(bool on, float speed, float amount, float scale) {
        autoOn_ = on;
        autotune_.setParams(clampf(speed, 0.0f, 1.0f), clampf(amount, 0.0f, 1.0f), (int)(scale + 0.5f));
    }
    /// LOW TUNER — a clean downward pitch shift for the main voice. Uses the
    /// formant-preserving phase vocoder (spectral envelope kept, pitch moved),
    /// so the voice gets deeper without the slowed-tape / chipmunk-in-reverse
    /// colour a plain resampler gives. semis 0 … −24.
    void setLow(bool on, float semis, float mix) {
        lowOn_ = on; lowRatio_ = std::pow(2.0f, clampf(semis, -24.0f, 0.0f) / 12.0f); lowMix_ = clampf(mix, 0.0f, 1.0f);
    }
    void setHarmonizer(bool on, float semis, float mix, bool autoKey) { harmOn_ = on; harmRatio_ = std::pow(2.0f, clampf(semis, -24.0f, 24.0f) / 12.0f); harmMix_ = clampf(mix, 0.0f, 1.0f); harmAuto_ = autoKey; }
    void setDelay(bool on, float ms, float fb)          { delayOn_ = on; delayMs_ = clampf(ms, 1.0f, 1000.0f); delayFb_ = clampf(fb, 0.0f, 0.95f); }
    void setChop(bool on, float rateHz, float depth)    { chopOn_ = on; chopRate_ = clampf(rateHz, 0.1f, 24.0f); chopDepth_ = clampf(depth, 0.0f, 1.0f); }
    void setSkip(bool on, float rateHz, float amount)   { skipOn_ = on; skipRate_ = clampf(rateHz, 0.5f, 16.0f); skipAmount_ = clampf(amount, 0.0f, 1.0f); }
    void setVocoder(bool on, float tone, float mix)     { vocOn_ = on; vocTone_ = clampf(tone, 0.0f, 1.0f); vocMix_ = clampf(mix, 0.0f, 1.0f); }
    void setReverb(bool on, float size, float mix)      { revOn_ = on; revSize_ = clampf(size, 0.0f, 1.0f); revMix_ = clampf(mix, 0.0f, 1.0f); }

    /// Fixed latency of the whole rack (samples) — the phase vocoder's frame.
    static constexpr int kLatency = 768;

    inline void processFrame(float& L, float& R) {
        const float rawIn[2] = { L, R };
        // AUTOTUNE runs first, on the voice, before any colouring. It's mono
        // (one corrected voice): detect+shift on the left, reuse for both.
        if (autoOn_) {
            const float corrected = autotune_.process(L);
            L = corrected;
            R = corrected;
        } else {
            // Constant latency: the dry voice takes the same 768-sample delay
            // the vocoder path has, so the latency reported to the host holds
            // with AUTOTUNE on or off, and the HiFi harmony (fed from the
            // undelayed input below) lands ON the dry voice instead of 16 ms
            // behind it.
            L = latDly_[0].push(L);
            R = latDly_[1].push(R);
        }
        float io[2] = { L, R };
        for (int ch = 0; ch < 2; ++ch) {
            float x = io[ch];

            // 1.2) LOW TUNER — formant-preserving shift DOWN of the main voice.
            // Mono (computed on the left, reused for both). Fed from the
            // undelayed input when AUTOTUNE is off so it lands exactly on the
            // (latency-matched) dry voice; from the corrected voice otherwise.
            if (lowOn_) {
                if (ch == 0) lowOut_ = low_.process(autoOn_ ? x : rawIn[0], lowRatio_);
                x += (lowOut_ - x) * lowMix_;
            }

            // 1.5) VOCODER — imprint the voice's spectral envelope onto a
            // saturated carrier of itself (robotic, pitch-tracking, smooth).
            if (vocOn_) x = voc_[ch].process(x, vocTone_, vocMix_);

            // 2) HARMONIZER — add a pitch-shifted harmony voice
            if (harmOn_) {
                float ratio = harmRatio_;                 // fixed-interval mode
                if (harmAuto_) {                          // intelligent in-key mode
                    if (ch == 0) smart_.push(x);          // track pitch on left
                    ratio = smart_.ratio();
                }
                // HiFi path: one MONO formant-preserving phase-vocoder shift per
                // frame (computed on the left, reused for both channels — cheap).
                // Cheap per-channel shifter kept as the CPU-lite fallback.
                float h;
                if (harmHiFi_) {
                    if (ch == 0) hqOut_ = hq_.process(autoOn_ ? x : rawIn[0], ratio);   // see kLatency
                    h = hqOut_;
                } else {
                    h = harm_[ch].process(x, ratio);
                }
                x = x * (1.0f - 0.4f * harmMix_) + h * harmMix_;
            }

            // 3) PITCH-SKIP — sample-and-hold random pitch jumps ("weird")
            if (skipOn_) {
                if (ch == 0) {
                    skipPhase_ += skipRate_ / sr_;
                    if (skipPhase_ >= 1.0f) {
                        skipPhase_ -= 1.0f;
                        static const float steps[7] = {-12, -7, -5, 0, 5, 7, 12};
                        const float pick = steps[(unsigned)(fastNoise(rng_) * 3.5f + 3.5f) % 7];
                        skipRatio_ = std::pow(2.0f, (pick * skipAmount_) / 12.0f);
                    }
                }
                const float s = skip_[ch].process(x, skipRatio_);
                x = x * (1.0f - skipAmount_ * 0.8f) + s * (skipAmount_ * 0.8f);
            }

            // 5) DELAY — stereo delay with feedback
            if (delayOn_) {
                const int N = (int)delayBuf_[ch].size();
                int d = (int)(delayMs_ * 0.001f * sr_);
                d = std::max(1, std::min(N - 2, d));
                const int rpos = (delayW_[ch] - d + N) % N;
                const float wet = delayBuf_[ch][rpos];
                delayBuf_[ch][delayW_[ch]] = x + wet * delayFb_;
                if (++delayW_[ch] >= N) delayW_[ch] = 0;
                x = x + wet * 0.7f;
            }

            // 6) CHOP — rhythmic amplitude gate (soft square tremolo)
            if (chopOn_) {
                if (ch == 0) {
                    chopPhase_ += chopRate_ / sr_;
                    if (chopPhase_ >= 1.0f) chopPhase_ -= 1.0f;
                    const float target = (chopPhase_ < 0.5f) ? 1.0f : (1.0f - chopDepth_);
                    chopGain_ += 0.012f * (target - chopGain_);   // smooth edges = no clicks
                }
                x *= chopGain_;
            }

            // Output safety — ALWAYS on, but now nearly transparent. We only
            // soft-clip the PEAKS (so the signal can't spike past ~±1) and lift
            // back so normal-level audio passes through essentially clean — this
            // is the main fix for the "too distorted / too artificial" tone.
            // A high one-pole LP still shaves residual aliasing fizz.
            x = std::tanh(x * 0.7f) / 0.7f;            // unity slope near 0, soft knee on peaks
            x = glueLP_[ch].process(x);

            io[ch] = x;
        }
        // REVERB — smooth stereo tail across the whole rack output.
        if (revOn_) rev_.process(io[0], io[1], revSize_, revMix_);
        // light output safety
        L = clampf(io[0], -1.5f, 1.5f);
        R = clampf(io[1], -1.5f, 1.5f);
    }

private:
    float sr_ = 48000.0f;

    // AUTOTUNE (mono — one corrected voice)
    struct LatDelay {
        float buf[768] = {}; int w = 0;
        inline float push(float v) { const float o = buf[w]; buf[w] = v; if (++w >= 768) w = 0; return o; }
        void reset() { for (auto &b : buf) b = 0.0f; w = 0; }
    } latDly_[2];
    bool  autoOn_ = false;
    AutoTune autotune_;
    // HARMONIZER
    bool  harmOn_ = false; float harmRatio_ = 1.5f, harmMix_ = 0.4f;
    bool  harmAuto_ = false;          // AUTO = intelligent in-key harmony
    bool  harmHiFi_ = true;           // formant-preserving phase-vocoder shifter
    PitchShifter harm_[2];            // cheap time-domain fallback
    PitchShifterHQ hq_;               // studio-clean mono shifter
    PitchShifterHQ low_;              // LOW TUNER — formant-preserving downward shift
    float lowOut_ = 0.0f, lowRatio_ = 0.75f, lowMix_ = 1.0f; bool lowOn_ = false;
    float hqOut_ = 0.0f;
    SmartHarmony smart_;              // pitch track + auto key + diatonic
    // PITCH-SKIP
    bool  skipOn_ = false; float skipRate_ = 4.0f, skipAmount_ = 0.5f;
    PitchShifter skip_[2];
    float skipPhase_ = 0.0f, skipRatio_ = 1.0f;
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
    // Always-on analogue glue (soft-clip + HF damp) per channel.
    OnePoleLP glueLP_[2];
};

} // namespace vbx
