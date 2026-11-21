// VoiceBox sound-quality harness — see sq_common.hpp / run_sq.sh.
// Usage: sq_<tag> <tag> <Tests/sq dir> [all | test names…]
#include "sq_common.hpp"
using namespace sq;

static std::string gTag, gDir;
#define M(...) do { std::printf("METRIC "); std::printf(__VA_ARGS__); std::printf("\n"); } while (0)

struct Cfg { std::string name; std::function<void(AUHost&)> set; };
static std::vector<Cfg> moduleCfgs() {
    return {
        {"off",       [](AUHost& h) { h.allOff(); }},
        {"autotune",  [](AUHost& h) { h.allOff(); h.p[0] = 1; }},
        {"harmonizer",[](AUHost& h) { h.allOff(); h.p[3] = 1; }},
        {"harm_auto", [](AUHost& h) { h.allOff(); h.p[3] = 1; h.p[21] = 1; }},
        {"pitchskip", [](AUHost& h) { h.allOff(); h.p[6] = 1; }},
        {"delay",     [](AUHost& h) { h.allOff(); h.p[9] = 1; }},
        {"chop",      [](AUHost& h) { h.allOff(); h.p[12] = 1; }},
        {"vocoder",   [](AUHost& h) { h.allOff(); h.p[15] = 1; }},
        {"reverb",    [](AUHost& h) { h.allOff(); h.p[18] = 1; }},
        {"lowtuner",  [](AUHost& h) { h.allOff(); h.p[23] = 1; }},
        {"low-12",    [](AUHost& h) { h.allOff(); h.p[23] = 1; h.p[24] = -12; }},
        {"low-24",    [](AUHost& h) { h.allOff(); h.p[23] = 1; h.p[24] = -24; }},
        {"all_on",    [](AUHost& h) { h.allOn(); }},
    };
}
static std::vector<Cfg> presetCfgs() {
    std::vector<Cfg> v;
    for (int i = 0; i < 10; ++i) v.push_back({std::string("P_") + kPresetNames[i], [i](AUHost& h) { h.preset(i); }});
    return v;
}
static std::vector<Cfg> allCfgs() { auto a = moduleCfgs(); auto b = presetCfgs(); a.insert(a.end(), b.begin(), b.end()); return a; }

static void run(const Cfg& c, int sr, const Buf& inL, const Buf& inR, Buf& L, Buf& R, int& lat, int block = 512, bool mono = false) {
    AUHost h(sr); c.set(h); lat = h.latency(); h.render(inL, inR, L, R, block, mono);
}

// ── levels: peak / true peak / clipping / NaN / DC / gain, per config and input level ──
static void testLevels() {
    const int sr = 48000; Phrase P = makePhrase(sr, 44.0);
    for (const Cfg& c : allCfgs()) {
        double gains[3] = {0, 0, 0}; int gi = 0;
        for (double lvl : {0.0, -12.0, -40.0}) {
            Buf x = scaled(P.x, std::pow(10.0, lvl / 20.0)), L, R; int lat; run(c, sr, x, x, L, R, lat);
            const Stats si = stats(x), so = stats(L), sr2 = stats(R);
            const double gain = dB(so.rms) - dB(si.rms); gains[gi++] = gain;
            M("levels %-12s in%+3.0fdBFS peak %+6.2f truepeak %+6.2f clipped %5ld over0dBFS %5ld nan %ld denorm %ld dc %+.5f gain %+6.2f dB peakR %+6.2f",
              c.name.c_str(), lvl, dB(so.peak), dB(so.truePeak), so.clipped, so.over, so.nan + sr2.nan, so.denorm + sr2.denorm, so.dc, gain, dB(sr2.peak));
        }
        M("levels_linearity %-12s gain(0dBFS)-gain(-40dBFS) %+6.2f dB   gain(-12)-gain(-40) %+6.2f dB", c.name.c_str(), gains[0] - gains[2], gains[1] - gains[2]);
    }
}

// ── thd: THD+N of a steady sine through the rack ──
static double bestThdn(const Buf& y, double hz, int sr, size_t a, size_t b, double* fOut = nullptr) {
    double best = 0, bf = hz; for (double c = -30; c <= 30; c += 0.5) { const double f = hz * std::pow(2.0, c / 1200.0); const double t = thdn(y, f, sr, a, b); if (t < best) { best = t; bf = f; } }
    for (double c = -0.5; c <= 0.5; c += 0.02) { const double f = bf * std::pow(2.0, c / 1200.0); const double t = thdn(y, f, sr, a, b); if (t < best) { best = t; if (fOut) *fOut = f; } }
    return best;
}
static void testThd() {
    const int sr = 48000;
    struct T { const char* name; std::function<void(AUHost&)> set; double inHz, outHz; };
    const T tests[] = {
        {"off_220Hz",            [](AUHost& h) { h.allOff(); }, 220.0, 220.0},
        {"off_1kHz",             [](AUHost& h) { h.allOff(); }, 1000.0, 1000.0},
        {"autotune_on_note_220", [](AUHost& h) { h.allOff(); h.p[0] = 1; h.p[1] = 0.1f; }, 220.0, 220.0},
        {"autotune_+40c_to_220", [](AUHost& h) { h.allOff(); h.p[0] = 1; h.p[1] = 0.0f; }, 220.0 * std::pow(2.0, 40 / 1200.0), 220.0},
        {"low-5_220Hz",          [](AUHost& h) { h.allOff(); h.p[23] = 1; }, 220.0, 220.0 * std::pow(2.0, -5 / 12.0)},
        {"low-12_220Hz",         [](AUHost& h) { h.allOff(); h.p[23] = 1; h.p[24] = -12; }, 220.0, 110.0},
    };
    for (const T& t : tests) for (double lvl : {-1.0, -6.0, -12.0, -20.0}) {
        Buf x = sine(t.inHz, 4.0, sr, std::pow(10.0, lvl / 20.0)), L, R; AUHost h(sr); t.set(h); h.render(x, x, L, R);
        double f = t.outHz; const double v = bestThdn(L, t.outHz, sr, (size_t)(1.5 * sr), (size_t)(3.5 * sr), &f);
        M("thd %-22s in%+3.0fdBFS THD+N %6.1f dB (%.4f %%)  out_peak %+6.2f dBFS", t.name, lvl, v, 100.0 * std::pow(10.0, v / 20.0), dB(stats(L, sr, 3 * sr).peak));
    }
}

