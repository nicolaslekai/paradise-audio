#import "StringThingAudioUnit.h"
#include <vector>
#include <cstring>
#import "DSP/StringThingEngine.hpp"
#include <memory>
#include <fenv.h>
#if defined(__x86_64__) || defined(__i386__)
#include <xmmintrin.h>
#endif

@interface StringThingAudioUnit ()
@property (nonatomic) AUAudioUnitBusArray *outputBusArray;
@end

@implementation StringThingAudioUnit {
    std::vector<float> _ownOutBuf;   // scratch output (2 ch) for hosts that pass NULL mData
    std::unique_ptr<stringk::StringThingEngine> _dsp;
    AUAudioUnitBus *_outBus;
    AVAudioFormat *_format;
    // Atomic-ish flag flipped by the render block when host tempo was read.
    BOOL _bpmSynced;
    // Backing storage for all writable @property declarations. Without these,
    // the UI never sees the current state and buttons don't highlight.
    int   _mode;
    int   _direction;
    int   _rate;
    int   _octaveRange;
    float _gate;
    float _swing;
    int   _scaleId;
    int   _rootKey;
    BOOL  _droneOn;
    float _mixSaw, _mixSquare, _mixSub;
    float _tone;
    int   _voiceMode;
    float _cutoffHz, _resonance, _filterEnvAmount;
    float _ampA, _ampD, _ampS, _ampR;
    float _fltA, _fltD, _fltS, _fltR;
    // Master output level + extended drone state
    float _level;
    float _droneLevel;
    int   _droneOctave;
    int   _droneInterval;
}
@synthesize parameterTree = _parameterTree;
@synthesize playing = _playing;
@synthesize bpm = _bpm;

- (instancetype)initWithComponentDescription:(AudioComponentDescription)d
                                     options:(AudioComponentInstantiationOptions)o
                                       error:(NSError **)e {
    self = [super initWithComponentDescription:d options:o error:e]; if (!self) return nil;
    _dsp = std::make_unique<stringk::StringThingEngine>();
    _dsp->prepare(48000);

    _format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    _outBus = [[AUAudioUnitBus alloc] initWithFormat:_format error:nil];
    _outputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self
                                                              busType:AUAudioUnitBusTypeOutput
                                                              busses:@[_outBus]];

    _playing = YES;
    _bpm = 120.0f;
    // Sensible defaults — also push to engine so the synth is playable
    // immediately when instantiated.
    _mode = 0;          // ARP
    _direction = 0;     // Up
    _rate = 3;          // 1/16
    _octaveRange = 1;
    _gate = 0.5f;
    _swing = 0.0f;
    _scaleId = 0;       // Chromatic
    _rootKey = 0;       // C
    _droneOn = NO;
    _mixSaw = 0.6f; _mixSquare = 0.4f; _mixSub = 0.4f; _tone = 0.5f;
    _voiceMode = 3;   // kVoiceEnsemble — violin/string section by default
    _cutoffHz = 2200.0f; _resonance = 0.6f; _filterEnvAmount = 0.6f;
    _ampA = 0.005f; _ampD = 0.12f; _ampS = 0.6f; _ampR = 0.18f;
    _fltA = 0.002f; _fltD = 0.10f; _fltS = 0.4f; _fltR = 0.15f;
    _level = 1.0f;
    _droneLevel = 0.7f; _droneOctave = -1; _droneInterval = 1;

    _dsp->setBPM(_bpm);
    _dsp->setMode(_mode);
    _dsp->setDirection(_direction);
    _dsp->setRate(_rate);
    _dsp->setOctaveRange(_octaveRange);
    _dsp->setGate(_gate);
    _dsp->setSwing(_swing);
    _dsp->setScale(_scaleId);
    _dsp->setRootKey(_rootKey);
    _dsp->setDroneOn(false);
    _dsp->setMix(_mixSaw, _mixSquare, _mixSub);
    _dsp->setFilter(_cutoffHz, _resonance, _filterEnvAmount);
    _dsp->setEnvAmp(_ampA, _ampD, _ampS, _ampR);
    _dsp->setEnvFlt(_fltA, _fltD, _fltS, _fltR);
    _dsp->setLevel(_level);
    _dsp->setDroneLevel(_droneLevel);
    _dsp->setDroneOctave(_droneOctave);
    _dsp->setDroneInterval(_droneInterval);

    _parameterTree = [AUParameterTree createTreeWithChildren:@[]];
    return self;
}

