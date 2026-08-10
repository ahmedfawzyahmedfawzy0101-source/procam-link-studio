import CoreGraphics
import Foundation

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
    var tightness: Double = 0.55
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
    var isSelected: Bool
}

struct TrackingState: Equatable {
    var isEnabled = true
    var subjects: [DetectedSubject] = []
    var selectedSubjectID: UUID?
    var selectedConfidence: Float = 0
    var lastSelectedRect: CGRect?
    var lastUpdateTime: TimeInterval = 0
    var isSearching = false
}

struct HorizonState: Equatable {
    var isAvailable = false
    var rollDegrees: Double = 0
}
