#import "CameraController.h"

#import "CallAudio.h"
#import "H264Encoder.h"
#import "MotionDetector.h"
#import "StreamServer.h"

static const uint16_t kPort = 5000;
static const uint16_t kAudioPort = 5001;
static const uint16_t kSpeakerPort = 5002;
static const uint16_t kDebugPort = 5003;
/// The highest bitrate the debug port's bitrate command holds: far above what the encoder sends, and low enough that
/// the encoder's rate math can't overflow an int.
static const int kMaxPinnedBitRate = 100000000;
/// Auto exposure holds the top rate and slows toward the preset's bottom one in the dark, for more light per frame.
static const int kTopFrameRate = 30;
/// Auto stabilization changes the camera at most once in this many seconds, since each change can glitch the picture.
static const double kAutoChangeInterval = 60;
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

/// The active mode's frame rate range that reaches highest.
static AVFrameRateRange *TopRange(AVCaptureDevice *device) {
    AVFrameRateRange *range = nil;
    for (AVFrameRateRange *candidate in device.activeFormat.videoSupportedFrameRateRanges) {
        if (!range || candidate.maxFrameRate > range.maxFrameRate) range = candidate;
    }
    return range;
}

/// Called with the device locked. Auto exposure holds the top rate and slows toward the preset's bottom one in the
/// dark.
static void ApplyFrameRates(AVCaptureDevice *device, NSString *preset) {
    AVFrameRateRange *range = TopRange(device);
    if (!range) return;
    device.activeVideoMinFrameDuration = FrameDuration(kTopFrameRate, range);
    device.activeVideoMaxFrameDuration = FrameDuration([CameraOptions bottomFrameRateOfPreset:preset], range);
}

/// The frames per second of a frame duration, such as 30 for 1/30 s.
static int FrameRateOf(CMTime duration) {
    double seconds = CMTimeGetSeconds(duration);
    return seconds > 0 ? (int)lround(1 / seconds) : 0;
}

/// The debug port's name for a stabilization mode.
static NSString *StabilizationModeName(AVCaptureVideoStabilizationMode mode) {
    switch (mode) {
        case AVCaptureVideoStabilizationModeOff: return @"off";
        case AVCaptureVideoStabilizationModeStandard: return @"standard";
        case AVCaptureVideoStabilizationModeCinematic: return @"cinematic";
        case AVCaptureVideoStabilizationModeAuto: return @"auto";
        default: return @"other";
    }
}

/// Reads the whole of text as a number, so "1x" or an empty word is no number.
static BOOL ParseFloat(NSString *text, float *value) {
    NSScanner *scanner = [NSScanner scannerWithString:text];
    return [scanner scanFloat:value] && scanner.isAtEnd;
}

static BOOL ParseInt(NSString *text, int *value) {
    NSScanner *scanner = [NSScanner scannerWithString:text];
    return [scanner scanInt:value] && scanner.isAtEnd;
}

