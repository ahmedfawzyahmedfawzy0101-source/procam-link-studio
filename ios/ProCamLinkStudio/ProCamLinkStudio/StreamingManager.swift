import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation

struct StreamingStatus: Equatable {
    var isStreaming = false
    var state: SRTConnectionState = .disconnected
    var statistics = SRTStatistics.empty
    var encodedFrames = 0
    var sentBytes = 0
    var droppedFrames = 0
    var lastError: String?
    var startedAt: Date?

    var elapsedSeconds: TimeInterval {
        startedAt.map { Date().timeIntervalSince($0) } ?? 0
    }
}

final class StreamingManager {
    var onStatusChanged: ((StreamingStatus) -> Void)?

    private let queue = DispatchQueue(label: "studio.procamlink.streaming.manager")
    private let encoder = VideoToolboxEncoder()
    private let audioEncoder = AACEncoder()
    private let transport = SRTTransport()
    private var muxer = MPEGTransportStreamMuxer(videoCodec: .h264)
    private var configuration = SRTConnectionConfiguration()
    private var videoCodec: RecordingCodec = .h264
    private var status = StreamingStatus()
    private var configuredVideoSize: (width: Int, height: Int)?
    private var frameInterval: CMTime = CMTime(value: 1, timescale: 30)
    private var lastVideoTimestamp: CMTime?

    init() {
        transport.onStateChanged = { [weak self] state in
            self?.queue.async {
                self?.status.state = state
                self?.publishStatus()
            }
        }
        transport.onStatistics = { [weak self] stats in
            self?.queue.async {
                self?.status.statistics = stats
                self?.publishStatus()
            }
        }
        encoder.onFrame = { [weak self] frame in
            self?.handleEncodedVideo(frame)
        }
        encoder.onError = { [weak self] error in
            self?.queue.async {
                self?.status.lastError = error.localizedDescription
                self?.status.droppedFrames += 1
                self?.publishStatus()
            }
        }
        audioEncoder.onFrame = { [weak self] frame in
            self?.handleEncodedAudio(frame)
        }
        audioEncoder.onError = { [weak self] error in
            self?.queue.async {
                self?.status.lastError = error.localizedDescription
                self?.publishStatus()
            }
        }
    }

    func updateConfiguration(_ configuration: SRTConnectionConfiguration) {
        queue.async {
            self.configuration = configuration
            self.transport.configure(configuration)
        }
    }

    func start(
        configuration: SRTConnectionConfiguration,
        codec: RecordingCodec,
        width: Int,
        height: Int,
        fps: Int
    ) {
        queue.async {
            self.configuration = configuration
            self.videoCodec = codec
            self.configuredVideoSize = (width, height)
            self.frameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
            self.muxer = MPEGTransportStreamMuxer(videoCodec: codec == .hevc ? .hevc : .h264)
            self.status = StreamingStatus(isStreaming: true, startedAt: Date())
            self.transport.configure(configuration)
            self.encoder.configure(
                VideoEncoderConfiguration.streamingDefault(
                    codec: codec,
                    width: width,
                    height: height,
                    fps: fps
                )
            )
            self.transport.connect()
            self.publishStatus()
        }
    }

    func stop() {
        queue.async {
            self.encoder.finish()
            self.audioEncoder.reset()
            self.transport.disconnect()
            self.muxer.reset()
            self.lastVideoTimestamp = nil
            self.status.isStreaming = false
            self.status.state = .disconnected
            self.status.startedAt = nil
            self.publishStatus()
        }
    }

    func appendVideo(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        queue.async {
            guard self.status.isStreaming else { return }
            self.lastVideoTimestamp = timestamp
            self.encoder.encode(pixelBuffer: pixelBuffer, presentationTime: timestamp, duration: self.frameInterval)
        }
    }

    func appendAudio(sampleBuffer: CMSampleBuffer) {
        queue.async {
            guard self.status.isStreaming, CMSampleBufferDataIsReady(sampleBuffer) else { return }
            self.audioEncoder.encode(sampleBuffer: sampleBuffer)
        }
    }

    private func handleEncodedVideo(_ frame: EncodedVideoFrame) {
        queue.async {
            guard self.status.isStreaming else { return }
            let payload = self.annexBVideoPayload(from: frame)
            guard !payload.isEmpty else {
                self.status.droppedFrames += 1
                self.publishStatus()
                return
            }
            let transportStream = self.muxer.muxVideo(
                TransportStreamSample(
                    payload: payload,
                    presentationTime: frame.presentationTime,
                    decodeTime: nil,
                    isKeyFrame: frame.isKeyFrame
                )
            )
            self.transport.send(transportStream, presentationTime: CMTimeGetSeconds(frame.presentationTime))
            self.status.encodedFrames += 1
            self.status.sentBytes += transportStream.count
            self.publishStatus()
        }
    }

