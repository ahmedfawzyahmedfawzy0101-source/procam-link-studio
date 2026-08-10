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
