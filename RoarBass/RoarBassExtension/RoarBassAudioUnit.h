//
//  RoarBassAudioUnit.h
//  RoarBass
//

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RoarBassAudioUnit : AUAudioUnit
// parameterTree is inherited from AUAudioUnit and assigned in init.
/// Scope tap for the editor (2026-11-21): copies the newest `count` output samples (left channel,
/// oldest first) into `dst` and returns how many were copied. Lock-free; a torn read only costs
/// one odd frame of the picture.
- (NSInteger)readScope:(float *)dst count:(NSInteger)count NS_SWIFT_NAME(readScope(_:count:));
/// Output sample rate (the editor scales the scope's time axis with it).
@property (nonatomic, readonly) double scopeSampleRate;
@end

NS_ASSUME_NONNULL_END
