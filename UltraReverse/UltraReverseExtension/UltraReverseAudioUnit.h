#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface UltraReverseAudioUnit : AUAudioUnit
/// Live scope probe — number of dry/wet peak buckets available.
@property (nonatomic, readonly) NSInteger probeSize;
/// Fill `dryOut` + `wetOut` with the most-recent `count` peak buckets
/// (oldest→newest). Returns the number written.
- (NSInteger)readProbeDry:(float *)dryOut wet:(float *)wetOut count:(NSInteger)count;
/// 0…1 position inside the current reverse segment (ECHO / REVERB).
@property (nonatomic, readonly) float segmentPhase;
/// Length of the current reverse segment in seconds (ECHO / REVERB).
@property (nonatomic, readonly) float segmentSeconds;
@end
NS_ASSUME_NONNULL_END
