//
//  DrumsEngine.hpp
//
//  10-voice drum engine + per-voice delay tap + internal 16-step sequencer
//  that follows host transport (host provides BPM and play state).
//

#pragma once
#include <climits>
#include "DrumVoices.hpp"
#include <vector>
#include <cstring>
#include <cstdint>

namespace drm {

constexpr int kVoices  = 12;   // 0=K 1=S 2=C 3=R 4=T1 5=T2 6=HATM 7=HATC 8=HATO 9=Crash 10=SUB 11=LONG SUB
constexpr int kSubdiv  = 64;   // master clock subdivisions per bar (64th notes)
constexpr int kSteps   = 512;  // 8 bars × 64 sixty-fourth-notes per bar (max)
constexpr int kSlots   = 4;    // PATTERN A B C D
constexpr int kMaxChain = 32;  // max entries in a pattern chain (song mode)

// Topology-preserving 2-pole state-variable low-pass — per-voice filter.
// Cutoff is set as a normalized 0..1 (UI knob).  1.0 = open (~18 kHz),
// 0 = very dark (~100 Hz).  Resonance fixed mild.
class SVFLowpass {
public:
    void prepare(float sr) { sr_ = sr; reset(); setNorm(1.0f); }
    void reset() { z1_ = z2_ = 0.0f; }
    void setNorm(float n) {
        const float nn = clamp(n, 0.0f, 1.0f);
        // Exponential map 100 Hz .. 18 kHz
        const float fc = 100.0f * std::pow(180.0f, nn);
        const float wd = 2.0f * kPi * fc;
        const float T = 1.0f / sr_;
        const float wa = (2.0f / T) * std::tan(wd * T * 0.5f);
        g_ = wa * T * 0.5f;
        // Mild Q
        const float R = 0.6f;
        h_ = 1.0f / (1.0f + 2.0f * R * g_ + g_ * g_);
        open_ = (nn > 0.985f);
    }
    inline float process(float x) {
        if (open_) return x;  // bypass at full open to preserve transients
        const float yHP = (x - 2.0f * 0.6f * z1_ - g_ * z1_ - z2_) * h_;
        const float yBP = g_ * yHP + z1_;
        const float yLP = g_ * yBP + z2_;
        z1_ = g_ * yHP + yBP;
        z2_ = g_ * yBP + yLP;
        return yLP;
    }
private:
    float sr_ = 48000;
    float g_ = 0.5f, h_ = 1.0f;
    float z1_ = 0, z2_ = 0;
    bool open_ = true;
};

/// Internal drum-bus reverb. Was a 4-comb / 2-allpass Schroeder with NO
/// damping, NO modulation, and barely any stereo decorrelation — sounded
/// metallic and brittle on snare/clap/hat sends. Now: 8 combs with a 1-pole
/// damping LP in each feedback path, slow chorus-style modulation on the
/// comb read positions (breaks up the static ringing), and per-channel
/// delay-length spread for a real stereo image.
class Reverb {
public:
    void prepare(float sr) {
        sr_ = sr;
        // 8 prime-ish comb lengths spread 24..55 ms at 48 kHz, plus a small
        // per-channel offset so L and R run different comb networks.
        // The lengths are 48 kHz sample counts: scale them with the rate so the
        // room (and its decay time) is the same at 44.1 / 96 kHz; the damping
        // pole and the modulation depth are converted the same way.
        const float k = sr / 48000.0f;
        dampR_     = 1.0f - std::pow(1.0f - damp_, 1.0f / k);
        modDepthR_ = modDepth_ * k;
        const int baseL[8] = { 1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617 };
        const int spread   = 31;
        for (int ch = 0; ch < 2; ++ch) {
            for (int i = 0; i < 8; ++i) {
                const int len = (int)std::lround((float)(baseL[i] + (ch ? spread : 0)) * k);
                comb_[ch][i].base = len;
                comb_[ch][i].buf.assign(len + 64 + (int)(4.0f * k), 0.0f); // mod headroom
                comb_[ch][i].idx = 0;
                comb_[ch][i].lp = 0;
                comb_[ch][i].modPhase = (ch ? 0.7f : 0.0f) + i * 0.4f;
                // Each comb modulates at a slightly different rate so they
                // don't pulse together.
                const float modHzTable[8] = {0.62f, 0.71f, 0.83f, 0.97f, 1.11f, 1.27f, 1.43f, 1.59f};
                comb_[ch][i].modInc = 2.0f * 3.14159265358979f * modHzTable[i] * (ch ? 1.07f : 1.0f) / sr;
            }
        }
        const int apLen[3] = { 556, 441, 341 };
        for (int ch = 0; ch < 2; ++ch) {
            for (int i = 0; i < 3; ++i) {
                ap_[ch][i].buf.assign((size_t)std::lround((float)(apLen[i] + (ch ? 17 : 0)) * k), 0.0f);
                ap_[ch][i].idx = 0;
            }
        }
    }
    void reset() {
        for (int ch = 0; ch < 2; ++ch) {
            for (auto &c : comb_[ch]) {
                std::fill(c.buf.begin(), c.buf.end(), 0.0f);
                c.idx = 0; c.lp = 0;
            }
            for (auto &a : ap_[ch]) {
                std::fill(a.buf.begin(), a.buf.end(), 0.0f); a.idx = 0;
            }
        }
    }
    /// In: dry mix to send into reverb. Out: stereo wet signal.
    inline void process(float in, float &wetL, float &wetR) {
        float sums[2] = {0, 0};
        for (int ch = 0; ch < 2; ++ch) {
            for (auto &c : comb_[ch]) {
                const int N = (int)c.buf.size();
                // Modulated read offset around `base` samples ago
                c.modPhase += c.modInc;
                if (c.modPhase > 6.28318530718f) c.modPhase -= 6.28318530718f;
                const float modOff = std::sin(c.modPhase) * modDepthR_;
                float rf = (float)c.idx - (float)c.base + modOff;
                while (rf < 0)       rf += (float)N;
                while (rf >= (float)N) rf -= (float)N;
                const int   r0 = (int)rf;
                const int   r1 = (r0 + 1) % N;
                const float fr = rf - (float)r0;
                const float out = c.buf[r0] + fr * (c.buf[r1] - c.buf[r0]);
                // 1-pole LP in the feedback path — damps highs in the tail
                c.lp += dampR_ * (out - c.lp);
                c.buf[c.idx] = in + c.lp * feedback_;
                if (++c.idx >= N) c.idx = 0;
                sums[ch] += out;
            }
            sums[ch] *= 0.125f;
            // 3 series allpasses for diffusion
            for (auto &a : ap_[ch]) {
                const int N = (int)a.buf.size();
                const float bufOut = a.buf[a.idx];
                const float y = -sums[ch] + bufOut;
                a.buf[a.idx] = sums[ch] + bufOut * 0.5f;
                if (++a.idx >= N) a.idx = 0;
                sums[ch] = y;
            }
        }
        wetL = sums[0];
        wetR = sums[1];
    }
private:
    struct Comb {
        std::vector<float> buf;
        int   idx = 0;
        int   base = 0;
        float lp = 0;
        float modPhase = 0;
        float modInc = 0;
    };
    struct AP { std::vector<float> buf; int idx = 0; };
    Comb comb_[2][8];
    AP   ap_[2][3];
    float sr_       = 48000;
    float feedback_ = 0.85f;   // calmer than before — tails decay sooner
    float damp_     = 0.42f;   // more aggressive damping, less hiss in the tail
    float modDepth_ = 1.0f;    // smaller chorus depth — was reading as noise
    float dampR_ = 0.42f, modDepthR_ = 1.0f;   // the two above, converted to the running rate
};

class DelayTap {
public:
    void prepare(float sr) {
        sr_ = sr;
        buf_.assign((int)std::ceil(0.5f * sr) + 4, 0.0f);  // up to 500 ms
        widx_ = 0;
    }
    void reset() { std::fill(buf_.begin(), buf_.end(), 0.0f); widx_ = 0; }
    void setMs(float ms) { delaySamps_ = clamp(ms * 0.001f * sr_, 1.0f, (float)buf_.size() - 2); }
    void setFeedback(float f) { feedback_ = clamp(f, 0.0f, 0.85f); }
    inline float process(float x) {
        if (buf_.empty()) return x;
        const int N = (int)buf_.size();
        const int d = (int)delaySamps_;
        const int r = (widx_ - d + N) % N;
        const float wet = buf_[r];
        buf_[widx_] = x + wet * feedback_;
        if (++widx_ >= N) widx_ = 0;
        return wet;
    }
private:
    float sr_ = 48000;
    std::vector<float> buf_;
    int widx_ = 0;
    float delaySamps_ = 240, feedback_ = 0.3f;
};

/// One sequencer trigger, captured during an offline render (MIDI export).
struct TrigEvent { long long frame; int voice; float vel; };

class DrumsEngine {
public:
    void prepare(float sr) {
        sr_ = sr;
        noiseDiv_ = (sr >= 160000.0f) ? 4 : (sr >= 80000.0f ? 2 : 1);
        noiseLpK_ = 1.0f - std::pow(1.0f - 0.35f, 48000.0f * (float)noiseDiv_ / sr);
        k_.prepare(sr); s_.prepare(sr); c_.prepare(sr); r_.prepare(sr);
        t1_.prepare(sr); t1_.setHz(80);
        t2_.prepare(sr); t2_.setHz(140);
        // Voice slot 6 is now HAT M (mid hat) instead of TOM 3.
        hm_.prepare(sr); hm_.setOpen(false); hm_.setDecay(0.9985f);
        hc_.prepare(sr); hc_.setOpen(false);
        ho_.prepare(sr); ho_.setOpen(true);
        cr_.prepare(sr);
        sb_.prepare(sr);
        ls_.prepare(sr);
        rev_.prepare(sr);
        for (int i = 0; i < kVoices; ++i) {
            dly_[i].prepare(sr); filt_[i].prepare(sr);
            if (!prepared_) { dly_[i].setMs(0); dly_[i].setFeedback(0.0f); delayMix_[i] = 0; filtN_[i] = 1.0f; reverbSend_[i] = 0.0f; }
            else { setDelayMs(i, lastDlyMs_[i]); setFilterNorm(i, filtN_[i]); }   // re-prepare keeps the user's DLY / FLT
        }
        // First prepare only. The host re-allocates render resources on a
        // sample-rate or buffer-size change (and some hosts restore state
        // BEFORE allocating) — that must not wipe the user's four patterns
        // and reload the factory grooves.
        if (!prepared_) {
        // Zero all 4 pattern slots + per-slot voice state.
        for (int slot = 0; slot < kSlots; ++slot) {
            for (int v = 0; v < kVoices; ++v) {
                for (int s = 0; s < kSteps; ++s) patterns_[slot][v][s] = false;
                slotChar_[slot][v]      = 0;
                slotVelPreset_[slot][v] = 0;
            }
        }
        for (int v = 0; v < kVoices; ++v) resolution_[v] = 16;

        // ── Genre-flavored presets with REAL grooves. Each preset is a
        // 4-bar pattern (looped over the 8-bar buffer = play twice). Bars
        // include syncopation, ghost notes, and fills at bar-4 so the
        // pattern breathes rather than feeling like a repeating 1-bar loop.
        //
        // Voice numbering: 0=K, 1=S, 2=C, 3=R, 4=T1, 5=T2, 6=HAT M,
        //                  7=HAT C, 8=HAT O, 9=Crash, 10=SUB.
        //
        // `setVoice`: set per-voice character + velocity preset for a slot.
        // `barHits`: place hits in one specific bar (0..3) on the listed
        //            16ths. Used to build per-bar variations + fills.
        auto setVoice = [this](int slot, int voice, int chr, int velPreset) {
            slotChar_[slot][voice]      = chr;
            slotVelPreset_[slot][voice] = velPreset;
        };
        auto barHits = [this](int slot, int voice, int bar,
                              std::initializer_list<int> steps16) {
            // Repeat the 4-bar pattern through the full 8-bar buffer.
            for (int rep = 0; rep < 2; ++rep) {
                const int absBar = rep * 4 + bar;
                if (absBar >= 8) break;
                const int base = absBar * kSubdiv;
                for (int s : steps16) {
                    if (s >= 0 && s < 16) patterns_[slot][voice][base + s * 4] = true;
                }
            }
        };
        // Place hits on ONE specific absolute bar (0..7) — used to add
        // bar-7 fills and second-half variations that DON'T repeat with
        // barHits().  Lets each preset breathe over the full 8-bar loop.
        auto absBarHits = [this](int slot, int voice, int absBar,
                                 std::initializer_list<int> steps16) {
            if (absBar < 0 || absBar >= 8) return;
            const int base = absBar * kSubdiv;
            for (int s : steps16) {
                if (s >= 0 && s < 16) patterns_[slot][voice][base + s * 4] = true;
            }
        };
        auto clearBarVoice = [this](int slot, int voice, int absBar) {
            if (absBar < 0 || absBar >= 8) return;
            const int base = absBar * kSubdiv;
            for (int s = 0; s < kSubdiv; ++s) patterns_[slot][voice][base + s] = false;
        };

        // ── Slot A — TECHNO (Detroit/Berlin 4/4, ~128) ──────────────────
        // Classic TR-909 vocabulary: kick every quarter, claps doubling
        // the snare on 2 & 4, offbeat closed hats, open hat lifting on the
        // & of every beat. Bar 4 adds a percussive accent + offbeat rim
        // on "e" of 4 (Robert Hood / Jeff Mills minimal-techno move).
        setVoice(0, 0, 1, 5);   // KICK   — 909 Punch, NUDGE
        setVoice(0, 1, 1, 0);   // SNARE  — Tight 909, FLAT
        setVoice(0, 2, 0, 0);   // CLAP   — STD, FLAT (doubles snare)
        setVoice(0, 3, 0, 0);   // RIM    — for the 909-style accent
        setVoice(0, 7, 0, 1);   // HAT C  — WHT, HAT
        setVoice(0, 8, 0, 0);   // HAT O  — WHT, FLAT
        setVoice(0, 9, 0, 0);   // CRASH
        setVoice(0, 11, 1, 0);  // LONG SUB — PURE, one held note per bar under the kicks
        for (int bar = 0; bar < 4; ++bar) {
            barHits(0, 0, bar, {0, 4, 8, 12});              // 4-on-the-floor
            barHits(0, 11, bar, {0});                       // LONG SUB on the 1
            barHits(0, 1, bar, {4, 12});                    // snare 2 & 4
            barHits(0, 2, bar, {4, 12});                    // clap doubles snare
            barHits(0, 7, bar, {2, 6, 10, 14});             // offbeat 8th hats
            barHits(0, 8, bar, {6});                        // open hat on & of 2
        }
        // Bar 4 — Detroit lift: extra open hat on & of 4 + rim on "e" of 4
        barHits(0, 8, 3, {6, 14});
        barHits(0, 3, 3, {13});                             // rim accent
        patterns_[0][9][0] = true;                          // crash on bar 1

        // ── Slot B — BOOM-BAP / FUNKY DRUMMER (~90 swung) ───────────────
        // Direct nod to the Clyde Stubblefield "Funky Drummer" pattern —
        // the most-sampled break in hip-hop. Kick on 1 + & of 2. Backbeat
        // snare on 2 & 4 with GHOST velocity preset filling the spaces.
        // Hat 16ths with the famous open-hat hit on "ah" of 4 (step 14).
        // Reference: roland.com Behind the Beat — Funky Drummer.
        setVoice(1, 0, 0, 5);   // KICK   — 808 Sub, NUDGE
        setVoice(1, 1, 0, 6);   // SNARE  — STD, GHOST (creates the ghost layer)
        setVoice(1, 7, 0, 2);   // HAT C  — WHT, SWING
        setVoice(1, 8, 0, 0);   // HAT O
        setVoice(1, 9, 0, 0);   // CRASH
        setVoice(1, 11, 0, 0);  // LONG SUB — 808 boom on the 1 and the & of 3
        for (int bar = 0; bar < 4; ++bar) {
            // Kick on 1 and "& of 2" — Funky Drummer foundation
            barHits(1, 0, bar, {0, 6});
            barHits(1, 11, bar, {0, 10});                   // LONG SUB 808
            // Backbeat + ghost snares between. GHOST preset on the snare
            // makes every 3rd hit drop — produces the soft layer naturally.
            barHits(1, 1, bar, {4, 5, 7, 12, 13, 15});
            // Continuous 16th hats — swing preset handles the lopsided feel
            barHits(1, 7, bar, {0, 1, 2, 3, 4, 5, 6, 7,
                                8, 9, 10, 11, 12, 13, 14, 15});
            // The Funky Drummer open-hat lift on "ah" of 4
            barHits(1, 8, bar, {14});
        }
        // Bar 4 — add an extra kick on "ah" of 3 (step 11) for variation
        barHits(1, 0, 3, {11});
        patterns_[1][9][0] = true;                          // crash on bar 1

        // ── Slot C — JUNGLE / AMEN BREAK (~165 BPM) ─────────────────────
        // Authentic 4-bar Amen Break transcription (16th-note grid, 0-idx):
        //   Bar 1:  K . K . S . . K K . K K S . . .    "Amen 1"
        //   Bar 2:  K . K . S . . K K . K K S . . .    "Amen 1"
        //   Bar 3:  K . K . S . . . K . K K . . S .    snare delayed to step 14
        //   Bar 4:  K . K . S . . . K . K . . . S K    closing K-K-S-K roll
        // Hi-hat: straight 16ths (PED for the choked pedal sizzle).
        // Open-hat lift on bar-4's "& of 2".
        // Reference: ethanhein.com Amen Break breakdown + MusicRadar jungle
        // groove guide. https://www.ethanhein.com/wp/2023/building-the-amen-break/
        setVoice(2, 0, 0, 5);   // KICK — 808 Sub, NUDGE
        setVoice(2, 1, 0, 6);   // SNARE — STD, GHOST
        setVoice(2, 7, 2, 1);   // HAT C — PED, HAT preset
        setVoice(2, 8, 0, 0);   // HAT O — WHT
        setVoice(2, 4, 0, 0);   // TOM 1 — for fills
        setVoice(2, 5, 0, 0);   // TOM 2
        // Bar 1 & 2 — Amen base pattern
        barHits(2, 0, 0, {0, 2, 7, 8, 10, 11});
        barHits(2, 1, 0, {4, 12});
        barHits(2, 0, 1, {0, 2, 7, 8, 10, 11});
        barHits(2, 1, 1, {4, 12});
        // Bar 3 — snare on beat-4 delayed by an 8th (step 12 → 14)
        barHits(2, 0, 2, {0, 2, 8, 10, 11});
        barHits(2, 1, 2, {4, 14});
        // Bar 4 — the iconic K-K-S-K closer that defines the break
        barHits(2, 0, 3, {0, 2, 8, 10, 15});
        barHits(2, 1, 3, {4, 14});
        // 16th-note pedal hats throughout
        for (int bar = 0; bar < 4; ++bar) {
            barHits(2, 7, bar, {0, 1, 2, 3, 4, 5, 6, 7,
                                8, 9, 10, 11, 12, 13, 14, 15});
        }
        // Open-hat lift on bar 4 and a small tom fill into the bar-4 roll
        barHits(2, 8, 3, {6, 13});
        barHits(2, 4, 3, {13});
        barHits(2, 5, 3, {14});

        // ── Slot D — DRUM & BASS TWO-STEP (~174 BPM) ────────────────────
        // The defining DnB groove: kick on 1 + 2nd kick pushed to the
        // "& of 3" (step 10) — the signature "stepping" quality. Snare on
        // beats 2 & 4 (steps 4 & 12). Bar 4 closes with a snare roll into
        // the next loop via the RISE velocity preset.
        // SUB doubles every kick for a sub-locked groove. Reference:
        // MusicRadar "How to program 6 DnB grooves" Step 2 (two-step beat).
        setVoice(3, 0, 0, 5);   // KICK — 808 Sub, NUDGE
        setVoice(3, 1, 1, 3);   // SNARE — Tight 909, RISE
        setVoice(3, 7, 2, 1);   // HAT C — PED, HAT
        setVoice(3, 8, 0, 0);   // HAT O
        setVoice(3, 9, 0, 0);   // CRASH
        setVoice(3, 10, 1, 0);  // SUB — TIGHT
        setVoice(3, 11, 4, 0);  // LONG SUB — SLIDE, the two-step's held bass note
        // Bars 0..2 — pure two-step
        for (int bar = 0; bar < 3; ++bar) {
            barHits(3, 0, bar, {0, 10});                    // kick: 1 + & of 3
            barHits(3, 1, bar, {4, 12});                    // snare: 2 & 4
            barHits(3, 7, bar, {0, 1, 2, 3, 4, 5, 6, 7,
                                8, 9, 10, 11, 12, 13, 14, 15});
            barHits(3, 10, bar, {0, 10});                   // SUB locked to kick
            barHits(3, 11, bar, {0});                       // LONG SUB slides under the bar
        }
        // Bar 4 — snare ramping roll into next loop (RISE preset)
        barHits(3, 0, 3, {0, 10});
        barHits(3, 1, 3, {4, 12, 13, 14, 15});
        barHits(3, 7, 3, {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11});
        barHits(3, 8, 3, {6});
        barHits(3, 10, 3, {0, 10});
        patterns_[3][9][0] = true;                          // crash on bar 1

        // ── 8-BAR FILLS — second-half variations & bar-7 turnarounds ──
        // The above `barHits` calls only described bars 0..3 and got mirrored
        // to bars 4..7. Now overwrite specific spots in the second half so
        // the loop has clear arrival points instead of repeating identically.
        //
        // A · TECHNO — bar 7 strips the hat to half-time + adds a full clap roll
        clearBarVoice(0, 7, 7);
        absBarHits(0, 7, 7, {0, 4, 8, 12});                      // half-time hat
        absBarHits(0, 2, 7, {0, 4, 8, 10, 12, 14});              // clap fill
        absBarHits(0, 8, 7, {0, 2, 4, 6, 8, 10, 12, 14});        // open hat sweep
        // B · BOOM-BAP — bar 6 adds an extra kick syncopation, bar 7 snare flam
        absBarHits(1, 0, 6, {3});                                // extra "e of 1"
        absBarHits(1, 1, 7, {11, 13, 14});                       // bar-7 flam
        absBarHits(1, 8, 7, {6, 14});                            // double open hat
        // C · JUNGLE — bar 7 swaps in a denser tom + snare fill rolling into 8
        absBarHits(2, 4, 7, {12, 13});                           // T1 fill
        absBarHits(2, 5, 7, {14});                               // T2 fill
        absBarHits(2, 1, 7, {6, 15});                            // extra snare ghosts
        absBarHits(2, 8, 7, {2, 10, 14});                        // open-hat lift
        // D · D&B TWO-STEP — bar 7 is a full snare buzz roll into next loop
        clearBarVoice(3, 1, 7);
        absBarHits(3, 1, 7, {4, 8, 10, 11, 12, 13, 14, 15});     // snare roll
        absBarHits(3, 0, 7, {0, 4, 10});                         // extra kick on 2
        absBarHits(3, 10, 7, {0, 4, 10});                        // SUB follows
        absBarHits(3, 8, 7, {6, 14});                            // open hat lift

        // Load slot A's voice state into the live per-voice fields so the
        // engine boots ready to play TECHNO out of the box.
        currentSlot_ = 0;
        currentStep_ = 0;
        sampleAccum_ = 0;
        for (int v = 0; v < kVoices; ++v) {
            character_[v]      = slotChar_[0][v];
            voiceVelPreset_[v] = slotVelPreset_[0][v];
            setCharacter(v, character_[v]);  // also push to the voice itself
        }
        }   // !prepared_
        prepared_ = true;
    }

