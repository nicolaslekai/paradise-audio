#import "UltraReverseAudioUnit.h"
#include <vector>
#include <cstring>
#import "DSP/ReverseProcessor.hpp"
#include <atomic>
#include <memory>
#include <fenv.h>
#if defined(__x86_64__) || defined(__i386__)
#include <xmmintrin.h>
#endif

// Parameter addresses. 0-8 keep their original meaning (saved sessions and
// automation stay valid); 9-18 were added with the real reverse engine
// (2026-11-20, REVERSE_PLAN.md §3.4). The UI reads these by address too.
enum : AUParameterAddress {
    kReverse=0, kSize=1, kDecay=2, kShimmer=3, kDiffusion=4, kTexture=5, kPre=6, kTone=7, kMix=8,
    kMode=9, kSync=10, kDivision=11, kSmooth=12, kCut=13, kFeedback=14, kFbTone=15,
    kLookahead=16, kLength=17, kGap=18,
    kNumParams=19
};

// State marker: sessions saved before the reverse engine have no marker and are
// restored as BLOOM with no lookahead, so they sound exactly as they did.
static NSString *const kStateVersionKey = @"urvEngineVersion";

@interface UltraReverseAudioUnit ()
@property (nonatomic) AUAudioUnitBusArray *inputBusArray;
@property (nonatomic) AUAudioUnitBusArray *outputBusArray;
@end

@implementation UltraReverseAudioUnit {
    std::vector<float> _ownOutBuf;   // scratch output (2 ch) for hosts that pass NULL mData
    std::unique_ptr<urv::ReverseProcessor> _dsp;
    AUAudioUnitBus *_inBus, *_outBus;
    AVAudioFormat *_format;
    std::atomic<float> _p[kNumParams];
    std::atomic<int> _latencySamples;
    double _sampleRate;
    dispatch_queue_t _irQueue;
    std::atomic<int> _irGeneration;
    AUHostMusicalContextBlock _musicalContext;
    AUHostTransportStateBlock _transportState;
}
@synthesize parameterTree = _parameterTree;

- (instancetype)initWithComponentDescription:(AudioComponentDescription)d options:(AudioComponentInstantiationOptions)o error:(NSError **)e {
    self = [super initWithComponentDescription:d options:o error:e]; if (!self) return nil;
    _sampleRate = 48000.0;
    _dsp = std::make_unique<urv::ReverseProcessor>(); _dsp->prepare(48000, 4096);
    _irQueue = dispatch_queue_create("com.paradise.ultrareverse.ir", DISPATCH_QUEUE_SERIAL);
    _irGeneration.store(0);
    _format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    _inBus  = [[AUAudioUnitBus alloc] initWithFormat:_format error:nil];
    _outBus = [[AUAudioUnitBus alloc] initWithFormat:_format error:nil];
    _inputBusArray  = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:@[_inBus]];
    _outputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[_outBus]];
    [self build];
    _latencySamples.store((int)lrint(urv::lookaheadSeconds((int)lrintf(_p[kLookahead].load())) * _sampleRate));
    return self;
}
- (AUAudioUnitBusArray *)inputBusses { return _inputBusArray; }
- (AUAudioUnitBusArray *)outputBusses { return _outputBusArray; }

static AUParameter *mk(NSString *ident, NSString *name, AUParameterAddress a, float mn, float mx,
                       AudioUnitParameterUnit u, AudioUnitParameterOptions extra, NSArray<NSString *> *strings, float def) {
    AUParameter *p = [AUParameterTree createParameterWithIdentifier:ident name:name address:a min:mn max:mx unit:u unitName:nil
        flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable | extra)
        valueStrings:strings dependentParameters:nil];
    p.value = def; return p;
}

