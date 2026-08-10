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
        if view.device != nil {
            view.delegate = context.coordinator
        }

        context.coordinator.attach(to: view)
        cameraSession.updatePreviewOrientation(view.previewOrientation)
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
        cameraSession.updatePreviewOrientation(uiView.previewOrientation)
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
    private let pipeline = ProcessedFramePipeline()
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
            let state = FrameProcessingState(
                orientation: snapshot.2,
                adjustments: snapshot.3,
                framing: snapshot.4,
                tracking: snapshot.5,
                horizon: snapshot.6,
                stabilization: snapshot.7,
                monitoring: snapshot.8,
                includeMonitoring: true
            )
            let image = pipeline
                .makeImage(pixelBuffer: pixelBuffer, state: state)
                .transformedForDisplay(in: view.drawableSize, fillMode: snapshot.1)

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
