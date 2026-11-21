#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface DelayAudioUnit : AUAudioUnit
/// Host tempo read from Logic's musicalContextBlock (120 until the host
/// hands us one). `bpmSynced` flips once a real tempo arrived.
@property (nonatomic, readonly) float hostBPM;
@property (nonatomic, readonly) BOOL  bpmSynced;
/// The delay times actually running in the DSP (ms) — equals the TIME
/// knobs when SYNC is off, or the note division × host tempo when on.
@property (nonatomic, readonly) float effectiveTimeL;
@property (nonatomic, readonly) float effectiveTimeR;
/// Note-division table shared with the UI (index → beats).
+ (int)divisionCount;
+ (float)beatsForDivision:(int)index;
+ (NSString *)divisionName:(int)index;
@end
NS_ASSUME_NONNULL_END