- (AUAudioUnitBusArray *)outputBusses { return _outputBusArray; }

- (int)currentStep { return _dsp ? _dsp->currentStep() : 0; }
- (int)chordCount  { return _dsp ? _dsp->chordCount() : 0; }
- (BOOL)bpmSynced  { return _bpmSynced; }

- (void)setBpm:(float)bpm { _bpm = bpm; if (_dsp) _dsp->setBPM(bpm); }
- (void)setPlaying:(BOOL)p { _playing = p; }

- (int)mode { return _mode; }
- (void)setMode:(int)m         { _mode = m; if (_dsp) _dsp->setMode(m); }
- (int)direction { return _direction; }
- (void)setDirection:(int)d    { _direction = d; if (_dsp) _dsp->setDirection(d); }
- (int)rate { return _rate; }
- (void)setRate:(int)r         { _rate = r; if (_dsp) _dsp->setRate(r); }
- (int)octaveRange { return _octaveRange; }
- (void)setOctaveRange:(int)o  { _octaveRange = o; if (_dsp) _dsp->setOctaveRange(o); }
- (float)gate { return _gate; }
- (void)setGate:(float)g       { _gate = g; if (_dsp) _dsp->setGate(g); }
- (float)swing { return _swing; }
- (void)setSwing:(float)s      { _swing = s; if (_dsp) _dsp->setSwing(s); }
- (int)scaleId { return _scaleId; }
- (void)setScaleId:(int)i      { _scaleId = i; if (_dsp) _dsp->setScale(i); }
- (int)rootKey { return _rootKey; }
- (void)setRootKey:(int)k      { _rootKey = k; if (_dsp) _dsp->setRootKey(k); }
- (int)dubstepStep:(int)step   { return _dsp ? _dsp->dubstepStep(step) : 0; }
- (void)setDubstepStep:(int)step division:(int)division {
    if (_dsp) _dsp->setDubstepStep(step, division);
}
- (NSInteger)dubstepPatternLen    { return (NSInteger)stringk::StringThingEngine::kDubPatternLen; }
- (NSInteger)dubstepDivisionCount { return (NSInteger)stringk::StringThingEngine::kDubDivisionCount; }
- (NSString *)dubstepDivisionName:(int)division {
    return [NSString stringWithUTF8String:stringk::StringThingEngine::dubstepDivisionName(division)];
}
- (BOOL)droneOn { return _droneOn; }
- (void)setDroneOn:(BOOL)on    { _droneOn = on; if (_dsp) _dsp->setDroneOn(on ? true : false); }

