#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SynthThingAudioUnit : AUAudioUnit

/// Live state — for UI visualization.
@property (nonatomic, readonly) int currentStep;
@property (nonatomic, readonly) int chordCount;
@property (nonatomic) BOOL  playing;
@property (nonatomic) float bpm;
/// Whether the engine BPM is being driven by the host transport (Logic) via
/// musicalContextBlock. UI shows a SYNC indicator + the live tempo.
@property (nonatomic, readonly) BOOL  bpmSynced;

/// Mode / direction / rate (see SynthThingEngine.hpp enums).
@property (nonatomic) int mode;        // 0=ARP 1=SEQ 2=BERLIN
@property (nonatomic) int direction;   // 0=Up 1=Down 2=UpDown 3=Random 4=AsPlayed
@property (nonatomic) int rate;        // 1=1/4 2=1/8 3=1/16 4=1/32 5=1/8T 6=1/16T
@property (nonatomic) int octaveRange; // 1..4
@property (nonatomic) float gate;      // 0.05..1.0
@property (nonatomic) float swing;     // 0..0.5
@property (nonatomic) int scaleId;     // 0..7
@property (nonatomic) int rootKey;     // 0..11 (C..B)
@property (nonatomic) BOOL droneOn;
/// Drone extension — UI controls.
///   droneLevel    : 0..1.5 mix
///   droneOctave   : -3..+1 octave offset from current root
///   droneInterval : 0=root only, 1=+5th, 2=+5+oct, 3=octave double
@property (nonatomic) float droneLevel;
@property (nonatomic) int   droneOctave;
@property (nonatomic) int   droneInterval;

/// Master output level (0..2). The previously broken LVL knob now drives this.
@property (nonatomic) float level;

/// Universal output FX — apply to every voice character.
@property (nonatomic) float mod;     // 0..1 — chorus → flange
@property (nonatomic) float dirt;    // 0..1 — tanh drive
@property (nonatomic) float noise;   // 0..1 — analog hiss floor
@property (nonatomic) float delayFx; // 0..1 — tempo-synced 1/8 delay
@property (nonatomic) float reverbFx;// 0..1 — reverb send
@property (nonatomic) float chop;    // 0..1 — tempo-synced 1/16 chopper
@property (nonatomic) int delayType;  // 0..5 (1/8,1/4,dot,trip,slap,ping)
@property (nonatomic) int reverbType; // 0..3 (room,hall,plate,ambi)
@property (nonatomic) int chopType;   // 0..4 (1/16,1/8,1/4,trip,saw)

/// Voice mix — direct osc levels (kept for completeness).
@property (nonatomic) float mixSaw;
@property (nonatomic) float mixSquare;
@property (nonatomic) float mixSub;
/// Single TONE blend (0..1): 0 = saw + sub heavy (dark), 1 = square heavy
/// (bright). Setting tone overwrites the three mix levels internally.
@property (nonatomic) float tone;

/// Filter
@property (nonatomic) float cutoffHz;
@property (nonatomic) float resonance;
@property (nonatomic) float filterEnvAmount;

/// Envelopes
@property (nonatomic) float ampA;
@property (nonatomic) float ampD;
@property (nonatomic) float ampS;
@property (nonatomic) float ampR;
@property (nonatomic) float fltA;
@property (nonatomic) float fltD;
@property (nonatomic) float fltS;
@property (nonatomic) float fltR;

/// Voice character — 0=SYNTH, 1=PLUCK, 2=MALLET. Affects ADSR + filter
/// behaviour per voice slot.
@property (nonatomic) int voiceMode;

/// Load one of 5 phrase presets into the 16-step grid:
/// 0=Ascending 1=Kotekan 2=Kalimba 3=Sarangi 4=Balafon.
- (void)loadPhrase:(int)phraseId;

/// DUBSTEP wobble pattern editor — 8 steps, each step picks a wobble
/// division: 0=1/2, 1=1/4, 2=1/8, 3=1/16, 4=1/8T, 5=STOP.
- (int)dubstepStep:(int)step;
- (void)setDubstepStep:(int)step division:(int)division;
@property (nonatomic, readonly) NSInteger dubstepPatternLen;
@property (nonatomic, readonly) NSInteger dubstepDivisionCount;
- (NSString *)dubstepDivisionName:(int)division;
/// Pattern step the wobble sequencer is on right now (0..7) — UI playhead.
@property (nonatomic, readonly) int dubstepCurrentStep;
/// DUBSTEP NOTE length: 0=1× (gated per step) 1=2× 2=4× 3=HOLD (until next note).
@property (nonatomic) int dubNoteLen;
- (NSString *)dubNoteLenName:(int)len;

