#import <Foundation/Foundation.h>

/// Plays the PC's speaker audio on the iPhone's loudspeaker and records its microphone through Apple's
/// voice-processing audio unit, which removes the loudspeaker's echo from the microphone, as in a phone call.
/// Both directions are 48 kHz mono 16-bit PCM.
@interface CallAudio : NSObject

/// Called on the audio thread with the microphone's PCM.
@property (nonatomic, copy) void (^onMicPCM)(NSData *pcm);

/// Starts the loudspeaker and, when allowed, the microphone; `onMicReady` gets whether the microphone runs.
- (void)startWithMicAllowed:(BOOL)micAllowed onMicReady:(void (^)(BOOL micRunning))onMicReady;
- (void)stop;
/// Stops or resumes sending the microphone; the voice processing keeps running.
- (void)setMicEnabled:(BOOL)enabled;
/// Queues PCM from the PC for the loudspeaker.
- (void)play:(NSData *)data;

@end