// ── Extended drone + master level (previously broken LVL knob)
- (float)droneLevel { return _droneLevel; }
- (void)setDroneLevel:(float)v { _droneLevel = v; if (_dsp) _dsp->setDroneLevel(v); }
- (int)droneOctave { return _droneOctave; }
- (void)setDroneOctave:(int)v { _droneOctave = v; if (_dsp) _dsp->setDroneOctave(v); }
- (int)droneInterval { return _droneInterval; }
- (void)setDroneInterval:(int)v { _droneInterval = v; if (_dsp) _dsp->setDroneInterval(v); }
- (float)level { return _level; }
- (void)setLevel:(float)v { _level = v; if (_dsp) _dsp->setLevel(v); }
- (float)mod { return _dsp ? _dsp->mod() : 0; }
- (void)setMod:(float)v { if (_dsp) _dsp->setMod(v); }
- (float)dirt { return _dsp ? _dsp->dirt() : 0; }
- (void)setDirt:(float)v { if (_dsp) _dsp->setDirt(v); }
- (float)noise { return _dsp ? _dsp->noise() : 0; }
- (void)setNoise:(float)v { if (_dsp) _dsp->setNoise(v); }
- (float)delayFx { return _dsp ? _dsp->delayFx() : 0; }
- (void)setDelayFx:(float)v { if (_dsp) _dsp->setDelay(v); }
- (float)reverbFx { return _dsp ? _dsp->reverbFx() : 0; }
- (void)setReverbFx:(float)v { if (_dsp) _dsp->setReverb(v); }
- (float)chop { return _dsp ? _dsp->chop() : 0; }
- (void)setChop:(float)v { if (_dsp) _dsp->setChop(v); }
- (int)delayType { return _dsp ? _dsp->delayType() : 0; }
- (void)setDelayType:(int)t { if (_dsp) _dsp->setDelayType(t); }
- (int)reverbType { return _dsp ? _dsp->reverbType() : 1; }
- (void)setReverbType:(int)t { if (_dsp) _dsp->setReverbType(t); }
- (int)chopType { return _dsp ? _dsp->chopType() : 0; }
- (void)setChopType:(int)t { if (_dsp) _dsp->setChopType(t); }

// ── Comet-field visualizer accessors
- (int)readNoteHistory:(int *)midiOut age:(double *)ageSecondsOut capacity:(int)cap {
    if (!_dsp || !midiOut || !ageSecondsOut || cap <= 0) return 0;
    int count = 0;
    _dsp->readNoteHistory(midiOut, ageSecondsOut, &count, cap);
    return count;
}
- (int)chordNoteAt:(int)index { return _dsp ? _dsp->chordNote(index) : -1; }
- (float)amplitudeEnv { return _dsp ? _dsp->amplitudeEnv() : 0.0f; }

// Voice mix
- (float)mixSaw { return _mixSaw; }
- (void)setMixSaw:(float)v { _mixSaw = v; [self pushMix]; }
- (float)mixSquare { return _mixSquare; }
- (void)setMixSquare:(float)v { _mixSquare = v; [self pushMix]; }
- (float)mixSub { return _mixSub; }
- (void)setMixSub:(float)v { _mixSub = v; [self pushMix]; }

- (float)tone { return _tone; }
- (void)setTone:(float)t {
    // 0 = saw + sub heavy (dark), 1 = square heavy (bright). Lerp the three
    // mix levels along a hand-picked curve.
    if (t < 0) t = 0; else if (t > 1) t = 1;
    _tone = t;
    _mixSaw    = 0.8f - 0.8f * t;        // 0.8 -> 0.0
    _mixSquare = t;                      // 0.0 -> 1.0
    _mixSub    = 0.7f - 0.6f * t;        // 0.7 -> 0.1
    [self pushMix];
}

// Filter
- (float)cutoffHz { return _cutoffHz; }
- (void)setCutoffHz:(float)v { _cutoffHz = v; [self pushFilter]; }
- (float)resonance { return _resonance; }
- (void)setResonance:(float)v { _resonance = v; [self pushFilter]; }
- (float)filterEnvAmount { return _filterEnvAmount; }
- (void)setFilterEnvAmount:(float)v { _filterEnvAmount = v; [self pushFilter]; }

// Envelopes
- (float)ampA { return _ampA; }
- (void)setAmpA:(float)v { _ampA = v; [self pushAmpEnv]; }
- (float)ampD { return _ampD; }
- (void)setAmpD:(float)v { _ampD = v; [self pushAmpEnv]; }
- (float)ampS { return _ampS; }
- (void)setAmpS:(float)v { _ampS = v; [self pushAmpEnv]; }
- (float)ampR { return _ampR; }
- (void)setAmpR:(float)v { _ampR = v; [self pushAmpEnv]; }
- (float)fltA { return _fltA; }
- (void)setFltA:(float)v { _fltA = v; [self pushFltEnv]; }
- (float)fltD { return _fltD; }
- (void)setFltD:(float)v { _fltD = v; [self pushFltEnv]; }
- (float)fltS { return _fltS; }
- (void)setFltS:(float)v { _fltS = v; [self pushFltEnv]; }
- (float)fltR { return _fltR; }
- (void)setFltR:(float)v { _fltR = v; [self pushFltEnv]; }

