#import "ReverbAudioUnit.h"
#include <vector>
#include <cstring>
#import "DSP/Freeverb.hpp"
#include <atomic>
#include <memory>
#include <fenv.h>
#if defined(__x86_64__) || defined(__i386__)
#include <xmmintrin.h>
#endif

enum : AUParameterAddress { kSize=0, kDecay=1, kDamp=2, kPre=3, kLo=4, kHi=5, kMix=6 };

@interface ReverbAudioUnit ()
@property (nonatomic) AUAudioUnitBusArray *inputBusArray;
@property (nonatomic) AUAudioUnitBusArray *outputBusArray;
@end

@implementation ReverbAudioUnit {
    std::atomic<float> _inLevel, _outLevel;   // block peaks for the space preview
    std::vector<float> _ownOutBuf;   // scratch output (2 ch) for hosts that pass NULL mData
    std::unique_ptr<rvb::Freeverb> _dsp;
    AUAudioUnitBus *_inBus, *_outBus;
    AVAudioFormat *_format;
    std::atomic<float> _size, _decay, _damp, _pre, _lo, _hi, _mix;
}
@synthesize parameterTree = _parameterTree;

- (instancetype)initWithComponentDescription:(AudioComponentDescription)d options:(AudioComponentInstantiationOptions)o error:(NSError **)e {
    self = [super initWithComponentDescription:d options:o error:e]; if (!self) return nil;
    _dsp = std::make_unique<rvb::Freeverb>(); _dsp->prepare(48000);
    _format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    _inBus  = [[AUAudioUnitBus alloc] initWithFormat:_format error:nil];
    _outBus = [[AUAudioUnitBus alloc] initWithFormat:_format error:nil];
    _inputBusArray  = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:@[_inBus]];
    _outputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[_outBus]];
    [self build]; return self;
}
- (AUAudioUnitBusArray *)inputBusses { return _inputBusArray; }
- (AUAudioUnitBusArray *)outputBusses { return _outputBusArray; }

- (void)build {
    AudioUnitParameterUnit g  = kAudioUnitParameterUnit_LinearGain;
    AudioUnitParameterUnit ms = kAudioUnitParameterUnit_Milliseconds;
    AudioUnitParameterUnit Hz = kAudioUnitParameterUnit_Hertz;
    AudioUnitParameterUnit sec = kAudioUnitParameterUnit_Seconds;

    AUParameter *pS = [AUParameterTree createParameterWithIdentifier:@"size"     name:@"Size"     address:kSize  min:0    max:1     unit:g  unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil]; pS.value = 0.65;
    AUParameter *pD = [AUParameterTree createParameterWithIdentifier:@"decay"    name:@"Decay"    address:kDecay min:0.5  max:8     unit:sec unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil]; pD.value = 2.1;
    AUParameter *pDm= [AUParameterTree createParameterWithIdentifier:@"damping"  name:@"Damping"  address:kDamp  min:0    max:1     unit:g  unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil]; pDm.value = 0.4;
    AUParameter *pP = [AUParameterTree createParameterWithIdentifier:@"predelay" name:@"Predelay" address:kPre   min:0    max:200   unit:ms unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil]; pP.value = 12;
    AUParameter *pLo= [AUParameterTree createParameterWithIdentifier:@"loCut"    name:@"EQ Lo"    address:kLo    min:20   max:1000  unit:Hz unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil]; pLo.value = 80;
    AUParameter *pHi= [AUParameterTree createParameterWithIdentifier:@"hiCut"    name:@"EQ Hi"    address:kHi    min:1000 max:18000 unit:Hz unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil]; pHi.value = 9000;
    AUParameter *pM = [AUParameterTree createParameterWithIdentifier:@"mix"      name:@"Mix"      address:kMix   min:0    max:1     unit:g  unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil]; pM.value = 0.35;

    _parameterTree = [AUParameterTree createTreeWithChildren:@[pS, pD, pDm, pP, pLo, pHi, pM]];
    _size.store(0.65f); _decay.store(2.1f); _damp.store(0.4f); _pre.store(12); _lo.store(80); _hi.store(9000); _mix.store(0.35f);

    __weak ReverbAudioUnit *w = self;
    _parameterTree.implementorValueObserver = ^(AUParameter *p, AUValue v) {
        ReverbAudioUnit *s = w; if (!s) return;
        switch (p.address) {
            case kSize: s->_size.store(v); break; case kDecay: s->_decay.store(v); break;
            case kDamp: s->_damp.store(v); break; case kPre: s->_pre.store(v); break;
            case kLo: s->_lo.store(v); break; case kHi: s->_hi.store(v); break;
            case kMix: s->_mix.store(v); break;
        }
    };
    _parameterTree.implementorValueProvider = ^AUValue(AUParameter *p) {
        ReverbAudioUnit *s = w; if (!s) return 0;
        switch (p.address) {
            case kSize: return s->_size.load(); case kDecay: return s->_decay.load();
            case kDamp: return s->_damp.load(); case kPre: return s->_pre.load();
            case kLo: return s->_lo.load(); case kHi: return s->_hi.load();
            case kMix: return s->_mix.load();
        }
        return 0;
    };
    _parameterTree.implementorStringFromValueCallback = ^NSString *(AUParameter *p, const AUValue *vp) {
        AUValue v = vp ? *vp : p.value;
        switch (p.address) {
            case kSize: case kDamp: return [NSString stringWithFormat:@"%.2f", v];
            case kDecay: return [NSString stringWithFormat:@"%.1f s", v];
            case kPre: return [NSString stringWithFormat:@"%.0f ms", v];
            case kLo: case kHi: return v >= 1000 ? [NSString stringWithFormat:@"%.1f kHz", v/1000] : [NSString stringWithFormat:@"%.0f Hz", v];
            case kMix: return [NSString stringWithFormat:@"%.0f%%", v * 100];
        }
        return [NSString stringWithFormat:@"%.2f", v];
    };
}

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)e { if (![super allocateRenderResourcesAndReturnError:e]) return NO; _dsp->prepare((float)_outBus.format.sampleRate); return YES; }
- (void)deallocateRenderResources { [super deallocateRenderResources]; if (_dsp) _dsp->reset(); }

