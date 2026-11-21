//
//  CompressorAudioUnit.mm
//

#import "CompressorAudioUnit.h"
#import "DSP/CompressorDSP.hpp"
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

// ── Live FFT spectrum (ported from the EQ) ───────────────────────────────────
// 2048-sample ring, 1024-point FFT → 512 bins. Two rings (input + compressed
// output) so the visualiser shows what the compressor is doing to the spectrum.
static constexpr int kRingSize = 2048;
static constexpr int kRingMask = kRingSize - 1;
static constexpr int kFFTSize  = 1024;
static constexpr int kFFTLog2  = 10;
static constexpr int kFFTBins  = kFFTSize / 2;

// Bin one ring's most-recent window into `count` log-spaced dB bands
// (20 Hz–20 kHz), temporally smoothed (fast rise / slow fall) so the live
// spectrum reads smoothly instead of strobing.
static void binSpectrum(const float *ring, int ringWrite, FFTSetup fftSetup,
                        const float *hann, float *fftReal, float *fftImag,
                        std::vector<float> &smoothed, float *outDB, int count, float sr) {
    float buf[kFFTSize];
    const int start = (ringWrite - kFFTSize) & kRingMask;
    for (int i = 0; i < kFFTSize; ++i) buf[i] = ring[(start + i) & kRingMask];
    vDSP_vmul(buf, 1, hann, 1, buf, 1, kFFTSize);
    DSPSplitComplex sc; sc.realp = fftReal; sc.imagp = fftImag;
    vDSP_ctoz((DSPComplex *)buf, 2, &sc, 1, kFFTBins);
    vDSP_fft_zrip(fftSetup, &sc, 1, kFFTLog2, FFT_FORWARD);
    float mag2[kFFTBins];
    vDSP_zvmags(&sc, 1, mag2, 1, kFFTBins);
    const float scl = 1.0f / (float)(kFFTSize * kFFTSize * 4);
    vDSP_vsmul(mag2, 1, &scl, mag2, 1, kFFTBins);
    if ((int)smoothed.size() != count) smoothed.assign(count, -90.0f);
    const float logMin = std::log(20.0f), logMax = std::log(20000.0f);
    for (int b = 0; b < count; ++b) {
        const float t  = (float)b / std::max(1, count - 1);
        const float hz = std::exp(logMin + t * (logMax - logMin));
        const float bin = hz * (float)kFFTSize / sr;
        const int   bi = std::max(0, std::min(kFFTBins - 1, (int)std::lround(bin)));
        const float m2 = std::max(mag2[bi], 1e-12f);
        const float dB = 10.0f * std::log10(m2);
        const float prev = smoothed[b];
        const float coeff = (dB > prev) ? 0.45f : 0.16f;
        smoothed[b] = prev + (dB - prev) * coeff;
        outDB[b] = smoothed[b];
    }
}

// Parameter addresses — used by both the param tree and the audio thread.
enum : AUParameterAddress {
    kParamThreshold = 0,
    kParamRatio     = 1,
    kParamAttack    = 2,
    kParamRelease   = 3,
    kParamKnee      = 4,
    kParamMix       = 5,
    kParamDuckOn    = 6,   // 0/1 toggle
    kParamDuckRate  = 7,   // 1=whole 2=half 3=quarter 4=eighth
    kParamDuckDepth = 8,   // dB
    kParamDuckAttack = 9,  // ms — duck-specific de-click attack
};

@interface CompressorAudioUnit ()
@property (nonatomic) AUAudioUnitBusArray *inputBusArray;
@property (nonatomic) AUAudioUnitBusArray *outputBusArray;
@end

@implementation CompressorAudioUnit {
    std::vector<float> _ownOutBuf;   // scratch output (2 ch) for hosts that pass NULL mData
    std::unique_ptr<cmp::Compressor> _dsp;
    AUAudioUnitBus *_inBus;
    AUAudioUnitBus *_outBus;
    AVAudioFormat  *_format;

    // Atomic mirrors of parameter values, written from the param-tree
    // observer and read by the audio thread. AUValue is float = 4 bytes,
    // which is naturally atomic on every CPU we target.
    std::atomic<float> _threshold;
    std::atomic<float> _ratio;
    std::atomic<float> _attack;
    std::atomic<float> _release;
    std::atomic<float> _knee;
    std::atomic<float> _mix;

    // Duck params
    std::atomic<float> _duckOn;     // 0/1
    std::atomic<float> _duckRate;   // 1..4
    std::atomic<float> _duckDepth;  // dB
    std::atomic<float> _duckAtk;    // ms — duck attack (de-click)
    std::atomic<int>   _duckTrigger;// inc to fire a manual hit (UI key press)
    std::atomic<float> _hostBPM;    // populated from musicalContextBlock when present
    std::atomic<bool>  _bpmSynced;  // YES once the host has fed us a tempo

    // Live FFT spectrum probe — input ring + compressed-output ring.
    float _ringIn[kRingSize];
    float _ringOut[kRingSize];
    std::atomic<int> _ringWrite;
    FFTSetup _fftSetup;
    std::vector<float> _hann, _fftReal, _fftImag, _smoothedInDB, _smoothedOutDB;
    float _sampleRate;
}

