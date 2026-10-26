#import "CameraController.h"

#import "CallAudio.h"
#import "H264Encoder.h"
#import "StreamServer.h"

static const uint16_t kPort = 5000;
static const uint16_t kAudioPort = 5001;
static const uint16_t kSpeakerPort = 5002;
/// Auto exposure holds the top rate and slows toward the bottom one in the dark, for more light per frame.
static const int kTopFrameRate = 30;
static const int kBottomFrameRate = 20;
/// How long focus stays on a face that left the picture before it returns to the center, in seconds.
static const double kFaceTimeout = 2;
/// How far a face moves, in the sensor's 0–1 coordinates, before focus and exposure follow it.
static const double kFaceMove = 0.1;

/// What focus and exposure follow: a tap holds until the next tap or a reset, then faces, then the center.
typedef NS_ENUM(NSInteger, FocusTarget) {
    FocusTargetCenter,
    FocusTargetFace,
    FocusTargetTap,
};

static NSString *FocusTargetName(FocusTarget target) {
    switch (target) {
        case FocusTargetCenter: return @"Center";
        case FocusTargetFace: return @"Face";
        case FocusTargetTap: return @"Tap";
    }
}

static double TopFrameRate(AVCaptureDeviceFormat *format) {
    double top = 0;
    for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) top = MAX(top, range.maxFrameRate);
    return top;
}

/// Ranks modes the way BestFormat picks them.
static BOOL IsBetterFormat(AVCaptureDeviceFormat *a, AVCaptureDeviceFormat *b) {
    if (a.isVideoBinned != b.isVideoBinned) return !a.isVideoBinned;
    if (a.isVideoHDRSupported != b.isVideoHDRSupported) return a.isVideoHDRSupported;
    if (a.videoZoomFactorUpscaleThreshold != b.videoZoomFactorUpscaleThreshold) {
        return a.videoZoomFactorUpscaleThreshold > b.videoZoomFactorUpscaleThreshold;
    }
    if (a.videoFieldOfView != b.videoFieldOfView) return a.videoFieldOfView > b.videoFieldOfView;
    return TopFrameRate(a) < TopFrameRate(b);
}

/// The 1920x1080 mode that reaches the top frame rate with the best picture: unbinned first, then with video HDR,
/// then the most zoom before upscaling, then the widest view, then the lowest top rate, the mode made for that rate.
static AVCaptureDeviceFormat *BestFormat(AVCaptureDevice *device) {
    AVCaptureDeviceFormat *best = nil;
    for (AVCaptureDeviceFormat *format in device.formats) {
        CMVideoDimensions size = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
        if (size.width != 1920 || size.height != 1080) continue;
        // Video-range YUV, the usual video format; a full-range twin of a mode would shift the stream's colors.
        if (CMFormatDescriptionGetMediaSubType(format.formatDescription) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
            continue;
        }
        if (TopFrameRate(format) < kTopFrameRate) continue;
        if (!best || IsBetterFormat(format, best)) best = format;
    }
    return best;
}

/// A rate the range can't reach falls back to the range's own limit.
static CMTime FrameDuration(int rate, AVFrameRateRange *range) {
    if (rate >= range.maxFrameRate) return range.minFrameDuration;
    if (rate <= range.minFrameRate) return range.maxFrameDuration;
    return CMTimeMake(1, rate);
}

/// Called with the device locked. Auto exposure holds the top rate and slows toward the bottom one in the dark.
static void ApplyFrameRates(AVCaptureDevice *device) {
    AVFrameRateRange *range = nil;
    for (AVFrameRateRange *candidate in device.activeFormat.videoSupportedFrameRateRanges) {
        if (!range || candidate.maxFrameRate > range.maxFrameRate) range = candidate;
    }
    if (!range) return;
    device.activeVideoMinFrameDuration = FrameDuration(kTopFrameRate, range);
    device.activeVideoMaxFrameDuration = FrameDuration(kBottomFrameRate, range);
}

