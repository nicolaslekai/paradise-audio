#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DrumsAudioUnit : AUAudioUnit

/// 0..127, for UI playhead drawing.
@property (nonatomic, readonly) int currentStep;

/// Transport
@property (nonatomic) BOOL playing;

/// Live-record arm. When YES and the transport is playing, incoming Maschine
/// MIDI notes are written into the active pattern (quantized) with their velocity.
@property (nonatomic) BOOL recordArmed;
@property (nonatomic) float bpm;
@property (nonatomic) float swing;

/// Pattern editing
- (BOOL)stepForVoice:(int)v step:(int)s;
- (void)setStepForVoice:(int)v step:(int)s on:(BOOL)on;

/// Per-cell SWING level (0..4). 0 = straight; 1..4 ≈ MPC 54/58/62/66%, each
/// pushing just that hit progressively later. UI tints the cell pinker per level.
- (int)swingLevelForVoice:(int)v step:(int)s;
- (void)setSwingLevelForVoice:(int)v step:(int)s level:(int)level;

/// Per-voice controls
- (float)levelForVoice:(int)v;
- (void)setLevelForVoice:(int)v level:(float)lvl;

- (float)delayMsForVoice:(int)v;
- (void)setDelayMsForVoice:(int)v ms:(float)ms;

- (BOOL)isMutedForVoice:(int)v;
- (void)setMutedForVoice:(int)v muted:(BOOL)muted;

- (BOOL)isSoloedForVoice:(int)v;
- (void)setSoloedForVoice:(int)v soloed:(BOOL)soloed;

/// Manually trigger a voice (e.g. from the UI when user clicks a row name)
- (void)triggerVoice:(int)v;

/// Per-voice resonant low-pass filter. norm: 0=very dark, 1=open/bypass.
- (float)filterNormForVoice:(int)v;
- (void)setFilterNormForVoice:(int)v norm:(float)n;

/// Per-voice DECAY (0..1). 1.0 = full natural tail; lower shortens just this
/// instrument's sound (gates it). Independent of the global DECAY master.
- (float)decayForVoice:(int)v;
- (void)setDecayForVoice:(int)v decay:(float)d;

/// Clear all steps for a single voice.
- (void)clearStepsForVoice:(int)v;

/// Clear every voice's steps (entire grid).
- (void)clearAllSteps;

/// Whether the engine is following the host's BPM (via musicalContextBlock).
/// When YES, setting bpm directly is a fallback only.
@property (nonatomic) BOOL followHostBPM;

/// Pattern slot 0..3 (PATTERN A B C D).
@property (nonatomic) int patternSlot;

/// Number of active bars (1..8). Sequencer wraps at bars × 32 internal steps.
@property (nonatomic) int bars;

/// Pattern chaining (song mode). The chain is an ordered list of slot indices
/// (0..3 = A..D), e.g. @[@0,@1,@0,@2] plays A→B→A→C, advancing one entry each
/// time the loop wraps. An empty chain turns song mode off (the selected slot
/// just loops). `chainPosition` is the index within the chain currently playing
/// — the UI uses it to highlight the live entry.
- (void)setChainSlots:(NSArray<NSNumber *> *)slots;
- (NSArray<NSNumber *> *)chainSlots;
- (void)clearChain;
@property (nonatomic, readonly) int chainPosition;

/// ISOLATE — loop the active slot on its own; the LINK chain stays stored and
/// resumes when ISOLATE is switched off. Persisted in the state blob.
@property (nonatomic) BOOL isolate;
/// MIDI MODE — the internal sequencer stays silent; incoming MIDI notes only
/// play the voices (no recording). Use after EXPORT MIDI so the host's MIDI
/// region plays the machine without doubling. Persisted in the state blob.
@property (nonatomic) BOOL midiMode;

