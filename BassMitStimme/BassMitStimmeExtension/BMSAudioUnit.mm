#import "BMSAudioUnit.h"
#import "DSP/BMSDSP.hpp"
#include <climits>
#include <cmath>
#include <atomic>
#include <memory>
#include <mutex>
#include <vector>
#include <cstring>
#include <fenv.h>
#if defined(__x86_64__) || defined(__i386__)
#include <xmmintrin.h>
#endif

enum : AUParameterAddress {
    kOct=0, kDet=1, kSub=2, kFmA=3, kFmR=4, kNoi=5,
    kCut=6, kRes=7, kEnv=8,
    kAA=9, kAD=10, kAS=11, kAR=12,
    kFA=13, kFD=14, kFS=15, kFR=16,
    kGain=17, kGlide=18, kMode=19,
    // Stimme (vocal underlay) controls — addresses 20..28
    // 25..28 replaced the old envelope-style controls (start/len/rel) with
    // real FX (drive/tone/air/shimmer). Same address slots, new meaning.
    kStmOn=20, kStmPitch=21, kStmMix=22, kStmFollow=23,
    kStmMode=24, kStmDrive=25, kStmTone=26, kStmAir=27, kStmShimmer=28, kStmReverb=29,
    kStmDist=30,
    // Two-filter front end on the vocal chain + its bypass.
    kStmHP=31, kStmLP=32, kStmFilt=33,
    // HARMONIZER (2026-11-20): on, interval set, sub-octave, KEY (0-11), SCALE (KEYS list)
    kHarmOn=34, kHarmMode=35, kHarmSub=36, kHarmKey=37, kHarmScale=38,
    // STRETCH / WARP (2026-11-21): length factor, warp mode, formant keep.
    kStmStretch=39, kStmWarp=40, kStmFormant=41
};

/// One loaded vocal. Created and freed on the main/state thread only; the
/// render thread just borrows it (see the lock-free handoff below).
struct BMSStimmeBuf {
    std::vector<float> pcm;
    double sr = 48000.0;
    int onset = 0;
};

@interface BMSAudioUnit ()
@property (nonatomic) AUAudioUnitBusArray *outputBusArray;
@end

@implementation BMSAudioUnit {
    std::vector<float> _ownOutBuf;   // scratch output (2 ch) for hosts that pass NULL mData
    std::unique_ptr<bms::Engine> _dsp;
    AUAudioUnitBus *_outBus;
    AVAudioFormat *_format;
    std::atomic<float> _oct, _det, _sub, _fmA, _fmR, _noi;
    std::atomic<float> _cut, _res, _env;
    std::atomic<float> _aa, _ad, _as, _ar;
    std::atomic<float> _fa, _fd, _fs, _fr;
    std::atomic<float> _gain, _glide, _mode;
    std::atomic<float> _stmOn, _stmPitch, _stmMix, _stmFollow, _stmMode;
    std::atomic<float> _stmDrive, _stmTone, _stmAir, _stmShimmer, _stmReverb, _stmDist;
    std::atomic<float> _stmHP, _stmLP, _stmFilt;
    std::atomic<float> _harmOn, _harmMode, _harmSub, _harmKey, _harmScale;
    std::atomic<float> _stmStretch, _stmWarp, _stmFormant;

    // ── Vocal buffer handoff (lock-free on the render side) ──
    // Main/state thread builds a BMSStimmeBuf (onset precomputed), publishes
    // it in _rtPending; the render block takes it at the top of a block,
    // hands the previous one back through the _retire ring and never frees,
    // locks or allocates. The main side frees retired buffers later.
    // (The old code swapped a std::vector under a mutex the render thread only
    // try-locked for hosts with NULL mData — i.e. normally not at all.)
    std::mutex _stimmeMutex;                       // main/state side only
    BMSStimmeBuf *_stimmeLatest;                   // what the UI / fullState see
    NSString *_stimmeName;
    std::atomic<BMSStimmeBuf *> _rtPending;
    BMSStimmeBuf *_rtCurrent;                      // render thread (or no render running)
    enum { kRetireMax = 16 };
    BMSStimmeBuf *_retire[kRetireMax];
    std::atomic<int> _retW, _retR;

    // Host transport snapshot — read from Logic each render block and exposed
    // to the KEYS sequencer so its generated melody locks to the project clock.
    std::atomic<float>  _hostBPM;
    std::atomic<float>  _hostBarBeats;   // bar length in quarter notes (time signature)
    std::atomic<double> _hostBeat;
    std::atomic<bool>   _hostPlaying;

    // ── UI note queue (main → render) ──
    enum { kPendMax = 64 };
    struct PendNote { int note; int vel; } _pend[kPendMax];
    std::atomic<int> _pendW, _pendR;
    double _renderSR;                     // set in allocateRenderResources
    // ── KEYS sequencer (render-thread, host-locked) ──
    enum { kSeqMax = 64 };
    int                 _seqNotes[kSeqMax];
    std::atomic<int>    _seqCount;
    std::atomic<double> _seqStepBeats;
    std::atomic<double> _seqGate;
    std::atomic<int>    _seqArmed;
    std::atomic<int>    _seqStep;      // sounding step (UI readback)
    std::atomic<int>    _seqNote;      // sounding note (UI readback)
    long long           _seqLastAbs;   // last absolute step fired
    int                 _seqNoteOn;    // note currently held by the sequencer, -1 none
    double              _seqNoteOnBeat;
    double              _seqFreeBeat;  // fallback clock while the host is stopped
}
@synthesize parameterTree = _parameterTree;
@synthesize stimmeSampleName = _stimmeName;

