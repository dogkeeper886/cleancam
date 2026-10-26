import CoreImage
import VideoToolbox

/// Hardware H.264 encoder. Hands out each frame as an Annex-B byte stream, the format ffmpeg reads with `-f h264`.
/// The stream is always 1920x1080 so the PC's webcam never changes size; portrait frames get black bars.
final class H264Encoder {
    var onEncoded: ((_ data: Data, _ isKeyframe: Bool) -> Void)?
    /// Called on the video queue with each event the debug port reports: the rate settings and what the session took
    /// of them, and each step down or up.
    var onEvent: (([String: Any]) -> Void)?

    /// The rate settings the debug port reports.
    private static let reportedKeys = [
        kVTCompressionPropertyKey_AverageBitRate, kVTCompressionPropertyKey_DataRateLimits,
        kVTCompressionPropertyKey_ExpectedFrameRate, kVTCompressionPropertyKey_MaxKeyFrameInterval,
        kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
    ]
    private static let width = 1920
    private static let height = 1080
    private static let startCode: [UInt8] = [0, 0, 0, 1]
    /// The target bitrate at 30 fps, about 0.16 bits per pixel in each frame; the target scales with the frame rate.
    private static let targetAt30fps = 10_000_000
    /// A backlog past this many sends, of the server's 30, means the link carries less than the stream sends.
    private static let congestedBacklog = 10
    /// Seconds without any backlog before the bitrate steps back up.
    private static let recoverySeconds = 10
    /// Each step changes the bitrate by this share.
    private static let step = 0.2
    /// The lowest share of the target the bitrate steps down to.
    private static let floorShare = 0.2

    // Used on the video queue only.
    /// The camera's top frame rate; rate control and keyframes plan around it.
    private(set) var frameRate = 30
    /// The bitrate the encoder aims for now, at or below the target.
    private(set) var bitRate = H264Encoder.targetAt30fps
    /// Set by the debug port's `bitrate` command; adaptation leaves the bitrate alone until `unpin`.
    private(set) var isPinned = false
    private var secondsWithoutBacklog = 0
    private var session: VTCompressionSession?
    private let ciContext = CIContext()
    private var letterboxPool: CVPixelBufferPool?

    private let lock = NSLock()
    private var keyframeRequested = false
    private var outputBytes = 0
    private var outputFrames = 0
    private var outputKeyframes = 0

    func requestKeyframe() {
        lock.lock()
        keyframeRequested = true
        lock.unlock()
    }

