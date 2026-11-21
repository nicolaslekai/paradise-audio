//
//  LimiterAudioUnit.mm
//
#import "LimiterAudioUnit.h"
#import "DSP/Limiter.hpp"
#import <Accelerate/Accelerate.h>
#include <memory>
#include <vector>
#include <cstring>
#include <cmath>
#include <fenv.h>
#if defined(__x86_64__) || defined(__i386__)
#include <xmmintrin.h>
#endif

enum : AUParameterAddress {
    kParamInputGain = 0,
    kParamCeiling   = 1,
    kParamRelease   = 2,
    kParamThreshold = 3,   // 2026-11-21 — new address; 0–2 keep their meaning
};

// Old sessions (before the THRESHOLD parameter) had drive = gain − ceiling.
// The new drive is gain + ceiling − threshold, so threshold = 2 × ceiling − gain
// with gain folded to 0 reproduces them exactly; whatever the threshold range
// cannot hold stays in the (now secondary) input trim.
static NSString * const kStateModelKey = @"paradiseLimiterModel";   // 2 = threshold model
static constexpr float kThrMin = -30.0f, kThrMax = 0.0f;

// FFT ring-buffer constants — identical to the EQ's spectrum probe.
static constexpr int kRingSize = 2048;
static constexpr int kRingMask = kRingSize - 1;
static constexpr int kFFTSize  = 1024;
static constexpr int kFFTLog2  = 10;
static constexpr int kFFTBins  = kFFTSize / 2;

@interface LimiterAudioUnit ()
@property (nonatomic) AUAudioUnitBusArray *inputBusArray;
@property (nonatomic) AUAudioUnitBusArray *outputBusArray;
@end

@implementation LimiterAudioUnit {
    std::vector<float> _ownOutBuf;   // scratch output (2 ch) for hosts that pass NULL mData
    std::unique_ptr<lim::Limiter> _dsp;
    AUAudioUnitBus *_inBus;
    AUAudioUnitBus *_outBus;
    AVAudioFormat  *_format;
    std::atomic<float> _gain, _ceil, _release, _thr;

    // Spectrum probe — render thread writes _ring, UI thread reads via FFT.
    float              _ring[kRingSize];
    std::atomic<int>   _ringWrite;
    FFTSetup           _fftSetup;
    std::vector<float> _hann;
    std::vector<float> _fftReal;
    std::vector<float> _fftImag;
    std::vector<float> _smoothedDB;
    float              _sampleRate;
}

@synthesize parameterTree = _parameterTree;