- (instancetype)initWithComponentDescription:(AudioComponentDescription)d options:(AudioComponentInstantiationOptions)o error:(NSError **)e {
    self = [super initWithComponentDescription:d options:o error:e]; if (!self) return nil;
    _dsp = std::make_unique<bms::Engine>(); _dsp->prepare(48000);
    _format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    _outBus = [[AUAudioUnitBus alloc] initWithFormat:_format error:nil];
    _outputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[_outBus]];
    _stimmeName = @"— EMPTY —";
    _stimmeLatest = nullptr; _rtPending.store(nullptr); _rtCurrent = nullptr;
    _retW.store(0); _retR.store(0);
    [self build];
    [self loadBundledStimme];
    return self;
}
- (AUAudioUnitBusArray *)outputBusses { return _outputBusArray; }

- (AUParameter *)pInt:(NSString *)ident name:(NSString *)nm addr:(AUParameterAddress)a min:(float)lo max:(float)hi def:(float)d unit:(AudioUnitParameterUnit)u {
    AUParameter *p = [AUParameterTree createParameterWithIdentifier:ident name:nm address:a min:lo max:hi unit:u unitName:nil flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable) valueStrings:nil dependentParameters:nil];
    p.value = d; return p;
}

- (AUParameter *)pIdx:(NSString *)ident name:(NSString *)nm addr:(AUParameterAddress)a names:(NSArray<NSString *> *)names def:(float)d {
    AUParameter *p = [AUParameterTree createParameterWithIdentifier:ident name:nm address:a min:0 max:(AUValue)(names.count - 1)
                        unit:kAudioUnitParameterUnit_Indexed unitName:nil
                       flags:(kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable)
                valueStrings:names dependentParameters:nil];
    p.value = d; return p;
}

