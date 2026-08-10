import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

struct EncodedVideoFrame {
    let data: Data
    let presentationTime: CMTime
    let duration: CMTime
    let isKeyFrame: Bool
}

struct VideoEncoderConfiguration: Equatable {
    var codec: RecordingCodec
    var width: Int
    var height: Int
    var bitRate: Int
    var fps: Int
    var keyFrameInterval: Int

    static func streamingDefault(codec: RecordingCodec, width: Int, height: Int, fps: Int) -> VideoEncoderConfiguration {
        let megapixels = Double(width * height) / 1_000_000
        let baseMbps = megapixels >= 8 ? 18.0 : 8.0
        return VideoEncoderConfiguration(
            codec: codec,
            width: width,
            height: height,
            bitRate: Int(baseMbps * (codec == .hevc ? 0.72 : 1.0) * 1_000_000),
            fps: fps,
            keyFrameInterval: max(1, fps * 2)
        )
    }
}

final class VideoToolboxEncoder {
    var onFrame: ((EncodedVideoFrame) -> Void)?
    var onError: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "studio.procamlink.video-toolbox-encoder")
    private var compressionSession: VTCompressionSession?
    private var configuration: VideoEncoderConfiguration?

    func configure(_ configuration: VideoEncoderConfiguration) {
        queue.async {
            self.invalidateSession()
            var session: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: nil,
                width: Int32(configuration.width),
                height: Int32(configuration.height),
                codecType: configuration.codec.cmCodecType,
                encoderSpecification: nil,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: videoToolboxOutputCallback,
                refcon: Unmanaged.passUnretained(self).toOpaque(),
                compressionSessionOut: &session
            )
            guard status == noErr, let session else {
                self.onError?(VideoToolboxEncoderError.sessionCreateFailed(status))
                return
            }

            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: configuration.codec.profileLevel)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: configuration.bitRate))
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: configuration.keyFrameInterval))
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            VTCompressionSessionPrepareToEncodeFrames(session)

            self.configuration = configuration
            self.compressionSession = session
        }
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime, duration: CMTime = .invalid) {
        queue.async {
            guard let compressionSession = self.compressionSession else { return }
            let status = VTCompressionSessionEncodeFrame(
                compressionSession,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: presentationTime,
                duration: duration,
                frameProperties: nil,
                sourceFrameRefcon: nil,
                infoFlagsOut: nil
            )
            guard status == noErr else {
                self.onError?(VideoToolboxEncoderError.encodeFailed(status))
                return
            }
        }
    }

    func finish() {
        queue.async {
            guard let compressionSession = self.compressionSession else { return }
            VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
            self.invalidateSession()
        }
    }

    fileprivate func handleEncoded(sampleBuffer: CMSampleBuffer) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return }

        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: baseAddress)
        }
        guard status == noErr else {
            onError?(VideoToolboxEncoderError.copyDataFailed(status))
            return
        }

        onFrame?(
            EncodedVideoFrame(
                data: data,
                presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                duration: CMSampleBufferGetDuration(sampleBuffer),
                isKeyFrame: sampleBuffer.isKeyFrame
            )
        )
    }

    private func invalidateSession() {
        if let compressionSession {
            VTCompressionSessionInvalidate(compressionSession)
        }
        compressionSession = nil
        configuration = nil
    }
}

enum VideoToolboxEncoderError: LocalizedError {
    case sessionCreateFailed(OSStatus)
    case encodeFailed(OSStatus)
    case copyDataFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .sessionCreateFailed(let status):
            return "VideoToolbox session creation failed with OSStatus \(status)."
        case .encodeFailed(let status):
            return "VideoToolbox encode failed with OSStatus \(status)."
        case .copyDataFailed(let status):
            return "Encoded sample copy failed with OSStatus \(status)."
        }
    }
}

private let videoToolboxOutputCallback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
    guard status == noErr,
          let refcon,
          let sampleBuffer,
          CMSampleBufferDataIsReady(sampleBuffer) else {
        return
    }
    let encoder = Unmanaged<VideoToolboxEncoder>.fromOpaque(refcon).takeUnretainedValue()
    encoder.handleEncoded(sampleBuffer: sampleBuffer)
}

private extension RecordingCodec {
    var cmCodecType: CMVideoCodecType {
        switch self {
        case .h264:
            return kCMVideoCodecType_H264
        case .hevc:
            return kCMVideoCodecType_HEVC
        }
    }

    var profileLevel: CFString {
        switch self {
        case .h264:
            return kVTProfileLevel_H264_High_AutoLevel
        case .hevc:
            return kVTProfileLevel_HEVC_Main_AutoLevel
        }
    }
}

private extension CMSampleBuffer {
    var isKeyFrame: Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[String: Any]],
              let first = attachments.first else {
            return true
        }
        return !(first[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false)
    }
}
