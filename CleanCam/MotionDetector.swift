import CoreMotion

/// Tells a phone that stands still from one that shakes, with the gyro, for auto stabilization. Each second counts as
/// still or shaking by its fastest rotation, and 5 such seconds in a row change the state.
final class MotionDetector {
    enum State: String {
        case unknown, still, shaking
    }

    /// A second whose fastest rotation stays under this, in radians per second, counts as still: about 3° a second.
    private static let stillPeak = 0.05
    /// A second whose fastest rotation passes this counts as shaking: about 9° a second, as in a hand.
    private static let shakingPeak = 0.15
    private static let seconds = 5

    private let manager = CMMotionManager()
    private let updates = OperationQueue()
    // Used on the queue `start` names only.
    private(set) var state = State.unknown
    private var peak = 0.0
    private var run = (state: State.unknown, seconds: 0)

    /// Reads the gyro ten times a second on `queue`.
    func start(on queue: DispatchQueue) {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        if updates.underlyingQueue == nil {
            updates.underlyingQueue = queue
            updates.maxConcurrentOperationCount = 1
        }
        manager.deviceMotionUpdateInterval = 0.1
        manager.startDeviceMotionUpdates(to: updates) { [weak self] motion, _ in
            guard let self, let rate = motion?.rotationRate else { return }
            self.peak = max(self.peak, (rate.x * rate.x + rate.y * rate.y + rate.z * rate.z).squareRoot())
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    /// Called once a second. Returns the fastest rotation since the last call, and whether `state` changed.
    func takeSecond() -> (peak: Double, changed: Bool) {
        let peak = self.peak
        self.peak = 0
        let kind: State = peak < Self.stillPeak ? .still : peak > Self.shakingPeak ? .shaking : .unknown
        run = kind == run.state ? (kind, run.seconds + 1) : (kind, 1)
        guard manager.isDeviceMotionActive, kind != .unknown, run.seconds >= Self.seconds, kind != state else {
            return (peak, false)
        }
        state = kind
        return (peak, true)
    }
}
