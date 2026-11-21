#import "DrumsAudioUnit.h"
#include <vector>
#include <cstring>
#import "DSP/DrumsEngine.hpp"
#import "DSP/DrumsOffline.hpp"
#include <atomic>
#include <memory>
#include <fenv.h>
#if defined(__x86_64__) || defined(__i386__)
#include <xmmintrin.h>
#endif

enum : AUParameterAddress { kGain = 0 };

@interface DrumsAudioUnit ()
@property (nonatomic) AUAudioUnitBusArray *outputBusArray;
@end

@implementation DrumsAudioUnit {
    std::vector<float> _ownOutBuf;   // scratch output (2 ch) for hosts that pass NULL mData
    std::unique_ptr<drm::DrumsEngine> _dsp;
    AUAudioUnitBus *_outBus;
    AVAudioFormat *_format;
    std::atomic<float> _gain;
    std::atomic<float> _hostBPM;
    BOOL _followHostBPM;
}
@synthesize parameterTree = _parameterTree;
@synthesize playing = _playing;
@synthesize bpm     = _bpm;
@synthesize swing   = _swing;
@synthesize followHostBPM = _followHostBPM;

- (instancetype)initWithComponentDescription:(AudioComponentDescription)d options:(AudioComponentInstantiationOptions)o error:(NSError **)e {
    self = [super initWithComponentDescription:d options:o error:e]; if (!self) return nil;
    _dsp = std::make_unique<drm::DrumsEngine>(); _dsp->prepare(48000);
    _format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    _outBus = [[AUAudioUnitBus alloc] initWithFormat:_format error:nil];
    _outputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[_outBus]];

    AUParameter *pG = [AUParameterTree createParameterWithIdentifier:@"gain" name:@"Gain"
        address:kGain min:-24 max:12 unit:kAudioUnitParameterUnit_Decibels unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil];
    pG.value = 0;
    _parameterTree = [AUParameterTree createTreeWithChildren:@[pG]];
    _gain.store(0);
    _playing = YES;
    _bpm = 120.0f;
    _swing = 0.12f;
    _followHostBPM = YES;
    _hostBPM.store(120.0f);
    _dsp->setBPM(_bpm);
    _dsp->setSwing(_swing);
    _dsp->setPlaying(true);

    __weak DrumsAudioUnit *w = self;
    _parameterTree.implementorValueObserver = ^(AUParameter *p, AUValue v) { DrumsAudioUnit *s = w; if (s) s->_gain.store(v); };
    _parameterTree.implementorValueProvider = ^AUValue(AUParameter *p) { DrumsAudioUnit *s = w; return s ? s->_gain.load() : 0; };
    _parameterTree.implementorStringFromValueCallback = ^NSString *(AUParameter *p, const AUValue *vp) {
        return [NSString stringWithFormat:@"%.1f dB", vp ? *vp : p.value];
    };
    return self;
}

- (AUAudioUnitBusArray *)outputBusses { return _outputBusArray; }
- (int)currentStep { return _dsp ? _dsp->currentStep() : 0; }

- (void)setPlaying:(BOOL)playing { _playing = playing; if (_dsp) _dsp->setPlaying(playing); }
- (BOOL)recordArmed { return _dsp ? _dsp->recordArmed() : NO; }
- (void)setRecordArmed:(BOOL)armed { if (_dsp) _dsp->setRecordArmed(armed); }
- (void)setBpm:(float)bpm        { _bpm = bpm;         if (_dsp) _dsp->setBPM(bpm); }
- (void)setSwing:(float)swing    { _swing = swing;     if (_dsp) _dsp->setSwing(swing); }

- (BOOL)stepForVoice:(int)v step:(int)s        { return _dsp ? _dsp->getStep(v, s) : NO; }
- (void)setStepForVoice:(int)v step:(int)s on:(BOOL)on { if (_dsp) _dsp->setStep(v, s, on); }
- (int)swingLevelForVoice:(int)v step:(int)s   { return _dsp ? _dsp->stepSwing(v, s) : 0; }
- (void)setSwingLevelForVoice:(int)v step:(int)s level:(int)level { if (_dsp) _dsp->setStepSwing(v, s, level); }

