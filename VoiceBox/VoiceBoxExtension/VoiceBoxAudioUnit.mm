//
//  VoiceBoxAudioUnit.mm
//
#import "VoiceBoxAudioUnit.h"
#import "DSP/VoiceBoxEngine.hpp"
#import <Accelerate/Accelerate.h>
#include <memory>
#include <vector>
#include <cstring>
#include <atomic>
#include <cmath>
#include <fenv.h>
#if defined(__x86_64__) || defined(__i386__)
#include <xmmintrin.h>
#endif

static constexpr int kNumParams = 28;   // 26/27 appended 2026-11-20 — never renumber 0–25

// FFT ring-buffer constants — identical to the EQ/Limiter spectrum probe.
static constexpr int kRingSize = 2048;
static constexpr int kRingMask = kRingSize - 1;
static constexpr int kFFTSize  = 1024;
static constexpr int kFFTLog2  = 10;
static constexpr int kFFTBins  = kFFTSize / 2;

namespace {
struct Spec { const char* id; const char* name; float mn, mx, df; };
const Spec kSpecs[kNumParams] = {
    {"atOn", "Tune On",     0,    1,    0},     // 0  AUTOTUNE engage
    {"atSpeed","Retune Spd",0,    1,    0.30f}, // 1  retune time 400^v − 1 ms: 0 hard, .3 → 5 ms, .7 → 65 ms, 1 → 399 ms
    {"atAmt","Tune Amount", 0,    1,    1.00f}, // 2  correction strength / wet
    {"hmOn", "Harm On",     0,    1,    0},     // 3
    {"hmSemi","Harm Semis", -24,  24,   7},     // 4
    {"hmMix","Harm Mix",    0,    1,    0.40f}, // 5
    {"skOn", "Skip On",     0,    1,    0},     // 6
    {"skRate","Skip Rate",  0.5f, 16,   4},     // 7
    {"skAmt","Skip Amt",    0,    1,    0.50f}, // 8
    {"dlOn", "Delay On",    0,    1,    0},     // 9
    {"dlTime","Delay Time", 1,    1000, 250},   // 10
    {"dlFb", "Delay FB",    0,    0.95f,0.35f}, // 11
    {"chOn", "Chop On",     0,    1,    0},     // 12
    {"chRate","Chop Rate",  0.1f, 24,   8},     // 13
    {"chDepth","Chop Depth",0,    1,    0.80f}, // 14
    {"vcOn", "Vocoder On",  0,    1,    0},     // 15
    {"vcTone","Voc Tone",   0,    1,    0.50f}, // 16
    {"vcMix","Voc Mix",     0,    1,    0.70f}, // 17
    {"rvOn", "Reverb On",   0,    1,    0},     // 18
    {"rvSize","Verb Size",  0,    1,    0.50f}, // 19
    {"rvMix","Verb Mix",    0,    1,    0.30f}, // 20
    {"hmAuto","Harm Auto",  0,    1,    0},     // 21 — intelligent in-key harmony
    {"atScale","Tune Scale",0,    2,    0},     // 22 — 0 chromatic,1 major,2 minor
    {"lwOn",  "Low On",     0,    1,    0},     // 23  LOW TUNER engage
    {"lwSemi","Low Semis",  -24,  0,    -5},    // 24  shift down, formant-preserving
    {"lwMix", "Low Mix",    0,    1,    1.00f}, // 25  dry/shifted blend
    {"atKey", "Tune Key",   0,    11,   0},     // 26  key root 0 = C … 11 = B (scale MAJ/MIN is relative to it)
    {"atHuman","Humanize",  0,    1,    0},     // 27  long notes breathe: τ·(1 + 4·humanize·sustain)
};
const char* kPresetNames[10] = {
    "CLEAN", "TUNED", "OCTAVE+", "ROBOT", "SLAP",
    "DUB", "GLITCH", "STUTTER", "GHOST", "FULL"
};
const float kPresets[10][kNumParams] = {
    // atOn,spd,amt, hmOn,semi,mix, skOn,rate,amt, dlOn,time,fb, chOn,rate,dep, vcOn,vcTone,vcMix, rvOn,rvSize,rvMix, hmAuto, atScale, lwOn,lwSemi,lwMix, atKey,atHuman
    {0,0.30f,1.0f, 0, 7,0.40f, 0,4,0.5f, 0,250,0.35f, 0, 8,0.8f, 0,0.5f,0.7f, 1,0.40f,0.22f, 0, 0, 0, -5, 1}, // CLEAN
    {1,0.10f,1.0f, 0, 7,0.40f, 0,4,0.5f, 0,250,0.35f, 0, 8,0.8f, 0,0.5f,0.7f, 1,0.45f,0.25f, 0, 1, 0, -5, 1}, // TUNED (hard autotune, major)
    {1,0.45f,1.0f, 1,12,0.50f, 0,4,0.5f, 0,250,0.35f, 0, 8,0.8f, 0,0.5f,0.7f, 1,0.50f,0.28f, 0, 0, 0, -5, 1}, // OCTAVE+
    {1,0.00f,1.0f, 0, 7,0.40f, 0,4,0.5f, 0,250,0.35f, 0, 8,0.8f, 1,0.55f,0.85f, 1,0.55f,0.32f, 0, 1, 0, -5, 1}, // ROBOT (vocoder + instant tune)
    {0,0.30f,1.0f, 0, 7,0.40f, 0,4,0.5f, 1,110,0.15f, 0, 8,0.8f, 0,0.5f,0.7f, 1,0.30f,0.20f, 0, 0, 0, -5, 1}, // SLAP
    {0,0.30f,1.0f, 0, 7,0.40f, 0,4,0.5f, 1,400,0.55f, 0, 8,0.8f, 0,0.5f,0.7f, 1,0.75f,0.45f, 0, 0, 0, -5, 1}, // DUB
    {1,0.05f,1.0f, 0, 7,0.40f, 0,4,0.5f, 0,250,0.35f, 1,12,0.9f, 0,0.5f,0.7f, 1,0.40f,0.25f, 0, 1, 0, -5, 1}, // GLITCH (hard tune)
    {0,0.30f,1.0f, 0, 7,0.40f, 1,6,0.7f, 0,250,0.35f, 1, 8,0.6f, 0,0.5f,0.7f, 1,0.45f,0.30f, 0, 0, 0, -5, 1}, // STUTTER
    {1,0.55f,1.0f, 1,-12,0.40f,0,4,0.5f, 1,300,0.40f, 0, 8,0.8f, 0,0.5f,0.7f, 1,0.82f,0.50f, 0, 2, 0, -5, 1, 0, 0.35f}, // GHOST (minor, soft tune, humanized)
    {1,0.08f,1.0f, 1, 7,0.30f, 1,4,0.4f, 1,250,0.35f, 1, 6,0.5f, 1,0.50f,0.60f, 1,0.60f,0.35f, 1, 1, 0, -5, 1}, // FULL (auto)
};
}