// ── tracker + pitch marks on a signal (independent PsolaCore) ──
struct TrackReport { double voicedPct = 0, flipsPerSec = 0, octJumpsPerVoicedSec = 0, markBadPct = 0, grossErrPct = 0, jitterCents = 0; };
static TrackReport trackReport(const Buf& x, int sr, const std::vector<double>* truthMidi = nullptr) {
    vbx::PsolaCore core; core.prepare((float)sr, std::max(1024, (int)std::ceil(1024.0 * sr / 48000.0)));
    TrackReport r; long hops = 0, voiced = 0, flips = 0, oct = 0, marks = 0, bad = 0, gross = 0, cmp = 0; bool pv = false; float pm = 0; int64_t lastHead = 0;
    std::vector<double> errs; const int W = core.tracker_.window();
    for (size_t n = 0; n < x.size(); ++n) {
        core.push(x[n], x[n]);
        while (lastHead < core.head_) {
            if (lastHead > 0) { const auto& m = core.marks_[lastHead & 1023]; const auto& q = core.marks_[(lastHead - 1) & 1023];
                if (m.voiced && q.voiced) { ++marks; const double d = (double)m.pos - (double)q.pos; if (std::fabs(d - m.T) > 0.15 * m.T) ++bad; } }
            ++lastHead;
        }
        if (!core.frameReady()) continue;
        const vbx::TrackState& st = core.track(); ++hops;
        if (st.voiced) { ++voiced; if (pv && std::fabs(st.midi - pm) > 6.0f) ++oct; pm = st.midi; }
        if (st.voiced != pv) ++flips; pv = st.voiced;
        if (truthMidi) { const int64_t c = (int64_t)n - W / 2; if (c >= 0) { const double tm = (*truthMidi)[(size_t)c];
                if (tm > 0 && st.voiced) { ++cmp; const double e = (st.midi - tm) * 100.0; if (std::fabs(e) > 80.0) ++gross; else errs.push_back(e); } } }
    }
    const double secs = (double)x.size() / sr, vsecs = std::max(1e-9, (double)voiced * core.tracker_.hop() / sr);
    r.voicedPct = 100.0 * voiced / std::max(1L, hops); r.flipsPerSec = flips / secs; r.octJumpsPerVoicedSec = oct / vsecs;
    r.markBadPct = 100.0 * bad / std::max(1L, marks); r.grossErrPct = 100.0 * gross / std::max(1L, cmp);
    if (!errs.empty()) { double m = 0; for (double e : errs) m += e; m /= errs.size(); double s = 0; for (double e : errs) s += (e - m) * (e - m); r.jitterCents = std::sqrt(s / errs.size()); }
    return r;
}

// Periodicity of the output vs the input (voiced frames): a clean shifter keeps the
// McLeod clarity; grain jitter / subharmonics / garbling lower it.
static void clarityCompare(const Buf& in, const Buf& out, int lat, int sr, double& inMean, double& outMean, double& pctWorse, double& subharmPct) {
    Buf o(out.begin() + std::min<size_t>(lat, out.size()), out.end());
    PitchFrames A = pitchFrames(in, sr), B = pitchFrames(o, sr);
    double si = 0, so = 0; long n = 0, worse = 0, sub = 0;
    for (size_t i = 0; i < A.hz.size() && i < B.hz.size(); ++i) {
        if (A.hz[i] <= 0 || A.clar[i] < 0.9f || A.rms[i] < 0.01f) continue;
        ++n; si += A.clar[i]; so += B.clar[i]; if (B.clar[i] < A.clar[i] - 0.10f) ++worse;
        // subharmonic: periodicity at 2T clearly better than at T in the output
        if (B.hz[i] > 0) { const double T = sr / B.hz[i]; const float* w = &o[i * (size_t)A.hop]; if (2 * T + 2 < A.W) { const double c1 = nsdfAt(w, A.W, T), c2 = nsdfAt(w, A.W, 2 * T); if (c2 > c1 + 0.08) ++sub; } }
    }
    inMean = n ? si / n : 0; outMean = n ? so / n : 0; pctWorse = n ? 100.0 * worse / n : 0; subharmPct = n ? 100.0 * sub / n : 0;
}

static std::vector<std::pair<std::string, std::string>> materialFiles() {
    return { {"realH33", gDir + "/material/realvox_H_33s_KJ_v001.wav"}, {"realH131", gDir + "/material/realvox_H_131s_KJ_v001.wav"},
             {"realG74", gDir + "/material/realvox_G_74s_KJ_v001.wav"}, {"stimme", gDir + "/material/stimme_KJ_v001.wav"} };
}

