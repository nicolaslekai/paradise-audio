//
//  VoiceBoxAudioUnit.h
//
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Live readout for the editor (lip-synced head + autotune display).
typedef struct {
    float level;       ///< output RMS (linear), peak-held since the previous read
    float midi;        ///< detected input pitch, fractional MIDI note
    float targetMidi;  ///< AUTOTUNE target note, −1 when there is none
    float corrCents;   ///< correction applied to the lead voice (0 when AUTOTUNE is off)
    int   voiced;      ///< 1 while the tracker hears a pitched voice
} VBVoiceMeter;

@interface VoiceBoxAudioUnit : AUAudioUnit

/// Fill `out` with the latest meter values (UI thread; lock-free reads).
- (void)readVoiceMeter:(VBVoiceMeter * _Nonnull)out NS_SWIFT_NAME(readVoiceMeter(_:));

/// Real-time FFT spectrum probe (same as the EQ/Limiter). Fills `outDB` with
/// `count` log-spaced magnitude bands (dB) of the post-effects signal, so the
/// analyzer visibly reacts as effects engage.
- (BOOL)readSpectrumBands:(float * _Nonnull)outDB count:(int)count;

/// Apply one of the built-in presets (0..9). Sets the whole parameter tree.
- (void)applyPreset:(int)preset;
/// Display name for a preset index.
- (NSString *)presetName:(int)preset;
@property (nonatomic, readonly) int presetCount;

@end

NS_ASSUME_NONNULL_END