    void reset() {
        k_.reset(); s_.reset(); c_.reset(); r_.reset();
        t1_.reset(); t2_.reset(); hm_.reset(); hc_.reset(); ho_.reset(); cr_.reset();
        sb_.reset(); ls_.reset();
        for (int i = 0; i < kVoices; ++i) { dly_[i].reset(); filt_[i].reset(); }
        rev_.reset();
        for (int i = 0; i < kAdaaMax; ++i) adaaXL_[i] = adaaFL_[i] = adaaXR_[i] = adaaFR_[i] = 0;
        adaaW_ = 0;
        currentStep_ = 0; sampleAccum_ = 0;
    }

    // ── State persistence (project save / restore + named presets) ────
    // Packs every musical/parameter member (all 4 slots' grids, swing, recorded
    // velocities, per-voice params, globals, and the chain) into a byte blob.
    // DSP runtime state (filters, buffers) is rebuilt from those values on load.
    std::vector<uint8_t> serialize() const {
        std::vector<uint8_t> v;
        auto put = [&](const void* p, size_t n) {
            const uint8_t* b = reinterpret_cast<const uint8_t*>(p);
            v.insert(v.end(), b, b + n);
        };
        const uint32_t magic = 0x44524d33u; // 'DRM3' (12 voices; DRM2 = 11 voices, still readable)
        put(&magic, 4);
        put(patterns_,      sizeof(patterns_));
        put(swingLevel_,    sizeof(swingLevel_));
        put(stepVel_,       sizeof(stepVel_));
        put(stepVelSet_,    sizeof(stepVelSet_));
        put(slotChar_,      sizeof(slotChar_));
        put(slotVelPreset_, sizeof(slotVelPreset_));
        put(levels_,        sizeof(levels_));
        put(filtN_,         sizeof(filtN_));
        put(lastDlyMs_,     sizeof(lastDlyMs_));
        put(pitchSemi_,     sizeof(pitchSemi_));
        put(decayVoice_,    sizeof(decayVoice_));
        put(reverbSend_,    sizeof(reverbSend_));
        put(resolution_,    sizeof(resolution_));
        put(character_,     sizeof(character_));
        put(voiceVelPreset_,sizeof(voiceVelPreset_));
        put(mute_,          sizeof(mute_));
        put(solo_,          sizeof(solo_));
        put(chain_,         sizeof(chain_));
        put(&chainLen_, 4); put(&chainPos_, 4);
        put(&currentSlot_, 4); put(&bars_, 4);
        put(&bpm_, 4); put(&swing_, 4);
        put(&globalPitchSemi_, 4); put(&globalNoise_, 4); put(&globalDecay_, 4);
        const uint8_t flags = (isolate_ ? 1 : 0) | (midiMode_ ? 2 : 0);   // appended 2026-11
        put(&flags, 1);
        return v;
    }