- (instancetype)initWithComponentDescription:(AudioComponentDescription)desc
                                     options:(AudioComponentInstantiationOptions)options
                                       error:(NSError * _Nullable __autoreleasing *)outError {
    self = [super initWithComponentDescription:desc options:options error:outError];
    if (!self) return nil;

    _dsp = std::make_unique<lim::Limiter>();
    _dsp->prepare(48000.0f);
    _sampleRate = 48000.0f;

    // Spectrum probe init (Hann window + FFT setup, allocated once).
    std::memset(_ring, 0, sizeof(_ring));
    _ringWrite.store(0);
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

- (float)currentGainReductionDB { return _dsp ? _dsp->currentGainReductionDB() : 0.0f; }
- (float)currentInputPeakDB     { return _dsp ? _dsp->currentInputPeakDB()     : -80.0f; }
- (float)shortTermLUFS          { return _dsp ? _dsp->shortTermLUFS()  : -120.0f; }
- (float)integratedLUFS         { return _dsp ? _dsp->integratedLUFS() : -120.0f; }
- (void)resetIntegrated         { if (_dsp) _dsp->resetIntegrated(); }
- (int)readWaveformInto:(float *)out count:(int)n {
    return _dsp ? _dsp->readWaveformLast(out, n) : 0;
}
- (int)readTapInto:(float *)out maxBuckets:(int)n writeCount:(uint32_t *)writeCount {
    return _dsp ? _dsp->readTap(out, n, writeCount) : 0;
}
- (double)tapBucketSeconds { return _dsp ? _dsp->tapBucketSeconds() : 0.006; }

#pragma mark - State (old-session migration)

- (NSDictionary<NSString *, id> *)fullState {
    NSMutableDictionary *d = [[super fullState] mutableCopy] ?: [NSMutableDictionary dictionary];
    d[kStateModelKey] = @2;
    return d;
}

- (void)setFullState:(NSDictionary<NSString *, id> *)fullState {
    [super setFullState:fullState];
    if (fullState == nil || [fullState[kStateModelKey] integerValue] >= 2) return;
    // Saved before THRESHOLD existed: fold the old drive into the threshold.
    AUParameter *gainP = [_parameterTree parameterWithAddress:kParamInputGain];
    AUParameter *ceilP = [_parameterTree parameterWithAddress:kParamCeiling];
    AUParameter *thrP  = [_parameterTree parameterWithAddress:kParamThreshold];
    if (!gainP || !ceilP || !thrP) return;
    const float g = gainP.value, c = ceilP.value;
    const float want = 2.0f * c - g;
    const float thr  = std::max(kThrMin, std::min(kThrMax, want));
    [thrP  setValue:thr originator:nil];
    [gainP setValue:(thr - want) originator:nil];   // 0 unless the threshold had to clamp
}

- (void)dealloc {
    if (_fftSetup) vDSP_destroy_fftsetup(_fftSetup);
}

/// 1024-point real FFT over the most-recent post-limit samples, binned into
/// `count` log-spaced bands (20 Hz – 20 kHz), smoothed for visual stability.
/// Lifted verbatim from the EQ so the Limiter's spectrum matches it exactly.
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
    const float logMin = std::log(20.0f);
    const float logMax = std::log(20000.0f);
    for (int b = 0; b < count; ++b) {
        const float t = (float)b / std::max(1, count - 1);
        const float hz = std::exp(logMin + t * (logMax - logMin));
        float bin = hz * (float)kFFTSize / sr;
        int bi = std::max(0, std::min(kFFTBins - 1, (int)std::round(bin)));
        const float m2 = std::max(mag2[bi], 1e-12f);
        const float dB = 10.0f * std::log10(m2);
        const float prev = _smoothedDB[b];
        const float coeff = (dB > prev) ? 0.55f : 0.18f;
        _smoothedDB[b] = prev + (dB - prev) * coeff;
        outDB[b] = _smoothedDB[b];
    }
    return YES;
}

- (void)applyLoudnessPreset:(int)preset {
    AUParameter *gainP = [_parameterTree parameterWithAddress:kParamInputGain];
    AUParameter *ceilP = [_parameterTree parameterWithAddress:kParamCeiling];
    AUParameter *relP  = [_parameterTree parameterWithAddress:kParamRelease];
    AUParameter *thrP  = [_parameterTree parameterWithAddress:kParamThreshold];
    if (!gainP || !ceilP || !relP || !thrP) return;
    // Same drive as the old presets (gain − ceiling), now as a threshold.
    switch (preset) {
        case 0:  // BROADCAST (-23 LUFS) — gentler drive (9 dB), longer release
            [gainP setValue:0.0f    originator:nil];
            [thrP  setValue:-12.0f  originator:nil];
            [ceilP setValue:-3.0f   originator:nil];
            [relP  setValue:100.0f  originator:nil];
            break;
        case 1:  // STREAM (-14 LUFS) — harder drive (13 dB), tighter release
        default:
            [gainP setValue:0.0f    originator:nil];
            [thrP  setValue:-14.0f  originator:nil];
            [ceilP setValue:-1.0f   originator:nil];
            [relP  setValue:60.0f   originator:nil];
            break;
    }
}

