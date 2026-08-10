import AVFoundation
import CoreGraphics
import CoreMotion
import Foundation
import QuartzCore
import Vision

final class IntelligentCameraManager {
    var onSubjectsUpdated: ((TrackingState) -> Void)?
    var onHorizonUpdated: ((HorizonState) -> Void)?
    var onPerformanceUpdated: ((PerformanceBudgetState) -> Void)?

    private let visionQueue = DispatchQueue(label: "studio.procamlink.vision", qos: .userInitiated)
    private let motionManager = CMMotionManager()
    private let scheduler = AnalysisScheduler()
    private var trackingState = TrackingState()
    private var smoothedRollDegrees = 0.0
    private var performance = PerformanceBudgetState()

    func setTrackingMode(_ mode: TrackingMode) {
        trackingState.mode = mode
        if mode == .group {
            trackingState.selectedSubjectID = nil
            trackingState.lifecycle = .tracking
        } else if mode == .autoBestSubject {
            trackingState.selectedSubjectID = trackingState.subjects.max(by: { $0.confidence < $1.confidence })?.id
        }
        onSubjectsUpdated?(trackingState)
    }

    func startMotion() {
        guard motionManager.isDeviceMotionAvailable else {
            onHorizonUpdated?(HorizonState(isAvailable: false, rollDegrees: 0))
            return
        }

        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let roll = motion.attitude.roll * 180 / .pi
            let rotationRate = motion.rotationRate
            let magnitude = sqrt(rotationRate.x * rotationRate.x + rotationRate.y * rotationRate.y + rotationRate.z * rotationRate.z)
            self?.smoothedRollDegrees = (self?.smoothedRollDegrees ?? roll) * 0.86 + roll * 0.14
            self?.onHorizonUpdated?(HorizonState(isAvailable: true, rollDegrees: roll, smoothedRollDegrees: self?.smoothedRollDegrees ?? roll, motionMagnitude: magnitude))
        }
    }

    func stopMotion() {
        motionManager.stopDeviceMotionUpdates()
    }

    func analyze(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard scheduler.shouldRun(.personTracking, fps: trackingState.mode == .face ? 20 : 15) else { return }

        visionQueue.async { [weak self] in
            let start = CACurrentMediaTime()
            self?.performVision(pixelBuffer: pixelBuffer, timestamp: timestamp)
            let duration = (CACurrentMediaTime() - start) * 1000
            DispatchQueue.main.async {
                self?.updatePerformance(trackingMS: duration)
            }
        }
    }

    func selectSubject(at normalizedPoint: CGPoint) {
        guard let subject = trackingState.subjects.min(by: {
            $0.normalizedRect.center.distance(to: normalizedPoint) < $1.normalizedRect.center.distance(to: normalizedPoint)
        }) else {
            return
        }

        trackingState.selectedSubjectID = subject.id
        trackingState.mode = .manualSubject
        trackingState.lifecycle = .tracking
        trackingState.lockStartedAt = CACurrentMediaTime()
        trackingState.lastSelectedRect = subject.normalizedRect
        trackingState.predictedSelectedRect = subject.normalizedRect
        trackingState.selectedConfidence = subject.confidence
        trackingState.subjects = trackingState.subjects.map { existing in
            var next = existing
            next.isSelected = existing.id == subject.id
            return next
        }
        onSubjectsUpdated?(trackingState)
    }

    private func performVision(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        let faceRequest = VNDetectFaceRectanglesRequest()
        let humanRequest = VNDetectHumanRectanglesRequest()
        humanRequest.upperBodyOnly = false

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        do {
            try handler.perform([faceRequest, humanRequest])
        } catch {
            return
        }

        let faces = (faceRequest.results ?? []).map {
            DetectedSubject(id: UUID(), kind: .face, normalizedRect: $0.boundingBox.cgRectFromVision, confidence: $0.confidence, isSelected: false)
        }
        let humans = (humanRequest.results ?? []).map {
            DetectedSubject(id: UUID(), kind: .person, normalizedRect: $0.boundingBox.cgRectFromVision, confidence: $0.confidence, isSelected: false)
        }

        let detected: [DetectedSubject]
        switch trackingState.mode {
        case .face:
            detected = faces
        case .person, .group:
            detected = humans.isEmpty ? faces : humans
        case .manualSubject, .autoBestSubject:
            detected = faces + humans
        }
        DispatchQueue.main.async { [weak self] in
            self?.mergeSubjects(detected, timestamp: timestamp)
        }
    }

    private func mergeSubjects(_ detected: [DetectedSubject], timestamp: CMTime) {
        let previous = trackingState.subjects
        let selectedID = trackingState.selectedSubjectID
        let time = CMTimeGetSeconds(timestamp)
        let deltaTime = max(1.0 / 60.0, time - trackingState.lastUpdateTime)

        var merged = detected.map { subject -> DetectedSubject in
            var next = subject
            if let match = bestMatch(for: subject, previous: previous, selectedID: selectedID, deltaTime: deltaTime) {
                let velocity = CGVector(
                    dx: (subject.normalizedRect.midX - match.normalizedRect.midX) / deltaTime,
                    dy: (subject.normalizedRect.midY - match.normalizedRect.midY) / deltaTime
                ).damped(maxMagnitude: 0.9)
                next = DetectedSubject(
                    id: match.id,
                    kind: subject.kind,
                    normalizedRect: subject.normalizedRect,
                    confidence: subject.confidence,
                    velocity: velocity,
                    age: match.age + 1,
                    missedFrames: 0,
                    isSelected: match.id == selectedID
                )
            }
            return next
        }

        if let selectedID, !merged.contains(where: { $0.id == selectedID }) {
            trackingState.isSearching = true
            trackingState.lifecycle = trackingState.selectedConfidence > 0.35 ? .temporarilyLost : .searching
        } else {
            trackingState.isSearching = false
        }

        if trackingState.mode == .autoBestSubject || trackingState.selectedSubjectID == nil {
            trackingState.selectedSubjectID = merged.max(by: { $0.confidence < $1.confidence })?.id
            if trackingState.lockStartedAt == nil {
                trackingState.lockStartedAt = CACurrentMediaTime()
            }
        }

        merged = merged.map { subject in
            var next = subject
            next.isSelected = next.id == trackingState.selectedSubjectID
            return next
        }

        let selected = selectedSubject(from: merged)
        if selected != nil, trackingState.lifecycle == .temporarilyLost || trackingState.lifecycle == .searching {
            trackingState.lifecycle = .reacquired
        } else if selected != nil {
            trackingState.lifecycle = .tracking
        } else if trackingState.selectedConfidence < 0.1 {
            trackingState.lifecycle = .manualFallback
        }

        trackingState.subjects = merged
        trackingState.selectedConfidence = selected?.confidence ?? max(0, trackingState.selectedConfidence * 0.92)
        trackingState.reacquisitionConfidence = selected.map { min(1, $0.confidence + Float($0.age) * 0.02) } ?? max(0, trackingState.reacquisitionConfidence * 0.9)
        trackingState.lastSelectedRect = selected?.normalizedRect ?? trackingState.lastSelectedRect
        if let selected {
            trackingState.predictedSelectedRect = selected.normalizedRect.offsetBy(dx: selected.velocity.dx * 0.18, dy: selected.velocity.dy * 0.18).clampedUnit
        }
        trackingState.lastUpdateTime = time
        onSubjectsUpdated?(trackingState)
    }

    private func updatePerformance(trackingMS: Double) {
        performance.trackingAnalysisMS = trackingMS
        performance.warning = trackingMS > performance.totalFrameBudgetMS * 0.4 ? "Tracking analysis over budget" : nil
        onPerformanceUpdated?(performance)
    }

    private func bestMatch(for subject: DetectedSubject, previous: [DetectedSubject], selectedID: UUID?, deltaTime: TimeInterval) -> DetectedSubject? {
        previous
            .map { candidate -> (DetectedSubject, CGFloat) in
                let predicted = candidate.normalizedRect.offsetBy(dx: candidate.velocity.dx * deltaTime, dy: candidate.velocity.dy * deltaTime)
                let positionCost = predicted.center.distance(to: subject.normalizedRect.center)
                let sizeCost = abs(predicted.area - subject.normalizedRect.area)
                let kindCost: CGFloat = candidate.kind == subject.kind ? 0 : 0.08
                let selectedBonus: CGFloat = candidate.id == selectedID ? -0.08 : 0
                let ageBonus = -min(CGFloat(candidate.age) * 0.003, 0.05)
                return (candidate, positionCost + sizeCost * 0.8 + kindCost + selectedBonus + ageBonus)
            }
            .filter { $0.1 < 0.26 }
            .min { $0.1 < $1.1 }?
            .0
    }

    private func selectedSubject(from subjects: [DetectedSubject]) -> DetectedSubject? {
        if trackingState.mode == .group {
            return groupSubject(from: subjects)
        }
        return subjects.first(where: { $0.id == trackingState.selectedSubjectID })
    }

    private func groupSubject(from subjects: [DetectedSubject]) -> DetectedSubject? {
        guard !subjects.isEmpty else { return nil }
        let rect = subjects.map(\.normalizedRect).reduce(subjects[0].normalizedRect) { $0.union($1) }.clampedUnit
        let confidence = subjects.map(\.confidence).reduce(0, +) / Float(subjects.count)
        return DetectedSubject(id: UUID(), kind: .person, normalizedRect: rect, confidence: confidence, age: subjects.map(\.age).max() ?? 0, isSelected: true)
    }
}

