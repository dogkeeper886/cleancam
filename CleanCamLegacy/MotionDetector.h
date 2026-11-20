#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, MotionState) {
    MotionStateUnknown,
    MotionStateStill,
    MotionStateShaking,
};

/// The debug port's name for a motion state: "unknown", "still" or "shaking".
NSString *MotionStateName(MotionState state);

/// Tells a phone that stands still from one that shakes, with the gyro, for auto stabilization. Each second counts as
/// still or shaking by its fastest rotation, and 5 such seconds in a row change the state.
@interface MotionDetector : NSObject

/// Read on the queue start names only.
@property (nonatomic, readonly) MotionState state;

/// Reads the gyro ten times a second on queue.
- (void)startOnQueue:(dispatch_queue_t)queue;
- (void)stop;
/// Called once a second on start's queue. Returns the fastest rotation since the last call, in radians per second,
/// and sets changed to whether state changed.
- (double)takeSecond:(BOOL *)changed;

@end
