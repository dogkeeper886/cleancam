#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

#import "CameraOptions.h"

/// Runs the back camera, shows it on the phone, and streams it as H.264 to whoever connects to port 5000,
/// and the microphone as raw PCM to whoever connects to port 5001.
/// Plays the raw PCM a PC sends to port 5002 on the loudspeaker.
/// Reports its stream to whoever connects to port 5003, one JSON line a second and one per event, and takes
/// commands there.
@interface CameraController : NSObject

@property (nonatomic, readonly) AVCaptureVideoPreviewLayer *previewLayer;
/// Called on the main queue whenever one of the properties below changes.
@property (nonatomic, copy) void (^onChange)(void);
@property (nonatomic, readonly, copy) NSString *status;
@property (nonatomic, readonly) double zoom;
@property (nonatomic, readonly) double maxZoom;
/// The zoom up to which the picture uses real sensor pixels; past it, the camera upscales.
@property (nonatomic, readonly) double losslessZoom;
/// The preset and what the auto settings and the options chose, for the status line, such as
/// "Call · 1080p · 24 fps · 8.0 Mbps · Stab off · Face"; empty until the camera runs.
@property (nonatomic, readonly, copy) NSString *details;
/// The preset and the camera options the user picked.
@property (nonatomic, readonly, copy) CameraOptions *options;
/// What this camera can do, known once it runs; the settings sheet offers only these.
@property (nonatomic, readonly) BOOL canStabilize;
@property (nonatomic, readonly) BOOL canFixWhiteBalance;
@property (nonatomic, readonly) BOOL canFocusNear;
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
/// Focus and exposure follow the tapped point until the next tap or resetFocus, while Lock is off.
/// The point is in the preview layer's coordinates.
- (void)focusAtPreviewPoint:(CGPoint)point;
/// Hands focus and exposure back to faces, or to the center while no face shows.
- (void)resetFocus;
/// Stops or resumes sending the microphone; the PC's microphone stays and goes silent.
- (void)toggleMic;
/// Applies the preset and the camera options, and keeps them for the next start. Called on any queue.
- (void)setOptions:(CameraOptions *)options;

@end
