//
//  EQAudioUnit.mm
//

#import "EQAudioUnit.h"
#import "DSP/EQEngine.hpp"
#import <Accelerate/Accelerate.h>

#include <atomic>
#include <memory>
#include <vector>
#include <cstring>
#include <cmath>
#include <fenv.h>
#if defined(__x86_64__) || defined(__i386__)
#include <xmmintrin.h>
#endif

enum : AUParameterAddress {
    kParamHP       = 0,
    kParamLoFreq   = 1,
    kParamLoGain   = 2,
    kParamHiFreq   = 3,
    kParamHiGain   = 4,
    kParamLP       = 5,
    kParamLMFreq   = 6,
    kParamLMGain   = 7,
    kParamHMFreq   = 8,
    kParamHMGain   = 9,
    kParamLoQ      = 10,
    kParamLMQ      = 11,
    kParamHMQ      = 12,
    kParamHiQ      = 13,
    kParamHPSlope  = 14,   // 0 = 12 dB/oct, 1 = 24 dB/oct
    kParamLPSlope  = 15,   // 0 = 12 dB/oct, 1 = 24 dB/oct
};

@interface EQAudioUnit ()
@property (nonatomic) AUAudioUnitBusArray *inputBusArray;
@property (nonatomic) AUAudioUnitBusArray *outputBusArray;
@end

// FFT ring-buffer constants. 2048 sample ring, 1024-point FFT (= 512 bins).
static constexpr int kRingSize  = 2048;
static constexpr int kRingMask  = kRingSize - 1;
static constexpr int kFFTSize   = 1024;
static constexpr int kFFTLog2   = 10;
static constexpr int kFFTBins   = kFFTSize / 2;

@implementation EQAudioUnit {
    std::vector<float> _ownOutBuf;   // scratch output (2 ch) for hosts that pass NULL mData
    std::unique_ptr<eq::EQEngine> _dsp;
    AUAudioUnitBus *_inBus;
    AUAudioUnitBus *_outBus;
    AVAudioFormat  *_format;

    std::atomic<float> _hp, _loFreq, _loGain, _hiFreq, _hiGain, _lp;
    std::atomic<float> _lmFreq, _lmGain, _hmFreq, _hmGain;
    std::atomic<float> _loQ, _lmQ, _hmQ, _hiQ;   // per-band bell width (Q)
    std::atomic<float> _hpSlope, _lpSlope;       // 0 = 12 dB/oct, 1 = 24 dB/oct

    // Spectrum probe — render thread writes, UI thread reads.
    float                   _ring[kRingSize];
    std::atomic<int>        _ringWrite;
    FFTSetup                _fftSetup;
    std::vector<float>      _hann;
    std::vector<float>      _fftReal;
    std::vector<float>      _fftImag;
    std::vector<float>      _smoothedDB;
    float                   _sampleRate;
}

@synthesize parameterTree = _parameterTree;

