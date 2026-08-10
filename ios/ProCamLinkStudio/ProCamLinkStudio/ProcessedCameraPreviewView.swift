import AVFoundation
import CoreImage
import MetalKit
import SwiftUI

protocol CameraFrameConsumer: AnyObject {
    func display(pixelBuffer: CVPixelBuffer, timestamp: CMTime)
}

final class CameraSampleBufferProxy: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    weak var previewConsumer: CameraFrameConsumer?
    var analysisHandler: ((CVPixelBuffer, CMTime) -> Void)?

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        previewConsumer?.display(pixelBuffer: pixelBuffer, timestamp: timestamp)
        analysisHandler?(pixelBuffer, timestamp)
    }
}

struct ProcessedCameraPreviewView: UIViewRepresentable {
    @ObservedObject var cameraSession: CameraSessionManager
    let tapHandler: (CGPoint) -> Void

    func makeCoordinator() -> ProcessedPreviewRenderer {
        ProcessedPreviewRenderer()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.backgroundColor = .black
        view.delegate = context.coordinator

        context.coordinator.attach(to: view)
        context.coordinator.update(
            fillMode: cameraSession.previewFillMode,
            orientation: view.previewOrientation,
            adjustments: cameraSession.imageAdjustments,
            framing: cameraSession.smartFraming,
            tracking: cameraSession.trackingState,
            horizon: cameraSession.horizonState,
            stabilization: cameraSession.stabilizationSettings,
            monitoring: cameraSession.monitoringState
        )
        context.coordinator.tapHandler = tapHandler
        cameraSession.setFrameConsumer(context.coordinator)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(ProcessedPreviewRenderer.handleTap(_:)))
        view.addGestureRecognizer(tap)

        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.update(
            fillMode: cameraSession.previewFillMode,
            orientation: uiView.previewOrientation,
            adjustments: cameraSession.imageAdjustments,
            framing: cameraSession.smartFraming,
            tracking: cameraSession.trackingState,
            horizon: cameraSession.horizonState,
            stabilization: cameraSession.stabilizationSettings,
            monitoring: cameraSession.monitoringState
        )
        context.coordinator.tapHandler = tapHandler
        cameraSession.setFrameConsumer(context.coordinator)
    }
}

final class ProcessedPreviewRenderer: NSObject, MTKViewDelegate, CameraFrameConsumer {
    var tapHandler: ((CGPoint) -> Void)?

    private weak var view: MTKView?
    private var ciContext: CIContext?
    private var commandQueue: MTLCommandQueue?
    private var latestPixelBuffer: CVPixelBuffer?
    private var fillMode: PreviewFillMode = .fill
    private var orientation: PreviewOrientation = .portrait
    private var adjustments = ImageAdjustmentState.neutral
    private var framing = SmartFramingSettings()
    private var tracking = TrackingState()
    private var horizon = HorizonState()
    private var stabilization = StabilizationSettings()
    private var monitoring = MonitoringState()
    private var smoothedCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var smoothedCorrectionDegrees = 0.0
    private let stateQueue = DispatchQueue(label: "studio.procamlink.preview.renderer")

    func attach(to view: MTKView) {
        self.view = view
        guard let device = view.device else {
            return
        }
        ciContext = CIContext(mtlDevice: device)
        commandQueue = device.makeCommandQueue()
    }

    func update(
        fillMode: PreviewFillMode,
        orientation: PreviewOrientation,
        adjustments: ImageAdjustmentState,
        framing: SmartFramingSettings,
        tracking: TrackingState,
        horizon: HorizonState,
        stabilization: StabilizationSettings,
        monitoring: MonitoringState
    ) {
        stateQueue.async {
            self.fillMode = fillMode
            self.orientation = orientation
            self.adjustments = adjustments
            self.framing = framing
            self.tracking = tracking
            self.horizon = horizon
            self.stabilization = stabilization
            self.monitoring = monitoring
        }
    }

