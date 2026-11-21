#import "HandyAudioUnit.h"
#include <vector>
#include <cstring>
#import "DSP/HandyEngine.hpp"
#import "DSP/CaptureWav.hpp"
#include <atomic>
#include <memory>
#include <mutex>
#include <fenv.h>
#if defined(__x86_64__) || defined(__i386__)
#include <xmmintrin.h>
#endif

enum : AUParameterAddress { kHF=0, kNR=1, kTr=2, kWa=3, kLv=4, kMx=5, kPt=6 };

@interface HandyAudioUnit ()
@property (nonatomic) AUAudioUnitBusArray *outputBusArray;
@end

@implementation HandyAudioUnit {
    std::vector<float> _ownOutBuf;   // scratch output (2 ch) for hosts that pass NULL mData
    std::unique_ptr<hdy::HandyEngine> _dsp;
    std::mutex _engineMutex;  // Guards pad buffer swaps from UI thread.
    AUAudioUnitBus *_outBus;
    AVAudioFormat  *_format;
    std::atomic<float> _hf, _nr, _tr, _wa, _lv, _mx, _pt;
    NSMutableArray<NSString *> *_padNames;
    cap::WavCapture _bounce;     // output capture for the BOUNCE button
    double _sampleRate;
}
@synthesize parameterTree = _parameterTree;

- (instancetype)initWithComponentDescription:(AudioComponentDescription)d options:(AudioComponentInstantiationOptions)o error:(NSError **)e {
    self = [super initWithComponentDescription:d options:o error:e]; if (!self) return nil;
    _dsp = std::make_unique<hdy::HandyEngine>(); _dsp->prepare(48000);
    _sampleRate = 48000;
    _format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    _outBus = [[AUAudioUnitBus alloc] initWithFormat:_format error:nil];
    _outputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[_outBus]];
    _padNames = [NSMutableArray array];
    for (NSInteger i = 0; i < hdy::kNumPads; ++i) [_padNames addObject:@"— EMPTY —"];
    [self build];
    return self;
}

- (AUAudioUnitBusArray *)outputBusses { return _outputBusArray; }
- (NSInteger)padCount { return hdy::kNumPads; }
- (NSInteger)zoneCount { return hdy::kNumZones; }

- (float)rangeStartForPad:(NSInteger)index { return _dsp ? _dsp->rangeStart((int)index) : 0.0f; }
- (float)rangeEndForPad:(NSInteger)index   { return _dsp ? _dsp->rangeEnd((int)index)   : 1.0f; }
- (void)setRangeForPad:(NSInteger)index start:(float)start end:(float)end {
    if (_dsp) _dsp->setRange((int)index, start, end);
}

- (float)pitchTranspose { return _pt.load(); }
- (void)setPitchTranspose:(float)semi {
    AUParameter *p = [_parameterTree parameterWithAddress:kPt];
    if (p) [p setValue:(AUValue)semi originator:nil];   // routes through the observer
    else { _pt.store(semi); if (_dsp) _dsp->setTranspose(semi); }
}

- (NSString *)nameForPad:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_padNames.count) return @"— EMPTY —";
    return _padNames[index];
}

- (void)setSamplePad:(NSInteger)index data:(const float *)data length:(NSInteger)length name:(NSString *)name {
    if (index < 0 || index >= hdy::kNumPads) return;
    std::lock_guard<std::mutex> lk(_engineMutex);
    _dsp->setSample((int)index, data, (int)length);
    _padNames[index] = name ?: @"loaded";
}

- (void)clearPad:(NSInteger)index {
    if (index < 0 || index >= hdy::kNumPads) return;
    std::lock_guard<std::mutex> lk(_engineMutex);
    _dsp->clearSample((int)index);
    _padNames[index] = @"— EMPTY —";
}

// ---- State persistence ------------------------------------------------------
// Embed the loaded pad samples (plus their per-pad pitch / chop / key-trigger /
// root) into the AU's saved state so they travel with the project / host saved
// state. Audio is stored as raw mono Float32 PCM at 48 kHz (the load-time
// rate), so reopening a project restores the exact pads you dropped. Overriding
// fullState / setFullState also covers fullStateForDocument, whose default
// implementation forwards to these. (The Paradise SAVE/LOAD preset buttons use
// a separate params-only path and intentionally do not carry the audio.)

