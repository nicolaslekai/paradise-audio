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
//   • Synthesis positions are fractional; grains are read with a 4-point cubic
//     interpolator, so small corrections don't quantise to whole samples.
//   • Constant output latency L (set by the engine). Every voice and the dry
//     path come out exactly L samples late.
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
        for (auto& v : voice_) { v.zL.assign(RB_, 0.0f); v.zR.assign(RB_, 0.0f); }
        // Raised-cosine half-window table (falling half: 1 → 0).
        for (int i = 0; i <= kTab; ++i) tab_[i] = 0.5f * (1.0f + std::cos((float)M_PI * (float)i / (float)kTab));
        reset();
    }
    void reset() {
        std::fill(inL_.begin(), inL_.end(), 0.0f); std::fill(inR_.begin(), inR_.end(), 0.0f); std::fill(inM_.begin(), inM_.end(), 0.0f);
        tracker_.reset();
        n_ = 0; hopCount_ = 0; frameReady_ = false;
        head_ = 0; nextPred_ = 0; lastVoiced_ = false;
        for (int v = 0; v < kVoices; ++v) { cents_[v] = 0.0f; voice_[v].active = false; clearVoice(voice_[v]); }
    }

    int latency() const { return L_; }
    int64_t now() const { return n_; }
    const TrackState& track() const { return tracker_.state(); }
    bool frameReady() const { return frameReady_; }
    float sampleRate() const { return sr_; }

    void setVoiceCents(int v, float cents) { cents_[v] = cents; }
    void setVoiceStereo(int v, bool st) { voice_[v].stereo = st; }
    void setVoiceActive(int v, bool on) {
        Voice& V = voice_[v];
        if (on && !V.active) { clearVoice(V); V.s = (double)(n_ - L_); }
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
    struct Mark { int64_t pos = 0; int T = 0; bool voiced = false; };
    struct Voice {
        bool active = false, stereo = false, started = false;
        double s = 0.0;           // next synthesis position (input-time samples)
        int64_t cur = 0;          // mark id cursor
        std::vector<float> zL, zR;
    };
    static constexpr int kMarks = 1024, kMarkMask = kMarks - 1, kTab = 2048;

    static inline float at(const std::vector<float>& b, int64_t idx) { return idx < 0 ? 0.0f : b[(size_t)(idx & (int64_t)(b.size() - 1))]; }

    void clearVoice(Voice& V) {
        std::fill(V.zL.begin(), V.zL.end(), 0.0f); std::fill(V.zR.begin(), V.zR.end(), 0.0f);
        V.started = false; V.cur = std::max<int64_t>(0, head_ - kMarks); V.s = 0.0;
    }

    void runTracker() {
        const int W = tracker_.window();
        const int64_t start = n_ - W;
        for (int k = 0; k < W; ++k) win_[k] = at(inM_, start + k);
        tracker_.analyze(win_.data());
    }

    void addMark(int64_t pos, int T, bool voiced) {
        Mark& m = marks_[head_ & kMarkMask];
        m.pos = pos; m.T = T; m.voiced = voiced;
        ++head_;
    }
    const Mark& mark(int64_t id) const { return marks_[id & kMarkMask]; }

    void placeMarks() {
        const int64_t cur = n_ - 1;
        for (int guard = 0; guard < 4; ++guard) {
            const TrackState& st = tracker_.state();
            if (st.voiced && st.hz > 0.0f) {
                const int T = std::max(minT_, std::min(maxT_, (int)std::lround(sr_ / st.hz)));
                const int half = std::max(2, T / 4);
                if (cur < nextPred_ + half + 2) return;               // need lookahead around the prediction
                // Strongest positive peak near the prediction (slight pull toward it).
                int64_t best = nextPred_; float bv = -1e30f;
                for (int64_t p = nextPred_ - half; p <= nextPred_ + half; ++p) {
                    const float w = 1.0f - 0.3f * (float)std::llabs(p - nextPred_) / (float)half;
                    const float v = at(inM_, p) * w;
                    if (v > bv) { bv = v; best = p; }
                }
                if (head_ > 0) {
                    const Mark& last = mark(head_ - 1);
                    const int64_t d = best - last.pos;
                    if (last.voiced && lastVoiced_ && (d < T / 2 || d > (3 * T) / 2)) best = last.pos + T;
                    if (best <= last.pos) best = last.pos + std::max(minT_, T / 2);
                }
                addMark(best, T, true); lastVoiced_ = true;
                nextPred_ = best + T;
            } else {
                if (cur < nextPred_) return;
                int64_t p = nextPred_;
                if (head_ > 0 && p <= mark(head_ - 1).pos) p = mark(head_ - 1).pos + unvT_;
                addMark(p, unvT_, false); lastVoiced_ = false;
                nextPred_ = p + unvT_;
            }
        }
    }

    // Nearest usable mark (it needs a right neighbour) to position s.
    bool pickMark(Voice& V, double s, int64_t& id) {
        const int64_t tail = std::max<int64_t>(0, head_ - kMarks), last = head_ - 2;
        if (last < tail) return false;
        if (V.cur < tail) V.cur = tail;
        if (V.cur > last) V.cur = last;
        while (V.cur + 1 <= last && (double)mark(V.cur + 1).pos <= s) ++V.cur;
        while (V.cur > tail && (double)mark(V.cur).pos > s) --V.cur;
        id = V.cur;
        if (V.cur + 1 <= last && std::fabs((double)mark(V.cur + 1).pos - s) < std::fabs((double)mark(V.cur).pos - s)) id = V.cur + 1;
        return true;
    }

    inline float halfWin(float d, float len) const {     // d in [0, len] → 1 … 0
        float x = d / len * (float)kTab; if (x >= (float)kTab) return 0.0f;
        const int i = (int)x; const float fr = x - (float)i;
        return tab_[i] + fr * (tab_[i + 1] - tab_[i]);
    }
    static inline float cubic(const std::vector<float>& b, int64_t mask, double p) {
        const int64_t i = (int64_t)std::floor(p); const float t = (float)(p - (double)i);
        const float y0 = b[(i - 1) & mask], y1 = b[i & mask], y2 = b[(i + 1) & mask], y3 = b[(i + 2) & mask];
        const float c1 = 0.5f * (y2 - y0), c2 = y0 - 2.5f * y1 + 2.0f * y2 - 0.5f * y3, c3 = 0.5f * (y3 - y0) + 1.5f * (y1 - y2);
        return ((c3 * t + c2) * t + c1) * t + y1;
    }

    void render(int v, float& outL, float& outR) {
        Voice& V = voice_[v];
        const int64_t t = n_ - 1 - L_;
        if (!V.active || t < 0) { outL = outR = 0.0f; return; }
        for (int guard = 0; guard < 16; ++guard) {
            int64_t id;
            if (!pickMark(V, V.started ? V.s : (double)t, id)) break;
            const Mark& M = mark(id);
            const int64_t tail = std::max<int64_t>(0, head_ - kMarks);
            int Tl = M.T, Tr = M.T;
            if (id > tail) { const int64_t d = M.pos - mark(id - 1).pos; if (d > 0 && d <= 2 * (int64_t)M.T) Tl = (int)d; }
            { const int64_t d = mark(id + 1).pos - M.pos; if (d > 0 && d <= 2 * (int64_t)std::max(M.T, mark(id + 1).T)) Tr = (int)d; }
            float r = M.voiced ? std::exp2(cents_[v] / 1200.0f) : 1.0f;
            r = std::max(0.5f, std::min(2.0f, r));
            double s = V.started ? V.s : (double)M.pos;
            const bool unity = !M.voiced || std::fabs(cents_[v]) < 0.05f;
            if (unity && std::fabs((double)M.pos - s) <= 0.5 * std::max(Tl, Tr)) s = (double)M.pos;   // lock to the mark → identity
            if (s - (double)Tl > (double)t + 1.0) { V.s = s; V.started = true; break; }          // not needed yet
            addGrain(V, M, s, Tl, Tr, r, t);
            V.started = true;
            V.s = s + (double)Tr / (double)r;
        }
        const int64_t ti = t & mask_;
        outL = V.zL[ti]; V.zL[ti] = 0.0f;
        if (V.stereo) { outR = V.zR[ti]; V.zR[ti] = 0.0f; } else outR = outL;
    }

    void addGrain(Voice& V, const Mark& M, double s, int Tl, int Tr, float r, int64_t t) {
        const float amp = r >= 1.0f ? 1.0f / r : 1.0f / std::sqrt(r);
        const int64_t j0 = std::max<int64_t>((int64_t)std::ceil(s - (double)Tl), t);
        const int64_t j1 = (int64_t)std::floor(s + (double)Tr);
        const double off = (double)M.pos - s;        // source = j + off
        const bool frac = std::fabs(off - std::round(off)) > 1e-9;
        const int64_t ioff = (int64_t)std::llround(off);
        for (int64_t j = j0; j <= j1; ++j) {
            const float d = (float)((double)j - s);
            const float w = amp * (d < 0.0f ? halfWin(-d, (float)Tl) : halfWin(d, (float)Tr));
            if (w == 0.0f) continue;
            const int64_t jo = j & mask_;
            if (V.stereo) {
                if (frac) { V.zL[jo] += w * cubic(inL_, mask_, (double)j + off); V.zR[jo] += w * cubic(inR_, mask_, (double)j + off); }
                else { const int64_t si = (j + ioff) & mask_; V.zL[jo] += w * inL_[si]; V.zR[jo] += w * inR_[si]; }
            } else {
                if (frac) V.zL[jo] += w * cubic(inM_, mask_, (double)j + off);
                else      V.zL[jo] += w * inM_[(j + ioff) & mask_];
            }
        }
    }

    float sr_ = 48000.0f;
    int   L_ = 1024, RB_ = 8192, maxT_ = 686, minT_ = 43, unvT_ = 240;
    int64_t mask_ = 8191;
    std::vector<float> inL_, inR_, inM_, win_;
    PitchTracker tracker_;
    int64_t n_ = 0; int hopCount_ = 0; bool frameReady_ = false;
    Mark marks_[kMarks];
    int64_t head_ = 0, nextPred_ = 0; bool lastVoiced_ = false;
    float cents_[kVoices] = {};
    Voice voice_[kVoices];
    float tab_[kTab + 1] = {};
};

} // namespace vbx
