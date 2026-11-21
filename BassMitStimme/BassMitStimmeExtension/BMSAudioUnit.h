#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

@interface BMSAudioUnit : AUAudioUnit

/// Replace the underlay vocal sample. data must be mono Float32 at the supplied
/// sampleRate. Pass NULL data to revert to no sample.
- (void)setStimmeSampleData:(const float *)data
                     length:(NSInteger)length
                 sampleRate:(double)srcSR
                       name:(NSString *)name;

/// Name of the currently loaded vocal sample (or @"— EMPTY —").
@property (nonatomic, readonly, copy) NSString *stimmeSampleName;

/// Current playhead 0..1 inside the loaded sample (UI use).
@property (nonatomic, readonly) float stimmePlayhead;

/// Cached Float32 sample buffer + length (for the UI waveform preview).
/// Returns NULL when no sample is loaded.
- (const float * _Nullable)stimmeSampleData;
@property (nonatomic, readonly) NSInteger stimmeSampleLength;
/// Source sample rate of the loaded vocal (for the duration readout).
@property (nonatomic, readonly) double stimmeSampleRate;
/// First loud sample (playback starts here; leading silence is skipped).
@property (nonatomic, readonly) NSInteger stimmeSampleOnset;

/// STRETCH / WARP readback (computed from the parameters): the length factor the
/// warp engine is applying (1 = original; in SYNC modes computed from the host
/// tempo) and whether the voice currently runs through the warp engine.
@property (nonatomic, readonly) float stimmeStretchFactor;
@property (nonatomic, readonly) BOOL  stimmeWarpEngaged;

/// Vintage analog CHARACTER preset applied to every voice.
/// 0 = CLEAN (modern, no drift)
/// 1 = MOOG  (Minimoog — fat ladder, mild drift)
/// 2 = 303   (TB-303 — aggressive Q, exponential env, accent)
/// 3 = SH101 (Roland SH-101 — drifty, snappy)
/// 4 = JUNO  (Juno-60 — chorusy slow drift)
@property (nonatomic) int analogCharacter;

/// Play / release a note from the on-screen KEYS keyboard. Drives the exact
/// same voice + Stimme pitch path as incoming host MIDI, so the vocal underlay
/// follows the played key (see Engine::noteOn / the render-block MIDI branch).
- (void)playNote:(int)midiNote velocity:(float)vel;
- (void)stopNote:(int)midiNote;

/// Host transport snapshot (updated each render block) so the KEYS sequencer
/// can lock its generated melody to Logic's tempo and bar grid.
@property (nonatomic, readonly) double hostBPM;
@property (nonatomic, readonly) double hostBeatPosition;
@property (nonatomic, readonly) BOOL   hostIsPlaying;

/// Engine-side KEYS sequencer — runs on the render thread, sample-accurate,
/// locked to Logic's beat position (free-runs at hostBPM while the transport
/// is stopped). The UI only feeds it a melody (MIDI notes, -1 = rest) and
/// reads the sounding step / note back for the key highlight.
- (void)setSequencerMelody:(NSArray<NSNumber *> *)notes stepBeats:(double)stepBeats gate:(double)gate;
@property (nonatomic) BOOL sequencerArmed;
@property (nonatomic, readonly) int sequencerStep;   // -1 while idle
@property (nonatomic, readonly) int sequencerNote;   // sounding note, or -1

/// Read a snapshot of the realtime visualizer probe. Caller passes two
/// float arrays of length `count`; engine writes the most recent `count`
/// samples of (bass mix) and (vocal mix) into them. Returns the number of
/// samples available (== Engine::probeSize() when not asked for more).
- (NSInteger)readProbeBass:(float * _Nonnull)bassOut
                       vox:(float * _Nonnull)voxOut
                     count:(NSInteger)count;

/// Size of the probe ring (so callers can pre-size their buffers).
@property (nonatomic, readonly) NSInteger probeSize;

@end
