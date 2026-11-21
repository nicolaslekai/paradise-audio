#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface HandyAudioUnit : AUAudioUnit

/// Pad count (4 storage slots; zones 0..1 are surfaced in the UI).
@property (nonatomic, readonly) NSInteger padCount;
/// Number of sample zones surfaced in the UI (2 stacked boxes).
@property (nonatomic, readonly) NSInteger zoneCount;

/// Load mono Float32 sample data into a zone/pad. Caller owns the memory; we copy.
- (void)setSamplePad:(NSInteger)index data:(const float *)data length:(NSInteger)length name:(NSString *)name;

/// Clear a pad.
- (void)clearPad:(NSInteger)index;

/// Display name of the sample loaded on a pad (or "— EMPTY —").
- (NSString *)nameForPad:(NSInteger)index;

/// Length (frames) of the sample on a pad, and a copy of its mono data — the
/// editor rebuilds its waveform peaks from this after a project reload.
- (NSInteger)sampleLengthForPad:(NSInteger)index;
- (NSInteger)copySampleForPad:(NSInteger)index into:(float *)dst maxFrames:(NSInteger)maxFrames;

/// Trigger a pad programmatically (UI click). MIDI also triggers via render.
- (void)triggerPad:(NSInteger)index velocity:(uint8_t)vel;

/// Per-pad fine pitch trim (-12..+12 semitones).
- (float)pitchSemiForPad:(NSInteger)index;
- (void)setPitchSemiForPad:(NSInteger)index semi:(float)st;

/// Per-pad chop algorithm knob 0..1
///   0.00–0.25 = FWD, 0.25–0.50 = REV, 0.50–0.75 = STUT, 0.75–1.00 = HALF
- (float)chopForPad:(NSInteger)index;
- (void)setChopForPad:(NSInteger)index knob:(float)k;

/// MIDI root note of a pad (0..127). Each pad covers a 2-octave (24-note) zone
/// centred on its root. Defaults: pad i → 24 + i*24 (C1, C3, C5, C7).
- (int)rootNoteForPad:(NSInteger)index;
- (void)setRootNoteForPad:(NSInteger)index midi:(int)note;

/// KEY TRIGGER mode (per pad).
///   ON  → sample plays only while key is held; noteOff fades it out.
///   OFF → sample plays through to its end regardless of key release (one-shot).
- (BOOL)keyTriggerForPad:(NSInteger)index;
- (void)setKeyTriggerForPad:(NSInteger)index on:(BOOL)on;

/// RANGE selector (per zone) — normalized [0,1] start/end choosing which portion
/// of the loaded sample actually plays. end is held >= start.
- (float)rangeStartForPad:(NSInteger)index;
- (float)rangeEndForPad:(NSInteger)index;
- (void)setRangeForPad:(NSInteger)index start:(float)start end:(float)end;

/// Global PITCH transpose (-24..+24 semitones). Backed by an automatable
/// parameter (identifier "pt"); these helpers mirror the param for the UI knob.
- (float)pitchTranspose;
- (void)setPitchTranspose:(float)semi;

// ── Live output scope probe ──
/// Number of peak buckets the scope ring holds.
@property (nonatomic, readonly) NSInteger probeSize;
/// Fill `out` with the most-recent `count` output peak buckets (oldest→newest).
- (NSInteger)readProbe:(float *)out count:(NSInteger)count;

// ── Bounce / capture-to-WAV ──
/// Arm/disarm output capture. Arming allocates a bounded stereo buffer and
/// starts recording the plugin's output; disarming stops it. Capture also
/// auto-stops when the buffer fills.
@property (nonatomic) BOOL bounceArmed;
/// Sample rate the capture was recorded at (for writing the WAV).
@property (nonatomic, readonly) double bounceSampleRate;
/// Number of stereo frames captured so far.
- (NSInteger)bounceFrameCount;
/// Copy up to `maxFrames` captured frames (interleaved stereo) into `dst`.
/// Returns the number of frames copied. Call after disarming.
- (NSInteger)copyBounceInterleaved:(float *)dst maxFrames:(NSInteger)maxFrames;
/// Free the capture buffer after the file has been written.
- (void)freeBounce;

@end

NS_ASSUME_NONNULL_END
