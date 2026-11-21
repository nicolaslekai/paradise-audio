//
//  Psola.hpp — pitch-synchronous overlap-add (TD-PSOLA) engine for VoiceBox.
//
//  One shared analysis (tracker + pitch marks over the mid signal) feeds up to
//  four synthesis VOICES (AUTOTUNE, HARMONY, LOW TUNER, PITCH-SKIP). Each voice
//  places windowed analysis grains at its own synthesis spacing T/ratio, so the
//  vocal-tract response inside every grain — the formants — stays where it was.
//
//  In-house implementation of Moulines & Charpentier (1990); structure follows
//  the TD-PSOLA reference in sannawag/TD-PSOLA (MIT, © 2019 Sanna Wager) but no
//  code was copied. See AUDIO_QUALITY_PLAN.md §2.1.
//
//  Design notes
//   • Grains are asymmetric: the rising half spans prev→this mark, the falling
//     half this→next mark. At ratio 1 consecutive grains are complementary
//     raised cosines, so the output is the input, sample-exact.
//   • Corrections (cents) are read when a grain is SYNTHESISED, not when its
//     mark is placed: the tracker's window (W = 2·L at every sample rate) is
//     then centred exactly on the output time, so the correction lines up with
//     the audio it was measured on (no vibrato phase lag).
//   • Unvoiced marks (consonants, breath, silence) are spaced 5 ms apart and
//     always synthesised at ratio 1 → s, sh, t and breaths pass untouched.
//   • Synthesis positions are fractional; grains are read with an 8-tap
//     windowed-sinc interpolator (flat to ~18 kHz @ 48 kHz), so small
//     corrections neither quantise to whole samples nor dull the top end.
//   • Constant output latency L (set by the engine). Every voice and the dry
//     path come out exactly L samples late.
//
//  2026-11-21 sound-quality pass (Tests/sq, HANDOFF §0):
//   • PITCH MARKS are chained by waveform similarity: the next mark is where
//     the cycle around the previous mark repeats best (normalised
//     cross-correlation, ±T/8 around the tracker's period, parabolic
//     sub-sample peak). Mark positions are fractional. The old rule — "the
//     strongest positive sample near the prediction" — jumped between
//     neighbouring samples / neighbouring peaks, which put 0.4–1 % of period
//     jitter into every shifted voice (rough, hoarse: HNR 15–30 dB on a glottal
//     vowel). A voiced run starts on the largest pulse of the cycle (either
//     polarity) and only drifts slowly (1 % of T per cycle) if another pulse
//     becomes clearly larger. A mark is only VOICED where the cycle really
//     repeats (correlation ≥ 0.5 with its neighbour): the tracker's voiced flag
//     lags by 15–30 ms, so the first milliseconds of an "s" after a vowel used
//     to be shifted as if they were voice.
//   • SCHEDULING can only move forward. Unity grains (unvoiced, or no shift)
//     use every mark exactly once, in order, at its own position. Before, a
//     "lock to the mark" step could jump back onto a mark that was already
//     synthesised and add the same grain 16× per sample until the next mark
//     arrived — a burst to full scale at word starts/ends and reverb tails.
//   • A grain's falling half is rendered when the NEXT mark is known, so it
//     always ends exactly on its neighbour (no right-neighbour wait: low
//     voices < 105 Hz no longer repeat grains at ratio 1).
//   • The summed window W is tracked per voice and the output divided by it
//     where W > 1: overlapping grains can never add up louder than the source.
//   • Voices can attenuate their unvoiced grains (`setVoiceUnvoicedGain`) so a
//     harmony does not double every "s".
//
#pragma once
#include "PitchTracker.hpp"
#include <vector>
#include <cmath>
#include <cstdint>
#include <algorithm>

namespace vbx {

class PsolaCore {
public:
    static constexpr int kVoices = 4;