    /// Reads a blob written with `V` voices per array into the current
    /// kVoices-sized layout (row by row), so older 11-voice projects load and
    /// the new LONG SUB row simply keeps its defaults.
    void deserializeVoices(const uint8_t* d, size_t n, int V) {
        size_t off = 0;
        auto get = [&](void* p, size_t sz) {
            if (off + sz <= n) { std::memcpy(p, d + off, sz); off += sz; } else off = n + 1;
        };
        auto get3 = [&](void* base, size_t elem) {            // [kSlots][kVoices][kSteps]
            uint8_t* b = reinterpret_cast<uint8_t*>(base);
            for (int sl = 0; sl < kSlots; ++sl) for (int v = 0; v < V; ++v)
                get(b + ((size_t)sl * kVoices + v) * kSteps * elem, (size_t)kSteps * elem);
        };
        auto get2 = [&](void* base, size_t elem) {            // [kSlots][kVoices]
            uint8_t* b = reinterpret_cast<uint8_t*>(base);
            for (int sl = 0; sl < kSlots; ++sl) get(b + (size_t)sl * kVoices * elem, (size_t)V * elem);
        };
        auto get1 = [&](void* base, size_t elem) { get(base, (size_t)V * elem); };   // [kVoices]
        get3(patterns_, sizeof(bool)); get3(swingLevel_, sizeof(uint8_t));
        get3(stepVel_, sizeof(float)); get3(stepVelSet_, sizeof(bool));
        get2(slotChar_, sizeof(int)); get2(slotVelPreset_, sizeof(int));
        get1(levels_, sizeof(float)); get1(filtN_, sizeof(float)); get1(lastDlyMs_, sizeof(float));
        get1(pitchSemi_, sizeof(float)); get1(decayVoice_, sizeof(float)); get1(reverbSend_, sizeof(float));
        get1(resolution_, sizeof(int)); get1(character_, sizeof(int)); get1(voiceVelPreset_, sizeof(int));
        get1(mute_, sizeof(bool)); get1(solo_, sizeof(bool));
        get(chain_, sizeof(chain_));
        get(&chainLen_, 4); get(&chainPos_, 4);
        get(&currentSlot_, 4); get(&bars_, 4);
        get(&bpm_, 4); get(&swing_, 4);
        get(&globalPitchSemi_, 4); get(&globalNoise_, 4); get(&globalDecay_, 4);
        uint8_t flags = 0; get(&flags, 1);   // absent in pre-2026-11 blobs → 0
        isolate_ = (flags & 1) != 0; midiMode_ = (flags & 2) != 0;
    }