static void testTracker() {
    for (int sr : {44100, 48000, 96000}) for (double base : {44.0, 56.0}) for (int inv = 0; inv < 2; ++inv) {
        Phrase P = makePhrase(sr, base, inv != 0); Buf x = scaled(P.x, 0.25);
        TrackReport r = trackReport(x, sr, &P.truthMidi);
        M("tracker synth sr%d base%.0f %s voiced %5.1f%% flips/s %4.1f octjumps/voiced-s %5.2f gross_err %5.2f%% jitter %4.1f c bad_marks %5.2f%%",
          sr, base, inv ? "inverted" : "normal  ", r.voicedPct, r.flipsPerSec, r.octJumpsPerVoicedSec, r.grossErrPct, r.jitterCents, r.markBadPct);
    }
    // Things that are NOT a voice must not be tracked (the level gate is low, the clarity test has to hold):
    // room noise, and a quiet voice (−40 dBFS peaks) which SHOULD be tracked.
    { const int sr = 48000; Buf nz = whiteNoise(5.0, sr, 0.004); double z = 0; Buf pink(nz.size()); for (size_t i = 0; i < nz.size(); ++i) { z += 0.02 * (nz[i] * 20.0 - z); pink[i] = (float)z; }
      TrackReport a = trackReport(nz, sr), b = trackReport(pink, sr);
      Phrase P = makePhrase(sr, 44.0); Buf q = scaled(P.x, 0.01); TrackReport c = trackReport(q, sr, &P.truthMidi);
      M("tracker noise: white −48 dBFS voiced %.1f%%  low-passed noise voiced %.1f%%  |  phrase at −40 dBFS peak: voiced %.1f%% gross_err %.2f%%", a.voicedPct, b.voicedPct, c.voicedPct, c.grossErrPct); }
    for (auto& mf : materialFiles()) {
        Buf L, R; int sr = 0; if (!loadWav(mf.second, L, R, sr)) { M("tracker %s MISSING", mf.first.c_str()); continue; }
        Buf m(L.size()); for (size_t i = 0; i < L.size(); ++i) m[i] = 0.5f * (L[i] + R[i]);
        TrackReport r = trackReport(m, sr);
        M("tracker %-8s voiced %5.1f%% flips/s %4.1f octjumps/voiced-s %5.2f bad_marks %5.2f%%", mf.first.c_str(), r.voicedPct, r.flipsPerSec, r.octJumpsPerVoicedSec, r.markBadPct);
    }
}

// ── real + synthetic voice through pitch configs: envelope, periodicity, clicks ──
static void voiceQuality(const std::string& label, const Buf& inL, const Buf& inR, int sr) {
    struct C { const char* name; std::function<void(AUHost&)> set; };
    const C cfgs[] = {
        {"off",          [](AUHost& h) { h.allOff(); }},
        {"at_amt0",      [](AUHost& h) { h.allOff(); h.p[0] = 1; h.p[2] = 0; }},
        {"at_hard_chrom",[](AUHost& h) { h.allOff(); h.p[0] = 1; h.p[1] = 0.0f; }},
        {"at_tuned_maj", [](AUHost& h) { h.allOff(); h.p[0] = 1; h.p[1] = 0.10f; h.p[22] = 1; }},
        {"at_soft",      [](AUHost& h) { h.allOff(); h.p[0] = 1; h.p[1] = 0.55f; }},
        {"low-5",        [](AUHost& h) { h.allOff(); h.p[23] = 1; }},
        {"low-12",       [](AUHost& h) { h.allOff(); h.p[23] = 1; h.p[24] = -12; }},
        {"harm+7_solo",  [](AUHost& h) { h.allOff(); h.p[3] = 1; h.p[4] = 7; h.p[5] = 1; }},
        {"harm+12_solo", [](AUHost& h) { h.allOff(); h.p[3] = 1; h.p[4] = 12; h.p[5] = 1; }},
        {"vocoder",      [](AUHost& h) { h.allOff(); h.p[15] = 1; }},
    };
    Buf mono(inL.size()); for (size_t i = 0; i < inL.size(); ++i) mono[i] = 0.5f * (inL[i] + inR[i]);
    for (const C& c : cfgs) {
        AUHost h(sr); c.set(h); Buf L, R; h.render(inL, inR, L, R); const int lat = h.latency();
        double med, p95, mx; envelopeDeviation(inL, L, lat, sr, med, p95, mx);
        double ci, co, worse, sub; clarityCompare(inL, L, lat, sr, ci, co, worse, sub);
        double wi = 0, wo = 0; const int cin = clickCount(inL, 0, inL.size(), 8.0, 2e-3, &wi), cout = clickCount(L, 0, L.size(), 8.0, 2e-3, &wo);
        const Stats so = stats(L);
        M("voice %-8s %-14s gain %+5.2f dB env_p95 %4.2f dB env_max %5.2f dB | clarity in %.3f out %.3f frames_worse %5.1f%% subharm %4.1f%% | clicks in %d out %d | peak %+6.2f over %ld",
          label.c_str(), c.name, med, p95, mx, ci, co, worse, sub, cin, cout, dB(so.peak), so.over);
    }
}
static void testReal() {
    for (auto& mf : materialFiles()) { Buf L, R; int sr = 0; if (!loadWav(mf.second, L, R, sr)) continue; voiceQuality(mf.first, L, R, sr); }
}
static void testSynthVoice() {
    for (double base : {44.0, 56.0}) for (int inv = 0; inv < 2; ++inv) {
        Phrase P = makePhrase(48000, base, inv != 0); Buf x = scaled(P.x, 0.25);
        voiceQuality(std::string("syn") + (base < 50 ? "Lo" : "Hi") + (inv ? "Inv" : ""), x, x, 48000);
    }
}


