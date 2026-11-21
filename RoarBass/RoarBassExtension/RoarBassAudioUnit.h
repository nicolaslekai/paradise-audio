//
//  RoarBassAudioUnit.h
//  RoarBass
//

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RoarBassAudioUnit : AUAudioUnit
// parameterTree is inherited from AUAudioUnit and assigned in init.
@end

NS_ASSUME_NONNULL_END