- (float)levelForVoice:(int)v                  { return _dsp ? _dsp->level(v) : 1.0f; }
- (void)setLevelForVoice:(int)v level:(float)lvl { if (_dsp) _dsp->setLevel(v, lvl); }

- (float)delayMsForVoice:(int)v                { return _dsp ? _dsp->delayMs(v) : 0.0f; }
- (void)setDelayMsForVoice:(int)v ms:(float)ms { if (_dsp) _dsp->setDelayMs(v, ms); }

- (BOOL)isMutedForVoice:(int)v                 { return _dsp ? _dsp->isMuted(v) : NO; }
- (void)setMutedForVoice:(int)v muted:(BOOL)m  { if (_dsp) _dsp->setMute(v, m); }

- (BOOL)isSoloedForVoice:(int)v                { return _dsp ? _dsp->isSoloed(v) : NO; }
- (void)setSoloedForVoice:(int)v soloed:(BOOL)s { if (_dsp) _dsp->setSolo(v, s); }

- (void)triggerVoice:(int)v { if (_dsp) _dsp->triggerVoice(v, 1.0f); }

- (float)filterNormForVoice:(int)v        { return _dsp ? _dsp->filterNorm(v) : 1.0f; }
- (void)setFilterNormForVoice:(int)v norm:(float)n { if (_dsp) _dsp->setFilterNorm(v, n); }
- (float)decayForVoice:(int)v             { return _dsp ? _dsp->decayForVoice(v) : 1.0f; }
- (void)setDecayForVoice:(int)v decay:(float)d { if (_dsp) _dsp->setDecayForVoice(v, d); }

- (void)clearStepsForVoice:(int)v { if (_dsp) _dsp->clearVoiceSteps(v); }
- (void)clearAllSteps             { if (_dsp) _dsp->clearAllSteps(); }

- (int)patternSlot       { return _dsp ? _dsp->currentSlot() : 0; }
- (void)setPatternSlot:(int)s { if (_dsp) _dsp->setSlot(s); }

- (int)bars              { return _dsp ? _dsp->bars() : 2; }
- (void)setBars:(int)b   { if (_dsp) _dsp->setBars(b); }

- (void)setChainSlots:(NSArray<NSNumber *> *)slots {
    if (!_dsp) return;
    int buf[drm::kMaxChain]; int n = 0;
    for (NSNumber *s in slots) { if (n >= drm::kMaxChain) break; buf[n++] = s.intValue; }
    _dsp->setChain(buf, n);
}
- (NSArray<NSNumber *> *)chainSlots {
    NSMutableArray<NSNumber *> *a = [NSMutableArray array];
    if (_dsp) for (int i = 0; i < _dsp->chainLength(); ++i) [a addObject:@(_dsp->chainSlotAt(i))];
    return a;
}
- (void)clearChain       { if (_dsp) _dsp->clearChain(); }
- (int)chainPosition     { return _dsp ? _dsp->chainPosition() : 0; }

// ── Full-state persistence: the host saves/restores this with the project,
// and the UI's SAVE/LOAD presets reuse the same blob. Carries the entire
// pattern/voice/global/chain state (which lives outside the parameter tree).
static NSString * const kParadiseStateKey = @"paradiseDrumState";

