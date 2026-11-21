// stretch_test.cpp — offline check of the BMS STRETCH / WARP engine.
// Drives the real bms::VocalLayer (DSP/BMSDSP.hpp) note by note, exactly as
// the render block does, and measures output length + fundamental (YIN).
//   Tests/run_stretch_test.sh [voice.wav] [outdir]
#include "../BassMitStimmeExtension/DSP/BMSDSP.hpp"
#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>

static const float SR = 48000.0f;

// ── minimal WAV I/O (float32 / int16, mono or first channel) ──
static bool readWav(const char* path, std::vector<float>& out, float& sr) {
    FILE* f = std::fopen(path, "rb"); if (!f) return false;
    std::vector<uint8_t> b; uint8_t tmp[65536]; size_t n;
    while ((n = std::fread(tmp, 1, sizeof tmp, f)) > 0) b.insert(b.end(), tmp, tmp + n);
    std::fclose(f);
    if (b.size() < 44 || std::memcmp(b.data(), "RIFF", 4)) return false;
    int fmt = 0, ch = 1, bits = 16; size_t p = 12;
    while (p + 8 <= b.size()) {
        uint32_t sz; std::memcpy(&sz, &b[p + 4], 4);
        if (!std::memcmp(&b[p], "fmt ", 4)) {
            uint16_t t, c, bt; uint32_t r; std::memcpy(&t, &b[p + 8], 2); std::memcpy(&c, &b[p + 10], 2);
            std::memcpy(&r, &b[p + 12], 4); std::memcpy(&bt, &b[p + 22], 2);
            fmt = t; ch = c; sr = (float)r; bits = bt;
            if (fmt == 0xFFFE) fmt = bits == 32 ? 3 : 1;
        } else if (!std::memcmp(&b[p], "data", 4)) {
            const size_t bps = bits / 8, frames = std::min<size_t>(sz, b.size() - p - 8) / (bps * ch);
            out.resize(frames);
            for (size_t i = 0; i < frames; ++i) {
                const uint8_t* s = &b[p + 8 + i * bps * ch];
                if (fmt == 3 && bits == 32) { float v; std::memcpy(&v, s, 4); out[i] = v; }
                else if (bits == 16) { int16_t v; std::memcpy(&v, s, 2); out[i] = v / 32768.0f; }
                else if (bits == 24) { int32_t v = (s[0] << 8) | (s[1] << 16) | (s[2] << 24); out[i] = v / 2147483648.0f; }
            }
            return true;
        }
        p += 8 + sz + (sz & 1);
    }
    return false;
}
static void writeWav(const std::string& path, const std::vector<float>& x, float sr) {
    FILE* f = std::fopen(path.c_str(), "wb"); if (!f) { std::printf("  !! cannot write %s\n", path.c_str()); return; }
    const uint32_t n = (uint32_t)x.size(), data = n * 2, riff = 36 + data, r = (uint32_t)sr, br = r * 2;
    const uint16_t pcm = 1, ch = 1, ba = 2, bits = 16; const uint32_t fl = 16;
    std::fwrite("RIFF", 1, 4, f); std::fwrite(&riff, 4, 1, f); std::fwrite("WAVEfmt ", 1, 8, f);
    std::fwrite(&fl, 4, 1, f); std::fwrite(&pcm, 2, 1, f); std::fwrite(&ch, 2, 1, f); std::fwrite(&r, 4, 1, f);
    std::fwrite(&br, 4, 1, f); std::fwrite(&ba, 2, 1, f); std::fwrite(&bits, 2, 1, f);
    std::fwrite("data", 1, 4, f); std::fwrite(&data, 4, 1, f);
    for (float v : x) { int16_t s = (int16_t)std::lround(std::max(-1.0f, std::min(1.0f, v)) * 32767.0f); std::fwrite(&s, 2, 1, f); }
    std::fclose(f);
}

