import AVFoundation
import CoreMedia
import CoreGraphics
import Foundation

enum PreviewFillMode: String, CaseIterable, Identifiable {
    case fit = "Fit"
    case fill = "Fill"

    var id: String { rawValue }
}

enum StudioPanel: String, CaseIterable, Identifiable {
    case camera = "Camera"
    case video = "Video"
    case image = "Image"
    case monitoring = "Monitoring"
    case app = "App"

    var id: String { rawValue }
}

enum TorchSetting: Equatable {
    case off
    case on(level: Float)
}

enum ExposureControlMode: String, CaseIterable, Identifiable {
    case continuousAuto = "Auto"
    case locked = "Lock"
    case manual = "Manual"

    var id: String { rawValue }
}

enum FocusControlMode: String, CaseIterable, Identifiable {
    case continuousAuto = "AF-C"
    case locked = "Lock"
    case manual = "Manual"

    var id: String { rawValue }
}

enum WhiteBalanceControlMode: String, CaseIterable, Identifiable {
    case continuousAuto = "Auto"
    case locked = "Lock"
    case manual = "Manual"

    var id: String { rawValue }
}

enum RecordingCodec: String, CaseIterable, Identifiable {
    case h264 = "H.264"
    case hevc = "HEVC"

    var id: String { rawValue }

    var avCodec: AVVideoCodecType {
        switch self {
        case .h264:
            return .h264
        case .hevc:
            return .hevc
        }
    }
}

struct CameraCapabilities: Equatable {
    var minZoom: CGFloat
    var maxZoom: CGFloat
    var neutralZoom: CGFloat
    var hasTorch: Bool
    var supportsVariableTorch: Bool
    var supportsTapFocus: Bool
    var supportsManualFocus: Bool
    var supportsExposurePoint: Bool
    var supportsManualExposure: Bool
    var supportsExposureBias: Bool
    var supportsWhiteBalanceLock: Bool
    var supportsManualWhiteBalance: Bool
    var minISO: Float
    var maxISO: Float
    var minExposureSeconds: Double
    var maxExposureSeconds: Double
    var minExposureBias: Float
    var maxExposureBias: Float
    var supportsHDR: Bool

    static let empty = CameraCapabilities(
        minZoom: 1,
        maxZoom: 1,
        neutralZoom: 1,
        hasTorch: false,
        supportsVariableTorch: false,
        supportsTapFocus: false,
        supportsManualFocus: false,
        supportsExposurePoint: false,
        supportsManualExposure: false,
        supportsExposureBias: false,
        supportsWhiteBalanceLock: false,
        supportsManualWhiteBalance: false,
        minISO: 0,
        maxISO: 0,
        minExposureSeconds: 0,
        maxExposureSeconds: 0,
        minExposureBias: 0,
        maxExposureBias: 0,
        supportsHDR: false
    )
}

struct CameraFormatOption: Identifiable, Equatable {
    let id: String
    let format: AVCaptureDevice.Format
    let width: Int32
    let height: Int32
    let minFPS: Double
    let maxFPS: Double
    let pixelFormat: String
    let supportsHDR: Bool

    var label: String {
        let resolution = resolutionLabel(width: width, height: height)
        let fps = minFPS == maxFPS ? "\(Int(maxFPS)) fps" : "\(Int(minFPS))-\(Int(maxFPS)) fps"
        let hdr = supportsHDR ? " HDR" : ""
        return "\(resolution) \(fps)\(hdr)"
    }

    var sortScore: Int {
        Int(width * height) * 1000 + Int(maxFPS)
    }

    static func == (lhs: CameraFormatOption, rhs: CameraFormatOption) -> Bool {
        lhs.id == rhs.id
    }

    static func make(format: AVCaptureDevice.Format, index: Int) -> CameraFormatOption {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let ranges = format.videoSupportedFrameRateRanges
        let minFPS = ranges.map(\.minFrameRate).min() ?? 0
        let maxFPS = ranges.map(\.maxFrameRate).max() ?? 0
        let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)

        return CameraFormatOption(
            id: "\(index)-\(dimensions.width)x\(dimensions.height)-\(maxFPS)-\(subtype)",
            format: format,
            width: dimensions.width,
            height: dimensions.height,
            minFPS: minFPS,
            maxFPS: maxFPS,
            pixelFormat: fourCC(subtype),
            supportsHDR: format.isVideoHDRSupported
        )
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff)
        ]
        return String(bytes: bytes, encoding: .macOSRoman) ?? "\(code)"
    }

    private func resolutionLabel(width: Int32, height: Int32) -> String {
        let longEdge = max(width, height)
        switch longEdge {
        case 3840...:
            return "4K"
        case 1920..<3840:
            return "1080p"
        case 1280..<1920:
            return "720p"
        default:
            return "\(width)x\(height)"
        }
    }
}

struct ExposureState: Equatable {
    var mode: ExposureControlMode = .continuousAuto
    var iso: Float = 0
    var shutterSeconds: Double = 1.0 / 60.0
    var exposureBias: Float = 0
}

struct FocusState: Equatable {
    var mode: FocusControlMode = .continuousAuto
    var lensPosition: Float = 0.5
    var focusPoint: CGPoint?
}

struct WhiteBalanceState: Equatable {
    var mode: WhiteBalanceControlMode = .continuousAuto
    var temperature: Float = 5600
    var tint: Float = 0
}

struct MonitoringState: Equatable {
    var grid = true
    var centerMarker = true
    var showThermal = true
}

enum LookPreset: String, CaseIterable, Identifiable {
    case natural = "Natural"
    case clean = "Clean"
    case soft = "Soft"
    case warm = "Warm"
    case cool = "Cool"
    case cinematic = "Cinematic"
    case highContrast = "High Contrast"
    case mono = "Mono"

    var id: String { rawValue }
}

struct ImageAdjustmentState: Equatable {
    var exposure: Double = 0
    var contrast: Double = 1
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var saturation: Double = 1
    var vibrance: Double = 0
    var temperature: Double = 0
    var tint: Double = 0
    var sharpness: Double = 0
    var denoise: Double = 0
    var gamma: Double = 1
    var vignette: Double = 0
    var look: LookPreset = .natural
    var lookIntensity: Double = 0

    static let neutral = ImageAdjustmentState()
}

struct ThermalStateLabel: Equatable {
    let title: String
    let isRisky: Bool
}

struct RecordingState: Equatable {
    var isRecording = false
    var elapsedSeconds: TimeInterval = 0
    var lastRecordingPath: String?
    var storageWarning: String?
}

func shutterLabel(seconds: Double) -> String {
    guard seconds > 0 else { return "-" }
    if seconds >= 1 {
        return String(format: "%.1fs", seconds)
    }

    let denominator = max(1, Int((1 / seconds).rounded()))
    return "1/\(denominator)"
}
