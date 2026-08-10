import AVFoundation
import CoreImage
import MetalKit
import SwiftUI

protocol CameraFrameConsumer: AnyObject {
    func display(pixelBuffer: CVPixelBuffer, timestamp: CMTime)
}

final class CameraSampleBufferProxy: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    weak var consumer: CameraFrameConsumer?

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        consumer?.display(pixelBuffer: pixelBuffer, timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
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
        context.coordinator.update(fillMode: cameraSession.previewFillMode, adjustments: cameraSession.imageAdjustments)
        context.coordinator.tapHandler = tapHandler
        cameraSession.setFrameConsumer(context.coordinator)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(ProcessedPreviewRenderer.handleTap(_:)))
        view.addGestureRecognizer(tap)

        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.update(fillMode: cameraSession.previewFillMode, adjustments: cameraSession.imageAdjustments)
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
    private var adjustments = ImageAdjustmentState.neutral
    private let stateQueue = DispatchQueue(label: "studio.procamlink.preview.renderer")

    func attach(to view: MTKView) {
        self.view = view
        guard let device = view.device else {
            return
        }
        ciContext = CIContext(mtlDevice: device)
        commandQueue = device.makeCommandQueue()
    }

    func update(fillMode: PreviewFillMode, adjustments: ImageAdjustmentState) {
        stateQueue.async {
            self.fillMode = fillMode
            self.adjustments = adjustments
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

        let snapshot = stateQueue.sync { (latestPixelBuffer, fillMode, adjustments) }
        guard let pixelBuffer = snapshot.0 else {
            return
        }

        autoreleasepool {
            var image = CIImage(cvPixelBuffer: pixelBuffer)
            image = apply(adjustments: snapshot.2, to: image)
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

private extension CIImage {
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
