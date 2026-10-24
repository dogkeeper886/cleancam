#import "ViewController.h"

#import "CameraController.h"

@implementation ViewController {
    CameraController *_camera;
    UILabel *_statusLabel;
    UIStackView *_zoomRow;
    UISlider *_zoomSlider;
    UILabel *_zoomLabel;
    UIButton *_lockButton;
    UIButton *_muteButton;
    UIView *_screenOffView;
    UILabel *_screenOffLabel;
    CGFloat _savedBrightness;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    _savedBrightness = 0.5;
    _camera = [CameraController new];
    [self.view.layer addSublayer:_camera.previewLayer];

    UIFont *font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    _statusLabel = [self labelWithFont:font];
    _zoomSlider = [UISlider new];
    _zoomSlider.minimumValue = 1;
    [_zoomSlider addTarget:self action:@selector(zoomChanged) forControlEvents:UIControlEventValueChanged];
    [_zoomSlider.widthAnchor constraintEqualToConstant:200].active = YES;
    _zoomLabel = [self labelWithFont:font];
    [_zoomLabel.widthAnchor constraintEqualToConstant:44].active = YES;
    _zoomRow = [[UIStackView alloc] initWithArrangedSubviews:@[_zoomSlider, _zoomLabel]];
    _zoomRow.spacing = 12;
    _zoomRow.alignment = UIStackViewAlignmentCenter;
    _lockButton = [self buttonWithTitle:@"Lock" action:@selector(toggleLock)];
    _muteButton = [self buttonWithTitle:@"Mute" action:@selector(toggleMic)];
    UIButton *screenOffButton = [self buttonWithTitle:@"Screen off" action:@selector(turnScreenOff)];
    // The buttons get their own row so all three fit an upright phone.
    UIStackView *buttonRow = [[UIStackView alloc] initWithArrangedSubviews:@[_lockButton, _muteButton, screenOffButton]];
    buttonRow.spacing = 12;

    UIStackView *controls = [[UIStackView alloc] initWithArrangedSubviews:@[_statusLabel, _zoomRow, buttonRow]];
    controls.axis = UILayoutConstraintAxisVertical;
    controls.alignment = UIStackViewAlignmentLeading;
    controls.spacing = 8;
    controls.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *panel = [UIView new];
    panel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    panel.layer.cornerRadius = 12;
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    [panel addSubview:controls];
    [self.view addSubview:panel];
    [NSLayoutConstraint activateConstraints:@[
        [controls.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:12],
        [controls.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-12],
        [controls.topAnchor constraintEqualToAnchor:panel.topAnchor constant:12],
        [controls.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-12],
        [panel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [panel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-16],
        [panel.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-16],
    ]];

    // iOS stops the camera when the screen really turns off, so "off" is a black screen at the lowest brightness.
    _screenOffView = [[UIView alloc] initWithFrame:self.view.bounds];
    _screenOffView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _screenOffView.backgroundColor = [UIColor blackColor];
    _screenOffView.hidden = YES;
    _screenOffLabel = [self labelWithFont:font];
    _screenOffLabel.frame = _screenOffView.bounds;
    _screenOffLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _screenOffLabel.textAlignment = NSTextAlignmentCenter;
    _screenOffLabel.textColor = [UIColor grayColor];
    [_screenOffView addSubview:_screenOffLabel];
    [_screenOffView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(turnScreenOn)]];
    [self.view addSubview:_screenOffView];

    __weak ViewController *weakSelf = self;
    _camera.onChange = ^{ [weakSelf refresh]; };
    [self refresh];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(didBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:self selector:@selector(willResignActive) name:UIApplicationWillResignActiveNotification object:nil];
    [center addObserver:self selector:@selector(didEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [center addObserver:self selector:@selector(orientationChanged) name:UIDeviceOrientationDidChangeNotification object:nil];
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _camera.previewLayer.frame = self.view.bounds;
    [CATransaction commit];
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

- (void)refresh {
    _statusLabel.text = _camera.status;
    _screenOffLabel.text = [NSString stringWithFormat:@"%@ · Tap to turn the screen on", _camera.status];
    _zoomRow.hidden = _camera.maxZoom <= 1;
    _zoomSlider.maximumValue = _camera.maxZoom;
    if (!_zoomSlider.isTracking) _zoomSlider.value = _camera.zoom;
    _zoomLabel.text = [NSString stringWithFormat:@"%.1fx", _camera.zoom];
    [_lockButton setTitle:_camera.isLocked ? @"Unlock" : @"Lock" forState:UIControlStateNormal];
    _lockButton.backgroundColor = _camera.isLocked ? [UIColor orangeColor] : [UIColor grayColor];
    _muteButton.hidden = !_camera.hasMic;
    [_muteButton setTitle:_camera.isMicOn ? @"Mute" : @"Unmute" forState:UIControlStateNormal];
    _muteButton.backgroundColor = _camera.isMicOn ? [UIColor grayColor] : [UIColor redColor];
}

- (void)zoomChanged {
    [_camera setZoom:_zoomSlider.value];
}

- (void)toggleLock {
    [_camera toggleLock];
}

- (void)toggleMic {
    [_camera toggleMic];
}

- (void)turnScreenOff {
    [self setScreenOff:YES];
}

- (void)turnScreenOn {
    [self setScreenOff:NO];
}

- (void)setScreenOff:(BOOL)off {
    if (off == !_screenOffView.hidden) return;
    if (off) {
        _savedBrightness = [UIScreen mainScreen].brightness;
        [UIScreen mainScreen].brightness = 0;
    } else {
        [UIScreen mainScreen].brightness = _savedBrightness;
    }
    _screenOffView.hidden = !off;
    [_camera setPreviewEnabled:!off];
}

- (void)didBecomeActive {
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    [_camera updateOrientation:[UIDevice currentDevice].orientation];
    [_camera start];
}

- (void)willResignActive {
    // Give the screen its brightness back before leaving the app.
    [self setScreenOff:NO];
}

- (void)didEnterBackground {
    [UIApplication sharedApplication].idleTimerDisabled = NO;
    [_camera stop];
}

- (void)orientationChanged {
    [_camera updateOrientation:[UIDevice currentDevice].orientation];
}

- (UILabel *)labelWithFont:(UIFont *)font {
    UILabel *label = [UILabel new];
    label.font = font;
    label.textColor = [UIColor whiteColor];
    return label;
}

- (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [button setTitleColor:[UIColor colorWithWhite:1 alpha:0.5] forState:UIControlStateHighlighted];
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    button.contentEdgeInsets = UIEdgeInsetsMake(6, 12, 6, 12);
    button.backgroundColor = [UIColor grayColor];
    button.layer.cornerRadius = 8;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

@end
