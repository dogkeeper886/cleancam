#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

/// Runs the back camera, shows it on the phone, and streams it as H.264 to whoever connects to port 5000,
/// and the microphone as raw PCM to whoever connects to port 5001.
/// Plays the raw PCM a PC sends to port 5002 on the loudspeaker.
@interface CameraController : NSObject

@property (nonatomic, readonly) AVCaptureVideoPreviewLayer *previewLayer;
/// Called on the main queue whenever one of the properties below changes.
@property (nonatomic, copy) void (^onChange)(void);
@property (nonatomic, readonly, copy) NSString *status;
@property (nonatomic, readonly) double zoom;
@property (nonatomic, readonly) double maxZoom;
@property (nonatomic, readonly) BOOL isLocked;
/// False when the microphone is not allowed or missing; the camera streams either way.
@property (nonatomic, readonly) BOOL hasMic;
@property (nonatomic, readonly) BOOL isMicOn;

- (void)start;
- (void)stop;
/// Keeps the preview and the stream upright: portrait or either landscape side.
/// Flat and upside-down positions keep the last orientation.
- (void)updateOrientation:(UIDeviceOrientation)deviceOrientation;
/// Stops drawing the preview while the screen is off; the stream keeps running.
- (void)setPreviewEnabled:(BOOL)enabled;
- (void)setZoom:(double)zoom;
/// Locks focus, exposure and white balance so the picture stops shifting.
- (void)toggleLock;
/// Stops or resumes sending the microphone; the PC's microphone stays and goes silent.
- (void)toggleMic;

@end