    func display(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        stateQueue.async {
            self.latestPixelBuffer = pixelBuffer
            DispatchQueue.main.async {
                self.view?.draw()
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let drawable = view.currentDrawable,
            let commandBuffer = commandQueue?.makeCommandBuffer(),
            let ciContext
        else {
            return
        }

        let snapshot = stateQueue.sync { (latestPixelBuffer, fillMode, orientation, adjustments, framing, tracking, horizon, stabilization, monitoring) }
        guard let pixelBuffer = snapshot.0 else {
            return
        }

        autoreleasepool {
            var image = CIImage(cvPixelBuffer: pixelBuffer)
                .oriented(forExifOrientation: snapshot.2.exifOrientation)
            image = applySmartFraming(snapshot.4, tracking: snapshot.5, to: image)
            image = applyStabilization(snapshot.7, horizon: snapshot.6, to: image)
            image = apply(adjustments: snapshot.3, to: image)
            image = applyMonitoring(snapshot.8, to: image)
            image = image.transformedForDisplay(in: view.drawableSize, fillMode: snapshot.1)

            ciContext.render(
                image,
                to: drawable.texture,
                commandBuffer: commandBuffer,
                bounds: CGRect(origin: .zero, size: view.drawableSize),
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }

    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let view = gesture.view else { return }
        let point = gesture.location(in: view)
        tapHandler?(CGPoint(x: point.x / max(view.bounds.width, 1), y: point.y / max(view.bounds.height, 1)))
    }

    private func apply(adjustments: ImageAdjustmentState, to image: CIImage) -> CIImage {
        var output = image
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: adjustments.exposure])
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: adjustedSaturation(adjustments),
                kCIInputContrastKey: adjustedContrast(adjustments),
                kCIInputBrightnessKey: (adjustments.whites * 0.04) - (adjustments.blacks * 0.04)
            ])

        if adjustments.vibrance != 0 {
            output = output.applyingFilter("CIVibrance", parameters: [kCIInputAmountKey: adjustments.vibrance])
        }

