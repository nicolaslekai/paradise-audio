//
//  RoarBassAudioUnit.mm
//  RoarBass
//
//  AUv3 AUAudioUnit subclass. Owns the C++ engine, exposes parameter tree,
//  handles MIDI events from the host, and renders into the output bus buffer.
//

#import "RoarBassAudioUnit.h"
#import "DSP/RoarBassDSP.hpp"

#include <vector>
#include <cstring>
#include <memory>
#include <fenv.h>
#if defined(__x86_64__) || defined(__i386__)
#include <xmmintrin.h>
#endif

using namespace roarbass;

#pragma mark - Parameter definitions

static AUParameter *MakeParam(AUParameterAddress addr,
                              NSString *identifier,
                              NSString *name,
                              float minV, float maxV, float defaultV,
                              AudioUnitParameterUnit unit,
                              AudioUnitParameterOptions flags = kAudioUnitParameterFlag_IsReadable |
                                                                kAudioUnitParameterFlag_IsWritable)
{
    AUParameter *p = [AUParameterTree createParameterWithIdentifier:identifier
                                                               name:name
                                                            address:addr
                                                                min:minV
                                                                max:maxV
                                                               unit:unit
                                                           unitName:nil
                                                              flags:flags
                                                       valueStrings:nil
                                                dependentParameters:nil];
    p.value = defaultV;
    return p;
}

#pragma mark - AU

@implementation RoarBassAudioUnit {
    std::vector<float> _ownOutBuf;   // scratch output (2 ch) for hosts that pass NULL mData
    std::unique_ptr<Engine>      _engine;
    AUAudioUnitBus              *_outputBus;
    AUAudioUnitBusArray         *_outputBusArray;
    AVAudioFormat               *_outputFormat;
    AUHostMusicalContextBlock    _musicalContext;
    AUHostTransportStateBlock    _transportState;
}

@synthesize parameterTree = _parameterTree;