    void prepare(float sr, int latency) {
        sr_ = sr; L_ = latency;
        tracker_.prepare(sr);
        maxT_ = (int)std::ceil(sr / 70.0f);
        minT_ = std::max(8, (int)std::floor(sr / 1100.0f));
        unvT_ = std::max(16, (int)(0.005f * sr));
        int need = L_ + 4 * maxT_ + tracker_.window() + 1024, rb = 1; while (rb < need) rb <<= 1;
        RB_ = rb; mask_ = RB_ - 1;
        inL_.assign(RB_, 0.0f); inR_.assign(RB_, 0.0f); inM_.assign(RB_, 0.0f);
        win_.assign(tracker_.window(), 0.0f);
        refBuf_.assign((size_t)maxT_ + 64, 0.0f); candBuf_.assign((size_t)(2 * maxT_) + 64, 0.0f); scoreBuf_.assign((size_t)(maxT_ / 2) + 16, 0.0f);
        for (auto& v : voice_) { v.zL.assign(RB_, 0.0f); v.zR.assign(RB_, 0.0f); v.zW.assign(RB_, 0.0f); }
        // Raised-cosine half-window table (falling half: 1 → 0).
        for (int i = 0; i <= kTab; ++i) tab_[i] = 0.5f * (1.0f + std::cos((float)M_PI * (float)i / (float)kTab));
        // 8-tap Kaiser-windowed sinc, kSincPhases fractional positions (grain reads at fractional offsets).
        sinc_.assign((size_t)(kSincPhases + 1) * kSincTaps, 0.0f);
        for (int ph = 0; ph <= kSincPhases; ++ph) {
            const double fr = (double)ph / (double)kSincPhases; double sum = 0.0, h[kSincTaps];
            for (int k = 0; k < kSincTaps; ++k) {
                const double x = (double)(k - (kSincTaps / 2 - 1)) - fr;                 // tap offsets −3 … +4
                const double u = x / (double)(kSincTaps / 2), beta = 7.0;
                const double win = std::fabs(u) < 1.0 ? bessI0(beta * std::sqrt(1.0 - u * u)) / bessI0(beta) : 0.0;
                h[k] = (std::fabs(x) < 1e-12 ? 1.0 : std::sin(M_PI * x) / (M_PI * x)) * win; sum += h[k];
            }
            for (int k = 0; k < kSincTaps; ++k) sinc_[(size_t)ph * kSincTaps + k] = (float)(h[k] / sum);   // unity DC gain
        }
        reset();
    }
    void reset() {
        std::fill(inL_.begin(), inL_.end(), 0.0f); std::fill(inR_.begin(), inR_.end(), 0.0f); std::fill(inM_.begin(), inM_.end(), 0.0f);
        tracker_.reset();
        n_ = 0; hopCount_ = 0; frameReady_ = false;
        head_ = 0; nextPred_ = 0; pol_ = 1.0f;
        for (int v = 0; v < kVoices; ++v) { cents_[v] = 0.0f; voice_[v].active = false; clearVoice(voice_[v]); }
    }

    int latency() const { return L_; }
    int64_t now() const { return n_; }
    const TrackState& track() const { return tracker_.state(); }
    bool frameReady() const { return frameReady_; }
    float sampleRate() const { return sr_; }

    void setVoiceCents(int v, float cents) { cents_[v] = cents; }
    void setVoiceStereo(int v, bool st) { voice_[v].stereo = st; }
    /// Level of consonants / breath / silence grains in this voice (1 = pass through, 0 = mute).
    void setVoiceUnvoicedGain(int v, float g) { voice_[v].uvGain = g; }
    void setVoiceActive(int v, bool on) {
        Voice& V = voice_[v];
        if (on && !V.active) clearVoice(V);
        V.active = on;
    }
    bool voiceActive(int v) const { return voice_[v].active; }