    private func handleEncodedAudio(_ frame: EncodedAudioFrame) {
        queue.async {
            guard self.status.isStreaming else { return }
            let transportStream = self.muxer.muxAudio(
                TransportStreamSample(
                    payload: frame.data,
                    presentationTime: frame.presentationTime,
                    decodeTime: nil,
                    isKeyFrame: true
                )
            )
            self.transport.send(transportStream, presentationTime: CMTimeGetSeconds(frame.presentationTime))
            self.status.sentBytes += transportStream.count
            self.publishStatus()
        }
    }

    private func annexBVideoPayload(from frame: EncodedVideoFrame) -> Data {
        var payload = Data()
        if frame.isKeyFrame, let parameterSets = frame.parameterSets {
            for set in parameterSets {
                appendStartCode(to: &payload)
                payload.append(set)
            }
        }

        var offset = 0
        while offset + 4 <= frame.data.count {
            let length = frame.data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard length > 0, offset + length <= frame.data.count else {
                return payload
            }
            appendStartCode(to: &payload)
            payload.append(contentsOf: frame.data[offset..<(offset + length)])
            offset += length
        }
        return payload
    }

    private func appendStartCode(to data: inout Data) {
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
    }

    private func publishStatus() {
        let snapshot = status
        DispatchQueue.main.async {
            self.onStatusChanged?(snapshot)
        }
    }
}

struct EncodedAudioFrame {
    let data: Data
    let presentationTime: CMTime
    let duration: CMTime
}

final class AACEncoder {
    var onFrame: ((EncodedAudioFrame) -> Void)?
    var onError: ((Error) -> Void)?

    private var converter: AudioConverterRef?
    private var inputDescription: AudioStreamBasicDescription?
    private var outputDescription: AudioStreamBasicDescription?
    private var maxOutputPacketSize: UInt32 = 2048

    func encode(sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let inputPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return
        }

        let inputASBD = inputPointer.pointee
        do {
            try configureIfNeeded(inputASBD)
        } catch {
            onError?(error)
            return
        }