private final class AnalysisScheduler {
    private var lastRun: [AnalysisTask: CFTimeInterval] = [:]

    func shouldRun(_ task: AnalysisTask, fps: Double) -> Bool {
        let now = CACurrentMediaTime()
        let interval = 1.0 / max(1, fps)
        let previous = lastRun[task] ?? 0
        guard now - previous >= interval else { return false }
        lastRun[task] = now
        return true
    }
}

private extension CGRect {
    var cgRectFromVision: CGRect {
        CGRect(x: minX, y: 1 - maxY, width: width, height: height)
    }

    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    var area: CGFloat {
        width * height
    }

    var clampedUnit: CGRect {
        var next = self
        next.size.width = min(max(next.width, 0.02), 1)
        next.size.height = min(max(next.height, 0.02), 1)
        next.origin.x = min(max(next.origin.x, 0), 1 - next.width)
        next.origin.y = min(max(next.origin.y, 0), 1 - next.height)
        return next
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}

private extension CGVector {
    func damped(maxMagnitude: CGFloat) -> CGVector {
        let magnitude = hypot(dx, dy)
        guard magnitude > maxMagnitude, magnitude > 0 else { return self }
        let scale = maxMagnitude / magnitude
        return CGVector(dx: dx * scale, dy: dy * scale)
    }
}
