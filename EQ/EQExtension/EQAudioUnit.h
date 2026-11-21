#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface EQAudioUnit : AUAudioUnit
// parameterTree inherited from AUAudioUnit and assigned in init.

/// Get the magnitude response (dB) at a given frequency for the current
/// parameter values. Used by the UI to draw the frequency response curve.
- (float)magnitudeDBAtFrequency:(float)hz;

/// Real-time FFT spectrum probe. Fills `outDB` with `count` log-spaced
/// magnitude bands (in dB) covering 20 Hz – 20 kHz. UI polls this on a
/// timer to draw the live audio spectrum behind the EQ curve. Returns YES
/// if data was available; NO if the ring buffer is empty.
- (BOOL)readSpectrumBands:(float *)outDB count:(int)count;

/// Per-band SHAPE selector (the "bell cover" — switch each mid band between
/// classic shelf and bell/peaking parametric).
@property (nonatomic) BOOL lowIsBell;
@property (nonatomic) BOOL highIsBell;
@end

NS_ASSUME_NONNULL_END
