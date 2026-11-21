#import "DelayAudioUnit.h"
#include <vector>
#include <cstring>
#import "DSP/DelayLine.hpp"
#include <atomic>
#include <memory>
#include <fenv.h>
#if defined(__x86_64__) || defined(__i386__)
#include <xmmintrin.h>
#endif

enum : AUParameterAddress { kTL=0, kTR=1, kFB=2, kFlt=3, kMix=4, kPP=5,
                            kBass=6, kWob=7, kWobR=8, kWarm=9,
                            kSync=10, kDivL=11, kDivR=12 };

// Note-division table (index → beats). Shared with the Swift UI through the
// class methods below so both sides agree on order + names.
static const int   kDivCount = 11;
static const float kDivBeats[kDivCount] = { 0.125f, 0.25f, 1.0f/6.0f, 0.375f, 0.5f, 1.0f/3.0f, 0.75f, 1.0f, 2.0f/3.0f, 1.5f, 2.0f };
static NSString * const kDivNames[kDivCount] = { @"1/32", @"1/16", @"1/16T", @"1/16D", @"1/8", @"1/8T", @"1/8D", @"1/4", @"1/4T", @"1/4D", @"1/2" };

static inline float clampf_(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

@interface DelayAudioUnit ()
@property (nonatomic) AUAudioUnitBusArray *inputBusArray;
@property (nonatomic) AUAudioUnitBusArray *outputBusArray;
@end

@implementation DelayAudioUnit {
    std::vector<float> _ownOutBuf;   // scratch output (2 ch) for hosts that pass NULL mData
    std::unique_ptr<dly::StereoDelay> _dsp;
    AUAudioUnitBus *_inBus, *_outBus;
    AVAudioFormat *_format;
    std::atomic<float> _tL, _tR, _fb, _flt, _mix, _pp;
    std::atomic<float> _bass, _wob, _wobR, _warm;
    std::atomic<float> _sync, _divL, _divR;
    std::atomic<float> _hostBPM, _effL, _effR;
    std::atomic<bool>  _bpmSynced;
}
@synthesize parameterTree = _parameterTree;

+ (int)divisionCount { return kDivCount; }
static inline float beatsForDivisionC(int index) { return (index >= 0 && index < kDivCount) ? kDivBeats[index] : 0.5f; }
+ (float)beatsForDivision:(int)index { return beatsForDivisionC(index); }
+ (NSString *)divisionName:(int)index { return (index >= 0 && index < kDivCount) ? kDivNames[index] : @"1/8"; }

- (float)hostBPM { return _hostBPM.load(); }
- (BOOL)bpmSynced { return _bpmSynced.load(); }
- (float)effectiveTimeL { return _effL.load(); }
- (float)effectiveTimeR { return _effR.load(); }

- (instancetype)initWithComponentDescription:(AudioComponentDescription)d options:(AudioComponentInstantiationOptions)o error:(NSError **)e {
    self = [super initWithComponentDescription:d options:o error:e]; if (!self) return nil;
    _dsp = std::make_unique<dly::StereoDelay>(); _dsp->prepare(48000);
    _format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    _inBus = [[AUAudioUnitBus alloc] initWithFormat:_format error:nil];
    _outBus = [[AUAudioUnitBus alloc] initWithFormat:_format error:nil];
    _inputBusArray  = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:@[_inBus]];
    _outputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[_outBus]];
    _hostBPM.store(120.0f); _bpmSynced.store(false);
    _effL.store(250.0f); _effR.store(375.0f);
    [self build]; return self;
}
- (AUAudioUnitBusArray *)inputBusses { return _inputBusArray; }
- (AUAudioUnitBusArray *)outputBusses { return _outputBusArray; }