// Step grid
- (int)voiceMode { return _voiceMode; }
- (void)setVoiceMode:(int)m { _voiceMode = m; if (_dsp) _dsp->setVoiceMode(m); }
- (void)loadPhrase:(int)phraseId { if (_dsp) _dsp->loadPhrase(phraseId); }

- (BOOL)stepOn:(int)i { return _dsp ? _dsp->stepOn(i) : NO; }
- (int)stepSemi:(int)i { return _dsp ? _dsp->stepSemi(i) : 0; }
- (int)stepOct:(int)i { return _dsp ? _dsp->stepOct(i) : 0; }
- (void)setStep:(int)i on:(BOOL)on semi:(int)semi oct:(int)oct {
    if (_dsp) _dsp->setStep(i, on, semi, oct);
}

#pragma mark - Melodic step-grid (keys)
- (int)numGridRows { return _dsp ? _dsp->numGridRows() : 8; }
- (int)gridSteps { return _dsp ? _dsp->gridSteps() : 16; }
- (void)setGridSteps:(int)n { if (_dsp) _dsp->setGridSteps(n); }
- (BOOL)cellAtRow:(int)row step:(int)step { return _dsp ? _dsp->cell(row, step) : NO; }
- (BOOL)cellInSlot:(int)slot row:(int)row step:(int)step { return _dsp ? _dsp->cellIn(slot, row, step) : NO; }
- (void)setCellInSlot:(int)slot row:(int)row step:(int)step on:(BOOL)on { if (_dsp) _dsp->setCellIn(slot, row, step, on ? true : false); }
- (int)lengthAtRow:(int)row step:(int)step { return _dsp ? _dsp->cellLength(row, step) : 1; }
- (void)setLength:(int)len atRow:(int)row step:(int)step { if (_dsp) _dsp->setCellLength(row, step, len); }
- (int)lengthInSlot:(int)slot row:(int)row step:(int)step { return _dsp ? _dsp->cellLengthIn(slot, row, step) : 1; }
- (void)setLengthInSlot:(int)slot row:(int)row step:(int)step length:(int)len { if (_dsp) _dsp->setCellLengthIn(slot, row, step, len); }
- (int)colSwingInSlot:(int)slot step:(int)step { return _dsp ? _dsp->colSwingIn(slot, step) : 0; }
- (void)setColSwingInSlot:(int)slot step:(int)step level:(int)level { if (_dsp) _dsp->setColSwingIn(slot, step, level); }
- (int)recRootInSlot:(int)slot step:(int)step { return _dsp ? _dsp->recRootIn(slot, step) : -1; }
- (void)setRecRootInSlot:(int)slot step:(int)step midi:(int)midi { if (_dsp) _dsp->setRecRootIn(slot, step, midi); }
- (void)setCellAtRow:(int)row step:(int)step on:(BOOL)on { if (_dsp) _dsp->setCell(row, step, on); }
- (void)clearGrid { if (_dsp) _dsp->clearGrid(); }
- (int)currentSlot { return _dsp ? _dsp->currentSlot() : 0; }
- (void)setCurrentSlot:(int)slot { if (_dsp) _dsp->setSlot(slot); }
- (void)copyPatternToSlot:(int)dst { if (_dsp) _dsp->copyCurrentPatternToSlot(dst); }