@interface CameraController () <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureMetadataOutputObjectsDelegate>
@property (nonatomic, readwrite, copy) NSString *status;
@property (nonatomic, readwrite) double zoom;
@property (nonatomic, readwrite) double maxZoom;
@property (nonatomic, readwrite) double losslessZoom;
@property (nonatomic, readwrite) BOOL isLocked;
@property (nonatomic, readwrite) BOOL hasMic;
@property (nonatomic, readwrite) BOOL isMicOn;
@property (nonatomic, readwrite) BOOL canStabilize;
@property (nonatomic, readwrite) BOOL canFixWhiteBalance;
@property (nonatomic, readwrite) BOOL canFocusNear;
/// The status line's name for the stabilization, such as "Stab off", or nil on a camera without it.
@property (nonatomic, copy) NSString *stabilizationName;
/// The camera mode's size, such as "1080p", once the camera runs.
@property (nonatomic, copy) NSString *formatName;
/// The frames the camera delivered in the last second.
@property (nonatomic) int frameRate;
/// The bitrate the encoder aims for, after it adapted to the link.
@property (nonatomic) int bitRate;
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
    StreamServer *_debugServer;
    // Used on the debug server's queue only.
    NSMutableData *_debugInput;
    // Used on _sessionQueue only.
    AVCaptureDevice *_device;
    AVCaptureVideoOrientation _videoOrientation;
    BOOL _deviceLocked;
    FocusTarget _target;
    CGPoint _facePoint;
    double _lastFaceTime;
    BOOL _faceTimeoutScheduled;
    CameraOptions *_activeOptions;
    MotionState _motion;
    double _stabilizationChangedAt;
    BOOL _stabilizationCheckScheduled;
    // Used on _videoQueue only.
    int _framesThisSecond;
    dispatch_source_t _frameTimer;
    MotionDetector *_motionDetector;
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
    _debugServer = [[StreamServer alloc] initWithPort:kDebugPort];
    _debugInput = [NSMutableData data];
    _videoOrientation = AVCaptureVideoOrientationLandscapeRight;
    _facePoint = CGPointMake(0.5, 0.5);
    _options = [CameraOptions saved];
    _activeOptions = [_options copy];
    _stabilizationChangedAt = -INFINITY;
    _motionDetector = [MotionDetector new];
    [_encoder setMaxBitRate:_options.maxBitRate];

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
        [weakSelf sendDebug:@{@"event": @"viewers", @"port": @(kPort), @"count": @(count)}];
        dispatch_async(dispatch_get_main_queue(), ^{
            CameraController *strongSelf = weakSelf;
            strongSelf.status = count > 0
                ? @"Streaming to PC"
                : [NSString stringWithFormat:@"Waiting for PC on port %u", kPort];
            [strongSelf changed];
        });
    };
    _audioServer.onClientsChanged = ^(NSUInteger count) {
        [weakSelf sendDebug:@{@"event": @"viewers", @"port": @(kAudioPort), @"count": @(count)}];
    };
    _speakerServer.onClientsChanged = ^(NSUInteger count) {
        [weakSelf sendDebug:@{@"event": @"viewers", @"port": @(kSpeakerPort), @"count": @(count)}];
    };
    _encoder.onEvent = ^(NSDictionary *event) {
        [weakSelf sendDebug:event];
    };
    _debugServer.onReceive = ^(NSData *data) {
        [weakSelf receiveDebug:data];
    };
    dispatch_queue_t sessionQueue = _sessionQueue;
    _debugServer.onClientsChanged = ^(NSUInteger count) {
        if (count == 0) return;
        // A new client learns the camera's state without waiting for a change.
        dispatch_async(sessionQueue, ^{
            [weakSelf reportMode];
            [weakSelf reportCamera:@"client"];
        });
    };
    return self;
}

- (NSString *)details {
    if (!self.formatName) return @"";
    CameraOptions *options = self.options;
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObjects:
        [CameraOptions nameOfPreset:options.preset], self.formatName,
        [NSString stringWithFormat:@"%d fps", self.frameRate], [NSString stringWithFormat:@"%.1f Mbps", self.bitRate / 1e6], nil];
    if (self.stabilizationName) [parts addObject:self.stabilizationName];
    if (options.exposureBias != 0) [parts addObject:[NSString stringWithFormat:@"EV %+.1f", options.exposureBias]];
    if (options.whiteBalance && self.canFixWhiteBalance) {
        [parts addObject:[NSString stringWithFormat:@"%d K", options.whiteBalance]];
    }
    if (options.nearFocus && self.canFocusNear) [parts addObject:@"Near"];
    [parts addObject:FocusTargetName(self.focusTarget)];
    return [parts componentsJoinedByString:@" · "];
}

- (void)start {
    [_server start];
    [_audioServer start];
    [_speakerServer start];
    [_debugServer start];
    [self startFrameCounter];
    MotionDetector *motionDetector = _motionDetector;
    dispatch_queue_t videoQueue = _videoQueue;
    dispatch_async(_videoQueue, ^{ [motionDetector startOnQueue:videoQueue]; });
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
            [self withDeviceLock:^(AVCaptureDevice *device) { ApplyFrameRates(device, self->_activeOptions.preset); }];
        }];
    }];
}

