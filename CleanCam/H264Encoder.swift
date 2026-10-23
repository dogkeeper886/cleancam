import VideoToolbox

/// Hardware H.264 encoder. Hands out each frame as an Annex-B byte stream, the format ffmpeg reads with `-f h264`.
final class H264Encoder {
    var onEncoded: ((_ data: Data, _ isKeyframe: Bool) -> Void)?

    private static let startCode: [UInt8] = [0, 0, 0, 1]

    // Used on the video queue only.
    private var session: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0

    private let lock = NSLock()
    private var keyframeRequested = false

    func requestKeyframe() {
        lock.lock()
        keyframeRequested = true
        lock.unlock()
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = Int32(CVPixelBufferGetWidth(imageBuffer))
        let height = Int32(CVPixelBufferGetHeight(imageBuffer))
        if session == nil || width != self.width || height != self.height {
            reset()
            session = Self.makeSession(width: width, height: height)
            self.width = width
            self.height = height
        }
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

    private static func makeSession(width: Int32, height: Int32) -> VTCompressionSession? {
        var session: VTCompressionSession?
        VTCompressionSessionCreate(
            allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_H264,
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