@interface CameraController () <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureMetadataOutputObjectsDelegate>
@property (nonatomic, readwrite, copy) NSString *status;
@property (nonatomic, readwrite) double zoom;
@property (nonatomic, readwrite) double maxZoom;
@property (nonatomic, readwrite) double losslessZoom;
@property (nonatomic, readwrite) BOOL isLocked;
@property (nonatomic, readwrite) BOOL hasMic;
@property (nonatomic, readwrite) BOOL isMicOn;
/// The camera mode's size, such as "1080p", once the camera runs.
@property (nonatomic, copy) NSString *formatName;
/// The frames the camera delivered in the last second.
@property (nonatomic) int frameRate;
@property (nonatomic) FocusTarget focusTarget;
@end

@implementation CameraController {
    AVCaptureSession *_session;
    AVCaptureVideoDataOutput *_videoOutput;
    AVCaptureMetadataOutput *_metadataOutput;
    dispatch_queue_t _sessionQueue;
    dispatch_queue_t _videoQueue;
    H264Encoder *_encoder;
    CallAudio *_callAudio;
    StreamServer *_server;
    StreamServer *_audioServer;
    StreamServer *_speakerServer;
    // Used on _sessionQueue only.
    AVCaptureDevice *_device;
    AVCaptureVideoOrientation _videoOrientation;
    BOOL _deviceLocked;
    FocusTarget _target;
    CGPoint _facePoint;
    double _lastFaceTime;
    BOOL _faceTimeoutScheduled;
    // Used on _videoQueue only.
    int _framesThisSecond;
    dispatch_source_t _frameTimer;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _status = @"Starting…";
    _zoom = 1;
    _maxZoom = 1;
    _losslessZoom = 1;
    _isMicOn = YES;
    _session = [AVCaptureSession new];
    _previewLayer = [AVCaptureVideoPreviewLayer new];
    _previewLayer.session = _session;
    _previewLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    _videoOutput = [AVCaptureVideoDataOutput new];
    _metadataOutput = [AVCaptureMetadataOutput new];
    _sessionQueue = dispatch_queue_create("cleancam.session", DISPATCH_QUEUE_SERIAL);
    _videoQueue = dispatch_queue_create("cleancam.video", DISPATCH_QUEUE_SERIAL);
    _encoder = [H264Encoder new];
    _callAudio = [CallAudio new];
    _server = [[StreamServer alloc] initWithPort:kPort];
    _audioServer = [[StreamServer alloc] initWithPort:kAudioPort];
    _speakerServer = [[StreamServer alloc] initWithPort:kSpeakerPort];
    _videoOrientation = AVCaptureVideoOrientationLandscapeRight;
    _facePoint = CGPointMake(0.5, 0.5);

    StreamServer *server = _server;
    _encoder.onEncoded = ^(NSData *data, BOOL isKeyframe) {
        [server broadcast:data isKeyframe:isKeyframe];
    };
    StreamServer *audioServer = _audioServer;
    _callAudio.onMicPCM = ^(NSData *pcm) {
        if (!audioServer.hasClients) return;
        // Raw audio has no keyframes: a client can start at any chunk.
        [audioServer broadcast:pcm isKeyframe:YES];
    };
    CallAudio *callAudio = _callAudio;
    _speakerServer.onReceive = ^(NSData *data) {
        [callAudio play:data];
    };
    H264Encoder *encoder = _encoder;
    __weak CameraController *weakSelf = self;
    _server.onClientsChanged = ^(NSUInteger count) {
        // A new viewer can only start decoding at a keyframe.
        if (count > 0) [encoder requestKeyframe];
        dispatch_async(dispatch_get_main_queue(), ^{
            CameraController *strongSelf = weakSelf;
            strongSelf.status = count > 0
                ? @"Streaming to PC"
                : [NSString stringWithFormat:@"Waiting for PC on port %u", kPort];
            [strongSelf changed];
        });
    };
    return self;
}

