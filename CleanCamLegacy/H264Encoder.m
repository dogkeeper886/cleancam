#import "H264Encoder.h"

#import <CoreImage/CoreImage.h>
#import <VideoToolbox/VideoToolbox.h>

static const int32_t kWidth = 1920;
static const int32_t kHeight = 1080;
static const uint8_t kStartCode[] = {0, 0, 0, 1};
/// The target bitrate at 30 fps, about 0.16 bits per pixel in each frame; the target scales with the frame rate.
static const int kTargetAt30fps = 10000000;
/// A backlog past this many sends, of the server's 30, means the link carries less than the stream sends.
static const int kCongestedBacklog = 10;
/// Seconds without any backlog before the bitrate steps back up.
static const int kRecoverySeconds = 10;
/// Each step changes the bitrate by this share.
static const double kStep = 0.2;
/// The lowest share of the target the bitrate steps down to.
static const double kFloorShare = 0.2;

@implementation H264Encoder {
    // Used on the video queue only.
    /// The camera's top frame rate; rate control and keyframes plan around it.
    int _frameRate;
    int _secondsWithoutBacklog;
    VTCompressionSessionRef _session;
    CIContext *_ciContext;
    CVPixelBufferPoolRef _letterboxPool;

    NSLock *_lock;
    BOOL _keyframeRequested;
    int _outputBytes;
    int _outputFrames;
    int _outputKeyframes;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _ciContext = [CIContext contextWithOptions:nil];
    _lock = [NSLock new];
    _frameRate = 30;
    _bitRate = kTargetAt30fps;
    return self;
}

- (void)dealloc {
    [self reset];
    if (_letterboxPool) CVPixelBufferPoolRelease(_letterboxPool);
}

- (void)requestKeyframe {
    [_lock lock];
    _keyframeRequested = YES;
    [_lock unlock];
}

- (NSDictionary *)takeOutput {
    [_lock lock];
    NSDictionary *output = @{@"out": @(_outputBytes * 8), @"encoded": @(_outputFrames), @"keyframes": @(_outputKeyframes)};
    _outputBytes = 0;
    _outputFrames = 0;
    _outputKeyframes = 0;
    [_lock unlock];
    return output;
}

- (int)topFrameRate {
    return _frameRate;
}

- (void)encode:(CMSampleBufferRef)sampleBuffer {
    CVImageBufferRef source = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!source) return;
    CVPixelBufferRef imageBuffer = [self fitToStream:source];
    if (!imageBuffer) return;
    if (!_session) _session = [self makeSession];
    if (!_session) {
        CVPixelBufferRelease(imageBuffer);
        return;
    }

    [_lock lock];
    BOOL forceKeyframe = _keyframeRequested;
    _keyframeRequested = NO;
    [_lock unlock];
    NSDictionary *frameProperties = forceKeyframe
        ? @{(__bridge NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES}
        : nil;
    __weak H264Encoder *weakSelf = self;
    OSStatus status = VTCompressionSessionEncodeFrameWithOutputHandler(
        _session, imageBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer), kCMTimeInvalid,
        (__bridge CFDictionaryRef)frameProperties, NULL,
        ^(OSStatus encodeStatus, VTEncodeInfoFlags infoFlags, CMSampleBufferRef encoded) {
            if (encodeStatus != noErr || !encoded) return;
            [weakSelf emit:encoded];
        });
    CVPixelBufferRelease(imageBuffer);
    // The session stops working after the app has been in the background; make a new one on the next frame.
    if (status != noErr) [self reset];
}