- (void)stop {
    [_server stop];
    [_audioServer stop];
    [_speakerServer stop];
    [_debugServer stop];
    [_callAudio stop];
    dispatch_async(_sessionQueue, ^{ [self->_session stopRunning]; });
    dispatch_async(_videoQueue, ^{
        if (self->_frameTimer) {
            dispatch_source_cancel(self->_frameTimer);
            self->_frameTimer = nil;
        }
        [self->_motionDetector stop];
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
        if ([device isFocusModeSupported:focus]) device.focusMode = focus;
        if ([device isExposureModeSupported:exposure]) device.exposureMode = exposure;
        [self applyWhiteBalanceTo:device];
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

- (void)setOptions:(CameraOptions *)options {
    CameraOptions *copy = [options copy];
    [self keepOptions:copy];
    dispatch_async(_sessionQueue, ^{ [self activateOptions:copy]; });
}

/// Changes the options from the debug port, as the settings sheet does. Each change takes effect before the next
/// command's, so commands sent together all apply.
- (void)changeOptions:(void (^)(CameraOptions *options))change {
    dispatch_async(_sessionQueue, ^{
        CameraOptions *options = [self->_activeOptions copy];
        change(options);
        [self keepOptions:options];
        [self activateOptions:options];
    });
}

/// Saves the options for the next start and hands them to the main queue's readers. Called on any queue.
- (void)keepOptions:(CameraOptions *)options {
    [options save];
    // The settings sheet's sliders read the options back as they move. setOptions: is the options property's
    // setter, so this sets the variable itself.
    if ([NSThread isMainThread]) {
        _options = options;
        [self changed];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_options = options;
            [self changed];
        });
    }
}

/// Called on _sessionQueue. Applies the options to the camera and the encoder.
- (void)activateOptions:(CameraOptions *)options {
    BOOL newPreset = ![options.preset isEqualToString:_activeOptions.preset];
    _activeOptions = options;
    AVCaptureDevice *device = _device;
    if (device && [device lockForConfiguration:nil]) {
        if (newPreset) ApplyFrameRates(device, options.preset);
        [self applyOptionsTo:device];
        [device unlockForConfiguration];
    }
    if ([self applyStabilization]) _stabilizationChangedAt = [NSProcessInfo processInfo].systemUptime;
    H264Encoder *encoder = _encoder;
    int maxBitRate = options.maxBitRate;
    dispatch_async(_videoQueue, ^{ [encoder setMaxBitRate:maxBitRate]; });
    if (newPreset) [self reportMode];
    [self reportCamera:@"options"];
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
        ApplyFrameRates(device, _activeOptions.preset);
        if (device.isSmoothAutoFocusSupported) device.smoothAutoFocusEnabled = YES;
        if (device.isLowLightBoostSupported) device.automaticallyEnablesLowLightBoostWhenAvailable = YES;
        [self applyOptionsTo:device];
        [device unlockForConfiguration];
    }
    [_session commitConfiguration];
    _device = device;
    [self applyOrientation];
    AVCaptureConnection *connection = [_videoOutput connectionWithMediaType:AVMediaTypeVideo];
    BOOL canStabilize = connection.isVideoStabilizationSupported &&
        [device.activeFormat isVideoStabilizationModeSupported:AVCaptureVideoStabilizationModeStandard];
    BOOL canFixWhiteBalance = device.isLockingWhiteBalanceWithCustomDeviceGainsSupported;
    BOOL canFocusNear = device.isAutoFocusRangeRestrictionSupported;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.canStabilize = canStabilize;
        self.canFixWhiteBalance = canFixWhiteBalance;
        self.canFocusNear = canFocusNear;
        [self changed];
    });
    [self applyStabilization];
    // The encoder plans its bitrate and keyframes around the mode's top rate.
    double frameDuration = CMTimeGetSeconds(device.activeVideoMinFrameDuration);
    if (frameDuration > 0) {
        int topRate = (int)lround(1 / frameDuration);
        H264Encoder *encoder = _encoder;
        dispatch_async(_videoQueue, ^{ [encoder setFrameRate:topRate]; });
    }

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

/// Called on _sessionQueue with the device locked. Sets the exposure compensation, the white balance and the focus
/// range the user picked.
- (void)applyOptionsTo:(AVCaptureDevice *)device {
    float bias = MIN(MAX(_activeOptions.exposureBias, device.minExposureTargetBias), device.maxExposureTargetBias);
    [device setExposureTargetBias:bias completionHandler:nil];
    if (device.isAutoFocusRangeRestrictionSupported) {
        device.autoFocusRangeRestriction = _activeOptions.nearFocus
            ? AVCaptureAutoFocusRangeRestrictionNear : AVCaptureAutoFocusRangeRestrictionNone;
    }
    [self applyWhiteBalanceTo:device];
}