- (NSDictionary<NSString *, id> *)fullState {
    NSMutableDictionary *state = [[super fullState] mutableCopy];
    if (!state) state = [NSMutableDictionary dictionary];
    std::lock_guard<std::mutex> lk(_engineMutex);
    NSMutableArray *pads = [NSMutableArray arrayWithCapacity:hdy::kNumPads];
    for (int i = 0; i < hdy::kNumPads; ++i) {
        NSMutableDictionary *pd = [NSMutableDictionary dictionary];
        const int len   = _dsp->sampleLength(i);
        const float *d  = _dsp->sampleData(i);
        if (d && len > 0) {
            pd[@"pcm"] = [NSData dataWithBytes:d length:(NSUInteger)len * sizeof(float)];
        }
        pd[@"name"]  = (i < (int)_padNames.count) ? _padNames[i] : @"loaded";
        pd[@"pitch"] = @(_dsp->pitchSemi(i));
        pd[@"chop"]  = @(_dsp->chop(i));
        pd[@"key"]   = @(_dsp->keyTrigger(i));
        pd[@"root"]  = @(_dsp->rootNote(i));
        pd[@"rs"]    = @(_dsp->rangeStart(i));   // RANGE start
        pd[@"re"]    = @(_dsp->rangeEnd(i));     // RANGE end
        [pads addObject:pd];
    }
    state[@"handyPads"] = pads;
    return state;
}

- (void)setFullState:(NSDictionary<NSString *, id> *)fullState {
    [super setFullState:fullState];   // restores the parameter tree (effect knobs)
    NSArray *pads = fullState[@"handyPads"];
    if ([pads isKindOfClass:[NSArray class]]) {
        std::lock_guard<std::mutex> lk(_engineMutex);
        for (int i = 0; i < hdy::kNumPads && i < (int)pads.count; ++i) {
            NSDictionary *pd = pads[i];
            if (![pd isKindOfClass:[NSDictionary class]]) continue;
            NSData *pcm = pd[@"pcm"];
            if ([pcm isKindOfClass:[NSData class]] && pcm.length >= sizeof(float)) {
                _dsp->setSample(i, (const float *)pcm.bytes, (int)(pcm.length / sizeof(float)));
            } else {
                _dsp->clearSample(i);
            }
            id name = pd[@"name"];
            _padNames[i] = [name isKindOfClass:[NSString class]] ? (NSString *)name : @"loaded";
            id v;
            if ([(v = pd[@"pitch"]) isKindOfClass:[NSNumber class]]) _dsp->setPitchSemi(i, [v floatValue]);
            if ([(v = pd[@"chop"])  isKindOfClass:[NSNumber class]]) _dsp->setChop(i, [v floatValue]);
            if ([(v = pd[@"key"])   isKindOfClass:[NSNumber class]]) _dsp->setKeyTrigger(i, [v boolValue]);
            if ([(v = pd[@"root"])  isKindOfClass:[NSNumber class]]) _dsp->setRootNote(i, [v intValue]);
            {
                id rs = pd[@"rs"], re = pd[@"re"];
                if ([rs isKindOfClass:[NSNumber class]] && [re isKindOfClass:[NSNumber class]])
                    _dsp->setRange(i, [rs floatValue], [re floatValue]);
            }
        }
    }
    // Let an open editor re-read pad names / loaded state on the main thread.
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"HandyDidRestoreState" object:self];
    });
}

- (NSInteger)sampleLengthForPad:(NSInteger)index { return _dsp ? _dsp->sampleLength((int)index) : 0; }
- (NSInteger)copySampleForPad:(NSInteger)index into:(float *)dst maxFrames:(NSInteger)maxFrames {
    if (!_dsp || !dst || maxFrames <= 0) return 0;
    std::lock_guard<std::mutex> lk(_engineMutex);
    return _dsp->copySample((int)index, dst, (int)maxFrames);
}

- (void)triggerPad:(NSInteger)index velocity:(uint8_t)vel {
    _dsp->triggerPad((int)index, vel / 127.0f);
}

- (float)pitchSemiForPad:(NSInteger)index               { return _dsp ? _dsp->pitchSemi((int)index) : 0.0f; }
- (void)setPitchSemiForPad:(NSInteger)index semi:(float)st { if (_dsp) _dsp->setPitchSemi((int)index, st); }

- (float)chopForPad:(NSInteger)index                    { return _dsp ? _dsp->chop((int)index) : 0.0f; }
- (BOOL)keyTriggerForPad:(NSInteger)index               { return _dsp ? _dsp->keyTrigger((int)index) : NO; }
- (void)setKeyTriggerForPad:(NSInteger)index on:(BOOL)on { if (_dsp) _dsp->setKeyTrigger((int)index, on ? true : false); }
- (void)setChopForPad:(NSInteger)index knob:(float)k    { if (_dsp) _dsp->setChop((int)index, k); }

