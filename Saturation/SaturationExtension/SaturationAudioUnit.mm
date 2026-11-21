#import "SaturationAudioUnit.h"
#include <vector>
#include <cstring>
#import "DSP/SaturationDSP.hpp"
#include <atomic>
#include <memory>
#include <fenv.h>
#if defined(__x86_64__) || defined(__i386__)
#include <xmmintrin.h>
#endif

enum : AUParameterAddress { kDrive=0, kBias=1, kTone=2, kMix=3, kOut=4 };

@interface SaturationAudioUnit ()
@property (nonatomic) AUAudioUnitBusArray *inputBusArray;
@property (nonatomic) AUAudioUnitBusArray *outputBusArray;
@end

@implementation SaturationAudioUnit {
    std::vector<float> _ownOutBuf;   // scratch output (2 ch) for hosts that pass NULL mData
    std::unique_ptr<sat::Saturation> _dsp;
    AUAudioUnitBus *_inBus, *_outBus;
    AVAudioFormat  *_format;
    std::atomic<float> _drive, _bias, _tone, _mix, _out;
    std::atomic<float> _meter;   // live output peak (0..1) for the UI visualizer
}
@synthesize parameterTree = _parameterTree;

- (float)currentLevel { return _meter.load(std::memory_order_relaxed); }

- (instancetype)initWithComponentDescription:(AudioComponentDescription)desc
                                     options:(AudioComponentInstantiationOptions)opt
                                       error:(NSError **)err {
    self = [super initWithComponentDescription:desc options:opt error:err];
    if (!self) return nil;
    _dsp = std::make_unique<sat::Saturation>(); _dsp->prepare(48000);
    _format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    _inBus  = [[AUAudioUnitBus alloc] initWithFormat:_format error:nil];
    _outBus = [[AUAudioUnitBus alloc] initWithFormat:_format error:nil];
    _inputBusArray  = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput  busses:@[_inBus]];
    _outputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[_outBus]];
    [self build];
    return self;
}
- (AUAudioUnitBusArray *)inputBusses  { return _inputBusArray; }
- (AUAudioUnitBusArray *)outputBusses { return _outputBusArray; }

- (float)transferAt:(float)x {
    // Build a temporary DSP-shape evaluation using current params — only the
    // pure transfer (no tilt / no mix / no output).
    sat::Saturation s; s.prepare(48000);
    s.setDriveDB(_drive.load()); s.setBias(_bias.load());
    return s.transfer(x);
}

