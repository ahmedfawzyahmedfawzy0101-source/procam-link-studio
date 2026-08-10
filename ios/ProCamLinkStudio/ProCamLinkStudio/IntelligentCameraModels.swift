import CoreGraphics
import Foundation

enum TrackingMode: String, CaseIterable, Identifiable {
    case face = "Face"
    case person = "Person"
    case group = "Group"
    case manualSubject = "Manual"
    case autoBestSubject = "Auto Best"

    var id: String { rawValue }
}

enum TrackingLifecycle: String {
    case tracking = "TRACKING"
    case temporarilyLost = "TEMPORARILY_LOST"
    case searching = "SEARCHING"
    case reacquired = "REACQUIRED"
    case manualFallback = "MANUAL_FALLBACK"
}

enum SmartFramingMode: String, CaseIterable, Identifiable {
    case off = "Off"
    case center = "Center"
    case ruleOfThirdsLeft = "Thirds L"
    case ruleOfThirdsRight = "Thirds R"
    case headAndShoulders = "Head"
    case halfBody = "Half"
    case fullBody = "Full"
    case group = "Group"
    case creatorPortrait = "Creator"

    var id: String { rawValue }
}

struct SmartFramingSettings: Equatable {
    var mode: SmartFramingMode = .off
    var followSpeed: Double = 0.35
    var smoothness: Double = 0.65
    var deadZone: Double = 0.08
    var sensitivity: Double = 0.65
    var minDigitalZoom: Double = 1.0
    var maxDigitalZoom: Double = 1.8
    var headroom: Double = 0.12
    var lookRoom: Double = 0.08
    var horizontalBias: Double = 0
    var verticalBias: Double = 0
    var tightness: Double = 0.55
    var groupSafetyMargin: Double = 0.12
}

enum DetectedSubjectKind: String {
    case face
    case person
}

struct DetectedSubject: Identifiable, Equatable {
    let id: UUID
    var kind: DetectedSubjectKind
    var normalizedRect: CGRect
    var confidence: Float
    var velocity: CGVector = .zero
    var age: Int = 0
    var missedFrames: Int = 0
    var isSelected: Bool
}

struct TrackingState: Equatable {
    var isEnabled = true
    var mode: TrackingMode = .autoBestSubject
    var lifecycle: TrackingLifecycle = .manualFallback
    var subjects: [DetectedSubject] = []
    var selectedSubjectID: UUID?
    var selectedConfidence: Float = 0
    var reacquisitionConfidence: Float = 0
    var lastSelectedRect: CGRect?
    var predictedSelectedRect: CGRect?
    var lastUpdateTime: TimeInterval = 0
    var lockStartedAt: TimeInterval?
    var minimumLockDuration: TimeInterval = 1.25
    var isSearching = false
}

struct HorizonState: Equatable {
    var isAvailable = false
    var rollDegrees: Double = 0
    var smoothedRollDegrees: Double = 0
    var motionMagnitude: Double = 0
}

enum HorizonCorrectionMode: String, CaseIterable, Identifiable {
    case off = "Off"
    case levelAssist = "Assist"
    case horizonLock = "Lock"

    var id: String { rawValue }
}

enum DigitalStabilizationMode: String, CaseIterable, Identifiable {
    case off = "Off"
    case low = "Low"
    case medium = "Medium"
    case strong = "Strong"

    var id: String { rawValue }
}

enum PipelinePriorityMode: String, CaseIterable, Identifiable {
    case quality = "Quality"
    case balanced = "Balanced"
    case fps = "FPS"

    var id: String { rawValue }
}

enum AnalysisTask: String {
    case personTracking
    case faceLandmarks
    case histogram
    case scopes
}

struct StabilizationSettings: Equatable {
    var horizonMode: HorizonCorrectionMode = .off
    var digitalMode: DigitalStabilizationMode = .off
    var strength: Double = 0.5
    var smoothing: Double = 0.75
    var maxCorrectionAngle: Double = 8
    var cropSafetyMargin: Double = 0.08
}

struct PerformanceBudgetState: Equatable {
    var priority: PipelinePriorityMode = .balanced
    var targetFPS: Double = 30
    var trackingAnalysisMS: Double = 0
    var gpuProcessingMS: Double = 0
    var stabilizationMS: Double = 0
    var totalFrameBudgetMS: Double { targetFPS >= 50 ? 16.7 : 33.3 }
    var warning: String?
}