// ── toggle: engage/disengage every 0.5 s; clicks = 2nd-difference outliers ──
static Buf smoothVowel(int sr, double hz, double sec, double peak) {
    std::vector<double> f0((size_t)(sec * sr), hz); Buf x = bench::vowel(f0, sr, 0.25); normalizePeak(x, peak); return x;
}
static void testToggle() {
    const int sr = 48000;
    struct T { const char* name; int addr; std::function<void(AUHost&)> pre; bool voice; };
    const T tests[] = {
        {"autotune", 0, [](AUHost& h) { h.p[1] = 0.0f; }, true}, {"harmonizer", 3, [](AUHost&) {}, true}, {"pitchskip", 6, [](AUHost&) {}, true},
        {"lowtuner", 23, [](AUHost&) {}, true}, {"low-24(hq)", 23, [](AUHost& h) { h.p[24] = -24; }, true}, {"harm+19(hq)", 3, [](AUHost& h) { h.p[4] = 19; }, true},
        {"delay", 9, [](AUHost&) {}, false}, {"chop", 12, [](AUHost&) {}, false}, {"vocoder", 15, [](AUHost&) {}, false}, {"reverb", 18, [](AUHost&) {}, false},
    };
    for (const T& t : tests) {
        // input: vowel slightly off-pitch (so autotune really shifts) or a 220 Hz sine for the non-pitch modules
        Buf x = t.voice ? smoothVowel(sr, 150.0 * std::pow(2.0, 30 / 1200.0), 6.0, 0.25) : sine(220.0, 6.0, sr, 0.25), L, R;
        AUHost h(sr); h.allOff(); t.pre(h);
        std::vector<Event> ev; for (int k = 1; k < 11; ++k) ev.push_back({(size_t)(k * 0.5 * sr), t.addr, (k & 1) ? 1.0f : 0.0f});
        h.render(x, x, L, R, 512, false, &ev);
        // steady reference: the same module held on for the whole signal
        AUHost h2(sr); h2.allOff(); t.pre(h2); h2.p[t.addr] = 1; Buf L2, R2; h2.render(x, x, L2, R2);
        const double steady = std::max(maxD2(L2, (size_t)(2 * sr), (size_t)(5 * sr)), maxD2(x, sr, 2 * sr));
        double worst = 0; int bad = 0;
        for (int k = 1; k < 11; ++k) { const size_t a = (size_t)(k * 0.5 * sr); const double m = maxD2(L, a, a + (size_t)(0.25 * sr)); worst = std::max(worst, m); if (m > 2.0 * steady) ++bad; }
        double wr = 0; const int cc = clickCount(L, sr / 4, L.size(), 8.0, 1e-3, &wr);
        M("toggle %-12s worst_jump/steady %6.2f  toggles_with_click %2d/10  click_events %3d (worst %5.1fx local)", t.name, worst / std::max(steady, 1e-9), bad, cc, wr);
    }
}

// ── zipper: continuous parameter moves (host automation, 512-sample blocks) ──
static void testZipper() {
    const int sr = 48000;
    struct T { const char* name; std::function<void(AUHost&)> pre; int addr; float from, to; bool voice; };
    const T tests[] = {
        {"harm_mix",   [](AUHost& h) { h.p[3] = 1; }, 5, 0.0f, 1.0f, true},
        {"harm_semis", [](AUHost& h) { h.p[3] = 1; }, 4, 0.0f, 12.0f, true},
        {"low_mix",    [](AUHost& h) { h.p[23] = 1; }, 25, 0.0f, 1.0f, true},
        {"at_amount",  [](AUHost& h) { h.p[0] = 1; h.p[1] = 0; }, 2, 0.0f, 1.0f, true},
        {"skip_amt",   [](AUHost& h) { h.p[6] = 1; }, 8, 0.0f, 1.0f, true},
        {"delay_time", [](AUHost& h) { h.p[9] = 1; }, 10, 100.0f, 400.0f, false},
        {"delay_fb",   [](AUHost& h) { h.p[9] = 1; }, 11, 0.0f, 0.9f, false},
        {"chop_depth", [](AUHost& h) { h.p[12] = 1; h.p[13] = 0.1f; }, 14, 0.0f, 1.0f, false},
        {"voc_mix",    [](AUHost& h) { h.p[15] = 1; }, 17, 0.0f, 1.0f, false},
        {"voc_tone",   [](AUHost& h) { h.p[15] = 1; }, 16, 0.0f, 1.0f, false},
        {"rev_mix",    [](AUHost& h) { h.p[18] = 1; }, 20, 0.0f, 1.0f, false},
        {"rev_size",   [](AUHost& h) { h.p[18] = 1; }, 19, 0.0f, 1.0f, false},
    };
    for (const T& t : tests) {
        Buf x = t.voice ? smoothVowel(sr, 150.0, 5.0, 0.25) : sine(220.0, 5.0, sr, 0.25), L, R;
        AUHost h(sr); h.allOff(); t.pre(h); h.p[t.addr] = t.from;
        std::vector<Event> ev; const size_t a = sr, b = 3 * (size_t)sr;      // ramp from 1 s to 3 s
        for (size_t pos = a; pos <= b; pos += 512) ev.push_back({pos, t.addr, t.from + (t.to - t.from) * (float)(pos - a) / (float)(b - a)});
        h.render(x, x, L, R, 512, false, &ev);
        AUHost h2(sr); h2.allOff(); t.pre(h2); h2.p[t.addr] = t.to; Buf L2, R2; h2.render(x, x, L2, R2);
        const double steady = std::max(maxD2(L2, 3 * (size_t)sr, 5 * (size_t)sr - 4096), maxD2(x, sr, 2 * sr));
        const double moving = maxD2(L, a, b + 4096);
        double wr = 0; const int cc = clickCount(L, a - 1024, b + 8192, 8.0, 1e-3, &wr);
        M("zipper %-11s max_jump/steady %7.2f  click_events %4d (worst %5.1fx local)", t.name, moving / std::max(steady, 1e-9), cc, wr);
    }
}

