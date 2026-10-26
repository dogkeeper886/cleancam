import AVFoundation
import Combine
import UIKit

/// Runs the back camera, shows it on the phone, and streams it as H.264 to whoever connects to `port`,
/// and the microphone as raw PCM to whoever connects to `audioPort`.
/// Plays the raw PCM a PC sends to `speakerPort` on the loudspeaker.
final class CameraController: NSObject, ObservableObject {
    static let port: UInt16 = 5000
    static let audioPort: UInt16 = 5001
    static let speakerPort: UInt16 = 5002
    /// Auto exposure holds the top rate and slows toward the bottom one in the dark, for more light per frame.
    static let frameRates = 20...30
    /// How long focus stays on a face that left the picture before it returns to the center, in seconds.
    private static let faceTimeout = 2.0
    /// How far a face moves, in the sensor's 0–1 coordinates, before focus and exposure follow it.
    private static let faceMove: CGFloat = 0.1

    /// What focus and exposure follow: a tap holds until the next tap or a reset, then faces, then the center.
    enum FocusTarget: String {
        case center = "Center", face = "Face", tap = "Tap"
    }

    @Published private(set) var status = "Starting…"
    @Published private(set) var zoom = 1.0
    @Published private(set) var zoomRange = 1.0...1.0
    /// The zoom factor the UI shows as "1x": the wide lens on phones that also have an ultra-wide lens.
    @Published private(set) var zoomDisplayScale = 1.0
    /// The zoom up to which the picture uses real sensor pixels; past it, the camera upscales.
    @Published private(set) var losslessZoom = 1.0
    @Published private(set) var isLocked = false
    /// False when the microphone is not allowed or missing; the camera streams either way.
    @Published private(set) var hasMic = false
    @Published private(set) var isMicOn = true
    /// The camera mode's size, such as "1080p", once the camera runs.
    @Published private(set) var formatName: String?
    /// The frames the camera delivered in the last second.
    @Published private(set) var frameRate = 0
    @Published private(set) var focusTarget = FocusTarget.center

    let previewLayer = AVCaptureVideoPreviewLayer()

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    private let sessionQueue = DispatchQueue(label: "cleancam.session")
    private let videoQueue = DispatchQueue(label: "cleancam.video")
    private let encoder = H264Encoder()
    private let callAudio = CallAudio()
    private let server = StreamServer(port: CameraController.port)
    private let audioServer = StreamServer(port: CameraController.audioPort)
    private let speakerServer = StreamServer(port: CameraController.speakerPort)
    // Used on sessionQueue only.
    private var device: AVCaptureDevice?
    private var videoOrientation = AVCaptureVideoOrientation.landscapeRight
    private var isDeviceLocked = false
    private var target = FocusTarget.center
    private var facePoint = CGPoint(x: 0.5, y: 0.5)
    private var lastFaceTime = 0.0
    private var faceTimeoutScheduled = false
    // Used on videoQueue only.
    private var framesThisSecond = 0
    private var frameTimer: DispatchSourceTimer?

    override init() {
        super.init()
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspect
        encoder.onEncoded = { [server] data, isKeyframe in
            server.broadcast(data, isKeyframe: isKeyframe)
        }
        callAudio.onMicPCM = { [audioServer] pcm in
            guard audioServer.hasClients else { return }
            // Raw audio has no keyframes: a client can start at any chunk.
            audioServer.broadcast(pcm, isKeyframe: true)
        }
        speakerServer.onReceive = { [callAudio] data in
            callAudio.play(data)
        }
        server.onClientsChanged = { [weak self] count in
            guard let self else { return }
            // A new viewer can only start decoding at a keyframe.
            if count > 0 { self.encoder.requestKeyframe() }
            DispatchQueue.main.async {
                self.status = count > 0 ? "Streaming to PC" : "Waiting for PC on port \(Self.port)"
            }
        }
    }

