// BLOOM regression reference (REVERSE_PLAN T11): the PRE-2026-11-20 engine,
// driven exactly like the old AU render block (all setters every block).
//   bloom_old <in.f32> <out.f32>      (stereo interleaved float32 @ 48 kHz, defaults)
#include "UltraReverse_old.hpp"
#include <cstdio>
#include <vector>
int main(int argc, char** argv) {
    FILE* f = std::fopen(argv[1], "rb"); std::fseek(f, 0, SEEK_END); long b = std::ftell(f); std::fseek(f, 0, SEEK_SET);
    std::vector<float> x(b / 4); std::fread(x.data(), 4, x.size(), f); std::fclose(f);
    urv::UltraReverseEngine e; e.prepare(48000);
    const int frames = (int)x.size() / 2, block = 512;
    for (int s = 0; s < frames; s += block) {
        e.setReverse(0.6f); e.setSize(0.7f); e.setDecaySec(4.0f); e.setShimmer(0.3f); e.setDiffusion(0.6f);
        e.setTexture(0.7f); e.setPredelayMs(20.0f); e.setTone(0.5f); e.setMix(0.4f);
        for (int i = s; i < std::min(frames, s + block); ++i) e.processFrame(x[2 * i], x[2 * i + 1]);
    }
    FILE* g = std::fopen(argv[2], "wb"); std::fwrite(x.data(), 4, x.size(), g); std::fclose(g);
    return 0;
}