- (instancetype)initWithComponentDescription:(AudioComponentDescription)componentDescription
                                     options:(AudioComponentInstantiationOptions)options
                                       error:(NSError * _Nullable *)outError
{
    self = [super initWithComponentDescription:componentDescription options:options error:outError];
    if (!self) return nil;

    _engine = std::make_unique<Engine>();
    _engine->prepare(44100.0f);

    // Default stereo float32 output
    _outputFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100.0
                                                                    channels:2];
    _outputBus = [[AUAudioUnitBus alloc] initWithFormat:_outputFormat error:nil];
    _outputBus.maximumChannelCount = 2;
    _outputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self
                                                             busType:AUAudioUnitBusTypeOutput
                                                              busses:@[_outputBus]];

    // Build parameter tree
    NSMutableArray<AUParameter*> *oscParams = [NSMutableArray array];
    [oscParams addObject:MakeParam(kParam_Osc1Octave, @"osc1Oct", @"OSC1 Octave",
                                   -2, 2, 0, kAudioUnitParameterUnit_Octaves)];
    [oscParams addObject:MakeParam(kParam_Osc2Octave, @"osc2Oct", @"OSC2 Octave",
                                   -2, 2, 0, kAudioUnitParameterUnit_Octaves)];
    [oscParams addObject:MakeParam(kParam_Osc2Detune, @"osc2Det", @"OSC2 Detune",
                                   -50, 50, 7, kAudioUnitParameterUnit_Cents)];
    [oscParams addObject:MakeParam(kParam_OscMix, @"oscMix", @"OSC Mix",
                                   0, 1, 0.5, kAudioUnitParameterUnit_Generic)];
    [oscParams addObject:MakeParam(kParam_SubLevel, @"sub", @"Sub Level",
                                   0, 1, 0.7, kAudioUnitParameterUnit_LinearGain)];

    NSMutableArray<AUParameter*> *fmParams = [NSMutableArray array];
    [fmParams addObject:MakeParam(kParam_FMAmount, @"fmAmt", @"FM Growl",
                                  0, 1, 0.25, kAudioUnitParameterUnit_LinearGain)];
    [fmParams addObject:MakeParam(kParam_FMRatio, @"fmRatio", @"FM Ratio",
                                  0.25, 8, 1, kAudioUnitParameterUnit_Ratio)];
    [fmParams addObject:MakeParam(kParam_FMFeedback, @"fmFb", @"FM Feedback",
                                  0, 1, 0.2, kAudioUnitParameterUnit_LinearGain)];

    NSMutableArray<AUParameter*> *noiseParams = [NSMutableArray array];
    [noiseParams addObject:MakeParam(kParam_NoiseLevel, @"nz", @"Noise Level",
                                     0, 1, 0.0, kAudioUnitParameterUnit_LinearGain)];
    [noiseParams addObject:MakeParam(kParam_NoiseColor, @"nzColor", @"Noise Colour",
                                     0, 1, 0.7, kAudioUnitParameterUnit_Generic)];

    NSMutableArray<AUParameter*> *filtParams = [NSMutableArray array];
    [filtParams addObject:MakeParam(kParam_FilterCutoff, @"cut", @"Filter Cutoff",
                                    20, 18000, 700, kAudioUnitParameterUnit_Hertz)];
    [filtParams addObject:MakeParam(kParam_FilterReso, @"res", @"Resonance",
                                    0, 1, 0.25, kAudioUnitParameterUnit_LinearGain)];
    [filtParams addObject:MakeParam(kParam_FilterDrive, @"drv", @"Filter Drive",
                                    0, 1, 0.2, kAudioUnitParameterUnit_LinearGain)];
    [filtParams addObject:MakeParam(kParam_FilterEnvAmt, @"fEnv", @"Filter Env Amt",
                                    -1, 1, 0.4, kAudioUnitParameterUnit_LinearGain)];

    NSMutableArray<AUParameter*> *ampEnvParams = [NSMutableArray array];
    [ampEnvParams addObject:MakeParam(kParam_AmpAttack, @"aA", @"Amp Attack",
                                      0.001, 4, 0.005, kAudioUnitParameterUnit_Seconds)];
    [ampEnvParams addObject:MakeParam(kParam_AmpDecay, @"aD", @"Amp Decay",
                                      0.001, 4, 0.2, kAudioUnitParameterUnit_Seconds)];
    [ampEnvParams addObject:MakeParam(kParam_AmpSustain, @"aS", @"Amp Sustain",
                                      0, 1, 0.85, kAudioUnitParameterUnit_LinearGain)];
    [ampEnvParams addObject:MakeParam(kParam_AmpRelease, @"aR", @"Amp Release",
                                      0.001, 4, 0.3, kAudioUnitParameterUnit_Seconds)];

    NSMutableArray<AUParameter*> *fltEnvParams = [NSMutableArray array];
    [fltEnvParams addObject:MakeParam(kParam_FilterAttack, @"fA", @"Filter Attack",
                                      0.001, 4, 0.005, kAudioUnitParameterUnit_Seconds)];
    [fltEnvParams addObject:MakeParam(kParam_FilterDecay, @"fD", @"Filter Decay",
                                      0.001, 4, 0.4, kAudioUnitParameterUnit_Seconds)];
    [fltEnvParams addObject:MakeParam(kParam_FilterSustain, @"fS", @"Filter Sustain",
                                      0, 1, 0.4, kAudioUnitParameterUnit_LinearGain)];
    [fltEnvParams addObject:MakeParam(kParam_FilterRelease, @"fR", @"Filter Release",
                                      0.001, 4, 0.3, kAudioUnitParameterUnit_Seconds)];

    NSMutableArray<AUParameter*> *globalParams = [NSMutableArray array];
    [globalParams addObject:MakeParam(kParam_Glide, @"glide", @"Glide",
                                      0, 1, 0.0, kAudioUnitParameterUnit_Seconds)];
    [globalParams addObject:MakeParam(kParam_VoiceMode, @"vmode", @"Voice Mode",
                                      0, 1, 0, kAudioUnitParameterUnit_Indexed)];
    [globalParams addObject:MakeParam(kParam_MasterGain, @"mg", @"Master Gain",
                                      0, 2, 0.9, kAudioUnitParameterUnit_LinearGain)];
    [globalParams addObject:MakeParam(kParam_DriveOut, @"dOut", @"Output Drive",
                                      0, 1, 0.1, kAudioUnitParameterUnit_LinearGain)];

    AUParameterGroup *gOsc   = [AUParameterTree createGroupWithIdentifier:@"osc"   name:@"Oscillators" children:oscParams];
    AUParameterGroup *gFm    = [AUParameterTree createGroupWithIdentifier:@"fm"    name:@"FM Growl"    children:fmParams];
    AUParameterGroup *gNoise = [AUParameterTree createGroupWithIdentifier:@"noise" name:@"Noise"       children:noiseParams];
    AUParameterGroup *gFlt   = [AUParameterTree createGroupWithIdentifier:@"flt"   name:@"Filter"      children:filtParams];
    AUParameterGroup *gAmpE  = [AUParameterTree createGroupWithIdentifier:@"ampe"  name:@"Amp Env"     children:ampEnvParams];
    AUParameterGroup *gFltE  = [AUParameterTree createGroupWithIdentifier:@"flte"  name:@"Filter Env"  children:fltEnvParams];
    AUParameterGroup *gGlobal= [AUParameterTree createGroupWithIdentifier:@"glob"  name:@"Global"      children:globalParams];

    _parameterTree = [AUParameterTree createTreeWithChildren:@[gOsc, gFm, gNoise, gFlt, gAmpE, gFltE, gGlobal]];

    // Push initial param values into engine
    for (AUParameter *p in [self allParameters:_parameterTree]) {
        _engine->setParameter(p.address, p.value);
    }

    // Sync engine on host writes
    __block Engine *engPtr = _engine.get();
    _parameterTree.implementorValueObserver = ^(AUParameter *param, AUValue value) {
        engPtr->setParameter(param.address, value);
    };
    _parameterTree.implementorValueProvider = ^AUValue(AUParameter *param) {
        return engPtr->getParameter(param.address);
    };
    _parameterTree.implementorStringFromValueCallback = ^NSString *(AUParameter *param, const AUValue *valuePtr) {
        AUValue v = (valuePtr == nullptr) ? param.value : *valuePtr;
        return [NSString stringWithFormat:@"%.3f", v];
    };

    self.maximumFramesToRender = 1024;
    return self;
}

