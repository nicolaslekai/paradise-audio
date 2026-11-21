// End-to-end check of the REAL AU class (VoiceBoxAudioUnit.mm + DSP) without Xcode:
// instantiate the AUAudioUnit subclass directly, drive its render block like a host
// (512-frame pulls, stereo and mono busses, 48 k and 96 k) and compare with the
// harness's AU-equivalent host (sq_common.hpp AUHost). Built by run_e2e.sh.
#import "VoiceBoxAudioUnit.h"
#include "sq_common.hpp"
using namespace sq;

static bool renderAU(int sr, int channels, int preset, const Buf& inL, const Buf& inR, Buf& outL, Buf& outR, int block, double* latencySec) {
    AudioComponentDescription d = {}; d.componentType = kAudioUnitType_Effect; d.componentSubType = 'Vbx1'; d.componentManufacturer = 'Para';
    NSError* err = nil;
    VoiceBoxAudioUnit* au = [[VoiceBoxAudioUnit alloc] initWithComponentDescription:d options:0 error:&err];
    if (!au) { std::printf("init failed: %s\n", err.localizedDescription.UTF8String); return false; }
    AVAudioFormat* fmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sr channels:(AVAudioChannelCount)channels];
    if (![au.inputBusses[0] setFormat:fmt error:&err] || ![au.outputBusses[0] setFormat:fmt error:&err]) { std::printf("setFormat failed: %s\n", err.localizedDescription.UTF8String); return false; }
    au.maximumFramesToRender = 4096;
    if (preset >= 0) [au applyPreset:preset];
    else for (NSNumber* a in @[@0, @3, @6, @9, @12, @15, @18, @23]) [[au.parameterTree parameterWithAddress:a.unsignedLongLongValue] setValue:0 originator:nil];
    if (![au allocateRenderResourcesAndReturnError:&err]) { std::printf("allocate failed: %s\n", err.localizedDescription.UTF8String); return false; }
    if (latencySec) *latencySec = au.latency;
    AURenderBlock render = au.renderBlock;
    const size_t N = inL.size(); outL.assign(N, 0); outR.assign(N, 0);
    __block size_t pos = 0; const Buf* pL = &inL; const Buf* pR = &inR;
    AURenderPullInputBlock pull = ^AUAudioUnitStatus(AudioUnitRenderActionFlags* flags, const AudioTimeStamp* ts, AUAudioFrameCount frames, NSInteger bus, AudioBufferList* io) {
        for (UInt32 b = 0; b < io->mNumberBuffers; ++b) { float* dst = (float*)io->mBuffers[b].mData; const Buf& src = (b == 0) ? *pL : *pR; for (AUAudioFrameCount i = 0; i < frames; ++i) dst[i] = pos + i < src.size() ? src[pos + i] : 0.0f; }
        return noErr;
    };
    std::vector<float> bufL(4096), bufR(4096);
    AudioBufferList* abl = (AudioBufferList*)std::calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer));
    AudioTimeStamp ts = {}; ts.mFlags = kAudioTimeStampSampleTimeValid;
    for (pos = 0; pos < N; pos += (size_t)block) {
        const AUAudioFrameCount n = (AUAudioFrameCount)std::min<size_t>(block, N - pos);
        abl->mNumberBuffers = (UInt32)channels;
        abl->mBuffers[0].mNumberChannels = 1; abl->mBuffers[0].mDataByteSize = n * sizeof(float); abl->mBuffers[0].mData = bufL.data();
        if (channels > 1) { abl->mBuffers[1].mNumberChannels = 1; abl->mBuffers[1].mDataByteSize = n * sizeof(float); abl->mBuffers[1].mData = bufR.data(); }
        AudioUnitRenderActionFlags flags = 0; ts.mSampleTime = (Float64)pos;
        const AUAudioUnitStatus st = render(&flags, &ts, n, 0, abl, pull);
        if (st != noErr) { std::printf("render error %d at %zu\n", (int)st, pos); std::free(abl); return false; }
        const float* oL = (const float*)abl->mBuffers[0].mData; const float* oR = channels > 1 ? (const float*)abl->mBuffers[1].mData : oL;
        for (AUAudioFrameCount i = 0; i < n; ++i) { outL[pos + i] = oL[i]; outR[pos + i] = oR[i]; }
    }
    std::free(abl); [au deallocateRenderResources];
    return true;
}

int main() {
    @autoreleasepool {
        int fails = 0;
        for (int sr : {44100, 48000, 96000}) {
            Phrase P = makePhrase(sr, 44.0); Buf x = scaled(P.x, 0.5);
            for (int preset : {-1, 1, 3, 9}) for (int ch : {2, 1}) {
                Buf aL, aR, hL, hR; double lat = 0;
                if (!renderAU(sr, ch, preset, x, x, aL, aR, 512, &lat)) { ++fails; continue; }
                AUHost h(sr); if (preset >= 0) h.preset(preset); else h.allOff(); h.render(x, x, hL, hR, 512, ch == 1);
                double md = 0; for (size_t i = 0; i < aL.size(); ++i) md = std::max<double>(md, std::max(std::fabs(aL[i] - hL[i]), std::fabs(aR[i] - hR[i])));
                const Stats s = stats(aL);
                const bool ok = md < 1e-6 && s.nan == 0 && s.over == 0 && std::lround(lat * sr) == h.latency();
                if (!ok) ++fails;
                std::printf("E2E sr %6d %-7s %s: AU latency %ld smp (engine %d)  peak %+6.2f dBFS  nan %ld over %ld  max|AU − harness| %.1e  %s\n", sr,
                            preset < 0 ? "all-off" : kPresetNames[preset], ch == 2 ? "stereo" : "mono  ", std::lround(lat * sr), h.latency(), dB(s.peak), s.nan, s.over, md, ok ? "OK" : "FAIL");
            }
        }
        std::printf("E2E %s\n", fails ? "FAILED" : "all OK");
        return fails ? 1 : 0;
    }
}