- (void)build {
    AudioUnitParameterUnit g   = kAudioUnitParameterUnit_LinearGain;
    AudioUnitParameterUnit ms  = kAudioUnitParameterUnit_Milliseconds;
    AudioUnitParameterUnit sec = kAudioUnitParameterUnit_Seconds;
    AudioUnitParameterUnit idx = kAudioUnitParameterUnit_Indexed;
    AudioUnitParameterUnit hz  = kAudioUnitParameterUnit_Hertz;

    NSArray *params = @[
        mk(@"reverse",   @"Reverse",   kReverse,   0.1, 4.0,  sec, 0, nil, 0.6),
        mk(@"size",      @"Size",      kSize,      0,   1,    g,   0, nil, 0.7),
        mk(@"decay",     @"Decay",     kDecay,     0.3, 30,   sec, 0, nil, 4.0),
        mk(@"shimmer",   @"Shimmer",   kShimmer,   0,   1,    g,   0, nil, 0.3),
        mk(@"diffusion", @"Diffusion", kDiffusion, 0,   1,    g,   0, nil, 0.6),
        mk(@"texture",   @"Texture",   kTexture,   0,   1,    g,   0, nil, 0.7),
        mk(@"predelay",  @"Predelay",  kPre,       0,   300,  ms,  0, nil, 20),
        mk(@"tone",      @"Tone",      kTone,      0,   1,    g,   0, nil, 0.5),
        mk(@"mix",       @"Mix",       kMix,       0,   1,    g,   0, nil, 0.4),
        mk(@"mode",      @"Mode",      kMode,      0,   3,    idx, 0, @[@"Bloom", @"Reverse Echo", @"Reverse Reverb", @"Pre-Verb"], 1),
        mk(@"sync",      @"Sync",      kSync,      0,   1,    idx, 0, @[@"Free", @"Sync"], 1),
        mk(@"division",  @"Division",  kDivision,  0,   7,    idx, 0, @[@"1/16", @"1/8", @"1/8.", @"1/4", @"1/4.", @"1/2", @"1 Bar", @"2 Bars"], 3),
        mk(@"smooth",    @"Smooth",    kSmooth,    1,   80,   ms,  0, nil, 15),
        mk(@"cut",       @"Cut",       kCut,       0.5, 20,   ms,  0, nil, 3),
        mk(@"feedback",  @"Feedback",  kFeedback,  0,   0.95, g,   0, nil, 0.3),
        mk(@"fbtone",    @"Repeat Tone", kFbTone,  500, 16000, hz, 0, nil, 6000),
        // LOOKAHEAD sets the reported latency. Non-real-time so hosts never automate it.
        // Default Off: a fresh instance adds NO latency (ECHO/REVERB are live-playable).
        // Picking PRE-VERB in the UI switches it to 1 s; latency still comes only from here.
        mk(@"lookahead", @"Lookahead", kLookahead, 0,   3,    idx, kAudioUnitParameterFlag_NonRealTime, @[@"Off", @"0.5 s", @"1 s", @"2 s"], 0),
        mk(@"length",    @"Swell",     kLength,    0.1, 2.0,  sec, 0, nil, 0.8),
        mk(@"gap",       @"Gap",       kGap,       0,   200,  ms,  0, nil, 0),
    ];
    _parameterTree = [AUParameterTree createTreeWithChildren:params];
    for (AUParameter *p in params) _p[p.address].store(p.value);

    __weak UltraReverseAudioUnit *w = self;
    _parameterTree.implementorValueObserver = ^(AUParameter *p, AUValue v) {
        UltraReverseAudioUnit *s = w; if (!s || p.address >= kNumParams) return;
        const float old = s->_p[p.address].load();
        s->_p[p.address].store(v);
        if (old == v) return;
        if (p.address == kLookahead) [s updateLatency];
        switch (p.address) {   // everything the Pre-Verb kernel is built from
            case kSize: case kDecay: case kDiffusion: case kTone: case kLength: case kGap: case kLookahead:
                [s scheduleIRRender]; break;
            default: break;
        }
    };
    _parameterTree.implementorValueProvider = ^AUValue(AUParameter *p) {
        UltraReverseAudioUnit *s = w; if (!s || p.address >= kNumParams) return 0;
        return s->_p[p.address].load();
    };
    _parameterTree.implementorStringFromValueCallback = ^NSString *(AUParameter *p, const AUValue *vp) {
        AUValue v = vp ? *vp : p.value;
        if (p.valueStrings.count > 0) {
            NSInteger i = MAX(0, MIN((NSInteger)p.valueStrings.count - 1, (NSInteger)lrintf(v)));
            return p.valueStrings[i];
        }
        switch (p.address) {
            case kReverse: case kLength: return [NSString stringWithFormat:@"%.2f s", v];
            case kDecay:   return [NSString stringWithFormat:@"%.1f s", v];
            case kPre: case kGap: case kSmooth: return [NSString stringWithFormat:@"%.0f ms", v];
            case kCut:     return [NSString stringWithFormat:@"%.1f ms", v];
            case kFbTone:  return v >= 1000 ? [NSString stringWithFormat:@"%.1f kHz", v / 1000] : [NSString stringWithFormat:@"%.0f Hz", v];
            case kSize: case kShimmer: case kDiffusion: case kTexture: case kTone: case kMix: case kFeedback:
                return [NSString stringWithFormat:@"%.0f%%", v * 100];
        }
        return [NSString stringWithFormat:@"%.2f", v];
    };
}

