#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface DeesserAudioUnit : AUAudioUnit
@property (nonatomic, readonly) float currentGainReductionDB;

/// Real-time FFT spectrum probe. Fills `outDB` with `count` log-spaced
/// magnitude bands covering 20 Hz – 20 kHz. UI polls on a timer.
- (BOOL)readSpectrumBands:(float *)outDB count:(int)count;
@end
NS_ASSUME_NONNULL_END