- (int)rootNoteForPad:(NSInteger)index                  { return _dsp ? _dsp->rootNote((int)index) : 36; }
- (void)setRootNoteForPad:(NSInteger)index midi:(int)note { if (_dsp) _dsp->setRootNote((int)index, note); }

- (void)build {
    AudioUnitParameterUnit g  = kAudioUnitParameterUnit_LinearGain;
    AudioUnitParameterUnit dB = kAudioUnitParameterUnit_Decibels;

    AUParameter *pH = [AUParameterTree createParameterWithIdentifier:@"hf"   name:@"HF Restore" address:kHF min:0    max:1   unit:g  unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil]; pH.value = 0.65;
    AUParameter *pN = [AUParameterTree createParameterWithIdentifier:@"nr"   name:@"Noise Rdx"  address:kNR min:-40  max:0   unit:dB unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil]; pN.value = -18;
    AUParameter *pT = [AUParameterTree createParameterWithIdentifier:@"tr"   name:@"Transient"  address:kTr min:-1   max:1   unit:g  unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil]; pT.value = 0.30;
    AUParameter *pW = [AUParameterTree createParameterWithIdentifier:@"wa"   name:@"Warmth"     address:kWa min:0    max:1   unit:g  unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil]; pW.value = 0.40;
    AUParameter *pL = [AUParameterTree createParameterWithIdentifier:@"lv"   name:@"Level"      address:kLv min:-24  max:12  unit:dB unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil]; pL.value = 0;
    AUParameter *pM = [AUParameterTree createParameterWithIdentifier:@"mx"   name:@"Mix"        address:kMx min:0    max:1   unit:g  unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil]; pM.value = 1.0;
    // Global PITCH transpose knob (-24..+24 semitones).
    AUParameter *pP = [AUParameterTree createParameterWithIdentifier:@"pt"   name:@"Pitch"      address:kPt min:-24  max:24  unit:kAudioUnitParameterUnit_RelativeSemiTones unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil]; pP.value = 0;

    _parameterTree = [AUParameterTree createTreeWithChildren:@[pH, pN, pT, pW, pL, pM, pP]];
    _hf.store(0.65f); _nr.store(-18); _tr.store(0.30f); _wa.store(0.40f); _lv.store(0); _mx.store(1.0f); _pt.store(0.0f);

    __weak HandyAudioUnit *w = self;
    _parameterTree.implementorValueObserver = ^(AUParameter *p, AUValue v) {
        HandyAudioUnit *s = w; if (!s) return;
        switch (p.address) {
            case kHF: s->_hf.store(v); break; case kNR: s->_nr.store(v); break;
            case kTr: s->_tr.store(v); break; case kWa: s->_wa.store(v); break;
            case kLv: s->_lv.store(v); break; case kMx: s->_mx.store(v); break;
            case kPt: s->_pt.store(v); break;
        }
    };
    _parameterTree.implementorValueProvider = ^AUValue(AUParameter *p) {
        HandyAudioUnit *s = w; if (!s) return 0;
        switch (p.address) {
            case kHF: return s->_hf.load(); case kNR: return s->_nr.load();
            case kTr: return s->_tr.load(); case kWa: return s->_wa.load();
            case kLv: return s->_lv.load(); case kMx: return s->_mx.load();
            case kPt: return s->_pt.load();
        }
        return 0;
    };
    _parameterTree.implementorStringFromValueCallback = ^NSString *(AUParameter *p, const AUValue *vp) {
        AUValue v = vp ? *vp : p.value;
        switch (p.address) {
            case kHF: case kWa: return [NSString stringWithFormat:@"%.2f", v];
            case kNR: case kLv: return [NSString stringWithFormat:@"%.0f dB", v];
            case kTr: return [NSString stringWithFormat:@"%+.2f", v];
            case kMx: return [NSString stringWithFormat:@"%.0f%%", v * 100];
            case kPt: return [NSString stringWithFormat:@"%+.0f st", v];
        }
        return [NSString stringWithFormat:@"%.2f", v];
    };
}

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)e {
    if (![super allocateRenderResourcesAndReturnError:e]) return NO;
    _ownOutBuf.assign((size_t)MAX((AUAudioFrameCount)512, self.maximumFramesToRender) * 2, 0.0f);
    std::lock_guard<std::mutex> lk(_engineMutex);
    _sampleRate = _outBus.format.sampleRate;
    _dsp->prepare((float)_sampleRate);
    return YES;
}