    /// The bytes, frames and keyframes handed out since the last call.
    func takeOutput() -> (bytes: Int, frames: Int, keyframes: Int) {
        lock.lock()
        let output = (bytes: outputBytes, frames: outputFrames, keyframes: outputKeyframes)
        outputBytes = 0
        outputFrames = 0
        outputKeyframes = 0
        lock.unlock()
        return output
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let source = CMSampleBufferGetImageBuffer(sampleBuffer),
              let imageBuffer = fitToStream(source) else { return }
        if session == nil { session = makeSession() }
        guard let session else { return }

        lock.lock()
        let forceKeyframe = keyframeRequested
        keyframeRequested = false
        lock.unlock()
        let frameProperties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] status, _, encoded in
            guard status == noErr, let encoded else { return }
            self?.emit(encoded)
        }
        // The session stops working after the app has been in the background; make a new one on the next frame.
        if status != noErr { reset() }
    }

    func reset() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    /// Plans rate control and keyframes around the camera's top frame rate, and restarts the bitrate at its target unless
    /// the debug port holds it. The next frame starts a new session, so the H.264 level the session picks as it starts
    /// fits the new rate.
    func setFrameRate(_ rate: Int) {
        guard rate > 0, rate != frameRate else { return }
        frameRate = rate
        if !isPinned { bitRate = targetBitRate }
        secondsWithoutBacklog = 0
        reset()
    }

    /// Holds the bitrate at `rate` until `unpin`, for the debug port.
    func pin(bitRate rate: Int) {
        isPinned = true
        bitRate = rate
        applyRates(reason: "pin")
    }

    /// Hands the bitrate back to adaptation, from where it is.
    func unpin() {
        isPinned = false
        secondsWithoutBacklog = 0
    }

    /// Called once a second with the most sends any client had waiting.
    /// Steps the bitrate down while a client falls behind, and back up after `recoverySeconds` without a backlog.
    func adapt(toBacklog backlog: Int) {
        guard !isPinned else { return }
        var next = bitRate
        if backlog > Self.congestedBacklog {
            secondsWithoutBacklog = 0
            next = max(Int(Double(bitRate) * (1 - Self.step)), Int(Double(targetBitRate) * Self.floorShare))
        } else if backlog > 0 {
            secondsWithoutBacklog = 0
        } else {
            secondsWithoutBacklog += 1
            guard secondsWithoutBacklog >= Self.recoverySeconds else { return }
            secondsWithoutBacklog = 0
            // One step up undoes one step down.
            next = min(Int(Double(bitRate) / (1 - Self.step)), targetBitRate)
        }
        guard next != bitRate else { return }
        let reason = next < bitRate ? "down" : "up"
        bitRate = next
        applyRates(reason: reason)
    }

    private var targetBitRate: Int { Self.targetAt30fps * frameRate / 30 }

    /// The settings that follow the frame rate and the bitrate; a running session takes new ones live.
    private var rateProperties: [CFString: Any] {
        [
            kVTCompressionPropertyKey_AverageBitRate: bitRate,
            // In bytes: any one second at 1.5 times the average, so a burst can't swamp the link, and any 5 s at the
            // average itself, which the iPhone 7's encoder overshoots by 40% under AverageBitRate alone.
            kVTCompressionPropertyKey_DataRateLimits: [bitRate * 3 / 2 / 8, 1, bitRate / 8 * 5, 5] as CFArray,
            kVTCompressionPropertyKey_ExpectedFrameRate: frameRate,
            // A keyframe every 2 s, also while the camera slows in the dark.
            kVTCompressionPropertyKey_MaxKeyFrameInterval: frameRate * 2,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2,
        ]
    }

    private func applyRates(reason: String) {
        guard let session else { return }
        let properties = rateProperties
        let status = VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary)
        report(properties, status: status, session: session, reason: reason)
    }

    /// Tells the debug port which rate settings were asked for, what VTSessionSetProperties returned, and what the
    /// session reports back for each, since an encoder can leave out a setting it doesn't support.
    private func report(_ properties: [CFString: Any], status: OSStatus, session: VTCompressionSession, reason: String) {
        guard let onEvent else { return }
        var asked: [String: Any] = [:]
        var took: [String: Any] = [:]
        for key in Self.reportedKeys {
            asked[key as String] = properties[key]
            var value: CFTypeRef?
            let copyStatus = VTSessionCopyProperty(session, key: key, allocator: nil, valueOut: &value)
            if copyStatus != noErr {
                took[key as String] = "error \(copyStatus)"
            } else if let value {
                took[key as String] = JSONSerialization.isValidJSONObject([value]) ? value as Any : "\(value)"
            } else {
                took[key as String] = NSNull()
            }
        }
        onEvent(["event": "rates", "reason": reason, "status": Int(status), "asked": asked, "took": took])
    }

    /// Scales a frame of any other size (mainly a portrait frame) into the middle of a black 1920x1080 frame.
    private func fitToStream(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        if CVPixelBufferGetWidth(source) == Self.width && CVPixelBufferGetHeight(source) == Self.height {
            return source
        }
        if letterboxPool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Self.width,
                kCVPixelBufferHeightKey as String: Self.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &letterboxPool)
        }
        var output: CVPixelBuffer?
        guard let letterboxPool,
              CVPixelBufferPoolCreatePixelBuffer(nil, letterboxPool, &output) == kCVReturnSuccess,
              let output else { return nil }

        let frame = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
        let image = CIImage(cvPixelBuffer: source)
        let scale = min(frame.width / image.extent.width, frame.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centered = scaled.transformed(by: CGAffineTransform(
            translationX: (frame.width - scaled.extent.width) / 2, y: (frame.height - scaled.extent.height) / 2))
        ciContext.render(centered.composited(over: CIImage(color: .black).cropped(to: frame)), to: output)
        return output
    }

    private func makeSession() -> VTCompressionSession? {
        var session: VTCompressionSession?
        VTCompressionSessionCreate(
            allocator: nil, width: Int32(Self.width), height: Int32(Self.height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard let session else { return nil }
        var properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,  // no B-frames, less delay
        ]
        properties.merge(rateProperties) { $1 }
        let status = VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary)
        report(properties, status: status, session: session, reason: "start")
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }

    /// Converts the encoder's length-prefixed NAL units to start-code-prefixed ones,
    /// and puts SPS/PPS in front of every keyframe so a viewer can join at any keyframe.
    private func emit(_ sampleBuffer: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return }
        var avcc = Data(count: length)
        let status = avcc.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
        }
        guard status == noErr else { return }

        var nalUnits = Data()
        var isKeyframe = false
        var offset = 0
        while offset + 4 <= avcc.count {
            let size = avcc[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            offset += 4
            guard size > 0, offset + size <= avcc.count else { break }
            if avcc[offset] & 0x1F == 5 { isKeyframe = true }  // IDR slice
            nalUnits.append(contentsOf: Self.startCode)
            nalUnits.append(avcc[offset..<offset + size])
            offset += size
        }

        var output = Data()
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            output.append(Self.parameterSets(of: format))
        }
        output.append(nalUnits)
        lock.lock()
        outputBytes += output.count
        outputFrames += 1
        if isKeyframe { outputKeyframes += 1 }
        lock.unlock()
        onEncoded?(output, isKeyframe)
    }

    private static func parameterSets(of format: CMFormatDescription) -> Data {
        var data = Data()
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                let pointer else { continue }
            data.append(contentsOf: startCode)
            data.append(pointer, count: size)
        }
        return data
    }
}
