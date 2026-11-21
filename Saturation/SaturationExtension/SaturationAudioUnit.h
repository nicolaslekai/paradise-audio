#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface SaturationAudioUnit : AUAudioUnit
/// Returns the transfer-curve output for input x ∈ [-1.5, 1.5] under current params.
- (float)transferAt:(float)x;
/// Live output peak (0..1), smoothed — drives the curve's swell/glow in the UI.
@property (nonatomic, readonly) float currentLevel;
@end
NS_ASSUME_NONNULL_END