    /// Feed one stereo input sample. Runs the tracker every hop and places marks.
    inline void push(float l, float r) {
        const int i = (int)(n_ & mask_);
        inL_[i] = l; inR_[i] = r; inM_[i] = 0.5f * (l + r);
        ++n_;
        frameReady_ = false;
        if (++hopCount_ >= tracker_.hop()) { hopCount_ = 0; runTracker(); frameReady_ = true; }
        placeMarks();
    }

    /// Dry input delayed by exactly L samples (call after push()).
    inline float dryL() const { return at(inL_, n_ - 1 - L_); }
    inline float dryR() const { return at(inR_, n_ - 1 - L_); }
    inline float dryM() const { return at(inM_, n_ - 1 - L_); }
    /// Newest mono input sample (for the STFT fallback shifter).
    inline float newestM() const { return inM_[(n_ - 1) & mask_]; }

    /// Output of voice v for the current output time (call once per push()).
    inline float renderMono(int v) { float l, r; render(v, l, r); return l; }
    inline void  renderStereo(int v, float& l, float& r) { render(v, l, r); }

private:
    struct Mark {
        double pos = 0.0;         // input-time position (fractional for voiced marks)
        double per = 0.0;         // measured local period (lag to the previous mark)
        int    T = 0;             // nominal period (tracker) / unvoiced spacing
        bool   voiced = false;
    };
    struct Voice {
        bool active = false, stereo = false, started = false, pend = false, lastUnity = false;
        float uvGain = 1.0f;
        double lastS = 0.0;       // centre of the last grain placed
        int64_t lastId = -1;      // … and its mark
        int64_t cur = 0;          // nearest-mark search cursor
        double pS = 0.0; int64_t pId = 0; float pAmp = 1.0f;   // grain whose falling half is still to render
        std::vector<float> zL, zR, zW;
    };
    static constexpr int kMarks = 1024, kMarkMask = kMarks - 1, kTab = 2048, kSincTaps = 8, kSincPhases = 1024;

    static inline float at(const std::vector<float>& b, int64_t idx) { return idx < 0 ? 0.0f : b[(size_t)(idx & (int64_t)(b.size() - 1))]; }

    void clearVoice(Voice& V) {
        std::fill(V.zL.begin(), V.zL.end(), 0.0f); std::fill(V.zR.begin(), V.zR.end(), 0.0f); std::fill(V.zW.begin(), V.zW.end(), 0.0f);
        V.started = false; V.pend = false; V.lastUnity = false; V.lastId = -1; V.lastS = 0.0;
        V.cur = std::max<int64_t>(0, head_ - kMarks);
    }

    void runTracker() {
        const int W = tracker_.window();
        const int64_t start = n_ - W;
        for (int k = 0; k < W; ++k) win_[k] = at(inM_, start + k);
        tracker_.analyze(win_.data());
    }

    void addMark(double pos, double per, int T, bool voiced) {
        Mark& m = marks_[head_ & kMarkMask];
        m.pos = pos; m.per = per; m.T = T; m.voiced = voiced;
        ++head_;
    }
    const Mark& mark(int64_t id) const { return marks_[id & kMarkMask]; }
    int64_t markTail() const { return std::max<int64_t>(0, head_ - kMarks); }