- (NSString *)details {
    if (!self.formatName) return @"";
    return [NSString stringWithFormat:@"%@ · %d fps · %@", self.formatName, self.frameRate, FocusTargetName(self.focusTarget)];
}

- (void)start {
    [_server start];
    [_audioServer start];
    [_speakerServer start];
    [self startFrameCounter];
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
        if (!granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.status = @"Allow camera access in Settings";
                [self changed];
            });
            return;
        }
        // Ask for the microphone too; the camera and the loudspeaker work whatever the answer.
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL micAllowed) {
            [self->_callAudio startWithMicAllowed:micAllowed onMicReady:^(BOOL micRunning) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.hasMic = micRunning;
                    [self changed];
                });
            }];
            dispatch_async(self->_sessionQueue, ^{
                if (!self->_device) [self configure];
                [self->_session startRunning];
            });
            // A session that falls back to the preset's mode can reset the frame rates as it starts.
            [self withDeviceLock:^(AVCaptureDevice *device) { ApplyFrameRates(device); }];
        }];
    }];
}

- (void)stop {
    [_server stop];
    [_audioServer stop];
    [_speakerServer stop];
    [_callAudio stop];
    dispatch_async(_sessionQueue, ^{ [self->_session stopRunning]; });
    dispatch_async(_videoQueue, ^{
        if (self->_frameTimer) {
            dispatch_source_cancel(self->_frameTimer);
            self->_frameTimer = nil;
        }
        [self->_encoder reset];
    });
}

- (void)updateOrientation:(UIDeviceOrientation)deviceOrientation {
    AVCaptureVideoOrientation orientation;
    switch (deviceOrientation) {
        case UIDeviceOrientationPortrait: orientation = AVCaptureVideoOrientationPortrait; break;
        case UIDeviceOrientationLandscapeLeft: orientation = AVCaptureVideoOrientationLandscapeRight; break;  // home button on the right
        case UIDeviceOrientationLandscapeRight: orientation = AVCaptureVideoOrientationLandscapeLeft; break;
        default: return;
    }
    dispatch_async(_sessionQueue, ^{
        self->_videoOrientation = orientation;
        [self applyOrientation];
    });
}

- (void)setPreviewEnabled:(BOOL)enabled {
    _previewLayer.connection.enabled = enabled;
}

- (void)setZoom:(double)zoom {
    _zoom = zoom;
    [self changed];
    [self withDeviceLock:^(AVCaptureDevice *device) { device.videoZoomFactor = zoom; }];
}

- (void)toggleLock {
    self.isLocked = !self.isLocked;
    [self changed];
    BOOL lock = self.isLocked;
    [self withDeviceLock:^(AVCaptureDevice *device) {
        self->_deviceLocked = lock;
        AVCaptureFocusMode focus = lock ? AVCaptureFocusModeLocked : AVCaptureFocusModeContinuousAutoFocus;
        AVCaptureExposureMode exposure = lock ? AVCaptureExposureModeLocked : AVCaptureExposureModeContinuousAutoExposure;
        AVCaptureWhiteBalanceMode whiteBalance = lock
            ? AVCaptureWhiteBalanceModeLocked : AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance;
        if ([device isFocusModeSupported:focus]) device.focusMode = focus;
        if ([device isExposureModeSupported:exposure]) device.exposureMode = exposure;
        if ([device isWhiteBalanceModeSupported:whiteBalance]) device.whiteBalanceMode = whiteBalance;
    }];
}

- (void)focusAtPreviewPoint:(CGPoint)point {
    CGPoint devicePoint = [_previewLayer captureDevicePointOfInterestForPoint:point];
    [self withDeviceLock:^(AVCaptureDevice *device) {
        if (self->_deviceLocked) return;
        [self setTarget:FocusTargetTap point:devicePoint device:device];
    }];
}