        if adjustments.temperature != 0 || adjustments.tint != 0 {
            output = output.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: CGFloat(6500 + adjustments.temperature), y: CGFloat(adjustments.tint)),
                "inputTargetNeutral": CIVector(x: 6500, y: 0)
            ])
        }

        if adjustments.highlights != 0 || adjustments.shadows != 0 {
            output = output.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 - adjustments.highlights,
                "inputShadowAmount": adjustments.shadows
            ])
        }

        if adjustments.sharpness > 0 {
            output = output.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: adjustments.sharpness])
        }

        if adjustments.denoise > 0 {
            output = output.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": adjustments.denoise,
                "inputSharpness": max(0, adjustments.sharpness)
            ])
        }

        if adjustments.gamma != 1 {
            output = output.applyingFilter("CIGammaAdjust", parameters: ["inputPower": adjustments.gamma])
        }

        if adjustments.vignette > 0 {
            output = output.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: adjustments.vignette,
                kCIInputRadiusKey: min(output.extent.width, output.extent.height) * 0.75
            ])
        }

        return applyLook(adjustments.look, intensity: adjustments.lookIntensity, to: output)
    }

    private func applySmartFraming(_ framing: SmartFramingSettings, tracking: TrackingState, to image: CIImage) -> CIImage {
        guard framing.mode != .off else {
            smoothedCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
            return image
        }

        let source = image.extent
        guard let targetRect = targetRect(for: tracking, framing: framing) else {
            smoothedCrop = smoothedCrop.smoothed(toward: CGRect(x: 0, y: 0, width: 1, height: 1), amount: 0.04)
            return crop(image, normalizedCrop: smoothedCrop)
        }

        let desired = desiredCrop(for: targetRect, framing: framing)
        let distance = smoothedCrop.center.distance(to: desired.center)
        let amount = distance < CGFloat(framing.deadZone) ? 0.02 : CGFloat(max(0.02, min(0.45, framing.followSpeed * (1 - framing.smoothness + 0.2))))
        smoothedCrop = smoothedCrop.smoothed(toward: desired, amount: amount).clampedUnit

        let cropped = crop(image, normalizedCrop: smoothedCrop)
        return cropped.transformed(by: CGAffineTransform(translationX: source.minX - cropped.extent.minX, y: source.minY - cropped.extent.minY))
    }

    private func targetRect(for tracking: TrackingState, framing: SmartFramingSettings) -> CGRect? {
        if framing.mode == .group || tracking.mode == .group {
            guard !tracking.subjects.isEmpty else { return tracking.predictedSelectedRect ?? tracking.lastSelectedRect }
            let union = tracking.subjects.map(\.normalizedRect).reduce(tracking.subjects[0].normalizedRect) { $0.union($1) }
            return union.insetBy(dx: -CGFloat(framing.groupSafetyMargin), dy: -CGFloat(framing.groupSafetyMargin)).clampedUnit
        }
        return tracking.predictedSelectedRect ?? tracking.lastSelectedRect ?? tracking.subjects.first?.normalizedRect
    }

    private func desiredCrop(for target: CGRect, framing: SmartFramingSettings) -> CGRect {
        let targetSize = max(target.width, target.height)
        let tightness = max(0.1, min(1, framing.tightness))
        let desiredSubjectShare: CGFloat
        switch framing.mode {
        case .headAndShoulders:
            desiredSubjectShare = 0.46
        case .halfBody, .creatorPortrait:
            desiredSubjectShare = 0.36
        case .fullBody, .group:
            desiredSubjectShare = 0.24
        default:
            desiredSubjectShare = 0.3
        }

        let zoom = min(max(CGFloat(targetSize / (desiredSubjectShare * tightness)), CGFloat(1 / framing.maxDigitalZoom)), CGFloat(1 / framing.minDigitalZoom))
        let cropSize = max(0.1, min(1, zoom))
        var center = target.center

        switch framing.mode {
        case .ruleOfThirdsLeft:
            center.x += cropSize * 0.16
        case .ruleOfThirdsRight:
            center.x -= cropSize * 0.16
        default:
            break
        }

        center.x += CGFloat(framing.horizontalBias + framing.lookRoom) * cropSize
        center.y += CGFloat(framing.headroom + framing.verticalBias) * cropSize
        return CGRect(x: center.x - cropSize / 2, y: center.y - cropSize / 2, width: cropSize, height: cropSize)
    }

    private func crop(_ image: CIImage, normalizedCrop: CGRect) -> CIImage {
        let source = image.extent
        let rect = CGRect(
            x: source.minX + source.width * normalizedCrop.minX,
            y: source.minY + source.height * (1 - normalizedCrop.maxY),
            width: source.width * normalizedCrop.width,
            height: source.height * normalizedCrop.height
        )
        return image.cropped(to: rect)
    }

    private func applyStabilization(_ settings: StabilizationSettings, horizon: HorizonState, to image: CIImage) -> CIImage {
        guard horizon.isAvailable else { return image }

        var targetCorrection = 0.0
        switch settings.horizonMode {
        case .off:
            targetCorrection = 0
        case .levelAssist:
            targetCorrection = -horizon.smoothedRollDegrees * settings.strength * 0.35
        case .horizonLock:
            targetCorrection = -horizon.smoothedRollDegrees * settings.strength
        }

        switch settings.digitalMode {
        case .off:
            break
        case .low:
            targetCorrection += -horizon.smoothedRollDegrees * 0.08
        case .medium:
            targetCorrection += -horizon.smoothedRollDegrees * 0.16
        case .strong:
            targetCorrection += -horizon.smoothedRollDegrees * 0.28
        }

        targetCorrection = min(max(targetCorrection, -settings.maxCorrectionAngle), settings.maxCorrectionAngle)
        smoothedCorrectionDegrees = smoothedCorrectionDegrees * settings.smoothing + targetCorrection * (1 - settings.smoothing)
        guard abs(smoothedCorrectionDegrees) > 0.05 else { return image }

        let source = image.extent
        let radians = CGFloat(smoothedCorrectionDegrees * .pi / 180)
        let rotated = image
            .transformed(by: CGAffineTransform(translationX: -source.midX, y: -source.midY))
            .transformed(by: CGAffineTransform(rotationAngle: radians))
            .transformed(by: CGAffineTransform(translationX: source.midX, y: source.midY))

        let safety = min(max(CGFloat(settings.cropSafetyMargin), 0), 0.25)
        let insetX = source.width * safety
        let insetY = source.height * safety
        return rotated.cropped(to: source.insetBy(dx: insetX, dy: insetY))
    }

    private func applyMonitoring(_ monitoring: MonitoringState, to image: CIImage) -> CIImage {
        var output = image

        if monitoring.falseColor {
            let falseColor = output.applyingFilter("CIFalseColor", parameters: [
                "inputColor0": CIColor(red: 0.05, green: 0.1, blue: 0.8),
                "inputColor1": CIColor(red: 1.0, green: 0.15, blue: 0.05)
            ])
            output = falseColor
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: monitoring.falseColorOpacity)
                ])
                .composited(over: output)
        }

        if monitoring.focusPeaking {
            let edges = output
                .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 6 * monitoring.focusPeakingSensitivity])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: monitoring.focusPeakingOpacity)
                ])
            output = edges.composited(over: output)
        }

        if monitoring.zebras {
            output = applyZebras(monitoring, to: output)
        }

        return output
    }

    private func applyZebras(_ monitoring: MonitoringState, to image: CIImage) -> CIImage {
        guard let threshold = CIFilter(name: "CIColorThreshold") else { return image }
        threshold.setValue(image, forKey: kCIInputImageKey)
        threshold.setValue(monitoring.zebraHighThreshold, forKey: "inputThreshold")
        guard let mask = threshold.outputImage else { return image }

        let stripes = CIImage.stripes(extent: image.extent)
        let zebra = stripes.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: mask
        ])
        return zebra
    }

    private func adjustedSaturation(_ adjustments: ImageAdjustmentState) -> Double {
        adjustments.saturation + lookDelta(adjustments.look, intensity: adjustments.lookIntensity).saturation
    }

    private func adjustedContrast(_ adjustments: ImageAdjustmentState) -> Double {
        adjustments.contrast + lookDelta(adjustments.look, intensity: adjustments.lookIntensity).contrast
    }

    private func applyLook(_ look: LookPreset, intensity: Double, to image: CIImage) -> CIImage {
        guard intensity > 0 else { return image }

        switch look {
        case .mono:
            return image.applyingFilter("CIPhotoEffectMono")
        case .warm:
            return image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: CGFloat(6500 + 700 * intensity), y: 0),
                "inputTargetNeutral": CIVector(x: 6500, y: 0)
            ])
        case .cool:
            return image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: CGFloat(6500 - 700 * intensity), y: 0),
                "inputTargetNeutral": CIVector(x: 6500, y: 0)
            ])
        default:
            return image
        }
    }

    private func lookDelta(_ look: LookPreset, intensity: Double) -> (contrast: Double, saturation: Double) {
        switch look {
        case .natural:
            return (0, 0)
        case .clean:
            return (0.04 * intensity, -0.02 * intensity)
        case .soft:
            return (-0.06 * intensity, -0.03 * intensity)
        case .warm:
            return (0.02 * intensity, 0.03 * intensity)
        case .cool:
            return (0.02 * intensity, -0.01 * intensity)
        case .cinematic:
            return (0.08 * intensity, -0.05 * intensity)
        case .highContrast:
            return (0.15 * intensity, 0.02 * intensity)
        case .mono:
            return (0.06 * intensity, -1 * intensity)
        }
    }
}