@interface VoiceBoxAudioUnit ()
@property (nonatomic) AUAudioUnitBusArray *inputBusArray;
@property (nonatomic) AUAudioUnitBusArray *outputBusArray;
@end

@implementation VoiceBoxAudioUnit {
    std::vector<float> _ownOutBuf;   // scratch output (2 ch) for hosts that pass NULL mData
    std::unique_ptr<vbx::VoiceBoxEngine> _dsp;
    AUAudioUnitBus *_inBus;
    AUAudioUnitBus *_outBus;
    AVAudioFormat  *_format;
    std::atomic<float> _p[kNumParams];

    // Spectrum probe.
    float              _ring[kRingSize];
    std::atomic<int>   _ringWrite;
    FFTSetup           _fftSetup;
    std::vector<float> _hann, _fftReal, _fftImag, _smoothedDB;
    float              _sampleRate;

    // Meter taps (written once per render block, read by the editor).
    std::atomic<float> _mLevel, _mMidi, _mTarget, _mCorr;
    std::atomic<int>   _mVoiced;
}

@synthesize parameterTree = _parameterTree;

- (instancetype)initWithComponentDescription:(AudioComponentDescription)desc
                                     options:(AudioComponentInstantiationOptions)options
                                       error:(NSError * _Nullable __autoreleasing *)outError {
    self = [super initWithComponentDescription:desc options:options error:outError];
    if (!self) return nil;

    _dsp = std::make_unique<vbx::VoiceBoxEngine>();
    _dsp->prepare(48000.0f);
    _sampleRate = 48000.0f;

    std::memset(_ring, 0, sizeof(_ring));
    _ringWrite.store(0);
    _mLevel.store(0.0f); _mMidi.store(0.0f); _mTarget.store(-1.0f); _mCorr.store(0.0f); _mVoiced.store(0);
    _hann.assign(kFFTSize, 0.0f);
    vDSP_hann_window(_hann.data(), kFFTSize, vDSP_HANN_NORM);
    _fftReal.assign(kFFTBins, 0.0f);
    _fftImag.assign(kFFTBins, 0.0f);
    _smoothedDB.clear();
    _fftSetup = vDSP_create_fftsetup(kFFTLog2, kFFTRadix2);

    _format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000.0 channels:2];
    _inBus  = [[AUAudioUnitBus alloc] initWithFormat:_format error:nil];
    _outBus = [[AUAudioUnitBus alloc] initWithFormat:_format error:nil];
    _inputBusArray  = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput  busses:@[_inBus]];
    _outputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[_outBus]];

    [self buildParameterTree];
    return self;
}