    // Where does the cycle around `lastPos` repeat? Normalised cross-correlation of
    // x[l0−T/2 … l0+T/4] against the same span one period later, ±T/8.
    bool chainLag(double lastPos, double Tf, int T, double& lag) {
        const int64_t l0 = (int64_t)std::llround(lastPos), c0 = l0 + (int64_t)std::llround(Tf);
        const int dl = std::max(2, T / 8), hb = std::max(4, T / 2), hf = std::max(4, T / 4), len = hb + hf + 1;
        float* ref = refBuf_.data(); float* cand = candBuf_.data(); float* sc = scoreBuf_.data();
        for (int i = 0; i < len; ++i) ref[i] = at(inM_, l0 - hb + i);
        for (int i = 0; i < len + 2 * dl; ++i) cand[i] = at(inM_, c0 - dl - hb + i);
        float ea = 0.0f, eb = 0.0f;
        vDSP_svesq(ref, 1, &ea, (vDSP_Length)len); if (ea < 1e-10f) return false;
        vDSP_svesq(cand, 1, &eb, (vDSP_Length)len);
        float best = -1e30f; int bi = 0;
        for (int k = 0; k <= 2 * dl; ++k) {
            float dot = 0.0f; vDSP_dotpr(ref, 1, cand + k, 1, &dot, (vDSP_Length)len);
            sc[k] = dot / std::sqrt(std::max(eb, 0.0f) + 1e-12f);
            if (sc[k] > best) { best = sc[k]; bi = k; }
            eb += cand[k + len] * cand[k + len] - cand[k] * cand[k];
        }
        if (best / std::sqrt(ea) < 0.5f) return false;              // the cycle did not repeat (onset, note change)
        double fr = 0.0;
        if (bi > 0 && bi < 2 * dl) { const double den = (double)sc[bi - 1] - 2.0 * sc[bi] + sc[bi + 1]; if (den < -1e-12) fr = std::max(-0.5, std::min(0.5, 0.5 * ((double)sc[bi - 1] - sc[bi + 1]) / den)); }
        lag = (double)(c0 + (bi - dl) - l0) + fr;
        return true;
    }

    void placeMarks() {
        const int64_t cur = n_ - 1;
        for (int guard = 0; guard < 4; ++guard) {
            const TrackState& st = tracker_.state();
            if (st.voiced && st.hz > 0.0f) {
                const double Tf = std::max((double)minT_, std::min((double)maxT_, (double)sr_ / (double)st.hz));
                const int T = (int)std::lround(Tf);
                const int dl = std::max(2, T / 8), hf = std::max(4, T / 4);
                const bool chain = head_ > 0 && mark(head_ - 1).voiced;
                const double lastPos = head_ > 0 ? mark(head_ - 1).pos : -1e18;
                const int64_t pred = chain ? (int64_t)std::llround(lastPos + Tf) : std::max<int64_t>(nextPred_, 0);
                if (cur < pred + (chain ? dl : 2 * dl) + hf + 2) return;   // need lookahead around the prediction
                double pos = 0.0, per = Tf; bool periodic = false;
                if (chain) {
                    periodic = chainLag(lastPos, Tf, T, per);
                    if (periodic) {
                        pos = lastPos + per;
                        // Stay on the cycle's main pulse: if another pulse nearby is clearly larger, drift to it slowly.
                        const int64_t pi = (int64_t)std::llround(pos);
                        float vCur = -1e30f, vBest = -1e30f; int o = 0;
                        for (int i = -1; i <= 1; ++i) vCur = std::max(vCur, pol_ * at(inM_, pi + i));
                        for (int i = -hf; i <= hf; ++i) { const float v = pol_ * at(inM_, pi + i); if (v > vBest) { vBest = v; o = i; } }
                        if (std::abs(o) > 1 && vBest > 1.3f * std::max(vCur, 1e-6f))
                            pos += std::copysign(std::min((double)std::abs(o), std::max(0.5, 0.01 * Tf)), (double)o);
                    }
                } else {
                    // Voiced onset: anchor on the largest pulse (either polarity) — but only if the cycle
                    // before it really looks like it. The tracker's "voiced" lags the audio by 15–30 ms;
                    // the waveform itself says where the periodic part starts and stops.
                    const int64_t minPos = head_ > 0 ? (int64_t)std::floor(lastPos) + std::max(minT_ / 2, 4) : 0;
                    const int64_t lo = std::max<int64_t>(pred - T / 2, minPos), hi = std::max<int64_t>(lo, pred + dl);
                    float mp = -1e30f, mn = -1e30f; int64_t ip = lo, in = lo;
                    for (int64_t p = lo; p <= hi; ++p) { const float v = at(inM_, p); if (v > mp) { mp = v; ip = p; } if (-v > mn) { mn = -v; in = p; } }
                    const float pol = mp >= mn ? 1.0f : -1.0f;
                    const double cand = (double)(pol > 0.0f ? ip : in);
                    double lag = Tf;
                    if (chainLag(cand - Tf, Tf, T, lag)) { periodic = true; pol_ = pol; pos = cand; per = lag; }
                }
                if (!periodic) {
                    // Not periodic here (consonant, breath, the tail of a note): an unvoiced mark → passes untouched.
                    double p = chain ? std::floor(lastPos) + (double)unvT_ : (double)nextPred_;
                    if (head_ > 0 && p <= lastPos) p = std::floor(lastPos) + (double)unvT_;
                    addMark(p, (double)unvT_, unvT_, false);
                    nextPred_ = (int64_t)p + unvT_;
                    continue;
                }
                if (head_ > 0 && pos <= lastPos + 1.0) pos = lastPos + std::max(1.0, 0.5 * Tf);   // strictly forward
                addMark(pos, per, T, true);
                nextPred_ = (int64_t)std::llround(pos + Tf);
            } else {
                if (cur < nextPred_) return;
                double p = (double)nextPred_;
                if (head_ > 0 && p <= mark(head_ - 1).pos) p = std::floor(mark(head_ - 1).pos) + (double)unvT_;
                addMark(p, (double)unvT_, unvT_, false);
                nextPred_ = (int64_t)p + unvT_;
            }
        }
    }