@synthesize parameterTree = _parameterTree;

- (instancetype)initWithComponentDescription:(AudioComponentDescription)desc
                                     options:(AudioComponentInstantiationOptions)options
                                       error:(NSError * _Nullable __autoreleasing *)outError {
    self = [super initWithComponentDescription:desc options:options error:outError];
    if (!self) return nil;

    _dsp = std::make_unique<cmp::Compressor>();
    _dsp->prepare(48000.0f);

    // FFT spectrum setup (once).
    std::memset(_ringIn, 0, sizeof(_ringIn));
    std::memset(_ringOut, 0, sizeof(_ringOut));
    _ringWrite.store(0);
    _hann.assign(kFFTSize, 0.0f);
    vDSP_hann_window(_hann.data(), kFFTSize, vDSP_HANN_NORM);
    _fftReal.assign(kFFTBins, 0.0f);
    _fftImag.assign(kFFTBins, 0.0f);
    _smoothedInDB.clear(); _smoothedOutDB.clear();
    _fftSetup = vDSP_create_fftsetup(kFFTLog2, kFFTRadix2);
    _sampleRate = 48000.0f;

    _format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000.0 channels:2];
    _inBus  = [[AUAudioUnitBus alloc] initWithFormat:_format error:nil];
    _outBus = [[AUAudioUnitBus alloc] initWithFormat:_format error:nil];
    _inputBusArray  = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self
                                                             busType:AUAudioUnitBusTypeInput
                                                              busses:@[_inBus]];
    _outputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self
                                                             busType:AUAudioUnitBusTypeOutput
                                                              busses:@[_outBus]];

    [self buildParameterTree];
    return self;
}

- (AUAudioUnitBusArray *)inputBusses  { return _inputBusArray; }
- (AUAudioUnitBusArray *)outputBusses { return _outputBusArray; }

- (float)currentGainReductionDB { return _dsp ? _dsp->currentGainReductionDB() : 0.0f; }
- (NSInteger)probeSize { return (NSInteger)cmp::Compressor::probeSize(); }
- (NSInteger)readProbeIn:(float *)inOut out:(float *)outOut count:(NSInteger)count {
    if (!_dsp || count <= 0) return 0;
    int n = (int)std::min<NSInteger>(count, cmp::Compressor::probeSize());
    _dsp->readProbe(inOut, outOut, n);
    return n;
}
- (float)currentDuckDB          { return _dsp ? _dsp->currentDuckDB()         : 0.0f; }
- (float)duckPhase              { return _dsp ? _dsp->duck().phase()          : 0.0f; }
- (BOOL)duckEnabled             { return _duckOn.load() >= 0.5f; }
- (int)duckRate                 { return (int)std::round(_duckRate.load()); }
- (float)duckDepthDB            { return _duckDepth.load(); }

- (void)setDuckEnabled:(BOOL)on {
    _duckOn.store(on ? 1.0f : 0.0f);
    AUParameter *p = [_parameterTree parameterWithAddress:kParamDuckOn];
    if (p) [p setValue:(on ? 1.0f : 0.0f) originator:nil];
}
- (void)setDuckRate:(int)rate {
    int r = std::max(1, std::min(12, rate));
    _duckRate.store((float)r);
    AUParameter *p = [_parameterTree parameterWithAddress:kParamDuckRate];
    if (p) [p setValue:(float)r originator:nil];
}
- (void)setDuckDepthDB:(float)db {
    float d = std::max(0.0f, std::min(36.0f, db));
    _duckDepth.store(d);
    AUParameter *p = [_parameterTree parameterWithAddress:kParamDuckDepth];
    if (p) [p setValue:d originator:nil];
}
- (void)triggerDuck {
    _duckTrigger.fetch_add(1);
}
- (float)duckBPM { return _hostBPM.load(); }
- (BOOL)bpmSynced { return _bpmSynced.load() ? YES : NO; }
- (void)setDuckBPM:(float)bpm {
    if (bpm < 20.0f)  bpm = 20.0f;
    if (bpm > 300.0f) bpm = 300.0f;
    _hostBPM.store(bpm);
    // Manual edit clears the sync indicator so the UI shows the user
    // their value is no longer host-driven.
    _bpmSynced.store(false);
}