// ── blocks: static parameters → the output must not depend on the host block size ──
static void testBlocks() {
    const int sr = 48000; Phrase P = makePhrase(sr, 44.0); Buf x = scaled(P.x, 0.25);
    for (const char* name : {"all_on", "P_TUNED", "P_FULL"}) {
        Cfg c; for (const Cfg& k : allCfgs()) if (k.name == name) c = k;
        Buf ref, refR; int lat; run(c, sr, x, x, ref, refR, lat, 512);
        for (int bs : {64, 128, 441, 1024, 4096}) { Buf L, R; run(c, sr, x, x, L, R, lat, bs); double m = 0; for (size_t i = 0; i < L.size(); ++i) m = std::max<double>(m, std::fabs(L[i] - ref[i]));
            M("blocks %-8s block %4d vs 512: max_abs_diff %.2e", name, bs, m); }
        Buf Lm, Rm; run(c, sr, x, x, Lm, Rm, lat, 512, true); const Stats s = stats(Lm);
        M("blocks %-8s mono bus: peak %+6.2f dBFS nan %ld over %ld", name, dB(s.peak), s.nan, s.over);
        // determinism (uninitialised state shows up as run-to-run differences)
        Buf L2, R2; run(c, sr, x, x, L2, R2, lat, 512); double m = 0; for (size_t i = 0; i < L2.size(); ++i) m = std::max<double>(m, std::fabs(L2[i] - ref[i]));
        M("blocks %-8s rerun on a fresh instance: max_abs_diff %.2e", name, m);
    }
}

// ── samplerate: latency, delay time, reverb decay, chop edge, vocoder level per rate ──
static void testSampleRate() {
    for (int sr : {44100, 48000, 88200, 96000}) {
        // latency: impulse through the rack with everything off, and with AUTOTUNE on (amount 0)
        Buf imp((size_t)sr, 0.0f); imp[100] = 0.5f; Buf L, R;
        { AUHost h(sr); h.allOff(); h.render(imp, imp, L, R); size_t pk = 0; for (size_t i = 0; i < L.size(); ++i) if (std::fabs(L[i]) > std::fabs(L[pk])) pk = i;
          M("samplerate %6d latency reported %4d measured(off) %4d  (%.2f ms)", sr, h.latency(), (int)pk - 100, 1000.0 * h.latency() / sr); }
        { AUHost h(sr); h.allOff(); h.p[0] = 1; h.p[2] = 0; h.render(imp, imp, L, R); size_t pk = 0; for (size_t i = 0; i < L.size(); ++i) if (std::fabs(L[i]) > std::fabs(L[pk])) pk = i;
          M("samplerate %6d latency measured(autotune on) %4d peak %.3f (in 0.500)", sr, (int)pk - 100, std::fabs(L[pk])); }
        // delay: first echo time
        { AUHost h(sr); h.allOff(); h.p[9] = 1; h.render(imp, imp, L, R); const int lat = h.latency(); size_t pk = 100 + lat + 50; for (size_t i = pk; i < L.size(); ++i) if (std::fabs(L[i]) > std::fabs(L[pk])) pk = i;
          M("samplerate %6d delay 250 ms → first echo at %.2f ms", sr, 1000.0 * ((double)pk - 100 - lat) / sr); }
        // reverb: decay time (Schroeder, −5…−25 dB extrapolated to 60) and wet level for noise
        { Buf x((size_t)(4 * sr), 0.0f); x[100] = 0.5f; AUHost h(sr); h.allOff(); h.p[18] = 1; h.p[20] = 1.0f; h.render(x, x, L, R);
          // (band-limit to ~2 kHz first: a broadband impulse has more fast-decaying HF at higher rates)
          { double z1 = 0, z2 = 0; const double a = 1 - std::exp(-2 * PI * 2000.0 / sr); for (auto& v : L) { z1 += a * (v - z1); z2 += a * (z1 - z2); v = (float)z2; } }
          std::vector<double> e(L.size() + 1, 0.0); for (size_t i = L.size(); i-- > 0;) e[i] = e[i + 1] + (double)L[i] * L[i];
          const double e0 = e[0]; size_t t5 = 0, t25 = 0; for (size_t i = 0; i < L.size(); ++i) { const double d = 10 * std::log10(e[i] / e0 + 1e-30); if (!t5 && d < -5) t5 = i; if (!t25 && d < -25) { t25 = i; break; } }
          Buf nz = whiteNoise(3.0, sr, 0.1); AUHost h3(sr); h3.allOff(); h3.p[18] = 1; h3.p[20] = 1.0f; Buf Ln, Rn; h3.render(nz, nz, Ln, Rn);
          M("samplerate %6d reverb size .5: RT60 %.2f s, wet-only gain on noise %+.2f dB", sr, 3.0 * (double)(t25 - t5) / sr, dB(rmsOf(Ln, sr, 3 * (size_t)sr)) - dB(rmsOf(nz, sr, 3 * (size_t)sr))); }
        // chop: 10–90 % time of the gate edge on DC
        { Buf x((size_t)sr, 0.5f); AUHost h(sr); h.allOff(); h.p[12] = 1; h.p[13] = 4; h.p[14] = 1; h.render(x, x, L, R); const int lat = h.latency();
          // falling edge after the first half period (125 ms; the gate LFO is not delayed by the latency)
          (void)lat; size_t a = (size_t)(0.125 * sr) - 10, t90 = 0, t10 = 0; for (size_t i = a; i < L.size(); ++i) { if (!t90 && L[i] < 0.45f) t90 = i; if (!t10 && L[i] < 0.05f) { t10 = i; break; } }
          M("samplerate %6d chop edge 90→10 %% in %.2f ms", sr, 1000.0 * (double)(t10 - t90) / sr); }
        // vocoder: output level + envelope ripple on a steady vowel (level −12 dBFS peak)
        { Buf x = smoothVowel(sr, 150.0, 2.0, 0.25); AUHost h(sr); h.allOff(); h.p[15] = 1; h.p[17] = 1.0f; h.render(x, x, L, R);
          M("samplerate %6d vocoder wet-only gain %+.2f dB (vowel 150 Hz @ −12 dBFS peak)", sr, dB(rmsOf(L, sr / 2, 2 * (size_t)sr - 4096)) - dB(rmsOf(x, sr / 2, 2 * (size_t)sr - 4096))); }
        // pitch quality: glottal phrase through LOW −5 and hard AUTOTUNE
        { Phrase P = makePhrase(sr, 44.0); Buf x = scaled(P.x, 0.25);
          for (int k = 0; k < 2; ++k) { AUHost h(sr); h.allOff(); if (k) { h.p[23] = 1; } else { h.p[0] = 1; h.p[1] = 0; } h.render(x, x, L, R);
            double ci, co, w, sb; clarityCompare(x, L, h.latency(), sr, ci, co, w, sb); double med, p95, mx; envelopeDeviation(x, L, h.latency(), sr, med, p95, mx);
            M("samplerate %6d %-9s clarity in %.3f out %.3f frames_worse %4.1f%% env_p95 %.2f dB env_max %.2f dB", sr, k ? "low-5" : "autotune", ci, co, w, p95, mx); } }
    }
}

