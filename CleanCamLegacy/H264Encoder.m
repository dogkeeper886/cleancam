#import "H264Encoder.h"

#import <CoreImage/CoreImage.h>
#import <VideoToolbox/VideoToolbox.h>

static const int32_t kWidth = 1920;
static const int32_t kHeight = 1080;
static const uint8_t kStartCode[] = {0, 0, 0, 1};

@implementation H264Encoder {
    // Used on the video queue only.
    VTCompressionSessionRef _session;
    CIContext *_ciContext;
    CVPixelBufferPoolRef _letterboxPool;

    NSLock *_lock;
    BOOL _keyframeRequested;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _ciContext = [CIContext contextWithOptions:nil];
    _lock = [NSLock new];
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

- (void)encode:(CMSampleBufferRef)sampleBuffer {
    CVImageBufferRef source = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!source) return;
    CVPixelBufferRef imageBuffer = [self fitToStream:source];
    if (!imageBuffer) return;
    if (!_session) _session = [H264Encoder makeSession];
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

+ (VTCompressionSessionRef)makeSession CF_RETURNS_RETAINED {
    VTCompressionSessionRef session = NULL;
    VTCompressionSessionCreate(NULL, kWidth, kHeight, kCMVideoCodecType_H264, NULL, NULL, NULL, NULL, NULL, &session);
    if (!session) return NULL;
    NSDictionary *properties = @{
        (__bridge NSString *)kVTCompressionPropertyKey_RealTime: @YES,
        (__bridge NSString *)kVTCompressionPropertyKey_ProfileLevel: (__bridge NSString *)kVTProfileLevel_H264_High_AutoLevel,
        (__bridge NSString *)kVTCompressionPropertyKey_AllowFrameReordering: @NO,  // no B-frames, less delay
        (__bridge NSString *)kVTCompressionPropertyKey_AverageBitRate: @10000000,
        (__bridge NSString *)kVTCompressionPropertyKey_ExpectedFrameRate: @30,
        (__bridge NSString *)kVTCompressionPropertyKey_MaxKeyFrameInterval: @60,
    };
    VTSessionSetProperties(session, (__bridge CFDictionaryRef)properties);
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
