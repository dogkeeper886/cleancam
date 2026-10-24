import AVFoundation

/// Plays the PC's speaker audio on the iPhone's loudspeaker and records its microphone through one audio engine,
/// so Apple's voice processing removes the loudspeaker's echo from the microphone, as in a phone call.
final class CallAudio {
    /// Called on the microphone's capture thread with 48 kHz mono 16-bit PCM.
    var onMicPCM: ((Data) -> Void)?

    /// Silence played before the first sound, and after the queue runs dry, to absorb uneven delivery.
    private static let prebufferFrames = 1_920  // 40 ms
    /// At most this much is queued; older sound beyond it is dropped, so the delay stays short after a burst
    /// or when the PC's clock runs faster than the phone's.
    private static let maxQueuedFrames = 3_840  // 80 ms

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: PCMConverter.sampleRate, channels: 1)!
    private let converter = PCMConverter()
    private let queue = DispatchQueue(label: "cleancam.callaudio")
    // Used on queue only.
    private var micAllowed = false
    private var micRunning = false
    private var queuedFrames = 0
    private var leftover = Data()

    private let lock = NSLock()
    private var micEnabled = true

    init() {
        engine.attach(player)
        // A route change, such as plugging in headphones, stops the engine, and so does an interruption such as a call.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { _ = self.startEngine() }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self.queue.async { _ = self.startEngine() }
        }
    }

    /// Starts the loudspeaker and, when allowed, the microphone; `onMicReady` gets whether the microphone runs.
    func start(micAllowed: Bool, onMicReady: @escaping (Bool) -> Void) {
        queue.async {
            self.micAllowed = micAllowed
            onMicReady(self.startEngine())
        }
    }

    func stop() {
        queue.async {
            self.player.stop()
            self.engine.stop()
            self.queuedFrames = 0
            self.leftover = Data()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Stops or resumes sending the microphone; the voice processing keeps running.
    func setMicEnabled(_ enabled: Bool) {
        lock.lock()
        micEnabled = enabled
        lock.unlock()
    }

    /// Queues 48 kHz mono 16-bit PCM from the PC for the loudspeaker.
    func play(_ data: Data) {
        queue.async { self.enqueue(data) }
    }

    /// Called on queue. Returns whether the microphone runs.
    @discardableResult
    private func startEngine() -> Bool {
        if engine.isRunning { return micRunning }
        do {
            // defaultToSpeaker plays on the loudspeaker instead of the earpiece.
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            return false
        }

        micRunning = false
        if micAllowed {
            let input = engine.inputNode
            // Voice processing must be on before the engine starts; it changes the input's format.
            if !input.isVoiceProcessingEnabled { try? input.setVoiceProcessingEnabled(true) }
            input.removeTap(onBus: 0)
            let format = input.outputFormat(forBus: 0)
            if format.sampleRate > 0, format.channelCount > 0 {
                input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
                    self?.capture(buffer)
                }
                micRunning = true
            }
        }
        if engine.outputConnectionPoints(for: player, outputBus: 0).isEmpty {
            engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        }

        // A stopped engine leaves stale buffers scheduled; start the queue afresh.
        player.stop()
        queuedFrames = 0
        leftover = Data()
        engine.prepare()
        do {
            try engine.start()
        } catch {
            micRunning = false
        }
        return micRunning
    }

    /// Called on the microphone's capture thread.
    private func capture(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let enabled = micEnabled
        lock.unlock()
        guard enabled, let pcm = converter.convert(buffer) else { return }
        onMicPCM?(pcm)
    }

    /// Called on queue.
    private func enqueue(_ data: Data) {
        guard engine.isRunning else { return }
        // TCP can split a 16-bit sample; the odd byte waits for the next chunk.
        leftover.append(data)
        let received = leftover.count / 2
        guard received > 0 else { return }
        let whole = leftover.prefix(received * 2)
        leftover = Data(leftover.dropFirst(received * 2))

        if queuedFrames == 0 { scheduleSilence(frames: Self.prebufferFrames) }
        // Keep the newest sound that fits; what arrives late in a burst is stale.
        let frames = min(received, Self.maxQueuedFrames - queuedFrames)
        guard frames > 0 else { return }
        let chunk = whole.suffix(frames * 2)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        var ints = [Int16](repeating: 0, count: frames)
        _ = ints.withUnsafeMutableBytes { chunk.copyBytes(to: $0) }
        for i in 0..<frames {
            samples[i] = Float(Int16(littleEndian: ints[i])) / 32_768
        }
        schedule(buffer)
    }

    /// Called on queue.
    private func scheduleSilence(frames: Int) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        samples.initialize(repeating: 0, count: frames)
        schedule(buffer)
    }

    /// Called on queue.
    private func schedule(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        queuedFrames += frames
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.queue.async { self.queuedFrames = max(0, self.queuedFrames - frames) }
        }
        if !player.isPlaying { player.play() }
    }
}
