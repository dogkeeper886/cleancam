import AVFoundation
import Combine
import UIKit

/// Runs the back camera, shows it on the phone, and streams it as H.264 to whoever connects to `port`,
/// and the microphone as raw PCM to whoever connects to `audioPort`.
/// Plays the raw PCM a PC sends to `speakerPort` on the loudspeaker.
/// Reports its stream to whoever connects to `debugPort`, one JSON line a second and one per event, and takes
/// commands there.
final class CameraController: NSObject, ObservableObject {
    static let port: UInt16 = 5000
    static let audioPort: UInt16 = 5001
    static let speakerPort: UInt16 = 5002
    static let debugPort: UInt16 = 5003
    /// The highest bitrate the debug port's `bitrate` command holds: far above what the encoder sends, and low enough
    /// that the encoder's rate math can't overflow.
    private static let maxPinnedBitRate = 100_000_000
    /// How long focus stays on a face that left the picture before it returns to the center, in seconds.
    private static let faceTimeout = 2.0
    /// How far a face moves, in the sensor's 0–1 coordinates, before focus and exposure follow it.
    private static let faceMove: CGFloat = 0.1
    /// Whether this phone encodes HEVC in hardware, as from the A10 chip on; without it, the WiFi preset sends H.264.
    private static let hasHEVCEncoder = AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetHEVCHighestQuality)

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
    @Published private(set) var isHEVC = false
    /// The frames the camera delivered in the last second.
    @Published private(set) var frameRate = 0
    /// The bitrate the encoder aims for, after it adapted to the link.
    @Published private(set) var bitRate = 0
    @Published private(set) var focusTarget = FocusTarget.center
    @Published private(set) var preset = Preset.saved

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
    private let debugServer = StreamServer(port: CameraController.debugPort)
    // Used on the debug server's queue only.
    private var debugInput = Data()
    // Used on sessionQueue only.
    private var device: AVCaptureDevice?
    private var activePreset = Preset.saved
    /// The zoom the UI shows as "1x"; the zoom slider reaches 10 times it.
    private var wideZoom = 1.0
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
            // The app stops encoding while no viewer is connected, and a session that sat idle then sends 40% over its
            // bitrate, so the next viewer gets a new session.
            if count == 0 { self.videoQueue.async { self.encoder.reset() } }
            self.sendDebug(["event": "viewers", "port": Int(Self.port), "count": count])
            DispatchQueue.main.async {
                self.status = count > 0 ? "Streaming to PC" : "Waiting for PC on port \(Self.port)"
            }
        }
        for (stream, port) in [(audioServer, Self.audioPort), (speakerServer, Self.speakerPort)] {
            stream.onClientsChanged = { [weak self] count in
                self?.sendDebug(["event": "viewers", "port": Int(port), "count": count])
            }
        }
        encoder.onEvent = { [weak self] event in self?.sendDebug(event) }
        debugServer.onReceive = { [weak self] data in self?.receiveDebug(data) }
        // A new debug client learns the preset and the camera mode at once.
        debugServer.onClientsChanged = { [weak self] count in
            guard let self, count > 0 else { return }
            self.sessionQueue.async {
                if let device = self.device { self.reportMode(device) }
            }
        }
    }

    /// The preset and what the auto settings chose, for the status line, such as "Call · 1080p · 24 fps · 8.0 Mbps · Face".
    var details: String {
        guard let formatName else { return "" }
        let mbps = String(format: "%.1f", Double(bitRate) / 1_000_000)
        let codec = isHEVC ? " · HEVC" : ""
        return "\(preset.name) · \(formatName)\(codec) · \(frameRate) fps · \(mbps) Mbps · \(focusTarget.rawValue)"
    }

    func start() {
        server.start()
        audioServer.start()
        speakerServer.start()
        debugServer.start()
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
                // A session that falls back to the session preset's mode can reset the frame rates as it starts.
                self.withDeviceLock { Self.applyFrameRates(self.activePreset.frameRates, to: $0) }
            }
        }
    }

    func stop() {
        server.stop()
        audioServer.stop()
        speakerServer.stop()
        debugServer.stop()
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

    /// Switches to `preset`'s camera mode and frame rates, and keeps it for the next start. Called on any queue.
    func setPreset(_ preset: Preset) {
        preset.save()
        DispatchQueue.main.async { self.preset = preset }
        sessionQueue.async {
            guard preset != self.activePreset else { return }
            self.activePreset = preset
            self.applyPreset()
        }
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
        // Inside the session's configuration, so the session keeps this mode instead of the session preset's.
        if (try? device.lockForConfiguration()) != nil {
            applyMode(to: device)
            if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = true }
            device.unlockForConfiguration()
        }
        session.commitConfiguration()
        self.device = device
        applyOrientation()

        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        let wideZoom = hasUltraWide ? (device.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue ?? 1) : 1
        self.wideZoom = wideZoom
        modeChanged(device)
        withDeviceLock { $0.videoZoomFactor = CGFloat(wideZoom) }

        DispatchQueue.main.async {
            self.zoom = wideZoom
            self.zoomDisplayScale = wideZoom
        }
    }

    /// Called on sessionQueue when the preset changes. A new camera mode pauses the picture for a moment.
    private func applyPreset() {
        guard let device else { return }
        session.beginConfiguration()
        if (try? device.lockForConfiguration()) != nil {
            applyMode(to: device)
            device.unlockForConfiguration()
        }
        session.commitConfiguration()
        let zoom = Double(device.videoZoomFactor)
        DispatchQueue.main.async { self.zoom = zoom }
        modeChanged(device)
    }

    /// Called on sessionQueue with the device locked, inside the session's configuration. Picks the camera mode for the
    /// preset's top frame rate, keeping the zoom, and sets the preset's frame rates.
    private func applyMode(to device: AVCaptureDevice) {
        let rates = activePreset.frameRates
        if let format = Self.bestFormat(of: device, reaching: rates.upperBound), format != device.activeFormat {
            let zoom = device.videoZoomFactor
            device.activeFormat = format
            device.videoZoomFactor = min(zoom, device.maxAvailableVideoZoomFactor)
        }
        Self.applyFrameRates(rates, to: device)
        if device.isLowLightBoostSupported { device.automaticallyEnablesLowLightBoostWhenAvailable = true }
    }

    /// Called on sessionQueue once the preset, the camera mode or its frame rates changed. The encoder plans its bitrate
    /// and keyframes around the mode's top rate and takes the preset's codec, and the status line, the zoom slider and
    /// the debug port follow the mode.
    private func modeChanged(_ device: AVCaptureDevice) {
        let topRate = Self.frameRate(of: device.activeVideoMinFrameDuration)
        let codec = activeCodec
        videoQueue.async {
            if topRate > 0 { self.encoder.setFrameRate(topRate) }
            // The receiver detects the codec as it connects, so a new codec reconnects it.
            if self.encoder.setCodec(codec) { self.server.disconnectAll() }
        }
        let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let lossless = Double(device.activeFormat.videoZoomFactorUpscaleThreshold)
        let range = Double(device.minAvailableVideoZoomFactor)...min(Double(device.maxAvailableVideoZoomFactor), wideZoom * 10)
        DispatchQueue.main.async {
            self.formatName = "\(size.height)p"
            self.isHEVC = codec == kCMVideoCodecType_HEVC
            self.losslessZoom = lossless
            self.zoomRange = range
        }
        reportMode(device)
    }

    /// Called on sessionQueue. Tells the debug port the preset, the camera mode, and the frame rates auto exposure
    /// moves between.
    private func reportMode(_ device: AVCaptureDevice) {
        let format = device.activeFormat
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        sendDebug([
            "event": "mode", "preset": activePreset.rawValue, "codec": activeCodec == kCMVideoCodecType_HEVC ? "hevc" : "h264",
            "width": Int(size.width), "height": Int(size.height),
            "fps": [Self.frameRate(of: device.activeVideoMaxFrameDuration), Self.frameRate(of: device.activeVideoMinFrameDuration)],
            "modeTopFps": Self.topFrameRate(of: format), "binned": format.isVideoBinned, "hdr": format.isVideoHDRSupported,
            "losslessZoom": Double(format.videoZoomFactorUpscaleThreshold),
        ])
    }

    /// Called on sessionQueue inside the session's configuration. Faces arrive in `metadataOutput(_:didOutput:from:)`.
    private func addFaceDetection() {
        guard session.canAddOutput(metadataOutput) else { return }
        session.addOutput(metadataOutput)
        guard metadataOutput.availableMetadataObjectTypes.contains(.face) else { return }
        metadataOutput.metadataObjectTypes = [.face]
        metadataOutput.setMetadataObjectsDelegate(self, queue: sessionQueue)
    }

    /// Called on sessionQueue. The preset's codec, where this phone can encode it.
    private var activeCodec: CMVideoCodecType {
        activePreset.prefersHEVC && Self.hasHEVCEncoder ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
    }

    /// The 1920x1080 mode that reaches `rate` with the best picture, or reaches 30 fps where none reaches `rate`:
    /// unbinned first, then with video HDR, then the most zoom before upscaling, then the widest view, then the lowest
    /// top rate, the mode made for that rate.
    private static func bestFormat(of device: AVCaptureDevice, reaching rate: Int) -> AVCaptureDevice.Format? {
        let modes = device.formats.filter { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return size.width == 1920 && size.height == 1080
                // Video-range YUV, the usual video format; a full-range twin of a mode would shift the stream's colors.
                && CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        let fast = modes.filter { topFrameRate(of: $0) >= Double(rate) }
        return (fast.isEmpty ? modes.filter { topFrameRate(of: $0) >= 30 } : fast).max { score($0) < score($1) }
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

    /// Called with the device locked. Auto exposure holds the top of `rates` and slows toward the bottom in the dark;
    /// a rate the mode can't reach falls back to the mode's own limit.
    private static func applyFrameRates(_ rates: ClosedRange<Int>, to device: AVCaptureDevice) {
        guard let range = device.activeFormat.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate })
        else { return }
        func duration(_ rate: Int) -> CMTime {
            if Double(rate) >= range.maxFrameRate { return range.minFrameDuration }
            if Double(rate) <= range.minFrameRate { return range.maxFrameDuration }
            return CMTime(value: 1, timescale: CMTimeScale(rate))
        }
        device.activeVideoMinFrameDuration = duration(rates.upperBound)
        device.activeVideoMaxFrameDuration = duration(rates.lowerBound)
    }

    /// The frames per second of a frame duration, such as 30 for 1/30 s.
    private static func frameRate(of duration: CMTime) -> Int {
        duration.seconds > 0 ? Int((1 / duration.seconds).rounded()) : 0
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

    /// Counts the frames the camera delivers each second, for the status line and the debug port,
    /// and adapts the encoder's bitrate to how far the PC fell behind in that second.
    private func startFrameCounter() {
        videoQueue.async {
            guard self.frameTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.videoQueue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let frames = self.framesThisSecond
                self.framesThisSecond = 0
                let backlog = self.server.takePeakBacklog()
                self.encoder.adapt(toBacklog: backlog)
                let bitRate = self.encoder.bitRate
                let output = self.encoder.takeOutput()
                self.sendDebug([
                    "event": "second", "fps": frames, "topFps": self.encoder.frameRate, "target": bitRate,
                    "pinned": self.encoder.isPinned, "out": output.bytes * 8, "encoded": output.frames,
                    "keyframes": output.keyframes, "backlog": backlog,
                    "viewers": [
                        "video": self.server.connectionCount, "mic": self.audioServer.connectionCount,
                        "speaker": self.speakerServer.connectionCount,
                    ],
                ])
                DispatchQueue.main.async {
                    self.frameRate = frames
                    self.bitRate = bitRate
                }
            }
            timer.resume()
            self.frameTimer = timer
        }
    }

    /// Sends one JSON line, stamped with the phone's uptime, to every client of the debug port. Called on any queue.
    private func sendDebug(_ event: [String: Any]) {
        guard debugServer.hasClients else { return }
        var line = event
        line["t"] = (ProcessInfo.processInfo.systemUptime * 1000).rounded() / 1000
        guard JSONSerialization.isValidJSONObject(line),
              var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        debugServer.broadcast(data, isKeyframe: true)
    }

    /// Called on the debug server's queue with what a debug client typed: one command per line.
    private func receiveDebug(_ data: Data) {
        debugInput.append(data)
        while let newline = debugInput.firstIndex(of: 0x0A) {
            let line = String(decoding: debugInput[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            debugInput = debugInput.subdata(in: newline + 1..<debugInput.endIndex)
            if !line.isEmpty { runDebugCommand(line) }
        }
        // A client that never ends a line can't grow the buffer without bound.
        if debugInput.count > 1024 { debugInput = Data() }
    }

    /// Runs a debug command: `bitrate N` holds the bitrate at N bits per second, `auto` hands it back to adaptation,
    /// `keyframe` asks for a keyframe, and `preset NAME` switches the preset, as the settings sheet does.
    private func runDebugCommand(_ line: String) {
        let words = line.split(separator: " ").map(String.init)
        var ok = true
        switch words.first {
        case "preset"? where words.count == 2 && Preset(rawValue: words[1]) != nil:
            setPreset(Preset(rawValue: words[1])!)
        case "bitrate"? where words.count == 2 && (1...Self.maxPinnedBitRate).contains(Int(words[1]) ?? 0):
            let rate = Int(words[1])!
            videoQueue.async { self.encoder.pin(bitRate: rate) }
        case "auto"? where words.count == 1:
            videoQueue.async { self.encoder.unpin() }
        case "keyframe"? where words.count == 1:
            encoder.requestKeyframe()
        default:
            ok = false
        }
        sendDebug(["event": "command", "command": line, "ok": ok])
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
