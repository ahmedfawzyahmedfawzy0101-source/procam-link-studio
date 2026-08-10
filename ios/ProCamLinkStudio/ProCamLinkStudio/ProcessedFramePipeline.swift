import CoreImage
import CoreVideo
import Foundation

struct FrameProcessingState {
    var orientation: PreviewOrientation
    var adjustments: ImageAdjustmentState
    var framing: SmartFramingSettings
    var tracking: TrackingState
    var horizon: HorizonState
    var stabilization: StabilizationSettings
    var monitoring: MonitoringState
    var includeMonitoring: Bool
}

final class ProcessedFramePipeline {
    private var smoothedCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var smoothedCorrectionDegrees = 0.0

    func makeImage(pixelBuffer: CVPixelBuffer, state: FrameProcessingState) -> CIImage {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
            .oriented(forExifOrientation: state.orientation.exifOrientation)
        image = applySmartFraming(state.framing, tracking: state.tracking, to: image)
        image = applyStabilization(state.stabilization, horizon: state.horizon, to: image)
        image = apply(adjustments: state.adjustments, to: image)
        if state.includeMonitoring {
            image = applyMonitoring(state.monitoring, to: image)
        }
        return image
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
            smoothedCrop = smoothedCrop.pipelineSmoothed(toward: CGRect(x: 0, y: 0, width: 1, height: 1), amount: 0.04)
            return crop(image, normalizedCrop: smoothedCrop)
        }

        let desired = desiredCrop(for: targetRect, framing: framing)
        let distance = smoothedCrop.pipelineCenter.pipelineDistance(to: desired.pipelineCenter)
        let amount = distance < CGFloat(framing.deadZone) ? 0.02 : CGFloat(max(0.02, min(0.45, framing.followSpeed * (1 - framing.smoothness + 0.2))))
        smoothedCrop = smoothedCrop.pipelineSmoothed(toward: desired, amount: amount).pipelineClampedUnit

        let cropped = crop(image, normalizedCrop: smoothedCrop)
        return cropped.transformed(by: CGAffineTransform(translationX: source.minX - cropped.extent.minX, y: source.minY - cropped.extent.minY))
    }

    private func targetRect(for tracking: TrackingState, framing: SmartFramingSettings) -> CGRect? {
        if framing.mode == .group || tracking.mode == .group {
            guard !tracking.subjects.isEmpty else { return tracking.predictedSelectedRect ?? tracking.lastSelectedRect }
            let union = tracking.subjects.map(\.normalizedRect).reduce(tracking.subjects[0].normalizedRect) { $0.union($1) }
            return union.insetBy(dx: -CGFloat(framing.groupSafetyMargin), dy: -CGFloat(framing.groupSafetyMargin)).pipelineClampedUnit
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
        var center = target.pipelineCenter

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
        return rotated.cropped(to: source.insetBy(dx: source.width * safety, dy: source.height * safety))
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
        let low = zebraComposite(threshold: monitoring.zebraLowThreshold, color: CIColor(red: 1, green: 0.85, blue: 0.05, alpha: 0.45), image: image)
        return zebraComposite(threshold: monitoring.zebraHighThreshold, color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.85), image: low)
    }

    private func zebraComposite(threshold thresholdValue: Double, color: CIColor, image: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CIColorThreshold") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(thresholdValue, forKey: "inputThreshold")
        guard let mask = filter.outputImage else { return image }

        let stripes = CIImage.stripes(extent: image.extent, color: color)
        return stripes.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: mask
        ])
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

extension CIImage {
    static func stripes(extent: CGRect, color: CIColor) -> CIImage {
        let stripe = CIFilter(
            name: "CIStripesGenerator",
            parameters: [
                "inputColor0": color,
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

extension CGRect {
    var pipelineCenter: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    var pipelineClampedUnit: CGRect {
        var next = self
        next.size.width = min(max(next.width, 0.1), 1)
        next.size.height = min(max(next.height, 0.1), 1)
        next.origin.x = min(max(next.origin.x, 0), 1 - next.width)
        next.origin.y = min(max(next.origin.y, 0), 1 - next.height)
        return next
    }

    func pipelineSmoothed(toward target: CGRect, amount: CGFloat) -> CGRect {
        CGRect(
            x: minX + (target.minX - minX) * amount,
            y: minY + (target.minY - minY) * amount,
            width: width + (target.width - width) * amount,
            height: height + (target.height - height) * amount
        )
    }
}

extension CGPoint {
    func pipelineDistance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}