// ---- Parameter tree ---------------------------------------------------------

- (void)buildParameterTree {
    AudioUnitParameterUnit dB     = kAudioUnitParameterUnit_Decibels;
    AudioUnitParameterUnit ms     = kAudioUnitParameterUnit_Milliseconds;
    AudioUnitParameterUnit rateio = kAudioUnitParameterUnit_Ratio;
    AudioUnitParameterUnit mix    = kAudioUnitParameterUnit_LinearGain;

    AUParameter *pThreshold = [AUParameterTree createParameterWithIdentifier:@"threshold"
        name:@"Threshold" address:kParamThreshold min:-60.0f max:0.0f unit:dB unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable)
        valueStrings:nil dependentParameters:nil];
    pThreshold.value = -18.0f;

    AUParameter *pRatio = [AUParameterTree createParameterWithIdentifier:@"ratio"
        name:@"Ratio" address:kParamRatio min:1.0f max:20.0f unit:rateio unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable)
        valueStrings:nil dependentParameters:nil];
    pRatio.value = 4.0f;

    AUParameter *pAttack = [AUParameterTree createParameterWithIdentifier:@"attack"
        name:@"Attack" address:kParamAttack min:0.1f max:100.0f unit:ms unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable)
        valueStrings:nil dependentParameters:nil];
    pAttack.value = 5.0f;

    AUParameter *pRelease = [AUParameterTree createParameterWithIdentifier:@"release"
        name:@"Release" address:kParamRelease min:5.0f max:2000.0f unit:ms unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable)
        valueStrings:nil dependentParameters:nil];
    pRelease.value = 80.0f;

    AUParameter *pKnee = [AUParameterTree createParameterWithIdentifier:@"knee"
        name:@"Knee" address:kParamKnee min:0.0f max:24.0f unit:dB unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable)
        valueStrings:nil dependentParameters:nil];
    pKnee.value = 6.0f;

    AUParameter *pMix = [AUParameterTree createParameterWithIdentifier:@"mix"
        name:@"Mix" address:kParamMix min:0.0f max:1.0f unit:mix unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable)
        valueStrings:nil dependentParameters:nil];
    pMix.value = 1.0f;

    AUParameter *pDuck = [AUParameterTree createParameterWithIdentifier:@"duckOn"
        name:@"Duck" address:kParamDuckOn min:0.0f max:1.0f unit:kAudioUnitParameterUnit_Boolean unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable)
        valueStrings:nil dependentParameters:nil];
    pDuck.value = 0.0f;

    AUParameter *pDuckRate = [AUParameterTree createParameterWithIdentifier:@"duckRate"
        name:@"Duck Rate" address:kParamDuckRate min:1.0f max:12.0f unit:kAudioUnitParameterUnit_Indexed unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable)
        valueStrings:@[@"1/1", @"1/2", @"1/4", @"1/8", @"1/16",
                       @"DOT Q", @"SWING", @"HOUSE", @"TRAP",
                       @"DUB", @"RAGGA", @"REGGAE"] dependentParameters:nil];
    pDuckRate.value = 3.0f;

    AUParameter *pDuckDepth = [AUParameterTree createParameterWithIdentifier:@"duckDepth"
        name:@"Duck Depth" address:kParamDuckDepth min:0.0f max:36.0f unit:dB unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable)
        valueStrings:nil dependentParameters:nil];
    pDuckDepth.value = 9.0f;

    AUParameter *pDuckAttack = [AUParameterTree createParameterWithIdentifier:@"duckAttack"
        name:@"Duck Attack" address:kParamDuckAttack min:0.1f max:50.0f unit:kAudioUnitParameterUnit_Milliseconds unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable)
        valueStrings:nil dependentParameters:nil];
    pDuckAttack.value = 3.0f;

    _parameterTree = [AUParameterTree createTreeWithChildren:@[pThreshold, pRatio, pAttack, pRelease, pKnee, pMix, pDuck, pDuckRate, pDuckDepth, pDuckAttack]];

    // Seed the atomic mirrors with the defaults.
    _threshold.store(-18.0f);
    _ratio.store(4.0f);
    _attack.store(5.0f);
    _release.store(80.0f);
    _knee.store(6.0f);
    _mix.store(1.0f);
    _duckOn.store(0.0f);
    _duckRate.store(3.0f);
    _duckDepth.store(9.0f);
    _duckAtk.store(3.0f);
    _duckTrigger.store(0);
    _hostBPM.store(120.0f);
    _bpmSynced.store(false);

    __weak CompressorAudioUnit *weakSelf = self;
    _parameterTree.implementorValueObserver = ^(AUParameter *param, AUValue value) {
        CompressorAudioUnit *strong = weakSelf;
        if (!strong) return;
        switch (param.address) {
            case kParamThreshold: strong->_threshold.store(value); break;
            case kParamRatio:     strong->_ratio.store(value);     break;
            case kParamAttack:    strong->_attack.store(value);    break;
            case kParamRelease:   strong->_release.store(value);   break;
            case kParamKnee:      strong->_knee.store(value);      break;
            case kParamMix:       strong->_mix.store(value);       break;
            case kParamDuckOn:    strong->_duckOn.store(value);    break;
            case kParamDuckRate:  strong->_duckRate.store(value);  break;
            case kParamDuckDepth: strong->_duckDepth.store(value); break;
            case kParamDuckAttack: strong->_duckAtk.store(value); break;
        }
    };
    _parameterTree.implementorValueProvider = ^AUValue(AUParameter *param) {
        CompressorAudioUnit *strong = weakSelf;
        if (!strong) return 0;
        switch (param.address) {
            case kParamThreshold: return strong->_threshold.load();
            case kParamRatio:     return strong->_ratio.load();
            case kParamAttack:    return strong->_attack.load();
            case kParamRelease:   return strong->_release.load();
            case kParamKnee:      return strong->_knee.load();
            case kParamMix:       return strong->_mix.load();
            case kParamDuckOn:    return strong->_duckOn.load();
            case kParamDuckRate:  return strong->_duckRate.load();
            case kParamDuckDepth: return strong->_duckDepth.load();
            case kParamDuckAttack: return strong->_duckAtk.load();
        }
        return 0;
    };
    _parameterTree.implementorStringFromValueCallback = ^NSString *(AUParameter *param, const AUValue *valuePtr) {
        AUValue v = valuePtr ? *valuePtr : param.value;
        switch (param.address) {
            case kParamThreshold: return [NSString stringWithFormat:@"%.1f dB", v];
            case kParamRatio:     return [NSString stringWithFormat:@"%.1f:1", v];
            case kParamAttack:    return [NSString stringWithFormat:@"%.1f ms", v];
            case kParamRelease:   return [NSString stringWithFormat:@"%.0f ms", v];
            case kParamKnee:      return [NSString stringWithFormat:@"%.1f dB", v];
            case kParamMix:       return [NSString stringWithFormat:@"%.0f%%", v * 100.0f];
            case kParamDuckOn:    return v >= 0.5f ? @"ON" : @"OFF";
            case kParamDuckRate: {
                int r = (int)std::round(v);
                static NSString *labels[] = {
                    @"1/1", @"1/2", @"1/4", @"1/8", @"1/16",
                    @"DOT Q", @"SWING", @"HOUSE", @"TRAP",
                    @"DUB", @"RAGGA", @"REGGAE"
                };
                return labels[std::max(0, std::min(11, r - 1))];
            }
            case kParamDuckDepth: return [NSString stringWithFormat:@"%.1f dB", v];
            case kParamDuckAttack: return [NSString stringWithFormat:@"%.1f ms", v];
        }
        return [NSString stringWithFormat:@"%.2f", v];
    };
}