- (void)build {
    AudioUnitParameterUnit dB = kAudioUnitParameterUnit_Decibels;
    AudioUnitParameterUnit g  = kAudioUnitParameterUnit_LinearGain;

    AUParameter *pD = [AUParameterTree createParameterWithIdentifier:@"drive" name:@"Drive" address:kDrive min:-12 max:24 unit:dB unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil]; pD.value = 8;
    AUParameter *pB = [AUParameterTree createParameterWithIdentifier:@"bias"  name:@"Bias"  address:kBias  min:-1 max:1  unit:g  unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil]; pB.value = 0.15;
    AUParameter *pT = [AUParameterTree createParameterWithIdentifier:@"tone"  name:@"Tone"  address:kTone  min:-1 max:1  unit:g  unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil]; pT.value = 0;
    AUParameter *pM = [AUParameterTree createParameterWithIdentifier:@"mix"   name:@"Mix"   address:kMix   min:0  max:1  unit:g  unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil]; pM.value = 1;
    AUParameter *pO = [AUParameterTree createParameterWithIdentifier:@"out"   name:@"Output" address:kOut  min:-12 max:12 unit:dB unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil]; pO.value = -2;

    _parameterTree = [AUParameterTree createTreeWithChildren:@[pD, pB, pT, pM, pO]];
    _drive.store(8); _bias.store(0.15f); _tone.store(0); _mix.store(1); _out.store(-2);

    __weak SaturationAudioUnit *w = self;
    _parameterTree.implementorValueObserver = ^(AUParameter *p, AUValue v) {
        SaturationAudioUnit *s = w; if (!s) return;
        switch (p.address) {
            case kDrive: s->_drive.store(v); break;
            case kBias:  s->_bias.store(v);  break;
            case kTone:  s->_tone.store(v);  break;
            case kMix:   s->_mix.store(v);   break;
            case kOut:   s->_out.store(v);   break;
        }
    };
    _parameterTree.implementorValueProvider = ^AUValue(AUParameter *p) {
        SaturationAudioUnit *s = w; if (!s) return 0;
        switch (p.address) {
            case kDrive: return s->_drive.load();
            case kBias:  return s->_bias.load();
            case kTone:  return s->_tone.load();
            case kMix:   return s->_mix.load();
            case kOut:   return s->_out.load();
        }
        return 0;
    };
    _parameterTree.implementorStringFromValueCallback = ^NSString *(AUParameter *p, const AUValue *vp) {
        AUValue v = vp ? *vp : p.value;
        switch (p.address) {
            case kDrive: case kOut: return [NSString stringWithFormat:@"%+.1f dB", v];
            case kBias: case kTone: return [NSString stringWithFormat:@"%+.2f", v];
            case kMix:              return [NSString stringWithFormat:@"%.0f%%", v * 100];
        }
        return [NSString stringWithFormat:@"%.2f", v];
    };
}

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)e {
    if (![super allocateRenderResourcesAndReturnError:e]) return NO;
    _ownOutBuf.assign((size_t)MAX((AUAudioFrameCount)512, self.maximumFramesToRender) * 2, 0.0f);
    _dsp->prepare((float)_outBus.format.sampleRate);
    // First-time values apply instantly (no fade-in from the constructor defaults).
    _dsp->setDriveDB(_drive.load()); _dsp->setBias(_bias.load()); _dsp->setTone(_tone.load());
    _dsp->setMix(_mix.load());       _dsp->setOutputDB(_out.load());
    _dsp->prepare((float)_outBus.format.sampleRate);
    return YES;
}
- (void)deallocateRenderResources { [super deallocateRenderResources]; if (_dsp) _dsp->reset(); }

/// The oversampled shaper has a constant linear-phase delay (36 samples at
/// 44.1/48 kHz, 35 at 88.2 kHz and up). Reported so Logic compensates it.
- (NSTimeInterval)latency {
    const double sr = _outBus.format.sampleRate > 0 ? _outBus.format.sampleRate : 48000.0;
    return (sr < 80000.0 ? 36.0 : 35.0) / sr;
}

/// Transport relocation / loop restart: clear tails so stale echoes don't replay.
- (void)reset { if (_dsp) _dsp->reset(); }

- (AUInternalRenderBlock)internalRenderBlock {
    __block sat::Saturation *dsp = _dsp.get();
    __block std::atomic<float> *aD=&_drive,*aB=&_bias,*aT=&_tone,*aM=&_mix,*aO=&_out,*aMeter=&_meter;
    __block std::vector<float> *ownOutBuf = &_ownOutBuf;
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
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
        AudioUnitRenderActionFlags pf=0;
        AUAudioUnitStatus err = pull(&pf, ts, n, 0, out);
        if (err != noErr) return err;
        dsp->setDriveDB(aD->load()); dsp->setBias(aB->load());
        dsp->setTone(aT->load());    dsp->setMix(aM->load());
        dsp->setOutputDB(aO->load());
        float pk = 0.0f;
        if (out->mNumberBuffers < 2) {
            float *m = (float *)out->mBuffers[0].mData;
            for (AVAudioFrameCount i = 0; i < n; ++i) { float L=m[i], R=m[i]; dsp->processFrame(L,R); m[i] = 0.5f*(L+R); float a=fabsf(m[i]); if(a>pk)pk=a; }
        } else {
            float *L = (float *)out->mBuffers[0].mData, *R = (float *)out->mBuffers[1].mData;
            for (AVAudioFrameCount i = 0; i < n; ++i) { dsp->processFrame(L[i], R[i]); float a=fmaxf(fabsf(L[i]), fabsf(R[i])); if(a>pk)pk=a; }
        }
        // Smooth toward the new peak: fast attack, slow release (UI meter feel).
        float prev = aMeter->load(std::memory_order_relaxed);
        float sm = (pk > prev) ? pk : (prev * 0.85f + pk * 0.15f);
        aMeter->store(sm, std::memory_order_relaxed);
        return noErr;
    };
}
@end