- (void)resetFocus {
    [self withDeviceLock:^(AVCaptureDevice *device) {
        if (self->_deviceLocked) return;
        [self setTarget:FocusTargetCenter point:CGPointMake(0.5, 0.5) device:device];
    }];
}

- (void)toggleMic {
    self.isMicOn = !self.isMicOn;
    [self changed];
    [_callAudio setMicEnabled:self.isMicOn];
}

/// Called on the main queue.
- (void)changed {
    if (self.onChange) self.onChange();
}

/// Called on _sessionQueue.
- (void)configure {
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    AVCaptureDeviceInput *input = device ? [AVCaptureDeviceInput deviceInputWithDevice:device error:nil] : nil;
    if (!input) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.status = @"No camera found";
            [self changed];
        });
        return;
    }

    [_session beginConfiguration];
    if ([_session canAddInput:input]) [_session addInput:input];
    if ([_session canSetSessionPreset:AVCaptureSessionPreset1920x1080]) _session.sessionPreset = AVCaptureSessionPreset1920x1080;
    _videoOutput.alwaysDiscardsLateVideoFrames = YES;
    [_videoOutput setSampleBufferDelegate:self queue:_videoQueue];
    if ([_session canAddOutput:_videoOutput]) [_session addOutput:_videoOutput];
    [self addFaceDetection];
    // Inside the session's configuration, so the session keeps this mode instead of the preset's.
    if ([device lockForConfiguration:nil]) {
        AVCaptureDeviceFormat *format = BestFormat(device);
        if (format) device.activeFormat = format;
        ApplyFrameRates(device);
        if (device.isSmoothAutoFocusSupported) device.smoothAutoFocusEnabled = YES;
        if (device.isLowLightBoostSupported) device.automaticallyEnablesLowLightBoostWhenAvailable = YES;
        [device unlockForConfiguration];
    }
    [_session commitConfiguration];
    _device = device;
    [self applyOrientation];

    CMVideoDimensions size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription);
    double lossless = device.activeFormat.videoZoomFactorUpscaleThreshold;
    double maxZoom = MIN(device.activeFormat.videoMaxZoomFactor, 10);
    dispatch_async(dispatch_get_main_queue(), ^{
        self.formatName = [NSString stringWithFormat:@"%dp", size.height];
        self.losslessZoom = lossless;
        self.maxZoom = maxZoom;
        [self changed];
    });
}

/// Called on _sessionQueue inside the session's configuration.
/// Faces arrive in captureOutput:didOutputMetadataObjects:fromConnection:.
- (void)addFaceDetection {
    if (![_session canAddOutput:_metadataOutput]) return;
    [_session addOutput:_metadataOutput];
    if (![_metadataOutput.availableMetadataObjectTypes containsObject:AVMetadataObjectTypeFace]) return;
    _metadataOutput.metadataObjectTypes = @[AVMetadataObjectTypeFace];
    [_metadataOutput setMetadataObjectsDelegate:self queue:_sessionQueue];
}

/// Called on _sessionQueue with the device locked. The point is in the sensor's 0–1 coordinates.
- (void)setTarget:(FocusTarget)target point:(CGPoint)point device:(AVCaptureDevice *)device {
    _target = target;
    if (device.isFocusPointOfInterestSupported) device.focusPointOfInterest = point;
    // Setting the mode again starts focusing and metering at the new point.
    if ([device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
        device.focusMode = AVCaptureFocusModeContinuousAutoFocus;
    }
    if (device.isExposurePointOfInterestSupported) device.exposurePointOfInterest = point;
    if ([device isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
        device.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        self.focusTarget = target;
        [self changed];
    });
}

/// Called on _sessionQueue. Returns focus to the center once no face has shown for kFaceTimeout.
- (void)scheduleFaceTimeoutAfter:(double)delay {
    if (_faceTimeoutScheduled) return;
    _faceTimeoutScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _sessionQueue, ^{
        self->_faceTimeoutScheduled = NO;
        AVCaptureDevice *device = self->_device;
        if (self->_target != FocusTargetFace || self->_deviceLocked || !device) return;
        double idle = [NSProcessInfo processInfo].systemUptime - self->_lastFaceTime;
        if (idle < kFaceTimeout) {
            [self scheduleFaceTimeoutAfter:kFaceTimeout - idle];
        } else if ([device lockForConfiguration:nil]) {
            [self setTarget:FocusTargetCenter point:CGPointMake(0.5, 0.5) device:device];
            [device unlockForConfiguration];
        }
    });
}