- (void)buildParameterTree {
    AudioUnitParameterUnit dB = kAudioUnitParameterUnit_Decibels;
    AudioUnitParameterUnit ms = kAudioUnitParameterUnit_Milliseconds;

    AUParameter *pThr = [AUParameterTree createParameterWithIdentifier:@"threshold"
        name:@"Threshold" address:kParamThreshold min:kThrMin max:kThrMax unit:dB unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable)
        valueStrings:nil dependentParameters:nil];
    pThr.value = -2.0f;   // = 2 × default ceiling: the old default sound

    // Input Gain is now a secondary trim (old sessions are folded into the
    // threshold on load, so it normally sits at 0). Identifier unchanged.
    AUParameter *pGain = [AUParameterTree createParameterWithIdentifier:@"inputGain"
        name:@"Input Trim" address:kParamInputGain min:-12.0f max:24.0f unit:dB unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable)
        valueStrings:nil dependentParameters:nil];
    pGain.value = 0.0f;

    AUParameter *pCeil = [AUParameterTree createParameterWithIdentifier:@"ceiling"
        name:@"Ceiling" address:kParamCeiling min:-12.0f max:0.0f unit:dB unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable)
        valueStrings:nil dependentParameters:nil];
    pCeil.value = -1.0f;

    AUParameter *pRel = [AUParameterTree createParameterWithIdentifier:@"release"
        name:@"Release" address:kParamRelease min:1.0f max:1000.0f unit:ms unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable)
        valueStrings:nil dependentParameters:nil];
    pRel.value = 80.0f;

    _parameterTree = [AUParameterTree createTreeWithChildren:@[pThr, pCeil, pRel, pGain]];

    _gain.store(0.0f); _ceil.store(-1.0f); _release.store(80.0f); _thr.store(-2.0f);

    __weak LimiterAudioUnit *weakSelf = self;
    _parameterTree.implementorValueObserver = ^(AUParameter *param, AUValue value) {
        LimiterAudioUnit *s = weakSelf; if (!s) return;
        switch (param.address) {
            case kParamInputGain: s->_gain.store(value);    break;
            case kParamCeiling:   s->_ceil.store(value);    break;
            case kParamRelease:   s->_release.store(value); break;
            case kParamThreshold: s->_thr.store(value);     break;
        }
    };
    _parameterTree.implementorValueProvider = ^AUValue(AUParameter *param) {
        LimiterAudioUnit *s = weakSelf; if (!s) return 0;
        switch (param.address) {
            case kParamInputGain: return s->_gain.load();
            case kParamCeiling:   return s->_ceil.load();
            case kParamRelease:   return s->_release.load();
            case kParamThreshold: return s->_thr.load();
        }
        return 0;
    };
    _parameterTree.implementorStringFromValueCallback = ^NSString *(AUParameter *param, const AUValue *valuePtr) {
        AUValue v = valuePtr ? *valuePtr : param.value;
        switch (param.address) {
            case kParamInputGain:
            case kParamCeiling:
            case kParamThreshold:
                return [NSString stringWithFormat:@"%+.1f dB", v];
            case kParamRelease:
                return [NSString stringWithFormat:@"%.0f ms", v];
        }
        return [NSString stringWithFormat:@"%.2f", v];
    };
}

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)outError {
    if (![super allocateRenderResourcesAndReturnError:outError]) return NO;
    _ownOutBuf.assign((size_t)MAX((AUAudioFrameCount)512, self.maximumFramesToRender) * 2, 0.0f);
    _dsp->prepare((float)_outBus.format.sampleRate);
    return YES;
}

- (void)deallocateRenderResources {
    [super deallocateRenderResources];
    if (_dsp) _dsp->reset();
}

/// The 5 ms lookahead delays the audio; tell the host so its plug-in delay
/// compensation lines the track back up (parallel drum busses were combing).
- (NSTimeInterval)latency { return 0.005; }
- (void)reset { if (_dsp) _dsp->reset(); }

- (AUInternalRenderBlock)internalRenderBlock {
    __block lim::Limiter *dsp = _dsp.get();
    __block std::atomic<float> *aG = &_gain, *aC = &_ceil, *aR = &_release, *aT = &_thr;
    __block float *ring = _ring;
    __block std::atomic<int> *ringWrite = &_ringWrite;

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

        dsp->setInputGainDB(aG->load());
        dsp->setCeilingDB(aC->load());
        dsp->setReleaseMs(aR->load());
        dsp->setThresholdDB(aT->load());

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
        // Push mono (avg) post-limit samples into the spectrum ring buffer.
        const float *mL = (const float *)outputData->mBuffers[0].mData;
        const float *mR = outputData->mNumberBuffers >= 2
                          ? (const float *)outputData->mBuffers[1].mData
                          : mL;
        int w = ringWrite->load(std::memory_order_relaxed);
        for (AVAudioFrameCount i = 0; i < frameCount; ++i) {
            ring[w & kRingMask] = 0.5f * (mL[i] + mR[i]);
            w++;
        }
        ringWrite->store(w, std::memory_order_relaxed);
        return noErr;
    };
}

@end