- (void)reset {
    if (_session) {
        VTCompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
}

- (void)setFrameRate:(int)frameRate {
    if (frameRate <= 0 || frameRate == _frameRate) return;
    _frameRate = frameRate;
    _bitRate = [self targetBitRate];
    _secondsWithoutBacklog = 0;
    [self applyRatesFor:@"frameRate"];
}

- (void)pinBitRate:(int)bitRate {
    _isPinned = YES;
    _bitRate = bitRate;
    [self applyRatesFor:@"pin"];
}

- (void)unpin {
    _isPinned = NO;
    _secondsWithoutBacklog = 0;
}

- (void)adaptToBacklog:(int)backlog {
    if (_isPinned) return;
    int next = _bitRate;
    if (backlog > kCongestedBacklog) {
        _secondsWithoutBacklog = 0;
        next = MAX((int)(_bitRate * (1 - kStep)), (int)([self targetBitRate] * kFloorShare));
    } else if (backlog > 0) {
        _secondsWithoutBacklog = 0;
    } else {
        _secondsWithoutBacklog += 1;
        if (_secondsWithoutBacklog < kRecoverySeconds) return;
        _secondsWithoutBacklog = 0;
        // One step up undoes one step down.
        next = MIN((int)(_bitRate / (1 - kStep)), [self targetBitRate]);
    }
    if (next == _bitRate) return;
    NSString *reason = next < _bitRate ? @"down" : @"up";
    _bitRate = next;
    [self applyRatesFor:reason];
}

- (int)targetBitRate {
    return kTargetAt30fps * _frameRate / 30;
}

/// The settings that follow the frame rate and the bitrate; a running session takes new ones live.
- (NSDictionary *)rateProperties {
    return @{
        (__bridge NSString *)kVTCompressionPropertyKey_AverageBitRate: @(_bitRate),
        // Caps any one second at 1.5 times the average, in bytes, so a burst can't swamp the link.
        (__bridge NSString *)kVTCompressionPropertyKey_DataRateLimits: @[@(_bitRate * 3 / 2 / 8), @1],
        (__bridge NSString *)kVTCompressionPropertyKey_ExpectedFrameRate: @(_frameRate),
        // A keyframe every 2 s, also while the camera slows in the dark.
        (__bridge NSString *)kVTCompressionPropertyKey_MaxKeyFrameInterval: @(_frameRate * 2),
        (__bridge NSString *)kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: @2,
    };
}

- (void)applyRatesFor:(NSString *)reason {
    if (!_session) return;
    NSDictionary *properties = [self rateProperties];
    OSStatus status = VTSessionSetProperties(_session, (__bridge CFDictionaryRef)properties);
    [self report:properties status:status session:_session reason:reason];
}

/// Tells the debug port which rate settings were asked for, what VTSessionSetProperties returned, and what the
/// session reports back for each, since an encoder can leave out a setting it doesn't support.
- (void)report:(NSDictionary *)properties status:(OSStatus)status session:(VTCompressionSessionRef)session
        reason:(NSString *)reason {
    if (!self.onEvent) return;
    NSMutableDictionary *asked = [NSMutableDictionary dictionary];
    NSMutableDictionary *took = [NSMutableDictionary dictionary];
    for (NSString *key in @[
             (__bridge NSString *)kVTCompressionPropertyKey_AverageBitRate,
             (__bridge NSString *)kVTCompressionPropertyKey_DataRateLimits,
             (__bridge NSString *)kVTCompressionPropertyKey_ExpectedFrameRate,
             (__bridge NSString *)kVTCompressionPropertyKey_MaxKeyFrameInterval,
             (__bridge NSString *)kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
         ]) {
        if (properties[key]) asked[key] = properties[key];
        CFTypeRef value = NULL;
        OSStatus copyStatus = VTSessionCopyProperty(session, (__bridge CFStringRef)key, NULL, &value);
        id object = CFBridgingRelease(value);
        if (copyStatus != noErr) {
            took[key] = [NSString stringWithFormat:@"error %d", (int)copyStatus];
        } else if (object) {
            took[key] = [NSJSONSerialization isValidJSONObject:@[object]] ? object : [object description];
        } else {
            took[key] = [NSNull null];
        }
    }
    self.onEvent(@{@"event": @"rates", @"reason": reason, @"status": @(status), @"asked": asked, @"took": took});
}

/// Scales a frame of any other size (mainly a portrait frame) into the middle of a black 1920x1080 frame.
/// Returns a retained buffer.
- (CVPixelBufferRef)fitToStream:(CVPixelBufferRef)source CF_RETURNS_RETAINED {
    if (CVPixelBufferGetWidth(source) == kWidth && CVPixelBufferGetHeight(source) == kHeight) {
        return CVPixelBufferRetain(source);
    }
    if (!_letterboxPool) {
        NSDictionary *attributes = @{
            (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (__bridge NSString *)kCVPixelBufferWidthKey: @(kWidth),
            (__bridge NSString *)kCVPixelBufferHeightKey: @(kHeight),
            (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attributes, &_letterboxPool);
    }
    CVPixelBufferRef output = NULL;
    if (!_letterboxPool || CVPixelBufferPoolCreatePixelBuffer(NULL, _letterboxPool, &output) != kCVReturnSuccess) {
        return NULL;
    }

    CGRect frame = CGRectMake(0, 0, kWidth, kHeight);
    CIImage *image = [CIImage imageWithCVPixelBuffer:source];
    CGFloat scale = MIN(frame.size.width / image.extent.size.width, frame.size.height / image.extent.size.height);
    CIImage *scaled = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CIImage *centered = [scaled imageByApplyingTransform:CGAffineTransformMakeTranslation(
        (frame.size.width - scaled.extent.size.width) / 2, (frame.size.height - scaled.extent.size.height) / 2)];
    CIImage *black = [[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0]] imageByCroppingToRect:frame];
    [_ciContext render:[centered imageByCompositingOverImage:black] toCVPixelBuffer:output];
    return output;
}

- (VTCompressionSessionRef)makeSession CF_RETURNS_RETAINED {
    VTCompressionSessionRef session = NULL;
    VTCompressionSessionCreate(NULL, kWidth, kHeight, kCMVideoCodecType_H264, NULL, NULL, NULL, NULL, NULL, &session);
    if (!session) return NULL;
    NSMutableDictionary *properties = [@{
        (__bridge NSString *)kVTCompressionPropertyKey_RealTime: @YES,
        (__bridge NSString *)kVTCompressionPropertyKey_ProfileLevel: (__bridge NSString *)kVTProfileLevel_H264_High_AutoLevel,
        (__bridge NSString *)kVTCompressionPropertyKey_AllowFrameReordering: @NO,  // no B-frames, less delay
    } mutableCopy];
    [properties addEntriesFromDictionary:[self rateProperties]];
    OSStatus status = VTSessionSetProperties(session, (__bridge CFDictionaryRef)properties);
    [self report:properties status:status session:session reason:@"start"];
    VTCompressionSessionPrepareToEncodeFrames(session);
    return session;
}

/// Converts the encoder's length-prefixed NAL units to start-code-prefixed ones,
/// and puts SPS/PPS in front of every keyframe so a viewer can join at any keyframe.
- (void)emit:(CMSampleBufferRef)sampleBuffer {
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!block) return;
    size_t length = CMBlockBufferGetDataLength(block);
    if (length == 0) return;
    NSMutableData *avcc = [NSMutableData dataWithLength:length];
    if (CMBlockBufferCopyDataBytes(block, 0, length, avcc.mutableBytes) != noErr) return;
    const uint8_t *bytes = avcc.bytes;

    NSMutableData *nalUnits = [NSMutableData data];
    BOOL isKeyframe = NO;
    size_t offset = 0;
    while (offset + 4 <= length) {
        size_t size = (size_t)bytes[offset] << 24 | (size_t)bytes[offset + 1] << 16
            | (size_t)bytes[offset + 2] << 8 | bytes[offset + 3];
        offset += 4;
        if (size == 0 || size > length - offset) break;
        if ((bytes[offset] & 0x1F) == 5) isKeyframe = YES;  // IDR slice
        [nalUnits appendBytes:kStartCode length:sizeof kStartCode];
        [nalUnits appendBytes:bytes + offset length:size];
        offset += size;
    }

    NSMutableData *output = [NSMutableData data];
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (isKeyframe && format) [output appendData:[H264Encoder parameterSetsOf:format]];
    [output appendData:nalUnits];
    [_lock lock];
    _outputBytes += (int)output.length;
    _outputFrames += 1;
    if (isKeyframe) _outputKeyframes += 1;
    [_lock unlock];
    if (self.onEncoded) self.onEncoded(output, isKeyframe);
}

+ (NSData *)parameterSetsOf:(CMFormatDescriptionRef)format {
    NSMutableData *data = [NSMutableData data];
    size_t count = 0;
    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, NULL, NULL, &count, NULL);
    for (size_t index = 0; index < count; index++) {
        const uint8_t *pointer = NULL;
        size_t size = 0;
        if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, index, &pointer, &size, NULL, NULL) != noErr
            || !pointer) continue;
        [data appendBytes:kStartCode length:sizeof kStartCode];
        [data appendBytes:pointer length:size];
    }
    return data;
}

@end