- (AUAudioUnitBusArray *)inputBusses  { return _inputBusArray; }
- (AUAudioUnitBusArray *)outputBusses { return _outputBusArray; }

- (void)dealloc {
    if (_fftSetup) vDSP_destroy_fftsetup(_fftSetup);
}

- (int)presetCount { return 10; }
- (NSString *)presetName:(int)preset {
    if (preset < 0 || preset >= 10) return @"";
    return [NSString stringWithUTF8String:kPresetNames[preset]];
}
- (void)applyPreset:(int)preset {
    if (preset < 0 || preset >= 10) return;
    for (int i = 0; i < kNumParams; ++i) {
        if (i == 26) continue;   // the song's KEY belongs to the user, not to a preset
        AUParameter *p = [_parameterTree parameterWithAddress:(AUParameterAddress)i];
        if (p) [p setValue:kPresets[preset][i] originator:nil];
    }
}

- (void)buildParameterTree {
    NSMutableArray<AUParameter *> *params = [NSMutableArray array];
    for (int i = 0; i < kNumParams; ++i) {
        AUParameter *p = [AUParameterTree createParameterWithIdentifier:[NSString stringWithUTF8String:kSpecs[i].id]
            name:[NSString stringWithUTF8String:kSpecs[i].name]
            address:(AUParameterAddress)i
            min:kSpecs[i].mn max:kSpecs[i].mx
            unit:kAudioUnitParameterUnit_Generic unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable)
            valueStrings:nil dependentParameters:nil];
        p.value = kSpecs[i].df;
        _p[i].store(kSpecs[i].df);
        [params addObject:p];
    }
    _parameterTree = [AUParameterTree createTreeWithChildren:params];

    __weak VoiceBoxAudioUnit *weakSelf = self;
    _parameterTree.implementorValueObserver = ^(AUParameter *param, AUValue value) {
        VoiceBoxAudioUnit *s = weakSelf; if (!s) return;
        if (param.address < kNumParams) s->_p[param.address].store(value);
    };
    _parameterTree.implementorValueProvider = ^AUValue(AUParameter *param) {
        VoiceBoxAudioUnit *s = weakSelf; if (!s) return 0;
        return (param.address < kNumParams) ? s->_p[param.address].load() : 0;
    };
}

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)outError {
    if (![super allocateRenderResourcesAndReturnError:outError]) return NO;
    _ownOutBuf.assign((size_t)MAX((AUAudioFrameCount)512, self.maximumFramesToRender) * 2, 0.0f);
    _sampleRate = (float)_outBus.format.sampleRate;
    // Latency depends on the sample rate (1024 @ 44.1/48 kHz, 2048 @ 96 kHz):
    // tell the host so it re-reads it for delay compensation.
    [self willChangeValueForKey:@"latency"];
    _dsp->prepare(_sampleRate);
    [self didChangeValueForKey:@"latency"];
    return YES;
}

- (void)deallocateRenderResources {
    [super deallocateRenderResources];
    if (_dsp) _dsp->reset();
}