// ── comb: dry/wet alignment. Noise (unvoiced → every pitch voice is a pure delay) through
//    partial mixes must come out as gain × delayed input; any residual is comb filtering. ──
static void testComb() {
    const int sr = 48000; Buf x = whiteNoise(3.0, sr, 0.1);
    struct T { const char* name; std::function<void(AUHost&)> set; };
    const T tests[] = {
        {"low_mix.5",          [](AUHost& h) { h.allOff(); h.p[23] = 1; h.p[25] = 0.5f; }},
        {"low-24(hq)_mix.5",   [](AUHost& h) { h.allOff(); h.p[23] = 1; h.p[24] = -24; h.p[25] = 0.5f; }},
        {"harm+7_mix.5",       [](AUHost& h) { h.allOff(); h.p[3] = 1; h.p[5] = 0.5f; }},
        {"skip_amt.5",         [](AUHost& h) { h.allOff(); h.p[6] = 1; }},
        {"autotune+low_mix.5", [](AUHost& h) { h.allOff(); h.p[0] = 1; h.p[23] = 1; h.p[25] = 0.5f; }},
        {"autotune+harm+skip", [](AUHost& h) { h.allOff(); h.p[0] = 1; h.p[3] = 1; h.p[6] = 1; }},
    };
    for (const T& t : tests) {
        AUHost h(sr); t.set(h); Buf L, R; h.render(x, x, L, R); const int lat = h.latency();
        double xy = 0, xx = 0, yy = 0; for (size_t n = sr; n + lat < L.size(); ++n) { xy += (double)x[n] * L[n + lat]; xx += (double)x[n] * x[n]; yy += (double)L[n + lat] * L[n + lat]; }
        const double g = xy / xx; const double resid = std::max(1e-30, yy - g * g * xx);
        M("comb %-20s gain %+5.2f dB  residual (not a pure delayed copy) %6.1f dB", t.name, dB(std::fabs(g)), 10 * std::log10(resid / yy));
    }
    // voiced: lowered voice at 0 st blended 50 % with the lead must not cancel
    { Buf v = smoothVowel(sr, 150.0, 3.0, 0.25); AUHost h(sr); h.allOff(); h.p[23] = 1; h.p[24] = 0; h.p[25] = 0.5f; Buf L, R; h.render(v, v, L, R);
      M("comb voiced_low0_mix.5      gain %+5.2f dB (0 = no cancellation)", dB(rmsOf(L, sr, 2 * (size_t)sr)) - dB(rmsOf(v, sr, 2 * (size_t)sr))); }
}