- (NSArray<AUParameter*> *)allParameters:(AUParameterTree *)tree {
    NSMutableArray<AUParameter*> *out = [NSMutableArray array];
    [self collect:tree.children into:out];
    return out;
}

- (void)collect:(NSArray<AUParameterNode*> *)nodes into:(NSMutableArray<AUParameter*> *)out {
    for (AUParameterNode *n in nodes) {
        if ([n isKindOfClass:[AUParameter class]]) {
            [out addObject:(AUParameter *)n];
        } else if ([n isKindOfClass:[AUParameterGroup class]]) {
            [self collect:((AUParameterGroup *)n).children into:out];
        }
    }
}

- (AUAudioUnitBusArray *)outputBusses { return _outputBusArray; }

- (BOOL)allocateRenderResourcesAndReturnError:(NSError * _Nullable *)outError {
    if (![super allocateRenderResourcesAndReturnError:outError]) return NO;
    double sr = _outputBus.format.sampleRate;
    _engine->prepare((float)sr);
    // Re-apply params after resample
    for (AUParameter *p in [self allParameters:_parameterTree]) {
        _engine->setParameter(p.address, p.value);
    }
    return YES;
}

- (void)deallocateRenderResources {
    if (_engine) _engine->allNotesOff();
    [super deallocateRenderResources];
}

#pragma mark - Render

