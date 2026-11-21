#import "PitchKnobAudioUnit.h"
#include <vector>
#include <cstring>
#import "DSP/PitchKnobDSP.hpp"
#include <atomic>
#include <memory>
#include <fenv.h>
#if defined(__x86_64__) || defined(__i386__)
#include <xmmintrin.h>
#endif

enum : AUParameterAddress { kKnob = 0, kDist = 1 };

@interface PitchKnobAudioUnit ()
@property (nonatomic) AUAudioUnitBusArray *inputBusArray;
@property (nonatomic) AUAudioUnitBusArray *outputBusArray;
@end

@implementation PitchKnobAudioUnit {
    std::vector<float> _ownOutBuf;   // scratch output (2 ch) for hosts that pass NULL mData
    std::unique_ptr<pkn::PitchKnobEngine> _dsp;
    AUAudioUnitBus *_inBus;
    AUAudioUnitBus *_outBus;
    AVAudioFormat *_format;
    std::atomic<float> _knob;
    std::atomic<float> _dist;
}
@synthesize parameterTree = _parameterTree;

- (instancetype)initWithComponentDescription:(AudioComponentDescription)d options:(AudioComponentInstantiationOptions)o error:(NSError **)e {
    self = [super initWithComponentDescription:d options:o error:e]; if (!self) return nil;
    _dsp = std::make_unique<pkn::PitchKnobEngine>(); _dsp->prepare(48000);
    _format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    _inBus  = [[AUAudioUnitBus alloc] initWithFormat:_format error:nil];
    _outBus = [[AUAudioUnitBus alloc] initWithFormat:_format error:nil];
    _inputBusArray  = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput  busses:@[_inBus]];
    _outputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[_outBus]];

    AUParameter *p = [AUParameterTree createParameterWithIdentifier:@"knob" name:@"Pitch"
        address:kKnob min:0 max:1 unit:kAudioUnitParameterUnit_LinearGain unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable)
        valueStrings:nil dependentParameters:nil];
    p.value = 0.5f;
    AUParameter *pd = [AUParameterTree createParameterWithIdentifier:@"filter" name:@"Filter"
        address:kDist min:0 max:1 unit:kAudioUnitParameterUnit_LinearGain unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable)
        valueStrings:nil dependentParameters:nil];
    pd.value = 0.5f;
    _parameterTree = [AUParameterTree createTreeWithChildren:@[p, pd]];
    _knob.store(0.5f);
    _dist.store(0.5f);

    __weak PitchKnobAudioUnit *w = self;
    _parameterTree.implementorValueObserver = ^(AUParameter *pp, AUValue v) {
        PitchKnobAudioUnit *s = w; if (!s) return;
        if (pp.address == kDist) s->_dist.store(v); else s->_knob.store(v);
    };
    _parameterTree.implementorValueProvider = ^AUValue(AUParameter *pp) {
        PitchKnobAudioUnit *s = w; if (!s) return 0;
        return (pp.address == kDist) ? s->_dist.load() : s->_knob.load();
    };
    _parameterTree.implementorStringFromValueCallback = ^NSString *(AUParameter *pp, const AUValue *vp) {
        const float v = vp ? *vp : pp.value;
        if (pp.address == kDist) {
            // Centre FILTER knob.
            if (std::fabs(v - 0.5f) < 0.005f) return @"OPEN";
            if (v < 0.5f) {
                const float t = (0.5f - v) * 2.0f;
                const float fc = 18000.0f * std::pow(80.0f / 18000.0f, t);
                return [NSString stringWithFormat:@"LP %.0fHz", fc];
            }
            const float t = (v - 0.5f) * 2.0f;
            const float fc = 20.0f * std::pow(8000.0f / 20.0f, t);
            return [NSString stringWithFormat:@"HP %.0fHz", fc];
        }
        // Big PITCH knob.
        const float semi = (v - 0.5f) * 24.0f;
        if (std::fabs(semi) < 0.05f) return @"UNISON";
        return [NSString stringWithFormat:@"%+.1f st", semi];
    };
    return self;
}

- (AUAudioUnitBusArray *)inputBusses  { return _inputBusArray; }
- (AUAudioUnitBusArray *)outputBusses { return _outputBusArray; }

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)e {
    if (![super allocateRenderResourcesAndReturnError:e]) return NO;
    _ownOutBuf.assign((size_t)MAX((AUAudioFrameCount)512, self.maximumFramesToRender) * 2, 0.0f);
    _dsp->setPitch(_knob.load()); _dsp->setFilter(_dist.load());   // settle on the current values
    _dsp->prepare((float)_outBus.format.sampleRate);
    return YES;
}
- (void)deallocateRenderResources { [super deallocateRenderResources]; if (_dsp) _dsp->reset(); }
/// The granular shifter is centred half a grain back (16 ms at 48 k); report
/// it so the host's delay compensation keeps the track in time.
- (NSTimeInterval)latency {
    const double sr = _outBus.format.sampleRate > 0 ? _outBus.format.sampleRate : 48000.0;
    // half a 32 ms grain at every sample rate (768 samples at 48 kHz, as before)
    return (double)(std::max(256, std::min(8192, 2 * (int)std::lround(0.016 * sr))) / 2) / sr;
}

/// Transport relocation / loop restart: clear tails so stale echoes don't replay.
- (void)reset { if (_dsp) _dsp->reset(); }

- (AUInternalRenderBlock)internalRenderBlock {
    __block pkn::PitchKnobEngine *dsp = _dsp.get();
    __block std::atomic<float> *aK = &_knob;
    __block std::atomic<float> *aDist = &_dist;
    __block std::vector<float> *ownOutBuf = &_ownOutBuf;
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *fl, const AudioTimeStamp *ts,
                              AVAudioFrameCount n, NSInteger bus, AudioBufferList *out,
                              const AURenderEvent *evt, AURenderPullInputBlock pull) {
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
        AUAudioUnitStatus err = pull(&pf, ts, n, 0, out);
        if (err != noErr) return err;

        dsp->setPitch(aK->load());
        dsp->setFilter(aDist->load());

        if (out->mNumberBuffers < 2) {
            float *m = (float *)out->mBuffers[0].mData;
            for (AVAudioFrameCount i = 0; i < n; ++i) {
                float l = m[i], r = m[i];
                dsp->processFrame(l, r);
                m[i] = 0.5f * (l + r);
            }
        } else {
            float *L = (float *)out->mBuffers[0].mData;
            float *R = (float *)out->mBuffers[1].mData;
            for (AVAudioFrameCount i = 0; i < n; ++i) {
                dsp->processFrame(L[i], R[i]);
            }
        }
        return noErr;
    };
}
@end