// ── sibilants: do "s"/"sh" survive (level + waveform) through each pitch module? ──
static void testSibilants() {
    const int sr = 48000; Phrase P = makePhrase(sr, 44.0); Buf x = scaled(P.x, 0.25);
    struct T { const char* name; std::function<void(AUHost&)> set; };
    const T tests[] = {
        {"autotune_hard", [](AUHost& h) { h.allOff(); h.p[0] = 1; h.p[1] = 0; }},
        {"lowtuner-5",    [](AUHost& h) { h.allOff(); h.p[23] = 1; }},
        {"harmonizer+7",  [](AUHost& h) { h.allOff(); h.p[3] = 1; }},
        {"octave+ .5",    [](AUHost& h) { h.allOff(); h.p[3] = 1; h.p[4] = 12; h.p[5] = 0.5f; }},
        {"pitchskip",     [](AUHost& h) { h.allOff(); h.p[6] = 1; }},
        {"vocoder",       [](AUHost& h) { h.allOff(); h.p[15] = 1; }},
    };
    for (const T& t : tests) {
        AUHost h(sr); t.set(h); Buf L, R; h.render(x, x, L, R); const int lat = h.latency();
        double lvl = 0, corr = 0; int n = 0;
        for (auto& sg : P.sibilants) { const size_t a = sg.first + (size_t)(0.03 * sr), b = sg.second - (size_t)(0.03 * sr); double ex = 0, ey = 0, exy = 0;
            for (size_t i = a; i < b; ++i) { ex += (double)x[i] * x[i]; ey += (double)L[i + lat] * L[i + lat]; exy += (double)x[i] * L[i + lat]; }
            lvl += 10 * std::log10(ey / ex); corr += exy / std::sqrt(ex * ey); ++n; }
        // vowel level change for reference (voiced parts, whole phrase median)
        double med, p95, mx; envelopeDeviation(x, L, lat, sr, med, p95, mx);
        M("sibilants %-14s s/sh level %+5.2f dB  waveform_corr %.3f  (voiced median gain %+5.2f dB → sibilant boost %+5.2f dB)", t.name, lvl / n, corr / n, med, lvl / n - med);
    }
}

// ── onset: uninitialised / first-block behaviour and a hard voice onset ──
static void testOnset() {
    const int sr = 48000;
    Buf v = smoothVowel(sr, 180.0, 1.0, 0.9);           // hot voice from sample 0
    for (const Cfg& c : allCfgs()) {
        AUHost h(sr); c.set(h); Buf L, R; h.render(v, v, L, R, 64); const int lat = h.latency();
        const Stats pre = stats(L, 0, lat), s = stats(L);
        if (pre.peak > 1e-4 || s.nan || c.name == "off" || c.name == "all_on" || c.name == "P_FULL")
            M("onset %-12s output before the latency has elapsed: peak %.5f ; whole: nan %ld peak %+6.2f dBFS", c.name.c_str(), pre.peak, s.nan, dB(s.peak));
    }
    // reset() mid-stream (transport jump) must not click louder than the signal itself
    { AUHost h(sr); h.allOn(); Buf a(v.begin(), v.begin() + sr / 2), L, R; h.render(a, a, L, R); h.e->reset(); h.render(a, a, L, R); const Stats s = stats(L);
      M("onset reset_all_on  after reset(): peak %+6.2f dBFS nan %ld", dB(s.peak), s.nan); }
}

// ── steady: HNR of each PSOLA voice on a steady glottal vowel (no reverb / delay) ──
static void testSteady() {
    const int sr = 48000;
    for (double hz : {110.0, 220.0, 330.0}) {
        std::vector<double> f0((size_t)(3 * sr), hz * std::pow(2.0, 0.3 / 12.0)), vw(f0.size(), 0.0); VoiceOpts o; o.jitter = 0; o.shimmer = 0; o.breath = 0;
        Buf x = glottalVoice(f0, vw, sr, o); normalizePeak(x, 0.25);
        const double inHnr = bench::hnr(&x[sr], sr, refineF0(&x[sr], sr, f0[0], sr), 40, sr);
        for (int cents : {-1200, -500, -30, 30, 700, 1200}) {
            vbx::PsolaCore core; core.prepare((float)sr, 1024); core.setVoiceActive(1, true); core.setVoiceCents(1, (float)cents);
            Buf y(x.size()); for (size_t n = 0; n < x.size(); ++n) { core.push(x[n], x[n]); y[n] = core.renderMono(1); }
            const double fo = f0[0] * std::pow(2.0, cents / 1200.0); Buf w(y.begin() + sr + 1024, y.begin() + 2 * sr + 1024);
            const double fm = refineF0(w.data(), (int)w.size(), fo, sr);
            M("steady glottal %3.0f Hz shift %+5d c: HNR %5.1f dB (input %5.1f) pitch_err %+5.1f c gain %+5.2f dB", hz, cents, bench::hnr(w.data(), sr, fm, 40, sr), inHnr, 1200 * std::log2(fm / fo), dB(rmsOf(w, 0, w.size())) - dB(rmsOf(x, sr, 2 * (size_t)sr)));
        }
    }
}