- (AUInternalRenderBlock)internalRenderBlock {
    Engine *eng = _engine.get();
    __block std::vector<float> *ownOutBuf = &_ownOutBuf;
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *actionFlags,
                              const AudioTimeStamp       *timestamp,
                              AVAudioFrameCount           frameCount,
                              NSInteger                   outputBusNumber,
                              AudioBufferList            *outputData,
                              const AURenderEvent        *realtimeEventListHead,
                              AURenderPullInputBlock      pullInputBlock) {
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

        // Flush denormals to zero on this audio thread. Without this,
        // decaying filter / reverb tails hit subnormal floats and CPU spikes.
#if defined(__arm64__) || defined(__aarch64__)
        fesetenv(FE_DFL_DISABLE_DENORMS_ENV);
#elif defined(__x86_64__) || defined(__i386__)
        // MXCSR bit 15 = FTZ, bit 6 = DAZ. Together = 0x8040.
        _mm_setcsr(_mm_getcsr() | 0x8040u);
#endif
        // Walk event list, dispatching MIDI in time-order. We process events between
        // sample positions and render in segments.
        const AURenderEvent *ev = realtimeEventListHead;
        AVAudioFrameCount cursor = 0;

        auto renderSegment = [&](AVAudioFrameCount segmentStart, AVAudioFrameCount segmentEnd) {
            if (segmentEnd <= segmentStart) return;
            AVAudioFrameCount count = segmentEnd - segmentStart;
            float *outL = (float *)outputData->mBuffers[0].mData + segmentStart;
            float *outR = (outputData->mNumberBuffers > 1)
                            ? (float *)outputData->mBuffers[1].mData + segmentStart
                            : outL;
            eng->render((int)count, outL, outR);
            if (outputData->mNumberBuffers <= 1) {
                // already mono, no copy needed
            }
        };

        while (ev != nullptr) {
            // Signed: events stamped before the block start (immediate events are
            // negative) wrapped to ~4 G unsigned and were dispatched AFTER the block.
            const int64_t evOff = (int64_t)ev->head.eventSampleTime - (int64_t)timestamp->mSampleTime;
            AVAudioFrameCount evFrame = evOff <= 0 ? 0 : (evOff >= (int64_t)frameCount ? frameCount : (AVAudioFrameCount)evOff);
            if (evFrame > frameCount) evFrame = frameCount;
            renderSegment(cursor, evFrame);
            cursor = evFrame;

            if (ev->head.eventType == AURenderEventMIDI) {
                const AUMIDIEvent &m = ev->MIDI;
                if (m.length >= 1) {
                    uint8_t status = m.data[0] & 0xF0;
                    if (status == 0x90 && m.length >= 3) {
                        uint8_t note = m.data[1];
                        uint8_t vel  = m.data[2];
                        if (vel == 0) eng->noteOff(note); else eng->noteOn(note, vel);
                    } else if (status == 0x80 && m.length >= 3) {
                        eng->noteOff(m.data[1]);
                    } else if (status == 0xB0 && m.length >= 3) {
                        if (m.data[1] == 120 || m.data[1] == 123) eng->allNotesOff();
                    }
                }
            } else if (ev->head.eventType == AURenderEventParameter ||
                       ev->head.eventType == AURenderEventParameterRamp) {
                const AUParameterEvent &pe = ev->parameter;
                eng->setParameter(pe.parameterAddress, pe.value);
            }
            ev = ev->head.next;
        }
        renderSegment(cursor, frameCount);

        // mark buffers as having valid data
        for (UInt32 b = 0; b < outputData->mNumberBuffers; ++b) {
            outputData->mBuffers[b].mDataByteSize = frameCount * sizeof(float);
        }
        return noErr;
    };
}

#pragma mark - AU metadata

- (BOOL)supportsMPE { return NO; }
// Below 80 kHz the engine runs 2x oversampled and comes back to the host rate
// through a linear-phase halfband filter: 15 samples, reported so Logic lines
// the track up.
- (NSTimeInterval)latency {
    const double sr = _outputBus.format.sampleRate > 0 ? _outputBus.format.sampleRate : 48000.0;
    return Engine::oversampled((float)sr) ? (double)Engine::kLatencySamples / sr : 0.0;
}
- (NSTimeInterval)tailTime { return 4.0; } // matches max release

@end