/// Called on _sessionQueue with the device locked. A fixed white balance holds the user's temperature; otherwise
/// iOS's auto white balance runs, or holds while Lock is on.
- (void)applyWhiteBalanceTo:(AVCaptureDevice *)device {
    int kelvins = _activeOptions.whiteBalance;
    if (kelvins && device.isLockingWhiteBalanceWithCustomDeviceGainsSupported) {
        AVCaptureWhiteBalanceTemperatureAndTintValues values = {.temperature = kelvins, .tint = 0};
        AVCaptureWhiteBalanceGains gains = [device deviceWhiteBalanceGainsForTemperatureAndTintValues:values];
        // The camera takes only gains from 1 to its maximum.
        float maxGain = device.maxWhiteBalanceGain;
        gains.redGain = MIN(MAX(gains.redGain, 1), maxGain);
        gains.greenGain = MIN(MAX(gains.greenGain, 1), maxGain);
        gains.blueGain = MIN(MAX(gains.blueGain, 1), maxGain);
        [device setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains:gains completionHandler:nil];
        return;
    }
    AVCaptureWhiteBalanceMode mode = _deviceLocked
        ? AVCaptureWhiteBalanceModeLocked : AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance;
    if ([device isWhiteBalanceModeSupported:mode]) device.whiteBalanceMode = mode;
}

/// Called on _sessionQueue. Sets the stabilization the user picked or, in Auto, the one the motion calls for: off
/// while the phone stands still, and on while it shakes. Returns whether the stabilization changed.
- (BOOL)applyStabilization {
    AVCaptureDevice *device = _device;
    AVCaptureConnection *connection = [_videoOutput connectionWithMediaType:AVMediaTypeVideo];
    if (!device || !connection.isVideoStabilizationSupported ||
        ![device.activeFormat isVideoStabilizationModeSupported:AVCaptureVideoStabilizationModeStandard]) {
        return NO;
    }
    NSString *asked = _activeOptions.stabilization;
    BOOL on = [asked isEqualToString:@"standard"] || ([asked isEqualToString:@"auto"] && _motion == MotionStateShaking);
    dispatch_async(dispatch_get_main_queue(), ^{
        self.stabilizationName = on ? @"Stab on" : @"Stab off";
        [self changed];
    });
    AVCaptureVideoStabilizationMode mode = on ? AVCaptureVideoStabilizationModeStandard : AVCaptureVideoStabilizationModeOff;
    if (mode == connection.preferredVideoStabilizationMode) return NO;
    connection.preferredVideoStabilizationMode = mode;
    return YES;
}

/// Called on _sessionQueue when the phone started to shake or has stood still for a while.
- (void)motionChanged:(MotionState)state {
    _motion = state;
    [self applyAutoStabilization];
}

/// Called on _sessionQueue. Auto stabilization follows the motion, at most once in kAutoChangeInterval.
- (void)applyAutoStabilization {
    if (![_activeOptions.stabilization isEqualToString:@"auto"]) return;
    double wait = _stabilizationChangedAt + kAutoChangeInterval - [NSProcessInfo processInfo].systemUptime;
    if (wait > 0) {
        if (_stabilizationCheckScheduled) return;
        _stabilizationCheckScheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), _sessionQueue, ^{
            self->_stabilizationCheckScheduled = NO;
            [self applyAutoStabilization];
        });
        return;
    }
    if (![self applyStabilization]) return;
    _stabilizationChangedAt = [NSProcessInfo processInfo].systemUptime;
    [self reportCamera:@"motion"];
}

/// Called on _sessionQueue. Tells the debug port the preset, the camera mode, the frame rates auto exposure moves
/// between, and the lowest and highest rates the mode allows.
- (void)reportMode {
    AVCaptureDevice *device = _device;
    if (!device) return;
    CMVideoDimensions size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription);
    AVFrameRateRange *range = TopRange(device);
    [self sendDebug:@{
        @"event": @"mode", @"preset": _activeOptions.preset, @"width": @(size.width), @"height": @(size.height),
        @"fps": @[@(FrameRateOf(device.activeVideoMaxFrameDuration)), @(FrameRateOf(device.activeVideoMinFrameDuration))],
        @"modeFps": @[@(range.minFrameRate), @(range.maxFrameRate)],
    }];
}