- (void)build {
    AudioUnitParameterUnit ms = kAudioUnitParameterUnit_Milliseconds;
    AudioUnitParameterUnit Hz = kAudioUnitParameterUnit_Hertz;
    AudioUnitParameterUnit g  = kAudioUnitParameterUnit_LinearGain;
    AudioUnitParameterUnit bo = kAudioUnitParameterUnit_Boolean;
    AudioUnitParameterUnit ix = kAudioUnitParameterUnit_Indexed;
    AudioUnitParameterOptions rw = kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable;
    NSArray<NSString *> *divNames = [NSArray arrayWithObjects:kDivNames count:kDivCount];

    AUParameter *pTL = [AUParameterTree createParameterWithIdentifier:@"timeL"   name:@"Time L"   address:kTL  min:1   max:2000  unit:ms unitName:nil flags:rw valueStrings:nil dependentParameters:nil]; pTL.value = 250;
    AUParameter *pTR = [AUParameterTree createParameterWithIdentifier:@"timeR"   name:@"Time R"   address:kTR  min:1   max:2000  unit:ms unitName:nil flags:rw valueStrings:nil dependentParameters:nil]; pTR.value = 375;
    AUParameter *pFB = [AUParameterTree createParameterWithIdentifier:@"feedback" name:@"Feedback" address:kFB  min:0   max:0.95  unit:g  unitName:nil flags:rw valueStrings:nil dependentParameters:nil]; pFB.value = 0.42;
    AUParameter *pFL = [AUParameterTree createParameterWithIdentifier:@"filter"  name:@"High"     address:kFlt min:200 max:18000 unit:Hz unitName:nil flags:rw valueStrings:nil dependentParameters:nil]; pFL.value = 3200;
    AUParameter *pM  = [AUParameterTree createParameterWithIdentifier:@"mix"     name:@"Mix"      address:kMix min:0   max:1     unit:g  unitName:nil flags:rw valueStrings:nil dependentParameters:nil]; pM.value = 0.28;
    AUParameter *pP  = [AUParameterTree createParameterWithIdentifier:@"pingpong" name:@"Ping-Pong" address:kPP  min:0   max:1     unit:bo unitName:nil flags:rw valueStrings:nil dependentParameters:nil]; pP.value = 1;
    // ── Dub controls ──────────────────────────────────────────────────────
    AUParameter *pBs = [AUParameterTree createParameterWithIdentifier:@"bass"    name:@"Bass Cut" address:kBass min:20 max:1200 unit:Hz unitName:nil flags:rw valueStrings:nil dependentParameters:nil]; pBs.value = 120;
    AUParameter *pWb = [AUParameterTree createParameterWithIdentifier:@"wobble"  name:@"Wobble"   address:kWob  min:0  max:1    unit:g  unitName:nil flags:rw valueStrings:nil dependentParameters:nil]; pWb.value = 0;
    AUParameter *pWr = [AUParameterTree createParameterWithIdentifier:@"wobrate" name:@"Rate"     address:kWobR min:0.02 max:12 unit:Hz unitName:nil flags:rw valueStrings:nil dependentParameters:nil]; pWr.value = 1.0;
    AUParameter *pWm = [AUParameterTree createParameterWithIdentifier:@"warmth"  name:@"Warmth"   address:kWarm min:0  max:1    unit:g  unitName:nil flags:rw valueStrings:nil dependentParameters:nil]; pWm.value = 0.35;
    // ── Tempo sync — note divisions × Logic's tempo replace the TIME knobs ──
    AUParameter *pSy = [AUParameterTree createParameterWithIdentifier:@"sync"    name:@"Sync"     address:kSync min:0  max:1    unit:bo unitName:nil flags:rw valueStrings:nil dependentParameters:nil]; pSy.value = 0;
    AUParameter *pDL = [AUParameterTree createParameterWithIdentifier:@"divL"    name:@"Div L"    address:kDivL min:0  max:kDivCount-1 unit:ix unitName:nil flags:rw valueStrings:divNames dependentParameters:nil]; pDL.value = 4;   // 1/8
    AUParameter *pDR = [AUParameterTree createParameterWithIdentifier:@"divR"    name:@"Div R"    address:kDivR min:0  max:kDivCount-1 unit:ix unitName:nil flags:rw valueStrings:divNames dependentParameters:nil]; pDR.value = 6;   // 1/8D

    _parameterTree = [AUParameterTree createTreeWithChildren:@[pTL, pTR, pFB, pFL, pM, pP, pBs, pWb, pWr, pWm, pSy, pDL, pDR]];
    _tL.store(250); _tR.store(375); _fb.store(0.42f); _flt.store(3200); _mix.store(0.28f); _pp.store(1);
    _bass.store(120); _wob.store(0); _wobR.store(1.0f); _warm.store(0.35f);
    _sync.store(0); _divL.store(4); _divR.store(6);

    __weak DelayAudioUnit *w = self;
    _parameterTree.implementorValueObserver = ^(AUParameter *p, AUValue v) {
        DelayAudioUnit *s = w; if (!s) return;
        switch (p.address) {
            case kTL:s->_tL.store(v);break; case kTR:s->_tR.store(v);break;
            case kFB:s->_fb.store(v);break; case kFlt:s->_flt.store(v);break;
            case kMix:s->_mix.store(v);break; case kPP:s->_pp.store(v);break;
            case kBass:s->_bass.store(v);break; case kWob:s->_wob.store(v);break;
            case kWobR:s->_wobR.store(v);break; case kWarm:s->_warm.store(v);break;
            case kSync:s->_sync.store(v);break; case kDivL:s->_divL.store(v);break;
            case kDivR:s->_divR.store(v);break;
        }
    };
    _parameterTree.implementorValueProvider = ^AUValue(AUParameter *p) {
        DelayAudioUnit *s = w; if (!s) return 0;
        switch (p.address) {
            case kTL:return s->_tL.load(); case kTR:return s->_tR.load();
            case kFB:return s->_fb.load(); case kFlt:return s->_flt.load();
            case kMix:return s->_mix.load(); case kPP:return s->_pp.load();
            case kBass:return s->_bass.load(); case kWob:return s->_wob.load();
            case kWobR:return s->_wobR.load(); case kWarm:return s->_warm.load();
            case kSync:return s->_sync.load(); case kDivL:return s->_divL.load();
            case kDivR:return s->_divR.load();
        }
        return 0;
    };
    _parameterTree.implementorStringFromValueCallback = ^NSString *(AUParameter *p, const AUValue *vp) {
        AUValue v = vp ? *vp : p.value;
        switch (p.address) {
            case kTL: case kTR: return [NSString stringWithFormat:@"%.0f ms", v];
            case kFB: case kMix: case kWob: case kWarm: return [NSString stringWithFormat:@"%.0f%%", v * 100];
            case kFlt: case kBass: return v >= 1000 ? [NSString stringWithFormat:@"%.1f kHz", v/1000] : [NSString stringWithFormat:@"%.0f Hz", v];
            case kWobR: return [NSString stringWithFormat:@"%.2f Hz", v];
            case kPP: case kSync: return v > 0.5 ? @"ON" : @"OFF";
            case kDivL: case kDivR: return [DelayAudioUnit divisionName:(int)lrintf(v)];
        }
        return [NSString stringWithFormat:@"%.2f", v];
    };
}

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)e { if (![super allocateRenderResourcesAndReturnError:e]) return NO; _dsp->prepare((float)_outBus.format.sampleRate); return YES; }
- (void)deallocateRenderResources { [super deallocateRenderResources]; if (_dsp) _dsp->reset(); }