    void deserialize(const uint8_t* d, size_t n) {
        if (!d || n < 4) return;
        uint32_t magic = 0; std::memcpy(&magic, d, 4);
        if      (magic == 0x44524d33u) deserializeVoices(d + 4, n - 4, kVoices);  // DRM3
        else if (magic == 0x44524d32u) {                                          // DRM2 — before LONG SUB
            // Rows the old blob does not carry really get their defaults.
            for (int v = 11; v < kVoices; ++v) {
                for (int sl = 0; sl < kSlots; ++sl) {
                    for (int st = 0; st < kSteps; ++st) { patterns_[sl][v][st] = false; swingLevel_[sl][v][st] = 0; stepVel_[sl][v][st] = 1.0f; stepVelSet_[sl][v][st] = false; }
                    slotChar_[sl][v] = 0; slotVelPreset_[sl][v] = 0;
                }
                levels_[v] = 1; filtN_[v] = 1; lastDlyMs_[v] = 0; pitchSemi_[v] = 0; decayVoice_[v] = 1;
                reverbSend_[v] = 0; resolution_[v] = 16; character_[v] = 0; voiceVelPreset_[v] = 0;
                mute_[v] = false; solo_[v] = false;
            }
            deserializeVoices(d + 4, n - 4, 11);
        }
        else return;
        // Sanitise + rebuild derived DSP state from the loaded values.
        if (currentSlot_ < 0 || currentSlot_ >= kSlots) currentSlot_ = 0;
        if (chainLen_ < 0 || chainLen_ > kMaxChain) chainLen_ = 0;
        if (chainPos_ < 0 || chainPos_ >= (chainLen_ > 0 ? chainLen_ : 1)) chainPos_ = 0;
        if (bars_ < 1 || bars_ > 8) bars_ = 2;
        // Values the render thread divides by or feeds into envelopes must be sane.
        if (!(bpm_ >= 20.0f && bpm_ <= 400.0f)) bpm_ = 120.0f;
        if (!(swing_ >= 0.0f && swing_ <= 0.5f)) swing_ = 0.0f;
        for (int vv = 0; vv < kVoices; ++vv) {
            if (resolution_[vv] != 16 && resolution_[vv] != 32 && resolution_[vv] != 64) resolution_[vv] = 16;
            if (voiceVelPreset_[vv] < 0 || voiceVelPreset_[vv] > 7) voiceVelPreset_[vv] = 0;
            if (!(levels_[vv] >= 0.0f && levels_[vv] <= 4.0f)) levels_[vv] = 1.0f;
            if (!(decayVoice_[vv] > 0.0f && decayVoice_[vv] <= 4.0f)) decayVoice_[vv] = 1.0f;
            for (int sl = 0; sl < kSlots; ++sl) for (int st = 0; st < kSteps; ++st)
                if (!(stepVel_[sl][vv][st] >= 0.0f && stepVel_[sl][vv][st] <= 1.0f)) stepVel_[sl][vv][st] = 1.0f;
        }
        for (int vv = 0; vv < kVoices; ++vv) {
            setDelayMs(vv, lastDlyMs_[vv]);   // rebuilds dly_ + delayMix_
            setFilterNorm(vv, filtN_[vv]);    // rebuilds filt_
            setDecayForVoice(vv, decayVoice_[vv]);
            setCharacter(vv, character_[vv]); // pushes character to the voice
        }
        setGlobalPitchSemi(globalPitchSemi_); // re-applies per-voice pitch
    }

    void setFilterNorm(int v, float n) {
        if (v < 0 || v >= kVoices) return;
        filtN_[v] = clamp(n, 0.0f, 1.0f);
        filt_[v].setNorm(filtN_[v]);
    }
    float filterNorm(int v) const { return (v >= 0 && v < kVoices) ? filtN_[v] : 1.0f; }

    void clearVoiceSteps(int v) {
        if (v < 0 || v >= kVoices) return;
        for (int s = 0; s < kSteps; ++s) {
            patterns_[currentSlot_][v][s]   = false;
            swingLevel_[currentSlot_][v][s] = 0;       // wipe per-cell swing ("late") ticks
            stepVelSet_[currentSlot_][v][s] = false;   // and any recorded velocities
        }
        pendingDelay_[v] = -1;                          // cancel an in-flight swing-delayed hit
    }
    void clearAllSteps() {
        for (int v = 0; v < kVoices; ++v) clearVoiceSteps(v);
    }

    void setLevel(int v, float lvl) { if (v >= 0 && v < kVoices) levels_[v] = clamp(lvl, 0.0f, 2.0f); }
    void setMute(int v, bool m)     { if (v >= 0 && v < kVoices) mute_[v] = m; }
    void setSolo(int v, bool s)     { if (v >= 0 && v < kVoices) solo_[v] = s; }
    void setDelayMs(int v, float ms){
        if (v < 0 || v >= kVoices) return;
        lastDlyMs_[v] = ms;
        dly_[v].setMs(std::max(1.0f, ms));
        dly_[v].setFeedback(ms > 0 ? 0.3f : 0);
        delayMix_[v] = ms > 0 ? 0.4f : 0;
    }
    void setBPM(float bpm)          { bpm_ = std::max(20.0f, bpm); }
    void setPlaying(bool p)         { if (p && !playing_) needsHostResync_ = true; playing_ = p; if (!p) sampleAccum_ = 0; }
    void setSwing(float s)          { swing_ = clamp(s, 0.0f, 0.5f); }
    // Host beat position — call once per render block, AFTER setBPM/setPlaying.
    // Locks currentStep_ to Logic's musical clock. Old behaviour only re-synced
    // on a backward loop, so hitting play from an arbitrary bar left the
    // sequencer out of phase. Now we hard-snap on (re)start OR on ANY transport
    // discontinuity (loop, or dropping the playhead at a new bar), detected by
    // comparing Logic's actual beat advance against the advance we'd expect
    // from elapsed samples. During continuous playback the two agree, so we
    // leave the free-running step alone and never stutter.
    void setHostBeatPosition(double beatPos) {
        const int active = std::max(1, bars_ * kSubdiv);  // kSubdiv=64 ticks/bar, 1 bar=4 beats
        const double ticks = beatPos * (double)kSubdiv / 4.0;
        long t = (long)std::floor(ticks);
        int target = (int)(((t % active) + active) % active);

        // `expected` must use the tempo the elapsed samples RAN at; setBPM has
        // already stored the new tempo, so a tempo-list jump looked like a
        // transport jump and refired the current step.
        const double ranBpm = lastBlockBpm_ > 0.0 ? lastBlockBpm_ : (double)bpm_;
        const double expected = (double)samplesSinceHostBeat_ / (double)sr_ * ranBpm / 60.0;
        const double actual   = beatPos - lastHostBeat_;
        const bool jumped = std::fabs(actual - expected) > 0.03;  // < a 64th note

        if (needsHostResync_ || jumped) {
            currentStep_ = target;
            sampleAccum_ = 0;
            lastAbsTick_ = LLONG_MIN;   // refire at the new position on the next frame
            for (int vi = 0; vi < kVoices; ++vi) voiceHitCount_[vi] = 0;
            // Song mode follows Logic's absolute position: pattern index =
            // which loop of the chain the bar sits in. (Snapping to tick 0
            // used to count as a loop wrap and skipped the chain's first entry.)
            if (chainLen_ > 0 && !isolate_) {
                const long long loops = (long long)std::floor((double)t / (double)active);
                chainPos_ = (int)(((loops % chainLen_) + chainLen_) % chainLen_);
                const int ns = chain_[chainPos_];
                if (ns != currentSlot_) setSlot(ns);
                currentStep_ = target;
            }
            needsHostResync_ = false;
        }
        lastBlockBpm_ = (double)bpm_;
        hostLocked_ = true;
        samplesSinceHostBeat_ = 0;
        lastHostBeat_ = beatPos;
    }

    // Pattern slot (A=0, B=1, C=2, D=3). Switching slots also swaps the
    // per-voice CHARACTER and VELOCITY preset choices, so the four slots
    // really behave like four different kits / genres.
    void setSlot(int slot) {
        if (slot < 0 || slot >= kSlots) return;
        // Save current per-voice state into the slot we're leaving so user
        // tweaks stick when they come back.
        for (int v = 0; v < kVoices; ++v) {
            slotChar_[currentSlot_][v]      = character_[v];
            slotVelPreset_[currentSlot_][v] = voiceVelPreset_[v];
        }
        currentSlot_ = slot;
        currentStep_ = 0;     // reset playhead to top of new pattern
        sampleAccum_ = 0;
        for (int v = 0; v < kVoices; ++v) voiceHitCount_[v] = 0;
        // Load the destination slot's saved state into the live voices.
        for (int v = 0; v < kVoices; ++v) {
            voiceVelPreset_[v] = slotVelPreset_[slot][v];
            setCharacter(v, slotChar_[slot][v]);  // pushes to the voice + character_[]
        }
    }
    int  currentSlot() const { return currentSlot_; }

    // ── Pattern chaining (song mode) ──────────────────────────────────
    // A chain is an ordered list of slots (e.g. A→B→A→C). When the chain
    // has entries, the sequencer advances to the next chain entry every
    // time the loop wraps (see the render loop). Empty chain = off, the
    // single currently-selected slot just loops as before.
    void setChain(const int* slots, int n) {
        if (n < 0) n = 0; if (n > kMaxChain) n = kMaxChain;
        chainLen_ = n;
        for (int i = 0; i < n; ++i) {
            int s = slots[i];
            if (s < 0) s = 0; if (s >= kSlots) s = kSlots - 1;
            chain_[i] = s;
        }
        if (chainPos_ >= chainLen_) chainPos_ = 0;
        // When stopped, jump straight to the head of the chain so the user
        // sees/edits the first pattern. While playing, leave the playhead be
        // and let it pick up the new chain at the next loop wrap.
        if (chainLen_ > 0 && !playing_ && !isolate_) { chainPos_ = 0; setSlot(chain_[0]); }
    }
    void clearChain() { chainLen_ = 0; chainPos_ = 0; }