- (instancetype)initWithComponentDescription:(AudioComponentDescription)desc
                                     options:(AudioComponentInstantiationOptions)options
                                       error:(NSError * _Nullable __autoreleasing *)outError {
    self = [super initWithComponentDescription:desc options:options error:outError];
    if (!self) return nil;

    _dsp = std::make_unique<eq::EQEngine>();
    _dsp->prepare(48000.0f);
    _sampleRate = 48000.0f;
    // Init spectrum buffers + Hann window once. FFT setup is lazy-allocated
    // because vDSP setup is expensive.
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

- (void)dealloc {
    if (_fftSetup) vDSP_destroy_fftsetup(_fftSetup);
}

- (float)magnitudeDBAtFrequency:(float)hz {
    if (!_dsp) return 0.0f;
    // Feed the UI's view of the parameters (the atomics the observer writes)
    // so the curve follows a dragged handle even when the host isn't rendering.
    eq::EQEngine::DisplayParams p = {
        _hp.load(), _loFreq.load(), _loGain.load(), _loQ.load(),
        _lmFreq.load(), _lmGain.load(), _lmQ.load(),
        _hmFreq.load(), _hmGain.load(), _hmQ.load(),
        _hiFreq.load(), _hiGain.load(), _hiQ.load(), _lp.load(),
        _hpSlope.load() >= 0.5f, _lpSlope.load() >= 0.5f };
    _dsp->setDisplayParams(p);
    return _dsp->magnitudeDBAt(hz);
}

// The bell/shelf switches are not parameters, so carry them in the state
// dictionary — otherwise a saved LO bell came back as a shelf on reload.
- (NSDictionary<NSString *, id> *)fullState {
    NSMutableDictionary *st = [[super fullState] mutableCopy] ?: [NSMutableDictionary dictionary];
    st[@"eqLowIsBell"]  = @(self.lowIsBell);
    st[@"eqHighIsBell"] = @(self.highIsBell);
    return st;
}
- (void)setFullState:(NSDictionary<NSString *, id> *)fullState {
    [super setFullState:fullState];
    id lo = fullState[@"eqLowIsBell"], hi = fullState[@"eqHighIsBell"];
    if ([lo isKindOfClass:[NSNumber class]]) self.lowIsBell  = [lo boolValue];
    if ([hi isKindOfClass:[NSNumber class]]) self.highIsBell = [hi boolValue];
}
- (void)reset { if (_dsp) _dsp->reset(); }

- (BOOL)lowIsBell  { return _dsp ? _dsp->lowIsBell()  : NO; }
- (void)setLowIsBell:(BOOL)b  { if (_dsp) _dsp->setLowIsBell(b ? true : false); }
- (BOOL)highIsBell { return _dsp ? _dsp->highIsBell() : NO; }
- (void)setHighIsBell:(BOOL)b { if (_dsp) _dsp->setHighIsBell(b ? true : false); }

/// Take a 1024-sample snapshot of the most recent input, run a 1024-point
/// real-to-complex FFT, and bin the magnitudes into `count` log-spaced bands
/// covering 20 Hz – 20 kHz. Smoothed over time for visual stability.
- (BOOL)readSpectrumBands:(float *)outDB count:(int)count {
    if (!_fftSetup || count <= 0) return NO;
    // Snapshot ring buffer.
    float buf[kFFTSize];
    const int w = _ringWrite.load(std::memory_order_relaxed);
    const int start = (w - kFFTSize) & kRingMask;
    for (int i = 0; i < kFFTSize; ++i) buf[i] = _ring[(start + i) & kRingMask];
    // Window
    vDSP_vmul(buf, 1, _hann.data(), 1, buf, 1, kFFTSize);
    // Pack real → split-complex
    DSPSplitComplex sc; sc.realp = _fftReal.data(); sc.imagp = _fftImag.data();
    vDSP_ctoz((DSPComplex *)buf, 2, &sc, 1, kFFTBins);
    // FFT
    vDSP_fft_zrip(_fftSetup, &sc, 1, kFFTLog2, FFT_FORWARD);
    // Magnitude² (avoid sqrt)
    float mag2[kFFTBins];
    vDSP_zvmags(&sc, 1, mag2, 1, kFFTBins);
    // Normalize. vDSP_fft_zrip returns a 2x-scaled result.
    const float scale = 1.0f / (float)(kFFTSize * kFFTSize * 4);
    vDSP_vsmul(mag2, 1, &scale, mag2, 1, kFFTBins);
    // Initialise smoother
    if ((int)_smoothedDB.size() != count) _smoothedDB.assign(count, -90.0f);
    // Bin into log-spaced bands (20 Hz .. 20 kHz)
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
        // Decay toward target — fast rise, slow fall for visual snap.
        const float prev = _smoothedDB[b];
        const float coeff = (dB > prev) ? 0.55f : 0.18f;
        _smoothedDB[b] = prev + (dB - prev) * coeff;
        outDB[b] = _smoothedDB[b];
    }
    return YES;
}