- (void)build {
    AudioUnitParameterUnit Hz = kAudioUnitParameterUnit_Hertz, sec = kAudioUnitParameterUnit_Seconds, g = kAudioUnitParameterUnit_LinearGain, idx = kAudioUnitParameterUnit_Indexed, ms = kAudioUnitParameterUnit_Milliseconds, bl = kAudioUnitParameterUnit_Boolean;

    NSArray *ps = @[
        [self pInt:@"oct"   name:@"OSC Oct"    addr:kOct min:-2 max:2  def:0    unit:idx],
        [self pInt:@"det"   name:@"Detune"     addr:kDet min:-50 max:50 def:6   unit:idx],
        [self pInt:@"sub"   name:@"Sub"        addr:kSub min:0 max:1   def:0.7  unit:g],
        [self pInt:@"fmA"   name:@"FM Growl"   addr:kFmA min:0 max:1   def:0    unit:g],
        [self pInt:@"fmR"   name:@"FM Ratio"   addr:kFmR min:0.25 max:8 def:1.5 unit:g],
        [self pInt:@"noi"   name:@"Noise"      addr:kNoi min:0 max:1   def:0    unit:g],
        [self pInt:@"cut"   name:@"Cutoff"     addr:kCut min:20 max:18000 def:600 unit:Hz],
        [self pInt:@"res"   name:@"Reso"       addr:kRes min:0 max:1   def:0.25 unit:g],
        [self pInt:@"env"   name:@"Env Amt"    addr:kEnv min:-1 max:1  def:0.4  unit:g],
        [self pInt:@"aA"    name:@"Amp A"      addr:kAA  min:0.001 max:4 def:0.005 unit:sec],
        [self pInt:@"aD"    name:@"Amp D"      addr:kAD  min:0.001 max:4 def:0.18  unit:sec],
        [self pInt:@"aS"    name:@"Amp S"      addr:kAS  min:0 max:1     def:0.7   unit:g],
        [self pInt:@"aR"    name:@"Amp R"      addr:kAR  min:0.001 max:4 def:0.32  unit:sec],
        [self pInt:@"fA"    name:@"Filt A"     addr:kFA  min:0.001 max:4 def:0.002 unit:sec],
        [self pInt:@"fD"    name:@"Filt D"     addr:kFD  min:0.001 max:4 def:0.2   unit:sec],
        [self pInt:@"fS"    name:@"Filt S"     addr:kFS  min:0 max:1     def:0.5   unit:g],
        [self pInt:@"fR"    name:@"Filt R"     addr:kFR  min:0.001 max:4 def:0.4   unit:sec],
        [self pInt:@"gain"  name:@"Gain"       addr:kGain  min:0 max:2   def:1.0   unit:g],
        [self pInt:@"glide" name:@"Glide"      addr:kGlide min:0 max:1000 def:45   unit:ms],
        [self pInt:@"mode"  name:@"Mode"       addr:kMode  min:0 max:2   def:1    unit:idx],
        // Stimme (vocal layer) — sample always underlays the bass
        [self pInt:@"stmOn"      name:@"Stimme"        addr:kStmOn      min:0 max:1   def:1    unit:bl],
        [self pInt:@"stmPitch"   name:@"Pitch"         addr:kStmPitch   min:-24 max:24 def:0   unit:idx],
        [self pInt:@"stmMix"     name:@"Mix"           addr:kStmMix     min:0 max:1   def:0.55 unit:g],
        [self pInt:@"stmFollow"  name:@"Follow"        addr:kStmFollow  min:0 max:1   def:1    unit:bl],
        [self pInt:@"stmMode"    name:@"Mode"          addr:kStmMode    min:0 max:2   def:2    unit:idx],
        // NEW vocal FX — replaced the old envelope-ish controls
        [self pInt:@"stmDrive"   name:@"Drive"         addr:kStmDrive   min:0 max:1   def:0.0  unit:g],
        [self pInt:@"stmTone"    name:@"Tone"          addr:kStmTone    min:0 max:1   def:0.5  unit:g],
        [self pInt:@"stmAir"     name:@"Air"           addr:kStmAir     min:0 max:1   def:0.0  unit:g],
        [self pInt:@"stmShimmer" name:@"Shimmer"       addr:kStmShimmer min:0 max:1   def:0.0  unit:g],
        [self pInt:@"stmReverb"  name:@"Reverb"        addr:kStmReverb  min:0 max:1   def:0.0  unit:g],
        [self pInt:@"stmDist"    name:@"Distortion"    addr:kStmDist    min:0 max:1   def:0.0  unit:g],
        // Two-filter front end. Defaults are wide open, so an existing
        // session sounds exactly as it did before these were added.
        [self pInt:@"stmHP"      name:@"HP Filter"     addr:kStmHP      min:0 max:1   def:0.0  unit:g],
        [self pInt:@"stmLP"      name:@"LP Filter"     addr:kStmLP      min:0 max:1   def:1.0  unit:g],
        [self pInt:@"stmFilt"    name:@"Filters"       addr:kStmFilt    min:0 max:1   def:1    unit:bl],
        // HARMONIZER — off by default so existing sessions sound unchanged.
        [self pInt:@"harmOn"     name:@"Harmonizer"    addr:kHarmOn     min:0 max:1   def:0    unit:bl],
        [self pInt:@"harmMode"   name:@"Harm Interval" addr:kHarmMode   min:0 max:3   def:0    unit:idx],
        [self pInt:@"harmSub"    name:@"Harm Sub"      addr:kHarmSub    min:0 max:1   def:0    unit:bl],
        [self pInt:@"harmKey"    name:@"Key"           addr:kHarmKey    min:0 max:11  def:0    unit:idx],
        [self pInt:@"harmScale"  name:@"Scale"         addr:kHarmScale  min:0 max:4   def:0    unit:idx],
        // STRETCH / WARP — defaults = classic varispeed, so old sessions load
        // and sound exactly as before.
        [self pInt:@"stmStretch" name:@"Stretch"       addr:kStmStretch min:0.25 max:4 def:1.0 unit:kAudioUnitParameterUnit_Rate],
        [self pIdx:@"stmWarp"    name:@"Warp"          addr:kStmWarp
              names:@[@"Off", @"Free", @"1/4 Beat", @"1/2 Beat", @"1 Beat", @"2 Beats", @"1 Bar", @"2 Bars", @"4 Bars"] def:0],
        [self pInt:@"stmFormant" name:@"Formant"       addr:kStmFormant min:0 max:1   def:1    unit:bl],
    ];
    _parameterTree = [AUParameterTree createTreeWithChildren:ps];

    _oct.store(0); _det.store(6); _sub.store(0.7f); _fmA.store(0); _fmR.store(1.5f); _noi.store(0);
    _cut.store(600); _res.store(0.25f); _env.store(0.4f);
    _aa.store(0.005f); _ad.store(0.18f); _as.store(0.7f); _ar.store(0.32f);
    _fa.store(0.002f); _fd.store(0.2f); _fs.store(0.5f); _fr.store(0.4f);
    _gain.store(1.0f); _glide.store(45); _mode.store(1);
    _stmOn.store(1); _stmPitch.store(0); _stmMix.store(0.55f); _stmFollow.store(1);
    _stmMode.store(2);
    _stmDrive.store(0.0f); _stmTone.store(0.5f); _stmAir.store(0.0f); _stmShimmer.store(0.0f); _stmReverb.store(0.0f); _stmDist.store(0.0f);
    _stmHP.store(0.0f); _stmLP.store(1.0f); _stmFilt.store(1.0f);
    _harmOn.store(0); _harmMode.store(0); _harmSub.store(0); _harmKey.store(0); _harmScale.store(0);
    _stmStretch.store(1.0f); _stmWarp.store(0); _stmFormant.store(1);
    _hostBarBeats.store(4.0f);
    _hostBPM.store(120.0f); _hostBeat.store(0.0); _hostPlaying.store(false);
    _pendW.store(0); _pendR.store(0); _renderSR = 48000.0;
    for (int i = 0; i < kSeqMax; ++i) _seqNotes[i] = -1;
    _seqCount.store(0); _seqStepBeats.store(0.25); _seqGate.store(0.7); _seqArmed.store(0);
    _seqStep.store(-1); _seqNote.store(-1); _seqLastAbs = LLONG_MIN; _seqNoteOn = -1; _seqNoteOnBeat = 0; _seqFreeBeat = 0;

    __weak BMSAudioUnit *w = self;
    _parameterTree.implementorValueObserver = ^(AUParameter *p, AUValue v) {
        BMSAudioUnit *s = w; if (!s) return;
        switch (p.address) {
            case kOct: s->_oct.store(v); break; case kDet: s->_det.store(v); break;
            case kSub: s->_sub.store(v); break; case kFmA: s->_fmA.store(v); break;
            case kFmR: s->_fmR.store(v); break; case kNoi: s->_noi.store(v); break;
            case kCut: s->_cut.store(v); break; case kRes: s->_res.store(v); break;
            case kEnv: s->_env.store(v); break;
            case kAA:  s->_aa.store(v); break; case kAD:  s->_ad.store(v); break;
            case kAS:  s->_as.store(v); break; case kAR:  s->_ar.store(v); break;
            case kFA:  s->_fa.store(v); break; case kFD:  s->_fd.store(v); break;
            case kFS:  s->_fs.store(v); break; case kFR:  s->_fr.store(v); break;
            case kGain:s->_gain.store(v); break; case kGlide: s->_glide.store(v); break;
            case kMode:s->_mode.store(v); break;
            case kStmOn:      s->_stmOn.store(v); break;
            case kStmPitch:   s->_stmPitch.store(v); break;
            case kStmMix:     s->_stmMix.store(v); break;
            case kStmFollow:  s->_stmFollow.store(v); break;
            case kStmMode:    s->_stmMode.store(v); break;
            case kStmDrive:   s->_stmDrive.store(v); break;
            case kStmTone:    s->_stmTone.store(v); break;
            case kStmAir:     s->_stmAir.store(v); break;
            case kStmShimmer: s->_stmShimmer.store(v); break;
            case kStmReverb:  s->_stmReverb.store(v); break;
            case kStmDist:    s->_stmDist.store(v); break;
            case kStmHP:      s->_stmHP.store(v); break;
            case kStmLP:      s->_stmLP.store(v); break;
            case kStmFilt:    s->_stmFilt.store(v); break;
            case kHarmOn:     s->_harmOn.store(v); break;
            case kHarmMode:   s->_harmMode.store(v); break;
            case kHarmSub:    s->_harmSub.store(v); break;
            case kHarmKey:    s->_harmKey.store(v); break;
            case kHarmScale:  s->_harmScale.store(v); break;
            case kStmStretch: s->_stmStretch.store(v); break;
            case kStmWarp:    s->_stmWarp.store(v); break;
            case kStmFormant: s->_stmFormant.store(v); break;
        }
    };
    _parameterTree.implementorValueProvider = ^AUValue(AUParameter *p) {
        BMSAudioUnit *s = w; if (!s) return 0;
        switch (p.address) {
            case kOct: return s->_oct.load(); case kDet: return s->_det.load();
            case kSub: return s->_sub.load(); case kFmA: return s->_fmA.load();
            case kFmR: return s->_fmR.load(); case kNoi: return s->_noi.load();
            case kCut: return s->_cut.load(); case kRes: return s->_res.load();
            case kEnv: return s->_env.load();
            case kAA: return s->_aa.load(); case kAD: return s->_ad.load();
            case kAS: return s->_as.load(); case kAR: return s->_ar.load();
            case kFA: return s->_fa.load(); case kFD: return s->_fd.load();
            case kFS: return s->_fs.load(); case kFR: return s->_fr.load();
            case kGain: return s->_gain.load(); case kGlide: return s->_glide.load();
            case kMode: return s->_mode.load();
            case kStmOn: return s->_stmOn.load(); case kStmPitch: return s->_stmPitch.load();
            case kStmMix: return s->_stmMix.load(); case kStmFollow: return s->_stmFollow.load();
            case kStmMode: return s->_stmMode.load();
            case kStmDrive: return s->_stmDrive.load();
            case kStmTone: return s->_stmTone.load();
            case kStmAir: return s->_stmAir.load();
            case kStmShimmer: return s->_stmShimmer.load();
            case kStmReverb:  return s->_stmReverb.load();
            case kStmDist:    return s->_stmDist.load();
            case kStmHP:      return s->_stmHP.load();
            case kStmLP:      return s->_stmLP.load();
            case kStmFilt:    return s->_stmFilt.load();
            case kHarmOn:     return s->_harmOn.load();
            case kHarmMode:   return s->_harmMode.load();
            case kHarmSub:    return s->_harmSub.load();
            case kHarmKey:    return s->_harmKey.load();
            case kHarmScale:  return s->_harmScale.load();
            case kStmStretch: return s->_stmStretch.load();
            case kStmWarp:    return s->_stmWarp.load();
            case kStmFormant: return s->_stmFormant.load();
        }
        return 0;
    };
}