// ---- Render -----------------------------------------------------------------

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)outError {
    if (![super allocateRenderResourcesAndReturnError:outError]) return NO;
    _ownOutBuf.assign((size_t)MAX((AUAudioFrameCount)512, self.maximumFramesToRender) * 2, 0.0f);
    const float sr = (float)_outBus.format.sampleRate;
    _sampleRate = sr;
    _dsp->prepare(sr);
    return YES;
}

- (void)deallocateRenderResources {
    [super deallocateRenderResources];
    if (_dsp) _dsp->reset();
}

- (void)dealloc {
    if (_fftSetup) vDSP_destroy_fftsetup(_fftSetup);
}

// Live spectrum — fills `inDB` (input) and `outDB` (compressed output) with
// `count` log-spaced dB bands. The UI draws them as a smooth EQ-style analyzer.
- (BOOL)readSpectrumIn:(float *)inDB out:(float *)outDB count:(NSInteger)count {
    if (!_fftSetup || count <= 0 || !inDB || !outDB) return NO;
    const int w = _ringWrite.load(std::memory_order_relaxed);
    binSpectrum(_ringIn,  w, _fftSetup, _hann.data(), _fftReal.data(), _fftImag.data(), _smoothedInDB,  inDB,  (int)count, _sampleRate);
    binSpectrum(_ringOut, w, _fftSetup, _hann.data(), _fftReal.data(), _fftImag.data(), _smoothedOutDB, outDB, (int)count, _sampleRate);
    return YES;
}