/// Time for the repeats to fall 60 dB after the input stops: one pass through
/// the longer delay per 20·log10(FEEDBACK) dB. It reported 0, so hosts were
/// free to stop rendering / cut a bounce as soon as the region ended.
- (NSTimeInterval)tailTime {
    const double t  = fmax((double)_effL.load(), (double)_effR.load()) * 0.001;     // seconds
    const double fb = fmin(0.98, fmax(0.0, (double)_fb.load()));
    const double passes = fb > 0.001 ? ceil(-60.0 / (20.0 * log10(fb))) : 0.0;
    return fmin(120.0, t * (passes + 1.0) + 0.1);
}

/// Transport relocation / loop restart: clear tails so stale echoes don't replay.
- (void)reset { if (_dsp) _dsp->reset(); }

- (AUInternalRenderBlock)internalRenderBlock {
    __block dly::StereoDelay *dsp = _dsp.get();
    __block std::atomic<float> *aTL=&_tL,*aTR=&_tR,*aFB=&_fb,*aF=&_flt,*aM=&_mix,*aPP=&_pp;
    __block std::atomic<float> *aBs=&_bass,*aWb=&_wob,*aWr=&_wobR,*aWm=&_warm;
    __block std::atomic<float> *aSync=&_sync,*aDivL=&_divL,*aDivR=&_divR;
    __block std::atomic<float> *aBPM=&_hostBPM,*aEffL=&_effL,*aEffR=&_effR;
    __block std::atomic<bool>  *aSynced=&_bpmSynced;
    // Re-fetch the host musical-context block every slice (StringThing
    // pattern): Logic may install it after this render block was created.
    __unsafe_unretained DelayAudioUnit *unsafeSelf = self;
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

        // Host tempo (Logic feeds it through musicalContextBlock).
        AUHostMusicalContextBlock mctx = unsafeSelf.musicalContextBlock;
        if (mctx) {
            double tempo = 0.0;
            if (mctx(&tempo, NULL, NULL, NULL, NULL, NULL) && tempo > 0.0) {
                aBPM->store((float)tempo);
                aSynced->store(true);
            }
        }

        // TIME: knobs, or note division × tempo when SYNC is on.
        float tL = aTL->load(), tR = aTR->load();
        if (aSync->load() > 0.5f) {
            const float msPerBeat = 60000.0f / std::max(20.0f, aBPM->load());
            const int dL = (int)lrintf(aDivL->load()), dR = (int)lrintf(aDivR->load());
            tL = clampf_(beatsForDivisionC(dL) * msPerBeat, 1.0f, 2000.0f);   // plain C on the audio thread
            tR = clampf_(beatsForDivisionC(dR) * msPerBeat, 1.0f, 2000.0f);
        }
        aEffL->store(tL); aEffR->store(tR);

        dsp->setTimes(tL, tR);
        dsp->setFeedback(aFB->load());
        dsp->setFilterFreq(aF->load());
        dsp->setMix(aM->load());
        dsp->setPingPong(aPP->load() > 0.5f);
        dsp->setBass(aBs->load());
        dsp->setWobble(aWb->load());
        dsp->setWobbleRate(aWr->load());
        dsp->setWarmth(aWm->load());
        if (out->mNumberBuffers < 2) {
            float *m = (float *)out->mBuffers[0].mData;
            for (AVAudioFrameCount i = 0; i < n; ++i) { float L=m[i], R=m[i]; dsp->processFrame(L,R); m[i] = 0.5f*(L+R); }
        } else {
            float *L = (float *)out->mBuffers[0].mData, *R = (float *)out->mBuffers[1].mData;
            for (AVAudioFrameCount i = 0; i < n; ++i) dsp->processFrame(L[i], R[i]);
        }
        return noErr;
    };
}
@end
