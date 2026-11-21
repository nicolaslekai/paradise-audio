// VoiceBox old-vs-new bench. Build both variants with Tests/run_bench.sh.
//   -DVBX_OLD  → Tests/baseline (DSP frozen 2026-11-20, before the quality work)
//   (default)  → VoiceBoxExtension/DSP (new)
// Usage: bench <tag old|new> <outdir> [quick]
#include "bench_common.hpp"
#include "VoiceBoxEngine.hpp"
#include <chrono>
using namespace bench;

#include <cstdlib>
static const int SR = std::getenv("VBX_SR") ? std::atoi(std::getenv("VBX_SR")) : 48000;

struct Rack {
    vbx::VoiceBoxEngine e;
    Rack() { e.prepare((float)SR); off(); }
    void off() {
        e.setAutotune(false, 0.3f, 1.0f, 0); e.setHarmonizer(false, 7, 0.4f, false); e.setLow(false, -5, 1);
        e.setSkip(false, 4, 0.5f); e.setDelay(false, 250, 0.35f); e.setChop(false, 8, 0.8f);
        e.setVocoder(false, 0.5f, 0.7f); e.setReverb(false, 0.5f, 0.3f);
    }
    int latency() const {
#ifdef VBX_OLD
        return vbx::VoiceBoxEngine::kLatency;
#else
        return e.latencySamples();
#endif
    }
    void autotune(bool on, float speed, float amt, int scale, int key = 0, float human = 0) {
#ifdef VBX_OLD
        (void)key; (void)human; e.setAutotune(on, speed, amt, (float)scale);
#else
        e.setAutotune(on, speed, amt, (float)scale, (float)key, human);
#endif
    }
    void run(const std::vector<float>& inL, const std::vector<float>& inR, std::vector<float>& L, std::vector<float>& R) {
        L = inL; R = inR; for (size_t i = 0; i < L.size(); ++i) e.processFrame(L[i], R[i]);
    }
    void runMono(const std::vector<float>& in, std::vector<float>& L, std::vector<float>& R) { run(in, in, L, R); }
};

static std::vector<double> glideF0(double a, double b, double sec, double vibC, double vibHz = 5.5) {
    std::vector<double> f; const int N = (int)(sec * SR);
    for (int n = 0; n < N; ++n) { const double t = (double)n / SR; const double m = 69 + 12 * std::log2(a / 440) + (12 * std::log2(b / a)) * (t / sec) + vibC / 100 * std::sin(2 * PI * vibHz * t); f.push_back(midiToHz(m)); }
    return f;
}