// ── YIN f0 estimate, median over voiced frames ──
static float yinFrame(const float* x, int W, float sr, float fmin, float fmax, float& conf) {
    const int tmin = (int)(sr / fmax), tmax = (int)(sr / fmin);
    std::vector<float> d(tmax + 2, 0.0f);
    for (int t = 1; t <= tmax + 1; ++t) { double s = 0; for (int i = 0; i < W; ++i) { const float q = x[i] - x[i + t]; s += q * q; } d[t] = (float)s; }
    double run = 0; std::vector<float> c(tmax + 2, 1.0f);
    for (int t = 1; t <= tmax + 1; ++t) { run += d[t]; c[t] = run > 0 ? (float)(d[t] * t / run) : 1.0f; }
    int best = -1;
    for (int t = tmin; t <= tmax; ++t) if (c[t] < 0.15f) { while (t + 1 <= tmax && c[t + 1] < c[t]) ++t; best = t; break; }
    if (best < 0) { conf = 0; return 0; }
    const float a = c[best - 1], b = c[best], cc = c[best + 1];
    const float den = a - 2 * b + cc, sh = std::fabs(den) > 1e-9f ? 0.5f * (a - cc) / den : 0.0f;
    conf = 1.0f - b; return sr / (best + sh);
}
static float medianF0(const std::vector<float>& x, float sr, float fmin = 60, float fmax = 900) {
    const int W = (int)(sr * 0.03f), hop = W / 2, tmax = (int)(sr / fmin) + 2;
    float peak = 0; for (float v : x) peak = std::max(peak, std::fabs(v));
    std::vector<float> f;
    for (size_t s = 0; s + W + tmax < x.size(); s += hop) {
        double e = 0; for (int i = 0; i < W; ++i) e += x[s + i] * x[s + i];
        if (std::sqrt(e / W) < peak * 0.1f) continue;                 // voiced + loud frames only
        float conf; const float f0 = yinFrame(&x[s], W, sr, fmin, fmax, conf);
        if (f0 > 0) f.push_back(f0);
    }
    if (f.empty()) return 0;
    std::sort(f.begin(), f.end()); return f[f.size() / 2];
}
/// Length = first to last sample above -40 dB of the peak.
static float activeSeconds(const std::vector<float>& x, float sr) {
    float peak = 0; for (float v : x) peak = std::max(peak, std::fabs(v));
    const float thr = peak * 0.01f; int a = -1, b = -1;
    for (int i = 0; i < (int)x.size(); ++i) if (std::fabs(x[i]) > thr) { if (a < 0) a = i; b = i; }
    return a < 0 ? 0 : (b - a + 1) / sr;
}

struct Cfg { int warp = 0; float stretch = 1.0f; float pitch = 0; bool formant = true; int note = 36; bool follow = false; float bpm = 120; };
struct Result { std::vector<float> y; double usPerSec = 0, noteOnUs = 0; };

static Result render(const std::vector<float>& smp, float smpSR, const Cfg& c) {
    auto L = std::make_unique<bms::VocalLayer>();
    L->prepare(SR);
    L->setSample(smp.data(), (int)smp.size(), smpSR);
    L->setMode(0); L->setMix(1.0f); L->setFollow(c.follow); L->setPitchSemi(c.pitch);
    L->setFilters(0.0f, 1.0f, false);            // bypass FX so we measure the voice itself
    L->setWarp(c.warp, std::log2(c.stretch), c.formant); L->setTempo(c.bpm, 4);
    Result r;
    auto t0 = std::chrono::steady_clock::now();
    L->noteOn(c.note);
    auto t1 = std::chrono::steady_clock::now();
    r.noteOnUs = std::chrono::duration<double, std::micro>(t1 - t0).count();
    const int maxN = (int)(SR * 40);
    while ((int)r.y.size() < maxN) { r.y.push_back(L->process()); if (!L->isPlaying()) break; }
    auto t2 = std::chrono::steady_clock::now();
    r.usPerSec = std::chrono::duration<double, std::micro>(t2 - t1).count() / (r.y.size() / SR);
    return r;
}

