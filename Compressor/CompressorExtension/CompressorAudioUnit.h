//
//  CompressorAudioUnit.h
//

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CompressorAudioUnit : AUAudioUnit
// parameterTree is inherited from AUAudioUnit and assigned in init.

// Live gain-reduction in dB (positive number = how many dB of attenuation
// the compressor is currently applying). Read by the UI for the meter.
@property (nonatomic, readonly) float currentGainReductionDB;

// Internal "phantom sidechain" duck — UI calls these directly.
//   setDuckEnabled:        toggle on/off
//   setDuckRate:           1=whole 2=half 3=quarter 4=eighth (keys 1-4)
//   setDuckDepthDB:        0..36 dB extra attenuation per trigger
//   triggerDuck:           fire an immediate duck (manual hit)
//   currentDuckDB:         live envelope dB for meters
//   duckPhase:             0..1 progress to next auto trigger (for UI)
@property (nonatomic, readonly) BOOL  duckEnabled;
@property (nonatomic, readonly) int   duckRate;
@property (nonatomic, readonly) float duckDepthDB;
@property (nonatomic, readonly) float currentDuckDB;
@property (nonatomic, readonly) float duckPhase;
@property (nonatomic, readonly) float duckBPM;
/// YES once Logic (or any other host with a musicalContextBlock) has fed
/// us a tempo at least once — UI shows a SYNC pip next to the BPM so
/// the user knows it's host-driven, not manual.
@property (nonatomic, readonly) BOOL  bpmSynced;
- (void)setDuckEnabled:(BOOL)on;
- (void)setDuckRate:(int)rate;
- (void)setDuckDepthDB:(float)db;
- (void)setDuckBPM:(float)bpm;
- (void)triggerDuck;

// Live waveform probe for the left visualiser. Caller passes two float arrays
// of length `count`; engine writes the most recent `count` input-peak and
// compressed-output-peak buckets. Returns the number of samples written.
- (NSInteger)readProbeIn:(float * _Nonnull)inOut
                     out:(float * _Nonnull)outOut
                   count:(NSInteger)count;
@property (nonatomic, readonly) NSInteger probeSize;

/// Live FFT spectrum — fills `inDB` (input) and `outDB` (compressed output)
/// with `count` log-spaced magnitude bands (dB), 20 Hz–20 kHz. Drawn as a
/// smooth EQ-style analyzer. Returns NO if not yet available.
- (BOOL)readSpectrumIn:(float * _Nonnull)inDB
                   out:(float * _Nonnull)outDB
                 count:(NSInteger)count;
@end

NS_ASSUME_NONNULL_END