    // Nearest existing mark to position s.
    int64_t nearest(Voice& V, double s) {
        const int64_t tail = markTail(), last = head_ - 1;
        if (V.cur < tail) V.cur = tail;
        if (V.cur > last) V.cur = last;
        while (V.cur + 1 <= last && mark(V.cur + 1).pos <= s) ++V.cur;
        while (V.cur > tail && mark(V.cur).pos > s) --V.cur;
        int64_t id = V.cur;
        if (id + 1 <= last && std::fabs(mark(id + 1).pos - s) < std::fabs(mark(id).pos - s)) id = id + 1;
        return id;
    }
    // Half-window lengths = distance to the neighbouring mark (the same number on
    // both sides of a gap, so neighbouring grains are exactly complementary).
    double leftLen(int64_t id) const {
        const Mark& M = mark(id);
        if (id > markTail()) { const Mark& P = mark(id - 1); const double d = M.pos - P.pos; if (d > 0.0 && d <= 2.0 * (double)std::max(M.T, P.T)) return d; }
        return (double)M.T;
    }
    double rightLen(int64_t id) const {
        const Mark& M = mark(id);
        if (id + 1 <= head_ - 1) { const Mark& N = mark(id + 1); const double d = N.pos - M.pos; if (d > 0.0 && d <= 2.0 * (double)std::max(M.T, N.T)) return d; }
        return (double)M.T;
    }

    inline float halfWin(float d, float len) const {     // d in [0, len] → 1 … 0
        float x = d / len * (float)kTab; if (x >= (float)kTab) return 0.0f;
        const int i = (int)x; const float fr = x - (float)i;
        return tab_[i] + fr * (tab_[i + 1] - tab_[i]);
    }
    static double bessI0(double x) { double s = 1.0, t = 1.0; for (int k = 1; k < 32; ++k) { t *= (x / (2.0 * k)) * (x / (2.0 * k)); s += t; } return s; }
    // Fractional read b[i + fr] with the sinc row for fr (taps i−3 … i+4).
    static inline float sincRead(const std::vector<float>& b, int64_t mask, int64_t i, const float* h) {
        return b[(i - 3) & mask] * h[0] + b[(i - 2) & mask] * h[1] + b[(i - 1) & mask] * h[2] + b[i & mask] * h[3]
             + b[(i + 1) & mask] * h[4] + b[(i + 2) & mask] * h[5] + b[(i + 3) & mask] * h[6] + b[(i + 4) & mask] * h[7];
    }

