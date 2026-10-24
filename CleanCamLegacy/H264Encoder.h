#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

/// Hardware H.264 encoder. Hands out each frame as an Annex-B byte stream, the format ffmpeg reads with `-f h264`.
/// The stream is always 1920x1080 so the PC's webcam never changes size; portrait frames get black bars.
@interface H264Encoder : NSObject

@property (nonatomic, copy) void (^onEncoded)(NSData *data, BOOL isKeyframe);

- (void)requestKeyframe;
/// Called on the video queue, like reset.
- (void)encode:(CMSampleBufferRef)sampleBuffer;
- (void)reset;

@end
