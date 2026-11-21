// VoiceBox sound-quality harness (2026-11-21) — AU-equivalent host, realistic
// test signals and objective metrics. Compiled twice by run_sq.sh:
//   before → Tests/sq/before_dsp   (DSP frozen on 2026-11-21, before this pass)
//   after  → VoiceBoxExtension/DSP (live)
// The parameter table and the 10 presets are extracted from VoiceBoxAudioUnit.mm
// at build time (au_tables.inc), so the harness always tests the shipped values.
#pragma once
#include <Accelerate/Accelerate.h>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <vector>
#include <string>
#include <algorithm>
#include <numeric>
#include <functional>
#include <memory>
#include <atomic>
#define private public            // test only: read tracker / pitch-mark internals
#include "VoiceBoxEngine.hpp"
#undef private
#include "../bench_common.hpp"
#include "au_tables.inc"

namespace sq {
using bench::PI;
typedef std::vector<float> Buf;

inline double dB(double x) { return 20.0 * std::log10(std::max(x, 1e-12)); }

// ── AU-equivalent host ──────────────────────────────────────────────────
// Mirrors VoiceBoxAudioUnit.mm internalRenderBlock: parameters are read once
// per render block, then processFrame() per sample; mono busses duplicate the
// input and average the output.
struct Event { size_t pos; int addr; float val; };
struct AUHost {
    std::unique_ptr<vbx::VoiceBoxEngine> e;
    float p[kNumParams]; int sr;
    explicit AUHost(int sampleRate) : e(new vbx::VoiceBoxEngine()), sr(sampleRate) {
        e->prepare(48000.0f);                 // as initWithComponentDescription does
        e->prepare((float)sr);                // allocateRenderResources
        for (int i = 0; i < kNumParams; ++i) p[i] = kSpecs[i].df;
    }
    void allOff() { for (int a : {0, 3, 6, 9, 12, 15, 18, 23}) p[a] = 0; }
    void preset(int i) { for (int k = 0; k < kNumParams; ++k) { if (k == 26) continue; p[k] = kPresets[i][k]; } }
    void allOn() { for (int a : {0, 3, 6, 9, 12, 15, 18, 23}) p[a] = 1; }
    int latency() const { return e->latencySamples(); }
    void apply() {
        e->setAutotune (p[0]  > 0.5f, p[1],  p[2], p[22], p[26], p[27]);
        e->setHarmonizer(p[3] > 0.5f, p[4],  p[5], p[21] > 0.5f);
        e->setSkip     (p[6]  > 0.5f, p[7],  p[8]);
        e->setDelay    (p[9]  > 0.5f, p[10], p[11]);
        e->setChop     (p[12] > 0.5f, p[13], p[14]);
        e->setVocoder  (p[15] > 0.5f, p[16], p[17]);
        e->setReverb   (p[18] > 0.5f, p[19], p[20]);
        e->setLow      (p[23] > 0.5f, p[24], p[25]);
    }
    // events must be sorted by pos; they take effect at the next block start (as in a host).
    void render(const Buf& inL, const Buf& inR, Buf& L, Buf& R, int block = 512, bool mono = false,
                const std::vector<Event>* ev = nullptr) {
        const size_t N = inL.size(); L.assign(N, 0); R.assign(N, 0); size_t ei = 0;
        for (size_t st = 0; st < N; st += (size_t)block) {
            const size_t n = std::min<size_t>(block, N - st);
            if (ev) while (ei < ev->size() && (*ev)[ei].pos <= st) { p[(*ev)[ei].addr] = (*ev)[ei].val; ++ei; }
            apply();
            if (mono) for (size_t i = 0; i < n; ++i) { float l = inL[st + i], r = l; e->processFrame(l, r); L[st + i] = R[st + i] = 0.5f * (l + r); }
            else for (size_t i = 0; i < n; ++i) { float l = inL[st + i], r = inR[st + i]; e->processFrame(l, r); L[st + i] = l; R[st + i] = r; }
        }
    }
};

// ── Signals ─────────────────────────────────────────────────────────────
struct Rng { uint32_t s; explicit Rng(uint32_t seed = 1) : s(seed) {} double uni() { s = s * 1664525u + 1013904223u; return ((s >> 8) & 0xffffff) / 8388608.0 - 1.0; } };

inline Buf sine(double hz, double sec, int sr, double amp) {
    Buf y((size_t)(sec * sr)); for (size_t n = 0; n < y.size(); ++n) y[n] = (float)(amp * std::sin(2 * PI * hz * n / sr)); return y;
}
inline Buf whiteNoise(double sec, int sr, double amp, uint32_t seed = 5) {
    Rng r(seed); Buf y((size_t)(sec * sr)); for (auto& v : y) v = (float)(amp * r.uni()); return y;
}

// Glottal-pulse voice: Rosenberg flow pulses (jitter, shimmer, aspiration noise)
// → 4 formant resonators that morph between vowels → lip radiation (difference).
// f0[n] in Hz (0 = unvoiced/silence). vowelPos[n] in 0…4 (a,e,i,o,u interpolated).
struct VoiceOpts { double jitter = 0.006, shimmer = 0.04, breath = 0.03; bool invert = false; uint32_t seed = 3; };
inline Buf glottalVoice(const std::vector<double>& f0, const std::vector<double>& vowelPos, int sr, const VoiceOpts& o = VoiceOpts()) {
    static const double VF[5][4] = { {730, 1090, 2440, 3500}, {530, 1840, 2480, 3500}, {270, 2290, 3010, 3600}, {570, 840, 2410, 3400}, {300, 870, 2240, 3400} };
    static const double BW[4] = {80, 90, 120, 180};
    const size_t N = f0.size(); Buf y(N, 0.0f); Rng rng(o.seed);
    double ph = 1.0, perJ = 1.0, amp = 1.0; double y1[4] = {0}, y2[4] = {0}; double prev = 0, aspLP = 0;
    for (size_t n = 0; n < N; ++n) {
        double src = 0.0;
        if (f0[n] > 0) {
            ph += f0[n] * perJ / sr;
            if (ph >= 1.0) { ph -= 1.0; perJ = 1.0 + o.jitter * rng.uni(); amp = 1.0 + o.shimmer * rng.uni(); }
            const double Tp = 0.40, Tn = 0.16; double g = 0.0;
            if (ph < Tp) g = 0.5 * (1.0 - std::cos(PI * ph / Tp));
            else if (ph < Tp + Tn) g = std::cos(PI * (ph - Tp) / (2.0 * Tn));
            const double w = rng.uni(); aspLP += 0.5 * (w - aspLP);
            src = amp * g + o.breath * (w - aspLP) * (0.3 + g);
        } else { ph = 1.0; }
        const double vp = std::max(0.0, std::min(3.999, vowelPos.empty() ? 0.0 : vowelPos[n])); const int vi = (int)vp; const double vf = vp - vi;
        double x = src;
        for (int k = 0; k < 4; ++k) {
            const double F = VF[vi][k] + vf * (VF[vi + 1][k] - VF[vi][k]);
            const double C = -std::exp(-2 * PI * BW[k] / sr), B = 2 * std::exp(-PI * BW[k] / sr) * std::cos(2 * PI * F / sr), A = 1 - B - C;
            const double out = A * x + B * y1[k] + C * y2[k]; y2[k] = y1[k]; y1[k] = out; x = out;
        }
        const double d = x - prev; prev = x;           // lip radiation
        y[n] = (float)((o.invert ? -1.0 : 1.0) * d);
    }
    return y;
}
// Band-passed noise burst: "s" (5–9 kHz), "sh" (2.5–5 kHz), breath (broad, soft).
inline Buf fricative(size_t N, int sr, double fLo, double fHi, uint32_t seed) {
    Rng r(seed); Buf y(N); double lp1 = 0, lp2 = 0;
    const double aHi = 1 - std::exp(-2 * PI * fHi / sr), aLo = 1 - std::exp(-2 * PI * fLo / sr);
    for (size_t n = 0; n < N; ++n) { const double w = r.uni(); lp1 += aHi * (w - lp1); lp2 += aLo * (lp1 - lp2); y[n] = (float)((lp1 - lp2) * std::sin(PI * (double)n / (double)N)); }
    return y;
}
inline void normalizePeak(Buf& y, double peak) { float m = 0; for (float v : y) m = std::max(m, std::fabs(v)); if (m > 0) for (auto& v : y) v = (float)(v * peak / m); }
inline Buf scaled(const Buf& x, double g) { Buf y(x); for (auto& v : y) v = (float)(v * g); return y; }

// The test phrase: off-pitch notes with vibrato, glides (100–400 Hz range via
// `baseMidi`), vowel changes, an "s", a "sh", a "t" plosive, a breath and a
// hard silence→voice onset. truth[n] = sung pitch in MIDI (0 = unvoiced).
struct Phrase { Buf x; std::vector<double> truthMidi; std::vector<std::pair<size_t, size_t>> sibilants; };
inline Phrase makePhrase(int sr, double baseMidi = 50.0, bool invert = false, uint32_t seed = 3) {
    struct Note { double semis, cents, dur, vib; bool glide; double vowel; int after; };   // after: 0 none 1 "s" 2 "sh" 3 breath 4 "t" 5 silence
    const Note notes[] = {
        {0, +35, 0.50, 15, false, 0.0, 0}, {2, -38, 0.40, 10, true, 1.0, 1}, {3, +22, 0.70, 30, false, 2.0, 0},
        {7, -45, 0.45, 20, true, 0.5, 2}, {5, +40, 0.55, 25, false, 3.0, 3}, {0, -20, 0.80, 35, true, 4.0, 4},
        {12, +15, 0.60, 30, true, 0.0, 5}, {19, -30, 0.50, 20, false, 2.0, 0}, {24, +25, 0.70, 40, true, 1.0, 1},
        {17, -10, 0.35, 0, true, 3.0, 0}, {12, +45, 0.90, 35, true, 0.0, 0},
    };
    std::vector<double> f0, vow; struct Gap { size_t at, len; int kind; }; std::vector<Gap> gaps;
    auto silence = [&](double sec) { for (int i = 0; i < (int)(sec * sr); ++i) { f0.push_back(0); vow.push_back(vow.empty() ? 0 : vow.back()); } };
    silence(0.20); double prev = baseMidi, prevV = 0;
    for (const Note& nt : notes) {
        const int N = (int)(nt.dur * sr); const double target = baseMidi + nt.semis + nt.cents / 100.0;
        for (int i = 0; i < N; ++i) {
            const double t = (double)i / sr; double m = target;
            const double gt = nt.glide ? 0.10 : 0.04; if (t < gt) m = prev + (target - prev) * (t / gt);
            m += (nt.vib / 100.0) * std::sin(2 * PI * 5.5 * t) * std::min(1.0, t / 0.25);
            f0.push_back(bench::midiToHz(m)); vow.push_back(prevV + (nt.vowel - prevV) * std::min(1.0, t / 0.08));
        }
        prev = target; prevV = nt.vowel;
        const double gl[6] = {0, 0.20, 0.22, 0.22, 0.09, 0.30};
        if (nt.after) { gaps.push_back({f0.size(), (size_t)(gl[nt.after] * sr), nt.after}); silence(gl[nt.after]); }
    }
    silence(0.30);
    VoiceOpts o; o.invert = invert; o.seed = seed;
    Phrase P; P.x = glottalVoice(f0, vow, sr, o);
    // soft attack/release per voiced run (except after the "silence" gap: hard onset)
    for (size_t n = 0, start = 0; n <= P.x.size(); ++n) {
        const bool v = n < P.x.size() && f0[n] > 0;
        if (!v) { if (n > start) { const size_t len = n - start, a = std::min<size_t>(len / 4, (size_t)(0.025 * sr));
                for (size_t i = 0; i < len; ++i) { double g = 1; if (i < a) g = (double)i / a; if (len - i < a) g = (double)(len - i) / a; P.x[start + i] *= (float)g; } }
            start = n + 1; }
    }
    normalizePeak(P.x, 1.0);
    for (const Gap& g : gaps) {
        if (g.kind == 5) continue;
        const double lo[5] = {0, 5000, 2500, 300, 3000}, hi[5] = {0, 9500, 5500, 4000, 10000}, lv[5] = {0, 0.45, 0.40, 0.08, 0.5};
        const size_t pad = (size_t)(0.01 * sr), len = g.len > 2 * pad ? g.len - 2 * pad : g.len;
        Buf fr = fricative(len, sr, lo[g.kind], hi[g.kind], 11 + (uint32_t)g.kind); float m = 0; for (float v : fr) m = std::max(m, std::fabs(v));
        for (size_t i = 0; i < len && g.at + pad + i < P.x.size(); ++i) P.x[g.at + pad + i] += (float)(fr[i] / std::max(m, 1e-9f) * lv[g.kind]);
        if (g.kind == 1 || g.kind == 2) P.sibilants.push_back({g.at + pad, g.at + pad + len});
    }
    normalizePeak(P.x, 1.0);
    P.truthMidi.resize(f0.size()); for (size_t n = 0; n < f0.size(); ++n) P.truthMidi[n] = f0[n] > 0 ? 69 + 12 * std::log2(f0[n] / 440.0) : 0;
    return P;
}

// ── Metrics ─────────────────────────────────────────────────────────────
struct Stats { double peak = 0, truePeak = 0, rms = 0, dc = 0; long clipped = 0, over = 0, nan = 0, denorm = 0; };
inline double truePeak4x(const Buf& y) {
    // 4× oversampled peak: 3 fractional phases of a 32-tap Hann-windowed sinc.
    const int T = 16; static float h[3][2 * T]; static bool init = false;
    if (!init) { for (int ph = 0; ph < 3; ++ph) for (int k = 0; k < 2 * T; ++k) { const double t = (k - T + 1) - (ph + 1) / 4.0; const double w = 0.5 + 0.5 * std::cos(PI * t / T); h[ph][k] = (float)((std::fabs(t) < 1e-9 ? 1.0 : std::sin(PI * t) / (PI * t)) * (std::fabs(t) < T ? w : 0.0)); } init = true; }
    double m = 0; for (float v : y) m = std::max<double>(m, std::fabs(v));
    for (size_t n = T; n + T < y.size(); ++n) {
        if (std::fabs(y[n]) < 0.5 * m && std::fabs(y[n + 1]) < 0.5 * m) continue;
        for (int ph = 0; ph < 3; ++ph) { float s = 0; vDSP_dotpr(&y[n - T + 1], 1, h[ph], 1, &s, 2 * T); m = std::max<double>(m, std::fabs(s)); }
    }
    return m;
}
inline Stats stats(const Buf& y, size_t a = 0, size_t b = (size_t)-1) {
    Stats s; b = std::min(b, y.size()); double sum = 0, sq = 0; size_t n = 0;
    for (size_t i = a; i < b; ++i, ++n) {
        const float v = y[i];
        if (!std::isfinite(v)) { ++s.nan; continue; }
        const double av = std::fabs(v); if (av > s.peak) s.peak = av;
        if (av >= 0.9999) ++s.clipped; if (av > 1.0) ++s.over;
        if (av != 0.0 && av < 1.17549435e-38) ++s.denorm;
        sum += v; sq += (double)v * v;
    }
    if (n) { s.dc = sum / n; s.rms = std::sqrt(sq / n); }
    s.truePeak = truePeak4x(y);
    return s;
}
inline double rmsOf(const Buf& y, size_t a, size_t b) { b = std::min(b, y.size()); double s = 0; for (size_t i = a; i < b; ++i) s += (double)y[i] * y[i]; return b > a ? std::sqrt(s / (b - a)) : 0; }

// THD+N of a steady sine: least-squares fit the fundamental, residual / total (dB).
inline double thdn(const Buf& y, double hz, int sr, size_t a, size_t b, double* fundDb = nullptr) {
    b = std::min(b, y.size()); double c = 0, s = 0, cc = 0, ss = 0, cs = 0;
    for (size_t n = a; n < b; ++n) { const double ph = 2 * PI * hz * n / sr, co = std::cos(ph), si = std::sin(ph); c += y[n] * co; s += y[n] * si; cc += co * co; ss += si * si; cs += co * si; }
    const double det = cc * ss - cs * cs; const double A = (c * ss - s * cs) / det, B = (s * cc - c * cs) / det;
    double E = 0, R = 0; for (size_t n = a; n < b; ++n) { const double ph = 2 * PI * hz * n / sr; const double r = y[n] - A * std::cos(ph) - B * std::sin(ph); E += (double)y[n] * y[n]; R += r * r; }
    if (fundDb) *fundDb = dB(std::sqrt(A * A + B * B));
    return 10 * std::log10(std::max(R, 1e-30) / std::max(E, 1e-30));
}


// Refine a fundamental estimate: maximise the energy captured by the first 8 harmonics
// (the HNR projection is very sensitive to f0 errors: 0.1 cent already costs dBs).
inline double harmEnergy(const float* y, int N, double f, int H, double sr) {
    double e = 0; for (int h = 1; h <= H; ++h) { const double w = 2 * PI * f * h / sr; if (f * h > sr / 2 - 200) break; double c = 0, s = 0; const double cw = std::cos(w), sw = std::sin(w); double pc = 1, ps = 0;
        for (int n = 0; n < N; ++n) { c += y[n] * pc; s += y[n] * ps; const double t = pc * cw - ps * sw; ps = pc * sw + ps * cw; pc = t; } e += c * c + s * s; }
    return e;
}
inline double refineF0(const float* y, int N, double f0, double sr, double spanCents = 3.0) {
    double lo = f0 * std::pow(2.0, -spanCents / 1200.0), hi = f0 * std::pow(2.0, spanCents / 1200.0);
    // coarse grid first (the objective has side lobes), then ternary search
    double best = f0, be = -1; for (int i = 0; i <= 60; ++i) { const double f = lo + (hi - lo) * i / 60.0; const double e = harmEnergy(y, N, f, 8, sr); if (e > be) { be = e; best = f; } }
    double a = best - (hi - lo) / 60.0, b = best + (hi - lo) / 60.0;
    for (int it = 0; it < 30; ++it) { const double m1 = a + (b - a) / 3, m2 = b - (b - a) / 3; if (harmEnergy(y, N, m1, 8, sr) < harmEnergy(y, N, m2, 8, sr)) a = m1; else b = m2; }
    return 0.5 * (a + b);
}

// Click detector on the 2nd difference: an event is |d2| > k × the local RMS of
// d2 (±512 samples, the ±6 around n excluded) and above an absolute floor.
inline int clickCount(const Buf& y, size_t a, size_t b, double k = 8.0, double floorAbs = 2e-3, double* worst = nullptr) {
    b = std::min(b, y.size()); if (b < a + 2048) return 0;
    std::vector<double> d2(b - a, 0.0); for (size_t n = a + 2; n < b; ++n) d2[n - a] = (double)y[n] - 2.0 * y[n - 1] + y[n - 2];
    std::vector<double> cs(d2.size() + 1, 0.0); for (size_t i = 0; i < d2.size(); ++i) cs[i + 1] = cs[i] + d2[i] * d2[i];
    int count = 0; size_t last = 0; double w = 0; const size_t W = 512;
    for (size_t i = W; i + W < d2.size(); ++i) {
        const double v = std::fabs(d2[i]); if (v < floorAbs) continue;
        const double ex = cs[i + 7] - cs[i - 6]; const double loc = std::sqrt(std::max(0.0, (cs[i + W] - cs[i - W] - ex)) / (2.0 * W - 13));
        const double ratio = v / std::max(loc, 1e-9);
        if (ratio > k) { if (i > last + 64 || count == 0) ++count; last = i; if (ratio > w) w = ratio; }
    }
    if (worst) *worst = w; return count;
}
inline double maxD2(const Buf& y, size_t a, size_t b) { b = std::min(b, y.size()); double m = 0; for (size_t n = std::max<size_t>(a, 2); n < b; ++n) m = std::max(m, std::fabs((double)y[n] - 2.0 * y[n - 1] + y[n - 2])); return m; }

// Frame-wise periodicity (McLeod clarity) + f0 of a signal, independent instance.
struct PitchFrames { std::vector<float> hz, clar, rms; int hop = 0, W = 0; };
inline PitchFrames pitchFrames(const Buf& y, int sr, int hop = 256) {
    PitchFrames F; F.hop = hop; F.W = (int)std::lround(0.070 * sr);
    vbx::mpm::Detector det; det.prepare(F.W);
    for (size_t st = 0; st + (size_t)F.W <= y.size(); st += (size_t)hop) {
        float c = 0; const float hz = det.detect(&y[st], (float)sr, 35.0f, 1100.0f, c);
        float ms = 0; vDSP_measqv(&y[st], 1, &ms, (vDSP_Length)F.W);
        F.hz.push_back(hz); F.clar.push_back(c); F.rms.push_back(std::sqrt(ms));
    }
    return F;
}
// Normalised autocorrelation of the window at one lag (linear interpolation of the lag).
inline double nsdfAt(const float* x, int W, double lag) {
    const int l0 = (int)lag; const double fr = lag - l0; double r = 0, m = 0;
    for (int i = 0; i + l0 + 1 < W; ++i) { const double b = x[i + l0] + fr * (x[i + l0 + 1] - x[i + l0]); r += x[i] * b; m += (double)x[i] * x[i] + b * b; }
    return m > 1e-12 ? 2 * r / m : 0;
}

// 10 ms RMS envelope (dB) → deviation of the output envelope from the input's.
inline void envelopeDeviation(const Buf& in, const Buf& out, int lat, int sr, double& medianGainDb, double& p95DevDb, double& maxDevDb, double floorDb = -50.0) {
    const size_t W = (size_t)(0.010 * sr); std::vector<double> d;
    for (size_t st = 0; st + W + lat <= out.size() && st + W <= in.size(); st += W) {
        const double ri = dB(rmsOf(in, st, st + W)), ro = dB(rmsOf(out, st + lat, st + lat + W));
        if (ri > floorDb) d.push_back(ro - ri);
    }
    if (d.empty()) { medianGainDb = p95DevDb = maxDevDb = 0; return; }
    std::vector<double> s(d); std::sort(s.begin(), s.end()); medianGainDb = s[s.size() / 2];
    std::vector<double> dev; for (double v : d) dev.push_back(std::fabs(v - medianGainDb)); std::sort(dev.begin(), dev.end());
    p95DevDb = dev[(size_t)(0.95 * (dev.size() - 1))]; maxDevDb = dev.back();
}

inline bool loadWav(const std::string& path, Buf& L, Buf& R, int& sr) { return bench::readWav(path, L, R, sr); }
// Linear-interpolation resampler (test material only; band-limited enough for voice at ≥44.1k).
inline Buf resampleTo(const Buf& x, int from, int to) {
    if (from == to) return x; const double r = (double)from / to; Buf y((size_t)(x.size() / r));
    for (size_t n = 0; n < y.size(); ++n) { const double p = n * r; const size_t i = (size_t)p; const double f = p - i; y[n] = (float)(i + 1 < x.size() ? x[i] * (1 - f) + x[i + 1] * f : 0.0); }
    return y;
}
inline void writeWavF(const std::string& path, const Buf& L, const Buf& R, int sr) { bench::writeWav(path, L, R, sr); }

} // namespace sq