    // ISOLATE — the active slot loops on its own; the chain stays stored and
    // resumes (host-locked: at the position Logic's bar count implies) when off.
    void setIsolate(bool on) { isolate_ = on; }
    bool isolate() const     { return isolate_; }
    bool chainActive() const { return chainLen_ > 0 && !isolate_; }

    // MIDI MODE — the internal sequencer stops firing; incoming MIDI notes only
    // play the voices (no record-into-pattern). Used after EXPORT MIDI so the
    // host's MIDI region plays the machine without doubling.
    void setMidiMode(bool on) { midiMode_ = on; if (on) for (int v = 0; v < kVoices; ++v) pendingDelay_[v] = -1; }
    bool midiMode() const     { return midiMode_; }

    // Row copy / swap for the drag handle (active slot): steps, per-step swing
    // and velocity, plus the voice's resolution and velocity preset so the
    // destination really plays the same rhythm.
    void copyRow(int src, int dst) {
        if (src < 0 || src >= kVoices || dst < 0 || dst >= kVoices || src == dst) return;
        const int sl = currentSlot_;
        std::memcpy(patterns_[sl][dst],   patterns_[sl][src],   sizeof(patterns_[sl][src]));
        std::memcpy(swingLevel_[sl][dst], swingLevel_[sl][src], sizeof(swingLevel_[sl][src]));
        std::memcpy(stepVel_[sl][dst],    stepVel_[sl][src],    sizeof(stepVel_[sl][src]));
        std::memcpy(stepVelSet_[sl][dst], stepVelSet_[sl][src], sizeof(stepVelSet_[sl][src]));
        resolution_[dst] = resolution_[src];
        voiceVelPreset_[dst] = voiceVelPreset_[src];
        slotVelPreset_[sl][dst] = voiceVelPreset_[src];
        pendingDelay_[dst] = -1;
    }
    void swapRows(int a, int b) {
        if (a < 0 || a >= kVoices || b < 0 || b >= kVoices || a == b) return;
        const int sl = currentSlot_;
        for (int st = 0; st < kSteps; ++st) {
            std::swap(patterns_[sl][a][st],   patterns_[sl][b][st]);
            std::swap(swingLevel_[sl][a][st], swingLevel_[sl][b][st]);
            std::swap(stepVel_[sl][a][st],    stepVel_[sl][b][st]);
            std::swap(stepVelSet_[sl][a][st], stepVelSet_[sl][b][st]);
        }
        std::swap(resolution_[a], resolution_[b]);
        std::swap(voiceVelPreset_[a], voiceVelPreset_[b]);
        slotVelPreset_[sl][a] = voiceVelPreset_[a]; slotVelPreset_[sl][b] = voiceVelPreset_[b];
        pendingDelay_[a] = pendingDelay_[b] = -1;
    }
    // Per-step recorded velocity (for undo snapshots).
    float stepVelocity(int v, int s) const {
        return (v >= 0 && v < kVoices && s >= 0 && s < kSteps) ? stepVel_[currentSlot_][v][s] : 1.0f;
    }
    bool stepVelocitySet(int v, int s) const {
        return (v >= 0 && v < kVoices && s >= 0 && s < kSteps) ? stepVelSet_[currentSlot_][v][s] : false;
    }
    void setStepVelocity(int v, int s, float vel, bool set) {
        if (v < 0 || v >= kVoices || s < 0 || s >= kSteps) return;
        stepVel_[currentSlot_][v][s] = clamp(vel, 0.0f, 1.0f);
        stepVelSet_[currentSlot_][v][s] = set;
    }
    bool mutedOrNotSoloed(int v) const {
        bool anySolo = false;
        for (int i = 0; i < kVoices; ++i) if (solo_[i]) { anySolo = true; break; }
        return anySolo ? !solo_[v] : mute_[v];
    }
    void forceSolo(int v) { for (int i = 0; i < kVoices; ++i) { solo_[i] = (i == v); mute_[i] = false; } }
    void setGlobalNoiseRaw(float n) { globalNoise_ = n; }

    // Offline render start (exports): free-running clock, chain head (unless
    // ISOLATE), and the very first frame fires step 0.
    void beginOfflinePlayback() {
        hostLocked_ = false; midiMode_ = false;
        for (int v = 0; v < kVoices; ++v) { voiceHitCount_[v] = 0; pendingDelay_[v] = -1; }
        if (chainActive()) { chainPos_ = chainLen_ - 1; setSlot(chain_[chainPos_]); }
        else               { setSlot(currentSlot_); }
        currentStep_ = std::max(1, bars_ * kSubdiv) - 1;
        sampleAccum_ = 0; forceBoundary_ = true; playing_ = true; needsHostResync_ = false;
    }
    /// Frames one pass of the export range lasts (chain loops × bars, or the
    /// isolated slot once) at `sr`.
    long long offlineLengthFrames(float sr) const {
        const int loops = chainActive() ? chainLen_ : 1;
        const double sec = (double)loops * bars_ * 4.0 * 60.0 / (double)bpm_;
        return (long long)std::llround(sec * sr);
    }
    float bpm() const { return bpm_; }
    int  chainLength() const { return chainLen_; }
    int  chainSlotAt(int i) const { return (i >= 0 && i < chainLen_) ? chain_[i] : -1; }
    int  chainPosition() const { return chainPos_; }

    // Bars (1..8). Sequencer wraps at bars_ * kSubdiv steps.
    void setBars(int b) { bars_ = std::max(1, std::min(8, b)); }
    int  bars() const   { return bars_; }

    // Per-voice resolution in subdivisions per bar (8, 16, 32, or 64).
    // A voice fires only when (internalStep % (kSubdiv / resolution)) == 0
    // AND its stored pattern bit is on.
    void setResolution(int v, int res) {
        if (v < 0 || v >= kVoices) return;
        if (res != 8 && res != 16 && res != 32 && res != 64) return;
        resolution_[v] = res;
    }
    int resolution(int v) const { return (v >= 0 && v < kVoices) ? resolution_[v] : 16; }

    /// Number of CHARACTER variants for a given voice (now 5 across the board,
    /// but resolved per-voice so it stays correct if any voice changes).
    int characterCount(int v) const {
        switch (v) {
            case 0:  return Kick::kNumChars;
            case 1:  return Snare::kNumChars;
            case 2:  return Clap::kNumChars;
            case 3:  return Rim::kNumChars;
            case 4: case 5: return Tom::kNumChars;
            case 6: case 7: case 8: return Hat::kNumChars;
            case 9:  return Crash::kNumChars;
            case 10: return Sub::kNumChars;
            case 11: return LongSub::kNumChars;
            default: return 1;
        }
    }
    /// Short display name for character `c` of voice `v` (e.g. "808", "AMEN").
    const char* characterName(int v, int c) const {
        switch (v) {
            case 0:  return Kick::charName(c);
            case 1:  return Snare::charName(c);
            case 2:  return Clap::charName(c);
            case 3:  return Rim::charName(c);
            case 4: case 5: return Tom::charName(c);
            case 6: case 7: case 8: return Hat::charName(c);
            case 9:  return Crash::charName(c);
            case 10: return Sub::charName(c);
            case 11: return LongSub::charName(c);
            default: return "";
        }
    }

    /// Per-voice CHARACTER variant (0..characterCount(v)-1). Engine forwards
    /// to the appropriate voice's setCharacter().
    void setCharacter(int v, int c) {
        if (v < 0 || v >= kVoices) return;
        const int clamped = std::max(0, std::min(characterCount(v) - 1, c));
        character_[v] = clamped;
        slotChar_[currentSlot_][v] = clamped;   // persist for current slot
        switch (v) {
            case 0: k_.setCharacter(clamped); break;
            case 1: s_.setCharacter(clamped); break;
            case 2: c_.setCharacter(clamped); break;
            case 3: r_.setCharacter(clamped); break;
            case 4: t1_.setCharacter(clamped); break;
            case 5: t2_.setCharacter(clamped); break;
            case 6: hm_.setCharacter(clamped); break;
            case 7: hc_.setCharacter(clamped); break;
            case 8: ho_.setCharacter(clamped); break;
            case 9: cr_.setCharacter(clamped); break;
            case 10: sb_.setCharacter(clamped); break;
            case 11: ls_.setCharacter(clamped); break;
        }
    }
    int character(int v) const { return (v >= 0 && v < kVoices) ? character_[v] : 0; }

    // Per-voice pitch in semitones (-24..+24 typical, clamped at the voice).
    // Setter routes (per-voice + global) through 2^(semi/12) to the voice.
    void setPitchSemi(int v, float semi) {
        if (v < 0 || v >= kVoices) return;
        pitchSemi_[v] = semi;
        applyVoicePitch(v);
    }
    float pitchSemi(int v) const { return (v >= 0 && v < kVoices) ? pitchSemi_[v] : 0.0f; }

    // ── Global controls — affect every voice ─────────────────────────
    // Global pitch in semitones is added on top of each voice's per-voice
    // pitch and re-applied. Range exposed to UI: -12..+12 typically.
    void setGlobalPitchSemi(float semi) {
        globalPitchSemi_ = semi;
        for (int v = 0; v < kVoices; ++v) applyVoicePitch(v);
    }
    float globalPitchSemi() const { return globalPitchSemi_; }

    // Global noise — analog-style grit mixed into the master output. 0 = clean,
    // 1 = audible noise floor (think 909/606 hiss + tape grain). Implemented as
    // soft-filtered white noise summed with the dry mix, attenuated by the
    // average voice envelope so the noise dips when nothing is playing.
    void setGlobalNoise(float n) {
        globalNoise_ = clamp(n, 0.0f, 1.0f);
    }
    float globalNoise() const { return globalNoise_; }