// ── Latency / tail ──────────────────────────────────────────────────────────
- (NSTimeInterval)latency { return (double)_latencySamples.load() / _sampleRate; }

- (void)updateLatency {
    const int idx = (int)lrintf(_p[kLookahead].load());
    const int d = (int)lrint(urv::lookaheadSeconds(idx) * _sampleRate);
    if (d == _latencySamples.load()) return;
    [self willChangeValueForKey:@"latency"];
    _latencySamples.store(d);
    [self didChangeValueForKey:@"latency"];
}

- (NSTimeInterval)tailTime {
    // Longest of: reverb decay, repeat tail (segment × repeats to −60 dB),
    // two segments of reversed playback — plus the lookahead and a margin.
    const double seg = std::max(0.1, (double)_dsp->segmentSeconds());
    const double fb = _p[kFeedback].load();
    const double repeats = fb > 0.01 ? std::log(1e-3) / std::log(fb) : 0.0;
    const double t = std::max({(double)_p[kDecay].load(), 2.0 * seg + seg * repeats, (double)_p[kReverse].load() * 2.0});
    return std::min(60.0, t + self.latency + 1.0);
}

// ── Pre-Verb kernel rendering (background, debounced) ─────────────────────
- (urv::IRParams)irParams {
    urv::IRParams ir;
    ir.size = _p[kSize].load(); ir.decay = _p[kDecay].load(); ir.diffusion = _p[kDiffusion].load();
    ir.tone = _p[kTone].load(); ir.lengthSec = _p[kLength].load(); ir.gapMs = _p[kGap].load();
    ir.latencySamples = (int)lrint(urv::lookaheadSeconds((int)lrintf(_p[kLookahead].load())) * _sampleRate);
    return ir;
}

- (void)scheduleIRRender {
    const int gen = ++_irGeneration;
    __weak UltraReverseAudioUnit *w = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), _irQueue, ^{
        UltraReverseAudioUnit *s = w; if (!s || gen != s->_irGeneration.load()) return;   // superseded
        if (!s->_dsp->renderIR([s irParams])) [s scheduleIRRender];                     // busy: retry
    });
}

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)e {
    if (![super allocateRenderResourcesAndReturnError:e]) return NO;
    _sampleRate = _outBus.format.sampleRate;
    const AUAudioFrameCount maxFrames = self.maximumFramesToRender;
    _ownOutBuf.assign((size_t)maxFrames * 2, 0.0f);             // was never sized (REVERSE_PLAN §1.4)
    dispatch_sync(_irQueue, ^{                                  // no render in flight while we rebuild
        _dsp->prepare((float)_sampleRate, (int)maxFrames);
        _dsp->renderIRNow([self irParams]);
    });
    [self updateLatency];
    _musicalContext = self.musicalContextBlock;
    _transportState = self.transportStateBlock;
    return YES;
}
- (void)deallocateRenderResources { [super deallocateRenderResources]; if (_dsp) _dsp->reset(); }

// ── State: old sessions (no marker) come back as BLOOM, lookahead Off ─────
- (NSDictionary<NSString *, id> *)fullState {
    NSMutableDictionary *d = [[super fullState] mutableCopy] ?: [NSMutableDictionary dictionary];
    d[kStateVersionKey] = @2;
    return d;
}
- (void)setFullState:(NSDictionary<NSString *, id> *)fullState {
    [super setFullState:fullState];
    if (fullState && fullState[kStateVersionKey] == nil) {
        [_parameterTree parameterWithAddress:kMode].value = 0;        // Bloom: the pre-2026-11 sound
        [_parameterTree parameterWithAddress:kLookahead].value = 0;   // no added latency
    }
}

- (NSInteger)probeSize { return (NSInteger)urv::ReverseProcessor::probeSize(); }
- (NSInteger)readProbeDry:(float *)dryOut wet:(float *)wetOut count:(NSInteger)count {
    if (!_dsp || !dryOut || !wetOut || count <= 0) return 0;
    NSInteger n = MIN(count, (NSInteger)urv::ReverseProcessor::probeSize());
    _dsp->readProbe(dryOut, wetOut, (int)n);
    return n;
}
- (float)segmentPhase { return _dsp ? _dsp->segmentPhase() : 0.0f; }
- (float)segmentSeconds { return _dsp ? _dsp->segmentSeconds() : 0.0f; }