// ── Live output scope probe ──
- (NSInteger)probeSize { return (NSInteger)hdy::HandyEngine::probeSize(); }
- (NSInteger)readProbe:(float *)out count:(NSInteger)count {
    if (!_dsp || !out || count <= 0) return 0;
    NSInteger n = MIN(count, (NSInteger)hdy::HandyEngine::probeSize());
    _dsp->readProbe(out, (int)n);
    return n;
}

// ── Bounce / capture-to-WAV ──
- (BOOL)bounceArmed { return _bounce.isArmed(); }
- (void)setBounceArmed:(BOOL)armed {
    if (armed) _bounce.arm(_sampleRate > 0 ? _sampleRate : 48000.0, 180.0);  // up to 3 min
    else       _bounce.disarm();
}
- (double)bounceSampleRate { return _sampleRate > 0 ? _sampleRate : 48000.0; }
- (NSInteger)bounceFrameCount { return (NSInteger)_bounce.capturedFrames(); }
- (NSInteger)copyBounceInterleaved:(float *)dst maxFrames:(NSInteger)maxFrames {
    if (!dst || maxFrames <= 0) return 0;
    return (NSInteger)_bounce.copyOut(dst, (int)maxFrames);
}
- (void)freeBounce { _bounce.freeBuf(); }
- (void)deallocateRenderResources { [super deallocateRenderResources]; if (_dsp) _dsp->reset(); }

- (AUInternalRenderBlock)internalRenderBlock {
    __block hdy::HandyEngine *dsp = _dsp.get();
    __block std::atomic<float> *aH=&_hf,*aN=&_nr,*aT=&_tr,*aW=&_wa,*aL=&_lv,*aM=&_mx,*aP=&_pt;
    __block cap::WavCapture *bounce = &_bounce;
    __block std::mutex *engineMutex = &_engineMutex;

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
        // A sample drop / project restore swaps pad buffers under the engine
        // lock. Never block the audio thread on it: if the UI holds the lock
        // for this one block, emit silence (a sub-millisecond gap during a
        // file load) instead of reading a buffer that is being freed.
        std::unique_lock<std::mutex> engineLock(*engineMutex, std::try_to_lock);
        if (!engineLock.owns_lock()) {
            for (UInt32 b = 0; b < out->mNumberBuffers; ++b)
                if (out->mBuffers[b].mData) memset(out->mBuffers[b].mData, 0, out->mBuffers[b].mDataByteSize);
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
        dsp->setHF(aH->load()); dsp->setNoiseDB(aN->load());
        dsp->setTransient(aT->load()); dsp->setWarmth(aW->load());
        dsp->setLevelDB(aL->load()); dsp->setMix(aM->load());
        dsp->setTranspose(aP->load());

        // MIDI is applied at its sample position inside the buffer: render up to
        // each event, apply it, carry on. (Every note used to fire at the START
        // of the host buffer — up to 21 ms early at a 1024 buffer, a different
        // amount for every hit, i.e. audible timing jitter on chopped drums.)
        float *outL = (float *)out->mBuffers[0].mData;
        float *outR = (out->mNumberBuffers >= 2) ? (float *)out->mBuffers[1].mData : NULL;
        hdy::HandyEngine *eng = dsp;            // (__block variables cannot be captured by a C++ lambda)
        cap::WavCapture  *capt = bounce;
        auto renderRange = [eng, capt, outL, outR](AVAudioFrameCount from, AVAudioFrameCount to) {
            if (outR) {
                for (AVAudioFrameCount i = from; i < to; ++i) {
                    eng->processFrame(outL[i], outR[i]);
                    capt->capture(outL[i], outR[i]);
                }
            } else {
                for (AVAudioFrameCount i = from; i < to; ++i) {
                    float L, R; eng->processFrame(L, R);
                    outL[i] = 0.5f * (L + R);
                    capt->capture(L, R);
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
                const uint8_t data1  = e->MIDI.data[1];
                const uint8_t data2  = e->MIDI.data[2];
                if ((status & 0xF0) == 0x90 && data2 > 0) {
                    dsp->noteOn(data1, data2);
                } else if (((status & 0xF0) == 0x80) ||
                           ((status & 0xF0) == 0x90 && data2 == 0)) {
                    // Note-off (explicit 0x8n OR 0x9n with velocity 0).
                    dsp->noteOff(data1);
                }
            }
            e = e->head.next;
        }
        renderRange(cursor, n);
        return noErr;
    };
}
@end