/// Called on _sessionQueue. Tells the debug port the camera options, what the camera took of them, and what it
/// supports.
- (void)reportCamera:(NSString *)reason {
    AVCaptureDevice *device = _device;
    if (!device) return;
    AVCaptureConnection *connection = [_videoOutput connectionWithMediaType:AVMediaTypeVideo];
    CameraOptions *options = _activeOptions;
    // The conversion throws on gains outside 1 to the maximum, as before the camera's first frames.
    AVCaptureWhiteBalanceGains gains = device.deviceWhiteBalanceGains;
    float maxGain = device.maxWhiteBalanceGain;
    BOOL validGains = gains.redGain >= 1 && gains.greenGain >= 1 && gains.blueGain >= 1 && gains.redGain <= maxGain &&
        gains.greenGain <= maxGain && gains.blueGain <= maxGain;
    float kelvins = validGains ? [device temperatureAndTintValuesForDeviceWhiteBalanceGains:gains].temperature : 0;
    BOOL canStabilize = connection.isVideoStabilizationSupported &&
        [device.activeFormat isVideoStabilizationModeSupported:AVCaptureVideoStabilizationModeStandard];
    [self sendDebug:@{
        @"event": @"camera", @"reason": reason,
        @"stabilization": @{
            @"asked": options.stabilization, @"motion": MotionStateName(_motion), @"supported": @(canStabilize),
            @"preferred": StabilizationModeName(connection.preferredVideoStabilizationMode),
            @"active": StabilizationModeName(connection.activeVideoStabilizationMode),
        },
        @"exposureBias": @{
            @"asked": @(options.exposureBias), @"took": @(device.exposureTargetBias),
            @"range": @[@(device.minExposureTargetBias), @(device.maxExposureTargetBias)],
        },
        @"whiteBalance": @{
            @"asked": options.whiteBalance ? @(options.whiteBalance) : @"auto",
            @"mode": device.whiteBalanceMode == AVCaptureWhiteBalanceModeLocked ? @"locked" : @"auto",
            @"kelvins": @(lroundf(kelvins)), @"fixable": @(device.isLockingWhiteBalanceWithCustomDeviceGainsSupported),
        },
        @"nearFocus": @{
            @"asked": @(options.nearFocus), @"supported": @(device.isAutoFocusRangeRestrictionSupported),
            @"took": @((BOOL)(device.autoFocusRangeRestriction == AVCaptureAutoFocusRangeRestrictionNear)),
        },
        @"maxBitRate": options.maxBitRate ? @(options.maxBitRate) : [NSNull null],
    }];
}

/// Counts the frames the camera delivers each second, for the status line and the debug port, adapts the encoder's
/// bitrate to how far the PC fell behind in that second, and tells auto stabilization how the phone moved.
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
            int backlog = [strongSelf->_server takePeakBacklog];
            H264Encoder *encoder = strongSelf->_encoder;
            [encoder adaptToBacklog:backlog];
            int bitRate = encoder.bitRate;
            BOOL motionChanged = NO;
            double rotation = [strongSelf->_motionDetector takeSecond:&motionChanged];
            if (motionChanged) {
                MotionState state = strongSelf->_motionDetector.state;
                dispatch_async(strongSelf->_sessionQueue, ^{ [strongSelf motionChanged:state]; });
            }
            NSMutableDictionary *second = [[encoder takeOutput] mutableCopy];
            [second addEntriesFromDictionary:@{
                @"event": @"second", @"fps": @(frames), @"topFps": @(encoder.topFrameRate), @"target": @(bitRate),
                @"pinned": @(encoder.isPinned), @"backlog": @(backlog), @"rotation": @(round(rotation * 1000) / 1000),
                @"viewers": @{
                    @"video": @(strongSelf->_server.connectionCount), @"mic": @(strongSelf->_audioServer.connectionCount),
                    @"speaker": @(strongSelf->_speakerServer.connectionCount),
                },
            }];
            [strongSelf sendDebug:second];
            dispatch_async(dispatch_get_main_queue(), ^{
                strongSelf.frameRate = frames;
                strongSelf.bitRate = bitRate;
                [strongSelf changed];
            });
        });
        dispatch_resume(timer);
        self->_frameTimer = timer;
    });
}

