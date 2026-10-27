import AVFoundation
import Combine
import UIKit

/// Runs the back camera, shows it on the phone, and streams it as H.264, or HEVC in the WiFi preset, to whoever
/// connects to `port`, and the microphone as raw PCM to whoever connects to `audioPort`.
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
    /// Auto stabilization, and the heat guard as the phone cools, change the camera at most once in this many seconds,
    /// since each change can glitch the picture.
    private static let autoChangeInterval = 60.0
    /// The debug port's names for the thermal states and battery states its `thermal` and `battery` commands stand in.
    private static let thermalStates: [String: ProcessInfo.ThermalState] = [
        "nominal": .nominal, "fair": .fair, "serious": .serious, "critical": .critical,
    ]
    private static let batteryStates: [String: UIDevice.BatteryState] = [
        "unknown": .unknown, "unplugged": .unplugged, "charging": .charging, "full": .full,
    ]

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
    /// Whether the encoder sends HEVC instead of H.264.
    @Published private(set) var isHEVC = false
    /// The frames the camera delivered in the last second.
    @Published private(set) var frameRate = 0
    /// The bitrate the encoder aims for, after it adapted to the link.
    @Published private(set) var bitRate = 0
    @Published private(set) var focusTarget = FocusTarget.center
    @Published private(set) var preset = Preset.saved
    @Published private(set) var options = CameraOptions.saved
    /// The lenses the user can hold, widest first; empty on a single-lens phone.
    @Published private(set) var lenses: [Lens] = []
    /// The zoom of each lens, for the chips above the zoom slider, while Auto switches lenses.
    @Published private(set) var lensZooms: [Double] = []
    /// The lens the picture comes from, where the phone has more than one and tells which.
    @Published private(set) var lensName: String?
    /// Whether the camera can hold a fixed white balance; a multi-lens camera can't, while each lens's own camera can.
    @Published private(set) var canFixWhiteBalance = false
    @Published private(set) var stabilizationMode = AVCaptureVideoStabilizationMode.off
    @Published private(set) var heat = HeatLevel.none

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
    /// The camera the picture comes from: `defaultDevice`, or one lens's own camera.
    private var device: AVCaptureDevice?
    /// The multi-lens camera, which switches lenses as the zoom changes, or the only back camera.
    private var defaultDevice: AVCaptureDevice?
    /// Each lens's own camera, widest first, with the multi-lens camera's zoom where it switches to that lens.
    private var lensCameras: [(lens: Lens, device: AVCaptureDevice, zoom: Double)] = []
    private var lensObservation: NSKeyValueObservation?
    private var activePreset = Preset.saved
    private var activeOptions = CameraOptions.saved
    private var motion = MotionDetector.State.unknown
    private var stabilizationChangedAt = -Double.infinity
    private var stabilizationCheckScheduled = false
    private var thermalState = ProcessInfo.ThermalState.nominal
    private var batteryState = UIDevice.BatteryState.unknown
    /// Set by the debug port's `thermal` and `battery` commands in place of the phone's own states.
    private var thermalOverride: ProcessInfo.ThermalState?
    private var batteryOverride: UIDevice.BatteryState?
    private var activeHeat = HeatLevel.none
    private var heatChangedAt = -Double.infinity
    private var heatCheckScheduled = false
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
    private let motionDetector = MotionDetector()

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
        // A new debug client learns the preset, the camera mode and the camera options at once.
        debugServer.onClientsChanged = { [weak self] count in
            guard let self, count > 0 else { return }
            self.sessionQueue.async {
                if let device = self.device { self.reportMode(device) }
                self.reportCamera(reason: "client")
            }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(powerChanged), name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(powerChanged), name: UIDevice.batteryStateDidChangeNotification, object: nil)
    }

    /// The preset and what the auto settings and the options chose, for the status line, such as
    /// "Call · 1080p · 24 fps · 8.0 Mbps · Wide · Stab off · Face".
    var details: String {
        guard let formatName else { return "" }
        let mbps = String(format: "%.1f", Double(bitRate) / 1_000_000)
        let codec = isHEVC ? " · HEVC" : ""
        var parts = [preset.name, "\(formatName)\(codec)", "\(frameRate) fps", "\(mbps) Mbps"]
        parts += [lensName, Self.statusName(of: stabilizationMode)].compactMap { $0 }
        if options.exposureBias != 0 { parts.append(String(format: "EV %+.1f", options.exposureBias)) }
        if let kelvins = options.whiteBalance, canFixWhiteBalance { parts.append("\(kelvins) K") }
        if options.nearFocus { parts.append("Near") }
        parts += [heat.name, focusTarget.rawValue].compactMap { $0 }
        return parts.joined(separator: " · ")
    }

    func start() {
        server.start()
        audioServer.start()
        speakerServer.start()
        debugServer.start()
        startFrameCounter()
        videoQueue.async { self.motionDetector.start(on: self.videoQueue) }
        UIDevice.current.isBatteryMonitoringEnabled = true
        powerChanged()
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
                self.withDeviceLock { Self.applyFrameRates(self.modeLimits.rates, to: $0) }
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
            self.motionDetector.stop()
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

    /// Locks focus, exposure and white balance so the picture stops shifting. A fixed white balance stays fixed.
    func toggleLock() {
        isLocked.toggle()
        let lock = isLocked
        withDeviceLock { device in
            self.isDeviceLocked = lock
            let focus: AVCaptureDevice.FocusMode = lock ? .locked : .continuousAutoFocus
            let exposure: AVCaptureDevice.ExposureMode = lock ? .locked : .continuousAutoExposure
            if device.isFocusModeSupported(focus) { device.focusMode = focus }
            if device.isExposureModeSupported(exposure) { device.exposureMode = exposure }
            self.applyWhiteBalance(to: device)
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
            self.applyCameraMode()
            self.applyStabilization()
        }
    }

    /// Applies the camera options and keeps them for the next start. Called on any queue.
    func setOptions(_ options: CameraOptions) {
        options.save()
        // The settings sheet's sliders read the options back as they move.
        if Thread.isMainThread { self.options = options } else { DispatchQueue.main.async { self.options = options } }
        sessionQueue.async {
            let old = self.activeOptions
            guard options != old else { return }
            self.activeOptions = options
            if options.lens != old.lens {
                self.applyLens()
            } else if let device = self.device, (try? device.lockForConfiguration()) != nil {
                self.applyOptions(to: device)
                device.unlockForConfiguration()
            }
            if self.applyStabilization() { self.stabilizationChangedAt = ProcessInfo.processInfo.systemUptime }
            self.applyBitRateLimit()
            self.reportCamera(reason: "options")
        }
    }

    private func configure() {
        // Virtual multi-lens cameras switch lenses as the zoom changes.
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera,
        ]
        guard let device = types.lazy.compactMap({ AVCaptureDevice.default($0, for: .video, position: .back) }).first
        else {
            DispatchQueue.main.async { self.status = "No camera found" }
            return
        }
        defaultDevice = device
        // The multi-lens camera starts at its widest lens, at zoom 1, and switches to each next lens at its zoom.
        let zooms = [1.0] + device.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue)
        let constituents = device.constituentDevices
            .compactMap { camera in Lens(camera.deviceType).map { (lens: $0, device: camera) } }
            .sorted { Lens.allCases.firstIndex(of: $0.lens)! < Lens.allCases.firstIndex(of: $1.lens)! }
        lensCameras = zip(constituents, zooms).map { (lens: $0.lens, device: $0.device, zoom: $1) }
        let lenses = lensCameras.map(\.lens)
        DispatchQueue.main.async { self.lenses = lenses }

        session.beginConfiguration()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        addFaceDetection()
        session.commitConfiguration()
        applyLens()
        applyBitRateLimit()
    }

    /// Called on sessionQueue. Streams from the lens the user holds, or in Auto from the multi-lens camera, which
    /// switches lenses as the zoom, the light and the focus distance change. A new camera starts with focus and exposure
    /// on the center and Lock off, and pauses the picture for a moment.
    private func applyLens() {
        guard let defaultDevice else { return }
        let held = lensCameras.first { $0.lens == activeOptions.lens }
        let camera = held?.device ?? defaultDevice
        guard camera != device, let input = try? AVCaptureDeviceInput(device: camera) else { return }

        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        if session.canAddInput(input) { session.addInput(input) }
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        // The new camera's faces arrive once the output asks for them again.
        if metadataOutput.availableMetadataObjectTypes.contains(.face) { metadataOutput.metadataObjectTypes = [.face] }
        // Inside the session's configuration, so the session keeps this mode instead of the session preset's.
        if (try? camera.lockForConfiguration()) != nil {
            isDeviceLocked = false
            applyMode(to: camera)
            if camera.isSmoothAutoFocusSupported { camera.isSmoothAutoFocusEnabled = true }
            Self.setSystemFaceTracking(true, on: camera)
            setTarget(.center, point: CGPoint(x: 0.5, y: 0.5), on: camera)
            applyOptions(to: camera)
            camera.unlockForConfiguration()
        }
        session.commitConfiguration()
        device = camera
        applyOrientation()

        // The UI shows the wide lens as 1x: in Auto at the multi-lens camera's zoom for it, and for a held lens by how
        // far that lens zooms past the wide one.
        let wide = lensCameras.first { $0.lens == .wide }?.zoom ?? 1
        let wideZoom = held.map { wide / $0.zoom } ?? wide
        let zoom = held == nil ? wideZoom : 1
        self.wideZoom = wideZoom
        if (try? camera.lockForConfiguration()) != nil {
            camera.videoZoomFactor = CGFloat(zoom)
            camera.unlockForConfiguration()
        }
        let chips = held == nil && lensCameras.count > 1 ? lensCameras.map(\.zoom) : []
        let canFixWhiteBalance = camera.isLockingWhiteBalanceWithCustomDeviceGainsSupported
        DispatchQueue.main.async {
            self.canFixWhiteBalance = canFixWhiteBalance
            self.zoom = zoom
            self.zoomDisplayScale = wideZoom
            self.lensZooms = chips
            self.isLocked = false
        }
        observeLens(of: camera)
        applyStabilization()
        modeChanged(camera)
    }

    /// Called on sessionQueue. Keeps the status line's lens name on the lens the picture comes from.
    private func observeLens(of camera: AVCaptureDevice) {
        lensObservation = nil
        guard !lensCameras.isEmpty else { return }
        guard camera.isVirtualDevice else {
            let name = Lens(camera.deviceType)?.name
            DispatchQueue.main.async { self.lensName = name }
            return
        }
        lensObservation = camera.observe(\.activePrimaryConstituent, options: [.initial, .new]) { [weak self] camera, _ in
            let name = camera.activePrimaryConstituent.flatMap { Lens($0.deviceType) }?.name
            DispatchQueue.main.async { self?.lensName = name }
        }
    }

    /// Called on sessionQueue with the device locked. Sets the exposure compensation, the white balance and the focus
    /// range the user picked.
    private func applyOptions(to device: AVCaptureDevice) {
        let bias = min(max(activeOptions.exposureBias, device.minExposureTargetBias), device.maxExposureTargetBias)
        device.setExposureTargetBias(bias, completionHandler: nil)
        if device.isAutoFocusRangeRestrictionSupported {
            device.autoFocusRangeRestriction = activeOptions.nearFocus ? .near : .none
        }
        applyWhiteBalance(to: device)
    }

    /// Called on sessionQueue with the device locked. A fixed white balance holds the user's temperature; otherwise
    /// iOS's auto white balance runs, or holds while Lock is on.
    private func applyWhiteBalance(to device: AVCaptureDevice) {
        if let kelvins = activeOptions.whiteBalance, device.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: Float(kelvins), tint: 0)
            let gains = device.deviceWhiteBalanceGains(for: values)
            // The camera takes only gains from 1 to its maximum.
            let fit = { (gain: Float) in min(max(gain, 1), device.maxWhiteBalanceGain) }
            device.setWhiteBalanceModeLocked(
                with: .init(redGain: fit(gains.redGain), greenGain: fit(gains.greenGain), blueGain: fit(gains.blueGain)),
                completionHandler: nil)
            return
        }
        let mode: AVCaptureDevice.WhiteBalanceMode = isDeviceLocked ? .locked : .continuousAutoWhiteBalance
        if device.isWhiteBalanceModeSupported(mode) { device.whiteBalanceMode = mode }
    }

    /// Called on sessionQueue. Sets the stabilization the user picked or, in Auto, the one the motion calls for: off
    /// while the phone stands still, and on while it shakes, cinematic in OBS, whose apps don't mind its delay. The heat
    /// guard turns it off. Returns whether the stabilization changed.
    @discardableResult
    private func applyStabilization() -> Bool {
        guard let device, let connection = videoOutput.connection(with: .video), connection.isVideoStabilizationSupported
        else { return false }
        var mode: AVCaptureVideoStabilizationMode
        switch activeOptions.stabilization {
        case .auto: mode = motion != .shaking ? .off : activePreset == .obs ? .cinematic : .standard
        case .off: mode = .off
        case .standard: mode = .standard
        case .cinematic: mode = .cinematic
        }
        if !activeHeat.allowsStabilization { mode = .off }
        if mode == .cinematic && !device.activeFormat.isVideoStabilizationModeSupported(.cinematic) { mode = .standard }
        if mode == .standard && !device.activeFormat.isVideoStabilizationModeSupported(.standard) { mode = .off }
        guard mode != connection.preferredVideoStabilizationMode else { return false }
        connection.preferredVideoStabilizationMode = mode
        DispatchQueue.main.async { self.stabilizationMode = mode }
        return true
    }

    /// Called on sessionQueue when the phone started to shake or has stood still for a while. Auto stabilization
    /// follows, at most once in `autoChangeInterval`.
    private func motionChanged(_ state: MotionDetector.State) {
        motion = state
        applyAutoStabilization()
    }

    private func applyAutoStabilization() {
        guard activeOptions.stabilization == .auto else { return }
        let wait = stabilizationChangedAt + Self.autoChangeInterval - ProcessInfo.processInfo.systemUptime
        guard wait <= 0 else {
            guard !stabilizationCheckScheduled else { return }
            stabilizationCheckScheduled = true
            sessionQueue.asyncAfter(deadline: .now() + wait) {
                self.stabilizationCheckScheduled = false
                self.applyAutoStabilization()
            }
            return
        }
        guard applyStabilization() else { return }
        stabilizationChangedAt = ProcessInfo.processInfo.systemUptime
        reportCamera(reason: "motion")
    }

    /// Called on any queue when the phone's heat or power changed.
    @objc private func powerChanged() {
        DispatchQueue.main.async {
            let battery = UIDevice.current.batteryState
            let thermal = ProcessInfo.processInfo.thermalState
            self.sessionQueue.async {
                self.thermalState = thermal
                self.batteryState = battery
                self.updateHeat()
            }
        }
    }

    /// Called on sessionQueue. Moves the heat guard to the level the phone's heat and power call for. A higher level
    /// applies at once; a lower one waits until `autoChangeInterval` after the last change, so a phone that cools
    /// changes its camera mode at most once in that time.
    private func updateHeat() {
        let level = HeatLevel(thermal: thermalOverride ?? thermalState, battery: batteryOverride ?? batteryState)
        guard level != activeHeat else { return }
        let wait = heatChangedAt + Self.autoChangeInterval - ProcessInfo.processInfo.systemUptime
        guard level > activeHeat || wait <= 0 else {
            guard !heatCheckScheduled else { return }
            heatCheckScheduled = true
            sessionQueue.asyncAfter(deadline: .now() + wait) {
                self.heatCheckScheduled = false
                self.updateHeat()
            }
            return
        }
        activeHeat = level
        heatChangedAt = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { self.heat = level }
        applyCameraMode()
        applyStabilization()
        applyBitRateLimit()
        reportCamera(reason: "heat")
    }

    /// Called on sessionQueue. Caps the encoder's bitrate by the heat guard and the user's max bitrate.
    private func applyBitRateLimit() {
        let share = activeHeat.bitRateShare
        let maxBitRate = [activeOptions.maxBitRate, activeHeat.maxBitRate].compactMap { $0 }.min()
        videoQueue.async { self.encoder.setLimit(share: share, maxBitRate: maxBitRate) }
    }

    /// Called on sessionQueue when the preset or the heat guard changes. A new camera mode pauses the picture for a
    /// moment.
    private func applyCameraMode() {
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
    /// preset's size and top frame rate, keeping the zoom, and sets the preset's frame rates, within what the heat guard
    /// allows.
    private func applyMode(to device: AVCaptureDevice) {
        let (height, rates) = modeLimits
        if let format = Self.bestFormat(of: device, height: height, reaching: rates.upperBound),
           format != device.activeFormat {
            let zoom = device.videoZoomFactor
            device.activeFormat = format
            device.videoZoomFactor = min(zoom, device.maxAvailableVideoZoomFactor)
        }
        Self.applyFrameRates(rates, to: device)
        if device.isLowLightBoostSupported { device.automaticallyEnablesLowLightBoostWhenAvailable = true }
    }

    /// Called on sessionQueue. The preset's camera mode height and frame rates, within what the heat guard allows.
    private var modeLimits: (height: Int, rates: ClosedRange<Int>) {
        let rates = activePreset.frameRates
        let top = min(rates.upperBound, activeHeat.topFrameRate ?? rates.upperBound)
        return (min(activePreset.height, activeHeat.maxHeight ?? activePreset.height), min(rates.lowerBound, top)...top)
    }

    /// Called on sessionQueue once the preset, the camera, the camera mode or its frame rates changed. The encoder plans
    /// its bitrate and keyframes around the mode's top rate, takes the mode's size and the preset's codec, and the status
    /// line, the zoom slider and the debug port follow the mode.
    private func modeChanged(_ device: AVCaptureDevice) {
        let topRate = Self.frameRate(of: device.activeVideoMinFrameDuration)
        let codec = activeCodec
        let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        videoQueue.async {
            if topRate > 0 { self.encoder.setFrameRate(topRate) }
            let newCodec = self.encoder.setCodec(codec)
            let newSize = self.encoder.setSize(width: Int(size.width), height: Int(size.height))
            // The receiver detects the codec and the size as it connects, so a new codec or size reconnects it.
            if newCodec || newSize { self.server.disconnectAll() }
        }
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

    /// Called on sessionQueue. Tells the debug port the camera options, what the camera took of them, and the heat
    /// guard's level and the states it follows.
    private func reportCamera(reason: String) {
        guard let device else { return }
        let connection = videoOutput.connection(with: .video)
        let options = activeOptions
        let kelvins = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains).temperature
        let activeLens = device.activePrimaryConstituent.flatMap { Lens($0.deviceType) }
        sendDebug([
            "event": "camera", "reason": reason,
            "lens": [
                "asked": options.lens.rawValue, "camera": Lens(device.deviceType)?.rawValue ?? "multi",
                "active": activeLens.map { $0.rawValue as Any } ?? NSNull(),
            ] as [String: Any],
            "stabilization": [
                "asked": options.stabilization.rawValue, "motion": motion.rawValue,
                "preferred": Self.debugName(of: connection?.preferredVideoStabilizationMode),
                "active": Self.debugName(of: connection?.activeVideoStabilizationMode),
            ],
            "exposureBias": ["asked": options.exposureBias, "took": device.exposureTargetBias],
            "whiteBalance": [
                "asked": options.whiteBalance.map { $0 as Any } ?? "auto",
                "mode": device.whiteBalanceMode == .locked ? "locked" : "auto", "kelvins": Int(kelvins.rounded()),
                "fixable": device.isLockingWhiteBalanceWithCustomDeviceGainsSupported,
            ] as [String: Any],
            "nearFocus": ["asked": options.nearFocus, "took": device.autoFocusRangeRestriction == .near],
            "maxBitRate": options.maxBitRate.map { $0 as Any } ?? NSNull(),
            "heat": [
                "level": String(describing: activeHeat),
                "thermal": Self.thermalStates.first { $0.value == thermalOverride ?? thermalState }?.key ?? "unknown",
                "battery": Self.batteryStates.first { $0.value == batteryOverride ?? batteryState }?.key ?? "unknown",
                "overridden": thermalOverride != nil || batteryOverride != nil,
            ] as [String: Any],
        ])
    }

    /// Called on sessionQueue inside the session's configuration. Faces arrive in `metadataOutput(_:didOutput:from:)`
    /// once a camera is added and asks for them.
    private func addFaceDetection() {
        guard session.canAddOutput(metadataOutput) else { return }
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: sessionQueue)
    }

    /// Called on sessionQueue. The preset's codec, where this phone can encode it.
    private var activeCodec: CMVideoCodecType {
        activePreset.prefersHEVC && Self.hasHEVCEncoder ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
    }

    /// The 16:9 mode `height` pixels tall that reaches `rate` with the best picture, or reaches 30 fps where none
    /// reaches `rate`: unbinned first, then with cinematic stabilization, then with video HDR, then the most zoom before
    /// upscaling, then the widest view, then the lowest top rate, the mode made for that rate. Nil where the camera has
    /// no mode that size.
    private static func bestFormat(of device: AVCaptureDevice, height: Int, reaching rate: Int) -> AVCaptureDevice.Format? {
        let modes = device.formats.filter { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return Int(size.height) == height && Int(size.width) == height * 16 / 9
                // Video-range YUV, the usual video format; a full-range twin of a mode would shift the stream's colors.
                && CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        let fast = modes.filter { topFrameRate(of: $0) >= Double(rate) }
        return (fast.isEmpty ? modes.filter { topFrameRate(of: $0) >= 30 } : fast).max { score($0) < score($1) }
    }

    private static func score(_ format: AVCaptureDevice.Format) -> (Int, Int, Int, Double, Double, Double) {
        (format.isVideoBinned ? 0 : 1,
         format.isVideoStabilizationModeSupported(.cinematic) ? 1 : 0,
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

    /// The status line's name for a stabilization mode.
    private static func statusName(of mode: AVCaptureVideoStabilizationMode) -> String {
        switch mode {
        case .off: return "Stab off"
        case .standard: return "Stab on"
        case .cinematic: return "Cinematic"
        default: return "Stab auto"
        }
    }

    /// The debug port's name for a stabilization mode.
    private static func debugName(of mode: AVCaptureVideoStabilizationMode?) -> String {
        switch mode {
        case .off?: return "off"
        case .standard?: return "standard"
        case .cinematic?: return "cinematic"
        case .cinematicExtended?: return "cinematicExtended"
        case .auto?: return "auto"
        case nil: return "none"
        default: return "other"
        }
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

    /// Counts the frames the camera delivers each second, for the status line and the debug port, adapts the encoder's
    /// bitrate to how far the PC fell behind in that second, and tells auto stabilization how the phone moved.
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
                let rotation = self.motionDetector.takeSecond()
                if rotation.changed {
                    let state = self.motionDetector.state
                    self.sessionQueue.async { self.motionChanged(state) }
                }
                self.sendDebug([
                    "event": "second", "fps": frames, "topFps": self.encoder.frameRate, "target": bitRate,
                    "pinned": self.encoder.isPinned, "out": output.bytes * 8, "encoded": output.frames,
                    "keyframes": output.keyframes, "backlog": backlog,
                    "rotation": (rotation.peak * 1000).rounded() / 1000,
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
    /// `keyframe` asks for a keyframe, and `preset NAME` switches the preset, as the settings sheet does. `lens`, `stab`,
    /// `ev`, `wb`, `near` and `maxbitrate` set a camera option as the settings sheet does; `thermal` and `battery` stand
    /// in for the phone's heat and power until `auto`; `camera` reports the camera options.
    private func runDebugCommand(_ line: String) {
        let words = line.split(separator: " ").map(String.init)
        let value = words.count == 2 ? words[1] : ""
        var ok = true
        switch words.first {
        case "preset"? where Preset(rawValue: value) != nil:
            setPreset(Preset(rawValue: value)!)
        case "bitrate"? where (1...Self.maxPinnedBitRate).contains(Int(value) ?? 0):
            let rate = Int(value)!
            videoQueue.async { self.encoder.pin(bitRate: rate) }
        case "auto"? where words.count == 1:
            videoQueue.async { self.encoder.unpin() }
        case "keyframe"? where words.count == 1:
            encoder.requestKeyframe()
        case "lens"? where Lens(rawValue: value) != nil:
            changeOptions { $0.lens = Lens(rawValue: value)! }
        case "stab"? where Stabilization(rawValue: value) != nil:
            changeOptions { $0.stabilization = Stabilization(rawValue: value)! }
        case "ev"? where Float(value).map { CameraOptions.exposureBiasRange.contains($0) } == true:
            changeOptions { $0.exposureBias = Float(value)! }
        case "wb"? where value == "auto" || Int(value).map { CameraOptions.whiteBalanceRange.contains($0) } == true:
            changeOptions { $0.whiteBalance = Int(value) }
        case "near"? where value == "on" || value == "off":
            changeOptions { $0.nearFocus = value == "on" }
        case "maxbitrate"? where value == "off" || (1...Self.maxPinnedBitRate).contains(Int(value) ?? 0):
            changeOptions { $0.maxBitRate = Int(value) }
        case "thermal"? where value == "auto" || Self.thermalStates[value] != nil:
            sessionQueue.async {
                self.thermalOverride = Self.thermalStates[value]
                self.updateHeat()
            }
        case "battery"? where value == "auto" || Self.batteryStates[value] != nil:
            sessionQueue.async {
                self.batteryOverride = Self.batteryStates[value]
                self.updateHeat()
            }
        case "camera"? where words.count == 1:
            sessionQueue.async { self.reportCamera(reason: "command") }
        default:
            ok = false
        }
        sendDebug(["event": "command", "command": line, "ok": ok])
    }

    /// Changes the camera options from the debug port, as the settings sheet does.
    private func changeOptions(_ change: @escaping (inout CameraOptions) -> Void) {
        sessionQueue.async {
            var options = self.activeOptions
            change(&options)
            self.setOptions(options)
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
