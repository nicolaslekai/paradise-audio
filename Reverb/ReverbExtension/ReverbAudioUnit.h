#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface ReverbAudioUnit : AUAudioUnit
/// Block peak levels (0..1+) for the space preview: dry input and wet output.
@property (nonatomic, readonly) float inputLevel;
@property (nonatomic, readonly) float outputLevel;
@end
NS_ASSUME_NONNULL_END