/// Sends one JSON line, stamped with the phone's uptime, to every client of the debug port. Called on any queue.
- (void)sendDebug:(NSDictionary *)event {
    if (!_debugServer.hasClients) return;
    NSMutableDictionary *line = [event mutableCopy];
    line[@"t"] = @(round([NSProcessInfo processInfo].systemUptime * 1000) / 1000);
    if (![NSJSONSerialization isValidJSONObject:line]) return;
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:line options:0 error:nil] mutableCopy];
    if (!data) return;
    [data appendBytes:"\n" length:1];
    [_debugServer broadcast:data isKeyframe:YES];
}

/// Called on the debug server's queue with what a debug client typed: one command per line.
- (void)receiveDebug:(NSData *)data {
    [_debugInput appendData:data];
    NSData *newlineData = [NSData dataWithBytes:"\n" length:1];
    while (YES) {
        NSRange newline = [_debugInput rangeOfData:newlineData options:0 range:NSMakeRange(0, _debugInput.length)];
        if (newline.location == NSNotFound) break;
        NSString *line = [[NSString alloc] initWithData:[_debugInput subdataWithRange:NSMakeRange(0, newline.location)]
                                               encoding:NSUTF8StringEncoding];
        [_debugInput replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];
        line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (line.length) [self runDebugCommand:line];
    }
    // A client that never ends a line can't grow the buffer without bound.
    if (_debugInput.length > 1024) _debugInput.length = 0;
}

/// Runs a debug command: "bitrate N" holds the bitrate at N bits per second, "auto" hands it back to adaptation,
/// and "keyframe" asks for a keyframe. "preset", "stab", "ev", "wb", "near" and "maxbitrate" set the preset or a
/// camera option as the settings sheet does, and "camera" reports the camera options.
- (void)runDebugCommand:(NSString *)line {
    NSArray<NSString *> *words = [[line componentsSeparatedByString:@" "]
        filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    NSString *command = words.firstObject;
    NSString *value = words.count == 2 ? words[1] : @"";
    float number = 0;
    int integer = 0;
    H264Encoder *encoder = _encoder;
    BOOL ok = YES;
    if (words.count == 2 && [words[0] isEqualToString:@"bitrate"] && words[1].intValue > 0 &&
        words[1].intValue <= kMaxPinnedBitRate) {
        int bitRate = words[1].intValue;
        dispatch_async(_videoQueue, ^{ [encoder pinBitRate:bitRate]; });
    } else if (words.count == 1 && [words[0] isEqualToString:@"auto"]) {
        dispatch_async(_videoQueue, ^{ [encoder unpin]; });
    } else if (words.count == 1 && [words[0] isEqualToString:@"keyframe"]) {
        [encoder requestKeyframe];
    } else if ([command isEqualToString:@"preset"] && [[CameraOptions presets] containsObject:value]) {
        [self changeOptions:^(CameraOptions *options) { options.preset = value; }];
    } else if ([command isEqualToString:@"stab"] && [[CameraOptions stabilizations] containsObject:value]) {
        [self changeOptions:^(CameraOptions *options) { options.stabilization = value; }];
    } else if ([command isEqualToString:@"ev"] && ParseFloat(value, &number) && fabsf(number) <= kExposureBiasLimit) {
        [self changeOptions:^(CameraOptions *options) { options.exposureBias = number; }];
    } else if ([command isEqualToString:@"wb"] && ([value isEqualToString:@"auto"] ||
               (ParseInt(value, &integer) && integer >= kMinWhiteBalance && integer <= kMaxWhiteBalance))) {
        [self changeOptions:^(CameraOptions *options) { options.whiteBalance = integer; }];
    } else if ([command isEqualToString:@"near"] && ([value isEqualToString:@"on"] || [value isEqualToString:@"off"])) {
        BOOL near = [value isEqualToString:@"on"];
        [self changeOptions:^(CameraOptions *options) { options.nearFocus = near; }];
    } else if ([command isEqualToString:@"maxbitrate"] && ([value isEqualToString:@"off"] ||
               (ParseInt(value, &integer) && integer > 0 && integer <= kMaxPinnedBitRate))) {
        [self changeOptions:^(CameraOptions *options) { options.maxBitRate = integer; }];
    } else if (words.count == 1 && [command isEqualToString:@"camera"]) {
        dispatch_async(_sessionQueue, ^{ [self reportCamera:@"command"]; });
    } else {
        ok = NO;
    }
    [self sendDebug:@{@"event": @"command", @"command": line, @"ok": @(ok)}];
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
