import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

struct ProcessedRecordingStats: Equatable {
    var encodedFrames: Int = 0
    var droppedFrames: Int = 0
    var outputWidth: Int = 0
    var outputHeight: Int = 0
    var lastPresentationTime: CMTime = .zero
}

final class ProcessedMasterRecorder {
    var onStats: ((ProcessedRecordingStats) -> Void)?
    var onFinish: ((URL?, Error?) -> Void)?

    private let queue = DispatchQueue(label: "studio.procamlink.processed-recorder")
    private let pipeline = ProcessedFramePipeline()
    private let ciContext = CIContext()
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?
    private var startTime: CMTime?
    private var stats = ProcessedRecordingStats()
    private var colorSpace = CGColorSpaceCreateDeviceRGB()

    var isRecording: Bool {
        queue.sync { writer != nil }
    }

    func start(url: URL, codec: RecordingCodec, quality: RecordingQualityPreset, sourceWidth: Int, sourceHeight: Int) {
        queue.async {
            guard self.writer == nil else { return }
            do {
                let dimensions = quality.dimensions(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
                let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
                let compression: [String: Any] = [
                    AVVideoAverageBitRateKey: quality.bitRate(codec: codec, width: dimensions.width, height: dimensions.height),
                    AVVideoMaxKeyFrameIntervalKey: 60,
                    AVVideoAllowFrameReorderingKey: false
                ]
                let settings: [String: Any] = [
                    AVVideoCodecKey: codec.avCodec,
                    AVVideoWidthKey: dimensions.width,
                    AVVideoHeightKey: dimensions.height,
                    AVVideoCompressionPropertiesKey: compression
                ]
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
                input.expectsMediaDataInRealTime = true
                guard writer.canAdd(input) else {
                    throw ProcessedRecordingError.unsupportedWriterInput
                }
                writer.add(input)

                let attributes: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: dimensions.width,
                    kCVPixelBufferHeightKey as String: dimensions.height,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ]
                self.pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: input,
                    sourcePixelBufferAttributes: attributes
                )
                self.writer = writer
                self.videoInput = input
                self.outputURL = url
                self.startTime = nil
                self.stats = ProcessedRecordingStats(
                    outputWidth: dimensions.width,
                    outputHeight: dimensions.height
                )
                self.emitStats()
            } catch {
                self.onFinish?(nil, error)
            }
        }
    }

    func append(pixelBuffer: CVPixelBuffer, timestamp: CMTime, state: FrameProcessingState) {
        queue.async {
            guard let writer = self.writer,
                  let videoInput = self.videoInput,
                  let pixelBufferAdaptor = self.pixelBufferAdaptor else {
                return
            }

            if writer.status == .unknown {
                self.startTime = timestamp
                writer.startWriting()
                writer.startSession(atSourceTime: timestamp)
            }

            guard writer.status == .writing else {
                self.finishWithCurrentWriter(error: writer.error)
                return
            }

            guard videoInput.isReadyForMoreMediaData else {
                self.stats.droppedFrames += 1
                self.emitStats()
                return
            }

            guard let pool = pixelBufferAdaptor.pixelBufferPool else {
                self.stats.droppedFrames += 1
                self.emitStats()
                return
            }

            var outputBuffer: CVPixelBuffer?
            let result = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
            guard result == kCVReturnSuccess, let outputBuffer else {
                self.stats.droppedFrames += 1
                self.emitStats()
                return
            }

            let renderSize = CGSize(width: self.stats.outputWidth, height: self.stats.outputHeight)
            let renderState = FrameProcessingState(
                orientation: state.orientation,
                adjustments: state.adjustments,
                framing: state.framing,
                tracking: state.tracking,
                horizon: state.horizon,
                stabilization: state.stabilization,
                monitoring: state.monitoring,
                includeMonitoring: false
            )
            let image = self.pipeline
                .makeImage(pixelBuffer: pixelBuffer, state: renderState)
                .transformedForDisplay(in: renderSize, fillMode: .fill)

            self.ciContext.render(
                image,
                to: outputBuffer,
                bounds: CGRect(origin: .zero, size: renderSize),
                colorSpace: self.colorSpace
            )

            if pixelBufferAdaptor.append(outputBuffer, withPresentationTime: timestamp) {
                self.stats.encodedFrames += 1
                self.stats.lastPresentationTime = timestamp
            } else {
                self.stats.droppedFrames += 1
            }
            self.emitStats()
        }
    }

    func stop() {
        queue.async {
            self.finishWithCurrentWriter(error: nil)
        }
    }

    private func finishWithCurrentWriter(error: Error?) {
        guard let writer else { return }
        let url = outputURL
        let finish = onFinish
        videoInput?.markAsFinished()
        self.writer = nil
        videoInput = nil
        pixelBufferAdaptor = nil
        outputURL = nil
        startTime = nil

        if let error {
            writer.cancelWriting()
            finish?(url, error)
            return
        }

        writer.finishWriting {
            finish?(writer.status == .completed ? url : nil, writer.error)
        }
    }

    private func emitStats() {
        onStats?(stats)
    }
}

enum ProcessedRecordingError: LocalizedError {
    case unsupportedWriterInput

    var errorDescription: String? {
        switch self {
        case .unsupportedWriterInput:
            return "Processed recording settings are not supported by AVAssetWriter."
        }
    }
}