- (void)setChainSlots:(NSArray<NSNumber *> *)slots {
    if (!_dsp) return;
    int buf[stringk::kMaxChain]; int n = 0;
    for (NSNumber *s in slots) { if (n >= stringk::kMaxChain) break; buf[n++] = s.intValue; }
    _dsp->setChain(buf, n);
}
- (NSArray<NSNumber *> *)chainSlots {
    NSMutableArray<NSNumber *> *a = [NSMutableArray array];
    if (_dsp) for (int i = 0; i < _dsp->chainLength(); ++i) [a addObject:@(_dsp->chainSlotAt(i))];
    return a;
}
- (void)clearChain    { if (_dsp) _dsp->clearChain(); }
- (int)chainPosition  { return _dsp ? _dsp->chainPosition() : 0; }
- (BOOL)isolate { return _dsp ? (_dsp->isolate() ? YES : NO) : NO; }
- (void)setIsolate:(BOOL)on { if (_dsp) _dsp->setIsolate(on ? true : false); }
- (void)copyGridRow:(int)src toRow:(int)dst { if (_dsp) _dsp->copyGridRow(src, dst); }
- (void)swapGridRow:(int)a withRow:(int)b { if (_dsp) _dsp->swapGridRows(a, b); }

// ── Full-state persistence (project reload + named SAVE/LOAD presets) ──
// Serialized through the AU's own accessors (no engine memory-layout coupling):
// every scalar param, all 4 pattern grids + per-column swing, and the chain.
static NSString * const kSynthStateKey = @"paradiseSynthState";

- (NSData *)stateData {
    if (!_dsp) return [NSData data];
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"bpm"]=@(self.bpm); d[@"mode"]=@(self.mode); d[@"direction"]=@(self.direction);
    d[@"rate"]=@(self.rate); d[@"octaveRange"]=@(self.octaveRange); d[@"gate"]=@(self.gate);
    d[@"swing"]=@(self.swing); d[@"scaleId"]=@(self.scaleId); d[@"rootKey"]=@(self.rootKey);
    d[@"droneOn"]=@(self.droneOn); d[@"droneLevel"]=@(self.droneLevel);
    d[@"droneOctave"]=@(self.droneOctave); d[@"droneInterval"]=@(self.droneInterval);
    d[@"level"]=@(self.level); d[@"mod"]=@(self.mod); d[@"dirt"]=@(self.dirt); d[@"noise"]=@(self.noise);
    d[@"delayFx"]=@(self.delayFx); d[@"reverbFx"]=@(self.reverbFx); d[@"chop"]=@(self.chop);
    d[@"delayType"]=@(self.delayType); d[@"reverbType"]=@(self.reverbType); d[@"chopType"]=@(self.chopType);
    d[@"mixSaw"]=@(self.mixSaw); d[@"mixSquare"]=@(self.mixSquare); d[@"mixSub"]=@(self.mixSub);
    d[@"tone"]=@(self.tone); d[@"cutoffHz"]=@(self.cutoffHz); d[@"resonance"]=@(self.resonance);
    d[@"filterEnvAmount"]=@(self.filterEnvAmount);
    d[@"ampA"]=@(self.ampA); d[@"ampD"]=@(self.ampD); d[@"ampS"]=@(self.ampS); d[@"ampR"]=@(self.ampR);
    d[@"fltA"]=@(self.fltA); d[@"fltD"]=@(self.fltD); d[@"fltS"]=@(self.fltS); d[@"fltR"]=@(self.fltR);
    d[@"voiceMode"]=@(self.voiceMode);
    d[@"gridSteps"]=@(self.gridSteps); d[@"gridOctave"]=@(self.gridOctave); d[@"halfTone"]=@(self.halfTone);
    d[@"slot"]=@(self.currentSlot);
    const int rows = self.numGridRows;
    // Slot-addressed reads: the live slot stays put while Logic autosaves.
    NSMutableArray *grids = [NSMutableArray array], *swings = [NSMutableArray array], *roots = [NSMutableArray array], *lens = [NSMutableArray array];
    for (int s = 0; s < 4; ++s) {
        NSMutableArray *g = [NSMutableArray array], *ln = [NSMutableArray array];
        for (int r = 0; r < rows; ++r)
            for (int c = 0; c < 64; ++c) {
                const BOOL on = [self cellInSlot:s row:r step:c];
                [g addObject:@(on ? 1 : 0)];
                [ln addObject:@(on ? [self lengthInSlot:s row:r step:c] : 1)];
            }
        [grids addObject:g]; [lens addObject:ln];
        NSMutableArray *sw = [NSMutableArray array], *rr = [NSMutableArray array];
        for (int c = 0; c < 64; ++c) { [sw addObject:@([self colSwingInSlot:s step:c])]; [rr addObject:@([self recRootInSlot:s step:c])]; }
        [swings addObject:sw]; [roots addObject:rr];
    }
    d[@"rows"]=@(rows); d[@"grids"]=grids; d[@"swings"]=swings; d[@"recRoots"]=roots; d[@"lens"]=lens;
    d[@"chain"]=[self chainSlots];
    d[@"isolate"]=@(self.isolate);   // 2026-11-21
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:d
                       format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    return data ?: [NSData data];
}