/// Step grid (legacy mono — kept for compatibility)
- (BOOL)stepOn:(int)i;
- (void)setStep:(int)i on:(BOOL)on semi:(int)semi oct:(int)oct;
- (int)stepSemi:(int)i;
- (int)stepOct:(int)i;

/// ── MELODIC STEP-GRID ("Drums machine for keys") ──────────────────
/// 8 note rows × 16 steps, polyphonic, per pattern slot A/B/C/D.
@property (nonatomic, readonly) int numGridRows;
/// Step count — 16 / 32 / 64.
@property (nonatomic) int gridSteps;
- (BOOL)cellAtRow:(int)row step:(int)step;
/// Slot-addressed grid access for state save / load. These never change the
/// live pattern slot (flipping it during a save fired the wrong pattern).
- (BOOL)cellInSlot:(int)slot row:(int)row step:(int)step;
- (void)setCellInSlot:(int)slot row:(int)row step:(int)step on:(BOOL)on;
/// NOTE LENGTH (in steps, ≥ 1) of the note STARTING at row/step. Tail cells
/// stay off; the start cell owns them. Edit-slot and slot-addressed variants.
- (int)lengthAtRow:(int)row step:(int)step;
- (void)setLength:(int)len atRow:(int)row step:(int)step;
- (int)lengthInSlot:(int)slot row:(int)row step:(int)step;
- (void)setLengthInSlot:(int)slot row:(int)row step:(int)step length:(int)len;
- (int)colSwingInSlot:(int)slot step:(int)step;
- (void)setColSwingInSlot:(int)slot step:(int)step level:(int)level;
- (int)recRootInSlot:(int)slot step:(int)step;          // recorded root track, -1 = none
- (void)setRecRootInSlot:(int)slot step:(int)step midi:(int)midi;

- (void)setCellAtRow:(int)row step:(int)step on:(BOOL)on;
- (void)clearGrid;
/// Pattern slots A/B/C/D (0..3). `currentSlot` is the EDIT slot — the
/// PATTERN button the user picked; it never moves on its own.
@property (nonatomic) int currentSlot;
/// The slot the engine is actually firing. Equals currentSlot unless a LINK
/// chain is running, in which case the chain drives it (UI shows a dot).
@property (nonatomic, readonly) int playSlot;
/// Copy the current pattern into another slot (Swift: copyPattern(toSlot:)).
- (void)copyPatternToSlot:(int)dst;
/// Pattern chaining (song mode): ordered slot list (0..3), advances one entry
/// per grid loop. Empty = off. `chainPosition` = the entry currently playing.
- (void)setChainSlots:(NSArray<NSNumber *> *)slots;
- (NSArray<NSNumber *> *)chainSlots;
- (void)clearChain;
/// ISOLATE (Engine 909 behaviour) — loop the pattern on the grid on its own;
/// the LINK chain stays stored and resumes when ISOLATE is switched off.
/// Persisted in the state blob (key `isolate`, absent in old sessions = off).
@property (nonatomic) BOOL isolate;
/// Per-row drag crosshair (909 "copy, ⌥ swap"): copy / swap one note row's
/// notes + lengths on the current pattern slot.
- (void)copyGridRow:(int)src toRow:(int)dst;
- (void)swapGridRow:(int)a withRow:(int)b;
@property (nonatomic, readonly) int chainPosition;
/// Global octave shift of the 8-row window (-2..+2) and the ♯ half-tone switch.
@property (nonatomic) int  gridOctave;
@property (nonatomic) BOOL halfTone;
/// REC arm — captures the live MIDI root per-step into the current slot.
@property (nonatomic) BOOL recordArmed;
/// Per-column swing ticks (0..4), mirrors the Drums per-cell swing.
- (int)colSwing:(int)step;
- (void)setColSwing:(int)step level:(int)level;
/// MIDI note a given row maps to (for note-name row labels).
- (int)gridRowMidi:(int)row;

/// Comet-field probe — fills the buffers with the most-recent N notes that
/// fired, newest first. Returns how many were populated. Notes older than
/// ~6 s are skipped.
- (int)readNoteHistory:(int * _Nonnull)midiOut
                   age:(double * _Nonnull)ageSecondsOut
              capacity:(int)cap;
/// Held chord notes (MIDI) for drawing the right-edge targets.
- (int)chordNoteAt:(int)index;
/// Smoothed master amplitude (0..1) for the background pulse.
@property (nonatomic, readonly) float amplitudeEnv;

/// Full-state blob (all synth params + 4 pattern grids + swing + chain). Used
/// by the UI's named SAVE/LOAD presets; the same bytes ride inside fullState so
/// the host restores everything on project reload.
- (NSData *)stateData;
- (void)loadStateData:(NSData *)data;

@end

NS_ASSUME_NONNULL_END
