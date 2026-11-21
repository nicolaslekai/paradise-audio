//
//  LimiterAudioUnit.h
//
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LimiterAudioUnit : AUAudioUnit

/// Live meter readouts (read from the audio thread, latched for UI)
@property (nonatomic, readonly) float currentGainReductionDB;
@property (nonatomic, readonly) float currentInputPeakDB;
/// K-weighted LUFS metering per ITU-R BS.1770-4.
///   shortTermLUFS:  rolling 3-second mean
///   integratedLUFS: gated long-term mean since the last reset
@property (nonatomic, readonly) float shortTermLUFS;
@property (nonatomic, readonly) float integratedLUFS;
/// Reset the integrated-loudness accumulator (UI "I RESET" button).
- (void)resetIntegrated;
/// Drain `n` of the most-recent post-limit samples into `out`, newest
/// first. Returns the count copied. Used by the waveform visualizer.
- (int)readWaveformInto:(float * _Nonnull)out count:(int)n;

/// Editor display tap (2026-11-21). Copies up to `n` of the newest ~6 ms
/// buckets into `out`, oldest first, 5 floats per bucket:
///   inHi, inLo   (trimmed input, linear, signed — same scale as THRESHOLD)
///   outHi, outLo (output, linear, signed — same scale as CEILING)
///   grDB         (max gain reduction in the bucket, positive dB)
/// Returns the count; `writeCount` receives the running bucket counter.
- (int)readTapInto:(float * _Nonnull)out maxBuckets:(int)n writeCount:(uint32_t * _Nonnull)writeCount;
/// Seconds of audio per tap bucket.
@property (nonatomic, readonly) double tapBucketSeconds;

/// Real-time FFT spectrum probe (same as the EQ's). Fills `outDB` with
/// `count` log-spaced magnitude bands (dB) covering 20 Hz – 20 kHz from the
/// post-limit signal. UI polls this on a timer to draw the live spectrum.
- (BOOL)readSpectrumBands:(float * _Nonnull)outDB count:(int)count;

/// Apply one of the loudness-target presets:
///   0 = BROADCAST (-23 LUFS target): threshold -12, ceiling -3, release 100 ms
///   1 = STREAM    (-14 LUFS target): threshold -14, ceiling -1, release 60 ms
/// (same drive as the old gain +6 / +12 presets; trim is reset to 0)
- (void)applyLoudnessPreset:(int)preset;

@end

NS_ASSUME_NONNULL_END