private extension UIView {
    var previewOrientation: PreviewOrientation {
        switch window?.windowScene?.interfaceOrientation {
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscapeLeft:
            return .landscapeLeft
        case .landscapeRight:
            return .landscapeRight
        default:
            return .portrait
        }
    }
}

private extension CIImage {
    static func stripes(extent: CGRect) -> CIImage {
        let stripe = CIFilter(
            name: "CIStripesGenerator",
            parameters: [
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0.85),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0.0),
                "inputWidth": 8,
                "inputSharpness": 1
            ]
        )?.outputImage ?? CIImage(color: CIColor(red: 1, green: 1, blue: 1))

        return stripe
            .transformed(by: CGAffineTransform(rotationAngle: .pi / 4))
            .cropped(to: extent)
    }

    func transformedForDisplay(in drawableSize: CGSize, fillMode: PreviewFillMode) -> CIImage {
        let target = CGRect(origin: .zero, size: drawableSize)
        guard extent.width > 0, extent.height > 0, target.width > 0, target.height > 0 else {
            return self
        }

        let xScale = target.width / extent.width
        let yScale = target.height / extent.height
        let scale = fillMode == .fill ? max(xScale, yScale) : min(xScale, yScale)
        let scaledWidth = extent.width * scale
        let scaledHeight = extent.height * scale
        let x = (target.width - scaledWidth) * 0.5
        let y = (target.height - scaledHeight) * 0.5

        return transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: x, y: y))
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    var clampedUnit: CGRect {
        var next = self
        next.size.width = min(max(next.width, 0.1), 1)
        next.size.height = min(max(next.height, 0.1), 1)
        next.origin.x = min(max(next.origin.x, 0), 1 - next.width)
        next.origin.y = min(max(next.origin.y, 0), 1 - next.height)
        return next
    }

    func smoothed(toward target: CGRect, amount: CGFloat) -> CGRect {
        CGRect(
            x: minX + (target.minX - minX) * amount,
            y: minY + (target.minY - minY) * amount,
            width: width + (target.width - width) * amount,
            height: height + (target.height - height) * amount
        )
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}