#pragma mark - Stimme sample loading

/// Load the bundled Stimme.m4a (placed in Resources/) at AU init time.
- (void)loadBundledStimme {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSURL *url = [bundle URLForResource:@"Stimme" withExtension:@"m4a"];
    if (!url) return;

    AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:nil];
    if (!file) return;
    AVAudioFormat *srcFmt = file.processingFormat;
    AVAudioFrameCount frames = (AVAudioFrameCount)file.length;
    AVAudioPCMBuffer *srcBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:srcFmt frameCapacity:frames];
    if (!srcBuf || ![file readIntoBuffer:srcBuf error:nil]) return;

    AVAudioFormat *dstFmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                            sampleRate:srcFmt.sampleRate
                                                              channels:1
                                                          interleaved:NO];
    AVAudioConverter *cv = [[AVAudioConverter alloc] initFromFormat:srcFmt toFormat:dstFmt];
    AVAudioPCMBuffer *dstBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:dstFmt frameCapacity:srcBuf.frameLength];
    __block BOOL provided = NO;
    [cv convertToBuffer:dstBuf error:nil withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount inNumberOfPackets, AVAudioConverterInputStatus *outStatus) {
        if (provided) { *outStatus = AVAudioConverterInputStatus_NoDataNow; return nil; }
        provided = YES;
        *outStatus = AVAudioConverterInputStatus_HaveData;
        return srcBuf;
    }];

    const float *src = dstBuf.floatChannelData ? dstBuf.floatChannelData[0] : NULL;
    const int n = (int)dstBuf.frameLength;
    if (!src || n < 2) return;
    [self setStimmeSampleData:src length:n sampleRate:srcFmt.sampleRate name:@"Stimme.m4a"];
}

- (void)setStimmeSampleData:(const float *)data length:(NSInteger)length sampleRate:(double)srcSR name:(NSString *)name {
    // Build the new buffer (and its onset — an O(n) scan) off the render thread.
    BMSStimmeBuf *nb = new BMSStimmeBuf();
    nb->sr = srcSR > 0 ? srcSR : 48000.0;
    if (data && length >= 2) {
        nb->pcm.assign(data, data + length);
        nb->onset = bms::VocalLayer::computeOnset(nb->pcm.data(), (int)nb->pcm.size(), (float)nb->sr);
    }
    std::lock_guard<std::mutex> lk(_stimmeMutex);
    [self drainRetiredLocked];
    _stimmeLatest = nb;
    _stimmeName = nb->pcm.empty() ? @"— EMPTY —" : (name.length ? [name copy] : @"loaded");
    // Publish. A buffer still waiting in the slot was never seen by the
    // render thread, so it can go right away.
    BMSStimmeBuf *stale = _rtPending.exchange(nb, std::memory_order_acq_rel);
    delete stale;
}

