#import "MotionDetector.h"

#import <CoreMotion/CoreMotion.h>

/// A second whose fastest rotation stays under this, in radians per second, counts as still: about 3° a second.
static const double kStillPeak = 0.05;
/// A second whose fastest rotation passes this counts as shaking: about 9° a second, as in a hand.
static const double kShakingPeak = 0.15;
static const int kSeconds = 5;

NSString *MotionStateName(MotionState state) {
    switch (state) {
        case MotionStateUnknown: return @"unknown";
        case MotionStateStill: return @"still";
        case MotionStateShaking: return @"shaking";
    }
}

@implementation MotionDetector {
    CMMotionManager *_manager;
    NSOperationQueue *_updates;
    // Used on the queue start names only.
    double _peak;
    MotionState _runState;
    int _runSeconds;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _manager = [CMMotionManager new];
    _updates = [NSOperationQueue new];
    _updates.maxConcurrentOperationCount = 1;
    return self;
}

- (void)startOnQueue:(dispatch_queue_t)queue {
    if (!_manager.isDeviceMotionAvailable || _manager.isDeviceMotionActive) return;
    if (!_updates.underlyingQueue) _updates.underlyingQueue = queue;
    _manager.deviceMotionUpdateInterval = 0.1;
    __weak MotionDetector *weakSelf = self;
    [_manager startDeviceMotionUpdatesToQueue:_updates withHandler:^(CMDeviceMotion *motion, NSError *error) {
        MotionDetector *strongSelf = weakSelf;
        if (!strongSelf || !motion) return;
        CMRotationRate rate = motion.rotationRate;
        strongSelf->_peak = MAX(strongSelf->_peak, sqrt(rate.x * rate.x + rate.y * rate.y + rate.z * rate.z));
    }];
}

- (void)stop {
    [_manager stopDeviceMotionUpdates];
}

- (double)takeSecond:(BOOL *)changed {
    double peak = _peak;
    _peak = 0;
    MotionState kind = peak < kStillPeak ? MotionStateStill : peak > kShakingPeak ? MotionStateShaking : MotionStateUnknown;
    _runSeconds = kind == _runState ? _runSeconds + 1 : 1;
    _runState = kind;
    *changed = _manager.isDeviceMotionActive && kind != MotionStateUnknown && _runSeconds >= kSeconds && kind != _state;
    if (*changed) _state = kind;
    return peak;
}

@end
