import AVFoundation
import Combine
import UIKit

/// Runs the back camera, shows it on the phone, and streams it as H.264 to whoever connects to `port`,
/// and the microphone as raw PCM to whoever connects to `audioPort`.
final class CameraController: NSObject, ObservableObject {
    static let port: UInt16 = 5000
    static let audioPort: UInt16 = 5001

    @Published private(set) var status = "Starting…"
    @Published private(set) var zoom = 1.0
    @Published private(set) var zoomRange = 1.0...1.0
    /// The zoom factor the UI shows as "1x": the wide lens on phones that also have an ultra-wide lens.
    @Published private(set) var zoomDisplayScale = 1.0
    @Published private(set) var isLocked = false
    /// False when the microphone is not allowed or missing; the camera streams either way.
    @Published private(set) var hasMic = false
    @Published private(set) var isMicOn = true

    let previewLayer = AVCaptureVideoPreviewLayer()

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "cleancam.session")
    private let videoQueue = DispatchQueue(label: "cleancam.video")
    private let audioQueue = DispatchQueue(label: "cleancam.audio")
    private let encoder = H264Encoder()
    private let pcmConverter = PCMConverter()
    private let server = StreamServer(port: CameraController.port)
    private let audioServer = StreamServer(port: CameraController.audioPort)
    // Used on sessionQueue only.
    private var device: AVCaptureDevice?
    private var videoOrientation = AVCaptureVideoOrientation.landscapeRight
    private var micEnabled = true

    override init() {
        super.init()
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspect
        encoder.onEncoded = { [server] data, isKeyframe in
            server.broadcast(data, isKeyframe: isKeyframe)
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

    func start() {
        server.start()
        audioServer.start()
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                DispatchQueue.main.async { self.status = "Allow camera access in Settings" }
                return
            }
            // Ask for the microphone too; the camera streams whatever the answer.
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                self.sessionQueue.async {
                    if self.device == nil { self.configure() }
                    self.session.startRunning()
                }
            }
        }
    }

    func stop() {
        server.stop()
        audioServer.stop()
        sessionQueue.async { self.session.stopRunning() }
        videoQueue.async { self.encoder.reset() }
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
            let focus: AVCaptureDevice.FocusMode = lock ? .locked : .continuousAutoFocus
            let exposure: AVCaptureDevice.ExposureMode = lock ? .locked : .continuousAutoExposure
            let whiteBalance: AVCaptureDevice.WhiteBalanceMode = lock ? .locked : .continuousAutoWhiteBalance
            if device.isFocusModeSupported(focus) { device.focusMode = focus }
            if device.isExposureModeSupported(exposure) { device.exposureMode = exposure }
            if device.isWhiteBalanceModeSupported(whiteBalance) { device.whiteBalanceMode = whiteBalance }
        }
    }

    /// Stops or resumes sending the microphone; the PC's microphone stays and goes silent.
    func toggleMic() {
        isMicOn.toggle()
        let on = isMicOn
        sessionQueue.async {
            self.micEnabled = on
            self.audioOutput.connection(with: .audio)?.isEnabled = on
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
        var micAdded = false
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
                audioOutput.connection(with: .audio)?.isEnabled = micEnabled
                micAdded = true
            }
        }
        session.commitConfiguration()
        self.device = device
        applyOrientation()

        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        let wideZoom = hasUltraWide ? (device.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue ?? 1) : 1
        let range = Double(device.minAvailableVideoZoomFactor)...min(Double(device.maxAvailableVideoZoomFactor), wideZoom * 10)
        withDeviceLock { $0.videoZoomFactor = CGFloat(wideZoom) }

        DispatchQueue.main.async {
            self.zoomRange = range
            self.zoom = wideZoom
            self.zoomDisplayScale = wideZoom
            self.hasMic = micAdded
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

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            guard audioServer.hasClients, let pcm = pcmConverter.convert(sampleBuffer) else { return }
            // Raw audio has no keyframes: a client can start at any chunk.
            audioServer.broadcast(pcm, isKeyframe: true)
            return
        }
        // Skip encoding while nobody is watching, to save battery.
        guard server.hasClients else { return }
        encoder.encode(sampleBuffer)
    }
}