    void render(int v, float& outL, float& outR) {
        Voice& V = voice_[v];
        const int64_t t = n_ - 1 - L_;
        if (!V.active || t < 0) { outL = outR = 0.0f; return; }
        for (int guard = 0; guard < 8; ++guard) {
            if (tryPlace(V, v, t)) continue;
            if (V.pend && V.pS <= (double)t + 1.0) { flush(V, t); continue; }
            break;
        }
        const int64_t ti = t & mask_;
        const float w = V.zW[ti], g = w > 1.0001f ? 1.0f / w : 1.0f;      // overlapping grains: normalise
        outL = V.zL[ti] * g; V.zL[ti] = 0.0f; V.zW[ti] = 0.0f;
        if (V.stereo) { outR = V.zR[ti] * g; V.zR[ti] = 0.0f; } else outR = outL;
    }

    double period(const Mark& M) const {
        return std::max((double)minT_, std::min((double)maxT_, M.per > 0.0 ? M.per : (double)M.T));
    }

    // Place the next grain if its rising half is due. Returns true when one was placed.
    bool tryPlace(Voice& V, int v, int64_t t) {
        const int64_t tail = markTail(), last = head_ - 1;
        if (last < tail) return false;
        const float cents = cents_[v];
        const bool shiftOn = std::fabs(cents) >= 0.05f;
        const float ratio = std::max(0.5f, std::min(2.0f, std::exp2(cents / 1200.0f)));
        int64_t id; double s;
        if (!V.started) {
            // Start on the last mark at or before the output time: its falling half covers t.
            id = nearest(V, (double)t);
            while (id > tail && mark(id).pos > (double)t) --id;
            s = mark(id).pos;
        } else {
            // Where the next grain would go if it is a shifted one: one period / ratio after the last.
            double sFree;
            if (V.lastUnity) sFree = V.lastS + rightLen(V.lastId);
            else {
                double P = period(mark(V.lastId));
                // Look one input period ahead: if the pitch there is higher (new note, or the tracker
                // left a subharmonic), step with THAT period — never stride over audio with a stale one.
                P = std::min(P, period(mark(nearest(V, V.lastS + P))));
                sFree = V.lastS + P / (double)ratio;
            }
            id = nearest(V, sFree);
            if (!mark(id).voiced || !shiftOn) {
                // UNITY: every mark exactly once, in order, at its own position → output == input.
                // After a unity grain: strictly the next mark. Leaving a shifted stretch: the first mark
                // after the last grain's centre, so no stretch of input is skipped (no hole in a lowered voice).
                if (V.lastUnity) id = V.lastId + 1;
                else id = nearest(V, V.lastS);
                while (id <= last && mark(id).pos <= V.lastS) ++id;
                if (id > last) return false;                      // that mark is not placed yet
                s = mark(id).pos;
            } else s = sFree;
        }
        bool unity = !mark(id).voiced || !shiftOn;
        double Tl = leftLen(id);
        if (V.started && !unity) {
            // Continuity: a shifted grain must begin before the previous one has rung out. When the
            // pitch jumps up while a voice is being lowered, the new (short) grain would otherwise
            // start long after the old (long) one ended — a hole of several ms in the lowered voice.
            const double maxS = V.lastS + rightLen(V.lastId) + Tl;
            if (s > maxS + 0.25 * Tl) {
                s = std::max(maxS, V.lastS + (double)minT_ * 0.5);
                id = nearest(V, s);
                unity = !mark(id).voiced || !shiftOn;
                if (unity) { while (id <= last && mark(id).pos <= V.lastS) ++id; if (id > last) return false; s = mark(id).pos; }
                Tl = leftLen(id);
            }
        }
        if (s - Tl > (double)t + 1.0) return false;               // not due yet
        double rise = Tl;
        if (V.started && s - Tl < (double)t) {
            // Its rising half should already have begun (the shift was switched off / the ratio jumped):
            // fade it in from NOW instead of starting mid-window (that was a step in the waveform).
            const double minRise = std::min(Tl, std::max(16.0, 0.25 * Tl));
            if (unity) {
                while (mark(id).pos - (double)t < minRise) { if (id + 1 > last) return false; ++id; }
                s = mark(id).pos; Tl = leftLen(id); unity = !mark(id).voiced || !shiftOn;
            } else if (s - (double)t < minRise) s = (double)t + minRise;
            rise = std::min(Tl, s - (double)t);
        }
        const Mark& M = mark(id);
        if (V.pend) flush(V, t);                                  // the previous grain ends on its neighbour
        const float r = unity ? 1.0f : ratio;
        const float amp = (r < 1.0f ? 1.0f / std::sqrt(r) : 1.0f) * (M.voiced ? 1.0f : V.uvGain);
        addHalf(V, M.pos, s, rise, amp, true, t);
        V.pend = true; V.pS = s; V.pId = id; V.pAmp = amp;
        V.started = true; V.lastS = s; V.lastId = id; V.lastUnity = unity;
        return true;
    }
    void flush(Voice& V, int64_t t) {
        addHalf(V, mark(V.pId).pos, V.pS, rightLen(V.pId), V.pAmp, false, t);
        V.pend = false;
    }

