// VoiceBox test bench — shared signal generators, metrics and WAV I/O.
// Used by bench.cpp, which is compiled twice: against Tests/baseline (OLD DSP,
// frozen 2026-11-20) and against VoiceBoxExtension/DSP (NEW DSP).
#pragma once
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>
#include <string>
#include <algorithm>
#include <numeric>

namespace bench {

static const double PI = 3.14159265358979323846;

// ── WAV ───────────────────────────────────────────────────────────────
inline void writeWav(const std::string& path, const std::vector<float>& L, const std::vector<float>& R, int sr) {
    FILE* f = std::fopen(path.c_str(), "wb"); if (!f) { std::printf("cannot write %s\n", path.c_str()); return; }
    const uint32_t n = (uint32_t)L.size(); const uint16_t ch = 2, bits = 24;
    auto w32 = [&](uint32_t v) { std::fwrite(&v, 4, 1, f); }; auto w16 = [&](uint16_t v) { std::fwrite(&v, 2, 1, f); };
    std::fwrite("RIFF", 1, 4, f); w32(36 + n * ch * 3); std::fwrite("WAVEfmt ", 1, 8, f);
    w32(16); w16(1); w16(ch); w32(sr); w32(sr * ch * 3); w16(ch * 3); w16(bits);
    std::fwrite("data", 1, 4, f); w32(n * ch * 3);
    for (uint32_t i = 0; i < n; ++i) for (int c = 0; c < 2; ++c) {
        const float v = std::max(-1.0f, std::min(1.0f, c ? R[i] : L[i]));
        const int32_t s = (int32_t)std::lround(v * 8388607.0);
        const uint8_t b[3] = { (uint8_t)(s & 0xff), (uint8_t)((s >> 8) & 0xff), (uint8_t)((s >> 16) & 0xff) };
        std::fwrite(b, 1, 3, f);
    }
    std::fclose(f);
}

// Minimal WAV reader (PCM 16/24/32-int or 32-float), returns stereo (mono duplicated).
inline bool readWav(const std::string& path, std::vector<float>& L, std::vector<float>& R, int& sr) {
    FILE* f = std::fopen(path.c_str(), "rb"); if (!f) return false;
    char id[4]; uint32_t sz; uint16_t fmt = 1, ch = 2, bits = 16; bool gotFmt = false;
    std::fread(id, 1, 4, f); std::fread(&sz, 4, 1, f); std::fread(id, 1, 4, f);
    while (std::fread(id, 1, 4, f) == 4 && std::fread(&sz, 4, 1, f) == 1) {
        if (!std::memcmp(id, "fmt ", 4)) {
            std::vector<uint8_t> b(sz); std::fread(b.data(), 1, sz, f);
            fmt = b[0] | (b[1] << 8); ch = b[2] | (b[3] << 8); sr = b[4] | (b[5] << 8) | (b[6] << 16) | (b[7] << 24);
            bits = b[14] | (b[15] << 8); if (fmt == 0xFFFE) fmt = (bits == 32 && b.size() >= 26 && b[24] == 3) ? 3 : 1; gotFmt = true;
        } else if (!std::memcmp(id, "data", 4) && gotFmt) {
            const int bps = bits / 8; const size_t frames = sz / (bps * ch);
            std::vector<uint8_t> d(sz); std::fread(d.data(), 1, sz, f);
            L.resize(frames); R.resize(frames);
            for (size_t i = 0; i < frames; ++i) for (int c = 0; c < std::min<int>(ch, 2); ++c) {
                const uint8_t* p = &d[(i * ch + c) * bps]; float v = 0;
                if (fmt == 3 && bits == 32) { std::memcpy(&v, p, 4); }
                else if (bits == 16) v = (int16_t)(p[0] | (p[1] << 8)) / 32768.0f;
                else if (bits == 24) { int32_t s = p[0] | (p[1] << 8) | (p[2] << 16); if (s & 0x800000) s |= ~0xffffff; v = s / 8388608.0f; }
                else if (bits == 32) { int32_t s; std::memcpy(&s, p, 4); v = s / 2147483648.0f; }
                (c ? R : L)[i] = v;
            }
            if (ch == 1) R = L;
            std::fclose(f); return true;
        } else std::fseek(f, sz + (sz & 1), SEEK_CUR);
    }
    std::fclose(f); return false;
}

// ── Signal generators ──────────────────────────────────────────────────
// Formant gain of a 3-formant vowel ("ah": 700 / 1220 / 2600 Hz).
inline double formantGain(double f) {
    const double F[3] = {700, 1220, 2600}, B[3] = {110, 120, 160}, A[3] = {1.0, 0.5, 0.25};
    double g = 0.02;
    for (int i = 0; i < 3; ++i) { const double d = (f - F[i]) / (B[i] * 0.5); g += A[i] / (1.0 + d * d); }
    return g;
}

// Additive "sung vowel": −12 dB/oct source × formant envelope, f0(t) given in Hz per sample.
inline std::vector<float> vowel(const std::vector<double>& f0, int sr, double level = 0.25) {
    const int H = 60; std::vector<double> ph(H + 1, 0.0); std::vector<float> y(f0.size());
    for (size_t n = 0; n < f0.size(); ++n) {
        double s = 0; const double f = f0[n];
        if (f > 0) for (int h = 1; h <= H; ++h) {
            const double fh = f * h; if (fh > 9000) break;
            ph[h] += 2 * PI * fh / sr; if (ph[h] > 2 * PI) ph[h] -= 2 * PI;
            s += std::sin(ph[h]) / (double)(h * h) * formantGain(fh) * 4.0;
        }
        y[n] = (float)(s * level);
    }
    return y;
}

// Harmonic tone (20 harmonics, 1/h) — the plan's phase-drift test signal.
inline std::vector<float> harmonicTone(double f0, double seconds, int sr) {
    const size_t N = (size_t)(seconds * sr); std::vector<float> y(N);
    for (size_t n = 0; n < N; ++n) { double t = (double)n / sr, s = 0; for (int h = 1; h <= 20; ++h) s += std::sin(2 * PI * f0 * h * t) / h; y[n] = (float)(0.3 * s); }
    return y;
}

// Band-passed white noise ("sss" / breath).
inline std::vector<float> hiss(size_t N, double level, uint32_t seed = 1) {
    std::vector<float> y(N); double z1 = 0, z2 = 0;
    for (size_t n = 0; n < N; ++n) {
        seed = seed * 1664525u + 1013904223u; const double w = ((seed >> 8) & 0xffffff) / 8388608.0 - 1.0;
        const double hp = w - z1; z1 = w; z2 += 0.35 * (hp - z2);          // crude high-pass + soft low-pass
        y[n] = (float)(z2 * level);
    }
    return y;
}

inline double midiToHz(double m) { return 440.0 * std::pow(2.0, (m - 69.0) / 12.0); }

// A sung phrase: notes deliberately off-pitch, glides, vibrato, an "s" and a breath.
// Returns mono; fills `truthMidi` with the intended (sung) pitch per sample (0 = unvoiced).
inline std::vector<float> phrase(int sr, std::vector<double>* truthMidi = nullptr) {
    struct Note { double midi, cents, dur, vibDepth; bool glideIn; };
    const Note notes[] = {
        {57, +35, 0.55, 15, false}, {59, -38, 0.45, 10, true}, {60, +22, 0.70, 30, false},
        {64, -45, 0.50, 20, true}, {62, +40, 0.60, 25, false}, {57, -20, 0.90, 35, true},
    };
    std::vector<double> f0; std::vector<int> unv;
    auto pushSilence = [&](double sec) { for (int i = 0; i < (int)(sec * sr); ++i) f0.push_back(0); };
    double prev = 57;
    pushSilence(0.15);
    for (size_t k = 0; k < sizeof(notes) / sizeof(notes[0]); ++k) {
        const Note& nt = notes[k]; const int N = (int)(nt.dur * sr);
        const double target = nt.midi + nt.cents / 100.0;
        for (int i = 0; i < N; ++i) {
            const double t = (double)i / sr;
            double m = target;
            if (nt.glideIn && t < 0.12) m = prev + (target - prev) * (t / 0.12);
            m += (nt.vibDepth / 100.0) * std::sin(2 * PI * 5.5 * t) * std::min(1.0, t / 0.25);
            f0.push_back(midiToHz(m));
        }
        prev = target;
        if (k == 2) pushSilence(0.28);       // gap for the "s" below
        if (k == 4) pushSilence(0.22);       // gap for a breath
    }
    pushSilence(0.25);
    std::vector<float> y = vowel(f0, sr, 0.22);
    // Amplitude envelope per voiced run (soft attack/release).
    for (size_t n = 0, start = 0; n <= y.size(); ++n) {
        const bool v = n < y.size() && f0[n] > 0;
        if (n == y.size() || !v) {
            if (n > start) {
                const size_t len = n - start, a = std::min<size_t>(len / 4, (size_t)(0.03 * sr));
                for (size_t i = 0; i < len; ++i) { double g = 1; if (i < a) g = (double)i / a; if (len - i < a) g = (double)(len - i) / a; y[start + i] *= (float)g; }
            }
            start = n + 1;
        }
    }
    // "s" in the first gap, breath in the second.
    size_t gapS = 0, gapB = 0; int gaps = 0;
    for (size_t n = 1; n < f0.size(); ++n) if (f0[n - 1] > 0 && f0[n] == 0) { ++gaps; if (gaps == 3) gapS = n; if (gaps == 5) gapB = n; }
    auto addNoise = [&](size_t at, double sec, double lvl, uint32_t seed) {
        std::vector<float> h = hiss((size_t)(sec * sr), lvl, seed);
        for (size_t i = 0; i < h.size() && at + i < y.size(); ++i) { const double e = std::sin(PI * i / h.size()); y[at + i] += (float)(h[i] * e); }
    };
    if (gapS) addNoise(gapS + (size_t)(0.03 * sr), 0.22, 0.10, 7);
    if (gapB) addNoise(gapB + (size_t)(0.02 * sr), 0.18, 0.03, 11);
    if (truthMidi) { truthMidi->resize(f0.size()); for (size_t n = 0; n < f0.size(); ++n) (*truthMidi)[n] = f0[n] > 0 ? 69 + 12 * std::log2(f0[n] / 440.0) : 0; }
    return y;
}

// ── Metrics ────────────────────────────────────────────────────────────
// HNR: project a window onto the expected harmonics of fout, residual = noise (dB).
inline double hnr(const float* y, int N, double fout, int H, double sr) {
    std::vector<double> r(y, y + N);
    for (int h = 1; h <= H; ++h) {
        const double f = fout * h; if (f > sr / 2 - 100) break;
        double c = 0, s = 0;
        for (int n = 0; n < N; ++n) { const double a = 2 * PI * f * n / sr; c += r[n] * std::cos(a); s += r[n] * std::sin(a); }
        c *= 2.0 / N; s *= 2.0 / N;
        for (int n = 0; n < N; ++n) { const double a = 2 * PI * f * n / sr; r[n] -= c * std::cos(a) + s * std::sin(a); }
    }
    double E = 0, R = 0; for (int n = 0; n < N; ++n) { E += (double)y[n] * y[n]; R += r[n] * r[n]; }
    return 10 * std::log10(std::max(E - R, 1e-30) / (R + 1e-30));
}

// Offline YIN in double precision → Hz per frame (0 = unvoiced). Independent of the plug-in's tracker.
inline std::vector<double> yinTrack(const std::vector<float>& x, int sr, int hop, double fmin = 70, double fmax = 1000) {
    const int W = (int)(0.040 * sr), maxLag = (int)(sr / fmin), minLag = (int)(sr / fmax);
    std::vector<double> out; std::vector<double> d(maxLag + 2), c(maxLag + 2);
    for (size_t st = 0; st + W + maxLag < x.size(); st += hop) {
        double e = 0; for (int i = 0; i < W; ++i) e += x[st + i] * x[st + i];
        if (e / W < 1e-6) { out.push_back(0); continue; }
        for (int tau = 1; tau <= maxLag; ++tau) { double s = 0; for (int i = 0; i < W; ++i) { const double df = x[st + i] - x[st + i + tau]; s += df * df; } d[tau] = s; }
        double run = 0; c[0] = 1; for (int tau = 1; tau <= maxLag; ++tau) { run += d[tau]; c[tau] = run > 0 ? d[tau] * tau / run : 1; }
        int best = -1; for (int tau = minLag; tau < maxLag; ++tau) if (c[tau] < 0.12) { while (tau + 1 < maxLag && c[tau + 1] < c[tau]) ++tau; best = tau; break; }
        if (best < 0) { out.push_back(0); continue; }
        double tf = best; const double a = c[best - 1], b = c[best], cc = c[best + 1], den = a + cc - 2 * b;
        if (std::fabs(den) > 1e-12) tf += std::max(-1.0, std::min(1.0, 0.5 * (a - cc) / den));
        out.push_back(sr / tf);
    }
    return out;
}

// Smoothed log-magnitude spectral envelope (cepstral lifter ~1.2 ms), averaged over [a,b).
inline std::vector<double> envelope(const std::vector<float>& x, int sr, size_t a, size_t b, int N = 4096) {
    std::vector<double> acc(N / 2 + 1, 0.0); int frames = 0;
    std::vector<double> re(N), im(N);
    auto fft = [&](std::vector<double>& R, std::vector<double>& I, bool inv) {
        for (int i = 1, j = 0; i < N; ++i) { int bit = N >> 1; for (; j & bit; bit >>= 1) j ^= bit; j ^= bit; if (i < j) { std::swap(R[i], R[j]); std::swap(I[i], I[j]); } }
        for (int len = 2; len <= N; len <<= 1) { const double ang = 2 * PI / len * (inv ? 1 : -1);
            for (int i = 0; i < N; i += len) for (int k = 0; k < len / 2; ++k) {
                const double wr = std::cos(ang * k), wi = std::sin(ang * k);
                const double ur = R[i + k], ui = I[i + k], vr = R[i + k + len / 2] * wr - I[i + k + len / 2] * wi, vi = R[i + k + len / 2] * wi + I[i + k + len / 2] * wr;
                R[i + k] = ur + vr; I[i + k] = ui + vi; R[i + k + len / 2] = ur - vr; I[i + k + len / 2] = ui - vi; } }
        if (inv) for (int i = 0; i < N; ++i) { R[i] /= N; I[i] /= N; }
    };
    const int lifter = (int)(0.0012 * sr);
    for (size_t st = a; st + N <= b; st += N / 2) {
        for (int i = 0; i < N; ++i) { re[i] = x[st + i] * (0.5 - 0.5 * std::cos(2 * PI * i / N)); im[i] = 0; }
        fft(re, im, false);
        for (int i = 0; i < N; ++i) { re[i] = std::log(std::sqrt(re[i] * re[i] + im[i] * im[i]) + 1e-9); im[i] = 0; }
        fft(re, im, true);
        for (int i = 0; i < N; ++i) { if (i > lifter && i < N - lifter) { re[i] = 0; im[i] = 0; } }
        fft(re, im, false);
        for (int k = 0; k <= N / 2; ++k) acc[k] += re[k];
        ++frames;
    }
    for (auto& v : acc) v /= std::max(1, frames);
    return acc;
}
inline double envCorr(const std::vector<double>& A, const std::vector<double>& B, int sr, int N = 4096, double lo = 300, double hi = 4500) {
    const int k0 = (int)(lo * N / sr), k1 = (int)(hi * N / sr);
    double ma = 0, mb = 0; for (int k = k0; k < k1; ++k) { ma += A[k]; mb += B[k]; } ma /= (k1 - k0); mb /= (k1 - k0);
    double sab = 0, saa = 0, sbb = 0; for (int k = k0; k < k1; ++k) { sab += (A[k] - ma) * (B[k] - mb); saa += (A[k] - ma) * (A[k] - ma); sbb += (B[k] - mb) * (B[k] - mb); }
    return sab / std::sqrt(saa * sbb + 1e-30);
}

// Lag (samples) of the cross-correlation peak of y against x, searched in [0, maxLag].
inline int xcorrLag(const std::vector<float>& x, const std::vector<float>& y, int maxLag, size_t a, size_t b, double* peakRatio = nullptr) {
    double best = -1e30; int bl = 0; std::vector<double> c(maxLag + 1);
    for (int lag = 0; lag <= maxLag; ++lag) { double s = 0; for (size_t n = a; n < b && n + lag < y.size(); ++n) s += (double)x[n] * y[n + lag]; c[lag] = s; if (s > best) { best = s; bl = lag; } }
    if (peakRatio) { double second = -1e30; for (int lag = 0; lag <= maxLag; ++lag) if (std::abs(lag - bl) > 200 && c[lag] > second) second = c[lag]; *peakRatio = second / best; }
    return bl;
}

inline float maxJump(const std::vector<float>& y, size_t a, size_t b) {
    float m = 0; for (size_t n = std::max<size_t>(a, 1); n < b && n < y.size(); ++n) m = std::max(m, std::fabs(y[n] - y[n - 1])); return m;
}

} // namespace bench