/// Transport relocation / loop restart: clear tails so stale echoes don't replay.
- (void)reset { if (_dsp) _dsp->reset(); }

- (AUInternalRenderBlock)internalRenderBlock {
    __block urv::ReverseProcessor *dsp = _dsp.get();
    __block std::atomic<float> *P = _p;
    __block std::atomic<int> *lat = &_latencySamples;
    __block std::vector<float> *ownOutBuf = &_ownOutBuf;
    __unsafe_unretained UltraReverseAudioUnit *unsafeSelf = self;
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *fl, const AudioTimeStamp *ts,
                              AVAudioFrameCount n, NSInteger bus, AudioBufferList *out,
                              const AURenderEvent *e, AURenderPullInputBlock pull) {
        // Host buffer contract: NULL mData → render into our own scratch.
        if (out->mNumberBuffers > 0 && out->mBuffers[0].mData == NULL) {
            float *own = ownOutBuf->data(); const size_t cap = ownOutBuf->size() / 2;
            if (!own || (size_t)n > cap) return kAudioUnitErr_TooManyFramesToProcess;
            for (UInt32 b = 0; b < out->mNumberBuffers && b < 2; ++b) {
                out->mBuffers[b].mData = own + (size_t)b * cap;
                out->mBuffers[b].mDataByteSize = (UInt32)(n * sizeof(float));
            }
        }
        if (!pull) {
            for (UInt32 b = 0; b < out->mNumberBuffers; ++b)
                if (out->mBuffers[b].mData) memset(out->mBuffers[b].mData, 0, n * sizeof(float));
            return noErr;
        }
#if defined(__arm64__) || defined(__aarch64__)
        fesetenv(FE_DFL_DISABLE_DENORMS_ENV);
#elif defined(__x86_64__) || defined(__i386__)
        _mm_setcsr(_mm_getcsr() | 0x8040u);   // FTZ | DAZ
#endif
        AudioUnitRenderActionFlags pf = 0;
        AUAudioUnitStatus err = pull(&pf, ts, n, 0, out); if (err != noErr) return err;

        urv::Params p;
        p.reverse = P[kReverse].load(); p.size = P[kSize].load(); p.decay = P[kDecay].load();
        p.shimmer = P[kShimmer].load(); p.diffusion = P[kDiffusion].load(); p.texture = P[kTexture].load();
        p.predelay = P[kPre].load(); p.tone = P[kTone].load(); p.mix = P[kMix].load();
        p.mode = (int)lrintf(P[kMode].load()); p.sync = (int)lrintf(P[kSync].load());
        p.division = (int)lrintf(P[kDivision].load());
        p.smoothMs = P[kSmooth].load(); p.cutMs = P[kCut].load(); p.feedback = P[kFeedback].load();
        p.fbToneHz = P[kFbTone].load(); p.lookahead = (int)lrintf(P[kLookahead].load());
        p.lengthSec = P[kLength].load(); p.gapMs = P[kGap].load();
        dsp->setLatencySamples(lat->load());

        // Host tempo / bar grid (Logic feeds both blocks).
        urv::HostTime ht;
        AUHostMusicalContextBlock mctx = unsafeSelf->_musicalContext;
        if (mctx) {
            double tempo = 0, beat = 0; double tsNum = 4; NSInteger tsDen = 4;
            if (mctx(&tempo, &tsNum, &tsDen, &beat, NULL, NULL)) {
                if (tempo > 0) { ht.hasTempo = true; ht.tempo = tempo; }
                ht.hasBeat = true; ht.beatPos = beat;
                if (tsNum > 0 && tsDen > 0) ht.beatsPerBar = tsNum * 4.0 / (double)tsDen;
            }
        }
        AUHostTransportStateBlock tst = unsafeSelf->_transportState;
        if (tst) {
            AUHostTransportStateFlags f = 0;
            if (tst(&f, NULL, NULL, NULL)) ht.playing = (f & AUHostTransportStateMoving) != 0;
        } else ht.playing = ht.hasBeat;

        if (out->mNumberBuffers < 2) {
            float *m = (float *)out->mBuffers[0].mData;
            dsp->process(p, ht, m, m, m, nullptr, (int)n);   // mono host: averaged into m
        } else {
            float *L = (float *)out->mBuffers[0].mData, *R = (float *)out->mBuffers[1].mData;
            dsp->process(p, ht, L, R, L, R, (int)n);
        }
        return noErr;
    };
}
@end
