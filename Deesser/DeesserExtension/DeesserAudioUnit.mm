#import "DeesserAudioUnit.h"
#import "DSP/DeesserDSP.hpp"
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

static constexpr int kRingSize = 2048;
static constexpr int kRingMask = kRingSize - 1;
static constexpr int kFFTSize  = 1024;
static constexpr int kFFTLog2  = 10;
static constexpr int kFFTBins  = kFFTSize / 2;

enum : AUParameterAddress { kF=0, kThr=1, kRng=2, kRel=3, kLst=4 };

@interface DeesserAudioUnit ()
@property (nonatomic) AUAudioUnitBusArray *inputBusArray;
@property (nonatomic) AUAudioUnitBusArray *outputBusArray;
@end

@implementation DeesserAudioUnit {
    std::vector<float> _ownOutBuf;   // scratch output (2 ch) for hosts that pass NULL mData
    std::unique_ptr<dsr::Deesser> _dsp;
    AUAudioUnitBus *_inBus, *_outBus;
    AVAudioFormat *_format;
    std::atomic<float> _freq, _thr, _rng, _rel, _listen;
    // Spectrum probe
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

- (instancetype)initWithComponentDescription:(AudioComponentDescription)d options:(AudioComponentInstantiationOptions)o error:(NSError **)e {
    self = [super initWithComponentDescription:d options:o error:e]; if (!self) return nil;
    _dsp = std::make_unique<dsr::Deesser>(); _dsp->prepare(48000);
    _sampleRate = 48000.0f;
    std::memset(_ring, 0, sizeof(_ring));
    _ringWrite.store(0);
    _hann.assign(kFFTSize, 0.0f);
    vDSP_hann_window(_hann.data(), kFFTSize, vDSP_HANN_NORM);
    _fftReal.assign(kFFTBins, 0.0f);
    _fftImag.assign(kFFTBins, 0.0f);
    _fftSetup = vDSP_create_fftsetup(kFFTLog2, kFFTRadix2);
    _format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    _inBus  = [[AUAudioUnitBus alloc] initWithFormat:_format error:nil];
    _outBus = [[AUAudioUnitBus alloc] initWithFormat:_format error:nil];
    _inputBusArray  = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:@[_inBus]];
    _outputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[_outBus]];
    [self build]; return self;
}
- (AUAudioUnitBusArray *)inputBusses  { return _inputBusArray; }
- (AUAudioUnitBusArray *)outputBusses { return _outputBusArray; }
- (float)currentGainReductionDB { return _dsp ? _dsp->currentGainReductionDB() : 0; }

- (void)build {
    AudioUnitParameterUnit Hz = kAudioUnitParameterUnit_Hertz;
    AudioUnitParameterUnit dB = kAudioUnitParameterUnit_Decibels;
    AudioUnitParameterUnit ms = kAudioUnitParameterUnit_Milliseconds;
    AudioUnitParameterUnit bo = kAudioUnitParameterUnit_Boolean;

    AUParameter *pF   = [AUParameterTree createParameterWithIdentifier:@"freq"      name:@"Frequency" address:kF   min:1000 max:12000 unit:Hz unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil]; pF.value = 6500;
    AUParameter *pT   = [AUParameterTree createParameterWithIdentifier:@"threshold" name:@"Threshold" address:kThr min:-60  max:0     unit:dB unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil]; pT.value = -32;
    AUParameter *pR   = [AUParameterTree createParameterWithIdentifier:@"range"     name:@"Range"     address:kRng min:-36  max:0     unit:dB unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil]; pR.value = -18;
    AUParameter *pRel = [AUParameterTree createParameterWithIdentifier:@"release"   name:@"Release"   address:kRel min:10   max:500   unit:ms unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil]; pRel.value = 80;
    AUParameter *pL   = [AUParameterTree createParameterWithIdentifier:@"listen"    name:@"Listen"    address:kLst min:0    max:1     unit:bo unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil]; pL.value = 0;

    _parameterTree = [AUParameterTree createTreeWithChildren:@[pF, pT, pR, pRel, pL]];
    _freq.store(6500); _thr.store(-32); _rng.store(-18); _rel.store(80); _listen.store(0);

    __weak DeesserAudioUnit *w = self;
    _parameterTree.implementorValueObserver = ^(AUParameter *p, AUValue v) {
        DeesserAudioUnit *s = w; if (!s) return;
        switch (p.address) { case kF:s->_freq.store(v);break; case kThr:s->_thr.store(v);break; case kRng:s->_rng.store(v);break; case kRel:s->_rel.store(v);break; case kLst:s->_listen.store(v);break; }
    };
    _parameterTree.implementorValueProvider = ^AUValue(AUParameter *p) {
        DeesserAudioUnit *s = w; if (!s) return 0;
        switch (p.address) { case kF:return s->_freq.load(); case kThr:return s->_thr.load(); case kRng:return s->_rng.load(); case kRel:return s->_rel.load(); case kLst:return s->_listen.load(); }
        return 0;
    };
    _parameterTree.implementorStringFromValueCallback = ^NSString *(AUParameter *p, const AUValue *vp) {
        AUValue v = vp ? *vp : p.value;
        switch (p.address) {
            case kF: return v >= 1000 ? [NSString stringWithFormat:@"%.1f kHz", v/1000.0f] : [NSString stringWithFormat:@"%.0f Hz", v];
            case kThr: return [NSString stringWithFormat:@"%.0f dB", v];
            case kRng: return [NSString stringWithFormat:@"%.0f dB", v];
            case kRel: return [NSString stringWithFormat:@"%.0f ms", v];
            case kLst: return v > 0.5f ? @"ON" : @"OFF";
        }
        return [NSString stringWithFormat:@"%.2f", v];
    };
}

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)e {
    if (![super allocateRenderResourcesAndReturnError:e]) return NO;
    _ownOutBuf.assign((size_t)MAX((AUAudioFrameCount)512, self.maximumFramesToRender) * 2, 0.0f);
    _sampleRate = (float)_outBus.format.sampleRate;
    _dsp->prepare(_sampleRate);
    return YES;
}
- (void)deallocateRenderResources { [super deallocateRenderResources]; if (_dsp) _dsp->reset(); }
- (void)dealloc { if (_fftSetup) vDSP_destroy_fftsetup(_fftSetup); }

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