- (void)buildParameterTree {
    AudioUnitParameterUnit Hz = kAudioUnitParameterUnit_Hertz;
    AudioUnitParameterUnit dB = kAudioUnitParameterUnit_Decibels;

    AUParameter *pHP = [AUParameterTree createParameterWithIdentifier:@"hp"
        name:@"HP" address:kParamHP min:20.0f max:1000.0f unit:Hz unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil];
    pHP.value = 40.0f;

    AUParameter *pLoF = [AUParameterTree createParameterWithIdentifier:@"loFreq"
        name:@"Lo Freq" address:kParamLoFreq min:40.0f max:800.0f unit:Hz unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil];
    pLoF.value = 120.0f;

    AUParameter *pLoG = [AUParameterTree createParameterWithIdentifier:@"loGain"
        name:@"Lo Gain" address:kParamLoGain min:-18.0f max:18.0f unit:dB unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil];
    pLoG.value = 0.0f;

    AUParameter *pHiF = [AUParameterTree createParameterWithIdentifier:@"hiFreq"
        name:@"Hi Freq" address:kParamHiFreq min:1000.0f max:16000.0f unit:Hz unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil];
    pHiF.value = 6000.0f;

    AUParameter *pHiG = [AUParameterTree createParameterWithIdentifier:@"hiGain"
        name:@"Hi Gain" address:kParamHiGain min:-18.0f max:18.0f unit:dB unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil];
    pHiG.value = 0.0f;

    AUParameter *pLP = [AUParameterTree createParameterWithIdentifier:@"lp"
        name:@"LP" address:kParamLP min:2000.0f max:20000.0f unit:Hz unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil];
    pLP.value = 18000.0f;

    AUParameter *pLMF = [AUParameterTree createParameterWithIdentifier:@"lmFreq"
        name:@"LM Freq" address:kParamLMFreq min:200.0f max:2000.0f unit:Hz unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil];
    pLMF.value = 500.0f;
    AUParameter *pLMG = [AUParameterTree createParameterWithIdentifier:@"lmGain"
        name:@"LM Gain" address:kParamLMGain min:-18.0f max:18.0f unit:dB unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil];
    pLMG.value = 0.0f;
    AUParameter *pHMF = [AUParameterTree createParameterWithIdentifier:@"hmFreq"
        name:@"HM Freq" address:kParamHMFreq min:1000.0f max:8000.0f unit:Hz unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil];
    pHMF.value = 2500.0f;
    AUParameter *pHMG = [AUParameterTree createParameterWithIdentifier:@"hmGain"
        name:@"HM Gain" address:kParamHMGain min:-18.0f max:18.0f unit:dB unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil];
    pHMG.value = 0.0f;

    // Per-band bell width (Q). Higher = narrower. The low/high bands use this
    // only when switched to bell mode; the mids are always bells.
    AudioUnitParameterUnit Q = kAudioUnitParameterUnit_Generic;
    AUParameter *pLoQ = [AUParameterTree createParameterWithIdentifier:@"loQ"
        name:@"Lo Q" address:kParamLoQ min:0.2f max:8.0f unit:Q unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil];
    pLoQ.value = 0.9f;
    AUParameter *pLMQ = [AUParameterTree createParameterWithIdentifier:@"lmQ"
        name:@"LM Q" address:kParamLMQ min:0.2f max:8.0f unit:Q unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil];
    pLMQ.value = 1.2f;
    AUParameter *pHMQ = [AUParameterTree createParameterWithIdentifier:@"hmQ"
        name:@"HM Q" address:kParamHMQ min:0.2f max:8.0f unit:Q unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil];
    pHMQ.value = 1.2f;
    AUParameter *pHiQ = [AUParameterTree createParameterWithIdentifier:@"hiQ"
        name:@"Hi Q" address:kParamHiQ min:0.2f max:8.0f unit:Q unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil];
    pHiQ.value = 0.9f;

    // HP / LP slope selectors. Indexed 0/1 → 12 / 24 dB/oct. Default 0 keeps
    // the original single-pole-pair behavior, so existing sessions are bit-
    // identical until the user double-clicks the HP/LP handle to steepen them.
    AUParameter *pHPSlope = [AUParameterTree createParameterWithIdentifier:@"hpSlope"
        name:@"HP Slope" address:kParamHPSlope min:0.0f max:1.0f unit:kAudioUnitParameterUnit_Indexed
        unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:@[@"12 dB/oct", @"24 dB/oct"] dependentParameters:nil];
    pHPSlope.value = 0.0f;
    AUParameter *pLPSlope = [AUParameterTree createParameterWithIdentifier:@"lpSlope"
        name:@"LP Slope" address:kParamLPSlope min:0.0f max:1.0f unit:kAudioUnitParameterUnit_Indexed
        unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:@[@"12 dB/oct", @"24 dB/oct"] dependentParameters:nil];
    pLPSlope.value = 0.0f;

    _parameterTree = [AUParameterTree createTreeWithChildren:@[pHP, pLoF, pLoG, pHiF, pHiG, pLP,
                                                                pLMF, pLMG, pHMF, pHMG,
                                                                pLoQ, pLMQ, pHMQ, pHiQ,
                                                                pHPSlope, pLPSlope]];

    _hp.store(40.0f); _loFreq.store(120.0f); _loGain.store(0.0f);
    _hiFreq.store(6000.0f); _hiGain.store(0.0f); _lp.store(18000.0f);
    _lmFreq.store(500.0f); _lmGain.store(0.0f);
    _hmFreq.store(2500.0f); _hmGain.store(0.0f);
    _loQ.store(0.9f); _lmQ.store(1.2f); _hmQ.store(1.2f); _hiQ.store(0.9f);
    _hpSlope.store(0.0f); _lpSlope.store(0.0f);

    __weak EQAudioUnit *weakSelf = self;
    _parameterTree.implementorValueObserver = ^(AUParameter *param, AUValue value) {
        EQAudioUnit *s = weakSelf; if (!s) return;
        switch (param.address) {
            case kParamHP:     s->_hp.store(value); break;
            case kParamLoFreq: s->_loFreq.store(value); break;
            case kParamLoGain: s->_loGain.store(value); break;
            case kParamHiFreq: s->_hiFreq.store(value); break;
            case kParamHiGain: s->_hiGain.store(value); break;
            case kParamLP:     s->_lp.store(value); break;
            case kParamLMFreq: s->_lmFreq.store(value); break;
            case kParamLMGain: s->_lmGain.store(value); break;
            case kParamHMFreq: s->_hmFreq.store(value); break;
            case kParamHMGain: s->_hmGain.store(value); break;
            case kParamLoQ:    s->_loQ.store(value); break;
            case kParamLMQ:    s->_lmQ.store(value); break;
            case kParamHMQ:    s->_hmQ.store(value); break;
            case kParamHiQ:    s->_hiQ.store(value); break;
            case kParamHPSlope: s->_hpSlope.store(value); break;
            case kParamLPSlope: s->_lpSlope.store(value); break;
        }
    };
    _parameterTree.implementorValueProvider = ^AUValue(AUParameter *param) {
        EQAudioUnit *s = weakSelf; if (!s) return 0;
        switch (param.address) {
            case kParamHP:     return s->_hp.load();
            case kParamLoFreq: return s->_loFreq.load();
            case kParamLoGain: return s->_loGain.load();
            case kParamHiFreq: return s->_hiFreq.load();
            case kParamHiGain: return s->_hiGain.load();
            case kParamLP:     return s->_lp.load();
            case kParamLMFreq: return s->_lmFreq.load();
            case kParamLMGain: return s->_lmGain.load();
            case kParamHMFreq: return s->_hmFreq.load();
            case kParamHMGain: return s->_hmGain.load();
            case kParamLoQ:    return s->_loQ.load();
            case kParamLMQ:    return s->_lmQ.load();
            case kParamHMQ:    return s->_hmQ.load();
            case kParamHiQ:    return s->_hiQ.load();
            case kParamHPSlope: return s->_hpSlope.load();
            case kParamLPSlope: return s->_lpSlope.load();
        }
        return 0;
    };
    _parameterTree.implementorStringFromValueCallback = ^NSString *(AUParameter *param, const AUValue *valuePtr) {
        AUValue v = valuePtr ? *valuePtr : param.value;
        switch (param.address) {
            case kParamHP: case kParamLoFreq: case kParamHiFreq: case kParamLP:
            case kParamLMFreq: case kParamHMFreq:
                return v >= 1000.0f ? [NSString stringWithFormat:@"%.1f kHz", v/1000.0f]
                                     : [NSString stringWithFormat:@"%.0f Hz", v];
            case kParamLoGain: case kParamHiGain:
            case kParamLMGain: case kParamHMGain:
                return [NSString stringWithFormat:@"%+.1f dB", v];
            case kParamLoQ: case kParamLMQ: case kParamHMQ: case kParamHiQ:
                return [NSString stringWithFormat:@"Q %.2f", v];
            case kParamHPSlope: case kParamLPSlope:
                return v >= 0.5f ? @"24 dB/oct" : @"12 dB/oct";
        }
        return [NSString stringWithFormat:@"%.2f", v];
    };
}

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)outError {
    if (![super allocateRenderResourcesAndReturnError:outError]) return NO;
    _ownOutBuf.assign((size_t)MAX((AUAudioFrameCount)512, self.maximumFramesToRender) * 2, 0.0f);
    _sampleRate = (float)_outBus.format.sampleRate;
    _dsp->prepare(_sampleRate);
    return YES;
}

