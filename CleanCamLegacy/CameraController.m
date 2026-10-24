#import "CameraController.h"

#import "CallAudio.h"
#import "H264Encoder.h"
#import "StreamServer.h"

static const uint16_t kPort = 5000;
static const uint16_t kAudioPort = 5001;
static const uint16_t kSpeakerPort = 5002;

@interface CameraController () <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, readwrite, copy) NSString *status;
@property (nonatomic, readwrite) double zoom;
@property (nonatomic, readwrite) double maxZoom;
@property (nonatomic, readwrite) BOOL isLocked;
@property (nonatomic, readwrite) BOOL hasMic;
@property (nonatomic, readwrite) BOOL isMicOn;
@end

@implementation CameraController {
    AVCaptureSession *_session;
    AVCaptureVideoDataOutput *_videoOutput;
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
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _status = @"Starting…";
    _zoom = 1;
    _maxZoom = 1;
    _isMicOn = YES;
    _session = [AVCaptureSession new];
    _previewLayer = [AVCaptureVideoPreviewLayer new];
    _previewLayer.session = _session;
    _previewLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    _videoOutput = [AVCaptureVideoDataOutput new];
    _sessionQueue = dispatch_queue_create("cleancam.session", DISPATCH_QUEUE_SERIAL);
    _videoQueue = dispatch_queue_create("cleancam.video", DISPATCH_QUEUE_SERIAL);
    _encoder = [H264Encoder new];
    _callAudio = [CallAudio new];
    _server = [[StreamServer alloc] initWithPort:kPort];
    _audioServer = [[StreamServer alloc] initWithPort:kAudioPort];
    _speakerServer = [[StreamServer alloc] initWithPort:kSpeakerPort];
    _videoOrientation = AVCaptureVideoOrientationLandscapeRight;

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

- (void)start {
    [_server start];
    [_audioServer start];
    [_speakerServer start];
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
        }];
    }];
}

- (void)stop {
    [_server stop];
    [_audioServer stop];
    [_speakerServer stop];
    [_callAudio stop];
    dispatch_async(_sessionQueue, ^{ [self->_session stopRunning]; });
    dispatch_async(_videoQueue, ^{ [self->_encoder reset]; });
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
        AVCaptureFocusMode focus = lock ? AVCaptureFocusModeLocked : AVCaptureFocusModeContinuousAutoFocus;
        AVCaptureExposureMode exposure = lock ? AVCaptureExposureModeLocked : AVCaptureExposureModeContinuousAutoExposure;
        AVCaptureWhiteBalanceMode whiteBalance = lock
            ? AVCaptureWhiteBalanceModeLocked : AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance;
        if ([device isFocusModeSupported:focus]) device.focusMode = focus;
        if ([device isExposureModeSupported:exposure]) device.exposureMode = exposure;
        if ([device isWhiteBalanceModeSupported:whiteBalance]) device.whiteBalanceMode = whiteBalance;
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
    [_session commitConfiguration];
    _device = device;
    [self applyOrientation];

    double maxZoom = MIN(device.activeFormat.videoMaxZoomFactor, 10);
    dispatch_async(dispatch_get_main_queue(), ^{
        self.maxZoom = maxZoom;
        [self changed];
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
    // Skip encoding while nobody is watching, to save battery.
    if (!_server.hasClients) return;
    [_encoder encode:sampleBuffer];
}

@end