- (void)loadStateData:(NSData *)data {
    if (!_dsp || data.length == 0) return;
    NSDictionary *d = [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil];
    if (![d isKindOfClass:[NSDictionary class]]) return;
    #define SETF(k, sel) { id v = d[k]; if (v) self.sel = [v floatValue]; }
    #define SETI(k, sel) { id v = d[k]; if (v) self.sel = [v intValue]; }
    #define SETB(k, sel) { id v = d[k]; if (v) self.sel = [v boolValue]; }
    SETF(@"bpm",bpm) SETI(@"mode",mode) SETI(@"direction",direction) SETI(@"rate",rate)
    SETI(@"octaveRange",octaveRange) SETF(@"gate",gate) SETF(@"swing",swing)
    SETI(@"scaleId",scaleId) SETI(@"rootKey",rootKey) SETB(@"droneOn",droneOn)
    SETF(@"droneLevel",droneLevel) SETI(@"droneOctave",droneOctave) SETI(@"droneInterval",droneInterval)
    SETF(@"level",level) SETF(@"mod",mod) SETF(@"dirt",dirt) SETF(@"noise",noise)
    SETF(@"delayFx",delayFx) SETF(@"reverbFx",reverbFx) SETF(@"chop",chop)
    SETI(@"delayType",delayType) SETI(@"reverbType",reverbType) SETI(@"chopType",chopType)
    SETF(@"mixSaw",mixSaw) SETF(@"mixSquare",mixSquare) SETF(@"mixSub",mixSub)
    SETF(@"tone",tone) SETF(@"cutoffHz",cutoffHz) SETF(@"resonance",resonance)
    SETF(@"filterEnvAmount",filterEnvAmount)
    SETF(@"ampA",ampA) SETF(@"ampD",ampD) SETF(@"ampS",ampS) SETF(@"ampR",ampR)
    SETF(@"fltA",fltA) SETF(@"fltD",fltD) SETF(@"fltS",fltS) SETF(@"fltR",fltR)
    SETI(@"voiceMode",voiceMode) SETI(@"gridSteps",gridSteps)
    SETI(@"gridOctave",gridOctave) SETB(@"halfTone",halfTone)
    #undef SETF
    #undef SETI
    #undef SETB
    const int rows = self.numGridRows;
    NSArray *grids = d[@"grids"], *swings = d[@"swings"];
    if ([grids isKindOfClass:[NSArray class]] && [swings isKindOfClass:[NSArray class]]) {
        NSArray *roots = d[@"recRoots"];
        if (![roots isKindOfClass:[NSArray class]]) roots = nil;
        NSArray *lensAll = d[@"lens"];
        if (![lensAll isKindOfClass:[NSArray class]]) lensAll = nil;
        for (int s = 0; s < 4 && s < (int)grids.count; ++s) {
            NSArray *g = grids[s];
            for (int r = 0; r < rows; ++r)
                for (int c = 0; c < 64; ++c) {
                    NSInteger idx = r * 64 + c;
                    BOOL on = (idx < (NSInteger)[g count]) ? [g[idx] boolValue] : NO;
                    [self setCellInSlot:s row:r step:c on:on];
                    // Note lengths (2026-11-20). Older sessions have none → 1 step.
                    NSArray *ln = (lensAll && s < (int)lensAll.count && [lensAll[s] isKindOfClass:[NSArray class]]) ? lensAll[s] : nil;
                    const int len = (ln && idx < (NSInteger)ln.count) ? [ln[idx] intValue] : 1;
                    if (on) [self setLengthInSlot:s row:r step:c length:len];
                }
            NSArray *sw = (s < (int)swings.count) ? swings[s] : nil;
            for (int c = 0; c < 64 && c < (int)[sw count]; ++c) [self setColSwingInSlot:s step:c level:[sw[c] intValue]];
            NSArray *rr = (roots && s < (int)roots.count) ? roots[s] : nil;
            for (int c = 0; c < 64; ++c) [self setRecRootInSlot:s step:c midi:(c < (int)[rr count]) ? [rr[c] intValue] : -1];
        }
    }
    id slot = d[@"slot"]; if (slot) self.currentSlot = [slot intValue];
    // ISOLATE before the chain, so a stopped load does not jump to the chain head.
    { id iso = d[@"isolate"]; self.isolate = iso ? [iso boolValue] : NO; }
    id chain = d[@"chain"];
    if ([chain isKindOfClass:[NSArray class]]) [self setChainSlots:(NSArray<NSNumber *> *)chain];
}