/// Free buffers the render thread has handed back. Caller holds _stimmeMutex.
- (void)drainRetiredLocked {
    for (int r = _retR.load(std::memory_order_relaxed); r != _retW.load(std::memory_order_acquire); ++r) {
        BMSStimmeBuf *b = _retire[r & (kRetireMax - 1)];
        if (b && b != _stimmeLatest && b != _rtPending.load()) delete b;
        _retR.store(r + 1, std::memory_order_release);
    }
}

/// Render-stopped install (allocateRenderResources): take the pending buffer
/// directly and hand it to the freshly prepared engine.
- (void)installStimmeWhileStopped {
    BMSStimmeBuf *p = _rtPending.exchange(nullptr, std::memory_order_acq_rel);
    if (p) {
        std::lock_guard<std::mutex> lk(_stimmeMutex);
        if (_rtCurrent && _rtCurrent != _stimmeLatest && _rtCurrent != p) delete _rtCurrent;
        _rtCurrent = p;
    }
    if (_rtCurrent && !_rtCurrent->pcm.empty())
        _dsp->stimme().setSample(_rtCurrent->pcm.data(), (int)_rtCurrent->pcm.size(), (float)_rtCurrent->sr, _rtCurrent->onset);
    else
        _dsp->stimme().setSample(nullptr, 0, 48000.0f, 0);
}

- (void)dealloc {
    std::lock_guard<std::mutex> lk(_stimmeMutex);
    std::vector<BMSStimmeBuf *> all = { _stimmeLatest, _rtPending.load(), _rtCurrent };
    for (int r = _retR.load(); r != _retW.load(); ++r) all.push_back(_retire[r & (kRetireMax - 1)]);
    std::sort(all.begin(), all.end()); all.erase(std::unique(all.begin(), all.end()), all.end());
    for (BMSStimmeBuf *b : all) delete b;
}

- (const float *)stimmeSampleData {
    std::lock_guard<std::mutex> lk(_stimmeMutex);
    return (_stimmeLatest && !_stimmeLatest->pcm.empty()) ? _stimmeLatest->pcm.data() : NULL;
}
- (NSInteger)stimmeSampleLength {
    std::lock_guard<std::mutex> lk(_stimmeMutex);
    return _stimmeLatest ? (NSInteger)_stimmeLatest->pcm.size() : 0;
}
- (double)stimmeSampleRate {
    std::lock_guard<std::mutex> lk(_stimmeMutex);
    return _stimmeLatest ? _stimmeLatest->sr : 48000.0;
}
- (NSInteger)stimmeSampleOnset {
    std::lock_guard<std::mutex> lk(_stimmeMutex);
    return _stimmeLatest ? (NSInteger)_stimmeLatest->onset : 0;
}
- (float)stimmePlayhead { return _dsp ? _dsp->stimme().currentPosition() : 0.0f; }
// Computed from the parameters (same rule as VocalLayer::effectiveStretch),
// so the UI is right even while the host is not rendering.
- (BOOL)stimmeWarpEngaged {
    return std::lround(_stmWarp.load()) != 0 || std::fabs(_stmStretch.load() - 1.0f) > 1e-4f;
}
- (float)stimmeStretchFactor {
    if (!self.stimmeWarpEngaged) return 1.0f;
    const int m = (int)std::lround(_stmWarp.load());
    if (m >= 2) {
        std::lock_guard<std::mutex> lk(_stimmeMutex);
        if (_stimmeLatest && _stimmeLatest->pcm.size() > 1) {
            float beats = bms::VocalLayer::warpBeats(m);
            if (beats < 0) beats = -beats * _hostBarBeats.load();
            const double targetSec = beats * 60.0 / std::max(20.0f, _hostBPM.load());
            const double srcSec = (double)std::max<long>(1, (long)_stimmeLatest->pcm.size() - _stimmeLatest->onset) / _stimmeLatest->sr;
            return (float)std::max(0.125, std::min(8.0, targetSec / srcSec));
        }
        return 1.0f;
    }
    return std::max(0.25f, std::min(4.0f, _stmStretch.load()));
}

// CHARACTER is a plain property and the dropped vocal lives outside the
// parameter tree — carry both in the state dictionary. The bundled default
// sample is not embedded (it ships with the plug-in).
- (NSDictionary<NSString *, id> *)fullState {
    NSMutableDictionary *st = [[super fullState] mutableCopy] ?: [NSMutableDictionary dictionary];
    st[@"bmsCharacter"] = @(self.analogCharacter);
    std::lock_guard<std::mutex> lk(_stimmeMutex);
    if (_stimmeLatest && !_stimmeLatest->pcm.empty() && ![_stimmeName isEqualToString:@"Stimme.m4a"]) {
        st[@"bmsStimmePCM"]  = [NSData dataWithBytes:_stimmeLatest->pcm.data() length:_stimmeLatest->pcm.size() * sizeof(float)];
        st[@"bmsStimmeSR"]   = @(_stimmeLatest->sr);
        st[@"bmsStimmeName"] = _stimmeName ?: @"loaded";
    }
    return st;
}
- (void)setFullState:(NSDictionary<NSString *, id> *)fullState {
    // States saved before STRETCH / WARP existed carry no value for 39-41:
    // put them on their defaults first, so such a session / preset restores
    // the classic sound even into an instance that had WARP switched on.
    [self.parameterTree parameterWithAddress:kStmStretch].value = 1.0f;
    [self.parameterTree parameterWithAddress:kStmWarp].value    = 0.0f;
    [self.parameterTree parameterWithAddress:kStmFormant].value = 1.0f;
    [super setFullState:fullState];
    id ch = fullState[@"bmsCharacter"];
    if ([ch isKindOfClass:[NSNumber class]]) self.analogCharacter = [ch intValue];
    NSData *pcm = fullState[@"bmsStimmePCM"]; id sr = fullState[@"bmsStimmeSR"]; id nm = fullState[@"bmsStimmeName"];
    if ([pcm isKindOfClass:[NSData class]] && pcm.length >= 2 * sizeof(float) && [sr isKindOfClass:[NSNumber class]]) {
        [self setStimmeSampleData:(const float *)pcm.bytes length:(NSInteger)(pcm.length / sizeof(float))
                       sampleRate:[sr doubleValue] name:[nm isKindOfClass:[NSString class]] ? nm : @"loaded"];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"BMSDidRestoreState" object:self];
        });
    }
}