    // ── Global DECAY / sample-shortening ─────────────────────────────
    // 1.0 = no shortening (each voice plays its natural tail).
    // 0.0 = aggressively gated — full mute in ~5 ms after each trigger.
    // The gate is per-voice (refreshed when that voice retriggers) so a
    // long crash isn't cut off by a kick on the next 16th.
    // Map a 0..1 decay value to a per-sample gate multiplier. 1.0 (== top of
    // the knob) bypasses the gate entirely so natural tails are preserved;
    // anything lower engages a quadratically-mapped exponential gate so the
    // upper half stays musical and the bottom gets choppy / 909-style.
    static inline float gateRateFromDecay(float d, float sr) {
        if (d >= 0.999f) return 1.0f;
        const float minTau = 0.005f * sr;            // 5 ms at d=0
        const float maxTau = 8.0f   * sr;            // 8 s near d=1
        const float tau    = minTau + (maxTau - minTau) * d * d;
        return std::exp(-1.0f / tau);
    }
    // Combined gate = global master × per-voice. Both default 1.0 (no gate).
    void recomputeGate(int v) {
        voiceGateRate_[v] = gateRateFromDecay(globalDecay_, sr_)
                          * gateRateFromDecay(decayVoice_[v], sr_);
    }
    void setGlobalDecay(float d) {
        globalDecay_ = clamp(d, 0.0f, 1.0f);
        for (int v = 0; v < kVoices; ++v) recomputeGate(v);
    }
    float globalDecay() const { return globalDecay_; }
    // Per-voice DECAY (0..1) — shortens just this instrument's sound.
    void setDecayForVoice(int v, float d) {
        if (v < 0 || v >= kVoices) return;
        decayVoice_[v] = clamp(d, 0.0f, 1.0f);
        recomputeGate(v);
    }
    float decayForVoice(int v) const { return (v >= 0 && v < kVoices) ? decayVoice_[v] : 1.0f; }

    // ── Per-VOICE velocity preset ───────────────────────────────────
    // Each preset tuned for a particular voice "personality". Counts only
    // TICKED steps for that voice — so rhythms with sparse hits get sensible
    // walks rather than step-grid alternation.
    //
    //   0 FLAT      every hit full (default)
    //   1 HAT       hat-style 16-step variation — busy, alive
    //   2 SWING     heavy on beat-1 of each pair, light on the &
    //   3 RISE      slow crescendo over 16 hits, resets on loop  ← snare
    //   4 BUILD     fast 4-hit ramp (good for fills)
    //   5 NUDGE     only varies hits in rapid runs (<200ms apart)  ← kick
    //   6 GHOST     every 3rd hit ghosted
    //   7 HUMAN     gentle ±10% per hit
    static constexpr int kVelPresetCount = 8;
    void setVelocityPresetForVoice(int v, int p) {
        if (v < 0 || v >= kVoices) return;
        const int clamped = (p >= 0 && p < kVelPresetCount) ? p : 0;
        voiceVelPreset_[v] = clamped;
        slotVelPreset_[currentSlot_][v] = clamped;  // persist for current slot
    }
    int velocityPresetForVoice(int v) const {
        return (v >= 0 && v < kVoices) ? voiceVelPreset_[v] : 0;
    }
    /// UI-facing preview: what velocity will the Nth hit of voice v fire at?
    /// NUDGE's "rapid run" branch is suppressed for preview (we don't know
    /// timing at draw time) — it always renders as 1.0 for that preset.
    float previewVelocityForVoice(int v, int hitIdx) const {
        return velocityForVoiceHit(v, hitIdx, 1 << 28);
    }

    static const char* velocityPresetName(int p) {
        switch (p) {
            case 0: return "FLAT";
            case 1: return "HAT";
            case 2: return "SWING";
            case 3: return "RISE";
            case 4: return "BUILD";
            case 5: return "NUDGE";
            case 6: return "GHOST";
            case 7: return "HUMAN";
            default: return "FLAT";
        }
    }

private:
    // Velocity for the Nth hit of a voice, with context about how recently
    // that voice last fired (for the NUDGE preset). `samplesSinceLast` is
    // INT32_MAX when this is the first hit / there hasn't been a recent one.
    inline float velocityForVoiceHit(int v, int hitIdx, int samplesSinceLast) const {
        if (v < 0 || v >= kVoices) return 1.0f;
        auto hash = [](int v, int i) {
            uint32_t s = (uint32_t)(v * 73856093u ^ i * 19349663u);
            s = s * 2654435761u;
            return (float)((s >> 24) & 0xFF) / 255.0f;   // 0..1
        };
        switch (voiceVelPreset_[v]) {
            case 0: return 1.0f;                                          // FLAT
            case 1: {                                                     // HAT — 16-step groove (wide dynamic range)
                static const float p[16] = {
                    1.00f, 0.32f, 0.75f, 0.40f,
                    0.92f, 0.28f, 0.70f, 0.36f,
                    0.88f, 0.30f, 0.72f, 0.34f,
                    0.85f, 0.26f, 0.68f, 0.32f
                };
                return p[hitIdx & 15];
            }
            case 2: return (hitIdx & 1) ? 0.35f : 1.0f;                   // SWING — heavy on beat, near-ghost off-beat
            case 3: {                                                     // RISE — slow crescendo
                const int phase = hitIdx & 15;                            // 0..15
                return 0.40f + 0.60f * ((float)phase / 15.0f);
            }
            case 4: {                                                     // BUILD — fast 4-hit ramp
                static const float r[4] = { 0.55f, 0.72f, 0.86f, 1.00f };
                return r[hitIdx & 3];
            }
            case 5: {                                                     // NUDGE — kick variation in runs
                // Only vary hits that landed within ~200 ms of the previous
                // one. Isolated hits play full strength. Variation is ±12%.
                const float threshold = 0.20f * sr_;                      // 200 ms in samples
                if (samplesSinceLast > (int)threshold) return 1.0f;
                return 0.88f + hash(v, hitIdx) * 0.12f;
            }
            case 6: return ((hitIdx % 3) == 2) ? 0.42f : 1.0f;            // GHOST — every 3rd ghosted
            case 7: return 0.90f + hash(v, hitIdx) * 0.10f;               // HUMAN — gentle ±10%
            default: return 1.0f;
        }
    }

public:

    void setStep(int v, int s, bool on) {
        if (v >= 0 && v < kVoices && s >= 0 && s < kSteps) {
            patterns_[currentSlot_][v][s] = on;
            // Erasing a step drops its per-cell swing ("late") tick and any
            // recorded velocity, so an off cell carries no stale state (this
            // also covers preset-load, which clears every step first).
            if (!on) {
                swingLevel_[currentSlot_][v][s] = 0;
                stepVelSet_[currentSlot_][v][s] = false;
            }
        }
    }
    bool getStep(int v, int s) const {
        return (v >= 0 && v < kVoices && s >= 0 && s < kSteps) ? patterns_[currentSlot_][v][s] : false;
    }
    bool isMuted(int v) const           { return v >= 0 && v < kVoices && mute_[v]; }
    bool isSoloed(int v) const          { return v >= 0 && v < kVoices && solo_[v]; }
    float level(int v) const            { return v >= 0 && v < kVoices ? levels_[v] : 1.0f; }
    float delayMs(int v) const          { return v >= 0 && v < kVoices ? lastDlyMs_[v] : 0.0f; }

    /// Trigger a voice from MIDI or UI.
    void triggerVoice(int v, float velocity) {
        switch (v) {
            case 0: k_.trigger(velocity); break;
            case 1: s_.trigger(velocity); break;
            case 2: c_.trigger(velocity); break;
            case 3: r_.trigger(velocity); break;
            case 4: t1_.trigger(velocity); break;
            case 5: t2_.trigger(velocity); break;
            case 6: hm_.trigger(velocity); break;   // HAT M (was TOM 3)
            case 7: hc_.trigger(velocity); break;
            case 8: ho_.trigger(velocity); break;
            case 9: cr_.trigger(velocity); break;
            case 10: sb_.trigger(velocity); break;  // SUB
            case 11: ls_.trigger(velocity); break;  // LONG SUB
        }
        // Refresh the per-voice global-DECAY gate so this hit gets its
        // shortened-or-not tail starting from full amplitude.
        if (v >= 0 && v < kVoices) voiceGateEnv_[v] = 1.0f;
    }

    /// Fire a sequencer step's voice: trigger it and set up the velocity-driven
    /// tail-shortening + "since last hit" bookkeeping. Used by both immediate
    /// hits and swing-delayed (pending) hits so they behave identically.
    void fireStepTrigger(int v, float vel) {
        if (capture_) capture_->push_back({captureFrame_, v, vel});
        triggerVoice(v, vel);
        samplesSinceLastHit_[v] = 0;
        if (vel >= 0.99f) {
            voiceVelRate_[v] = 1.0f;
        } else {
            const float tau = (0.08f + 7.92f * vel * vel) * sr_;
            voiceVelRate_[v] = std::exp(-1.0f / tau);
        }
    }

    /// Per-cell SWING level (0..4). 0 = straight; 1..4 ≈ MPC 54/58/62/66%
    /// (~15/30/50/70 ms @ 90 BPM), delaying just that hit.
    int stepSwing(int v, int s) const {
        return (v >= 0 && v < kVoices && s >= 0 && s < kSteps) ? (int)swingLevel_[currentSlot_][v][s] : 0;
    }
    void setStepSwing(int v, int s, int level) {
        if (v < 0 || v >= kVoices || s < 0 || s >= kSteps) return;
        swingLevel_[currentSlot_][v][s] = (uint8_t)std::max(0, std::min(4, level));
    }

    // ── Live record (Maschine pads → grid) ──────────────────────────
    void setRecordArmed(bool on) { recordArmed_ = on; }
    bool recordArmed() const     { return recordArmed_; }