- (NSDictionary<NSString *, id> *)fullState {
    NSMutableDictionary *d = [[super fullState] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (_dsp) {
        std::vector<uint8_t> bytes = _dsp->serialize();
        d[kParadiseStateKey] = [NSData dataWithBytes:bytes.data() length:bytes.size()];
    }
    return d;
}

- (void)setFullState:(NSDictionary<NSString *, id> *)fullState {
    [super setFullState:fullState];
    id blob = fullState[kParadiseStateKey];
    if (_dsp && [blob isKindOfClass:[NSData class]]) {
        NSData *data = (NSData *)blob;
        _dsp->deserialize((const uint8_t *)data.bytes, (size_t)data.length);
    }
}

- (NSData *)stateData {
    if (!_dsp) return [NSData data];
    std::vector<uint8_t> b = _dsp->serialize();
    return [NSData dataWithBytes:b.data() length:b.size()];
}

- (void)loadStateData:(NSData *)data {
    if (_dsp && data.length) _dsp->deserialize((const uint8_t *)data.bytes, (size_t)data.length);
}

- (int)resolutionForVoice:(int)v        { return _dsp ? _dsp->resolution(v) : 16; }
- (void)setResolutionForVoice:(int)v resolution:(int)r { if (_dsp) _dsp->setResolution(v, r); }

- (float)pitchSemiForVoice:(int)v       { return _dsp ? _dsp->pitchSemi(v) : 0.0f; }
- (void)setPitchSemiForVoice:(int)v semi:(float)semi { if (_dsp) _dsp->setPitchSemi(v, semi); }

- (float)reverbSendForVoice:(int)v      { return _dsp ? _dsp->reverbSend(v) : 0.0f; }
- (void)setReverbSendForVoice:(int)v send:(float)s { if (_dsp) _dsp->setReverbSend(v, s); }

- (int)characterForVoice:(int)v         { return _dsp ? _dsp->character(v) : 0; }
- (void)setCharacterForVoice:(int)v character:(int)c { if (_dsp) _dsp->setCharacter(v, c); }
- (int)characterCountForVoice:(int)v    { return _dsp ? _dsp->characterCount(v) : 1; }
- (NSString *)characterNameForVoice:(int)v character:(int)c {
    return _dsp ? [NSString stringWithUTF8String:_dsp->characterName(v, c)] : @"";
}

- (float)globalPitchSemi { return _dsp ? _dsp->globalPitchSemi() : 0.0f; }
- (void)setGlobalPitchSemi:(float)semi { if (_dsp) _dsp->setGlobalPitchSemi(semi); }
- (float)globalNoise { return _dsp ? _dsp->globalNoise() : 0.0f; }
- (void)setGlobalNoise:(float)n { if (_dsp) _dsp->setGlobalNoise(n); }

- (int)velocityPresetForVoice:(int)v { return _dsp ? _dsp->velocityPresetForVoice(v) : 0; }
- (void)setVelocityPresetForVoice:(int)v preset:(int)p { if (_dsp) _dsp->setVelocityPresetForVoice(v, p); }
- (NSInteger)velocityPresetCount { return (NSInteger)drm::DrumsEngine::kVelPresetCount; }
- (NSString *)velocityPresetName:(int)preset {
    return [NSString stringWithUTF8String:drm::DrumsEngine::velocityPresetName(preset)];
}
- (float)previewVelocityForVoice:(int)v hitIndex:(int)hitIdx {
    return _dsp ? _dsp->previewVelocityForVoice(v, hitIdx) : 1.0f;
}

- (float)globalDecay { return _dsp ? _dsp->globalDecay() : 1.0f; }
- (void)setGlobalDecay:(float)d { if (_dsp) _dsp->setGlobalDecay(d); }

// ── 2026-11 features: ISOLATE, MIDI MODE, row copy/swap, exports ─────────
- (BOOL)isolate { return _dsp ? _dsp->isolate() : NO; }
- (void)setIsolate:(BOOL)on { if (_dsp) _dsp->setIsolate(on); }
- (BOOL)midiMode { return _dsp ? _dsp->midiMode() : NO; }
- (void)setMidiMode:(BOOL)on { if (_dsp) _dsp->setMidiMode(on); }
- (void)copyPatternFromVoice:(int)src toVoice:(int)dst { if (_dsp) _dsp->copyRow(src, dst); }
- (void)swapPatternOfVoice:(int)a withVoice:(int)b { if (_dsp) _dsp->swapRows(a, b); }
- (float)stepVelocityForVoice:(int)v step:(int)s { return _dsp ? _dsp->stepVelocity(v, s) : 1.0f; }
- (BOOL)stepVelocityIsSetForVoice:(int)v step:(int)s { return _dsp ? _dsp->stepVelocitySet(v, s) : NO; }
- (void)setStepVelocityForVoice:(int)v step:(int)s velocity:(float)vel isSet:(BOOL)isSet {
    if (_dsp) _dsp->setStepVelocity(v, s, vel, isSet);
}

- (float)exportSampleRate {
    const double sr = _outBus.format.sampleRate;
    return (float)((sr >= 8000.0 && sr <= 384000.0) ? sr : 48000.0);
}
- (float)exportGainLin { return std::pow(10.0f, _gain.load() * 0.05f); }
- (double)exportDurationSeconds {
    if (!_dsp) return 0;
    const float sr = [self exportSampleRate];
    return (double)_dsp->offlineLengthFrames(sr) / sr;
}
- (BOOL)exportMIDIToPath:(NSString *)path {
    if (!_dsp || path.length == 0) return NO;
    const std::vector<uint8_t> blob = _dsp->serialize();
    const float sr = [self exportSampleRate];
    drm::OfflineResult r = drm::renderOffline(blob, sr, _bpm, 1.0f, -1, 0.0f, true, false);
    // What you hear is what you export: drop muted / non-soloed voices.
    auto probe = std::make_unique<drm::DrumsEngine>();
    probe->prepare(sr); probe->deserialize(blob.data(), blob.size());
    std::vector<drm::TrigEvent> ev;
    for (const auto &e : r.events) if (!probe->mutedOrNotSoloed(e.voice)) ev.push_back(e);
    return drm::writeMidiFile(path.fileSystemRepresentation, ev, sr, _bpm) ? YES : NO;
}
- (BOOL)exportAudioMixToPath:(NSString *)path {
    if (!_dsp || path.length == 0) return NO;
    const std::vector<uint8_t> blob = _dsp->serialize();
    const float sr = [self exportSampleRate];
    drm::OfflineResult r = drm::renderOffline(blob, sr, _bpm, [self exportGainLin], -1, 2.0f, false, true);
    return drm::writeWav24(path.fileSystemRepresentation, r.L, r.R, (int)sr) ? YES : NO;
}
- (NSArray<NSString *> *)exportAudioStemsToFolder:(NSString *)folder {
    NSMutableArray<NSString *> *written = [NSMutableArray array];
    if (!_dsp || folder.length == 0) return written;
    const std::vector<uint8_t> blob = _dsp->serialize();
    const float sr = [self exportSampleRate];
    const float g = [self exportGainLin];
    for (int v : drm::audibleVoicesWithHits(blob, sr, _bpm)) {
        drm::OfflineResult r = drm::renderOffline(blob, sr, _bpm, g, v, 2.0f, false, true);
        NSString *name = [NSString stringWithFormat:@"%s.wav", drm::kVoiceFileNames[v]];
        NSString *p = [folder stringByAppendingPathComponent:name];
        if (drm::writeWav24(p.fileSystemRepresentation, r.L, r.R, (int)sr)) [written addObject:p];
    }
    return written;
}

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)e {
    if (![super allocateRenderResourcesAndReturnError:e]) return NO;
    _ownOutBuf.assign((size_t)MAX((AUAudioFrameCount)512, self.maximumFramesToRender) * 2, 0.0f);
    _dsp->prepare((float)_outBus.format.sampleRate);
    _dsp->setBPM(_bpm);
    _dsp->setSwing(_swing);
    _dsp->setPlaying(_playing);
    return YES;
}
- (void)deallocateRenderResources { [super deallocateRenderResources]; if (_dsp) _dsp->reset(); }