int main(int argc, char** argv) {
    const std::string tag = argc > 1 ? argv[1] : "new";
    const std::string out = argc > 2 ? argv[2] : ".";
    const bool quick = argc > 3 && std::string(argv[3]) == "quick";
    std::printf("== VoiceBox bench [%s] ==\n", tag.c_str());
    { Rack r; std::printf("METRIC latency_samples %d\n", r.latency()); }

    // ── T1: long-run quality of a shifted harmonic tone (phase drift) ──
    {
        const double secs = quick ? 32 : 182;   // +1 s so the last window (offset by the latency) stays inside
        std::vector<float> x = harmonicTone(200.0, secs, SR), L, R;
        for (int cfg = 0; cfg < 2; ++cfg) {
            Rack r; double fout;
            if (cfg == 0) { r.e.setLow(true, -5, 1.0f); fout = 200.0 * std::pow(2.0, -5 / 12.0); }
            else { r.autotune(true, 0.0f, 1.0f, 0); fout = midiToHz(56); }     // 200 Hz → G#3 (+35 c)
            r.runMono(x, L, R);
            const int lat = r.latency();
            for (int t : {2, 30, 180}) {
                if (t + 1 > secs) continue;
                const size_t a = (size_t)t * SR + lat;
                // Use the MEASURED output fundamental (the old autotune lands on G3, not G#3).
                std::vector<float> w(L.begin() + a, L.begin() + a + SR);
                std::vector<double> tr = yinTrack(w, SR, 4800, fout / 1.3, fout * 1.3); std::sort(tr.begin(), tr.end());
                const double fm = tr.empty() || tr[tr.size() / 2] <= 0 ? fout : tr[tr.size() / 2];
                std::printf("METRIC T1_%s_hnr_t%03ds %.1f (f %.1f Hz)\n", cfg ? "autotune" : "low-5", t, hnr(&L[a], SR, fm, 120, SR), fm);
            }
        }
    }

    // ── T3: hard tune, vibrato vowel sitting near the A3/A#3 boundary ──
    {
        std::vector<double> f0; const int N = 4 * SR;
        for (int n = 0; n < N; ++n) { const double t = (double)n / SR; f0.push_back(220.0 * std::pow(2.0, (30 + 30 * std::sin(2 * PI * 5.5 * t)) / 1200)); }
        std::vector<float> x = vowel(f0, SR), L, R;
        Rack r; r.autotune(true, 0.0f, 1.0f, 0); r.runMono(x, L, R);
        std::vector<double> tr = yinTrack(L, SR, 240, 220 / 1.5, 220 * 1.5);   // ±7 st window: robust to harmonic locking
        std::vector<double> c; for (size_t i = (size_t)(0.6 * SR / 240); i < tr.size(); ++i) if (tr[i] > 0) c.push_back(1200 * std::log2(tr[i] / 220.0));
        const double mean = std::accumulate(c.begin(), c.end(), 0.0) / c.size();
        double sd = 0; for (double v : c) sd += (v - mean) * (v - mean); sd = std::sqrt(sd / c.size());
        int flips = 0; for (size_t i = 1; i < c.size(); ++i) if ((c[i] > 50) != (c[i - 1] > 50)) ++flips;
        std::printf("METRIC T3_wobble_mean_cents %.1f\nMETRIC T3_wobble_sd_cents %.1f\nMETRIC T3_wobble_range_cents %.1f..%.1f\nMETRIC T3_note_flips %d\n",
                    mean, sd, *std::min_element(c.begin(), c.end()), *std::max_element(c.begin(), c.end()), flips);
        writeWav(out + "/t3_wobble_" + tag + ".wav", L, R, SR);
    }

    // ── Formants + pitch accuracy at ±5 st (shifter level, steady 150 Hz vowel) ──
    {
        std::vector<double> f0(3 * SR, 150.0);
        std::vector<float> x = vowel(f0, SR);
        const std::vector<double> envIn = envelope(x, SR, (size_t)(0.5 * SR), (size_t)(2.5 * SR));
        for (int semis : {-5, +5}) {
            const double ratio = std::pow(2.0, semis / 12.0);
            std::vector<float> y(x.size(), 0.0f);
#ifdef VBX_OLD
            vbx::PitchShifterHQ ps; ps.prepare((float)SR); ps.setFormantPreserve(true);
            for (size_t n = 0; n < x.size(); ++n) y[n] = ps.process(x[n], (float)ratio);
            const int lat = vbx::PitchShifterHQ::kLat;
#else
            vbx::PsolaCore core; core.prepare((float)SR, 768);
            core.setVoiceActive(1, true); core.setVoiceCents(1, semis * 100.0f);
            for (size_t n = 0; n < x.size(); ++n) { core.push(x[n], x[n]); y[n] = core.renderMono(1); }
            const int lat = core.latency();
#endif
            std::vector<float> ya(y.begin() + lat, y.end());
            const std::vector<double> envOut = envelope(ya, SR, (size_t)(0.5 * SR), (size_t)(2.4 * SR));
            std::vector<double> tr = yinTrack(ya, SR, 480); std::vector<double> c;
            for (size_t i = (size_t)(0.5 * SR / 480); i < tr.size() && i < (size_t)(2.4 * SR / 480); ++i) if (tr[i] > 0) c.push_back(1200 * std::log2(tr[i] / (150.0 * ratio)));
            std::sort(c.begin(), c.end()); const double med = c.empty() ? 999 : c[c.size() / 2];
            // Reference: plain resampling (formants move with the pitch) — what "no preservation" scores.
            std::vector<float> rs((size_t)(x.size() / ratio)); for (size_t n = 0; n < rs.size(); ++n) { const double p = n * ratio; const size_t i = (size_t)p; const double fr = p - i; rs[n] = (float)(i + 1 < x.size() ? x[i] * (1 - fr) + x[i + 1] * fr : 0); }
            const std::vector<double> envRs = envelope(rs, SR, (size_t)(0.3 * SR), (size_t)(1.6 * SR));
            std::printf("METRIC F_%+d_env_corr %.3f\nMETRIC F_%+d_resample_ref_corr %.3f\nMETRIC F_%+d_pitch_err_cents %.1f\nMETRIC F_%+d_hnr %.1f\n",
                        semis, envCorr(envIn, envOut, SR), semis, envCorr(envIn, envRs, SR), semis, med, semis, hnr(&ya[SR], SR, 150.0 * ratio, 25, SR));
        }
    }

    // ── T7: latency alignment of every path (aperiodic voiced signal, ratio ≈ 1) ──
    {
        std::vector<float> x = vowel(glideF0(200, 262, 3.0, 25), SR), L, R;
        struct Cfg { const char* name; int mode; };
        const Cfg cfgs[] = { {"dry", 0}, {"autotune_amt0", 1}, {"at+low0", 2}, {"at+harm0", 3}, {"low0", 4}, {"harm0", 5} };
        for (const Cfg& c : cfgs) {
            Rack r;
            if (c.mode == 1 || c.mode == 2 || c.mode == 3) r.autotune(true, 0.3f, 0.0f, 0);
            if (c.mode == 2 || c.mode == 4) r.e.setLow(true, 0, 1.0f);
            if (c.mode == 3 || c.mode == 5) r.e.setHarmonizer(true, 0, 1.0f, false);
            r.runMono(x, L, R);
            double second = 0; const int lag = xcorrLag(x, L, 3200, (size_t)(0.4 * SR), (size_t)(2.4 * SR), &second);
            std::printf("METRIC T7_%s_lag %d (reported %d, err %+d, 2nd-peak %.2f)\n", c.name, lag, r.latency(), lag - r.latency(), second);
        }
        // Click train (unvoiced): exact sample alignment.
        std::vector<float> ck(2 * SR, 0.0f); for (int n = 1000; n < 2 * SR; n += 4801) ck[n] = 0.8f;
        for (int mode = 0; mode < 2; ++mode) {
            Rack r; if (mode) r.autotune(true, 0.3f, 1.0f, 0);
            r.runMono(ck, L, R);
            int lag = xcorrLag(ck, L, 3200, 0, (size_t)(1.5 * SR));
            std::printf("METRIC T7_clicks_%s_lag %d (reported %d)\n", mode ? "autotune" : "dry", lag, r.latency());
        }
    }

    // ── T6: consonants pass through autotune untouched ("sss" between two vowels) ──
    {
        std::vector<double> f0a((size_t)(0.5 * SR), 220.0 * std::pow(2.0, 40 / 1200.0));
        std::vector<float> v1 = vowel(f0a, SR), ss = hiss((size_t)(0.3 * SR), 0.12, 3), x;
        x.insert(x.end(), v1.begin(), v1.end()); const size_t s0 = x.size();
        x.insert(x.end(), ss.begin(), ss.end()); const size_t s1 = x.size();
        x.insert(x.end(), v1.begin(), v1.end()); x.resize(x.size() + SR / 4, 0.0f);
        std::vector<float> L, R; Rack r; r.autotune(true, 0.0f, 1.0f, 0); r.runMono(x, L, R);
        const int lat = r.latency(); const size_t a = s0 + (size_t)(0.05 * SR), b = s1 - (size_t)(0.05 * SR);
        double ex = 0, ey = 0, exy = 0; for (size_t n = a; n < b; ++n) { const double u = x[n], v = L[n + lat]; ex += u * u; ey += v * v; exy += u * v; }
        std::printf("METRIC T6_sss_level_change_db %+.2f\nMETRIC T6_sss_waveform_corr %.3f\n", 10 * std::log10(ey / ex), exy / std::sqrt(ex * ey));
    }

    // ── T8: engage/disengage clicks (toggle every 0.5 s on a sung vowel) ──
    {
        std::vector<double> f0(6 * SR); for (size_t n = 0; n < f0.size(); ++n) f0[n] = 220.0 * std::pow(2.0, (30 + 15 * std::sin(2 * PI * 5.0 * n / SR)) / 1200);
        std::vector<float> x = vowel(f0, SR);
        for (int which = 0; which < 3; ++which) {
            Rack r; std::vector<float> L(x.size()), R(x.size());
            const int half = SR / 2; const int lat = r.latency();
            for (size_t n = 0; n < x.size(); ++n) {
                if (n % half == 0) {
                    const bool on = (n / half) % 2 == 1;
                    if (which == 0) r.autotune(on, 0.2f, 1.0f, 0);
                    if (which == 1) r.e.setLow(on, -5, 1.0f);
                    if (which == 2) r.e.setHarmonizer(on, 7, 0.6f, false);
                }
                float l = x[n], rr = x[n]; r.e.processFrame(l, rr); L[n] = l; R[n] = rr;
            }
            float steady = 0, tog = 0;
            for (size_t k = 1; k < x.size() / half; ++k) {
                const size_t t = k * half;
                tog = std::max(tog, maxJump(L, t, t + lat + (size_t)(0.03 * SR)));
                steady = std::max(steady, maxJump(L, t + lat + (size_t)(0.08 * SR), t + half - (size_t)(0.02 * SR)));
            }
            static const char* nm[3] = {"autotune", "low-5", "harm+7"};
            std::printf("METRIC T8_%s_toggle_jump_ratio %.2f (toggle %.4f, steady %.4f)\n", nm[which], tog / steady, tog, steady);
        }
    }

    // ── CPU: all pitch effects on, 20 s of the sung phrase ──
    {
        std::vector<float> p = phrase(SR), x; while (x.size() < (size_t)(20 * SR)) x.insert(x.end(), p.begin(), p.end()); x.resize(20 * SR);
        std::vector<float> L, R;
        Rack r; r.autotune(true, 0.3f, 1.0f, 1); r.e.setHarmonizer(true, 7, 0.4f, true); r.e.setLow(true, -12, 0.5f); r.e.setSkip(true, 4, 0.5f);
        const auto t0 = std::chrono::steady_clock::now(); r.runMono(x, L, R);
        const double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        Rack r2; r2.autotune(true, 0.3f, 1.0f, 1);
        const auto t1 = std::chrono::steady_clock::now(); r2.runMono(x, L, R);
        const double s2 = std::chrono::duration<double>(std::chrono::steady_clock::now() - t1).count();
        std::printf("METRIC CPU_all_pitch_fx_pct_of_core %.2f\nMETRIC CPU_autotune_only_pct_of_core %.2f\n", 100 * s / 20.0, 100 * s2 / 20.0);
    }

    // ── Demos: the sung phrase through each effect ──
    {
        std::vector<double> truth; std::vector<float> x = phrase(SR, &truth), L, R;
        struct Demo { const char* name; int mode; };
        const Demo demos[] = { {"input", 0}, {"autotune_fast", 1}, {"autotune_slow", 2}, {"harmonizer", 3}, {"lowtuner", 4} };
        for (const Demo& d : demos) {
            Rack r;
            if (d.mode == 1) r.autotune(true, 0.0f, 1.0f, 1, 0);
            if (d.mode == 2) r.autotune(true, 0.7f, 1.0f, 1, 0);
            if (d.mode == 3) r.e.setHarmonizer(true, 7, 0.5f, true);
            if (d.mode == 4) r.e.setLow(true, -12, 1.0f);
            r.runMono(x, L, R);
            if (d.mode == 0) { L = x; R = x; }
            writeWav(out + "/demo_" + d.name + "_" + tag + ".wav", L, R, SR);
            if (d.mode == 1 || d.mode == 2) {   // pitch error vs the nearest C-major note
                std::vector<double> tr = yinTrack(L, SR, 240, 150, 420); std::vector<double> err;
                static const int maj[7] = {0, 2, 4, 5, 7, 9, 11};
                for (size_t i = 0; i < tr.size(); ++i) if (tr[i] > 0) {
                    const double m = 69 + 12 * std::log2(tr[i] / 440); double best = 99;
                    for (int o = -1; o <= 1; ++o) for (int dd : maj) { const double cand = (std::floor(m / 12) + o) * 12 + dd; best = std::min(best, std::fabs(m - cand)); }
                    err.push_back(best * 100);
                }
                std::sort(err.begin(), err.end());
                std::printf("METRIC demo_%s_median_err_cents %.1f\nMETRIC demo_%s_p90_err_cents %.1f\n", d.name, err[err.size() / 2], d.name, err[(size_t)(err.size() * 0.9)]);
            }
        }
    }
    return 0;
}