/// How long the reverb keeps ringing after the input stops (DECAY = RT60, plus
/// the pre-delay). It reported 0, so hosts were free to stop rendering / cut the
/// bounce the moment the region ended.
- (NSTimeInterval)tailTime { return (double)_decay.load() + (double)_pre.load() * 0.001 + 0.25; }

/// Transport relocation / loop restart: clear tails so stale echoes don't replay.
- (void)reset { if (_dsp) _dsp->reset(); }
- (float)inputLevel  { return _inLevel.load(std::memory_order_relaxed); }
- (float)outputLevel { return _outLevel.load(std::memory_order_relaxed); }

- (AUInternalRenderBlock)internalRenderBlock {
    __block rvb::Freeverb *dsp = _dsp.get();
    __block std::atomic<float> *aS=&_size,*aD=&_decay,*aDm=&_damp,*aP=&_pre,*aLo=&_lo,*aHi=&_hi,*aM=&_mix;
    __block std::atomic<float> *aInLvl=&_inLevel,*aOutLvl=&_outLevel;
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
        dsp->setSize(aS->load()); dsp->setDecaySec(aD->load());
        dsp->setDamping(aDm->load()); dsp->setPredelayMs(aP->load());
        dsp->setLoCut(aLo->load()); dsp->setHiCut(aHi->load());
        dsp->setMix(aM->load());
        float pkIn = 0.0f, pkOut = 0.0f;
        if (out->mNumberBuffers < 2) {
            float *m = (float *)out->mBuffers[0].mData;
            for (AVAudioFrameCount i = 0; i < n; ++i) { float L=m[i], R=m[i]; pkIn = fmaxf(pkIn, fabsf(L)); dsp->processFrame(L,R); m[i] = 0.5f*(L+R); pkOut = fmaxf(pkOut, fabsf(m[i])); }
        } else {
            float *L = (float *)out->mBuffers[0].mData, *R = (float *)out->mBuffers[1].mData;
            for (AVAudioFrameCount i = 0; i < n; ++i) { pkIn = fmaxf(pkIn, fmaxf(fabsf(L[i]), fabsf(R[i]))); dsp->processFrame(L[i], R[i]); pkOut = fmaxf(pkOut, fmaxf(fabsf(L[i]), fabsf(R[i]))); }
        }
        aInLvl->store(pkIn, std::memory_order_relaxed); aOutLvl->store(pkOut, std::memory_order_relaxed);
        return noErr;
    };
}
@end