- (BOOL)readSpectrumBands:(float *)outDB count:(int)count {
    if (!_fftSetup || count <= 0) return NO;
    float buf[kFFTSize];
    const int w = _ringWrite.load(std::memory_order_relaxed);
    const int start = (w - kFFTSize) & kRingMask;
    for (int i = 0; i < kFFTSize; ++i) buf[i] = _ring[(start + i) & kRingMask];
    vDSP_vmul(buf, 1, _hann.data(), 1, buf, 1, kFFTSize);
    DSPSplitComplex sc; sc.realp = _fftReal.data(); sc.imagp = _fftImag.data();
    vDSP_ctoz((DSPComplex *)buf, 2, &sc, 1, kFFTBins);
    vDSP_fft_zrip(_fftSetup, &sc, 1, kFFTLog2, FFT_FORWARD);
    float mag2[kFFTBins];
    vDSP_zvmags(&sc, 1, mag2, 1, kFFTBins);
    const float scale = 1.0f / (float)(kFFTSize * kFFTSize * 4);
    vDSP_vsmul(mag2, 1, &scale, mag2, 1, kFFTBins);
    if ((int)_smoothedDB.size() != count) _smoothedDB.assign(count, -90.0f);
    const float sr = _sampleRate;
    const float logMin = std::log(20.0f), logMax = std::log(20000.0f);
    for (int b = 0; b < count; ++b) {
        const float t = (float)b / std::max(1, count - 1);
        const float hz = std::exp(logMin + t * (logMax - logMin));
        int bi = std::max(0, std::min(kFFTBins - 1, (int)std::round(hz * (float)kFFTSize / sr)));
        const float dB = 10.0f * std::log10(std::max(mag2[bi], 1e-12f));
        const float prev = _smoothedDB[b];
        _smoothedDB[b] = prev + (dB - prev) * ((dB > prev) ? 0.55f : 0.18f);
        outDB[b] = _smoothedDB[b];
    }
    return YES;
}

- (void)readVoiceMeter:(VBVoiceMeter *)out {
    if (!out) return;
    out->level      = _mLevel.exchange(0.0f, std::memory_order_relaxed);
    out->midi       = _mMidi.load(std::memory_order_relaxed);
    out->targetMidi = _mTarget.load(std::memory_order_relaxed);
    out->corrCents  = _mCorr.load(std::memory_order_relaxed);
    out->voiced     = _mVoiced.load(std::memory_order_relaxed);
}

/// Transport relocation / loop restart: clear tails so stale echoes don't replay.
- (void)reset { if (_dsp) _dsp->reset(); }
/// Constant latency of the whole rack — every path (dry, AUTOTUNE, HARMONY,
/// LOW TUNER, PITCH-SKIP) comes out exactly this late (bench test T7).
- (NSTimeInterval)latency {
    const double sr = _sampleRate > 0 ? (double)_sampleRate : 48000.0;
    return (double)_dsp->latencySamples() / sr;
}
/// What keeps ringing after the input stops: the DELAY repeats (one pass per
/// 20·log10(FB) dB down to −60 dB) and the REVERB, when those modules are on.
/// It reported 0, so a host was free to cut the tail on a bounce.
- (NSTimeInterval)tailTime {
    double t = 0.0;
    if (_p[9].load() >= 0.5f) {                                   // dlOn
        const double fb = fmin(0.95, fmax(0.0, (double)_p[11].load()));
        const double passes = fb > 0.001 ? ceil(-60.0 / (20.0 * log10(fb))) : 0.0;
        t = (double)_p[10].load() * 0.001 * (passes + 1.0);
    }
    if (_p[18].load() >= 0.5f) t = fmax(t, 1.0 + 4.0 * (double)_p[19].load());   // rvOn, rvSize
    return fmin(60.0, t);
}