// ── overload: what happens when the rack's sum exceeds 0 dBFS (hot vocal + delay / harmony / reverb) ──
static void testOverload() {
    const int sr = 48000;
    struct T { const char* name; std::function<void(AUHost&)> set; };
    const T tests[] = {
        {"delay_fb.35",      [](AUHost& h) { h.allOff(); h.p[9] = 1; }},
        {"reverb_mix.5",     [](AUHost& h) { h.allOff(); h.p[18] = 1; h.p[20] = 0.5f; }},
        {"P_DUB",            [](AUHost& h) { h.preset(5); }},
    };
    for (const T& t : tests) for (double lvl : {0.0, -6.0}) {
        // steady 220 Hz sine: after the echoes have built up the sum is far above the input peak
        Buf x = sine(220.0, 6.0, sr, std::pow(10.0, lvl / 20.0)), L, R; AUHost h(sr); t.set(h); h.render(x, x, L, R);
        const double v = bestThdn(L, 220.0, sr, (size_t)(4.0 * sr), (size_t)(5.5 * sr)); const Stats so = stats(L, 4 * (size_t)sr, (size_t)(5.5 * sr));
        M("overload %-13s sine in%+3.0fdBFS: out peak %+6.2f dBFS over0dBFS %ld  THD+N %6.1f dB (%.3f %%)", t.name, lvl, dB(so.peak), so.over, v, 100.0 * std::pow(10.0, v / 20.0));
    }
    // hot voice (peaks at 0 dBFS) through every preset: samples over 0 dBFS, flat-topped runs (≥ 3 equal samples at the peak)
    Phrase P = makePhrase(sr, 44.0);
    for (const Cfg& c : presetCfgs()) {
        Buf L, R; int lat; run(c, sr, P.x, P.x, L, R, lat);
        long flat = 0, over = 0; double pk = 0; for (int ch = 0; ch < 2; ++ch) { const Buf& y = ch ? R : L; for (float v : y) pk = std::max<double>(pk, std::fabs(v));
            for (size_t n = 2; n < y.size(); ++n) { if (std::fabs(y[n]) > 1.0f) ++over; if (std::fabs(y[n]) > 0.9 && y[n] == y[n - 1] && y[n] == y[n - 2]) ++flat; } }
        M("overload %-10s voice at 0 dBFS: peak %+6.2f dBFS samples_over_0dBFS %6ld flat_topped %6ld", c.name.c_str(), dB(pk), over, flat);
    }
}

// ── render: before/after audio of the same phrases (run with VBX_RENDER_DIR=<dir>) ──
static void testRender() {
    const char* dir = std::getenv("VBX_RENDER_DIR"); if (!dir) { M("render skipped (set VBX_RENDER_DIR)"); return; }
    const int sr = 48000;
    struct Src { std::string suffix; Buf L, R; };
    std::vector<Src> srcs;
    { Buf L, R; int s2 = 0; if (loadWav(gDir + "/material/realvox_H_131s_KJ_v001.wav", L, R, s2) && s2 == sr) {
        srcs.push_back({"", L, R});                                           // main set: real vocal, level as in the session
        float pk = 0; for (size_t i = 0; i < L.size(); ++i) pk = std::max(pk, std::max(std::fabs(L[i]), std::fabs(R[i])));
        srcs.push_back({"_hot", scaled(L, 0.891 / pk), scaled(R, 0.891 / pk)}); } }   // same take, peaks at −1 dBFS
    { Buf L, R; int s2 = 0; if (loadWav(gDir + "/material/realvox_H_33s_KJ_v001.wav", L, R, s2) && s2 == sr) srcs.push_back({"_phraseB", L, R}); }
    { Phrase P = makePhrase(sr, 47.0); Buf x = scaled(P.x, 0.5); srcs.push_back({"_synthphrase", x, x}); }
    struct C { const char* name; std::function<void(AUHost&)> set; };
    const C cfgs[] = { {"alloff", [](AUHost& h) { h.allOff(); }}, {"TUNED", [](AUHost& h) { h.preset(1); }}, {"ROBOT", [](AUHost& h) { h.preset(3); }},
                       {"OCTAVEplus", [](AUHost& h) { h.preset(2); }}, {"FULL", [](AUHost& h) { h.preset(9); }} };
    for (const Src& sc : srcs) {
        if (gTag == "after") writeWavF(std::string(dir) + "/voicebox_input" + sc.suffix + "_KJ_v001.wav", sc.L, sc.R, sr);
        for (const C& c : cfgs) {
            AUHost h(sr); c.set(h); const int lat = h.latency();
            Buf inL(sc.L), inR(sc.R); inL.resize(inL.size() + lat + sr, 0.0f); inR.resize(inR.size() + lat + sr, 0.0f);   // room for the latency + 1 s of tail
            Buf L, R; h.render(inL, inR, L, R, 512);
            Buf oL(L.begin() + lat, L.end()), oR(R.begin() + lat, R.end());     // latency removed: files line up with the input
            const Stats sl = stats(oL), sr2 = stats(oR);
            const std::string path = std::string(dir) + "/voicebox_" + c.name + sc.suffix + "_" + gTag + "_KJ_v001.wav";
            writeWavF(path, oL, oR, sr);
            M("render %-11s%-13s peak L %+6.2f R %+6.2f dBFS  samples_over_0dBFS %ld  rms %+6.2f dBFS", c.name, sc.suffix.c_str(), dB(sl.peak), dB(sr2.peak), sl.over + sr2.over, dB(sl.rms));
        }
    }
}

int main(int argc, char** argv) {
    gTag = argc > 1 ? argv[1] : "after"; gDir = argc > 2 ? argv[2] : ".";
    std::vector<std::string> want; for (int i = 3; i < argc; ++i) want.push_back(argv[i]);
    const bool all = want.empty() || want[0] == "all";
    auto on = [&](const char* n) { return all || std::find(want.begin(), want.end(), n) != want.end(); };
    std::printf("== VoiceBox sound-quality harness [%s] ==\n", gTag.c_str());
    if (on("levels"))  testLevels();
    if (on("thd"))     testThd();
    if (on("tracker")) testTracker();
    if (on("synth"))   testSynthVoice();
    if (on("real"))    testReal();
    if (on("steady"))  testSteady();
    if (on("toggle"))  testToggle();
    if (on("zipper"))  testZipper();
    if (on("blocks"))  testBlocks();
    if (on("samplerate")) testSampleRate();
    if (on("comb"))    testComb();
    if (on("sibilants")) testSibilants();
    if (on("onset"))   testOnset();
    if (on("overload")) testOverload();
    if (!all && on("render")) testRender();
    return 0;
}