- (NSDictionary<NSString *, id> *)fullState {
    NSMutableDictionary *d = [[super fullState] mutableCopy] ?: [NSMutableDictionary dictionary];
    d[kSynthStateKey] = [self stateData];
    return d;
}
- (void)setFullState:(NSDictionary<NSString *, id> *)fullState {
    [super setFullState:fullState];
    id blob = fullState[kSynthStateKey];
    if ([blob isKindOfClass:[NSData class]]) [self loadStateData:(NSData *)blob];
}
- (int)gridOctave { return _dsp ? _dsp->gridOctave() : 0; }
- (void)setGridOctave:(int)oct { if (_dsp) _dsp->setGridOctave(oct); }
- (BOOL)halfTone { return _dsp ? _dsp->halfTone() : NO; }
- (void)setHalfTone:(BOOL)on { if (_dsp) _dsp->setHalfTone(on); }
- (BOOL)recordArmed { return _dsp ? _dsp->recordArmed() : NO; }
- (void)setRecordArmed:(BOOL)on { if (_dsp) _dsp->setRecordArmed(on); }
- (int)colSwing:(int)step { return _dsp ? _dsp->colSwing(step) : 0; }
- (void)setColSwing:(int)step level:(int)level { if (_dsp) _dsp->setColSwing(step, level); }
- (int)gridRowMidi:(int)row { return _dsp ? _dsp->gridRowMidi(row) : 60; }