- (int)analogCharacter { return _dsp ? _dsp->character() : 0; }
- (void)setAnalogCharacter:(int)c { if (_dsp) _dsp->setCharacter(c); }

// Host transport snapshot for the KEYS sequencer.
- (double)hostBPM          { return (double)_hostBPM.load(); }
- (double)hostBeatPosition { return _hostBeat.load(); }
- (BOOL)hostIsPlaying      { return _hostPlaying.load() ? YES : NO; }

// On-screen KEYS → same path as host MIDI. Mirrors the codebase convention of
// driving the DSP straight from the UI thread (cf. DrumsAudioUnit triggerVoice).
// The KEYS keyboard used to call the engine straight from the main thread
// while the sequencer called it from the render thread — a data race on the
// voice list and on the held-key count (vocal layer droning on / never
// starting). Queue the events and let the render block play them.
- (void)enqueueNote:(int)midiNote vel:(int)vel {
    const int w = _pendW.load(std::memory_order_relaxed);
    if (w - _pendR.load(std::memory_order_acquire) >= kPendMax) return;   // full: drop
    _pend[w & (kPendMax - 1)] = { midiNote, vel };
    _pendW.store(w + 1, std::memory_order_release);
}
- (void)playNote:(int)midiNote velocity:(float)vel {
    if (!_dsp) return;
    int v = (int)std::lround(std::fmin(127.0f, std::fmax(1.0f, vel * 127.0f)));
    [self enqueueNote:midiNote vel:v];
}
- (void)stopNote:(int)midiNote { if (_dsp) [self enqueueNote:midiNote vel:0]; }

#pragma mark - KEYS sequencer
- (void)setSequencerMelody:(NSArray<NSNumber *> *)notes stepBeats:(double)stepBeats gate:(double)gate {
    const int n = (int)MIN((NSInteger)kSeqMax, notes.count);
    for (int i = 0; i < n; ++i) _seqNotes[i] = notes[i].intValue;
    _seqCount.store(n);
    _seqStepBeats.store(MAX(0.0625, stepBeats));
    _seqGate.store(MIN(1.0, MAX(0.05, gate)));
}
- (BOOL)sequencerArmed { return _seqArmed.load() != 0; }
- (void)setSequencerArmed:(BOOL)armed {
    if (armed && !_seqArmed.load()) { _seqLastAbs = LLONG_MIN; _seqFreeBeat = 0; }
    _seqArmed.store(armed ? 1 : 0);
}
- (int)sequencerStep { return _seqArmed.load() ? _seqStep.load() : -1; }
- (int)sequencerNote { return _seqArmed.load() ? _seqNote.load() : -1; }

- (NSInteger)probeSize { return (NSInteger)bms::Engine::probeSize(); }
- (NSInteger)readProbeBass:(float *)bassOut vox:(float *)voxOut count:(NSInteger)count {
    if (!_dsp || !bassOut || !voxOut || count <= 0) return 0;
    const NSInteger n = MIN(count, (NSInteger)bms::Engine::probeSize());
    _dsp->readProbe(bassOut, voxOut, (int)n);
    return n;
}

#pragma mark - Render

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)e {
    if (![super allocateRenderResourcesAndReturnError:e]) return NO;
    _renderSR = _outBus.format.sampleRate > 0 ? _outBus.format.sampleRate : 48000.0;
    _ownOutBuf.assign((size_t)MAX((AUAudioFrameCount)512, self.maximumFramesToRender) * 2, 0.0f);
    _dsp->prepare((float)_outBus.format.sampleRate);
    // Re-supply the buffer after the engine reset (prepare zeroes state), with
    // its *original* source rate so the varispeed ratio (srcSR/engineSR) stays
    // right. Render is not running here, so a pending buffer installs directly.
    [self installStimmeWhileStopped];
    return YES;
}
- (void)deallocateRenderResources { [super deallocateRenderResources]; if (_dsp) _dsp->reset(); }

