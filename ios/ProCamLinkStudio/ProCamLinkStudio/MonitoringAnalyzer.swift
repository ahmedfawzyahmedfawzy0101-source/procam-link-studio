import CoreVideo
import Foundation
import QuartzCore

final class MonitoringAnalyzer {
    var onAnalysisUpdated: ((MonitoringAnalysisState) -> Void)?

    private let queue = DispatchQueue(label: "studio.procamlink.monitoring.analysis", qos: .utility)
    private let scheduler = MonitoringAnalysisScheduler()

    func analyze(pixelBuffer: CVPixelBuffer) {
        guard scheduler.shouldRun(fps: 12) else { return }

        queue.async { [weak self] in
            let start = CACurrentMediaTime()
            var state = Self.analyzeLuma(pixelBuffer: pixelBuffer)
            state.analysisMS = (CACurrentMediaTime() - start) * 1000
            DispatchQueue.main.async {
                self?.onAnalysisUpdated?(state)
            }
        }
    }

    private static func analyzeLuma(pixelBuffer: CVPixelBuffer) -> MonitoringAnalysisState {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let plane = 0
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) ?? CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return MonitoringAnalysisState()
        }

        let planeWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let planeHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        let width = planeWidth == 0 ? CVPixelBufferGetWidth(pixelBuffer) : planeWidth
        let height = planeHeight == 0 ? CVPixelBufferGetHeight(pixelBuffer) : planeHeight
        let planeBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
        let bytesPerRow = planeBytesPerRow == 0 ? CVPixelBufferGetBytesPerRow(pixelBuffer) : planeBytesPerRow
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        let stepX = max(1, width / 320)
        let stepY = max(1, height / 180)

        let uvBase = CVPixelBufferGetPlaneCount(pixelBuffer) > 1 ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) : nil
        let uvWidth = CVPixelBufferGetPlaneCount(pixelBuffer) > 1 ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 1) : 0
        let uvHeight = CVPixelBufferGetPlaneCount(pixelBuffer) > 1 ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 1) : 0
        let uvBytesPerRow = CVPixelBufferGetPlaneCount(pixelBuffer) > 1 ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) : 0
        let uvPointer = uvBase?.assumingMemoryBound(to: UInt8.self)

        var histogram = Array(repeating: 0.0, count: 32)
        var red = Array(repeating: 0.0, count: 32)
        var green = Array(repeating: 0.0, count: 32)
        var blue = Array(repeating: 0.0, count: 32)
        var clipping = 0.0
        var shadows = 0.0
        var count = 0.0

        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let value = Double(pointer[y * bytesPerRow + x]) / 255.0
                let bin = min(31, max(0, Int(value * 31)))
                histogram[bin] += 1
                if let uvPointer, uvWidth > 0, uvHeight > 0 {
                    let uvX = min(uvWidth - 1, x / 2) * 2
                    let uvY = min(uvHeight - 1, y / 2)
                    let cb = Double(uvPointer[uvY * uvBytesPerRow + uvX]) - 128
                    let cr = Double(uvPointer[uvY * uvBytesPerRow + uvX + 1]) - 128
                    let yValue = Double(pointer[y * bytesPerRow + x])
                    let r = min(max((yValue + 1.402 * cr) / 255.0, 0), 1)
                    let g = min(max((yValue - 0.344136 * cb - 0.714136 * cr) / 255.0, 0), 1)
                    let b = min(max((yValue + 1.772 * cb) / 255.0, 0), 1)
                    red[min(31, max(0, Int(r * 31)))] += 1
                    green[min(31, max(0, Int(g * 31)))] += 1
                    blue[min(31, max(0, Int(b * 31)))] += 1
                }
                if value >= 0.97 { clipping += 1 }
                if value <= 0.03 { shadows += 1 }
                count += 1
                x += stepX
            }
            y += stepY
        }

        guard count > 0 else { return MonitoringAnalysisState() }
        let peak = max(histogram.max() ?? 1, 1)
        let normalized = histogram.map { $0 / peak }
        let redPeak = max(red.max() ?? 1, 1)
        let greenPeak = max(green.max() ?? 1, 1)
        let bluePeak = max(blue.max() ?? 1, 1)
        return MonitoringAnalysisState(
            lumaHistogram: normalized,
            redHistogram: red.map { $0 / redPeak },
            greenHistogram: green.map { $0 / greenPeak },
            blueHistogram: blue.map { $0 / bluePeak },
            clippingPercent: clipping / count,
            shadowsPercent: shadows / count
        )
    }
}

private final class MonitoringAnalysisScheduler {
    private var lastRun: CFTimeInterval = 0

    func shouldRun(fps: Double) -> Bool {
        let now = CACurrentMediaTime()
        let interval = 1.0 / max(1, fps)
        guard now - lastRun >= interval else { return false }
        lastRun = now
        return true
    }
}