/// Transport relocation / loop restart: clear tails so stale echoes don't replay.
- (void)reset { if (_dsp) _dsp->reset(); }

- (AUInternalRenderBlock)internalRenderBlock {
    __block dsr::Deesser *dsp = _dsp.get();
    __block std::atomic<float> *aF=&_freq, *aT=&_thr, *aR=&_rng, *aRel=&_rel, *aL=&_listen;
    __block float *ring = _ring;
    __block std::atomic<int> *ringWrite = &_ringWrite;
    __block std::vector<float> *ownOutBuf = &_ownOutBuf;
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *fl, const AudioTimeStamp *ts,
                              AVAudioFrameCount n, NSInteger bus, AudioBufferList *out,
                              const AURenderEvent *e, AURenderPullInputBlock pull) {
        // ── Host buffer contract ─────────────────────────────────────────
        // A host may hand us output buffers whose mData is NULL and expect the
        // AU to render into memory it owns (Logic passes real buffers, other
        // hosts and auval passes may not). Point the buffers at our scratch.
        if (out->mNumberBuffers > 0 && out->mBuffers[0].mData == NULL) {
            float *own = ownOutBuf->data(); const size_t cap = ownOutBuf->size() / 2;
            if (!own || (size_t)n > cap) return kAudioUnitErr_TooManyFramesToProcess;
            for (UInt32 b = 0; b < out->mNumberBuffers && b < 2; ++b) {
                out->mBuffers[b].mData = own + (size_t)b * cap;
                out->mBuffers[b].mDataByteSize = (UInt32)(n * sizeof(float));
            }
        }
        // No input connected (bypass / unconnected render pass): silence, not a
        // call through a NULL pull block.
        if (!pull) {
            for (UInt32 b = 0; b < out->mNumberBuffers; ++b)
                if (out->mBuffers[b].mData) memset(out->mBuffers[b].mData, 0, n * sizeof(float));
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
        AudioUnitRenderActionFlags pf = 0;
        AUAudioUnitStatus err = pull(&pf, ts, n, 0, out); if (err != noErr) return err;
        dsp->setFrequency(aF->load()); dsp->setThresholdDB(aT->load());
        dsp->setRangeDB(aR->load());   dsp->setReleaseMs(aRel->load());
        dsp->setListen(aL->load() > 0.5f);
        if (out->mNumberBuffers < 2) {
            float *m = (float *)out->mBuffers[0].mData;
            for (AVAudioFrameCount i = 0; i < n; ++i) { float L = m[i], R = m[i]; dsp->processFrame(L, R); m[i] = 0.5f * (L + R); }
        } else {
            float *L = (float *)out->mBuffers[0].mData, *R = (float *)out->mBuffers[1].mData;
            for (AVAudioFrameCount i = 0; i < n; ++i) dsp->processFrame(L[i], R[i]);
        }
        // Push processed mono samples into spectrum ring buffer.
        const float *mL = (const float *)out->mBuffers[0].mData;
        const float *mR = out->mNumberBuffers >= 2
                          ? (const float *)out->mBuffers[1].mData : mL;
        int w = ringWrite->load(std::memory_order_relaxed);
        for (AVAudioFrameCount i = 0; i < n; ++i) {
            ring[w & kRingMask] = 0.5f * (mL[i] + mR[i]);
            w++;
        }
        ringWrite->store(w, std::memory_order_relaxed);
        return noErr;
    };
}
@end