- (AUInternalRenderBlock)internalRenderBlock {
    __block vbx::VoiceBoxEngine *dsp = _dsp.get();
    __block std::atomic<float> *p = _p;
    __block float *ring = _ring;
    __block std::atomic<int> *ringWrite = &_ringWrite;
    __block std::atomic<float> *mLevel = &_mLevel, *mMidi = &_mMidi, *mTarget = &_mTarget, *mCorr = &_mCorr;
    __block std::atomic<int> *mVoiced = &_mVoiced;

    __block std::vector<float> *ownOutBuf = &_ownOutBuf;
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *actionFlags,
                              const AudioTimeStamp *timestamp,
                              AVAudioFrameCount frameCount,
                              NSInteger outputBusNumber,
                              AudioBufferList *outputData,
                              const AURenderEvent *realtimeEventListHead,
                              AURenderPullInputBlock pullInputBlock) {
        // ── Host buffer contract ─────────────────────────────────────────
        // A host may hand us output buffers whose mData is NULL and expect the
        // AU to render into memory it owns (Logic passes real buffers, other
        // hosts and auval passes may not). Point the buffers at our scratch.
        if (outputData->mNumberBuffers > 0 && outputData->mBuffers[0].mData == NULL) {
            float *own = ownOutBuf->data(); const size_t cap = ownOutBuf->size() / 2;
            if (!own || (size_t)frameCount > cap) return kAudioUnitErr_TooManyFramesToProcess;
            for (UInt32 b = 0; b < outputData->mNumberBuffers && b < 2; ++b) {
                outputData->mBuffers[b].mData = own + (size_t)b * cap;
                outputData->mBuffers[b].mDataByteSize = (UInt32)(frameCount * sizeof(float));
            }
        }
        // No input connected (bypass / unconnected render pass): silence, not a
        // call through a NULL pull block.
        if (!pullInputBlock) {
            for (UInt32 b = 0; b < outputData->mNumberBuffers; ++b)
                if (outputData->mBuffers[b].mData) memset(outputData->mBuffers[b].mData, 0, frameCount * sizeof(float));
            return noErr;
        }
#if defined(__arm64__) || defined(__aarch64__)
        fesetenv(FE_DFL_DISABLE_DENORMS_ENV);
#elif defined(__x86_64__) || defined(__i386__)
        _mm_setcsr(_mm_getcsr() | 0x8040u);
#endif
        AudioUnitRenderActionFlags pullFlags = 0;
        AUAudioUnitStatus err = pullInputBlock(&pullFlags, timestamp, frameCount, 0, outputData);
        if (err != noErr) return err;

        dsp->setAutotune (p[0].load()  > 0.5f, p[1].load(),  p[2].load(), p[22].load(), p[26].load(), p[27].load());
        dsp->setHarmonizer(p[3].load() > 0.5f, p[4].load(),  p[5].load(), p[21].load() > 0.5f);
        dsp->setSkip     (p[6].load()  > 0.5f, p[7].load(),  p[8].load());
        dsp->setDelay    (p[9].load()  > 0.5f, p[10].load(), p[11].load());
        dsp->setChop     (p[12].load() > 0.5f, p[13].load(), p[14].load());
        dsp->setVocoder  (p[15].load() > 0.5f, p[16].load(), p[17].load());
        dsp->setReverb   (p[18].load() > 0.5f, p[19].load(), p[20].load());
        dsp->setLow      (p[23].load() > 0.5f, p[24].load(), p[25].load());

        if (outputData->mNumberBuffers < 2) {
            float *m = (float *)outputData->mBuffers[0].mData;
            for (AVAudioFrameCount i = 0; i < frameCount; ++i) {
                float l = m[i], r = m[i];
                dsp->processFrame(l, r);
                m[i] = 0.5f * (l + r);
            }
        } else {
            float *L = (float *)outputData->mBuffers[0].mData;
            float *R = (float *)outputData->mBuffers[1].mData;
            for (AVAudioFrameCount i = 0; i < frameCount; ++i) {
                dsp->processFrame(L[i], R[i]);
            }
        }
        // Push post-effects mono samples into the spectrum ring.
        const float *mL = (const float *)outputData->mBuffers[0].mData;
        const float *mR = outputData->mNumberBuffers >= 2
                          ? (const float *)outputData->mBuffers[1].mData : mL;
        int w = ringWrite->load(std::memory_order_relaxed);
        float acc = 0.0f;
        for (AVAudioFrameCount i = 0; i < frameCount; ++i) {
            const float m = 0.5f * (mL[i] + mR[i]);
            ring[w & kRingMask] = m;
            acc += m * m;
            w++;
        }
        ringWrite->store(w, std::memory_order_relaxed);
        // Meter taps for the editor: block RMS peak-held until the UI reads it
        // (readVoiceMeter exchanges it back to 0), plus the tracker / tune state.
        if (frameCount > 0) {
            const float rms = std::sqrt(acc / (float)frameCount);
            if (rms > mLevel->load(std::memory_order_relaxed)) mLevel->store(rms, std::memory_order_relaxed);
        }
        mVoiced->store(dsp->meterVoiced() ? 1 : 0, std::memory_order_relaxed);
        mMidi->store(dsp->meterMidi(), std::memory_order_relaxed);
        mTarget->store((float)dsp->meterTarget(), std::memory_order_relaxed);
        mCorr->store(dsp->meterCorrCents(), std::memory_order_relaxed);
        return noErr;
    };
}

@end
