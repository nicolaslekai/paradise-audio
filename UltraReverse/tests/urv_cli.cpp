// Ultra Reverse offline test CLI (REVERSE_PLAN.md §6).
//   urv_cli <in.f32> <out.f32> [key=value ...]
// in/out: interleaved stereo float32 @ sr (default 48000). Keys: mode sync division reverse
// size decay shimmer diffusion texture predelay tone mix smooth cut feedback fbtone
// lookahead length gap bpm block playing sweep(=1: random knob sweeps + concurrent IR renders)
#include "ReverseProcessor.hpp"
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <random>
#include <map>

using namespace urv;

int main(int argc, char** argv) {
    if (argc < 3) { std::fprintf(stderr, "usage: urv_cli in.f32 out.f32 [k=v...]\n"); return 1; }
    std::map<std::string, double> kv;
    for (int i = 3; i < argc; ++i) { std::string a = argv[i]; auto e = a.find('='); if (e != std::string::npos) kv[a.substr(0, e)] = atof(a.c_str() + e + 1); }
    auto get = [&](const char* k, double d) { auto it = kv.find(k); return it == kv.end() ? d : it->second; };
    const float sr = (float)get("sr", 48000); const int block = (int)get("block", 512);
    FILE* f = std::fopen(argv[1], "rb"); if (!f) return 2;
    std::fseek(f, 0, SEEK_END); long bytes = std::ftell(f); std::fseek(f, 0, SEEK_SET);
    std::vector<float> in(bytes / 4); std::fread(in.data(), 4, in.size(), f); std::fclose(f);
    const int frames = (int)in.size() / 2;

    Params p;
    p.mode = (int)get("mode", 1); p.sync = (int)get("sync", 1); p.division = (int)get("division", 3);
    p.reverse = get("reverse", 0.6); p.size = get("size", 0.7); p.decay = get("decay", 4.0);
    p.shimmer = get("shimmer", 0.3); p.diffusion = get("diffusion", 0.6); p.texture = get("texture", 0.7);
    p.predelay = get("predelay", 20); p.tone = get("tone", 0.5); p.mix = get("mix", 0.4);
    p.smoothMs = get("smooth", 15); p.cutMs = get("cut", 3); p.feedback = get("feedback", 0.3);
    p.fbToneHz = get("fbtone", 6000); p.lookahead = (int)get("lookahead", 2);
    p.lengthSec = get("length", 0.8); p.gapMs = get("gap", 0);
    const double bpm = get("bpm", 120); const bool playing = get("playing", 1) != 0;
    const bool sweep = get("sweep", 0) != 0;

    ReverseProcessor proc; proc.prepare(sr, block);
    auto irp = [&](const Params& q) { IRParams ir; ir.size = q.size; ir.decay = q.decay; ir.diffusion = q.diffusion; ir.tone = q.tone;
        ir.lengthSec = q.lengthSec; ir.gapMs = q.gapMs; ir.latencySamples = (int)std::lround(lookaheadSeconds(q.lookahead) * sr); return ir; };
    proc.renderIRNow(irp(p));
    proc.setLatencySamples((int)std::lround(lookaheadSeconds(p.lookahead) * sr));
    std::printf("latency_samples=%d\n", proc.latencySamples());

    std::atomic<bool> stop{false}; std::atomic<int> renders{0}, busy{0};
    std::thread irThread;
    std::mt19937 rng(7);
    Params live = p;
    std::atomic<float> irSize{p.size}, irDecay{p.decay};
    if (sweep) irThread = std::thread([&] {        // concurrent kernel re-renders, like the AU's background queue
        while (!stop.load()) {
            Params q = p; q.size = irSize.load(); q.decay = irDecay.load();
            if (proc.renderIR(irp(q))) ++renders; else ++busy;
            std::this_thread::sleep_for(std::chrono::milliseconds(15));
        }
    });

    std::vector<float> L(block), R(block), oL(block), oR(block), out(in.size());
    long long done = 0; int blk = 0;
    while (done < frames) {
        const int n = (int)std::min<long long>(block, frames - done);
        for (int i = 0; i < n; ++i) { L[i] = in[2 * (done + i)]; R[i] = in[2 * (done + i) + 1]; }
        if (sweep) {
            std::uniform_real_distribution<float> u(0.f, 1.f);
            if (blk % 5 == 0) {
                live.division = (int)(u(rng) * 8) % 8; live.reverse = 0.1f + u(rng) * 3.9f;
                live.smoothMs = 1 + u(rng) * 79; live.cutMs = 0.5f + u(rng) * 19.5f;
                live.feedback = u(rng) * 0.95f; live.fbToneHz = 500 + u(rng) * 15500;
                live.size = u(rng); live.decay = 0.3f + u(rng) * 12; live.mix = u(rng);
                live.tone = u(rng); live.diffusion = u(rng); live.texture = u(rng); live.shimmer = u(rng);
                live.sync = u(rng) > 0.3f; irSize.store(live.size); irDecay.store(live.decay);
            }
            if (blk % 47 == 0) live.mode = (live.mode + 1) % 4;   // every ~0.5 s
        }
        HostTime ht; ht.hasTempo = true; ht.tempo = bpm; ht.hasBeat = playing; ht.playing = playing;
        ht.beatPos = (double)done / sr * bpm / 60.0;
        proc.process(sweep ? live : p, ht, L.data(), R.data(), oL.data(), oR.data(), n);
        for (int i = 0; i < n; ++i) { out[2 * (done + i)] = oL[i]; out[2 * (done + i) + 1] = oR[i]; }
        done += n; ++blk;
        if (get("pace", 0) > 0) std::this_thread::sleep_for(std::chrono::microseconds((long long)(1e6 * n / sr * get("pace", 0))));
    }
    if (sweep) { stop.store(true); irThread.join(); std::printf("ir_renders=%d ir_busy_retries=%d\n", renders.load(), busy.load()); }
    FILE* g = std::fopen(argv[2], "wb"); std::fwrite(out.data(), 4, out.size(), g); std::fclose(g);
    return 0;
}