    /// Called from the MIDI handler for every incoming note. Always triggers
    /// the voice so the pad is audible (monitoring). When armed AND the
    /// transport is running, it also writes the hit into the active pattern at
    /// the nearest step on this voice's resolution grid, capturing the played
    /// velocity (stored per-step so it overrides the velocity preset).
    void recordNote(int v, float velocity) {
        triggerVoice(v, velocity);
        if (midiMode_ || !recordArmed_ || !playing_ || v < 0 || v >= kVoices) return;
        const int divisor    = kSubdiv / resolution_[v];          // 8/4/2/1
        const int activeSteps = std::max(divisor, bars_ * kSubdiv);
        int q = ((currentStep_ + divisor / 2) / divisor) * divisor; // quantize
        q %= activeSteps;
        patterns_[currentSlot_][v][q]   = true;
        stepVel_[currentSlot_][v][q]    = clamp(velocity, 0.0f, 1.0f);
        stepVelSet_[currentSlot_][v][q] = true;
    }

    /// Per-voice reverb send 0..1.
    void setReverbSend(int v, float s) {
        if (v < 0 || v >= kVoices) return;
        reverbSend_[v] = clamp(s, 0.0f, 1.0f);
    }
    float reverbSend(int v) const { return (v >= 0 && v < kVoices) ? reverbSend_[v] : 0.0f; }

    int currentStep() const { return currentStep_; }

    inline void processFrame(float& outL, float& outR) {
        // Count elapsed frames so setHostBeatPosition can tell continuous
        // playback from a transport jump (see that function).
        ++samplesSinceHostBeat_;
        // Host-locked musical time for this frame (beats) — see setHostBeatPosition.
        if (hostLocked_)
            hostBeatNow_ = lastHostBeat_ + (double)(samplesSinceHostBeat_ - 1) / (double)sr_ * (double)bpm_ / 60.0;
        // Sequencer — master clock at 64th-note resolution. Per-voice
        // firing is masked by the voice's resolution_ so res=8 voices fire
        // every 8th tick, res=16 every 4th, res=32 every 2nd, res=64 every.
        //
        // MPC swing: each 8 internal ticks = one 16th-note pair. swing_
        // (UI shows 0..50%) sets how much of the pair the first 16th gets.
        // 0 = even (50/50), 0.5 = full shuffle (75/25). Classic MPC sits
        // around 12–20% on this scale.
        if (playing_) {
            const float pairDuration = sr_ * 60.0f / (bpm_ * 2.0f);  // 8 64ths = 1 8th
            const float w = 0.5f + swing_ * 0.5f;                     // 0.5 .. 1.0
            const int sixteenthOfPair = (currentStep_ / 4) & 1;       // 0 = first 16th, 1 = second
            const float thisSixteenthDur = pairDuration * (sixteenthOfPair == 0 ? w : (1.0f - w));
            const float samplesPerStep = std::max(1.0f, thisSixteenthDur * 0.25f);

            const int activeSteps = bars_ * kSubdiv;
            bool boundary = false; int nextStep = currentStep_;
            if (hostLocked_) {
                // Absolute 64th tick derived from Logic's beat position, with the
                // MPC swing folded in (first 16th of each pair lasts w, second 1-w),
                // so the machine can never drift against the project grid.
                const double pairs = hostBeatNow_ * 2.0;
                const double pairIdx = std::floor(pairs);
                const double u = pairs - pairIdx;
                const double wd = (double)w;
                const int tickInPair = (u < wd) ? std::min(3, (int)(u / wd * 4.0))
                                                : 4 + std::min(3, (int)((u - wd) / std::max(1e-6, 1.0 - wd) * 4.0));
                const long long absTick = (long long)pairIdx * 8 + tickInPair;
                if (absTick != lastAbsTick_) {
                    lastAbsTick_ = absTick; boundary = true;
                    nextStep = (int)(((absTick % activeSteps) + activeSteps) % activeSteps);
                }
            } else if (forceBoundary_) {
                forceBoundary_ = false; sampleAccum_ = 0; boundary = true;
                nextStep = (currentStep_ + 1) % activeSteps;
            } else if (sampleAccum_ >= samplesPerStep) {
                sampleAccum_ -= samplesPerStep; boundary = true;
                nextStep = (currentStep_ + 1) % activeSteps;
            }
            if (boundary) {
                // Loop wrap — reset per-voice hit counters so velocity
                // patterns stay aligned with the loop, not drifting.
                if (nextStep == 0) {
                    for (int vi = 0; vi < kVoices; ++vi) voiceHitCount_[vi] = 0;
                    // Song mode: at every loop wrap, step to the next slot in
                    // the chain. setSlot() also re-zeroes currentStep_ (already
                    // 0 here) and swaps the per-slot CHARACTER / VEL state.
                    if (chainLen_ > 0 && !isolate_) {
                        if (hostLocked_) {
                            // Absolute: the chain entry is derived from Logic's bar count.
                            const long long loops = (long long)std::floor((double)lastAbsTick_ / (double)activeSteps);
                            chainPos_ = (int)(((loops % chainLen_) + chainLen_) % chainLen_);
                        } else {
                            chainPos_ = (chainPos_ + 1) % chainLen_;
                        }
                        const int ns = chain_[chainPos_];
                        if (ns != currentSlot_) setSlot(ns);
                    }
                }
                currentStep_ = nextStep;
                // MIDI MODE: the playhead keeps moving (UI), nothing fires.
                for (int v = 0; v < kVoices && !midiMode_; ++v) {
                    const int divisor = kSubdiv / resolution_[v];   // 8/4/2/1
                    if ((currentStep_ % divisor) == 0 &&
                        patterns_[currentSlot_][v][currentStep_]) {
                        // Pass the per-voice hit index (counts only ticked steps
                        // for THIS voice) so velocity presets walk the rhythm,
                        // not the raw step grid. Also pass the time since this
                        // voice last fired — NUDGE uses it to detect rapid runs.
                        const int hitIdx = voiceHitCount_[v]++;
                        const int sinceLast = samplesSinceLastHit_[v];
                        // Recorded (live-played) velocity overrides the preset.
                        const float vel = stepVelSet_[currentSlot_][v][currentStep_]
                                        ? stepVel_[currentSlot_][v][currentStep_]
                                        : velocityForVoiceHit(v, hitIdx, sinceLast);
                        // Per-cell SWING — push just this hit late by a musical
                        // fraction of a 16th note (levels map to MPC 54/58/62/66%
                        // ≈ 15/30/50/70 ms @ 90 BPM, tempo-scaled). Level 0 fires
                        // immediately; otherwise schedule a delayed (pending) hit.
                        const int sw = (int)swingLevel_[currentSlot_][v][currentStep_];
                        if (sw > 0) {
                            static const float swingFrac[5] = {0.0f, 0.09f, 0.18f, 0.30f, 0.42f};
                            const float sixteenthDur = sr_ * 60.0f / (bpm_ * 4.0f);
                            pendingDelay_[v] = (int)(swingFrac[sw] * sixteenthDur);
                            pendingVel_[v]   = vel;
                        } else {
                            fireStepTrigger(v, vel);   // sets vel-rate + sinceLast
                        }
                    }
                }
            }
            sampleAccum_ += 1.0f;
        }

        // Fire any swing-delayed (pending) triggers whose countdown elapsed.
        for (int v = 0; v < kVoices; ++v) {
            if (pendingDelay_[v] >= 0) {
                if (pendingDelay_[v] == 0) { fireStepTrigger(v, pendingVel_[v]); pendingDelay_[v] = -1; }
                else                        pendingDelay_[v]--;
            }
        }

        // Voice render
        float sum = 0.0f;
        float perVoice[kVoices];
        perVoice[0] = k_.process();
        perVoice[1] = s_.process();
        perVoice[2] = c_.process();
        perVoice[3] = r_.process();
        perVoice[4] = t1_.process();
        perVoice[5] = t2_.process();
        perVoice[6] = hm_.process();     // HAT M (was TOM 3)
        perVoice[7] = hc_.process();
        perVoice[8] = ho_.process();
        perVoice[9] = cr_.process();
        perVoice[10] = sb_.process();    // SUB
        perVoice[11] = ls_.process();    // LONG SUB
        // Solo overrides mute
        bool anySolo = false;
        for (int v = 0; v < kVoices; ++v) if (solo_[v]) { anySolo = true; break; }
        float revIn = 0.0f;
        for (int v = 0; v < kVoices; ++v) {
            const bool playV = anySolo ? solo_[v] : !mute_[v];
            const float gate = playV ? 1.0f : 0.0f;
            // Per-voice global-DECAY envelope — sample-shortening / "snappier"
            // knob. Decays each sample by voiceGateRate_ (set by setGlobalDecay).
            // Refreshed to 1.0 inside triggerVoice() so every hit starts open.
            float dry = perVoice[v] * levels_[v] * gate * voiceGateEnv_[v];
            // Combine global DECAY gate with the per-hit velocity-driven
            // shortening so soft hits decay faster than loud ones.
            voiceGateEnv_[v] *= voiceGateRate_[v] * voiceVelRate_[v];
            dry = filt_[v].process(dry);
            const float wet = dly_[v].process(dry);
            sum += dry + wet * delayMix_[v];
            revIn += dry * reverbSend_[v];
            // Tick "samples since last hit" — capped to avoid overflow over
            // very long idle periods. Used by NUDGE velocity preset.
            if (samplesSinceLastHit_[v] < (1 << 28)) samplesSinceLastHit_[v]++;
        }
        // Reverb wet — single shared tank.
        float wetL = 0.0f, wetR = 0.0f;
        rev_.process(revIn * 0.5f, wetL, wetR);
        float mixL = sum + wetL;
        float mixR = sum + wetR;

        // Global noise floor — analog-style grit. White noise lightly low-passed
        // so it reads as "tape hiss" rather than digital fizz. Decorrelated
        // L/R taps for natural width.
        if (globalNoise_ > 0.0001f) {
            // (one new value per 48 kHz-sized tick, so the hiss has the same
            //  level and colour at every sample rate)
            if (++noiseTick_ >= noiseDiv_) {
                noiseTick_ = 0;
                noiseRng_ = noiseRng_ * 1664525u + 1013904223u;
                const float wn  = (((noiseRng_ >> 8) & 0x00FFFFFF) / 8388608.0f - 1.0f);
                noiseLpZ_ += noiseLpK_ * (wn - noiseLpZ_); // mild LP
                noiseRng_ = noiseRng_ * 1664525u + 1013904223u;
                noiseW2_ = (((noiseRng_ >> 8) & 0x00FFFFFF) / 8388608.0f - 1.0f);
            }
            const float wn2 = noiseW2_;
            const float n = noiseLpZ_ * 0.5f + wn2 * 0.15f;
            const float amt = globalNoise_ * 0.18f;  // scale so 1.0 = audible but not punishing
            mixL += n * amt;
            mixR += (n * 0.9f + wn2 * 0.05f) * amt;
        }
        // Output soft-clip with 1st-order ADAA (antiderivative antialiasing).
        // The antiderivative of tanh(x) is ln(cosh(x)). ADAA replaces the
        // direct nonlinearity with (F(x) - F(x_prev)) / (x - x_prev), which
        // dramatically reduces the harmonic aliasing introduced by tanh
        // — no oversampling required. Fall back to the midpoint nonlinearity
        // when consecutive samples are too close (avoids 0/0).
        // NOTE: the antiderivative bookkeeping MUST run in double. In float,
        // (F - pf)/dx suffers catastrophic cancellation on loud, slow,
        // low-frequency signals — i.e. the kick body — because consecutive
        // log(cosh) values are large and nearly equal. The quotient then
        // turns to broadband noise that rides the kick's decay tail (the
        // "hiss after every bassdrum hit"). Double precision drops that
        // cancellation error from ~-66 dB to inaudible. Fallback threshold
        // widened to 1e-4 so we switch to the stable midpoint form sooner.
        // The difference is taken over one 48 kHz-sized step (1 sample below
        // 80 kHz, 2 at 88.2/96 kHz, 4 above): ADAA is also a gentle top-end
        // roll-off tied to that step, and taken over a single sample at 96 kHz
        // the whole kit came out 3 dB brighter above 10 kHz than at 48 kHz.
        const double drive = 1.1;
        const int w = adaaW_;
        auto adaa = [drive, w](float x, double *hx, double *hf) -> float {
            const double s  = (double)x * drive * 0.5;
            const double F  = std::log(std::cosh(s));
            const double px = hx[w], pf = hf[w];        // what was written noiseDiv_ samples ago
            hx[w] = s; hf[w] = F;
            const double dx = s - px;
            double y;
            if (std::fabs(dx) > 1e-4) {
                y = (F - pf) / dx;
            } else {
                y = std::tanh(0.5 * (s + px));
            }
            return (float)(y / drive * 1.05);
        };
        outL = adaa(mixL, adaaXL_, adaaFL_);
        outR = adaa(mixR, adaaXR_, adaaFR_);
        if (++adaaW_ >= noiseDiv_) adaaW_ = 0;
    }

private:
    // Apply (per-voice + global) pitch in semitones to the voice as a multiplier.
    void applyVoicePitch(int v) {
        const float semi = pitchSemi_[v] + globalPitchSemi_;
        const float scale = std::pow(2.0f, semi / 12.0f);
        switch (v) {
            case 0: k_.setPitch(scale); break;
            case 1: s_.setPitch(scale); break;
            case 2: c_.setPitch(scale); break;
            case 3: r_.setPitch(scale); break;
            case 4: t1_.setPitch(scale); break;
            case 5: t2_.setPitch(scale); break;
            case 6: hm_.setPitch(scale); break;
            case 7: hc_.setPitch(scale); break;
            case 8: ho_.setPitch(scale); break;
            case 9: cr_.setPitch(scale); break;
            case 10: sb_.setPitch(scale); break;
            case 11: ls_.setPitch(scale); break;
        }
    }