int main(int argc, char** argv) {
    const std::string outDir = argc > 2 ? argv[2] : "";
    int fails = 0;
    auto check = [&](bool ok, const char* what) { std::printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what); if (!ok) ++fails; };

    // ── 1. Synthetic "vocal": 165 Hz glottal-ish pulse train (harmonics up to
    // 6 kHz) through two formant resonances, 1.0 s, 10 ms fades. ──
    std::vector<float> syn((size_t)SR);
    {
        double ph = 0; float z1 = 0, z2 = 0, w1 = 0, w2 = 0;
        for (size_t i = 0; i < syn.size(); ++i) {
            double v = 0; for (int h = 1; h * 165.0 < 6000; ++h) v += std::sin(ph * h) / h;
            ph += 2 * M_PI * 165.0 / SR;
            // crude 2-pole resonators around 700 Hz and 1200 Hz ("ah")
            auto res = [](float x, float& a, float& b, float f, float q) { const float w = 2 * 3.14159265f * f / SR, r = 1 - w / (2 * q);
                const float y = x + 2 * r * std::cos(w) * a - r * r * b; b = a; a = y; return y * (1 - r); };
            float y = res((float)v, z1, z2, 700, 6) + res((float)v, w1, w2, 1200, 8);
            const float fade = std::min(1.0f, std::min((float)i, (float)(syn.size() - i)) / (0.01f * SR));
            syn[i] = y * fade;
        }
        float pk = 0; for (float v : syn) pk = std::max(pk, std::fabs(v));
        for (float& v : syn) v *= 0.5f / pk;
    }
    const float synF0 = medianF0(syn, SR), synLen = activeSeconds(syn, SR);
    std::printf("SYNTH source: f0 %.2f Hz, length %.3f s\n", synF0, synLen);
    std::printf("%-26s %9s %9s %9s %9s %9s %10s\n", "case", "len s", "len exp", "f0 Hz", "f0 exp", "cents", "CPU x RT");
    auto row = [&](const char* name, const Result& r, float lenExp, float f0Exp, float lenTol = 0.03f) {
        const float len = activeSeconds(r.y, SR), f0 = medianF0(r.y, SR);
        const float cents = f0 > 0 ? 1200.0f * std::log2(f0 / f0Exp) : 9999.0f;
        std::printf("%-26s %9.3f %9.3f %9.2f %9.2f %+9.1f %10.0f   (note-on %.0f us)\n", name, len, lenExp, f0, f0Exp, cents,
                    1e6 / std::max(1.0, r.usPerSec), r.noteOnUs);
        char buf[160];
        std::snprintf(buf, sizeof buf, "%s: length within %.0f%%", name, lenTol * 100); check(std::fabs(len / lenExp - 1) < lenTol, buf);
        std::snprintf(buf, sizeof buf, "%s: pitch within 10 cents", name); check(std::fabs(cents) < 10.0f, buf);
    };
    Cfg c;
    c = {}; row("classic 1x (old path)", render(syn, SR, c), synLen, synF0);
    c = {}; c.warp = 1; c.stretch = 0.5f; row("WARP FREE 0.50x", render(syn, SR, c), synLen * 0.5f, synF0);
    c = {}; c.warp = 1; c.stretch = 2.0f; row("WARP FREE 2.00x", render(syn, SR, c), synLen * 2.0f, synF0);
    c = {}; c.warp = 1; c.stretch = 1.0f; c.pitch = 5; row("WARP 1x PITCH +5", render(syn, SR, c), synLen, synF0 * std::pow(2.0f, 5 / 12.0f));
    c = {}; c.warp = 1; c.stretch = 1.0f; c.follow = true; c.note = 43; row("WARP 1x FOLLOW G2 (+7)", render(syn, SR, c), synLen, synF0 * std::pow(2.0f, 7 / 12.0f));
    c = {}; c.warp = 6; c.bpm = 120; row("WARP 1 BAR @120 (2.0 s)", render(syn, SR, c), 2.0f * synLen / ((syn.size()) / SR), synF0, 0.04f);
    {   // classic varispeed for contrast: +5 st also shortens (that is the old behaviour)
        c = {}; c.pitch = 5; auto r = render(syn, SR, c);
        std::printf("  classic PITCH +5 for contrast: len %.3f s (shorter, as before), f0 %.2f Hz\n", activeSeconds(r.y, SR), medianF0(r.y, SR));
    }

    // ── 2. Real voice (Stimme.m4a converted to WAV) ──
    if (argc > 1) {
        std::vector<float> v; float vsr = SR;
        if (!readWav(argv[1], v, vsr)) { std::printf("cannot read %s\n", argv[1]); return 2; }
        const int onset = bms::VocalLayer::computeOnset(v.data(), (int)v.size(), vsr);
        std::vector<float> body(v.begin() + onset, v.end());
        const float vF0 = medianF0(body, vsr), vLen = activeSeconds(body, vsr);
        std::printf("\nVOICE %s: %.0f Hz SR, f0 %.2f Hz, length from onset %.3f s\n", argv[1], vsr, vF0, vLen);
        Result r;
        c = {}; r = render(v, vsr, c); row("voice classic 1x", r, vLen, vF0, 0.05f);
        if (!outDir.empty()) writeWav(outDir + "/bms_stretch_1x_original_KJ_v001.wav", r.y, SR);
        c = {}; c.warp = 1; c.stretch = 0.5f; r = render(v, vsr, c); row("voice WARP 0.50x", r, vLen * 0.5f, vF0, 0.05f);
        if (!outDir.empty()) writeWav(outDir + "/bms_stretch_0p5x_KJ_v001.wav", r.y, SR);
        c = {}; c.warp = 1; c.stretch = 2.0f; r = render(v, vsr, c); row("voice WARP 2.00x", r, vLen * 2.0f, vF0, 0.05f);
        if (!outDir.empty()) writeWav(outDir + "/bms_stretch_2x_KJ_v001.wav", r.y, SR);
        c = {}; c.warp = 1; c.pitch = 5; r = render(v, vsr, c); row("voice WARP PITCH +5", r, vLen, vF0 * std::pow(2.0f, 5 / 12.0f), 0.05f);
        if (!outDir.empty()) writeWav(outDir + "/bms_stretch_pitch+5_warp_KJ_v001.wav", r.y, SR);
        c = {}; c.pitch = 5; r = render(v, vsr, c);
        std::printf("  voice classic PITCH +5 (old varispeed, for contrast): len %.3f s, f0 %.2f Hz\n", activeSeconds(r.y, SR), medianF0(r.y, SR));
        if (!outDir.empty()) writeWav(outDir + "/bms_stretch_pitch+5_classic_KJ_v001.wav", r.y, SR);
        c = {}; c.warp = 6; c.bpm = 120; r = render(v, vsr, c);
        const float barExp = 2.0f * vLen / ((v.size() - onset) / vsr);
        row("voice WARP 1 BAR @120", r, barExp, vF0, 0.05f);
        if (!outDir.empty()) writeWav(outDir + "/bms_warp_1bar_120bpm_KJ_v001.wav", r.y, SR);
    }
    std::printf("\n%s (%d failure%s)\n", fails ? "FAILED" : "ALL PASS", fails, fails == 1 ? "" : "s");
    return fails ? 1 : 0;
}