#pragma mark - Push helpers
- (void)pushMix    { if (_dsp) _dsp->setMix(_mixSaw, _mixSquare, _mixSub); }
- (void)pushFilter { if (_dsp) _dsp->setFilter(_cutoffHz, _resonance, _filterEnvAmount); }
- (void)pushAmpEnv { if (_dsp) _dsp->setEnvAmp(_ampA, _ampD, _ampS, _ampR); }
- (void)pushFltEnv { if (_dsp) _dsp->setEnvFlt(_fltA, _fltD, _fltS, _fltR); }

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)e {
    if (![super allocateRenderResourcesAndReturnError:e]) return NO;
    _ownOutBuf.assign((size_t)MAX((AUAudioFrameCount)512, self.maximumFramesToRender) * 2, 0.0f);
    _dsp->prepare((float)_outBus.format.sampleRate);
    // Re-push everything in case sample rate changed.
    _dsp->setBPM(_bpm);
    _dsp->setMix(_mixSaw, _mixSquare, _mixSub);
    _dsp->setFilter(_cutoffHz, _resonance, _filterEnvAmount);
    _dsp->setEnvAmp(_ampA, _ampD, _ampS, _ampR);
    _dsp->setEnvFlt(_fltA, _fltD, _fltS, _fltR);
    _dsp->setLevel(_level);
    _dsp->setDroneLevel(_droneLevel);
    _dsp->setDroneOctave(_droneOctave);
    _dsp->setDroneInterval(_droneInterval);
    return YES;
}

- (void)deallocateRenderResources { [super deallocateRenderResources]; if (_dsp) _dsp->reset(); }

- (AUInternalRenderBlock)internalRenderBlock {
    __block stringk::StringThingEngine *dsp = _dsp.get();
    // unsafe_unretained: refetch musicalContextBlock + transportStateBlock
    // every render. Logic doesn't always have them set at the moment the
    // render block is captured — they appear once the track is armed. Reading
    // `self.musicalContextBlock` here picks up the latest value cheaply.
    __unsafe_unretained StringThingAudioUnit *unsafeSelf = self;
    __block std::vector<float> *ownOutBuf = &_ownOutBuf;
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *fl,
                              const AudioTimeStamp *ts,
                              AVAudioFrameCount n, NSInteger bus,
                              AudioBufferList *out,
                              const AURenderEvent *evt,
                              AURenderPullInputBlock pull) {
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
        // Pull host tempo if available. Refetch each render so we catch the
        // case where Logic installs the block after render setup. Calling the
        // property accessor on __unsafe_unretained self avoids the ARC
        // retain/release that __weak would force on this hot path.
        // Drive sequencer from host transport FIRST, so a play/stop transition
        // is known before we feed the beat position — lets the sequencer
        // hard-snap to the host on the very block playback starts.
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
                dsp->setBPM((float)hostTempo);
                unsafeSelf->_bpm = (float)hostTempo;
                if (!unsafeSelf->_bpmSynced) unsafeSelf->_bpmSynced = YES;
                // Lock the sequencer step to Logic's bar grid.
                dsp->setHostBeatPosition(beatPos);
            }
        }
        // MIDI is applied at its sample position inside the buffer: render up to
        // each event, apply it, carry on. (Every note used to fire at the START
        // of the host buffer — 9 ms early at a 512 buffer, 14.5 ms at 1024, a
        // different amount for every note = timing jitter on played parts.)
        // The internal sequencer runs inside processFrame and is not affected.
        stringk::StringThingEngine *eng = dsp;                 // (__block variables cannot be captured by a C++ lambda)
        float *outL = (float *)out->mBuffers[0].mData;
        float *outR = (out->mNumberBuffers >= 2) ? (float *)out->mBuffers[1].mData : NULL;
        auto renderRange = [eng, outL, outR](AVAudioFrameCount from, AVAudioFrameCount to) {
            if (outR) {
                for (AVAudioFrameCount i = from; i < to; ++i) eng->processFrame(outL[i], outR[i]);
            } else {
                for (AVAudioFrameCount i = from; i < to; ++i) {
                    float L, R; eng->processFrame(L, R);
                    outL[i] = 0.5f * (L + R);
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
                const uint8_t d1     = e->MIDI.data[1];
                const uint8_t d2     = e->MIDI.data[2];
                if ((status & 0xF0) == 0x90 && d2 > 0)         dsp->noteOn(d1, d2);
                else if ((status & 0xF0) == 0x80 ||
                         ((status & 0xF0) == 0x90 && d2 == 0)) dsp->noteOff(d1);
            }
            e = e->head.next;
        }
        renderRange(cursor, n);
        return noErr;
    };
}
@end