/// How long the kit keeps sounding after the last trigger: LONG SUB rings up
/// to 3 s, crash + reverb about as long. It reported 0, so a host was free to
/// stop rendering / cut a bounce the moment the region ended.
- (NSTimeInterval)tailTime { return 4.0; }

- (AUInternalRenderBlock)internalRenderBlock {
    __block drm::DrumsEngine *dsp = _dsp.get();
    __block std::atomic<float> *aG = &_gain;
    __block std::atomic<float> *aHostBPM = &_hostBPM;
    __unsafe_unretained DrumsAudioUnit *unsafeSelf = self;
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
        // Flush denormals to zero on this audio thread. Without this,
        // decaying filter / reverb tails hit subnormal floats and CPU spikes.
#if defined(__arm64__) || defined(__aarch64__)
        fesetenv(FE_DFL_DISABLE_DENORMS_ENV);
#elif defined(__x86_64__) || defined(__i386__)
        // MXCSR bit 15 = FTZ, bit 6 = DAZ. Together = 0x8040.
        _mm_setcsr(_mm_getcsr() | 0x8040u);
#endif
        // Pull host tempo + transport so Drums sync to Logic. Refetch each
        // render — Logic doesn't always have these set when the render block
        // is captured. Property access on __unsafe_unretained self is safe
        // here (no ARC retain/release).
        // Transport state FIRST, so a play/stop transition is known before we
        // feed the beat position — this lets the sequencer hard-snap to the
        // host on the very block playback starts (zero-block sync latency).
        AUHostTransportStateBlock tsb = unsafeSelf.transportStateBlock;
        if (tsb) {
            AUHostTransportStateFlags flags = 0;
            if (tsb(&flags, NULL, NULL, NULL)) {
                BOOL hostPlaying = (flags & AUHostTransportStateMoving) != 0;
                dsp->setPlaying(hostPlaying ? true : false);
            }
        }
        AUHostMusicalContextBlock mctx = unsafeSelf.musicalContextBlock;
        if (mctx) {
            double hostTempo = 0;
            double beatPos = 0;
            if (mctx(&hostTempo, NULL, NULL, &beatPos, NULL, NULL) && hostTempo > 0) {
                aHostBPM->store((float)hostTempo);
                dsp->setBPM((float)hostTempo);
                unsafeSelf->_bpm = (float)hostTempo;
                // Beat position locks the sequencer to Logic's bar grid.
                dsp->setHostBeatPosition(beatPos);
            }
        }
        const float gainLin = std::pow(10.0f, aG->load() * 0.05f);

        // MIDI is applied at its sample position inside the buffer: render up to
        // each event, apply it, carry on. (Every hit used to fire at the START
        // of the host buffer — 9 ms early at a 512 buffer, 14.5 ms at 1024, a
        // different amount for every hit; in MIDI MODE, where a host region
        // plays the voices, that was audible timing jitter.) The internal
        // sequencer runs inside processFrame from the host beat position set
        // above and is not affected; a recorded hit now lands on the step that
        // is current at its own sample position.
        drm::DrumsEngine *eng = dsp;             // (__block variables cannot be captured by a C++ lambda)
        float *outL = (float *)out->mBuffers[0].mData;
        float *outR = (out->mNumberBuffers >= 2) ? (float *)out->mBuffers[1].mData : NULL;
        auto renderRange = [eng, outL, outR, gainLin](AVAudioFrameCount from, AVAudioFrameCount to) {
            if (outR) {
                for (AVAudioFrameCount i = from; i < to; ++i) {
                    float l, r; eng->processFrame(l, r);
                    outL[i] = l * gainLin; outR[i] = r * gainLin;
                }
            } else {
                for (AVAudioFrameCount i = from; i < to; ++i) {
                    float L, R; eng->processFrame(L, R);
                    outL[i] = 0.5f * (L + R) * gainLin;
                }
            }
        };
        AVAudioFrameCount cursor = 0;
        const AURenderEvent *e = evt;
        while (e) {
            if (e->head.eventType == AURenderEventMIDI) {
                // signed: "immediate" events are stamped before the block start
                const int64_t off = (int64_t)e->head.eventSampleTime - (int64_t)ts->mSampleTime;
                const AVAudioFrameCount at = off <= 0 ? 0 : (off >= (int64_t)n ? n : (AVAudioFrameCount)off);
                if (at > cursor) { renderRange(cursor, at); cursor = at; }
                const uint8_t status = e->MIDI.data[0];
                const uint8_t d1 = e->MIDI.data[1], d2 = e->MIDI.data[2];
                if ((status & 0xF0) == 0x90 && d2 > 0) {
                    // Maschine default: bottom-left pad = note 36, ascending.
                    const int voice = (int)d1 - 36;
                    if (voice >= 0 && voice < drm::kVoices) {
                        // recordNote always triggers the voice (monitoring) and,
                        // when armed + playing, captures the hit + velocity into
                        // the active pattern at the nearest step.
                        dsp->recordNote(voice, (float)d2 / 127.0f);
                    }
                }
            }
            e = e->head.next;
        }
        renderRange(cursor, n);
        return noErr;
    };
}
@end
