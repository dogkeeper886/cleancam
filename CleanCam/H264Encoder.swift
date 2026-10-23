import CoreImage
import VideoToolbox

/// Hardware H.264 encoder. Hands out each frame as an Annex-B byte stream, the format ffmpeg reads with `-f h264`.
/// The stream is always 1920x1080 so the PC's webcam never changes size; portrait frames get black bars.
final class H264Encoder {
    var onEncoded: ((_ data: Data, _ isKeyframe: Bool) -> Void)?

    private static let width = 1920
    private static let height = 1080
    private static let startCode: [UInt8] = [0, 0, 0, 1]

    // Used on the video queue only.
    private var session: VTCompressionSession?
    private let ciContext = CIContext()
    private var letterboxPool: CVPixelBufferPool?

    private let lock = NSLock()
    private var keyframeRequested = false

    func requestKeyframe() {
        lock.lock()
        keyframeRequested = true
        lock.unlock()
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let source = CMSampleBufferGetImageBuffer(sampleBuffer),
              let imageBuffer = fitToStream(source) else { return }
        if session == nil { session = Self.makeSession() }
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

    private static func makeSession() -> VTCompressionSession? {
        var session: VTCompressionSession?
        VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard let session else { return nil }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,  // no B-frames, less delay
            kVTCompressionPropertyKey_AverageBitRate: 10_000_000,
            kVTCompressionPropertyKey_ExpectedFrameRate: 30,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 60,
        ]
        VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary)
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