/// Counts the frames the camera delivers each second, for the status line.
- (void)startFrameCounter {
    dispatch_async(_videoQueue, ^{
        if (self->_frameTimer) return;
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_videoQueue);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
        __weak CameraController *weakSelf = self;
        dispatch_source_set_event_handler(timer, ^{
            CameraController *strongSelf = weakSelf;
            if (!strongSelf) return;
            int frames = strongSelf->_framesThisSecond;
            strongSelf->_framesThisSecond = 0;
            dispatch_async(dispatch_get_main_queue(), ^{
                strongSelf.frameRate = frames;
                [strongSelf changed];
            });
        });
        dispatch_resume(timer);
        self->_frameTimer = timer;
    });
}

/// Called on _sessionQueue.
- (void)applyOrientation {
    AVCaptureVideoOrientation orientation = _videoOrientation;
    AVCaptureConnection *connection = [_videoOutput connectionWithMediaType:AVMediaTypeVideo];
    if (connection.isVideoOrientationSupported) connection.videoOrientation = orientation;
    dispatch_async(dispatch_get_main_queue(), ^{
        AVCaptureConnection *preview = self.previewLayer.connection;
        if (preview.isVideoOrientationSupported) preview.videoOrientation = orientation;
    });
}

- (void)withDeviceLock:(void (^)(AVCaptureDevice *device))change {
    dispatch_async(_sessionQueue, ^{
        AVCaptureDevice *device = self->_device;
        if (!device || ![device lockForConfiguration:nil]) return;
        change(device);
        [device unlockForConfiguration];
    });
}

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {
    _framesThisSecond += 1;
    // Skip encoding while nobody is watching, to save battery.
    if (!_server.hasClients) return;
    [_encoder encode:sampleBuffer];
}

/// Called on _sessionQueue. Focus and exposure follow the largest face, unless a tap or Lock holds them.
- (void)captureOutput:(AVCaptureOutput *)output
    didOutputMetadataObjects:(NSArray<__kindof AVMetadataObject *> *)metadataObjects
              fromConnection:(AVCaptureConnection *)connection {
    AVCaptureDevice *device = _device;
    if (_target == FocusTargetTap || _deviceLocked || !device) return;
    AVMetadataObject *face = nil;
    for (AVMetadataObject *object in metadataObjects) {
        if (![object.type isEqualToString:AVMetadataObjectTypeFace]) continue;
        if (!face || object.bounds.size.width * object.bounds.size.height > face.bounds.size.width * face.bounds.size.height) {
            face = object;
        }
    }
    if (!face) return;
    _lastFaceTime = [NSProcessInfo processInfo].systemUptime;
    // Face bounds and the point of interest share the sensor's coordinates.
    CGPoint point = CGPointMake(CGRectGetMidX(face.bounds), CGRectGetMidY(face.bounds));
    // Small head movements keep the last point, so focus and exposure stay steady.
    if (_target != FocusTargetFace || hypot(point.x - _facePoint.x, point.y - _facePoint.y) > kFaceMove) {
        _facePoint = point;
        if ([device lockForConfiguration:nil]) {
            [self setTarget:FocusTargetFace point:point device:device];
            [device unlockForConfiguration];
        }
    }
    [self scheduleFaceTimeoutAfter:kFaceTimeout];
}

@end