    // One half of a grain centred at s (source = j + mpos − s). left: s−len < j < s, right: s ≤ j < s+len.
    void addHalf(Voice& V, double mpos, double s, double len, float amp, bool left, int64_t t) {
        int64_t j0, j1;
        if (left) { j0 = (int64_t)std::floor(s - len) + 1; j1 = (int64_t)std::ceil(s) - 1; }
        else      { j0 = (int64_t)std::ceil(s);            j1 = (int64_t)std::ceil(s + len) - 1; }
        const double off = mpos - s;                 // source = j + off
        j0 = std::max(j0, t);
        j1 = std::min(j1, (int64_t)std::floor((double)(n_ - 1) - off) - 4);   // never read ahead of the input
        // The offset is constant over the grain: one integer part + one sinc row.
        const double offFl = std::floor(off); double offFr = off - offFl;
        int ph = (int)std::lround(offFr * (double)kSincPhases);
        const bool frac = ph != 0 && ph != kSincPhases;
        const int64_t ioff = (int64_t)offFl + (ph == kSincPhases ? 1 : 0);
        const float* h = &sinc_[(size_t)ph * kSincTaps];
        const float flen = (float)len;
        for (int64_t j = j0; j <= j1; ++j) {
            const float w = halfWin((float)std::fabs((double)j - s), flen);
            if (w == 0.0f) continue;
            const int64_t jo = j & mask_;
            V.zW[jo] += w;
            const float wa = w * amp;
            if (wa == 0.0f) continue;
            if (V.stereo) {
                if (frac) { V.zL[jo] += wa * sincRead(inL_, mask_, j + ioff, h); V.zR[jo] += wa * sincRead(inR_, mask_, j + ioff, h); }
                else { const int64_t si = (j + ioff) & mask_; V.zL[jo] += wa * inL_[si]; V.zR[jo] += wa * inR_[si]; }
            } else {
                if (frac) V.zL[jo] += wa * sincRead(inM_, mask_, j + ioff, h);
                else      V.zL[jo] += wa * inM_[(j + ioff) & mask_];
            }
        }
    }

    float sr_ = 48000.0f;
    int   L_ = 1024, RB_ = 8192, maxT_ = 686, minT_ = 43, unvT_ = 240;
    int64_t mask_ = 8191;
    std::vector<float> inL_, inR_, inM_, win_, refBuf_, candBuf_, scoreBuf_, sinc_;
    PitchTracker tracker_;
    int64_t n_ = 0; int hopCount_ = 0; bool frameReady_ = false;
    Mark marks_[kMarks];
    int64_t head_ = 0, nextPred_ = 0; float pol_ = 1.0f;
    float cents_[kVoices] = {};
    Voice voice_[kVoices];
    float tab_[kTab + 1] = {};
};

} // namespace vbx