/// Drag handle: copy voice `src`'s pattern (active slot: steps, per-step
/// velocity + swing, resolution, velocity preset) onto `dst`, or swap the two.
- (void)copyPatternFromVoice:(int)src toVoice:(int)dst;
- (void)swapPatternOfVoice:(int)a withVoice:(int)b;
/// Per-step recorded velocity (undo snapshots).
- (float)stepVelocityForVoice:(int)v step:(int)s;
- (BOOL)stepVelocityIsSetForVoice:(int)v step:(int)s;
- (void)setStepVelocityForVoice:(int)v step:(int)s velocity:(float)vel isSet:(BOOL)isSet;

/// Exports. Range = the LINK chain once through, or the active pattern alone
/// when ISOLATE is on / no chain is set. Rendered offline on the calling
/// thread with a separate engine instance — call from a background queue.
@property (nonatomic, readonly) double exportDurationSeconds;
/// Standard MIDI file, channel 10, note = 36 + voice (same map as MIDI input).
- (BOOL)exportMIDIToPath:(NSString *)path;
/// One stereo 24-bit WAV of the mix (+2 s tail).
- (BOOL)exportAudioMixToPath:(NSString *)path;
/// One stereo 24-bit WAV per audible voice with hits, "<VOICE>.wav" in `folder`.
/// Returns the written paths (empty on failure).
- (NSArray<NSString *> *)exportAudioStemsToFolder:(NSString *)folder;

/// Per-voice resolution in subdivisions per bar. Must be 8, 16, or 32.
- (int)resolutionForVoice:(int)v;
- (void)setResolutionForVoice:(int)v resolution:(int)res;

/// Per-voice pitch in semitones (-24..+24). 0 = native voice tuning.
- (float)pitchSemiForVoice:(int)v;
- (void)setPitchSemiForVoice:(int)v semi:(float)semi;

/// Per-voice reverb send 0..1 into the shared reverb tank.
- (float)reverbSendForVoice:(int)v;
- (void)setReverbSendForVoice:(int)v send:(float)s;

/// Per-voice CHARACTER variant (0..characterCountForVoice-1). Each voice
/// now exposes 5 reference-modelled variants (e.g. Kick: 808/909/LINN/DMX/
/// ACOUS, Snare: STD/TIGHT/CLAP/LINN/AMEN). Use the count/name accessors to
/// drive the UI selector rather than hard-coding labels.
- (int)characterForVoice:(int)v;
- (void)setCharacterForVoice:(int)v character:(int)c;
- (int)characterCountForVoice:(int)v;
- (NSString *)characterNameForVoice:(int)v character:(int)c;

/// Global pitch in semitones (-12..+12). Shifts every voice up or down.
@property (nonatomic) float globalPitchSemi;

/// Global noise floor (0..1). Analog grit / tape hiss mixed into the master.
@property (nonatomic) float globalNoise;

/// Per-voice VELOCITY preset (0..5). 0=FLAT, 1=ALT 50, 2=ALT 25, 3=GHOST,
/// 4=BUILD, 5=HUMAN. Counts only ticked hits for that voice — so the
/// preset walks the rhythm rather than the raw step grid.
- (int)velocityPresetForVoice:(int)v;
- (void)setVelocityPresetForVoice:(int)v preset:(int)p;
@property (nonatomic, readonly) NSInteger velocityPresetCount;
- (NSString *)velocityPresetName:(int)preset;
/// Preview the velocity that hit `hitIdx` of voice `v` will fire at, given
/// the voice's current preset. Used by the UI to draw velocity bars in the
/// step cells. Returns 1.0 when preset == FLAT.
- (float)previewVelocityForVoice:(int)v hitIndex:(int)hitIdx;

/// Global DECAY (0..1). 1.0 = full natural voice tails. Lower values gate
/// each hit shorter; 0 sounds like aggressive 909-style choke.
@property (nonatomic) float globalDecay;

/// Raw engine state blob (all patterns/voices/globals/chain). Used by the UI's
/// named SAVE / LOAD presets; the same bytes ride inside the AU's fullState so
/// the host restores everything on project reload.
- (NSData *)stateData;
- (void)loadStateData:(NSData *)data;

@end

NS_ASSUME_NONNULL_END