        let byteLength = CMBlockBufferGetDataLength(blockBuffer)
        guard byteLength > 0 else { return }
        var pcm = Data(count: byteLength)
        let copyStatus = pcm.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: byteLength, destination: baseAddress)
        }
        guard copyStatus == noErr else {
            onError?(AACEncoderError.copyDataFailed(copyStatus))
            return
        }

        guard let converter, let outputDescription else { return }
        var output = Data(count: Int(maxOutputPacketSize))
        let frames = UInt32(CMSampleBufferGetNumSamples(sampleBuffer))
        let inputBox = AACInputBox(data: pcm, frames: frames, inputDescription: inputASBD)
        var actualByteCount = 0
        let status = output.withUnsafeMutableBytes { outputBuffer -> OSStatus in
            guard let outputBase = outputBuffer.baseAddress else { return kAudio_ParamError }
            var outputPacketCount: UInt32 = 1
            let audioBuffer = AudioBuffer(
                mNumberChannels: outputDescription.mChannelsPerFrame,
                mDataByteSize: maxOutputPacketSize,
                mData: outputBase
            )
            var outputList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
            return pcm.withUnsafeBytes { inputBuffer -> OSStatus in
                inputBox.baseAddress = inputBuffer.baseAddress
                let fillStatus = withUnsafeMutablePointer(to: &outputList) { outputListPointer in
                    AudioConverterFillComplexBuffer(
                        converter,
                        aacInputDataProc,
                        Unmanaged.passUnretained(inputBox).toOpaque(),
                        &outputPacketCount,
                        outputListPointer,
                        nil
                    )
                }
                actualByteCount = Int(outputList.mBuffers.mDataByteSize)
                return fillStatus
            }
        }
        guard status == noErr else {
            onError?(AACEncoderError.encodeFailed(status))
            return
        }

        actualByteCount = min(actualByteCount, output.count)
        guard actualByteCount > 0 else { return }
        output.removeSubrange(actualByteCount..<output.count)

        let packet = adtsHeader(payloadLength: output.count, description: outputDescription) + output
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        onFrame?(
            EncodedAudioFrame(
                data: packet,
                presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                duration: duration.isValid ? duration : CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(inputASBD.mSampleRate))
            )
        )
    }

    func reset() {
        if let converter {
            AudioConverterDispose(converter)
        }
        converter = nil
        inputDescription = nil
        outputDescription = nil
        maxOutputPacketSize = 2048
    }

    private func configureIfNeeded(_ inputASBD: AudioStreamBasicDescription) throws {
        if let inputDescription,
           inputDescription.mSampleRate == inputASBD.mSampleRate,
           inputDescription.mChannelsPerFrame == inputASBD.mChannelsPerFrame,
           converter != nil {
            return
        }

        reset()
        var source = inputASBD
        var destination = AudioStreamBasicDescription(
            mSampleRate: inputASBD.mSampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: inputASBD.mChannelsPerFrame,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var status = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &destination)
        guard status == noErr else { throw AACEncoderError.formatInfoFailed(status) }

        var nextConverter: AudioConverterRef?
        status = AudioConverterNew(&source, &destination, &nextConverter)
        guard status == noErr, let nextConverter else { throw AACEncoderError.converterCreateFailed(status) }

        var bitRate: UInt32 = 128_000
        status = AudioConverterSetProperty(nextConverter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitRate)
        guard status == noErr else { throw AACEncoderError.bitRateFailed(status) }

        var packetSizeSize = UInt32(MemoryLayout<UInt32>.size)
        var packetSize: UInt32 = 0
        status = AudioConverterGetProperty(nextConverter, kAudioConverterPropertyMaximumOutputPacketSize, &packetSizeSize, &packetSize)
        guard status == noErr else { throw AACEncoderError.packetSizeFailed(status) }

        converter = nextConverter
        inputDescription = inputASBD
        outputDescription = destination
        maxOutputPacketSize = max(packetSize, 2048)
    }

    private func adtsHeader(payloadLength: Int, description: AudioStreamBasicDescription) -> Data {
        let sampleRateIndex = adtsSampleRateIndex(Int(description.mSampleRate.rounded()))
        let channelConfig = UInt8(max(1, min(description.mChannelsPerFrame, 7)))
        let frameLength = payloadLength + 7
        let profile: UInt8 = 1
        return Data([
            0xFF,
            0xF1,
            UInt8((profile << 6) | (sampleRateIndex << 2) | (channelConfig >> 2)),
            UInt8(((channelConfig & 0x03) << 6) | UInt8((frameLength >> 11) & 0x03)),
            UInt8((frameLength >> 3) & 0xFF),
            UInt8(((frameLength & 0x07) << 5) | 0x1F),
            0xFC
        ])
    }

    private func adtsSampleRateIndex(_ sampleRate: Int) -> UInt8 {
        switch sampleRate {
        case 96_000: return 0
        case 88_200: return 1
        case 64_000: return 2
        case 48_000: return 3
        case 44_100: return 4
        case 32_000: return 5
        case 24_000: return 6
        case 22_050: return 7
        case 16_000: return 8
        case 12_000: return 9
        case 11_025: return 10
        case 8_000: return 11
        default: return 4
        }
    }
}

private final class AACInputBox {
    let data: Data
    let frames: UInt32
    let inputDescription: AudioStreamBasicDescription
    var baseAddress: UnsafeRawPointer?
    var consumed = false

    init(data: Data, frames: UInt32, inputDescription: AudioStreamBasicDescription) {
        self.data = data
        self.frames = frames
        self.inputDescription = inputDescription
    }
}

private let aacInputDataProc: AudioConverterComplexInputDataProc = { _, packetCount, ioData, _, userData in
    guard let userData else { return kAudio_ParamError }
    let input = Unmanaged<AACInputBox>.fromOpaque(userData).takeUnretainedValue()
    guard !input.consumed, let baseAddress = input.baseAddress else {
        packetCount.pointee = 0
        return noErr
    }
    input.consumed = true
    packetCount.pointee = input.frames
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mNumberChannels = input.inputDescription.mChannelsPerFrame
    ioData.pointee.mBuffers.mDataByteSize = UInt32(input.data.count)
    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: baseAddress)
    return noErr
}

enum AACEncoderError: LocalizedError {
    case formatInfoFailed(OSStatus)
    case converterCreateFailed(OSStatus)
    case bitRateFailed(OSStatus)
    case packetSizeFailed(OSStatus)
    case copyDataFailed(OSStatus)
    case encodeFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .formatInfoFailed(let status):
            return "AAC format setup failed with OSStatus \(status)."
        case .converterCreateFailed(let status):
            return "AAC converter creation failed with OSStatus \(status)."
        case .bitRateFailed(let status):
            return "AAC bitrate setup failed with OSStatus \(status)."
        case .packetSizeFailed(let status):
            return "AAC packet size lookup failed with OSStatus \(status)."
        case .copyDataFailed(let status):
            return "Audio sample copy failed with OSStatus \(status)."
        case .encodeFailed(let status):
            return "AAC encode failed with OSStatus \(status)."
        }
    }
}