- (AUInternalRenderBlock)internalRenderBlock {
    __block bms::Engine *dsp = _dsp.get();
    __block std::atomic<float> *aOct=&_oct,*aDet=&_det,*aSub=&_sub,*aFmA=&_fmA,*aFmR=&_fmR,*aNoi=&_noi;
    __block std::atomic<float> *aCut=&_cut,*aRes=&_res,*aEnv=&_env;
    __block std::atomic<float> *aAA=&_aa,*aAD=&_ad,*aAS=&_as,*aAR=&_ar;
    __block std::atomic<float> *aFA=&_fa,*aFD=&_fd,*aFS=&_fs,*aFR=&_fr;
    __block std::atomic<float> *aG=&_gain,*aGl=&_glide,*aMo=&_mode;
    __block std::atomic<float> *aSon=&_stmOn,*aSpt=&_stmPitch,*aSmx=&_stmMix,*aSfo=&_stmFollow;
    __block std::atomic<float> *aSmd=&_stmMode;
    __block std::atomic<float> *aSdr=&_stmDrive,*aStn=&_stmTone,*aSair=&_stmAir,*aSsh=&_stmShimmer,*aSrv=&_stmReverb,*aSdist=&_stmDist;
    __block std::atomic<float> *aShp=&_stmHP,*aSlp=&_stmLP,*aSflt=&_stmFilt;
    __block std::atomic<float> *aHon=&_harmOn,*aHmo=&_harmMode,*aHsu=&_harmSub,*aHky=&_harmKey,*aHsc=&_harmScale;
    __block std::atomic<float>  *aHB   = &_hostBPM;
    __block std::atomic<double> *aHBt  = &_hostBeat;
    __block std::atomic<bool>   *aHPl  = &_hostPlaying;
    __unsafe_unretained BMSAudioUnit *us = self;
    // Plain pointers (captured by value into the block) — a C++ lambda inside
    // the block can't capture __block variables, so none of these are __block.
    int *seqNotes = _seqNotes;
    std::atomic<int> *seqCount = &_seqCount, *seqArmed = &_seqArmed, *seqStep = &_seqStep, *seqNoteOut = &_seqNote;
    std::atomic<double> *seqStepBeats = &_seqStepBeats, *seqGate = &_seqGate;
    long long *seqLastAbs = &_seqLastAbs;
    int *seqNoteOn = &_seqNoteOn;
    double *seqNoteOnBeat = &_seqNoteOnBeat, *seqFreeBeat = &_seqFreeBeat;
    __block double *renderSR = &_renderSR;          // refreshed in allocateRenderResources
    __block std::atomic<float> *aSst=&_stmStretch,*aSwp=&_stmWarp,*aSfm=&_stmFormant;
    __block std::atomic<float> *aBar=&_hostBarBeats;
    std::atomic<BMSStimmeBuf *> *rtPending = &_rtPending;
    BMSStimmeBuf **rtCurrent = &_rtCurrent;
    BMSStimmeBuf **retire = _retire;
    std::atomic<int> *retW = &_retW, *retR = &_retR;
    __block PendNote *pend = _pend;
    __block std::atomic<int> *pendW = &_pendW, *pendR = &_pendR;
    bms::Engine *seqEngine = _dsp.get();
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
        // New vocal buffer? Take it (lock-free), hand the old one back to the
        // main thread for freeing. If the retire ring is full, wait a block.
        if (rtPending->load(std::memory_order_acquire) &&
            retW->load(std::memory_order_relaxed) - retR->load(std::memory_order_acquire) < kRetireMax) {
            BMSStimmeBuf *p = rtPending->exchange(nullptr, std::memory_order_acq_rel);
            if (p) {
                if (*rtCurrent) {
                    const int w = retW->load(std::memory_order_relaxed);
                    retire[w & (kRetireMax - 1)] = *rtCurrent;
                    retW->store(w + 1, std::memory_order_release);
                }
                *rtCurrent = p;
                if (!p->pcm.empty()) dsp->stimme().setSample(p->pcm.data(), (int)p->pcm.size(), (float)p->sr, p->onset);
                else                 dsp->stimme().setSample(nullptr, 0, 48000.0f, 0);
            }
        }
        // Snapshot Logic's tempo / beat position / transport so the KEYS
        // sequencer can lock its generated melody to the project bar grid.
        AUHostMusicalContextBlock mctx = us.musicalContextBlock;
        if (mctx) {
            double tempo = 0, beat = 0, tsNum = 0; NSInteger tsDen = 0;
            if (mctx(&tempo, &tsNum, &tsDen, &beat, NULL, NULL)) {
                if (tempo > 0) aHB->store((float)tempo);
                aHBt->store(beat);
                if (tsNum > 0 && tsDen > 0) aBar->store((float)(tsNum * 4.0 / (double)tsDen));
            }
        }
        AUHostTransportStateBlock tsb = us.transportStateBlock;
        if (tsb) {
            AUHostTransportStateFlags tf = 0;
            if (tsb(&tf, NULL, NULL, NULL)) aHPl->store((tf & AUHostTransportStateMoving) != 0);
        }
        // Flush denormals to zero on this audio thread. Without this,
        // decaying filter / reverb tails hit subnormal floats and CPU spikes.
#if defined(__arm64__) || defined(__aarch64__)
        fesetenv(FE_DFL_DISABLE_DENORMS_ENV);
#elif defined(__x86_64__) || defined(__i386__)
        // MXCSR bit 15 = FTZ, bit 6 = DAZ. Together = 0x8040.
        _mm_setcsr(_mm_getcsr() | 0x8040u);
#endif
        dsp->setOct((int)std::round(aOct->load())); dsp->setDetune(aDet->load());
        dsp->setSub(aSub->load()); dsp->setFM(aFmA->load(), aFmR->load());
        dsp->setNoise(aNoi->load());
        dsp->setFilter(aCut->load(), aRes->load(), aEnv->load());
        dsp->setAmpADSR(aAA->load(), aAD->load(), aAS->load(), aAR->load());
        dsp->setFltADSR(aFA->load(), aFD->load(), aFS->load(), aFR->load());
        dsp->setGain(aG->load()); dsp->setGlideMs(aGl->load()); dsp->setMode((int)std::round(aMo->load()));

        // Stimme params
        dsp->stimme().setEnabled(aSon->load() >= 0.5f);
        dsp->stimme().setPitchSemi(aSpt->load());
        dsp->stimme().setMix(aSmx->load());
        dsp->stimme().setFollow(aSfo->load() >= 0.5f);
        dsp->stimme().setMode((int)std::round(aSmd->load()));
        // Vocal FX
        dsp->stimme().setDrive(aSdr->load());
        dsp->stimme().setDistortion(aSdist->load());
        dsp->stimme().setTone(aStn->load());
        dsp->stimme().setAir(aSair->load());
        dsp->stimme().setShimmer(aSsh->load());
        dsp->stimme().setReverb(aSrv->load());
        dsp->stimme().setFilters(aShp->load(), aSlp->load(), aSflt->load() >= 0.5f);
        // STRETCH / WARP: pitch stays independent of length in warp mode.
        dsp->stimme().setWarp((int)std::lround(aSwp->load()), std::log2(std::max(0.25f, std::min(4.0f, aSst->load()))),
                              aSfm->load() >= 0.5f);
        dsp->stimme().setTempo(aHB->load(), aBar->load());
        dsp->setHarmonizer(aHon->load() >= 0.5f, (int)std::lround(aHmo->load()), aHsu->load() >= 0.5f,
                           (int)std::lround(aHky->load()), (int)std::lround(aHsc->load()));

        // On-screen KEYS events (queued from the main thread).
        for (int r = pendR->load(std::memory_order_relaxed); r != pendW->load(std::memory_order_acquire); ++r) {
            const PendNote &pn = pend[r & (kPendMax - 1)];
            if (pn.vel > 0) dsp->noteOn(pn.note, pn.vel); else dsp->noteOff(pn.note);
            pendR->store(r + 1, std::memory_order_release);
        }
        // Host MIDI is applied at its sample position inside the buffer (see
        // midiUpTo() in the frame loops below). Every note used to fire at the
        // START of the host buffer — 9 ms early at a 512 buffer, 14.5 ms at
        // 1024, a different amount for every note.
        const AURenderEvent *e = evt;
        const int64_t blockStart = (int64_t)ts->mSampleTime;
        auto midiUpTo = [&e, blockStart, n, seqEngine](AVAudioFrameCount i) {
            while (e) {
                if (e->head.eventType != AURenderEventMIDI) { e = e->head.next; continue; }
                // signed: "immediate" events are stamped before the block start
                const int64_t off = (int64_t)e->head.eventSampleTime - blockStart;
                const AVAudioFrameCount at = off <= 0 ? 0 : (off >= (int64_t)n ? n - 1 : (AVAudioFrameCount)off);
                if (at > i) break;
                const uint8_t status = e->MIDI.data[0];
                const uint8_t d1 = e->MIDI.data[1], d2 = e->MIDI.data[2];
                const uint8_t cmd = status & 0xF0;
                if (cmd == 0x90 && d2 > 0) seqEngine->noteOn((int)d1, (int)d2);
                else if (cmd == 0x80 || (cmd == 0x90 && d2 == 0)) seqEngine->noteOff((int)d1);
                else if (cmd == 0xB0 && (d1 == 120 || d1 == 123)) seqEngine->allNotesOff();   // All Sound / All Notes Off
                e = e->head.next;
            }
        };

        // ── KEYS sequencer: sample-accurate, on Logic's beat grid ──
        // Per-frame musical time = host beat at block start + elapsed samples,
        // so steps land on the exact sample, not on a 60 Hz UI poll.
        const bool seqOn = seqArmed->load() != 0;
        const bool hostPlaying = aHPl->load();
        const double bpm = std::max(20.0, (double)aHB->load());
        const double beatPerSample = bpm / 60.0 / std::max(1.0, *renderSR);
        const double beat0 = hostPlaying ? aHBt->load() : *seqFreeBeat;
        const int    seqN = seqCount->load();
        const double stepLen = seqStepBeats->load();
        const double gate = seqGate->load();
        if (!seqOn && *seqNoteOn >= 0) {          // disarmed: release the held note
            seqEngine->noteOff(*seqNoteOn); *seqNoteOn = -1; seqNoteOut->store(-1); seqStep->store(-1);
        }
        auto seqFrame = [&](AVAudioFrameCount i) {
            if (!seqOn) return;
            const double beat = beat0 + (double)i * beatPerSample;
            const long long absStep = (long long)std::floor(beat / stepLen);
            if (absStep != *seqLastAbs) {
                *seqLastAbs = absStep;
                const int s = seqN > 0 ? (int)(((absStep % seqN) + seqN) % seqN) : 0;
                if (*seqNoteOn >= 0) { seqEngine->noteOff(*seqNoteOn); *seqNoteOn = -1; }
                const int note = (seqN > 0 && s < kSeqMax) ? seqNotes[s] : -1;
                if (note >= 0) { seqEngine->noteOn(note, 108); *seqNoteOn = note; }
                seqStep->store(s); seqNoteOut->store(note);
                *seqNoteOnBeat = (double)absStep * stepLen;
            }
            if (*seqNoteOn >= 0 && gate < 1.0 && (beat - *seqNoteOnBeat) >= stepLen * gate) {
                seqEngine->noteOff(*seqNoteOn); *seqNoteOn = -1; seqNoteOut->store(-1);
            }
        };

        if (out->mNumberBuffers < 2) {
            float *m = (float *)out->mBuffers[0].mData;
            for (AVAudioFrameCount i = 0; i < n; ++i) {
                midiUpTo(i);
                seqFrame(i);
                float l, r; dsp->processFrame(l, r);
                m[i] = 0.5f * (l + r);
            }
        } else {
            float *L = (float *)out->mBuffers[0].mData;
            float *R = (float *)out->mBuffers[1].mData;
            for (AVAudioFrameCount i = 0; i < n; ++i) {
                midiUpTo(i);
                seqFrame(i);
                float l, r; dsp->processFrame(l, r);
                L[i] = l; R[i] = r;
            }
        }
        // Free clock always tracks the position we just played, so a Stop
        // continues from the host position instead of jumping back.
        if (seqOn) *seqFreeBeat = beat0 + (double)n * beatPerSample;
        return noErr;
    };
}
@end
