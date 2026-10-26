#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

/// Hardware H.264 encoder. Hands out each frame as an Annex-B byte stream, the format ffmpeg reads with `-f h264`.
/// The stream is always 1920x1080 so the PC's webcam never changes size; portrait frames get black bars.
@interface H264Encoder : NSObject

@property (nonatomic, copy) void (^onEncoded)(NSData *data, BOOL isKeyframe);
/// Called on the video queue with each event the debug port reports: the rate settings and what the session took
/// of them, and each step down or up.
@property (nonatomic, copy) void (^onEvent)(NSDictionary *event);
/// The bitrate the encoder aims for now, at or below the target. Read on the video queue.
@property (nonatomic, readonly) int bitRate;
/// The camera's top frame rate, which rate control and keyframes plan around. Read on the video queue.
@property (nonatomic, readonly) int topFrameRate;
/// Set by the debug port's bitrate command; adaptation leaves the bitrate alone until unpin. Read on the video queue.
@property (nonatomic, readonly) BOOL isPinned;

- (void)requestKeyframe;
/// The bits, frames and keyframes handed out since the last call, as the debug port's out, encoded and keyframes.
- (NSDictionary *)takeOutput;
/// Called on the video queue, like reset, setFrameRate and adaptToBacklog.
- (void)encode:(CMSampleBufferRef)sampleBuffer;
- (void)reset;
/// Plans rate control and keyframes around the camera's top frame rate, and restarts the bitrate at its target.
- (void)setFrameRate:(int)frameRate;
/// Called once a second with the most sends any client had waiting.
/// Steps the bitrate down while a client falls behind, and back up after 10 s without a backlog.
- (void)adaptToBacklog:(int)backlog;
/// Holds the bitrate until unpin, for the debug port.
- (void)pinBitRate:(int)bitRate;
/// Hands the bitrate back to adaptation, from where it is.
- (void)unpin;

@end