/// Transport relocation / loop restart: clear tails so stale echoes don't replay.
- (void)reset { if (_dsp) _dsp->reset(); }

- (AUInternalRenderBlock)internalRenderBlock {
    __block cmp::Compressor *dsp = _dsp.get();
    __block std::atomic<float> *aThr     = &_threshold;
    __block std::atomic<float> *aRat     = &_ratio;
    __block std::atomic<float> *aAtk     = &_attack;
    __block std::atomic<float> *aRel     = &_release;
    __block std::atomic<float> *aKne     = &_knee;
    __block std::atomic<float> *aMix     = &_mix;
    __block std::atomic<float> *aDuckOn  = &_duckOn;
    __block std::atomic<float> *aDuckR   = &_duckRate;
    __block std::atomic<float> *aDuckD   = &_duckDepth;
    __block std::atomic<float> *aDuckAtk = &_duckAtk;
    __block std::atomic<int>   *aDuckTrg = &_duckTrigger;
    __block std::atomic<float> *aHostBPM = &_hostBPM;
    __block std::atomic<bool>  *aBpmSyn  = &_bpmSynced;
    __block float *ringIn = _ringIn; __block float *ringOut = _ringOut;
    __block std::atomic<int> *ringW = &_ringWrite;
    __block int lastTrigSeen = 0;
    // Snapshot the host musical-context block. Logic provides this; standalone
    // hosts may not. We read tempo from it every render slice so the duck
    // stays locked to the Logic project BPM as the user changes it.
    AUHostMusicalContextBlock musicalCtx = self.musicalContextBlock;

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
        // Pull the input.
        AudioUnitRenderActionFlags pullFlags = 0;
        AUAudioUnitStatus err = pullInputBlock(&pullFlags, timestamp, frameCount, 0, outputData);
        if (err != noErr) return err;

        // Pull the live tempo from Logic's transport so the Duck stays in
        // sync with the project BPM. Falls back to whatever _hostBPM holds
        // (120 default, or the user-typed value) when no host context.
        if (musicalCtx) {
            double tempo = 0.0;
            if (musicalCtx(&tempo, NULL, NULL, NULL, NULL, NULL) && tempo > 0.0) {
                aHostBPM->store((float)tempo);
                aBpmSyn->store(true);
            }
        }

        // Refresh DSP parameters once per render slice. This is conservative
        // (no per-sample smoothing) but plenty for compressor controls.
        dsp->setThresholdDB(aThr->load());
        dsp->setRatio(aRat->load());
        dsp->setAttackMs(aAtk->load());
        dsp->setReleaseMs(aRel->load());
        dsp->setKneeDB(aKne->load());
        dsp->setMix(aMix->load());

        // Duck params
        dsp->duck().setEnabled(aDuckOn->load() >= 0.5f);
        dsp->duck().setBPM(aHostBPM->load());
        dsp->duck().setRate((int)std::round(aDuckR->load()));
        dsp->duck().setDepthDB(aDuckD->load());
        dsp->duck().setAttackMs(aDuckAtk->load());
        const int trig = aDuckTrg->load();
        if (trig != lastTrigSeen) { dsp->duck().manualTrigger(); lastTrigSeen = trig; }

        int rw = ringW->load(std::memory_order_relaxed);
        if (outputData->mNumberBuffers < 2) {
            // Mono fallback — duplicate channel through the stereo DSP.
            float *m = (float *)outputData->mBuffers[0].mData;
            for (AVAudioFrameCount i = 0; i < frameCount; ++i) {
                float l = m[i], r = m[i];
                const float inM = 0.5f * (l + r);
                dsp->processFrame(l, r);
                const float outM = 0.5f * (l + r);
                m[i] = outM;
                ringIn[rw & kRingMask] = inM; ringOut[rw & kRingMask] = outM; rw++;
            }
        } else {
            float *L = (float *)outputData->mBuffers[0].mData;
            float *R = (float *)outputData->mBuffers[1].mData;
            for (AVAudioFrameCount i = 0; i < frameCount; ++i) {
                const float inM = 0.5f * (L[i] + R[i]);
                dsp->processFrame(L[i], R[i]);
                const float outM = 0.5f * (L[i] + R[i]);
                ringIn[rw & kRingMask] = inM; ringOut[rw & kRingMask] = outM; rw++;
            }
        }
        ringW->store(rw, std::memory_order_relaxed);
        return noErr;
    };
}

@end
