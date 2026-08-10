import AVFoundation
import CoreGraphics
import CoreMotion
import Foundation
import QuartzCore
import Vision

final class IntelligentCameraManager {
    var onSubjectsUpdated: ((TrackingState) -> Void)?
    var onHorizonUpdated: ((HorizonState) -> Void)?

    private let visionQueue = DispatchQueue(label: "studio.procamlink.vision", qos: .userInitiated)
    private let motionManager = CMMotionManager()
    private var lastAnalysisTime: CFTimeInterval = 0
    private var trackingState = TrackingState()

    func startMotion() {
        guard motionManager.isDeviceMotionAvailable else {
            onHorizonUpdated?(HorizonState(isAvailable: false, rollDegrees: 0))
            return
        }

        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let roll = motion.attitude.roll * 180 / .pi
            self?.onHorizonUpdated?(HorizonState(isAvailable: true, rollDegrees: roll))
        }
    }

    func stopMotion() {
        motionManager.stopDeviceMotionUpdates()
    }

    func analyze(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        let now = CACurrentMediaTime()
        guard now - lastAnalysisTime >= 1.0 / 15.0 else { return }
        lastAnalysisTime = now

        visionQueue.async { [weak self] in
            self?.performVision(pixelBuffer: pixelBuffer, timestamp: timestamp)
        }
    }

    func selectSubject(at normalizedPoint: CGPoint) {
        guard let subject = trackingState.subjects.min(by: {
            $0.normalizedRect.center.distance(to: normalizedPoint) < $1.normalizedRect.center.distance(to: normalizedPoint)
        }) else {
            return
        }

        trackingState.selectedSubjectID = subject.id
        trackingState.lastSelectedRect = subject.normalizedRect
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

        let detected = faces + humans
        DispatchQueue.main.async { [weak self] in
            self?.mergeSubjects(detected, timestamp: timestamp)
        }
    }

    private func mergeSubjects(_ detected: [DetectedSubject], timestamp: CMTime) {
        let previous = trackingState.subjects
        let selectedID = trackingState.selectedSubjectID

        var merged = detected.map { subject -> DetectedSubject in
            var next = subject
            if let match = previous.min(by: {
                $0.normalizedRect.center.distance(to: subject.normalizedRect.center) < $1.normalizedRect.center.distance(to: subject.normalizedRect.center)
            }), match.normalizedRect.center.distance(to: subject.normalizedRect.center) < 0.18 {
                next = DetectedSubject(id: match.id, kind: subject.kind, normalizedRect: subject.normalizedRect, confidence: subject.confidence, isSelected: match.id == selectedID)
            }
            return next
        }

        if let selectedID, !merged.contains(where: { $0.id == selectedID }) {
            trackingState.isSearching = true
        } else {
            trackingState.isSearching = false
        }

        if trackingState.selectedSubjectID == nil {
            trackingState.selectedSubjectID = merged.max(by: { $0.confidence < $1.confidence })?.id
        }

        merged = merged.map { subject in
            var next = subject
            next.isSelected = next.id == trackingState.selectedSubjectID
            return next
        }

        let selected = merged.first(where: { $0.isSelected })
        trackingState.subjects = merged
        trackingState.selectedConfidence = selected?.confidence ?? max(0, trackingState.selectedConfidence * 0.92)
        trackingState.lastSelectedRect = selected?.normalizedRect ?? trackingState.lastSelectedRect
        trackingState.lastUpdateTime = CMTimeGetSeconds(timestamp)
        onSubjectsUpdated?(trackingState)
    }
}

private extension CGRect {
    var cgRectFromVision: CGRect {
        CGRect(x: minX, y: 1 - maxY, width: width, height: height)
    }

    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}