- (void)deallocateRenderResources {
    [super deallocateRenderResources];
    if (_dsp) _dsp->reset();
}

- (AUInternalRenderBlock)internalRenderBlock {
    __block eq::EQEngine *dsp = _dsp.get();
    __block std::atomic<float> *aHP = &_hp, *aLoF = &_loFreq, *aLoG = &_loGain;
    __block std::atomic<float> *aHiF = &_hiFreq, *aHiG = &_hiGain, *aLP = &_lp;
    __block std::atomic<float> *aLMF = &_lmFreq, *aLMG = &_lmGain;
    __block std::atomic<float> *aHMF = &_hmFreq, *aHMG = &_hmGain;
    __block std::atomic<float> *aLoQ = &_loQ, *aLMQ = &_lmQ, *aHMQ = &_hmQ, *aHiQ = &_hiQ;
    __block std::atomic<float> *aHPSlope = &_hpSlope, *aLPSlope = &_lpSlope;
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
        // Flush denormals to zero on this audio thread. Without this,
        // decaying filter / reverb tails hit subnormal floats and CPU spikes.
#if defined(__arm64__) || defined(__aarch64__)
        fesetenv(FE_DFL_DISABLE_DENORMS_ENV);
#elif defined(__x86_64__) || defined(__i386__)
        // MXCSR bit 15 = FTZ, bit 6 = DAZ. Together = 0x8040.
        _mm_setcsr(_mm_getcsr() | 0x8040u);
#endif
        AudioUnitRenderActionFlags pullFlags = 0;
        AUAudioUnitStatus err = pullInputBlock(&pullFlags, timestamp, frameCount, 0, outputData);
        if (err != noErr) return err;

        dsp->setHPFreq(aHP->load());
        dsp->setLowFreq(aLoF->load());
        dsp->setLowGainDB(aLoG->load());
        dsp->setHighFreq(aHiF->load());
        dsp->setHighGainDB(aHiG->load());
        dsp->setLPFreq(aLP->load());
        dsp->setLowMidFreq(aLMF->load());
        dsp->setLowMidGainDB(aLMG->load());
        dsp->setHighMidFreq(aHMF->load());
        dsp->setHighMidGainDB(aHMG->load());
        dsp->setLowQ(aLoQ->load());
        dsp->setLowMidQ(aLMQ->load());
        dsp->setHighMidQ(aHMQ->load());
        dsp->setHighQ(aHiQ->load());
        dsp->setHPSlope24(aHPSlope->load() >= 0.5f);
        dsp->setLPSlope24(aLPSlope->load() >= 0.5f);

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
        // Push mono (avg) samples into the spectrum ring buffer. Post-EQ
        // signal so the UI shows what the listener hears after the curve.
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