    /// What the auto settings chose, for the status line, such as "1080p · 24 fps · Face".
    var details: String {
        guard let formatName else { return "" }
        return "\(formatName) · \(frameRate) fps · \(focusTarget.rawValue)"
    }

    func start() {
        server.start()
        audioServer.start()
        speakerServer.start()
        startFrameCounter()
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                DispatchQueue.main.async { self.status = "Allow camera access in Settings" }
                return
            }
            // Ask for the microphone too; the camera and the loudspeaker work whatever the answer.
            AVCaptureDevice.requestAccess(for: .audio) { micAllowed in
                self.callAudio.start(micAllowed: micAllowed) { micRunning in
                    DispatchQueue.main.async { self.hasMic = micRunning }
                }
                self.sessionQueue.async {
                    if self.device == nil { self.configure() }
                    self.session.startRunning()
                }
                // A session that falls back to the preset's mode can reset the frame rates as it starts.
                self.withDeviceLock { Self.applyFrameRates(to: $0) }
            }
        }
    }

    func stop() {
        server.stop()
        audioServer.stop()
        speakerServer.stop()
        callAudio.stop()
        sessionQueue.async { self.session.stopRunning() }
        videoQueue.async {
            self.frameTimer?.cancel()
            self.frameTimer = nil
            self.encoder.reset()
        }
    }

    /// Keeps the preview and the stream upright: portrait or either landscape side.
    /// Flat and upside-down positions keep the last orientation.
    func updateOrientation(_ deviceOrientation: UIDeviceOrientation) {
        let orientation: AVCaptureVideoOrientation
        switch deviceOrientation {
        case .portrait: orientation = .portrait
        case .landscapeLeft: orientation = .landscapeRight  // home button on the right
        case .landscapeRight: orientation = .landscapeLeft
        default: return
        }
        sessionQueue.async {
            self.videoOrientation = orientation
            self.applyOrientation()
        }
    }

    /// Stops drawing the preview while the screen is off; the stream keeps running.
    func setPreviewEnabled(_ enabled: Bool) {
        previewLayer.connection?.isEnabled = enabled
    }

    func setZoom(_ value: Double) {
        zoom = value
        withDeviceLock { $0.videoZoomFactor = CGFloat(value) }
    }

    /// Locks focus, exposure and white balance so the picture stops shifting.
    func toggleLock() {
        isLocked.toggle()
        let lock = isLocked
        withDeviceLock { device in
            self.isDeviceLocked = lock
            let focus: AVCaptureDevice.FocusMode = lock ? .locked : .continuousAutoFocus
            let exposure: AVCaptureDevice.ExposureMode = lock ? .locked : .continuousAutoExposure
            let whiteBalance: AVCaptureDevice.WhiteBalanceMode = lock ? .locked : .continuousAutoWhiteBalance
            if device.isFocusModeSupported(focus) { device.focusMode = focus }
            if device.isExposureModeSupported(exposure) { device.exposureMode = exposure }
            if device.isWhiteBalanceModeSupported(whiteBalance) { device.whiteBalanceMode = whiteBalance }
        }
    }

    /// Focus and exposure follow the tapped point until the next tap or `resetFocus`, while Lock is off.
    /// `point` is in the preview layer's coordinates.
    func focus(atPreviewPoint point: CGPoint) {
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        withDeviceLock { device in
            guard !self.isDeviceLocked else { return }
            Self.setSystemFaceTracking(false, on: device)
            self.setTarget(.tap, point: devicePoint, on: device)
        }
    }

    /// Hands focus and exposure back to faces, or to the center while no face shows.
    func resetFocus() {
        withDeviceLock { device in
            guard !self.isDeviceLocked else { return }
            Self.setSystemFaceTracking(true, on: device)
            self.setTarget(.center, point: CGPoint(x: 0.5, y: 0.5), on: device)
        }
    }

    /// Stops or resumes sending the microphone; the PC's microphone stays and goes silent.
    func toggleMic() {
        isMicOn.toggle()
        callAudio.setMicEnabled(isMicOn)
    }

    private func configure() {
        // Virtual multi-lens cameras switch lenses as the zoom changes.
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera,
        ]
        guard let device = types.lazy.compactMap({ AVCaptureDevice.default($0, for: .video, position: .back) }).first,
              let input = try? AVCaptureDeviceInput(device: device) else {
            DispatchQueue.main.async { self.status = "No camera found" }
            return
        }

        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        addFaceDetection()
        // Inside the session's configuration, so the session keeps this mode instead of the preset's.
        if (try? device.lockForConfiguration()) != nil {
            if let format = Self.bestFormat(of: device) { device.activeFormat = format }
            Self.applyFrameRates(to: device)
            if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = true }
            if device.isLowLightBoostSupported { device.automaticallyEnablesLowLightBoostWhenAvailable = true }
            device.unlockForConfiguration()
        }
        session.commitConfiguration()
        self.device = device
        applyOrientation()

        let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let lossless = Double(device.activeFormat.videoZoomFactorUpscaleThreshold)
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        let wideZoom = hasUltraWide ? (device.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue ?? 1) : 1
        let range = Double(device.minAvailableVideoZoomFactor)...min(Double(device.maxAvailableVideoZoomFactor), wideZoom * 10)
        withDeviceLock { $0.videoZoomFactor = CGFloat(wideZoom) }

        DispatchQueue.main.async {
            self.formatName = "\(size.height)p"
            self.losslessZoom = lossless
            self.zoomRange = range
            self.zoom = wideZoom
            self.zoomDisplayScale = wideZoom
        }
    }

    /// Called on sessionQueue inside the session's configuration. Faces arrive in `metadataOutput(_:didOutput:from:)`.
    private func addFaceDetection() {
        guard session.canAddOutput(metadataOutput) else { return }
        session.addOutput(metadataOutput)
        guard metadataOutput.availableMetadataObjectTypes.contains(.face) else { return }
        metadataOutput.metadataObjectTypes = [.face]
        metadataOutput.setMetadataObjectsDelegate(self, queue: sessionQueue)
    }

    /// The 1920x1080 mode that reaches the top frame rate with the best picture: unbinned first, then with video HDR,
    /// then the most zoom before upscaling, then the widest view, then the lowest top rate, the mode made for that rate.
    private static func bestFormat(of device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        device.formats
            .filter { format in
                let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return size.width == 1920 && size.height == 1080
                    // Video-range YUV, the usual video format; a full-range twin of a mode would shift the stream's colors.
                    && CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    && topFrameRate(of: format) >= Double(frameRates.upperBound)
            }
            .max { score($0) < score($1) }
    }

    private static func score(_ format: AVCaptureDevice.Format) -> (Int, Int, Double, Double, Double) {
        (format.isVideoBinned ? 0 : 1,
         format.isVideoHDRSupported ? 1 : 0,
         Double(format.videoZoomFactorUpscaleThreshold),
         Double(format.videoFieldOfView),
         -topFrameRate(of: format))
    }

    private static func topFrameRate(of format: AVCaptureDevice.Format) -> Double {
        format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
    }

    /// Called with the device locked. Auto exposure holds the top of `frameRates` and slows toward the bottom in the dark;
    /// a rate the mode can't reach falls back to the mode's own limit.
    private static func applyFrameRates(to device: AVCaptureDevice) {
        guard let range = device.activeFormat.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate })
        else { return }
        func duration(_ rate: Int) -> CMTime {
            if Double(rate) >= range.maxFrameRate { return range.minFrameDuration }
            if Double(rate) <= range.minFrameRate { return range.maxFrameDuration }
            return CMTime(value: 1, timescale: CMTimeScale(rate))
        }
        device.activeVideoMinFrameDuration = duration(frameRates.upperBound)
        device.activeVideoMaxFrameDuration = duration(frameRates.lowerBound)
    }

    /// iOS 15.4 and later can steer focus and exposure to faces by itself.
    /// A tap turns that off so the tapped point holds; a reset hands it back to iOS.
    private static func setSystemFaceTracking(_ automatic: Bool, on device: AVCaptureDevice) {
        guard #available(iOS 15.4, *) else { return }
        device.automaticallyAdjustsFaceDrivenAutoFocusEnabled = automatic
        device.automaticallyAdjustsFaceDrivenAutoExposureEnabled = automatic
        guard !automatic else { return }
        device.isFaceDrivenAutoFocusEnabled = false
        device.isFaceDrivenAutoExposureEnabled = false
    }

    /// Called on sessionQueue with the device locked. `point` is in the sensor's 0–1 coordinates.
    private func setTarget(_ target: FocusTarget, point: CGPoint, on device: AVCaptureDevice) {
        self.target = target
        if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = point }
        // Setting the mode again starts focusing and metering at the new point.
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = point }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        DispatchQueue.main.async { self.focusTarget = target }
    }

    /// Called on sessionQueue. Returns focus to the center once no face has shown for `faceTimeout`.
    private func scheduleFaceTimeout(after delay: Double) {
        guard !faceTimeoutScheduled else { return }
        faceTimeoutScheduled = true
        sessionQueue.asyncAfter(deadline: .now() + delay) {
            self.faceTimeoutScheduled = false
            guard self.target == .face, !self.isDeviceLocked, let device = self.device else { return }
            let idle = ProcessInfo.processInfo.systemUptime - self.lastFaceTime
            if idle < Self.faceTimeout {
                self.scheduleFaceTimeout(after: Self.faceTimeout - idle)
            } else if (try? device.lockForConfiguration()) != nil {
                self.setTarget(.center, point: CGPoint(x: 0.5, y: 0.5), on: device)
                device.unlockForConfiguration()
            }
        }
    }

    /// Counts the frames the camera delivers each second, for the status line.
    private func startFrameCounter() {
        videoQueue.async {
            guard self.frameTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.videoQueue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let frames = self.framesThisSecond
                self.framesThisSecond = 0
                DispatchQueue.main.async { self.frameRate = frames }
            }
            timer.resume()
            self.frameTimer = timer
        }
    }

    /// Called on sessionQueue.
    private func applyOrientation() {
        let orientation = videoOrientation
        if let connection = videoOutput.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = orientation
        }
        DispatchQueue.main.async {
            if let connection = self.previewLayer.connection, connection.isVideoOrientationSupported {
                connection.videoOrientation = orientation
            }
        }
    }

    private func withDeviceLock(_ change: @escaping (AVCaptureDevice) -> Void) {
        sessionQueue.async {
            guard let device = self.device, (try? device.lockForConfiguration()) != nil else { return }
            change(device)
            device.unlockForConfiguration()
        }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        framesThisSecond += 1
        // Skip encoding while nobody is watching, to save battery.
        guard server.hasClients else { return }
        encoder.encode(sampleBuffer)
    }
}

extension CameraController: AVCaptureMetadataOutputObjectsDelegate {
    /// Called on sessionQueue. Focus and exposure follow the largest face, unless a tap or Lock holds them.
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard target != .tap, !isDeviceLocked, let device,
              let face = metadataObjects
                  .filter({ $0.type == .face })
                  .max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
        else { return }
        lastFaceTime = ProcessInfo.processInfo.systemUptime
        // Face bounds and the point of interest share the sensor's coordinates.
        let point = CGPoint(x: face.bounds.midX, y: face.bounds.midY)
        // Small head movements keep the last point, so focus and exposure stay steady.
        if target != .face || hypot(point.x - facePoint.x, point.y - facePoint.y) > Self.faceMove {
            facePoint = point
            if (try? device.lockForConfiguration()) != nil {
                setTarget(.face, point: point, on: device)
                device.unlockForConfiguration()
            }
        }
        scheduleFaceTimeout(after: Self.faceTimeout)
    }
}