    float sr_ = 48000;
    Kick k_; Snare s_; Clap c_; Rim r_;
    Tom t1_, t2_;
    Hat hm_, hc_, ho_;   // HAT M (mid decay) replaces TOM 3
    Crash cr_;
    Sub sb_;             // voice 10 — raw large sub-bass
    LongSub ls_;         // voice 11 — sustained long sub notes
    Reverb rev_;
    DelayTap dly_[kVoices];
    SVFLowpass filt_[kVoices];
    float filtN_[kVoices]    = {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1};
    float levels_[kVoices]   = {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1};
    float delayMix_[kVoices] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    float lastDlyMs_[kVoices]= {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    float reverbSend_[kVoices] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    // ADAA state: previous-sample input + previous antiderivative value per
    // channel. MUST be double — see the adaa lambda for why (kick-hiss fix).
    static constexpr int kAdaaMax = 4;
    double adaaXL_[kAdaaMax] = {0}, adaaFL_[kAdaaMax] = {0}, adaaXR_[kAdaaMax] = {0}, adaaFR_[kAdaaMax] = {0};
    int    adaaW_ = 0;
    bool  mute_[kVoices] = {};
    bool  solo_[kVoices] = {};
    bool  patterns_[kSlots][kVoices][kSteps] = {};
    uint8_t swingLevel_[kSlots][kVoices][kSteps] = {};        // per-cell swing 0..4
    int     pendingDelay_[kVoices] = {-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1};  // swing countdown (-1 idle)
    float   pendingVel_[kVoices]   = {};
    bool    recordArmed_ = false;                             // live-record arm
    float   stepVel_[kSlots][kVoices][kSteps] = {};           // recorded per-step velocity
    bool    stepVelSet_[kSlots][kVoices][kSteps] = {};        // true where recorded
    int   resolution_[kVoices] = {16,16,16,16,16,16,16,16,16,16,16,16};
    int   character_[kVoices]  = {};
    float pitchSemi_[kVoices]  = {};
    int   currentSlot_ = 0;
    int   bars_ = 2;

    // Pattern chain (song mode). chainLen_ == 0 means off.
    int   chain_[kMaxChain] = {};
    int   chainLen_ = 0;
    int   chainPos_ = 0;

    // Global FX
    float globalPitchSemi_ = 0.0f;
    float globalNoise_ = 0.0f;
    int   voiceVelPreset_[kVoices] = {};  // per-voice velocity preset
    int   voiceHitCount_[kVoices]  = {};  // hits since last loop reset
    // Per-slot snapshot of character + velocity-preset choices, so flipping
    // PATTERN A/B/C/D feels like switching genres — not just patterns. We
    // save the current per-voice state into the active slot, then load the
    // destination slot's saved state on slot switch.
    int   slotChar_[kSlots][kVoices]      = {{0}};
    int   slotVelPreset_[kSlots][kVoices] = {{0}};
    // Per-trigger gate decay multiplier — set when a voice fires based on the
    // velocity for that hit. Soft hits get a faster decay so they're short
    // AND quiet, matching how acoustic drums respond to lighter strikes.
    // 1.0 = no velocity-driven shortening (full hit).
    float voiceVelRate_[kVoices]   = {1,1,1,1,1,1,1,1,1,1,1,1};
    int   noiseDiv_ = 1, noiseTick_ = 0;
    float noiseLpK_ = 0.35f, noiseW2_ = 0.0f;
    // samples since this voice last fired — used by NUDGE preset to detect
    // rapid runs. Starts at "very large" so the first hit always reads as
    // isolated and plays full strength.
    int   samplesSinceLastHit_[kVoices] = {1<<30,1<<30,1<<30,1<<30,1<<30,1<<30,1<<30,1<<30,1<<30,1<<30,1<<30,1<<30};
    float globalDecay_ = 1.0f;   // master: 1.0 = no shortening, 0.0 = aggressive
    float decayVoice_[kVoices]    = {1,1,1,1,1,1,1,1,1,1,1,1};  // per-voice DECAY knob
    float voiceGateEnv_[kVoices]  = {1,1,1,1,1,1,1,1,1,1,1,1};  // refreshed on trigger
    float voiceGateRate_[kVoices] = {1,1,1,1,1,1,1,1,1,1,1,1};  // per-sample gate (global×voice)
    uint32_t noiseRng_ = 0xDEADBEEFu;
    float noiseLpZ_ = 0.0f;   // softens the white noise toward pink-ish hiss

    bool  playing_ = false;
    float bpm_ = 120.0f;
    float swing_ = 0.0f;
    int   currentStep_ = 0;
    float sampleAccum_ = 0;
    double lastHostBeat_ = 0.0;
    bool  needsHostResync_ = true;   // force a hard snap on the next host update
    int   samplesSinceHostBeat_ = 0; // elapsed frames since last setHostBeatPosition
    bool      prepared_    = false;      // prepare() ran once (patterns loaded)
    double    lastBlockBpm_ = 0.0;       // tempo the previous block ran at (jump detection)
    bool      hostLocked_  = false;      // true once Logic has fed a beat position
    double    hostBeatNow_ = 0.0;        // musical time of the current frame (beats)
    long long lastAbsTick_ = LLONG_MIN;  // last 64th tick fired under host lock
    // ── 2026-11 features ──
    bool  isolate_  = false;   // ISOLATE: loop the active slot, ignore (keep) the chain
    bool  midiMode_ = false;   // MIDI MODE: sequencer silent, MIDI notes just play voices
    bool  forceBoundary_ = false;  // offline start: next frame crosses into step 0
public:
    // Offline capture (MIDI export): when set, every sequencer trigger is logged.
    std::vector<TrigEvent>* capture_ = nullptr;
    long long captureFrame_ = 0;
};

}
